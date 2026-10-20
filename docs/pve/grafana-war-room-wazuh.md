---
layout: default
title: "用 Grafana 建立戰情中心（一）：接上 Wazuh"
date: 2026-10-14
categories: [PVE, Grafana, Wazuh]
permalink: /docs/pve/grafana-war-room-wazuh/
last_modified_at: 2026-10-17
---

# 用 Grafana 建立戰情中心（一）：接上 Wazuh

> **一句話**：各系統的狀態散在 Wazuh、LibreNMS、PVE、Graylog 四個地方，所以另建一台 Grafana 把資料拉到同一頁；第一階段先用**唯讀帳號**接上 Wazuh，做出 5 個面板的第一版戰情中心。

| 項目 | 內容 |
| --- | --- |
| 適合誰看 | 想用 Grafana 看 Wazuh 資料、又不想動到 Wazuh 本身的人 |
| 環境 | Grafana 13.2.3（OSS）、Ubuntu 24.04 LXC（CT 114）；Wazuh All-in-one 4.14.8（CT 112） |
| 日期 | 2026-10-13～14 |
| 結論 | ✅ Grafana 建立並納管；✅ 唯讀接上 Wazuh Indexer；✅ 第一版戰情中心 5 個面板驗收；⏳ 階段 3～5 未做 |

> 文中 IP 都是文件示範位址：Grafana 192.0.2.33、Wazuh 192.0.2.32。

## 1. 先認識幾個名詞

| 名詞 | 白話解釋 |
| --- | --- |
| **Grafana** | 把各種資料來源畫成圖表、數字的儀表板工具 |
| **Wazuh Indexer** | Wazuh 存放告警與狀態資料的資料庫（基於 OpenSearch） |
| **index** | Indexer 裡的「資料表」，例如 `wazuh-alerts-*` 存告警 |
| **Data source** | Grafana 裡設定「要去哪裡、用什麼帳號拿資料」 |
| **Panel（面板）** | 儀表板上的一格；Stat 面板只顯示一個大數字 |
| **socat** | 小工具，把某個埠收到的連線原封不動轉送到另一個位址 |
| **nftables** | Linux 防火牆，本案用來限制只有 Grafana 能連 |
| **Lucene query** | 搜尋語法，例如 `rule.level:>=12` |

## 2. 架構與分階段計畫

```text
                     ┌─ Wazuh Indexer   → 資安告警、Agent 狀態、弱點    （階段 1，本篇）
瀏覽器                │
  ↓ 唯讀帳號          ├─ LibreNMS        → 設備上下線、告警              （階段 2）
Grafana（CT 114）────┤
                     ├─ Prometheus      → Ceph 健康、節點負載、VM／HA    （階段 3）
                     └─ Graylog／PBS    → PVE 任務失敗、備份結果          （階段 4）
```

階段 5 再排版成專用電腦全螢幕顯示（kiosk）。

> 每接上一個來源，都要做到三件事：**唯讀帳號、來源端防火牆只允許 Grafana、從其他來源實測會被擋**。

| 項目 | 選擇 | 原因 |
| --- | --- | --- |
| 工具 | Grafana OSS | 可同時接多種資料來源；Wazuh Dashboard 只有 Wazuh 自己的資料 |
| 作業系統 | Ubuntu 24.04 LTS | 支援到 2029；Debian 13 的 apt 拒絕 SHA1 簽章（Graylog 升級時遇過），不確定 Grafana 套件庫能不能通過 |
| 使用者 | 自己每天看一眼 | 版面以明細與數字為主 |

## 3. 步驟一：建立 CT 114

**做什麼**：先確認編號、IP 沒被用，再參考現有容器（jt-ipam，CT 103）的網路設定。

```bash
pvesh get /cluster/resources --type vm --output-format json | python3 -c "import json,sys; r=[x for x in json.load(sys.stdin) if x['vmid']==114]; print('114 已被使用') if r else print('114 可用')"
ping -c 2 -W 1 192.0.2.33 >/dev/null && echo "已被使用！" || echo "沒有回應"   # 另對照 jt-ipam
pveam update >/dev/null && pveam available --section system | grep -i ubuntu-24.04
pct config 103 | grep -E '^(net0|nameserver|rootfs|unprivileged|features)'
```

**建立並啟動**：

