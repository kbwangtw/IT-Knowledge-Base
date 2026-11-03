---
layout: default
title: "啟用 PVE 防火牆（階段 1a）：只收緊 Ceph 與沒用的埠"
date: 2026-11-02
categories: [PVE, Security, Firewall, Ceph]
permalink: /docs/pve/pve-firewall-stage1a-ceph-hardening/
last_modified_at: 2026-11-03
---

# 啟用 PVE 防火牆（階段 1a）：只收緊 Ceph 與沒用的埠

> **一句話**：想擋「VM／CT 被入侵後去打節點」，第一步先在叢集啟用 PVE 防火牆，只把 Ceph 收緊到「只有三台節點能連」、把沒人用的埠擋掉，管理用的 8006／22／3128 暫時對整個服務網開放；人不在現場、沒有主控台也做完了，靠的是「排好自動保險」，三台備份與叢集都正常。

| 項目 | 內容 |
| --- | --- |
| 適合誰看 | 想啟用 PVE 防火牆、又怕鎖死自己或擋到 Ceph 與 Corosync 的人 |
| 環境 | PVE 9.2 三節點（node10／11／12）、Ceph（97 個 PG）、PBS31、兩台無網管交換器；管理員只有一位 |
| 日期 | 2026-11-02（叢集層啟用 12:34～12:36、node11 主機層）；2026-11-03（node10 主機層） |
| 風險 | 中：設錯會擋到 Ceph 或管理連線；本篇做法是**先排自動保險、一次一台、做完才取消保險** |
| 結論 | ✅ 階段 1a 完成：Ceph 只放行三台節點、沒人用的埠被擋、三台備份與叢集正常 ⏳ 階段 1b（縮小管理來源）、階段 2、3（Guest 層）尚未開始 |

> 文中 IP 是示範位址：服務網 192.0.2.x、叢集網 198.51.100.x，最後一個數字和真實環境對得上，但網段不是真的。管理員電腦的位址不寫。

## 1. 先認識幾個名詞

| 名詞 | 白話解釋 |
| --- | --- |
| **PVE Firewall** | PVE 內建的防火牆，分三層：叢集層（整個叢集的共用規則）、主機層（每台節點自己的）、Guest 層（每個 VM／CT 自己的） |
| **`cluster.fw`** | 叢集層設定檔 `/etc/pve/firewall/cluster.fw`，有 `[OPTIONS]`（總開關、預設政策）、`[IPSET]`（位址清單）、`[RULES]`（規則） |
| **`host.fw`** | 每台節點的主機層設定檔，在 `/etc/pve/nodes/<節點名>/host.fw`（不在 `/etc/pve/firewall/`） |
| **`policy_in`／`policy_out`** | 沒有任何規則符合時的預設：進站 `DROP`（丟棄）、出站 `ACCEPT`（放行） |
| **IPSet** | 一組位址的名字，規則裡寫 `+名字` 就代表這組位址；這裡的 `pve_nodes` 是三台節點的 6 個位址（服務網、叢集網各三個） |
| **橫向移動** | 一台機器被入侵後，從內網去打其他機器 |
| **保險計時器** | 用 `systemd-run` 排一個「N 分鐘後執行 `pve-firewall stop`」的定時任務；規則寫錯、人被鎖在外面時，時間到防火牆自動停止 |
| **`simulate`** | `pve-firewall simulate`：用來問「某個來源連某個埠，會被放行還是丟棄」的預覽指令 |

## 2. 目標與範圍

目標：擋「VM／CT 被入侵後的橫向移動」。分四個階段，這篇只做第一階段的前半：

| 階段 | 內容 | 狀態 |
| --- | --- | --- |
| **1a（本篇）** | 叢集啟用防火牆；Ceph 只放行三台節點；9283 只放 Grafana；UDP 161 只放 LibreNMS；沒人用的埠（例如 rpcbind 111）被預設政策擋掉；**8006／22／3128／ICMP 暫時對整個服務網 /24 開放** | ✅ 完成 |
| 1b | 管理員電腦固定 IP 後，縮小 8006／22／3128 的來源 | ⏳ 未開始（管理員電腦目前是 DHCP，要先固定 IP） |
| 2 | 高價值 Guest（DC01、DC02 等）的 Guest 層規則 | ⏳ 未開始 |
| 3 | 其他 Guest | ⏳ 未開始 |

