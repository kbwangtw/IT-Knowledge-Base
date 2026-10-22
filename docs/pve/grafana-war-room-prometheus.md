---
layout: default
title: "用 Grafana 建立戰情中心（三）：接上 Prometheus（Ceph 與 PVE）"
date: 2026-10-22
categories: [PVE, Grafana, Prometheus, Ceph]
permalink: /docs/pve/grafana-war-room-prometheus/
last_modified_at: 2026-10-22
---
{% raw %}

# 用 Grafana 建立戰情中心（三）：接上 Prometheus（Ceph 與 PVE）

> **一句話**：在 Grafana 同一台容器裡裝 Prometheus，啟用 Ceph 內建的 prometheus 模組、再用**唯讀 Token** 的 PVE exporter 讀取叢集狀態，戰情中心多了「Ceph／PVE」區塊：8 格狀態、3 張趨勢圖和一張「VM／CT 位置與 HA」表，數字都與命令列對照過。

| 項目 | 內容 |
| --- | --- |
| 適合誰看 | 想在 Grafana 看到 Ceph 健康、節點負載、VM／HA 狀態的人 |
| 環境 | PVE 9.2.21、Ceph 20.2.4（3 節點、3 OSD）；Grafana 13.2.3（CT 114，Ubuntu 24.04）；Prometheus 2.45.3（Ubuntu 套件）；prometheus-pve-exporter 3.10.1 |
| 日期 | 2026-10-22 |
| 結論 | ✅ Ceph 9283 只允許 Grafana；✅ Prometheus／exporter 只聽本機；✅ PVE Token 只有 `*.Audit`；✅ exporter 驗證 PVE 憑證；✅ 12 個面板與命令列一致；✅ 停掉 exporter 時「監控資料來源」會變紅 |