```bash
pveam download local ubuntu-24.04-standard_24.04-2_amd64.tar.zst
pct create 114 local:vztmpl/ubuntu-24.04-standard_24.04-2_amd64.tar.zst \
  --hostname grafana --cores 2 --memory 2048 --swap 512 \
  --rootfs VM_Pool:30 \
  --net0 name=eth0,bridge=vmbr0,firewall=1,gw=192.0.2.1,ip=192.0.2.33/24,type=veth \
  --nameserver "192.0.2.21 192.0.2.20" \
  --unprivileged 1 --features nesting=1 --timezone host --onboot 1
pct start 114
```

| 參數 | 意思 |
| --- | --- |
| `--rootfs VM_Pool:30` | 30 GB 磁碟放在 Ceph；階段 3 的 Prometheus 也規劃放這台 |
| `--unprivileged 1` | 非特權容器，比較安全 |
| `--features nesting=1` | 讓容器內的 systemd 正常運作 |
| `--timezone host` | 時區跟主機一樣 |
| `--onboot 1` | 主機開機時自動啟動 |

- **不在指令中設 root 密碼**（會留在 shell 歷史）；用 `pct enter 114` 進入。
- 範本較舊，第一次 `apt full-upgrade` 有 193 個套件（109 個 LTS 安全更新），確認沒有移除任何套件後再繼續。

## 4. 步驟二：安裝 Grafana 並關閉回傳

**安裝**（在 CT 114 內，用 Grafana 官方套件庫，只用 stable）：

```bash
apt install -y gnupg wget
mkdir -p /etc/apt/keyrings
wget -q -O - https://apt.grafana.com/gpg.key | gpg --dearmor > /etc/apt/keyrings/grafana.gpg
echo "deb [signed-by=/etc/apt/keyrings/grafana.gpg] https://apt.grafana.com stable main" > /etc/apt/sources.list.d/grafana.list
apt update && apt install grafana
```

**關閉回傳**：Grafana 預設會把匿名使用統計送到 grafana.com 並定期檢查更新。為符合「資料不上雲端」，**啟動前**用環境變數關閉（不改 `grafana.ini`，升級時不會被覆蓋）：

```bash
cat >> /etc/default/grafana-server <<'EOF'
GF_ANALYTICS_REPORTING_ENABLED=false
GF_ANALYTICS_CHECK_FOR_UPDATES=false
GF_ANALYTICS_CHECK_FOR_PLUGIN_UPDATES=false
GF_ANALYTICS_FEEDBACK_LINKS_ENABLED=false
EOF
systemctl daemon-reload && systemctl enable --now grafana-server
curl -s http://127.0.0.1:3000/api/health                     # "database": "ok"
tr '\0' '\n' < /proc/$(pgrep -f 'grafana server' | head -1)/environ | grep ^GF_ANALYTICS   # 4 行都是 false
```

最後一行是直接讀「正在執行的 Grafana 程序」拿到的環境變數，確認設定真的生效。

**啟動後立刻**用瀏覽器登入 `http://192.0.2.33:3000`：

- 預設 admin／admin，同網段任何人都能登入；首次登入會要求改密碼（存進密碼管理器）。
- 首頁的「Latest from the blog」只是下載官網文章，不上傳資料；要完全不連外，可加 `GF_NEWS_NEWS_FEED_ENABLED=false`。

**加入 HA**（回到節點執行；先 `exit` 離開容器、確認提示字元後再貼）：

```bash
ha-manager add ct:114 --state started
ha-manager status | grep 114        # 先 queued，十幾秒後 started
```

## 5. 步驟三：讓 Grafana 連得到 Wazuh Indexer

**問題**：All-in-one 的 Indexer 只綁 `127.0.0.1:9200`（Dashboard 從本機連），Grafana 連不到。

| | 改 Indexer 綁定位址 | 加轉送服務（✅ 採用） |
| --- | --- | --- |
| 動到 Indexer | 要改 `opensearch.yml` 並重啟 | 不動 |
| 風險 | 綁到非本機位址會啟用 bootstrap checks，非特權 LXC 可能不通過，**Indexer 起不來、Wazuh 停擺** | 轉送服務掛掉只影響 Grafana |
| 升級 Wazuh | 設定可能被覆蓋 | 不受影響 |

### 5-1 先建防火牆

順序是**先擋、再開服務**。在 CT 112 內：

```bash
cp -a /etc/nftables.conf /etc/nftables.conf.bak-$(date +%Y%m%d-%H%M%S)
cat >> /etc/nftables.conf <<'EOF'

table inet wazuh_indexer {
    chain input {
        type filter hook input priority filter - 1; policy accept;
        tcp dport 9201 ip saddr 192.0.2.33 accept
        tcp dport 9201 drop
    }
}
EOF
nft -c -f /etc/nftables.conf && nft -f /etc/nftables.conf && nft list ruleset | grep -n 'table\|dport'
```