**為什麼 8006／22／3128 先全開**：管理員電腦位址是 DHCP 動態的，現在縮小會把自己擋在外面。代價是「被入侵的 Guest 連節點管理介面」這條路徑**還沒擋**，要等階段 1b。

## 3. 全貌

```text
          Ceph（MON 3300／6789、OSD／MDS／MGR 6800～7300）
  VM／CT ───────────────────────────────▶ 節點  ✘ 擋（只放行 pve_nodes）
  VM／CT ───── 8006／22／3128／ICMP ─────▶ 節點  ✔ 暫時放行整個服務網 /24
  Grafana ───── 9283 ────────────────────▶ 節點  ✔ 只放 Grafana
  LibreNMS ──── UDP 161 ─────────────────▶ 節點  ✔ 只放 LibreNMS
  任何來源 ───── 111（rpcbind）等沒人用的埠 ▶ 節點  ✘ 預設政策 DROP
  節點 ↔ 節點 ── Corosync、Ceph、SSH、8006 ─  ✔ 放行（IPSet pve_nodes）
```

## 4. 啟用前先對照官方文件

文件：[Proxmox VE Firewall](https://pve.proxmox.com/pve-docs/chapter-pve-firewall.html)（2026-11-02 查）

| 項目 | 文件寫的 |
| --- | --- |
| `enable` 預設值 | 叢集層 0、主機層 1、VM／CT 層 0 |
| `policy_in`／`policy_out` 預設 | 文件**沒寫** |
| 啟用後自動放行 | 管理主機到 8006、22、3128、5900-5999、60000-60050；叢集網的 Corosync UDP 5405-5412 |
| Ceph | 這一頁**沒有提**；PVE 的 Ceph 文件說要開 Ceph 埠、推薦用防火牆巨集（名稱沒寫） |
| 救援 | `pve-firewall stop`（iptables 版）或 `systemctl stop proxmox-firewall`（nftables 版） |

幾個**文件沒說、要靠實測**的地方，後面的章節會逐一驗證：

- 定義了 `management` 這個 IPSet 之後，`local_network` 還放不放行？→ 我刻意**不用** `management` 這個名字，怕把自己鎖在外面。
- VM 層 `enable` 為 0、但網卡的防火牆旗標已開時，Guest 會不會被過濾？
- 節點的 `host.fw` 寫 `enable: 0` 到底會怎樣？

## 5. 設定內容

### 5-1 `cluster.fw` 的 `[OPTIONS]` 與 IPSet

| 項目 | 設定 |
| --- | --- |
| `enable` | 1（原本 0） |
| `ebtables` | 0（不變） |
| `policy_in` | `DROP` |
| `policy_out` | `ACCEPT` |
| IPSet `pve_nodes` | 三台節點的服務網位址（192.0.2.10／11／12）與叢集網位址（198.51.100.10／11／12），共 6 個 |

原始檔先備份：`/root/cluster.fw.bak-20261102`（只有 `enable: 0` 與 `ebtables: 0`，34 位元組）。

### 5-2 規則（白話整理，不是檔案逐字）

| # | 方向 | 動作 | 協定／埠 | 來源 | 用途 |
| --- | --- | --- | --- | --- | --- |
| 1～4 | 進站 | 放行 | TCP 8006、TCP 22、TCP 3128、ICMP | 服務網 192.0.2.0/24 | **暫時全開**，階段 1b 才縮小 |
| 5 | 進站 | 放行 | ICMP | `+pve_nodes` | 節點互 ping |
| 6 | 進站 | 放行 | TCP 5900:5999 | `+pve_nodes` | VM 主控台（VNC） |
| 7 | 進站 | 放行 | TCP 60000:60050 | `+pve_nodes` | 線上遷移 |
| 8 | 進站 | 放行 | TCP 3300 | `+pve_nodes` | Ceph MON（msgr2） |
| 9 | 進站 | 放行 | TCP 6789 | `+pve_nodes` | Ceph MON（msgr1） |
| 10 | 進站 | 放行 | TCP 6800:7300 | `+pve_nodes` | Ceph OSD／MDS／MGR |
| 11 | 進站 | 放行 | TCP 9283 | Grafana（192.0.2.33） | Ceph mgr 的 Prometheus 指標 |
| 12 | 進站 | 放行 | UDP 161 | LibreNMS（192.0.2.22） | SNMP 監控 |
| 13（後補） | 進站 | 放行 | TCP 22、8006、3128 | `+pve_nodes` | 叢集網上的 SSH／API／spiceproxy，見第 8 節 |

沒列的埠（例如 rpcbind 的 111）不在任何放行規則裡，被 `policy_in: DROP` 擋掉。

## 6. 步驟

### 6-1 先寫規則，總開關保持關閉（`enable: 0`）

**做什麼**：把 IPSet 與規則寫進 `cluster.fw`，但總開關還是關的，所以**不會有任何影響**。

**怎麼做**：用編輯器或 PVE 網頁（資料中心 → 防火牆）建立 IPSet 與規則，儲存。

**驗證規則有被 PVE 讀懂**（唯讀）：

```bash
pvesh get /cluster/firewall/rules --output-format json-pretty | grep -c '"action"'
pvesh get /cluster/firewall/ipset/pve_nodes
```

**應該看到**：規則數是 12（後來補一條變 13）、IPSet 有 6 個位址。

### 6-2 先測保險本身是否有效

**做什麼**：保險計時器是遠端操作唯一的救援，要先確認它真的會動，再依賴它。

```bash
systemd-run --on-active=1min --unit=fw-test /usr/bin/logger fw-safety-test
systemctl list-timers fw-test.timer
journalctl -u fw-test --since "3 minutes ago"
```

| 測試 | 做法 | 結果 |
| --- | --- | --- |
| 測試 1 | 排 1 分鐘後 `logger` 一行字 | 三台都準時觸發 |
| 測試 2 | 排 1 分鐘後執行 `pve-firewall stop`（防火牆還是關的） | node12 的 `pve-firewall status` 變成 `disabled/stopped`；再用 `systemctl start pve-firewall` 回到 `disabled/running` |

> 排好計時器**立刻**查，會看到 `No entries`，那只是時間還沒到，不是失敗；用 `systemctl list-timers` 看 `LEFT` 欄位。

### 6-3 排保險，再打開總開關

**做什麼**：在三台各排一個「10 分鐘後停止防火牆」的保險，然後把 `enable` 從 0 改成 1。

```bash
systemd-run --on-active=10min --unit=fw-safety /usr/sbin/pve-firewall stop
```

**排保險要三台各貼一次**（每台自己的 terminal，或用 `ssh root@node11 '…'`）；**改總開關只在 node10 貼一次**（`/etc/pve` 是叢集共用，改一次三台都會套用）。

```bash
grep -c '^enable: 0' /etc/pve/firewall/cluster.fw && sed -i 's/^enable: 0/enable: 1/' /etc/pve/firewall/cluster.fw
```

| 片段 | 意思 |
| --- | --- |
| `systemd-run --on-active=10min --unit=fw-safety` | 10 分鐘後執行指定指令；取名 `fw-safety`，之後可以取消 |
| `grep -c '^enable: 0' … && sed -i …` | **只有**找到 `enable: 0` 才改；找不到就不動，避免改錯 |

**應該看到**：`Running timer as unit: fw-safety.timer`；改檔沒有輸出。

### 6-4 驗證（保險倒數中）

```bash
sleep 15
pve-firewall status
iptables -S INPUT | head -3
pvecm status | grep -E 'Quorate|Nodes:'
ceph -s | grep -E 'health|pgs'
ha-manager status | head -20
```

| 檢查 | 預期 | 11/02 實測 |
| --- | --- | --- |
| `pve-firewall status` | `enabled/running` | 三台都是 |
| `iptables -S INPUT` | 跳到 `PVEFW-INPUT` | 三台都是（`PVEFW` 規則數：node10 80、node11 80、node12 127） |
| `pvecm status` | `Quorate: Yes`、兩條 Corosync link 都 connected | ✅ |
| `ceph -s` | `HEALTH_OK`、97 個 PG `active+clean` | ✅ |
| `ha-manager status` | 13 個服務 `started` | ✅ |

**預覽規則**（防火牆啟用之後才能用）：

```bash
pve-firewall simulate --from outside --source 192.0.2.99 --dest 192.0.2.12 --dport 8006
```

| 模擬（在 node12，`--from outside`） | 結果 |
| --- | --- |
| 服務網一般位址 → 8006 | `ACCEPT` |
| 服務網一般位址 → 3300（Ceph MON） | `DROP` |
| 節點 → 3300 | `ACCEPT`（後來補規則 13 之後，這類節點對節點的模擬會出錯，見第 10 節） |
| 服務網一般位址 → 111（rpcbind） | `DROP` |
| Grafana → 9283 | `ACCEPT` |
| LibreNMS → UDP 161 | `ACCEPT` |

**手動確認**：管理員電腦連節點的網頁、手機開 VPN 連內網、DNS（兩台）、AD、ProxCenter、Grafana、LibreNMS、Wazuh、Graylog、VPN 都正常。

**14 個「網卡防火牆旗標已開」的 Guest 沒有被誤擋**：VM104、106、107、108、111；CT100、101、102、103、105、110、112、113、114（只有 CT109 WireGuard 沒有旗標）。DNS、AD、各服務網頁都正常。**推測** VM 層 `enable` 為 0 時不過濾（文件沒寫；目前沒有任何 `<VMID>.fw`）。

**全部正常才取消保險**：

```bash
systemctl stop fw-safety.timer
systemctl list-timers fw-safety.timer
```

**應該看到**：`0 timers listed`。11/02 在 12:36:41 三台都取消成功。

## 7. 主機層 `host.fw`：逐台啟用

### 7-1 發生什麼事

三台原本都有 `host.fw`，內容只有 `enable: 1`。啟用叢集層之前，node10、node11 的 `host.fw` 被改成了 `enable: 0`（打算「先只套用 node12」）。啟用之後的實測：

| 項目 | 結果 |
| --- | --- |
| 三台 `pve-firewall status` | 都是 `enabled/running`，INPUT 都跳進 `PVEFW-INPUT`：`host.fw` 的 `enable: 0` **沒有把防火牆整個排除** |
| Ceph MON（3300）對外模擬 | node10、node11 是 `ACCEPT`、node12 是 `DROP` |

結論：**`host.fw` 的 `enable: 0` 只讓該節點的「主機層規則」不套用，叢集層規則照樣生效**。也就是 Ceph 的收緊只有 node12 有效。`PVEFW` 規則數 80／80／127 也一致（node12 多出主機層規則，推測）。

### 7-2 啟用 node11（11/02）與 node10（11/03）

做之前先確認沒有非節點的 Ceph 用戶端（唯讀）：

```bash
ssh root@node10 "ss -tnH state established '( sport = :3300 or sport = :6789 or ( sport >= :6800 and sport <= :7300 ) )' | awk '{print \$4}' | sed 's/:[0-9]*\$//' | sort | uniq -c"
```

**應該看到**：來源位址只有三台節點的 6 個位址；三台各看一次，11/03 的結果都是這樣（只是一個時間點的快照）。

每台依序做：

```bash
ssh root@node11 'systemd-run --on-active=10min --unit=fw-safety /usr/sbin/pve-firewall stop'
pvesh set /nodes/node11/firewall/options --enable 1
```

之後驗證（node10 換成對應名稱與位址）：

```bash
sleep 20
ssh root@node11 'pve-firewall simulate --from outside --source 192.0.2.99 --dest 192.0.2.11 --dport 3300 | tail -1'
ssh root@node11 hostname
ssh root@198.51.100.11 hostname
curl -sk -o /dev/null -w '%{http_code}\n' --max-time 5 https://198.51.100.11:8006/
pvecm status | grep -E 'Quorate|Nodes:'
ceph -s | grep -E 'health|pgs|mon:|osd:'
ssh root@node11 'systemctl list-timers fw-safety.timer'
```

| 預期 | 說明 |
| --- | --- |
| `DROP` | 外部連 3300 被擋 |
| `node11`、`node11` | 服務網與叢集網的 SSH 都通 |
| `200` | 叢集網的 8006 通 |
| `Quorate: Yes`、`Nodes: 3` | 叢集正常 |
| `HEALTH_OK`、97 `active+clean`、MON 3 個 quorum 且 `age` 沒歸零、OSD 3 up 3 in | **MON 與 OSD 的存活時間沒有重置**，代表節點間的 Ceph 流量沒受影響 |

手動確認 Web UI、VPN、DNS、AD 後，才取消保險：

```bash
ssh root@node11 'systemctl stop fw-safety.timer; systemctl list-timers fw-safety.timer'
```

> 我用 `pvesh set` 改 `host.fw`，不用 `>` 寫檔（原因見第 10 節 `dateprintf` 事件）。

## 8. 補一條叢集網放行規則

### 8-1 發現問題

啟用後在 node10 測叢集網的 SSH：

```bash
ssh -o ConnectTimeout=5 root@198.51.100.11 hostname
ssh -o ConnectTimeout=5 root@198.51.100.12 hostname
```

| 目標 | 結果 |
| --- | --- |
| node11（主機層規則當時**沒**套用） | 成功 |
| node12（主機層規則已套用） | **逾時** |

官方說「管理主機自動放行」，實際涵蓋的是**節點本機的網段（服務網）**，叢集網的 22、8006 不在內。我寫的 22／8006／3128 規則也只放了服務網，所以 node12 擋掉了叢集網上的連線。PVE 內部可能走叢集網位址的功能（遷移、跨節點的 Shell、API 代理）有風險，所以要補。

### 8-2 補規則

```bash
pvesh create /cluster/firewall/rules --type in --action ACCEPT --proto tcp --dport 22,8006,3128 --source +pve_nodes --enable 1 --comment 'nodes mgmt over cluster net'
```

| 片段 | 意思 |
| --- | --- |
| `pvesh create /cluster/firewall/rules` | 在叢集層新增規則，PVE 會先檢查語法 |
| `--type in --action ACCEPT` | 進站、放行 |
| `--proto tcp --dport 22,8006,3128` | SSH、Web UI／API、spiceproxy |
| `--source +pve_nodes` | 只放行三台節點的 6 個位址 |

**驗證**（過約 10 秒才套用）：

```bash
sleep 15
ssh -o ConnectTimeout=5 root@198.51.100.12 hostname
curl -sk -o /dev/null -w '%{http_code}\n' --max-time 5 https://198.51.100.12:8006/
pvesh get /cluster/firewall/rules --output-format json-pretty | grep -c '"action"'
```

**應該看到**：`node12`、`200`、規則數 13。再從 node10 的網頁開 node12 的「摘要」與「Shell」，確認節點間的 API 代理也通。

## 9. 備份與完整驗證

| 備份 | node10 | node11 | node12 |
| --- | --- | --- | --- |
| 11/02 14:00～14:22 手動全量（防火牆啟用後） | 14:01:52～14:06:58 `OK`（4 個 Guest） | 14:07:19～14:17:14 `WARNINGS: 2`（7 個 Guest） | 14:19:07～14:22:41 `OK`（4 個 Guest） |
| 11/02 晚上排程（開始時間） | 21:00 `OK` | 21:30 `OK` | 22:00 `OK` |

- node11 的 `WARNINGS: 2` 是 VM 108 關機時備份的已知警告（細節見 [Ceph 慢操作那篇](https://kbwangtw.github.io/IT-Knowledge-Base/docs/pve/ceph-bluestore-slow-op-backup-schedule/) 第 12 節），與防火牆無關；11/02 晚上 VM 108 開機中，所以 `OK`。
- 備份是節點主動連 PBS31 的 8007 埠（出站），`policy_out: ACCEPT`，所以不受影響；增量備份都重用 67%～100% 的舊資料，代表 PBS31 讀得到前一次的備份。
- 三台依序備份，沒有同時衝擊 Ceph；備份後 `ceph -s` 仍是 `HEALTH_OK`、97 個 PG `active+clean`。

## 10. 常見問題（踩過的雷）

| 現象 | 怎麼辦 |
| --- | --- |
| `pve-firewall compile` 輸出 `firewall disabled`、`simulate` 回 `no such chain PVEFW-INPUT` | 總開關關閉時這兩個指令不能用；要先啟用才能預覽，所以規則要先寫好、確認 PVE 解析成功（`pvesh get`），啟用後才用 `simulate` 看效果 |
| 以為沒有 `host.fw` | 它在 `/etc/pve/nodes/<節點名>/host.fw`，不在 `/etc/pve/firewall/`；三台原本內容只有 `enable: 1` |
| `host.fw` 寫 `enable: 0`，以為該節點不套用防火牆 | 只有該節點的主機層規則不套用；叢集層規則照樣生效（第 7 節）。逐台啟用是 `pvesh set /nodes/<節點>/firewall/options --enable 1` |
| 貼上兩個指令接在一起（`date` 與 `printf` 變成 `dateprintf`），節點的 `host.fw` 被清成空檔案 | shell 的 `>` 重新導向會**先清空檔案、再找指令**，所以指令打錯也會清檔。多個區塊不要一起貼、同一個區塊只貼一次；改設定優先用 `pvesh set` |
| 排好計時器立刻查，`list-timers` 顯示 `No entries` | 不是失敗，是時間還沒到；用 `systemctl list-timers fw-safety.timer` 看 `LEFT` |
| 叢集網 SSH 逾時（只有主機層規則已生效的節點） | 官方「管理主機自動放行」只涵蓋服務網；用第 8 節的規則放行 `+pve_nodes` 到 22、8006、3128 |
| `simulate` 回 `unable to parse rule: --match multiport --dports 22,8006,3128 -j RETURN` | 模擬器讀不懂 `multiport`（規則寫了一次多個埠就會被編成這個）；真實的 iptables 沒問題（SSH、8006 實際連得通）。**節點對節點要看真實流量判斷**，不要用 `simulate` |
| 遠端、沒有實體主控台，規則寫錯人被鎖在外面 | 保險計時器是唯一的救援；VPN 救不了規則寫錯，因為 VPN 走同一個服務網 |
| 緊急要停防火牆 | `for n in node10 node11 node12; do ssh root@$n '/usr/sbin/pve-firewall stop'; done`；這只是臨時停止，節點重開機或 `pve-firewall` 服務重啟後規則會再套用 |
| 要永久還原 | 把 `cluster.fw` 的 `enable` 改回 `0`、再 `systemctl start pve-firewall`；主機層用 `pvesh set /nodes/<節點>/firewall/options --enable 0`；原始檔備份是 `/root/cluster.fw.bak-20261102` |

## 11. 待辦

- [x] 啟用叢集層防火牆、補叢集網規則（2026-11-02）
- [x] 三台主機層規則生效：node12 原本就有、node11（11/02）、node10（11/03）
- [x] 啟用後三台備份、Ceph、HA、Corosync 都正常（11/02 手動全量與晚上排程）
- [ ] 管理員電腦固定 IP，之後縮小 8006、22、3128 的來源（階段 1b）；要用 `management` IPSet 還是改 `local_network`，以 `simulate` 在已啟用的環境測試為準（文件沒說定義 `management` 後 `local_network` 還放不放行，**未驗證**）
- [ ] 階段 2、3：Guest 層規則，尚未開始
- [ ] 驗證 IPv6 的行為與被丟棄封包的 log 位置（**未驗證**）
- [ ] （可選）停用沒人用的 rpcbind（111，推測沒人用）
- [ ] （可選）實測 Corosync link1 的備援接手（見[Corosync 第二條 link](https://kbwangtw.github.io/IT-Knowledge-Base/docs/pve/corosync-second-link/)）

## 12. 延伸閱讀

- [Proxmox VE Firewall](https://pve.proxmox.com/pve-docs/chapter-pve-firewall.html)
- [內網橫向感染評估：先看清楚網路長怎樣，再決定要不要裝防火牆](https://kbwangtw.github.io/IT-Knowledge-Base/docs/network/internal-network-lateral-movement-assessment/)
- [Corosync 加第二條 link（備援）](https://kbwangtw.github.io/IT-Knowledge-Base/docs/pve/corosync-second-link/)
- [PVE 一直被嘗試登入：怎麼確認 Fail2Ban 真的有擋？](https://kbwangtw.github.io/IT-Knowledge-Base/docs/pve/pve-cluster-fail2ban-hardening/)