> 第一、二階段見 [戰情中心（一）：接上 Wazuh](https://kbwangtw.github.io/IT-Knowledge-Base/docs/pve/grafana-war-room-wazuh/)、[戰情中心（二）：接上 LibreNMS](https://kbwangtw.github.io/IT-Knowledge-Base/docs/pve/grafana-war-room-librenms/)。文中 IP 都是文件示範位址：Grafana 192.0.2.33，node10／11／12 為 192.0.2.10／.11／.12。

## 1. 先認識幾個名詞

| 名詞 | 白話解釋 |
| --- | --- |
| **Prometheus** | 每隔幾秒去各處「抓」一次數字並存成時間序列的資料庫 |
| **scrape（抓取）** | Prometheus 連到某個網址讀取數字的動作；被抓的對象叫 target |
| **exporter** | 把某個系統的狀態翻譯成 Prometheus 看得懂格式的小程式 |
| **Ceph prometheus 模組** | Ceph mgr 內建的 exporter，開啟後在 9283 埠提供數字 |
| **active／standby mgr** | Ceph 的管理程序有三份，同時只有一份在工作（active），其他待命 |
| **PVE exporter** | 用 PVE API 讀取節點、VM／CT、儲存、HA 狀態的 exporter（Python） |
| **API Token／權限分離（privsep）** | 給程式用的通行證；開啟權限分離時，Token 的權限是「使用者權限」和「Token 權限」的交集 |
| **PVEAuditor** | PVE 內建的唯讀角色，只有各種 `*.Audit` 權限 |
| **PromQL** | Prometheus 的查詢語法，例如 `max(ceph_health_status)` |
| **venv** | Python 的獨立環境，套件裝在自己的目錄，不影響系統的 Python |

## 2. 全貌與原則

```text
                          CT 114（Grafana）
  ┌─────────────────────────────────────────────────────────┐
  │ Grafana :3000 ──→ Prometheus 127.0.0.1:9090             │
  │                     │  每 15～30 秒抓一次               │
  │                     ├──→ PVE exporter 127.0.0.1:9221 ───┼──→ node10 PVE API :8006（唯讀 Token，驗證憑證）
  │                     │                                   │
  └─────────────────────┼───────────────────────────────────┘
                        └──→ node10／11／12 :9283（Ceph prometheus 模組；只有 active mgr 有資料）
                             └ 各節點 nftables：9283 只允許 Grafana
```

照第一篇的三原則：**唯讀帳號、來源端防火牆只允許 Grafana、從其他來源實測會被擋**。這次多一條：Prometheus 和 exporter 都跟 Grafana 在同一台容器，所以**只聽 `127.0.0.1`**，外面根本連不到，不需要另外開防火牆。

## 3. 步驟零：盤點

**做什麼**：先看 mgr 在哪、防火牆狀態、CT 114 資源，全部只讀。

```bash
ceph -s | head -15
ceph mgr stat
ceph mgr services
ceph mgr module ls | grep -i prometheus
pve-firewall status
pct config 114 | grep -E '^(cores|memory|swap|rootfs)'
pct exec 114 -- bash -c 'df -h /; free -h; ss -tlnp'      # 在 CT 114 所在節點執行
```

**看到的結果**：

| 看到的 | 代表什麼 | 影響 |
| --- | --- | --- |
| `mgr: node12(active), standbys: node11, node10` | 三台都有 mgr | Prometheus 要三台都抓 |
| `prometheus  -`、`ceph mgr services` 是 `{}` | 模組沒開 | 可以「先擋、再開」 |
| `pve-firewall status: disabled/running` | 叢集防火牆沒開，節點上的埠同網段都連得到 | 9283 要自己用 nftables 擋 |
| CT 114 磁碟剩 26G、記憶體可用 1.7G | 夠放 Prometheus | 保留上限設 8GB |
| CT 114 沒有程式聽 9090、9221 | 埠是空的 | 照計畫使用 |

## 4. 步驟一：Ceph prometheus 模組

### 4-1 先擋：三台節點的 9283 只准 Grafana

**為什麼不寫進 `/etc/nftables.conf`**：Debian 預設的那個檔案開頭有 `flush ruleset`（清空所有規則），日後打開 PVE 防火牆時，開機可能把 PVE 自己的規則一起清掉。改用**獨立規則檔＋小服務**，只管自己那張表。

在 node10 建好兩個檔案：

```bash
GRAFANA_IP=192.0.2.33

cat > /root/ceph-prometheus-fw.nft <<EOF
table inet ceph_prometheus
delete table inet ceph_prometheus
table inet ceph_prometheus {
    chain input {
        type filter hook input priority filter - 1; policy accept;
        iif "lo" accept
        tcp dport 9283 ip saddr ${GRAFANA_IP} accept
        tcp dport 9283 drop
    }
}
EOF

cat > /root/ceph-prometheus-fw.service <<'EOF'
[Unit]
Description=Restrict Ceph mgr prometheus port 9283 to Grafana (CT 114)
Before=ceph-mgr.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/sbin/nft -f /etc/ceph-prometheus-fw.nft
ExecStop=/usr/sbin/nft delete table inet ceph_prometheus

[Install]
WantedBy=multi-user.target
EOF
```

| 片段 | 意思 |
| --- | --- |
| 前兩行 `table …`／`delete table …` | 先建空表再刪，接著重建；重跑幾次都不會出現重複規則 |
| `priority filter - 1` | 比一般規則早一步檢查 |
| `iif "lo" accept` | 節點連自己不擋，方便除錯 |
| `ip saddr … accept` → `drop` | 只有 Grafana 能連 9283，其他一律丟掉（IPv6 也被 drop 擋住） |
| `Before=ceph-mgr.target` | 開機時規則先載入、mgr 才啟動，沒有空窗 |
| `ExecStop` | `systemctl stop` 時刪掉這張表，還原乾淨 |

派送到三台並啟用：

```bash
for n in node10 node11 node12; do
  echo "== $n"
  scp -q /root/ceph-prometheus-fw.nft root@$n:/etc/ceph-prometheus-fw.nft
  scp -q /root/ceph-prometheus-fw.service root@$n:/etc/systemd/system/ceph-prometheus-fw.service
  ssh root@$n 'nft -c -f /etc/ceph-prometheus-fw.nft && systemctl daemon-reload && systemctl enable --now ceph-prometheus-fw && nft list table inet ceph_prometheus | grep dport'
done
```

**看到的結果**：三台各印出 `tcp dport 9283 ip saddr 192.0.2.33 accept` 和 `tcp dport 9283 drop`。

### 4-2 再開：啟用模組（整個叢集一次）

```bash
ceph mgr module enable prometheus
sleep 5; ceph mgr services
```

**看到的結果**：第一次 5 秒內還是 `{}`（模組還在啟動）；再查一次出現 `"prometheus": "http://192.0.2.12:9283/"`。

### 4-3 兩邊實測

在 **Grafana 容器內**（`root@grafana`）：

```bash
for ip in 192.0.2.10 192.0.2.11 192.0.2.12; do
  echo -n "$ip  "
  curl -s -o /dev/null -w "%{http_code}  %{size_download} bytes\n" --max-time 5 http://$ip:9283/metrics
done
```

在**節點**（例如 `root@node11`）：

```bash
curl -s -o /dev/null -w '%{http_code}\n' --max-time 5 http://192.0.2.12:9283/metrics
```

**看到的結果**：

| 來源 → 目標 | 結果 | 意思 |
| --- | --- | --- |
| Grafana → node12（active） | `200  32026 bytes` | ✅ 有資料 |
| Grafana → node10、node11（standby） | `200  0 bytes` | standby 回 200 但沒內容；Prometheus 會當成 up，**不會誤報 down** |
| node11 → node12 | `000` | ✅ 被防火牆擋掉 |

## 5. 步驟二：在 CT 114 安裝 Prometheus

### 5-1 安裝，但先不讓它自動啟動

Ubuntu 套件一裝好就會啟動，而且預設聽 `0.0.0.0:9090`。先用 `policy-rc.d` 擋住，改完設定再自己啟動。在 `root@grafana`：

```bash
apt update && apt policy prometheus
printf '#!/bin/sh\nexit 101\n' > /usr/sbin/policy-rc.d && chmod +x /usr/sbin/policy-rc.d
apt install -y --no-install-recommends prometheus
rm /usr/sbin/policy-rc.d
systemctl is-active prometheus                 # inactive
```

| 片段 | 意思 |
| --- | --- |
| `policy-rc.d` 回傳 `exit 101` | Debian／Ubuntu 的標準機制：這次安裝不要啟動服務 |
| `--no-install-recommends` | 不順便裝 node-exporter，免得多開 9100 埠 |
| `rm /usr/sbin/policy-rc.d` | **一定要刪**，否則之後裝的套件都不會自動啟動 |

**看到的結果**：版本 `2.45.3+ds-2ubuntu0.3`，來自 `noble-security`（universe 但有在收安全修補）；安裝訊息出現 `policy-rc.d denied execution of start`，最後 `inactive`；多用 331 MB。

### 5-2 只聽本機、設保留上限

```bash
cp -a /etc/default/prometheus /etc/default/prometheus.bak-$(date +%Y%m%d-%H%M%S)
cat > /etc/default/prometheus <<'EOF'
ARGS="--web.listen-address=127.0.0.1:9090 --storage.tsdb.retention.time=30d --storage.tsdb.retention.size=8GB"
EOF
```

| 參數 | 意思 |
| --- | --- |
| `127.0.0.1:9090` | 只有容器內（Grafana）連得到 |
| `retention.time=30d` | 資料保留 30 天 |
| `retention.size=8GB` | 超過 8GB 先刪最舊的，保護 30G 的磁碟 |

### 5-3 抓取設定（先只有 Ceph）

```bash
cp -a /etc/prometheus/prometheus.yml /etc/prometheus/prometheus.yml.bak-$(date +%Y%m%d-%H%M%S)
cat > /etc/prometheus/prometheus.yml <<'EOF'
global:
  scrape_interval: 15s
  evaluation_interval: 15s

scrape_configs:
  - job_name: prometheus
    static_configs:
      - targets: ['127.0.0.1:9090']

  - job_name: ceph
    honor_labels: true
    static_configs:
      - targets: ['192.0.2.10:9283', '192.0.2.11:9283', '192.0.2.12:9283']
EOF
promtool check config /etc/prometheus/prometheus.yml
```

| 片段 | 意思 |
| --- | --- |
| `scrape_interval: 15s` | 跟 Ceph 模組預設的更新頻率一致 |
| `honor_labels: true` | 保留 Ceph 自帶的標籤（Ceph 官方建議） |
| 三台都列 | mgr 換到哪台都抓得到 |
| `promtool check config` | 先檢查語法，出現 `SUCCESS` 才繼續 |

### 5-4 啟動並驗收

```bash
systemctl enable --now prometheus
sleep 20
ss -tlnp | grep 9090
curl -s http://127.0.0.1:9090/-/ready; echo
curl -s 'http://127.0.0.1:9090/api/v1/targets' | python3 -c 'import json,sys; [print(t["labels"]["job"], t["scrapeUrl"], t["health"], t["lastError"]) for t in json.load(sys.stdin)["data"]["activeTargets"]]'
curl -s 'http://127.0.0.1:9090/api/v1/query?query=ceph_health_status'; echo
```

**看到的結果**：只有 `127.0.0.1:9090`；`Prometheus Server is Ready.`；4 個 target（prometheus、三台 ceph）都是 `up`；`ceph_health_status` 的值是 `"0"`（0＝HEALTH_OK、1＝WARN、2＝ERR），`instance` 是目前 active mgr 的位址。

## 6. 步驟三：PVE 唯讀 Token 與 PVE exporter

### 6-1 建立唯讀使用者與 Token（任一節點）

```bash
pveum user add pve-exporter@pve --comment "Prometheus PVE exporter (read-only, CT 114)"
pveum acl modify / --users pve-exporter@pve --roles PVEAuditor
pveum user token add pve-exporter@pve prometheus --privsep 1 \
  --expire $(date -d '+1 year' +%s) --comment "Grafana CT 114"
pveum acl modify / --tokens 'pve-exporter@pve!prometheus' --roles PVEAuditor
pveum user token permissions pve-exporter@pve prometheus --path /
```

| 片段 | 意思 |
| --- | --- |
| `@pve`、不設密碼 | PVE 自己的帳號系統，不能 SSH、也不能從網頁登入，只能透過 Token 使用 |
| `PVEAuditor` | 內建唯讀角色 |
| `--privsep 1` | 權限分離：使用者和 Token **兩邊都要**給 PVEAuditor |
| `--expire …+1 year` | 一年後到期，跟 LibreNMS Token 一樣定期更換 |

**看到的結果**：

- Token 的 `value` **只顯示這一次**，立刻存進密碼管理器；`info` 是 `privsep: 1`、`expire: 1824183190`（2027-10-22）。
- 權限只有 7 個：`Datastore.Audit`、`Mapping.Audit`、`Pool.Audit`、`SDN.Audit`、`Sys.Audit`、`VM.Audit`、`VM.GuestAgent.Audit`，沒有任何能修改或開關機的權限。

**順便確認憑證**（決定 exporter 能不能驗證 TLS）：

```bash
ls /etc/pve/nodes/*/pveproxy-ssl.pem 2>/dev/null || echo "沒有自訂憑證，用的是 PVE 內建憑證"
openssl x509 -in /etc/pve/nodes/node10/pve-ssl.pem -noout -subject -ext subjectAltName
```

**看到的結果**：沒有自訂憑證；node10 憑證的 SAN 包含 `192.0.2.10`、`node10`、`node10.<網域>`，由叢集 CA（`/etc/pve/pve-root-ca.pem`）簽發。所以 exporter 用 IP 連線、配上叢集 CA，就能驗證憑證。

### 6-2 安裝 exporter（Ubuntu 沒有套件，改用 venv）

`apt policy prometheus-pve-exporter` 顯示 `Unable to locate package`，改用 Python venv 安裝官方版本。

**在 CT 114 所在節點**把叢集 CA 放進容器（CA 是公開憑證，不是金鑰）：

```bash
pct push 114 /etc/pve/pve-root-ca.pem /etc/prometheus/pve-root-ca.pem --perms 644
```

**在 `root@grafana`**：

```bash
apt install -y python3-venv
useradd --system --no-create-home --shell /usr/sbin/nologin pve-exporter
python3 -m venv /opt/pve-exporter
/opt/pve-exporter/bin/pip install --upgrade pip prometheus-pve-exporter
/opt/pve-exporter/bin/pip show prometheus-pve-exporter | grep -E '^(Name|Version)'
```

**看到的結果**：`prometheus-pve-exporter 3.10.1`（相依套件包含 proxmoxer 2.3.0、requests 2.34.2、gunicorn 26.2.0）。

### 6-3 設定檔：Token 不留在指令歷史

```bash
read -rsp "貼上 Token value（畫面不會顯示）: " PVE_TOKEN; echo
umask 077
cat > /etc/prometheus/pve.yml <<EOF
default:
  user: pve-exporter@pve
  token_name: prometheus
  token_value: "${PVE_TOKEN}"
  verify_ssl: true
EOF
unset PVE_TOKEN; umask 022
chown pve-exporter:pve-exporter /etc/prometheus/pve.yml
ls -l /etc/prometheus/pve.yml
```

| 片段 | 意思 |
| --- | --- |
| `read -rsp` | 貼上時畫面不顯示，指令歷史只記到變數名稱 |
| `umask 077` | 接下來建立的檔案權限是 600 |
| `verify_ssl: true` | 驗證 PVE 憑證，不跳過 |
| `unset` | 用完清掉變數 |

**看到的結果**：`-rw------- 1 pve-exporter pve-exporter … /etc/prometheus/pve.yml`。

### 6-4 systemd 服務（只聽本機）

```bash
cat > /etc/systemd/system/pve-exporter.service <<'EOF'
[Unit]
Description=Prometheus PVE exporter (read-only token, for Grafana)
After=network-online.target
Wants=network-online.target

[Service]
User=pve-exporter
Group=pve-exporter
Environment=REQUESTS_CA_BUNDLE=/etc/prometheus/pve-root-ca.pem
ExecStart=/opt/pve-exporter/bin/pve_exporter --config.file /etc/prometheus/pve.yml --web.listen-address 127.0.0.1:9221
Restart=on-failure
RestartSec=5
NoNewPrivileges=yes

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload && systemctl enable --now pve-exporter
sleep 3; systemctl is-active pve-exporter; ss -tlnp | grep 9221
curl -s 'http://127.0.0.1:9221/pve?target=192.0.2.10&cluster=1&node=1' | grep -E '^pve_(up|version_info)' | head -20
```

| 片段 | 意思 |
| --- | --- |
| `REQUESTS_CA_BUNDLE=…` | 讓 exporter 改用叢集 CA 驗證 PVE 憑證 |
| `127.0.0.1:9221` | 只有容器內的 Prometheus 連得到 |
| `User=pve-exporter` | 低權限帳號執行 |
| `target=…&cluster=1&node=1` | 問 node10 的 API；`cluster=1` 一次拿整個叢集 |

**看到的結果**：`active`、`127.0.0.1:9221`；`pve_up{id="cluster/<叢集名稱>"} 1.0`、三台 `node/…`、VM／CT 100～114、儲存都是 `1.0`，沒有 SSL 錯誤，代表 **CA 驗證確實可行**。

### 6-5 讓 Prometheus 抓 PVE

```bash
cp -a /etc/prometheus/prometheus.yml /etc/prometheus/prometheus.yml.bak-$(date +%Y%m%d-%H%M%S)
cat >> /etc/prometheus/prometheus.yml <<'EOF'

  - job_name: pve
    scrape_interval: 30s
    metrics_path: /pve
    params:
      module: [default]
      cluster: ['1']
      node: ['1']
    static_configs:
      - targets: ['192.0.2.10']
    relabel_configs:
      - source_labels: [__address__]
        target_label: __param_target
      - source_labels: [__param_target]
        target_label: instance
      - target_label: __address__
        replacement: 127.0.0.1:9221
EOF
promtool check config /etc/prometheus/prometheus.yml && systemctl reload prometheus
```

| 片段 | 意思 |
| --- | --- |
| `cat >>` | 接在檔案最後面；`scrape_configs` 是最後一個區段，所以直接接上就屬於它 |
| `targets: ['192.0.2.10']` | 問 node10；刻意**不選 CT 114 所在的節點**，演練時比較好分辨問題 |
| `relabel_configs` 三段 | 把「要問哪台 PVE」放進網址參數 `target`，實際連線改連本機 exporter（官方 README 寫法） |
| `scrape_interval: 30s` | 減少 PVE API 負擔 |

**看到的結果**：5 個 target 全部 `up`（多了 `pve 192.0.2.10`）；`count(pve_up)` 是 **34**。

## 7. 步驟四：Grafana 資料來源

**Connections → Add new connection → Prometheus** 會先看到外掛介紹頁，按右上角 **Add new data source**（旁邊的 Uninstall 不要按）：

| 欄位 | 設定 |
| --- | --- |
| Name | `prometheus` |
| Prometheus server URL | `http://127.0.0.1:9090` |
| Authentication | No Authentication（同一台容器、只聽本機） |

**看到的結果**：Save & test 出現 `Successfully queried the Prometheus API.`

面板要用的 20 個 metric 都確認存在：

```bash
curl -s http://127.0.0.1:9090/api/v1/label/__name__/values | python3 -c 'import json,sys; print("\n".join(json.load(sys.stdin)["data"]))' | grep -E '^(pve_|ceph_(health|osd_|pg_|cluster_total|mon_quorum))'
```

`pve_ha_state` 的格式用 Explore 查 `pve_ha_state == 1` 確認：每個 HA 資源一個狀態一筆、目前狀態的值是 1；共 16 筆，3 台節點是 `state="online"`、13 台 VM／CT 是 `state="started"`。VM 104、108 **刻意不加入 HA**，所以不在裡面。

## 8. 步驟五：做面板

### 8-1 Grafana 13 的分區塊方式

儀表板「戰情中心」→ **Edit** → 右側工具列 **＋（Add new element）**。第一次只有 **Group into rows**：

1. **Group into rows**：現有 Wazuh／LibreNMS 面板收進第一個區塊，標題改成 `資安／設備`，存檔
2. 再按 **＋**，這時出現 **Add row**，新增 `Ceph／PVE`
3. 新面板要用 **`Ceph／PVE` 正下方**那顆 **Add panel**（上一個區塊也有一顆）

### 8-2 第一個面板的完整做法（Ceph 健康）

1. **Add panel** → Title `Ceph 健康` → **Edit visualization**
2. **Data source 預設是 `Wazuh Alerts`**，改成 **prometheus**；查詢切到 **Code**，貼 `max(ceph_health_status)`，Shift＋Enter
3. 右側 Suggestions 點 **Stat**
4. Value mappings：`0`→`HEALTH_OK` 綠、`1`→`HEALTH_WARN` 橘、`2`→`HEALTH_ERR` 紅
5. Stat styles：**Color mode = Background Solid**、**Graph mode = None**
6. **Back** → **Save**

其餘 Stat 面板從相近的面板 **Duplicate** 再改，最省事。設定欄右上角的**放大鏡**可以直接搜尋 `mapping`、`threshold`、`unit`、`legend`。

### 8-3 狀態面板（Stat）

| 面板 | 查詢 | 顏色 | 驗收時 |
| --- | --- | --- | --- |
| Ceph 健康 | `max(ceph_health_status)` | Mapping 0／1／2 → OK 綠／WARN 橘／ERR 紅 | HEALTH_OK |
| OSD 異常數 | `count(ceph_osd_up == 0 or ceph_osd_in == 0) or vector(0)` | Base 綠；≥1 紅 | 0 |
| PG 不健康數 | `sum(ceph_pg_total) - sum(ceph_pg_clean)` | Base 綠；≥1 橘（scrub 時可能短暫不是 clean） | 0 |
| MON quorum | `sum(ceph_mon_quorum_status)` | Base **紅**；≥3 綠（剩 2 個時再掉一台 Ceph 就停擺） | 3 |
| HA 異常數 | 見下方 | Base 綠；≥1 紅 | 0 |
| 停機的 VM／CT | `count(pve_up{id=~"(qemu|lxc)/.*"} == 0) or vector(0)` | Base 綠；≥1 紅 | 0 |
| 監控資料來源 | `min(up)` | Mapping 1→`正常` 綠、0→`中斷` 紅 | 正常 |
| Ceph 使用率 | `sum(ceph_cluster_total_used_bytes) / sum(ceph_cluster_total_bytes) * 100` | Gauge；Unit Percent (0-100)；Max 100；70 橘、80 紅 | 19.4% |

HA 異常數：

```promql
count((pve_ha_state{id=~"(qemu|lxc)/.*", state!="started"} == 1) or (pve_ha_state{id=~"node/.*", state!="online"} == 1)) or vector(0)
```

| 片段 | 意思 |
| --- | --- |
| `max(…)`、`sum(…)` | 把 `instance` 合併掉；Ceph 資料只來自 active mgr，換手後 instance 會變 |
| `== 0`／`!= "started"` | 只留下異常的 |
| `count(…)` | 算有幾個 |
| `or vector(0)` | 一個都沒有時 `count` 回傳「沒有資料」，補一個 0 才會是綠色 |
| `min(up)` | 5 個 target 有一個抓不到就變 0；用來發現「監控本身失明」 |

### 8-4 趨勢圖（Time series）

| 面板 | 查詢 | 設定 |
| --- | --- | --- |
| OSD 延遲 | `max by (ceph_daemon) (ceph_osd_commit_latency_ms)` | Legend `{{ceph_daemon}}`；Unit milliseconds；Legend Mode **Table**、Values **Mean、Max** |
| 節點 CPU | `pve_cpu_usage_ratio{id=~"node/.*"} * 100` | Legend `{{id}}`；Unit Percent (0-100) |
| 節點記憶體 | `pve_memory_usage_bytes{id=~"node/.*"} / pve_memory_size_bytes{id=~"node/.*"} * 100` | 同上 |

Legend 在查詢下方 **Options** 的**最左邊**欄位；中間那格是 Min step，不要填錯。

### 8-5 VM／CT 位置與 HA（Table）

原本規劃「VM／CT 狀態表」和「HA 狀態表」兩張，但跟 LibreNMS 設備清單太像，所以合併成一張，重點放在 LibreNMS 看不到的**所在節點**和 **HA 狀態**：

| | 設備清單（LibreNMS） | VM／CT 位置與 HA（PVE） |
| --- | --- | --- |
| 問誰 | 每台機器的作業系統（SNMP） | PVE |
| 抓得到 | 作業系統當掉、PVE 以外的設備 | VM 被停掉、HA 把它搬到哪台節點 |

查詢（Options：**Format = Table**、**Type = Instant**）：

```promql
((pve_up{id=~"(qemu|lxc)/.*"} * on(id) group_left(name, node) pve_guest_info) * on(id) group_left(state) (pve_ha_state == 1)) or on(id) label_replace(pve_up{id=~"(qemu|lxc)/.*"} * on(id) group_left(name, node) pve_guest_info, "state", "未加入 HA", "", "")
```

| 區塊 | 意思 |
| --- | --- |
| `pve_up{…} * on(id) group_left(name, node) pve_guest_info` | 每台 VM／CT 開機（1）或停機（0），帶上名稱和所在節點 |
| `… * on(id) group_left(state) (pve_ha_state == 1)` | 再接上 HA 狀態；只有 13 台 HA 接得上 |
| `label_replace(…, "state", "未加入 HA", "", "")` | 替每一筆加上 `state="未加入 HA"`（最後兩個 `""` 代表不設條件） |
| `or on(id)` | 只補前半段**沒有的 id**（104、108），不會重複 |

顯示設定：

- **Transformations → Organize fields by name**：隱藏 Time、id、instance、job；`name`→名稱、`node`→所在節點、`state`→HA、`Value`→狀態
- Value mappings：`1`→`執行中` 綠、`0`→`停機` 紅
- **Add field override → Fields with name：狀態 → Cell options > Cell type：Colored background**（只染這一欄；面板層級的 Cell type 維持 Auto）

**看到的結果**：15 列；13 台 HA 是 `started`，UBClient（104）、WinClient（108）是 `未加入 HA`，全部「執行中」。

**版面**：最後兩張表都保留，「設備清單（LibreNMS）」和「VM／CT 位置與 HA」**左右並排**。一邊看作業系統有沒有回應，一邊看 VM 在哪台節點、HA 狀態，演練時兩邊對照最方便。

> 評估過合併成一張（面板資料來源選 Mixed，再用 Join by field 依主機名稱對應），**決定不做**：LibreNMS 是 `adguard.<網域>`、PVE 是 `AdGuard`，PromQL 不能轉小寫，要另靠 Grafana 轉換；而且任一邊改名就會對不上，又沒有錯誤提示。並排對照時注意：PVE「執行中」但 LibreNMS「Down」，代表 VM 開著、裡面的系統沒回應。
>
> 並排時也看出：**DC01、DC02、CA、UBClient、WinClient 這 5 台 Windows 不在 LibreNMS 清單**，網域控制站和 CA 當時沒有 SNMP 監控；10/22 已改用 Ping 加入 LibreNMS，見[戰情中心（二）](https://kbwangtw.github.io/IT-Knowledge-Base/docs/pve/grafana-war-room-librenms/)第 9 節。

## 9. 驗收

### 9-1 故意讓監控失明：停掉 exporter

```bash
systemctl stop pve-exporter; date        # 停止（14:38:33）
# 等約 1 分鐘，Grafana 按 Refresh
systemctl start pve-exporter; systemctl is-active pve-exporter
```

**看到的結果**：「監控資料來源」變成**中斷**；恢復後回到**正常**。第一次測試時「中斷」是橘底，原因是改 mapping 時 `0` 那列沿用了舊的橘色，改成紅色後重測正確。

> **推測（未逐格確認）**：exporter 停掉時，PVE 的數字抓不到，`count` 沒有東西可算，`or vector(0)` 會補 0，所以「HA 異常數」「停機的 VM／CT」**仍然是綠色 0**。這正是需要「監控資料來源」這一格的原因：不能只看其他格是綠的。

### 9-2 與命令列對照

```bash
ceph -s | grep -E 'health|mon:|osd:|pgs'
ceph df | head -4
pvesh get /cluster/resources --type node --output-format json | python3 -c 'import json,sys; [print(n["node"], n["status"], "CPU %.1f%%" % (n["cpu"]*100), "MEM %.1f%%" % (n["mem"]/n["maxmem"]*100)) for n in json.load(sys.stdin)]'
ha-manager status | grep -c started
```

| 面板 | 面板顯示 | 命令列 | |
| --- | --- | --- | --- |
| Ceph 健康 | HEALTH_OK | `HEALTH_OK` | ✅ |
| OSD 異常數 | 0 | 3 up、3 in | ✅ |
| MON quorum | 3 | quorum node10,node11,node12 | ✅ |
| PG 不健康數 | 0 | 97 active+clean | ✅ |
| Ceph 使用率 | 19.4% | %RAW USED 19.38 | ✅ |
| 節點記憶體（平均） | 19.6／43.5／27.4% | 當下 20.9／43.5／28.5% | ✅ 平均與當下差約 1% |
| 節點 CPU（平均） | 1.24／1.82／0.99% | 當下 2.0／1.9／1.0% | ✅ |
| HA（started） | 13 台 | 13 | ✅ |
| OSD 延遲 | 平均 6.45／0.075／1.20 ms | `ceph osd perf` 5／0／1 ms | ✅ 比例一致 |

## 10. 順便發現

### 10-1 三顆 OSD 的延遲差很多：三個不同型號的消費級 NVMe

| OSD | 節點 | NVMe 型號 | 延遲平均／最高 |
| --- | --- | --- | --- |
| osd.0 | node10 | BIWIN NV7200 2TB | 6.45／30 ms |
| osd.1 | node11 | Lexar THOR PRO 2TB | 0.075／1 ms |
| osd.2 | node12 | Kingston NV3（SNV3S2000G） | 1.20／18 ms |

```bash
ceph osd tree                                   # CLASS 都是 ssd；osd.1 WEIGHT 1.86299，其他 1.81940
for i in 0 1 2; do ceph osd metadata $i | grep -E '"(hostname|rotational|devices)"'; done
for n in node10 node11 node12; do ssh root@$n 'smartctl -i /dev/nvme1n1 | grep -E "Model Number|Firmware"'; done
```

- osd.0 一直比較慢，不是新問題：10/14〈[BlueStore 慢操作](https://kbwangtw.github.io/IT-Knowledge-Base/docs/pve/ceph-bluestore-slow-op-backup-schedule/)〉的 `ceph osd perf` 也是 osd.0 6 ms、另外兩顆 1 ms，當時 SMART 正常。
- Ceph 寫入要等三個副本都完成，**最慢的 osd.0 決定整體寫入速度**。
- **推測，需查規格書**：三款都沒有斷電保護（PLP）。osd.1 延遲接近 0 的原因不確定，可能是 DRAM 快取的差異，也可能是韌體在資料真正寫入前就回報完成（斷電時有遺失風險）。所以 UPS 很重要；日後換碟建議改成有 PLP 的企業級 NVMe，三台同型號。

### 10-2 VM／CT 分布：node11 最多

node10 4 台、**node11 7 台**、node12 4 台；沒加入 HA 的 104、108 和 CT 114（Grafana）都在 node11。做單節點故障演練時，如果關的是 node11，104／108 會一直停機到 node11 回來，Grafana 也會先跟著 HA 搬家。

## 11. 常見問題

| 現象 | 怎麼辦 |
| --- | --- |
| `ceph mgr services` 剛啟用時是 `{}` | 模組啟動要幾秒，再查一次 |
| 指令出現 `node12: No such file or directory` | 把 `<node12 IP>` 這種佔位字直接貼上了：bash 把 `<` 當成「從檔案讀取」。換成實際 IP |
| `pct: command not found` | 在容器裡執行了節點指令；`pct` 只存在 PVE 節點 |
| `pct enter 114` 顯示 `Configuration file … does not exist` | `pct` 只能操作**本節點**的容器；先 `ssh` 到 CT 114 所在的節點 |
| standby mgr 的 9283 回 `200 0 bytes` | 正常；只有 active mgr 有資料，Prometheus 仍視為 up |
| 面板 instance 每隔一陣子換掉、線條斷掉 | mgr 換手；查詢用 `max()`／`sum()`／`max by (ceph_daemon)` 合併 instance。**不要**把三個 target 的 instance 改寫成同一個值，Prometheus 會把它們當成重複 target 只留一個 |
| 新面板查不到資料 | 新增空白面板時 Data source 預設是 `Wazuh Alerts`，改成 prometheus |
| 右側只有 Suggestions、找不到設定欄 | 空白面板還沒選定類型；點一個建議圖（例如 Time series）或用 All visualizations |
| 圖例格式沒生效 | `{{ceph_daemon}}` 填到了中間的 Min step；Legend 在最左邊，Min step 要維持 `auto` |
| Duplicate 後數字變成 `HEALTH_OK` | 連 Value mappings 一起複製了；到 Edit value mappings 刪掉 |
| 表格沒有 `state` 欄 | 有些列有 state、有些沒有，Grafana 把結果拆成兩張表只顯示一張；用 `label_replace` 讓每一列都有 state（8-5）。先用 `curl …/api/v1/query --data-urlencode 'query=…'` 確認查詢本身正確 |
| 表格整列都變色 | 改到面板層級的 Cell type；改回 Auto，改用 Field override 只套用在「狀態」欄 |
| 表格的 Time 不是現在 | Instant 查詢的「現在」在開啟儀表板或按 Refresh 時固定；按 Refresh 更新。kiosk 要設自動更新 |
| VM／CT 遷移時 HA 異常數閃一下 | 遷移中 state 會短暫是 `migrate`／`relocate`，屬正常 |

## 12. 還原

```bash
# Grafana 容器（root@grafana）
systemctl disable --now pve-exporter prometheus
rm /etc/systemd/system/pve-exporter.service && systemctl daemon-reload
rm -rf /opt/pve-exporter /etc/prometheus/pve.yml /etc/prometheus/pve-root-ca.pem
userdel pve-exporter
apt purge prometheus          # 會一起刪除 /var/lib/prometheus 的資料

# 任一節點：Token 與帳號、Ceph 模組
pveum user token remove pve-exporter@pve prometheus
pveum user delete pve-exporter@pve
ceph mgr module disable prometheus

# 三台節點各自執行：移除 9283 規則
systemctl disable --now ceph-prometheus-fw
rm /etc/systemd/system/ceph-prometheus-fw.service /etc/ceph-prometheus-fw.nft && systemctl daemon-reload
```

最後在 Grafana 刪除 prometheus 資料來源和 `Ceph／PVE` 區塊。

## 13. 日後維運注意

- **exporter 不會跟著 apt 更新**：定期執行 `/opt/pve-exporter/bin/pip install --upgrade prometheus-pve-exporter && systemctl restart pve-exporter`。Prometheus 則跟著 `apt upgrade` 更新。
- **Token 2027-10-22 到期**：到期前用 6-1 的指令建新 Token，重做 6-3，再刪舊 Token。
- **PVE 叢集 CA 更換**（或改用自訂憑證）時，重新 `pct push` CA 到 `/etc/prometheus/pve-root-ca.pem` 並重啟 exporter。
- **node10 長時間停機**時，PVE 的面板會停在「監控資料來源：中斷」；可暫時把 `targets` 改成另一台節點 IP 後 `systemctl reload prometheus`。
- **新增節點**：新節點也要裝 `ceph-prometheus-fw`（4-1），並加進 `job_name: ceph` 的 targets。
- 磁碟：Prometheus 資料最多 8GB；`du -sh /var/lib/prometheus` 可查實際用量。

## 14. 待辦

| 項目 | 狀態 |
| --- | --- |
| 階段 3：Prometheus、Ceph 模組、PVE exporter、面板 | ✅ 2026-10-22 |
| PVE exporter Token 2027-10-22 到期前更換 | 長期追蹤（建議排行事曆 2027-10-08） |
| 第 5 階段 kiosk：儀表板設定自動更新（例如 1m） | ⏳ 待辦 |
| 查三款 NVMe 規格（PLP、DRAM），評估換成同型號企業級 NVMe | ⏳ 待評估（10-1） |
| DC01、DC02、CA 加入 LibreNMS 監控 | ✅ 2026-10-22，只用 Ping（UBClient、WinClient 不加入） |
| 叢集防火牆（pve-firewall）目前停用，8006、22 同網段全開 | ⏳ 另案評估 |
| Wazuh Critical 弱點 205（10/14）→ 296（10/22） | ⏳ 另案檢查 |
| 單節點故障演練（建議不要選 node11，或事先處理 104／108） | ⏳ 待辦 |

## 15. 延伸閱讀

- [Ceph：Prometheus module](https://docs.ceph.com/en/latest/mgr/prometheus/)
- [prometheus-pve-exporter](https://github.com/prometheus-pve/prometheus-pve-exporter)
- [Prometheus：Storage（retention 參數）](https://prometheus.io/docs/prometheus/latest/storage/)
- [Prometheus：Querying basics（PromQL）](https://prometheus.io/docs/prometheus/latest/querying/basics/)
- [PVE：User Management（API Token、權限分離）](https://pve.proxmox.com/wiki/User_Management)
- [nftables wiki：Scripting](https://wiki.nftables.org/wiki-nftables/index.php/Scripting)
- [Grafana：Prometheus data source](https://grafana.com/docs/grafana/latest/datasources/prometheus/)
- [用 Grafana 建立戰情中心（一）：接上 Wazuh](https://kbwangtw.github.io/IT-Knowledge-Base/docs/pve/grafana-war-room-wazuh/)
- [用 Grafana 建立戰情中心（二）：接上 LibreNMS](https://kbwangtw.github.io/IT-Knowledge-Base/docs/pve/grafana-war-room-librenms/)

{% endraw %}