| 片段 | 意思 |
| --- | --- |
| `tcp dport 9201 ip saddr 192.0.2.33 accept` | 只有 Grafana 能連 9201 |
| `tcp dport 9201 drop` | 其他人連 9201 一律丟掉 |
| `nft -c -f` | 先**檢查語法**（`-c`），通過才真正套用 |

確認原有的 `wazuh_api`（55000）規則仍在。

### 5-2 再建轉送服務

socat 只轉送 TCP，TLS 由兩端直接加密：

```bash
apt install -y socat
cat > /etc/systemd/system/indexer-proxy.service <<'EOF'
[Unit]
Description=Forward Wazuh IP:9201 to local Wazuh Indexer 127.0.0.1:9200 (for Grafana)
After=network-online.target wazuh-indexer.service
Wants=network-online.target

[Service]
ExecStart=/usr/bin/socat TCP4-LISTEN:9201,bind=192.0.2.32,reuseaddr,fork TCP4:127.0.0.1:9200
Restart=always
RestartSec=5
User=nobody
NoNewPrivileges=yes

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload && systemctl enable --now indexer-proxy
ss -tlnp | grep -E ':920[01] '      # 127.0.0.1:9200（java）與 192.0.2.32:9201（socat）
```

`ExecStart` 那行的意思：在 192.0.2.32 的 9201 埠接連線，每條連線（`fork`）都轉到本機 9200。用 `nobody` 帳號執行，權限最低。

### 5-3 兩邊實測

在 Grafana 所在節點執行（當時是 node10）：

```bash
curl -sk -o /dev/null -w '%{http_code}\n' --max-time 5 https://192.0.2.32:9201/                    # 000：被擋
pct exec 114 -- curl -sk -o /dev/null -w '%{http_code}\n' --max-time 5 https://192.0.2.32:9201/     # 401：連得到、需要帳號
```

**應該看到**：從節點連是 `000`（防火牆擋掉），從 Grafana 容器連是 `401`（連得到，只是還沒給帳號）。

## 6. 步驟四：建立 Indexer 唯讀帳號

**做什麼**：替 Grafana 建一個只能讀三類 index 的帳號。

All-in-one 安裝時產生的管理員憑證（`admin.pem`）可以直接呼叫安全設定 API，**不需要 admin 密碼**。腳本存成 CT 112 的 `/root/grafana-indexer-user.sh`（權限 700）：

```bash
#!/bin/bash
set -e
C=/etc/wazuh-indexer/certs
U=https://127.0.0.1:9200/_plugins/_security/api
A=(-sk --fail-with-body --cert $C/admin.pem --key $C/admin-key.pem -H 'Content-Type: application/json')
PW=$(python3 -c "import secrets,string;a=string.ascii_letters+string.digits;print(''.join(secrets.choice(a) for _ in range(24))+'-Aa9')")
curl "${A[@]}" -X PUT $U/roles/grafana_wazuh_read -d '{"cluster_permissions":["cluster_composite_ops_ro","cluster:monitor/main"],"index_permissions":[{"index_patterns":["wazuh-alerts-*","wazuh-monitoring-*","wazuh-states-vulnerabilities-*"],"allowed_actions":["read","indices:admin/mappings/get"]}]}'; echo
curl "${A[@]}" -X PUT $U/internalusers/grafana -d "{\"password\":\"$PW\"}"; echo
curl "${A[@]}" -X PUT $U/rolesmapping/grafana_wazuh_read -d '{"users":["grafana"]}'; echo
sleep 2
curl -sk -u "grafana:$PW" "https://127.0.0.1:9200/wazuh-alerts-*/_count"; echo                                   # 筆數
curl -sk -o /dev/null -w '%{http_code}\n' -u "grafana:$PW" "$U/internalusers"                                    # 403
curl -sk -o /dev/null -w '%{http_code}\n' -u "grafana:$PW" "https://127.0.0.1:9200/.opendistro_security/_search" # 403
echo "Grafana password (shown once): $PW"
unset PW
```

**這段在做什麼**：

1. `PW=…`：用 Python 的 `secrets` 產生 24 碼隨機密碼，結尾固定加 `-Aa9` 滿足複雜度規則。
2. 三個 `PUT`：建角色 → 建帳號 → 把帳號綁到角色。
3. 最後三行測試：能數告警筆數（讀得到）、看帳號清單和安全設定都是 `403`（看不到不該看的）。
4. 密碼只顯示一次，之後 `unset` 清掉變數。

| 權限 | 用途 |
| --- | --- |
| 三類 index 的 `read` | 告警、Agent 狀態快照、目前存在的弱點；不能寫入或刪除，也看不到其他 index |
| `indices:admin/mappings/get` | 讓查詢編輯器列出欄位 |
| `cluster_composite_ops_ro` | 多筆查詢（msearch）等唯讀操作 |
| `cluster:monitor/main` | 讀取根目錄 `/` 的名稱與版本；Grafana 的 Get Version 需要，只看得到版本號 |

> 密碼存進密碼管理器，截圖時遮住。

## 7. 步驟五：在 Grafana 建立資料來源

先在 **Connections → Add new connection** 安裝 OpenSearch plugin（從 grafana.com 下載，不上傳資料）。三個資料來源的連線設定相同：

| 欄位 | 設定 |
| --- | --- |
| URL | `https://192.0.2.32:9201` |
| Basic auth | **開啟**，User `grafana` |
| Skip TLS Verify | 開啟（Indexer 是自簽憑證，而且憑證寫的是 127.0.0.1；連線仍有加密） |
| PPL enabled | 關閉（唯讀角色沒開放 PPL） |
| Logs → Level field name | **留空** |
| Version | 按 Get Version and Save，顯示 `OpenSearch (compatibility mode)` |

| 名稱 | Index name | Time field |
| --- | --- | --- |
| Wazuh Alerts | `wazuh-alerts-*` | `timestamp` |
| Wazuh Agents | `wazuh-monitoring-*` | `timestamp` |
| Wazuh Vulnerabilities | `wazuh-states-vulnerabilities-*` | `vulnerability.detected_at` |

- 弱點 index 的日期欄位是用管理員憑證查 mapping 確認的（另有 `package.installed`、`vulnerability.published_at`）。
- Wazuh Alerts 的 Logs → Message field name 可以填 `full_log`。

> ⚠️ **Level field name 不要填 `rule.level`**：Grafana 會把數字當成 syslog 嚴重等級翻譯（3→ERROR、7→DEBUG）。但 Wazuh 是數字越大越嚴重，syslog 剛好相反，低等級的 AppArmor 告警會被標成 ERROR，造成誤判。

## 8. 步驟六：第一版戰情中心

儀表板「戰情中心」，時間範圍 Last 24 hours。數字面板用 Stat；從查詢正常的面板 **Duplicate** 再修改最省事。

| 面板 | 資料來源 | 查詢 | 重點設定 | 顏色 |
| --- | --- | --- | --- | --- |
| 24 小時告警數 | Wazuh Alerts | 空白；Count；Date Histogram 10m | Calculation **Total**；Graph mode Area | 綠；≥10000 橘 |
| 高風險告警（≥12） | Wazuh Alerts | `rule.level:>=12` | Total；Graph mode None | 綠；≥1 紅 |
| 斷線 Agent | Wazuh Agents | `status:disconnected`；**Unique Count `id`**；Interval 15m、**Min Doc Count 1** | Calculation **Last \***；No value `0` | 綠；≥1 紅 |
| Critical 弱點 | Wazuh Vulnerabilities | `vulnerability.severity:Critical`；Count；Date Histogram auto | **Query options → Relative time `10y`**；Total | 綠；≥1 橘；≥300 紅 |
| 告警趨勢（10 分鐘） | Wazuh Alerts | 空白；Count；Date Histogram 10m | Time series | — |

**設計重點**：

- **Calculation**：查詢回來是「每個時段一個數字」，Stat 只能顯示一個值。總量用 Total；「現在幾台斷線」用 Last \*（最新一次快照，星號代表略過空值）。
- **斷線 Agent**：monitoring 每 15 分鐘替每台 Agent 寫一筆快照，用 Count 會重複計算，所以改用不重複的 `id`。Min Doc Count 1 避免最後一段還沒寫入時誤顯示 0。
- **No data 不一定代表正常**：24 小時沒有斷線時查不到資料是正常的；但 index 沒資料或欄位名稱打錯也會是 No data，面板就**永遠不會變紅**。設定 No value 0 之前，先在 Explore 驗證：Wazuh Agents 查空白條件、Unique Count `id` 應約 18（17 Agent + Manager）；`status:active` 也約 18。
- **Critical 弱點**：弱點 index 存的是「目前仍存在」的弱點；套用儀表板的 24 小時只會算到最近新偵測到的，所以這個面板單獨看 10 年。

**驗收**（2026-10-14）：

| 面板 | 顯示 | 對照 |
| --- | --- | --- |
| 24 小時告警數 | 3,981～4,350（綠） | 與 [Wazuh 維運篇](https://kbwangtw.github.io/IT-Knowledge-Base/docs/pve/wazuh-lxc-ubuntu2204-operations/) §10-5 的每日 1,300～5,300 筆一致 |
| 高風險告警 | 0（綠） | Explore 查 24 小時為 0 |
| 斷線 Agent | 0（綠） | Explore 驗證 `id`、`status` 欄位 |
| Critical 弱點 | 205（橘） | 命令列 `_count?q=vulnerability.severity:Critical` 為 205（10/06 修補後 292） |

查詢時觀察到：ubclient 的 rootcheck 掃描會在幾秒內產生大量事件（趨勢圖尖峰）；node10 持續出現低等級的 AppArmor DENIED，列入下一輪告警調校。

## 9. CT 114 納管（2026-10-14）

新主機比照其他容器納入既有管理。CT 114、LibreNMS（CT 102）和 SNMP 腳本都在 node10；`pct exec` 只能操作**所在節點**上的容器，執行前先看提示字元。

| 項目 | 做法 | 結果 |
| --- | --- | --- |
| DNS | AdGuard 和 Pi-hole 兩台都加 `grafana` | 兩台都解析到 .33；LibreNMS 容器 `getent hosts` 解析得到 |
| Wazuh Agent | [Wazuh 安裝篇](https://kbwangtw.github.io/IT-Knowledge-Base/docs/pve/wazuh-lxc-ubuntu2204-sop/) §9-6：節點下載 .deb → `pct push` → `env WAZUH_MANAGER=... dpkg -i` → 確認 `<address>` 後才啟動 | Manager 顯示 `grafana`、Active |
| LibreNMS | `/root/snmp-v3-add.sh 114 Node10`（`snmpd=active usmUser=1 createUser=0 udp161=1`）→ `/root/snmp-v3-lnms.sh grafana.<網域>` → `lnms device:poll` | v3／authPriv／SHA／AES |
| PBS 備份 | `pvesh get /cluster/backup`：三台各有 `all: 1`、無排除的備份工作（21:00／21:30／22:00） | 不需調整，HA 搬到哪台都會被備份 |
| HA | `ha-manager add ct:114` | started |
| jt-ipam | LibreNMS 的「Auto-create discovered IPs」預設開啟，同步時以設備主要 IP 建立紀錄；Wazuh 只比對不建立 | IP 清單出現 .33（grafana）；`wazuh_agents` 同步到 Agent 018（ip .33、active），並對應到 .33 的 IP 紀錄（`jt_ipam_address_id`），共 18 筆 |

> `lnms` 指令要用 `su - librenms -s /bin/bash -c "cd /opt/librenms && ./lnms ..."` 執行。少了 `-` 和 `cd`，工作目錄會停在 `/root`，fping 因權限不足失敗（`posix_spawn() failed: Permission denied`）。

**cluster-check.sh 計數修正**：Wazuh 那一行用 `grep -c Active` 計算，Manager 自己的 `Active/Local` 也會算進去，原本說明 `expect 17` 少算了 Manager。加入 grafana 後改成 `expect 19 = 18 agents + manager`（先備份，再用 `sed` 只改說明文字）。

實測：`active=19`；同次檢查 Ceph HEALTH_OK、97 PG active+clean、三台 kernel `7.0.14-23-pve`、HA 全部 started、DNS／DC 分處不同節點、LibreNMS 沒有斷線設備。

## 10. 常見問題

| 現象 | 原因／處理 |
| --- | --- |
| Get Version 顯示 `Failed to connect to server` | 從 Grafana 容器用 curl 測，`GET /` 回 403 `no permissions for [cluster:monitor/main]`；角色補上這個權限 |
| 資料來源 `"Unauthorized" is not valid JSON` | Basic auth 開關沒開，沒送出帳密（401）；開啟後填 User／Password |
| 新面板 `invalid query, missing metrics and aggregations` | 新增空白面板不會自動帶入 Count 與 Date Histogram；改從正常面板 Duplicate |
| 改了 Lucene query 數字沒變 | 輸入後要點欄位外讓查詢生效，再 Refresh |
| Interval 改了沒效果 | `10m` 誤填到 Min Doc Count（只能填數字）；Interval 在展開後的下拉選單 |
| `pct enter` 後連同 `exit` 和節點指令一起貼上，指令沒執行 | 容器 shell 關閉時後續輸入會被丟掉；先 `exit`、確認提示字元再貼 |

## 11. 想撤掉 Grafana 的存取時（還原）

在 CT 112 內移除 Grafana 的存取，Wazuh 本身不受影響：

```bash
systemctl disable --now indexer-proxy && rm /etc/systemd/system/indexer-proxy.service && systemctl daemon-reload
cp -a $(ls -t /etc/nftables.conf.bak-* | head -1) /etc/nftables.conf && nft -f /etc/nftables.conf
C=/etc/wazuh-indexer/certs; A=(-sk --cert $C/admin.pem --key $C/admin-key.pem -X DELETE)
curl "${A[@]}" https://127.0.0.1:9200/_plugins/_security/api/rolesmapping/grafana_wazuh_read
curl "${A[@]}" https://127.0.0.1:9200/_plugins/_security/api/internalusers/grafana
curl "${A[@]}" https://127.0.0.1:9200/_plugins/_security/api/roles/grafana_wazuh_read
```

nftables 備份要選**建立 `wazuh_indexer` 之前**的那一份；如果之後又改過 nftables，改成手動刪除 `table inet wazuh_indexer` 區塊。

## 12. 日後維運注意

- **Wazuh 升級後**檢查：`indexer-proxy` 是 active、9201 仍只允許 Grafana、`grafana` 帳號能登入，以及原有的 `api.yaml` host 與 55000 規則（見 [Wazuh 維運篇](https://kbwangtw.github.io/IT-Knowledge-Base/docs/pve/wazuh-lxc-ubuntu2204-operations/) §13）。
- 如果用 `wazuh-passwords-tool` 重設 Indexer 密碼，工具可能用設定檔覆蓋目前的帳號清單，`grafana` 帳號可能消失（未實測）；重新執行 `/root/grafana-indexer-user.sh` 補回，並更新 Grafana 三個資料來源的密碼。
- Skip TLS Verify：只有 Grafana 能連 9201、帳號唯讀，風險有限；待改善為匯入 Wazuh CA（同 jt-ipam）。
- 資料來源顯示 compatibility mode：Wazuh Indexer 對外回報相容版本，目前查詢正常；日後出現查詢錯誤再回頭檢查。

## 13. 待辦

| 項目 | 狀態 |
| --- | --- |
| CT 114 納管：DNS、jt-ipam、Wazuh Agent、LibreNMS（SNMPv3）、PBS 備份 | ✅ 完成（第 9 節） |
| 階段 2：LibreNMS | ✅ 完成（改用 API 唯讀 Token），見[戰情中心（二）](https://kbwangtw.github.io/IT-Knowledge-Base/docs/pve/grafana-war-room-librenms/) |
| 階段 3：Prometheus、Ceph prometheus 模組、PVE exporter | ⏳ 未做 |
| 階段 4：Graylog／PBS（Graylog 的 OpenSearch 可能沒有帳號保護，要另外評估） | ⏳ 未做 |
| 階段 5：專用電腦 kiosk（`?kiosk`、開機自動開啟、Viewer 帳號、不休眠） | ⏳ 未做 |
| node10 AppArmor DENIED 告警調校 | ✅ 2026-10-20：來源就是 Grafana 容器（CT 114，Ubuntu 24.04）的 rsyslogd 規則，停用後歸零，容器 syslog 也恢復寫入（Wazuh 維運篇 11-2） |

## 14. 延伸閱讀

- [用 Grafana 建立戰情中心（二）：接上 LibreNMS](https://kbwangtw.github.io/IT-Knowledge-Base/docs/pve/grafana-war-room-librenms/)
- [Grafana：Install on Debian or Ubuntu](https://grafana.com/docs/grafana/latest/setup-grafana/installation/debian/)
- [Grafana：Configure with environment variables](https://grafana.com/docs/grafana/latest/setup-grafana/configure-grafana/#override-configuration-with-environment-variables)
- [Grafana OpenSearch data source](https://grafana.com/grafana/plugins/grafana-opensearch-datasource/)
- [OpenSearch：Security REST API](https://docs.opensearch.org/latest/security/access-control/api/)
- [OpenSearch：Default action groups](https://docs.opensearch.org/latest/security/access-control/default-action-groups/)
