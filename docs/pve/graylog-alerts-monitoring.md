---
layout: default
title: "Graylog 告警與監控（二）：告警清單、監控腳本與中文告警信"
date: 2026-10-19
categories: [PVE, Graylog, Monitoring]
permalink: /docs/pve/graylog-alerts-monitoring/
last_modified_at: 2026-10-19
---

# Graylog 告警與監控（二）：告警清單、監控腳本與中文告警信

> **一句話**：日誌收進 Graylog 之後，靠 14 個告警把「出事了」寄到 Gmail；再用 PVE 節點上的外部檢查盯住 Graylog 本身、NAS 複寫和每晚的備份，就算 Graylog 掛了也收得到信。

| 項目 | 內容 |
| --- | --- |
| 適合誰看 | 已經把日誌送進 Graylog、想知道告警怎麼設、怎麼確認它真的會寄信的人 |
| 上篇 | [把 PVE、PBS 與 NAS 的日誌集中到 Graylog（一）：收集、分類與寄信設定](https://kbwangtw.github.io/IT-Knowledge-Base/docs/pve/proxmox-graylog-syslog-pipeline-sop/)（收集、Pipeline、jt-ipam、Gmail 寄信、第一個告警、日常維運） |
| 環境 | Graylog 7.1.9（CT 105）；PVE 三台節點 node10～12；PBS31；Synology NAS tokyo16、melayu17 |
| 目前狀態 | ✅ 14 個告警（13 個 Email 通知）運作中，告警信 10/19 改為中文 ✅ Graylog 本身、NAS 複寫與連線、每晚備份都有外部檢查 ⏳ 其他告警的實際事件測試、單節點故障演練 |
| 紀錄期間 | 2026-10-16 盤點起，最後更新 2026-10-19 |

**這篇怎麼讀**：先看第 1、2 節弄懂「三條寄信路徑」；收到某種告警信時，直接看第 10 節「常見問題」找對應的「收到信時怎麼查」。

## 1. 先認識幾個名詞

| 名詞 | 白話解釋 |
| --- | --- |
| **Event Definition（告警規則）** | 定時搜尋日誌，符合條件就產生一個「事件」，例如「PVE 任務失敗警報」 |
| **Notification（通知）** | 事件發生後怎麼通知：寄給誰、主旨、內文範本。本環境每個告警各綁一個 |
| **Grace Period** | 同一個告警在這段時間內最多寄一封，避免信件轟炸 |
| **Backlog** | 告警信裡附上的原始日誌筆數 |
| **監控腳本** | 放在 PVE 節點上、定時檢查某件事的小程式（shell 或 Python），由 systemd timer 定時執行 |
| **systemd timer** | Linux 內建的排程器，功能類似 cron，可以用 `systemctl list-timers` 查看 |
| **postfix** | 節點上負責寄信的程式，經 Gmail 轉寄；外部檢查用它直接寄信，不經過 Graylog |
| **logger** | 寫一筆日誌的指令；用它產生「合成測試訊息」，不用真的弄壞東西就能測試告警 |

## 2. 全貌：三條寄信路徑

```text
路徑 A（Graylog 告警）
  日誌 → Graylog → Event Definition（第 3 節）→ Notification（中文範本，第 8 節）→ Gmail

路徑 B（腳本 → Graylog）
  PVE 節點監控腳本（節點、儲存空間，第 4 節）→ logger 寫日誌 → 走路徑 A

路徑 C（外部檢查，不經過 Graylog）
  PVE 節點上的檢查腳本 ─┬─ Graylog 本身（第 5 節）
                        ├─ NAS 連線（第 6 節）
                        └─ 每晚備份（第 7 節）
                        → 本機 postfix（第 9 節）→ Gmail

每天 08:00 心跳 → 路徑 A → 【每日健康回報】：收到就代表路徑 A 整條是通的（第 5 節）
```

| 想知道 | 看哪裡 |
| --- | --- |
| 有哪些告警、條件是什麼 | 第 3 節 |
| 「節點離線」「儲存空間」這類告警的訊息從哪來 | 第 4 節 |
| Graylog 掛了怎麼知道 | 第 5 節 |
| NAS 快照複寫失敗怎麼知道 | 第 6 節 |
| 備份沒做、驗證失敗怎麼知道 | 第 7 節 |
| 告警信的內容怎麼改 | 第 8 節 |

## 3. 全部告警清單（2026-10-16 盤點）

### 3-1 怎麼匯出所有告警設定

大部分告警在本文件之前就由其他人建立，沒有紀錄。10/16 用 Graylog 的 REST API 一次匯出。

在 Graylog 容器內執行。注意 Graylog 監聽的是**容器的 IP**，不是 127.0.0.1；`-u admin` 會詢問 admin 密碼：

```bash
GL=$(hostname -I | awk '{print $1}')
curl -s -o /root/event-defs.json -w 'http=%{http_code}\n' -u admin "http://$GL:9000/api/events/definitions?per_page=100"
python3 -c '
import json
d=json.load(open("/root/event-defs.json"))
for e in d["event_definitions"]:
    c=e["config"]; n=e.get("notification_settings") or {}
    print("==", e["title"], "| priority", e["priority"])
    print("  query:", c.get("query"))
    print("  every/within(min):", c.get("execute_every_ms",0)//60000, "/", c.get("search_within_ms",0)//60000)
    print("  group_by:", c.get("group_by"), "| conditions:", json.dumps(c.get("conditions"), ensure_ascii=False))
    print("  grace(min):", (n.get("grace_period_ms") or 0)//60000, "| backlog:", n.get("backlog_size"), "| notifications:", len(e.get("notifications") or []))
'
rm /root/event-defs.json
```

| 顯示 | 意思 |
| --- | --- |
| `http=200` | 成功 |
| `http=401` | 帳號或密碼錯誤。忘記密碼時，可在網頁 System → Users and Teams → Administrator → **Edit Tokens** 建立暫時 token，改用 `-u "<token>:token"`，用完刪除 |
| `http=000` | 連不上，多半是用了 127.0.0.1 |

### 3-2 清單

「每／範圍」是「每幾分鐘檢查一次／檢查最近幾分鐘」。

| 告警 | 條件（Search Query） | 每／範圍（分） | 分組、門檻 | Grace／Backlog |
| --- | --- | --- | --- | --- |
| Ceph 健康警告 | `message:"Health check failed:" AND NOT message:"cmd=" AND NOT message:"dispatch" AND NOT message:"finished"` | 5／5 | 每筆（10/19 由「有就觸發」改，第 8 節第八步） | 5 分／10 |
| PVE Corosync 成員離線 | `message:corosync AND message:"Members left:"` | 5／5 | 每筆（10/19 由「有就觸發」改，第 8 節第八步） | 5 分／10 |
| PVE Node 狀態離線 | `"PVE_NODE_OFFLINE" OR "PVE_NODE_MONITOR_ERROR"`（4-1 的腳本產生；10/16 加入後者） | 1／1 | 每筆 | 5 分／10 |
| PVE 任務失敗警報 | `pve_event_type:task_failed` | 5／5 | 每筆 | 5 分／5（10/16 由 0 改為 5） |
| PVE 儲存空間嚴重 | `message:"STORAGE_CRITICAL"`（4-1） | 5／5 | 每筆（10/19 由「有就觸發」改，第 8 節第八步） | 5 分／10 |
| PVE 儲存空間警告 | `message:"STORAGE_WARNING"`（4-1） | 5／5 | 每筆（10/19 由「有就觸發」改，第 8 節第八步） | **24 小時**／10（10/16 由 5 分改為 24 小時） |
| PVE 儲存設備離線 | `message:"STORAGE_UNAVAILABLE"`（4-1） | 5／5 | 每筆（10/19 由「有就觸發」改，第 8 節第八步） | 5 分／10 |
| PVE 多次驗證失敗 | `device_type:"pve" AND event_category:"authentication" AND (message:failure OR message:failed)` | 5／5 | 同一台 `source` ≥ 3 次 | 5 分／50 |
| PVE 服務異常 | `device_type:"pve" AND event_category:"system_error" AND message:"Failed with result"` | 5／5 | 每筆 | 5 分／50 |
| Synology DSM 登入失敗 | `synology_auth_result:failed AND synology_service:DSM` | 5／5 | 同一台 NAS、同一來源 IP ≥ 3 次 | 5 分／10 |
| Synology DSM 管理員登入 | `message:"User [<NAS 管理員帳號>]" AND message:"signed in to [DSM] successfully"` | 5／5 | 每筆 | 5 分／10 |
| WireGuard VPN 異常 | `source:wazuh AND "WireGuard ct:109"`（由 Wazuh 轉來） | 1／5 | 每筆 | 30 分／5 |
| Graylog 每日健康回報 | `"GRAYLOG_DAILY_HEARTBEAT"`（三台每天 08:00 送出；10/19 加入，見第 5 節） | 5／5 | 有就觸發 | 60 分／3 |
| System notification events | Graylog 內建 | — | — | — |

- 每個告警都綁了一個 Email 通知（上篇第 9 節），共 13 個；10/19 起內文都是中文範本（第 8 節）。
- 「每筆」和「有就觸發／≥ N 次」決定了信裡「摘要」能不能帶出原始日誌的欄位（第 8 節第七步）。
- **Grace 5 分鐘**：同一告警 5 分鐘內最多寄一封。狀態持續時（節點一直離線、儲存一直超標）會每 5 分鐘再寄一封，直到恢復。
- **NAS 登入失敗**：要「同一台 NAS、同一個 IP、5 分鐘內 ≥ 3 次」才通知；比較慢的嘗試由 DSM 的自動封鎖處理。
- **NAS 管理員登入**：只涵蓋那一個管理員帳號。兩步驟驗證時只有最後的 `signed in ... successfully via [OTP]` 符合，一次登入只寄一封。
- **WireGuard**：檢查範圍 5 分鐘比間隔 1 分鐘長，同一筆訊息會被抓到好幾次，靠 30 分鐘的 Grace 避免重複寄信（建置過程見 [WireGuard 文件](https://kbwangtw.github.io/IT-Knowledge-Base/docs/pve/wireguard-remote-access-replace-8006/)第 12 節）。

## 4. 告警背後的監控腳本與盤點修正

### 4-1 告警背後的監控腳本（PVE 三台）

「Node 離線」和三個「儲存」告警的訊息**不是 PVE 原生的日誌**，而是節點上的腳本定期檢查後，用 `logger` 寫進 syslog，再轉送到 Graylog。

| 腳本 | 在哪裡 | 多久跑一次 | 檢查什麼 |
| --- | --- | --- | --- |
| `/usr/local/sbin/pve-node-monitor.sh` | 三台（10/16 加入 node11、node12） | 每 1 分鐘 | 用 `pvesh get /cluster/resources --type node` 查叢集，狀態不是 online 的節點寫出 `PVE_NODE_OFFLINE node=<節點> status=<狀態>`；查詢失敗寫 `PVE_NODE_MONITOR_ERROR` |
| `/usr/local/sbin/pve-storage-monitor.sh` | 三台，內容相同 | 每 5 分鐘 | 本機 `/` 與 `pve/data`（LVM Thin 的 data、metadata）用量 ≥ 80% 寫 `STORAGE_WARNING`、≥ 90% 寫 `STORAGE_CRITICAL`；共用儲存 PBS31、VM_Pool、cephfs（`pvesm status`）狀態不是 active 寫 `STORAGE_UNAVAILABLE` |

**怎麼判讀「哪一台出問題」**：

| 訊息 | 出問題的是 |
| --- | --- |
| `PVE_NODE_OFFLINE node=node12 status=offline` | `node=` 後面那一台；訊息的 source 是負責偵測的節點 |
| `PVE_NODE_MONITOR_ERROR ...` | 送出訊息的那一台本身（查不到叢集狀態） |
| `STORAGE_WARNING host=node11 storage=...` | `host=` 那一台的 `storage=` 那個儲存 |

`pve-node-monitor.sh`（需要先安裝 `jq`）：

```bash
#!/bin/bash
TAG="PVE-NODE-MONITOR"
NODES_JSON=$(pvesh get /cluster/resources --type node --output-format json 2>/dev/null)
if [ $? -ne 0 ] || [ -z "$NODES_JSON" ]; then
    logger -t "$TAG" "PVE_NODE_MONITOR_ERROR unable_to_query_cluster_resources"
    exit 1
fi
echo "$NODES_JSON" | jq -r '.[] | select(.status != "online") | "\(.node)|\(.status)"' |
while IFS='|' read -r NODE STATUS; do
    [ -z "$NODE" ] && continue
    logger -t "$TAG" "PVE_NODE_OFFLINE node=$NODE status=$STATUS"
done
```

`pve-storage-monitor.sh`（三台相同）：

```bash
#!/bin/bash
WARN=80
CRIT=90
HOST=$(hostname -s)

# local：PVE root filesystem
ROOT_USAGE=$(df --output=pcent / | tail -1 | tr -dc '0-9')
if [ "$ROOT_USAGE" -ge "$CRIT" ]; then
    logger -t pve-storage-monitor "STORAGE_CRITICAL host=$HOST storage=local type=filesystem usage=${ROOT_USAGE}% threshold=${CRIT}%"
elif [ "$ROOT_USAGE" -ge "$WARN" ]; then
    logger -t pve-storage-monitor "STORAGE_WARNING host=$HOST storage=local type=filesystem usage=${ROOT_USAGE}% threshold=${WARN}%"
fi

# local-lvm：LVM Thin Pool Data% 與 Metadata%
for M in data metadata; do
    V=$(lvs --noheadings --nosuffix -o ${M}_percent pve/data 2>/dev/null | xargs)
    [ -z "$V" ] && continue
    I=${V%.*}
    if [ "$I" -ge "$CRIT" ]; then
        logger -t pve-storage-monitor "STORAGE_CRITICAL host=$HOST storage=local-lvm metric=$M usage=${V}% threshold=${CRIT}%"
    elif [ "$I" -ge "$WARN" ]; then
        logger -t pve-storage-monitor "STORAGE_WARNING host=$HOST storage=local-lvm metric=$M usage=${V}% threshold=${WARN}%"
    fi
done

# Shared Storage：由三台節點監控，重複訊息由 Graylog 合併
for STORAGE in PBS31 VM_Pool cephfs; do
    LINE=$(pvesm status 2>/dev/null | awk -v s="$STORAGE" '$1 == s {print}')
    [ -z "$LINE" ] && continue
    STATUS=$(echo "$LINE" | awk '{print $3}')
    USAGE=$(echo "$LINE" | awk '{print $7}' | tr -d '%')
    if [ "$STATUS" != "active" ]; then
        logger -t pve-storage-monitor "STORAGE_UNAVAILABLE host=$HOST storage=$STORAGE type=shared status=$STATUS"
        continue
    fi
    [ -z "$USAGE" ] && continue
    U=${USAGE%.*}
    if [ "$U" -ge "$CRIT" ]; then
        logger -t pve-storage-monitor "STORAGE_CRITICAL host=$HOST storage=$STORAGE type=shared usage=${USAGE}% threshold=${CRIT}%"
    elif [ "$U" -ge "$WARN" ]; then
        logger -t pve-storage-monitor "STORAGE_WARNING host=$HOST storage=$STORAGE type=shared usage=${USAGE}% threshold=${WARN}%"
    fi
done
```

（原腳本的 data、metadata 是分開兩段寫的，邏輯相同，這裡合併以便閱讀。）

讓腳本定時執行的 systemd 設定：

```ini
# /etc/systemd/system/pve-node-monitor.service
[Unit]
Description=PVE Cluster Node Status Monitor
After=pve-cluster.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/pve-node-monitor.sh

# /etc/systemd/system/pve-node-monitor.timer
[Unit]
Description=Run PVE Cluster Node Status Monitor every minute

[Timer]
OnBootSec=1min
OnUnitActiveSec=1min
Unit=pve-node-monitor.service
Persistent=true

[Install]
WantedBy=timers.target

# /etc/systemd/system/pve-storage-monitor.timer（三台都有；service 為同名的 oneshot）
[Unit]
Description=Run PVE Storage Capacity Monitor every 5 minutes

[Timer]
OnBootSec=2min
OnUnitActiveSec=5min
Persistent=true

[Install]
WantedBy=timers.target
```

| systemd 名詞 | 意思 |
| --- | --- |
| `.service`（oneshot） | 「執行一次就結束」的工作；跑完狀態是 `inactive`，代表成功 |
| `.timer` | 鬧鐘：`OnBootSec` 開機後多久第一次執行，`OnUnitActiveSec` 之後每隔多久執行 |

node10 的 `/root/graylog-alert-test-all.sh`、`graylog-alert-test-remaining.sh` 是建立告警時用的測試腳本，日後要驗證告警是否仍有效時可以參考。

### 4-2 盤點發現與處理（2026-10-16）

| 發現 | 影響 | 處理 |
| --- | --- | --- |
| Node 離線檢查與共用儲存檢查**只在 node10** | node10 自己離線時沒人送 `PVE_NODE_OFFLINE`，共用儲存也沒人查（但 node11、node12 的 corosync 仍會觸發「Corosync 成員離線」） | ✅ node11、node12 部署相同腳本與 timer，三台互相監控（4-3） |
| `PVE_NODE_MONITOR_ERROR` 沒有告警 | node10 查不到叢集狀態（例如失去 quorum）時只寫 log | ✅ Node 離線告警條件加入 `OR "PVE_NODE_MONITOR_ERROR"`，用 `logger -t PVE-NODE-MONITOR "PVE_NODE_MONITOR_ERROR manual-test-20261016"` 測試，收到通知。node10 重開機時若 timer 比叢集服務早執行，可能多寄一封，屬預期 |
| 共用儲存在 `pvesm status` 找不到時直接略過 | 儲存被移除或改名時不會告警 | 留意；改名時同步修改腳本 |
| 儲存空間警告的 Grace 只有 5 分鐘 | 超過 80% 後每 5 分鐘寄一封，可能連續好幾天 | ✅ 警告改為 24 小時；嚴重維持 5 分鐘 |
| 任務失敗告警 Backlog 0 | 通知信看不出是哪個任務失敗 | ✅ 改為 5 |
| 腳本與 timer 只存在節點上 | 重灌或換節點時容易遺漏 | ✅ 本節保存了完整內容 |

### 4-3 三台都部署監控腳本（2026-10-16）

先加 node11（讓 node10 離線時也有人回報），再加 node12（讓三台設定一致；node12 額外的效益只在 node10、node11 同時離線時，那時 node12 失去 quorum，多半會送出 `PVE_NODE_MONITOR_ERROR`）。

- 任一台離線時，另外兩台都會送 `PVE_NODE_OFFLINE`，由 5 分鐘 Grace 合併成一封信。
- 三個儲存告警 10/19 起是「每筆」：多台各送一筆會各產生一個事件，但 Grace 期間只寄一封信（第 8 節第八步）。

部署步驟（在 node10 執行，以 node11 為例）：

```bash
# 1. 比對：兩台 storage 腳本只差共用儲存那一段
diff <(ssh root@node11 cat /usr/local/sbin/pve-storage-monitor.sh) /usr/local/sbin/pve-storage-monitor.sh
# 2. 安裝 jq（原本沒有，腳本會失敗）並備份
ssh root@node11 "apt-get install -y jq"
ssh root@node11 "cp -a /usr/local/sbin/pve-storage-monitor.sh /usr/local/sbin/pve-storage-monitor.sh.bak-$(date +%Y%m%d)"
# 3. 複製腳本與 systemd 設定，啟用 timer
scp -p /usr/local/sbin/pve-storage-monitor.sh /usr/local/sbin/pve-node-monitor.sh root@node11:/usr/local/sbin/
scp -p /etc/systemd/system/pve-node-monitor.service /etc/systemd/system/pve-node-monitor.timer root@node11:/etc/systemd/system/
ssh root@node11 "chmod 755 /usr/local/sbin/pve-node-monitor.sh && systemctl daemon-reload && systemctl enable --now pve-node-monitor.timer"
```

驗證：

```bash
ssh root@node11 "pvesh get /cluster/resources --type node --output-format json | jq -r '.[] | \"\(.node) \(.status)\"'"
ssh root@node11 "systemctl start pve-node-monitor.service pve-storage-monitor.service; systemctl is-failed pve-node-monitor.service pve-storage-monitor.service"
ssh root@node11 "systemctl list-timers --no-pager | grep -E 'pve-(node|storage)'"
ssh root@node11 'logger -t PVE-NODE-MONITOR "PVE_NODE_MONITOR_ERROR manual-test-node11"'
for h in node10 node11 node12; do echo "== $h"; ssh root@$h "md5sum /usr/local/sbin/pve-*-monitor.sh"; done
```

| 檢查 | 結果（node11、node12 都相同） |
| --- | --- |
| 查叢集 | 三台都是 `online` |
| 兩個服務 | `inactive`（執行完畢、沒有 failed） |
| timer | 兩個都已排程 |
| 測試訊息 | 收到「PVE Node 狀態離線」通知，信裡 source 是送出的那一台 |
| md5 | 三台兩支腳本完全相同 |

node12 部署前，它的 storage 腳本和 node11 改版前的備份 `diff` 沒有差異。

還原（node11 或 node12）：`systemctl disable --now pve-node-monitor.timer`，刪除 node-monitor 腳本與兩個 systemd 檔案後 `daemon-reload`；storage 腳本用 `.bak-日期` 還原。

## 5. 監控 Graylog 本身（2026-10-19）

**為什麼要做**：所有告警都由 Graylog 寄出，連 Wazuh 的 VPN 告警也要經過它。Graylog 自己掛掉時，**所有告警都會靜默**，而且沒有任何通知。所以監控 Graylog 一定要走**另一條寄信路線**。

「Graylog 掛了」有四種情況，用兩層分工處理：

| # | 情況 | 例子 | 由哪一層抓 |
| --- | --- | --- | --- |
| 1 | 服務停了 | 容器沒開、graylog-server 當掉 | 第一層 |
| 2 | 服務在，但收不到日誌 | Input 停了、來源端的 rsyslog 壞了 | 第一層 |
| 3 | 收得到，但處理不了 | OpenSearch 卡住、磁碟滿，訊息堆在佇列（journal） | 第一層 |
| 4 | 都正常，但**信寄不出去** | Gmail 應用程式密碼失效 | 第二層 |

```text
第一層：外部檢查（抓 1、2、3）
  node10／11／12 每 5 分鐘呼叫 Graylog API 檢查
    → 異常 → 用節點本機的 postfix 直接寄 Gmail（不經過 Graylog）

第二層：每日健康回報（抓 4）
  每天 08:00 三台各送一筆 GRAYLOG_DAILY_HEARTBEAT 日誌
    → Graylog 照正常告警流程寄出【每日健康回報】
    → 哪天早上沒收到這封信 = 告警鏈有地方斷了
```

> 三台都部署，是因為 node10、node11 同時故障時，node12 雖然失去 quorum，但檢查腳本只用 `curl` 和 `mail`、不依賴叢集功能，仍然能檢查和寄信。代價是同一個故障會收到 3 封信（主旨寫明是哪一台偵測到的）。

### 第一步：確認節點能直接寄信

PVE 沒有 `/etc/pve/notifications.cfg`，代表用預設方式：交給本機 postfix，而 postfix 已設定經 Gmail 轉寄（備份通知信就是走這條路）。

```bash
postconf -h relayhost          # 應為 smtp.gmail.com:587
command -v sendmail mail       # 有這兩個指令
read -p "收件 Gmail：" TO
```

```bash
echo "寄信測試，來自 $(hostname)" | mail -s "【測試】$(hostname) 直接寄信（不經過 Graylog）" "$TO"
journalctl --since "10 min ago" --no-pager | grep -E 'postfix/.*status=' | tail -3
```

**看到的結果**：三台 relayhost 都是 `smtp.gmail.com:587`，紀錄出現 `status=sent (250 2.0.0 OK …)`，三封測試信都收到。postfix 的服務名稱各版本不同，所以用 `journalctl` 讀全部日誌再 grep，不指定 `-u`。

`postconf` 當時會出現 `support for parameter "smtp_use_tls" will be removed` 警告，是舊參數名稱，不影響寄信；10/19 已改成新參數（第 9 節）。

### 第二步：建立唯讀帳號與 token

腳本要讀 Graylog API，所以建一個只有 **Reader** 角色的帳號 `pve-monitor`。以下在 node10 用管理員身分透過 API 建立，token 直接寫進設定檔，**不顯示在畫面上、不經過剪貼簿**。

先建立設定檔（`read -p` 單獨貼上）：

```bash
read -p "收件 Gmail：" TO
```

```bash
umask 077
printf 'GL_URL=http://<Graylog IP>:9000\nGL_TOKEN=\nMAIL_TO=%s\n' "$TO" > /root/.graylog-monitor.conf
ls -l /root/.graylog-monitor.conf      # 應為 -rw-------
```

輸入管理員密碼（`read -s` 單獨貼上，輸入時畫面不顯示）：

```bash
read -s -p "Graylog admin 密碼：" GLPASS; echo
```

建立帳號與 token：

```bash
. /root/.graylog-monitor.conf
H=(-s -u "admin:$GLPASS" -H 'X-Requested-By: cli' -H 'Content-Type: application/json' -H 'Accept: application/json')
UPW=$(openssl rand -base64 32)
curl "${H[@]}" -w '  http=%{http_code}\n' -X POST "$GL_URL/api/users" -d "{\"username\":\"pve-monitor\",\"first_name\":\"PVE\",\"last_name\":\"Monitor\",\"email\":\"$MAIL_TO\",\"password\":\"$UPW\",\"roles\":[\"Reader\"],\"permissions\":[]}"
unset UPW
UID_=$(curl "${H[@]}" "$GL_URL/api/users/pve-monitor" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("id",""))')
RESP=$(curl "${H[@]}" -X POST "$GL_URL/api/users/$UID_/tokens/pve-graylog-monitor" -d '{"token_ttl":"P3650D"}')
unset GLPASS H
NEWTOKEN=$(printf '%s' "$RESP" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("token",""))' 2>/dev/null)
[ -n "$NEWTOKEN" ] && sed -i "s|^GL_TOKEN=.*|GL_TOKEN=$NEWTOKEN|" /root/.graylog-monitor.conf
unset NEWTOKEN RESP UID_
```

| 片段 | 意思 |
| --- | --- |
| `UPW=$(openssl rand …)` | 帳號的密碼隨機產生、不顯示；這個帳號只用 token，不用密碼登入 |
| `"roles":["Reader"]` | 只能讀，不能改任何設定 |
| `/api/users/<ID>/tokens/<名稱>` | 建立 token 要用帳號 ID，不是帳號名稱 |
| `"token_ttl":"P3650D"` | 有效期 3650 天，避免預設期限一到監控就失效 |
| `sed -i …` | token 直接寫進設定檔 |

測試 token（`-u "<token>:token"` 是 Graylog 的 token 登入方式：帳號欄放 token，密碼欄固定寫 `token`）：

```bash
. /root/.graylog-monitor.conf; echo "token 長度：${#GL_TOKEN}"
A=(-s -m 10 -u "$GL_TOKEN:token" -H 'Accept: application/json')
for p in system/lbstatus system/journal system/inputstates system/metrics/org.graylog2.throughput.input system/metrics/org.graylog2.throughput.output; do
  printf '%-48s ' "$p"; curl "${A[@]}" -o /dev/null -w 'http=%{http_code}\n' "$GL_URL/api/$p"
done
```

**看到的結果**：token 長度 52，五個端點都是 `http=200`。Reader 權限就讀得到佇列、Input 狀態和累計數字，不需要再補權限。

| 端點 | 用途 | 實測值（10/19） |
| --- | --- | --- |
| `system/lbstatus` | 健康狀態，不需登入 | `ALIVE` |
| `system/journal` | 佇列堆積幾筆 | 9 筆，每秒進出各 6 筆 |
| `system/inputstates` | 每個 Input 是否 RUNNING | 全部 RUNNING |
| `…throughput.input` | 啟動以來**收進**幾筆（累計） | 1,016,412 |
| `…throughput.output` | 啟動以來**處理完**幾筆（累計） | 825,263（比收進少，是上篇 7-3 的丟棄規則把 NAS 雜訊丟掉） |

> `system/throughput`（每秒處理量）**不適合**拿來判斷：連續 10 秒測得 6、0、3、0、6、3、6、0、3、0，日誌是一陣一陣進來的，碰到空檔就是 0，會誤報。所以改用只增不減的累計數字。`count/total` 在 Graylog 7 已不存在（404）。

### 第三步：安裝檢查腳本

| 檢查 | 判定異常的條件 | 對應情況 |
| --- | --- | --- |
| 健康端點 | 不是 `ALIVE`，或 10 秒內沒回應 | 1 |
| Input | 有任何 Input 不是 `RUNNING` | 2 |
| 輸入累計 | 和上次檢查（5 分鐘前）相比完全沒增加 | 2 |
| 處理累計 | 有收到新訊息，但處理數完全沒增加 | 3 |
| 佇列 | 堆積超過 50,000 筆（平常個位數） | 3 |
| API | 讀不到資料 | token 失效或權限被改 |

**寄信規則**：剛異常時立刻寄一封；持續異常每 60 分鐘再寄一次；恢復時寄「已恢復」。Graylog 重開時累計數字會歸零，腳本把「數字變小」視為重開，不當成異常。

`/usr/local/sbin/graylog-health-check.sh`：

```bash
#!/bin/bash
# Graylog 健康檢查：異常時用本機 postfix 直接寄信（不經過 Graylog）
CONF=${CONF:-/root/.graylog-monitor.conf}
STATE_DIR=/var/lib/graylog-health
JOURNAL_MAX=50000   # 佇列堆積超過這個數量就告警
REPEAT_MIN=60       # 持續異常時，每隔幾分鐘再寄一次
. "$CONF" || exit 1
mkdir -p "$STATE_DIR"
H=$(hostname -s); NOW=$(date +%s); problems=()
api() { curl -s -m 10 -u "$GL_TOKEN:token" -H 'Accept: application/json' "$GL_URL/api/$1"; }
num() { python3 -c "import json,sys; print(json.load(sys.stdin)$1)" 2>/dev/null; }

lb=$(curl -s -m 10 "$GL_URL/api/system/lbstatus")
if [ "$lb" != "ALIVE" ]; then
  problems+=("健康端點不是 ALIVE（實際回應：${lb:-沒有回應}）")
else
  in_now=$(api system/metrics/org.graylog2.throughput.input | num '["count"]')
  out_now=$(api system/metrics/org.graylog2.throughput.output | num '["count"]')
  unc=$(api system/journal | num '["uncommitted_journal_entries"]')
  down=$(api system/inputstates | python3 -c 'import json,sys; print(", ".join(s["message_input"]["title"]+"="+s["state"] for s in json.load(sys.stdin)["states"] if s["state"]!="RUNNING"))' 2>/dev/null)
  if [ -z "$in_now" ] || [ -z "$out_now" ] || [ -z "$unc" ]; then
    problems+=("API 讀不到累計數字或佇列（token 失效或權限被改？）")
  else
    [ -n "$down" ] && problems+=("Input 沒有在執行：$down")
    [ "$unc" -gt "$JOURNAL_MAX" ] && problems+=("佇列堆積 $unc 筆（上限 $JOURNAL_MAX）：收得到但處理不了")
    read -r in_prev out_prev 2>/dev/null < "$STATE_DIR/counts"
    if [ -n "$in_prev" ] && [ "$in_now" -ge "$in_prev" ]; then   # 數字變小 = Graylog 重開，略過這一輪
      [ "$in_now" -eq "$in_prev" ] && problems+=("上次檢查到現在沒有收到任何新訊息（輸入累計停在 $in_now）")
      [ "$in_now" -gt "$in_prev" ] && [ "$out_now" -eq "$out_prev" ] && problems+=("有收到新訊息，但處理數沒有增加（停在 $out_now）")
    fi
    echo "$in_now $out_now" > "$STATE_DIR/counts"
  fi
fi

prev=$(cat "$STATE_DIR/status" 2>/dev/null || echo OK)
last=$(cat "$STATE_DIR/last_mail" 2>/dev/null || echo 0)
if [ ${#problems[@]} -gt 0 ]; then
  logger -t graylog-health "GRAYLOG_UNHEALTHY host=$H $(printf '%s; ' "${problems[@]}")"
  if [ "$prev" = OK ] || [ $((NOW-last)) -ge $((REPEAT_MIN*60)) ]; then
    printf '偵測主機：%s\n時間：%s\n\n異常項目：\n%s\n\n這封信由 PVE 節點直接寄出，不經過 Graylog。\n處理方式見知識庫 Graylog 文件「監控 Graylog 本身」一節。\n' \
      "$H" "$(date '+%F %T')" "$(printf -- '- %s\n' "${problems[@]}")" \
      | mail -s "【Graylog 異常】$H 偵測到 Graylog 有問題" "$MAIL_TO"
    echo "$NOW" > "$STATE_DIR/last_mail"
  fi
  echo FAIL > "$STATE_DIR/status"
else
  if [ "$prev" = FAIL ]; then
    printf '偵測主機：%s\n時間：%s\n\nGraylog 已恢復正常（健康端點 ALIVE、佇列 %s 筆）。\n' \
      "$H" "$(date '+%F %T')" "$unc" | mail -s "【Graylog 已恢復】$H" "$MAIL_TO"
    logger -t graylog-health "GRAYLOG_RECOVERED host=$H"
  fi
  echo OK > "$STATE_DIR/status"
fi
```

| 片段 | 意思 |
| --- | --- |
| `CONF=${CONF:-…}` | 平常讀正式設定檔；測試時可以換成另一份 |
| `api()`、`num()` | 小函式：呼叫 API、從 JSON 取出數字 |
| `/var/lib/graylog-health/` | 記錄狀態（OK／FAIL）、上次寄信時間、上次的累計數字 |
| `logger -t graylog-health` | 異常時也寫一筆 syslog，Graylog 還活著時事後查得到 |

systemd 設定（每 5 分鐘）：

```ini
# /etc/systemd/system/graylog-health-check.service
[Unit]
Description=Graylog health check (alerts via local postfix, not Graylog)
After=network-online.target postfix.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/graylog-health-check.sh

# /etc/systemd/system/graylog-health-check.timer
[Unit]
Description=Run Graylog health check every 5 minutes

[Timer]
OnBootSec=5min
OnUnitActiveSec=5min
Persistent=true

[Install]
WantedBy=timers.target
```

先手動執行兩次（隔 60 秒）確認 `exit=0`、狀態 `OK`、累計數字有增加，再啟用 timer。

### 第四步：模擬故障測試（不碰真正的 Graylog）

用一份故意寫錯埠號的設定，讓腳本以為連不到 Graylog：

```bash
sed 's|:9000|:9999|' /root/.graylog-monitor.conf > /root/.graylog-monitor-test.conf; chmod 600 /root/.graylog-monitor-test.conf
CONF=/root/.graylog-monitor-test.conf /usr/local/sbin/graylog-health-check.sh   # 模擬故障 → 寄「異常」
CONF=/root/.graylog-monitor-test.conf /usr/local/sbin/graylog-health-check.sh   # 60 分鐘內 → 不再寄
/usr/local/sbin/graylog-health-check.sh                                          # 正式設定 → 寄「已恢復」
rm -f /root/.graylog-monitor-test.conf
```

| 測試 | 結果（10/19） |
| --- | --- |
| 模擬故障 | ✅ 狀態 FAIL，收到【Graylog 異常】node10，內容「健康端點不是 ALIVE（實際回應：沒有回應）」 |
| 重複告警 | ✅ 沒有再寄 |
| 模擬恢復 | ✅ 狀態 OK，收到【Graylog 已恢復】node10 |

### 第五步：部署到三台並啟用

```bash
systemctl enable --now graylog-health-check.timer
for h in node11 node12; do
  scp -p /usr/local/sbin/graylog-health-check.sh root@$h:/usr/local/sbin/
  scp -p /etc/systemd/system/graylog-health-check.service /etc/systemd/system/graylog-health-check.timer root@$h:/etc/systemd/system/
  scp -p /root/.graylog-monitor.conf root@$h:/root/
  ssh root@$h "chmod 600 /root/.graylog-monitor.conf && systemctl daemon-reload && /usr/local/sbin/graylog-health-check.sh; systemctl enable --now graylog-health-check.timer"
done
for h in node10 node11 node12; do
  echo "== $h"; ssh root@$h "ls -l /root/.graylog-monitor.conf | cut -c1-10; md5sum /usr/local/sbin/graylog-health-check.sh | cut -c1-12; cat /var/lib/graylog-health/status; systemctl list-timers --no-pager | grep graylog-health"
done
```

**看到的結果**：三台設定檔都是 `-rw-------`、腳本指紋相同、狀態 `OK`、timer 每 5 分鐘執行。

### 第六步：每日健康回報（第二層）

三台節點每天 08:00 送一筆心跳日誌：

```ini
# /etc/systemd/system/graylog-heartbeat.service
[Unit]
Description=Send daily heartbeat message to Graylog

[Service]
Type=oneshot
ExecStart=/usr/bin/logger -t graylog-heartbeat "GRAYLOG_DAILY_HEARTBEAT host=%H"

# /etc/systemd/system/graylog-heartbeat.timer
[Unit]
Description=Daily Graylog heartbeat at 08:00

[Timer]
OnCalendar=*-*-* 08:00:00
Persistent=false

[Install]
WantedBy=timers.target
```

| 設定 | 意思 |
| --- | --- |
| `%H` | systemd 自動換成主機名稱 |
| `OnCalendar=*-*-* 08:00:00` | 每天 08:00（節點時區 CST） |
| `Persistent=false` | 08:00 剛好關機時，開機後不補送，避免半夜收到「每日回報」 |

三台都複製這兩個檔案後 `systemctl daemon-reload && systemctl enable --now graylog-heartbeat.timer`。

Graylog 端建立通知與 Event Definition：

| 項目 | 設定 |
| --- | --- |
| 通知 | Title `每日健康回報通知`；Email Notification；Subject `【每日健康回報】Graylog 告警鏈正常`；Time Zone `Asia/Taipei`；先 Execute Test Notification 收到測試信再 Create |
| Event Definition | Title `Graylog 每日健康回報`；Priority Low；Filter & Aggregation；Query `"GRAYLOG_DAILY_HEARTBEAT"`；Stream Infrastructure Syslog；每 5 分鐘、看 5 分鐘；Filter has results；通知 `每日健康回報通知`；**Grace 60 分鐘**（三台各一筆只寄一封）；Backlog 3 |

**測試**：建好 Event Definition **之後**才手動觸發（規則只看最近 5 分鐘，建好前送的訊息不會被抓到）：

```bash
for h in node10 node11 node12; do ssh root@$h "systemctl start graylog-heartbeat.service"; done
```

**看到的結果**（10/19）：三筆訊息進入 Infrastructure Syslog（`device_type=pve`），09:00:34 觸發事件，收到**一封**【每日健康回報】信。

**日常使用**：Gmail 可設篩選器（主旨含「每日健康回報」→ 略過收件匣、加標籤），**每天早上看一眼有沒有今天的信**；沒收到就代表告警鏈斷了，依第一層的信或手動檢查找原因。

### 收到「Graylog 異常」信時怎麼查

| 信裡的異常項目 | 先查什麼 |
| --- | --- |
| 健康端點不是 ALIVE | Graylog 容器有沒有開（`pct status 105`）、`systemctl status graylog-server`、OpenSearch 是否正常 |
| Input 沒有在執行 | Graylog **System → Inputs**，看錯誤訊息後重新啟動該 Input |
| 沒有收到任何新訊息 | 來源端 rsyslog（`systemctl status rsyslog`）、網路、Input 是否 RUNNING |
| 處理數沒有增加／佇列堆積 | OpenSearch 狀態（上篇 11-2）、磁碟空間；佇列會在恢復後自動消化 |
| API 讀不到資料 | token 被刪除或過期、`pve-monitor` 帳號被停用；重建 token（第二步） |

### 還原

三台各執行：`systemctl disable --now graylog-health-check.timer graylog-heartbeat.timer`，刪除 `/usr/local/sbin/graylog-health-check.sh`、四個 systemd 檔案、`/root/.graylog-monitor.conf`、`/var/lib/graylog-health/` 後 `daemon-reload`。Graylog 端刪除 Event Definition「Graylog 每日健康回報」、通知「每日健康回報通知」與 `pve-monitor` 帳號（連同它的 token）。

## 6. NAS 快照複寫與連線監控（2026-10-19）

**為什麼要做**：melayu17 是 tokyo16 的快照複寫目的地，也是**最後一道防線**。回查 Snapshot Replication 套件的日誌（2023-12 起），過去的複寫失敗都**連續好幾天沒被發現**：

| 期間 | 失敗的任務 | 原因 |
| --- | --- | --- |
| 2026-08-30～08-31 | PBS_BK_Folder、No16、homes（兩天全部失敗） | `connection failed`：連不到 melayu17 的 DSM 埠 |
| 2026-07-13～07-15 | No16、homes、PVE_Backup（連續三天） | 同上 |
| 2026-07-01～07-02 | No16、homes、PVE_Backup | 同上 |
| 2025 年 8～9 月 | 共 4 天 | 同上 |

### 目前的複寫任務（tokyo16 → melayu17，每天一次）

| 來源 | 目的地 | 每天完成時間 |
| --- | --- | --- |
| PBS_BK_Folder | PBS_BK_Folder | 約 00:15～00:25 |
| No16 | No16 | 約 02:00 |
| homes | homes-replicated | 約 02:01 |
| ActiveBackupforBusiness | ActiveBackupforBusiness-1 | 約 03:10 |
| KB-GD | KB-GD | 約 03:10 |
| ITBH-GD | ITBH-GD | 約 03:11 |

`PVE_Backup` 的複寫在 2026-07-27 改用 `PBS_BK_Folder` 後已移除，PVE 也沒有使用這個共用資料夾（`grep -i pve_backup /etc/pve/storage.cfg` 無結果）。10/19 從兩台的「控制台 → 共用資料夾」確認，`PVE_Backup` 共用資料夾在 tokyo16 與 melayu17 都已不存在（File Station 只列出目前帳號有權限的資料夾，要用控制台確認）。

**日誌格式**（套件內的「日誌」頁，**不在 DSM 記錄中心，所以不會經「記錄傳送」進 Graylog**；在 Graylog 搜尋 7 天為 0 筆）：

```text
成功：Synced shared folder replication from [tokyo16:<來源>] to [melayu17:<目的地>] completed.
失敗：Failed to sync shared folder replication from [tokyo16:<來源>] to [melayu17:<目的地>] due to [<原因>].
```

### 要抓的情況與分工

| 情況 | 例子 | 怎麼抓 |
| --- | --- | --- |
| 複寫失敗 | melayu17 連不上、空間滿 | DSM 內建通知（Warning 規則） |
| 複寫被停止 | 任務被暫停或停用 | DSM 內建通知（自訂規則「快照複寫停止」） |
| 任一台 NAS 當機或斷線 | tokyo16 整台掛掉時 DSM 自己寄不出信 | PVE 節點每 5 分鐘檢查兩台 DSM 是否回應 |

### 第一步：DSM 內建通知（tokyo16）

tokyo16 的 **控制台 → 通知設定 → 電子郵件** 已設定 Gmail 寄信，標題前置文字 `[tokyo16]`。預設規則 **Warning**（不能修改）已包含：

| Snapshot Replication 事件 | 層級 | Warning |
| --- | --- | --- |
| 執行初始複寫失敗 | 重大 | ✅ |
| 執行排程複寫失敗 | 重大 | ✅ |
| 無法為複寫任務啟用不可變快照 | 警告 | ✅ |
| 複寫任務未於特定時間內完成 | 警告 | ✅ |
| 複寫已停止 | 資訊 | ❌ |
| 初始／排程複寫已完成 | 資訊 | ❌（不需要） |

在「檢視規則」視窗的搜尋框輸入「複寫」，就能直接列出這些事件（不用展開類別）。

補上「複寫已停止」：

1. **規則 → 新增**：名稱 `快照複寫停止`，只勾 Snapshot Replication 的「複寫已停止」。
2. **電子郵件 → 收件者設定檔 → 新增**：同一個 Gmail，規則選 `快照複寫停止`。**保留原本的 Warning 那一筆**（一個收件者設定檔只能套一條規則，兩筆並存才不會少收）。

**看到的結果**：收件者設定檔有兩筆，分別套 Warning 與 快照複寫停止。

### 第二步：為什麼不用 DSM API 查「最新快照」

原本想讓節點每小時用 DSM API 查 melayu17 上每個資料夾的最新快照（超過 26 小時沒有新的就告警）。實測結果：

| 測試 | 結果 |
| --- | --- |
| `SYNO.API.Info` 查詢（不用登入） | ✅ 有 `SYNO.Core.Share.Snapshot`、`SYNO.DR.Plan` |
| 管理員帳號登入後 `SYNO.Core.Share.Snapshot list` | ✅ 列得出每日快照（`time: GMT+08-2026.10.18-00.10.02`） |
| 一般帳號（只開 DSM 權限）登入 | ✅（`session` 要用 `webui`；用自訂名稱回 402） |
| 一般帳號讀快照、讀複寫任務 | ❌ 都回 `105`（沒有權限） |

結論：**只有管理員帳號讀得到**。melayu17 是最後一道防線，不在 PVE 節點上存它的管理員帳密（節點被入侵時，最後一份備份也會被刪），所以改用「連線檢查」，測試用的一般帳號已刪除。這樣抓不到「排程被改掉、但沒觸發停止事件」這種少見情況，改以每月人工看一次 Snapshot Replication 狀態頁補上。

### 第三步：PVE 節點檢查兩台 NAS 是否回應

檢查方式是呼叫 DSM 的 `query.cgi`（**不需要登入，節點上沒有任何 NAS 帳密**）。兩台的 DSM HTTPS 埠刻意設成不同號碼，文件中以 `<tokyo16 埠>`、`<melayu17 埠>` 代稱。

設定檔 `/root/.nas-monitor.conf`（權限 600，收件人沿用第 5 節的設定）：

```bash
umask 077
. /root/.graylog-monitor.conf
cat > /root/.nas-monitor.conf <<EOF
MAIL_TO=$MAIL_TO
NAS_LIST="tokyo16=https://<tokyo16 IP>:<tokyo16 埠> melayu17=https://<melayu17 IP>:<melayu17 埠>"
EOF
umask 022
```

`/usr/local/sbin/nas-reach-check.sh`：

```bash
#!/bin/bash
# NAS 連線檢查：DSM 是否有回應；異常用本機 postfix 直接寄信（不經過 Graylog）
CONF=${CONF:-/root/.nas-monitor.conf}
STATE_DIR=/var/lib/nas-reach
FAIL_MIN=2      # 連續幾次沒回應才告警（每 5 分鐘一次 = 10 分鐘）
REPEAT_MIN=60   # 持續異常時，每隔幾分鐘再寄一次
. "$CONF" || exit 1
mkdir -p "$STATE_DIR"
H=$(hostname -s); NOW=$(date +%s)
for item in $NAS_LIST; do
  name=${item%%=*}; url=${item#*=}
  ok=$(curl -sk -m 10 "$url/webapi/query.cgi?api=SYNO.API.Info&version=1&method=query&query=SYNO.API.Auth" \
       | python3 -c 'import json,sys; print("yes" if json.load(sys.stdin).get("success") else "no")' 2>/dev/null)
  f="$STATE_DIR/$name"
  read -r fails status last 2>/dev/null < "$f"
  fails=${fails:-0}; status=${status:-OK}; last=${last:-0}
  if [ "$ok" = yes ]; then
    if [ "$status" = FAIL ]; then
      printf '偵測主機：%s\n時間：%s\n\n%s 的 DSM 已恢復回應。\n請到 Snapshot Replication 確認今晚的複寫有正常完成。\n' \
        "$H" "$(date '+%F %T')" "$name" | mail -s "【NAS 已恢復】$name（$H 偵測）" "$MAIL_TO"
      logger -t nas-reach "NAS_RECOVERED nas=$name host=$H"
    fi
    echo "0 OK 0" > "$f"
  else
    fails=$((fails+1))
    logger -t nas-reach "NAS_UNREACHABLE nas=$name host=$H fails=$fails"
    if [ "$fails" -ge "$FAIL_MIN" ]; then
      if [ "$status" = OK ] || [ $((NOW-last)) -ge $((REPEAT_MIN*60)) ]; then
        printf '偵測主機：%s\n時間：%s\n\n%s 的 DSM 連續 %s 次（每 5 分鐘一次）沒有回應。\n\n影響：\n- tokyo16 連不上：PBS 備份與快照複寫都會失敗\n- melayu17 連不上：快照複寫會失敗（最後一道防線沒有更新）\n\n這封信由 PVE 節點直接寄出，不經過 Graylog。\n' \
          "$H" "$(date '+%F %T')" "$name" "$fails" | mail -s "【NAS 連不上】$name（$H 偵測）" "$MAIL_TO"
        last=$NOW
      fi
      status=FAIL
    fi
    echo "$fails $status $last" > "$f"
  fi
done
```

| 片段 | 意思 |
| --- | --- |
| `NAS_LIST="名稱=網址 …"` | 要檢查的 NAS；多一台就多加一組 |
| 狀態檔 `連續失敗次數 狀態 上次寄信時間` | 每台 NAS 一個檔，在 `/var/lib/nas-reach/` |
| `FAIL_MIN=2` | 連續 10 分鐘沒回應才寄信，避開 DSM 更新重開的短暫中斷 |
| `logger -t nas-reach` | 每次失敗也寫 syslog，Graylog 事後查得到 |

systemd 設定與第 5 節相同模式（`nas-reach-check.service` 為 oneshot，`nas-reach-check.timer` 為 `OnBootSec=5min`、`OnUnitActiveSec=5min`）。

### 第四步：模擬 melayu17 連不上（不碰真正的 NAS）

```bash
sed 's|:<melayu17 埠>|:39999|' /root/.nas-monitor.conf > /root/.nas-monitor-test.conf; chmod 600 /root/.nas-monitor-test.conf
show() { for f in /var/lib/nas-reach/*; do echo "  $(basename $f)：$(cat $f)"; done; }
CONF=/root/.nas-monitor-test.conf /usr/local/sbin/nas-reach-check.sh; show   # 第 1 次
CONF=/root/.nas-monitor-test.conf /usr/local/sbin/nas-reach-check.sh; show   # 第 2 次
CONF=/root/.nas-monitor-test.conf /usr/local/sbin/nas-reach-check.sh; show   # 第 3 次
/usr/local/sbin/nas-reach-check.sh; show                                     # 第 4 次（正式設定）
rm -f /root/.nas-monitor-test.conf
```

| 第幾次 | melayu17 狀態檔（10/19 實測） | 信件 |
| --- | --- | --- |
| 1 | `1 OK 0` | 不寄 |
| 2 | `2 FAIL <時間戳>` | ✅ 收到【NAS 連不上】melayu17（node10 偵測） |
| 3 | `3 FAIL <同一個時間戳>` | 不寄（60 分鐘內） |
| 4 | `0 OK 0` | ✅ 收到【NAS 已恢復】melayu17（node10 偵測） |

tokyo16 全程 `0 OK 0`。

### 第五步：部署到三台

```bash
systemctl enable --now nas-reach-check.timer
for h in node11 node12; do
  scp -p /usr/local/sbin/nas-reach-check.sh root@$h:/usr/local/sbin/
  scp -p /etc/systemd/system/nas-reach-check.service /etc/systemd/system/nas-reach-check.timer root@$h:/etc/systemd/system/
  scp -p /root/.nas-monitor.conf root@$h:/root/
  ssh root@$h "chmod 600 /root/.nas-monitor.conf && systemctl daemon-reload && /usr/local/sbin/nas-reach-check.sh && systemctl enable --now nas-reach-check.timer"
done
```

**看到的結果**：三台設定檔都是 `-rw-------`、腳本指紋相同、兩台 NAS 都是 `0 OK 0`、timer 已排程。同一個故障三台會各寄一封（主旨寫明偵測主機）。

### 收到信時怎麼查

| 信件 | 先查什麼 |
| --- | --- |
| `[tokyo16]` 排程複寫失敗 | 失敗原因寫在信裡；`connection failed` → melayu17 是否開機、網路、DSM 埠；空間不足 → melayu17 儲存空間 |
| `[tokyo16]` 複寫已停止 | 是不是有人手動暫停；確認後在 Snapshot Replication 恢復任務 |
| 【NAS 連不上】tokyo16 | 主機是否當機；PBS 的 Tokyo16 datastore（CIFS）也會失效，見「PVE 儲存設備離線」告警 |
| 【NAS 連不上】melayu17 | 開機、網路；恢復後到 Snapshot Replication 確認當晚複寫完成，必要時手動「立即同步」 |

### 還原

三台各執行 `systemctl disable --now nas-reach-check.timer`，刪除腳本、兩個 systemd 檔、`/root/.nas-monitor.conf`、`/var/lib/nas-reach/` 後 `daemon-reload`。tokyo16 可刪除「快照複寫停止」規則與對應的收件者設定檔。

## 7. 備份監控（2026-10-19）

**為什麼要做**：備份分成三段，任何一段出錯都要知道；最難發現的是「備份根本沒執行」，因為那時信箱只是少了幾封信。

```text
每晚 21:00～22:30  PVE 三台各自備份（vzdump）→ PBS31
每晚 00:00          PBS31 GC（清掉不要的資料、釋放空間）
每晚 02:00          PBS31 Verify（檢查備份資料有沒有損壞）
每天 08:30          三台 PVE 檢查每台 VM／CT 的最新備份（本節新增）
```

### 盤點：失敗時本來就會寄信的部分

| 階段 | 通知方式 | 證據 |
| --- | --- | --- |
| PVE 備份 | 三個 vzdump 排程都是 `notification-mode notification-system`；PVE 沒有 `/etc/pve/notifications.cfg`，用預設：每次都寄到 root@pam，經 postfix 轉寄 Gmail | `grep -A12 '^vzdump:' /etc/pve/jobs.cfg`；另有 Graylog「PVE 任務失敗警報」 |
| PBS GC、Verify | PBS 目標 `mail-to-root`（sendmail）、規則 `default-matcher`（除了成功的 Prune 以外全部都寄）；root@pam 有 email；postfix relayhost 為 Gmail | `proxmox-backup-manager notification target list`、`… matcher list` |
| 實際收信 | 每天收到中文的【PBS 垃圾資料回收成功】、【PBS 備份驗證成功】；2026-10-19 在測試 datastore 實際製造 GC 失敗、Verify 失敗，兩封中文失敗信都有寄到 | 成功每次都寄，失敗也確認會寄（做法見中文通知文件 9-1） |

PBS 的任務結果不會以 `TASK ERROR`／`end task` 的形式出現在 Graylog（搜尋 7 天 0 筆），所以 PBS 這段只靠 PBS 自己的通知。

**Gmail 篩選器**：每天有約 5 封成功信，失敗信容易被淹沒。主旨含「失敗」→ 標上星號、永遠標示為重要、永不移至垃圾郵件，並套用到既有的相符信件。

### 新增：每日備份檢查（抓「沒執行」與「驗證失敗」）

**做法**：直接看結果。PVE 本來就連得到 PBS31，用 `pvesh` 讀 PBS31 上的備份清單，**不需要新增帳號或密碼**。

| 檢查 | 判定異常 | 抓的情況 |
| --- | --- | --- |
| 叢集裡每台 VM／CT（不含範本）在 PBS31 上有沒有備份 | 完全沒有 | 新建的 VM 沒被納入備份 |
| 最新備份的時間 | 超過 26 小時 | 備份沒執行（排程停用、PBS 掛載失效） |
| 最新備份的驗證結果 | `failed` 或沒有驗證紀錄 | 備份損壞，或 Verify 沒執行 |
| 讀不到 PBS31 的備份清單 | 指令失敗 | PBS31 掛了或連線問題 |

先用唯讀指令確認讀得到（10/19 實測：15 台、最新備份都是 10/18 21:00～22:07、驗證全部 `ok`）。指令裡含引號的 Python 要先用 `<<'EOF'` 寫成檔案再執行，直接放在 `python3 -c '…'` 裡用 `\"` 跳脫會出現 SyntaxError。

`/usr/local/sbin/pbs-backup-check.py`：

```python
#!/usr/bin/env python3
# 每日備份檢查：PBS31 上每台 VM／CT 是否有 26 小時內的新備份、最新一份是否驗證通過
# 有問題才用本機 postfix 寄信（不經過 Graylog）
import json, os, socket, subprocess, time

STORAGE = "PBS31"
MAX_AGE_H = float(os.environ.get("MAX_AGE_H", "26"))   # 測試時可用環境變數縮短
CONF = "/root/.graylog-monitor.conf"
host = socket.gethostname().split(".")[0]
mail_to = next(l.split("=", 1)[1].strip() for l in open(CONF) if l.startswith("MAIL_TO="))

def pvesh(*args):
    r = subprocess.run(["pvesh", "get", *args, "--output-format", "json"],
                       capture_output=True, text=True, timeout=180, check=True)
    return json.loads(r.stdout)

problems = []
try:
    guests = {str(g["vmid"]): g.get("name", "") for g in pvesh("/cluster/resources", "--type", "vm")
              if not g.get("template")}
    latest = {}
    for b in pvesh(f"/nodes/{host}/storage/{STORAGE}/content"):
        v = str(b.get("vmid", ""))
        if v and b.get("ctime", 0) > latest.get(v, {}).get("ctime", 0):
            latest[v] = b
    now = time.time()
    for v in sorted(guests, key=int):
        name = guests[v]
        b = latest.get(v)
        if not b:
            problems.append(f"{v} {name}：PBS31 上完全沒有備份")
            continue
        age = (now - b["ctime"]) / 3600
        when = time.strftime("%m/%d %H:%M", time.localtime(b["ctime"]))
        state = b.get("verification", {}).get("state")
        if age > MAX_AGE_H:
            problems.append(f"{v} {name}：最新備份是 {when}（{age:.1f} 小時前），超過 {MAX_AGE_H:g} 小時")
        if state == "failed":
            problems.append(f"{v} {name}：最新備份（{when}）驗證失敗")
        elif not state:
            problems.append(f"{v} {name}：最新備份（{when}）沒有驗證紀錄")
    summary = f"檢查 {len(guests)} 台，異常 {len(problems)} 項"
except Exception as e:
    problems.append(f"讀不到 {STORAGE} 的備份清單：{e}")
    summary = "檢查失敗"

print(summary)
for p in problems:
    print(" -", p)
if problems:
    body = (f"偵測主機：{host}\n時間：{time.strftime('%F %T')}\n{summary}\n\n異常項目：\n"
            + "\n".join(f"- {p}" for p in problems)
            + "\n\n這封信由 PVE 節點直接寄出，不經過 Graylog。\n")
    subprocess.run(["mail", "-s", f"【備份檢查異常】{len(problems)} 項（{host} 偵測）", mail_to],
                   input=body, text=True)
    subprocess.run(["logger", "-t", "pbs-backup-check", f"BACKUP_CHECK_PROBLEM host={host} {summary}"])
```

| 設計 | 原因 |
| --- | --- |
| 先列出叢集**所有** VM／CT 再對照 | 只看 PBS 上有的備份，會漏掉「從來沒備份過」的新 VM |
| 每台節點用自己的連線查 PBS31 | 某台節點連不到 PBS31 時，只有那台寄「讀不到」，看得出是哪一台 |
| `MAX_AGE_H` 可用環境變數覆蓋 | 測試時改成 1 小時觸發告警 |

systemd：`pbs-backup-check.service`（oneshot，`After=… pve-cluster.service`）與 `pbs-backup-check.timer`（`OnCalendar=*-*-* 08:30:00`、`Persistent=true`，節點 08:30 剛好關機時開機後補跑）。

### 測試與部署（10/19）

```bash
/usr/local/sbin/pbs-backup-check.py               # 檢查 15 台，異常 0 項，不寄信
MAX_AGE_H=1 /usr/local/sbin/pbs-backup-check.py   # 15 台都超過 1 小時 → 收到【備份檢查異常】15 項（node10 偵測）
systemctl enable --now pbs-backup-check.timer
for h in node11 node12; do
  scp -p /usr/local/sbin/pbs-backup-check.py root@$h:/usr/local/sbin/
  scp -p /etc/systemd/system/pbs-backup-check.service /etc/systemd/system/pbs-backup-check.timer root@$h:/etc/systemd/system/
  ssh root@$h "systemctl daemon-reload && systemctl enable --now pbs-backup-check.timer"
done
```

**看到的結果**：三台腳本指紋相同、都有收件人設定檔、手動檢查都是「檢查 15 台，異常 0 項」、timer 下次執行 10/20 08:30。

### 收到【備份檢查異常】時怎麼查

| 異常項目 | 先查什麼 |
| --- | --- |
| 完全沒有備份 | 是新建的 VM／CT 嗎？確認備份排程的 Selection 是 All 且有 Node，或手動備份一次 |
| 超過 26 小時 | 前一晚有沒有收到該節點的 PVE 備份信；`pvenode task list --typefilter vzdump --limit 3`；PBS31 的 Tokyo16 是否掛載（「PVE 儲存設備離線」告警） |
| 驗證失敗 | 看當天的【PBS 備份驗證】信；PBS 網頁 Datastore → Content 找到該份備份，必要時手動重新驗證或重新備份 |
| 沒有驗證紀錄 | 前一晚 02:00 的 Verify 有沒有執行（PBS 網頁 Tasks） |
| 讀不到備份清單 | `pvesm status --storage PBS31`；PBS31 是否開機、8007 是否連得到 |

### 還原

三台各執行 `systemctl disable --now pbs-backup-check.timer`，刪除腳本與兩個 systemd 檔後 `daemon-reload`。

## 8. 告警信改成中文範本（2026-10-19）

**為什麼要改**：Graylog 預設的告警信是英文，而且把整筆事件欄位倒出來（`--- [Event Definition] ---`…），`Source` 顯示的是 Graylog 自己，要往下翻很久才看得出是哪台出問題。

| 名詞 | 白話解釋 |
| --- | --- |
| **Notification** | 告警觸發後「怎麼通知」：收件人、主旨、內文範本。每個 Event Definition 綁一個 |
| **Body Template／HTML Body Template** | 內文的純文字版和網頁版。Gmail 優先顯示 HTML 版，**只改純文字版看到的還是英文** |
| **Backlog** | 信裡附上的原始日誌（3-2 的 Backlog 欄位決定最多幾筆） |
| `${…}` | 範本變數，寄信時換成實際內容；`${foreach backlog message}…${end}` 是「每筆日誌重複一次」 |

```text
13 個 Event Definition ──各綁一個──▶ 13 個 Notification ──▶ 同一份中文範本（純文字 + HTML）──▶ Gmail
```

### 第一步：盤點（只讀取）

用 admin 帳號讀 Notification 和 Event Definition，看各有幾個、誰綁誰、範本是不是預設的。第 5 節的唯讀帳號 `pve-monitor` 是 Reader，推測讀不到 Notification，所以這裡用 admin（密碼用 `read -rsp` 輸入，單獨貼上）：

```bash
read -rsp "Graylog admin 密碼：" GLPW; echo
```

```bash
cat > /root/gl-notif-inventory.py <<'EOF2'
import json, os, sys, base64, urllib.request
url = os.environ["GL_URL"].rstrip("/")
auth = base64.b64encode(("admin:" + os.environ["GLPW"]).encode()).decode()
def get(path):
    req = urllib.request.Request(url + path, headers={"Authorization": "Basic " + auth, "Accept": "application/json"})
    return json.load(urllib.request.urlopen(req, timeout=15))
n = get("/api/events/notifications?per_page=100")["notifications"]
d = get("/api/events/definitions?per_page=100")["event_definitions"]
use = {}
for e in d:
    for x in e.get("notifications") or []:
        use.setdefault(x["notification_id"], []).append(e["title"])
print("Notification 數量：", len(n))
for x in n:
    c = x["config"]
    print("==", x["title"], "| type:", c.get("type"))
    print("   subject:", c.get("subject"))
    print("   收件人數:", len(c.get("email_recipients") or []), "| time_zone:", c.get("time_zone"))
    print("   body 長度:", len(c.get("body_template") or ""), "| html 長度:", len(c.get("html_body_template") or ""))
    print("   body 開頭:", (c.get("body_template") or "")[:60].replace("\n", "⏎"))
    print("   被這些告警使用:", "、".join(use.get(x["id"], [])) or "（沒有）")
EOF2
. /root/.graylog-monitor.conf
GL_URL="$GL_URL" GLPW="$GLPW" python3 /root/gl-notif-inventory.py
```

| 片段 | 意思 |
| --- | --- |
| `. /root/.graylog-monitor.conf` | 讀入第 5 節設定檔裡的 `GL_URL` |
| `收件人數` | 只顯示數量，不印出信箱 |
| `body 開頭` | 前 60 字，判斷是不是預設範本 |

**看到的結果**：

| 發現 | 代表什麼 |
| --- | --- |
| 13 個 Notification，每個告警各一個、沒有共用 | 改一個不會影響別的告警 |
| 13 個 body 都是 1210 字、html 都是 2315 字，開頭 `--- [Event Definition] ---` | 全部是預設範本，可以共用同一份中文範本 |
| 主旨大多已是中文（如 `【Ceph 告警】${event_definition_title}`） | 主旨保留不動 |
| 「PVE 服務異常通知」time_zone 是 UTC | 信裡時間差 8 小時，一起改成 Asia/Taipei |
| 「VPN 異常通知」主旨是 `【VPN 告警 】: …` | 多了空格與冒號，一起整理 |

### 第二步：寫入範本與工具（還不會改 Graylog）

```bash
mkdir -p /root/gl-tpl && chmod 700 /root/gl-tpl

cat > /root/gl-tpl/body.txt <<'EOF2'
${event_definition_title}
========================================
說明：${event_definition_description}
時間：${event.timestamp}
等級：${event.priority}（1 低／2 中／3 高）
摘要：${event.message}

相關日誌
----------------------------------------
${if backlog}${foreach backlog message}
[${message.timestamp}] ${message.source}${if message.fields.src_host}（${message.fields.src_host}）${end}
${message.message}
${end}${else}這次沒有附上原始日誌（Message Backlog 為 0，或是測試通知）。
${end}
----------------------------------------
此信由 Graylog 自動寄出。
EOF2

cat > /root/gl-tpl/body.html <<'EOF2'
<div style="font-family:sans-serif;font-size:14px;max-width:760px">
<div style="background:#1f3a5f;color:#fff;padding:10px 12px;font-size:16px;font-weight:bold">${event_definition_title}</div>
<table style="border-collapse:collapse;width:100%;margin:8px 0">
<tr><td style="padding:4px 12px;color:#666;width:4em">說明</td><td style="padding:4px 12px">${event_definition_description}</td></tr>
<tr><td style="padding:4px 12px;color:#666">時間</td><td style="padding:4px 12px">${event.timestamp}</td></tr>
<tr><td style="padding:4px 12px;color:#666">等級</td><td style="padding:4px 12px">${event.priority}（1 低／2 中／3 高）</td></tr>
<tr><td style="padding:4px 12px;color:#666">摘要</td><td style="padding:4px 12px">${event.message}</td></tr>
</table>
<div style="font-weight:bold;margin:14px 0 6px">相關日誌</div>
${if backlog}<table style="border-collapse:collapse;width:100%;font-size:13px">
<tr style="background:#eee"><th align="left" style="padding:4px 8px">時間</th><th align="left" style="padding:4px 8px">主機</th><th align="left" style="padding:4px 8px">內容</th></tr>
${foreach backlog message}<tr style="border-top:1px solid #ddd"><td style="padding:4px 8px;white-space:nowrap;vertical-align:top">${message.timestamp}</td><td style="padding:4px 8px;white-space:nowrap;vertical-align:top">${message.source}${if message.fields.src_host}<br>${message.fields.src_host}${end}</td><td style="padding:4px 8px;font-family:monospace">${message.message}</td></tr>
${end}</table>${else}<p>這次沒有附上原始日誌（Message Backlog 為 0，或是測試通知）。</p>${end}
<p style="color:#888;font-size:12px;margin-top:16px">此信由 Graylog 自動寄出。</p>
</div>
EOF2

cat > /root/gl-tpl/notif.py <<'EOF2'
import json, os, sys, base64, urllib.request
url = os.environ["GL_URL"].rstrip("/")
auth = base64.b64encode(("admin:" + os.environ["GLPW"]).encode()).decode()
H = {"Authorization": "Basic " + auth, "Accept": "application/json",
     "Content-Type": "application/json", "X-Requested-By": "cli"}
def call(method, path, data=None):
    body = None if data is None else json.dumps(data).encode()
    req = urllib.request.Request(url + path, method=method, headers=H, data=body)
    with urllib.request.urlopen(req, timeout=15) as r:
        b = r.read()
        return json.loads(b) if b else None
mode, arg = sys.argv[1], sys.argv[2]
if mode == "backup":
    ns = call("GET", "/api/events/notifications?per_page=100")["notifications"]
    os.umask(0o077)
    json.dump(ns, open(arg, "w"), ensure_ascii=False, indent=1)
    print("已備份", len(ns), "個 →", arg)
elif mode == "apply":
    body = open("/root/gl-tpl/body.txt").read()
    html = open("/root/gl-tpl/body.html").read()
    done = 0
    for n in call("GET", "/api/events/notifications?per_page=100")["notifications"]:
        if arg != "ALL" and n["title"] != arg:
            continue
        c = n["config"]
        c["body_template"], c["html_body_template"], c["time_zone"] = body, html, "Asia/Taipei"
        if c.get("subject", "").startswith("【VPN 告警 】"):
            c["subject"] = "【VPN 告警】${event_definition_title}"
        call("PUT", "/api/events/notifications/" + n["id"], n)
        print("已更新：", n["title"]); done += 1
    print("共更新", done, "個")
elif mode == "restore":
    who = sys.argv[3]
    for n in json.load(open(arg)):
        if who != "ALL" and n["title"] != who:
            continue
        call("PUT", "/api/events/notifications/" + n["id"], n)
        print("已還原：", n["title"])
EOF2
```

| 片段 | 意思 |
| --- | --- |
| `<<'EOF2'`（有引號） | `${…}` 原封不動寫進檔案，不被 bash 當成變數 |
| `${if message.fields.src_host}` | 有 jt-ipam 補上的主機名稱（上篇第 6 節）才顯示 |
| `backup／apply／restore` | 備份全部、套用範本（指定名稱或 `ALL`）、從備份還原 |
| `X-Requested-By` | Graylog 規定修改類 API 要帶這個標頭 |

### 第三步：備份，先改一個測試

```bash
export GL_URL GLPW
BK=/root/gl-notifications-backup-$(date +%Y%m%d-%H%M).json
python3 /root/gl-tpl/notif.py backup "$BK"
python3 /root/gl-tpl/notif.py apply "每日健康回報通知"
logger -t graylog-heartbeat "GRAYLOG_DAILY_HEARTBEAT host=$(hostname) test=zh-template"
```

拿「每日健康回報通知」測試：用 `logger` 就能安全觸發（第 5 節），會帶出真的 backlog。當天 08:00 那封的 60 分鐘 Grace 已過，所以會再寄一封。

**看到的結果**：`已備份 13 個`、`共更新 1 個`；幾分鐘內收到中文的【每日健康回報】，HTML 表格顯示時間 `2026-10-19T14:29:00.000+08:00`、等級 `1`、主機 node10 與完整原始訊息。

### 第四步：套用到全部

```bash
python3 /root/gl-tpl/notif.py apply ALL
GL_URL="$GL_URL" GLPW="$GLPW" python3 /root/gl-notif-inventory.py | grep -E '^==|time_zone|body 長度|subject'
unset GLPW
```

**看到的結果**：`共更新 13 個`；13 個都是 `time_zone: Asia/Taipei`、`body 長度: 507 | html 長度: 1596`（Python 算的是字元數；`ls -l` 顯示的 615／1704 是位元組數，中文一個字佔 3 位元組），VPN 主旨變成 `【VPN 告警】${event_definition_title}`。

**還原**（全部或指定一個；先重新 `read -rsp` 輸入密碼並 `export GLPW`）：

```bash
python3 /root/gl-tpl/notif.py restore /root/gl-notifications-backup-<日期時間>.json ALL
```

> 備份檔含收件人信箱，只有 root 能讀；觀察一週沒問題再刪。

### 第五步：統一主旨

13 個主旨裡只有兩個還是 `【Graylog 警報】…`，看不出類別。改成和其他一樣的「【類別 告警】告警名稱」：

| Notification | 原本 | 改成 |
| --- | --- | --- |
| PVE 任務失敗通知 | `【Graylog 警報】${event_definition_title}` | `【PVE 任務告警】${event_definition_title}` |
| PVE 服務異常通知 | `【Graylog 警報】${event_definition_title}` | `【PVE 服務告警】${event_definition_title}` |

```bash
cat > /root/gl-tpl/subject.py <<'EOF2'
import json, os, sys, base64, urllib.request
url = os.environ["GL_URL"].rstrip("/")
auth = base64.b64encode(("admin:" + os.environ["GLPW"]).encode()).decode()
H = {"Authorization": "Basic " + auth, "Accept": "application/json",
     "Content-Type": "application/json", "X-Requested-By": "cli"}
def call(method, path, data=None):
    body = None if data is None else json.dumps(data).encode()
    req = urllib.request.Request(url + path, method=method, headers=H, data=body)
    with urllib.request.urlopen(req, timeout=15) as r:
        b = r.read()
        return json.loads(b) if b else None
NEW = {"PVE 任務失敗通知": "【PVE 任務告警】${event_definition_title}",
       "PVE 服務異常通知": "【PVE 服務告警】${event_definition_title}"}
for n in call("GET", "/api/events/notifications?per_page=100")["notifications"]:
    if n["title"] in NEW:
        old = n["config"]["subject"]
        n["config"]["subject"] = NEW[n["title"]]
        call("PUT", "/api/events/notifications/" + n["id"], n)
        print("已更新：", n["title"], "|", old, "→", NEW[n["title"]])
EOF2
export GL_URL GLPW
python3 /root/gl-tpl/notif.py backup /root/gl-notifications-backup-$(date +%Y%m%d-%H%M).json
python3 /root/gl-tpl/subject.py
GL_URL="$GL_URL" GLPW="$GLPW" python3 /root/gl-notif-inventory.py | grep -E '^==|subject'
unset GLPW
```

**看到的結果**：`已更新：` 兩行（舊 → 新），盤點後 13 個主旨都不再出現 `【Graylog 警報】`。主旨只影響之後的信件標題，沒有另外觸發測試信，等這兩個告警自然觸發時確認。

### 第六步：「PVE 任務失敗」的摘要改成一眼看懂

中文範本裡的「摘要」（`${event.message}`）是告警的 **Event Summary Template** 組出來的。「PVE 任務失敗警報」原本是 `PVE 任務失敗：${source.message}`，從來沒有驗證過。

**① 看目前的設定（只讀取）**：

```bash
cat > /root/gl-tpl/eventdef.py <<'EOF2'
import json, os, sys, base64, urllib.request
url = os.environ["GL_URL"].rstrip("/")
auth = base64.b64encode(("admin:" + os.environ["GLPW"]).encode()).decode()
req = urllib.request.Request(url + "/api/events/definitions?per_page=100",
      headers={"Authorization": "Basic " + auth, "Accept": "application/json"})
for e in json.load(urllib.request.urlopen(req, timeout=15))["event_definitions"]:
    if e["title"] != sys.argv[1]:
        continue
    def walk(o, path=""):
        if isinstance(o, dict):
            for k, v in o.items(): walk(v, path + "." + k)
        elif isinstance(o, list):
            for i, v in enumerate(o): walk(v, path + "[%d]" % i)
        elif isinstance(o, str) and ("${" in o or "summary" in path.lower() or "template" in path.lower()):
            print(path, "=", o)
    walk(e)
    print("field_spec =", json.dumps(e.get("field_spec"), ensure_ascii=False))
    print("backlog =", (e.get("notification_settings") or {}).get("backlog_size"),
          "| grace(min) =", ((e.get("notification_settings") or {}).get("grace_period_ms") or 0) // 60000)
EOF2
python3 /root/gl-tpl/eventdef.py "PVE 任務失敗警報"
```

看到的結果：`.event_summary_template = PVE 任務失敗：${source.message}`、`field_spec = {}`、`backlog = 5 | grace(min) = 5`。

**② 用合成訊息驗證原本的寫法**（VM 999 不存在，不會動到任何機器）：

```bash
logger -p daemon.warning "end task UPID:node10:TEST:TEST:TEST:vzstart:999:root@pam: GRAYLOG-SUMMARY-TEMPLATE-TEST"
```

看到的結果：Graylog 收到這筆，欄位有 `pve_event_type=task_failed`、`pve_task_name=vzstart`、`pve_task_node=node10`、`pve_vmid=999`；約 5 分鐘後收到【PVE 任務告警】PVE 任務失敗警報，摘要是 `PVE 任務失敗：node10 root: end task UPID:node10:TEST:TEST:TEST:vzstart:999:root@pam: GRAYLOG-SUMMARY-TEMPLATE-TEST`。**`${source.message}` 可以用**，但和下面「相關日誌」重複，重點埋在長字串裡。

**③ 改成結構化摘要**：用 ② 確認存在的欄位，VM 編號用 `${if}` 有才顯示（`aptupdate` 這類任務沒有 VM）：

```bash
cat > /root/gl-tpl/summary.py <<'EOF2'
import json, os, sys, base64, urllib.request
url = os.environ["GL_URL"].rstrip("/")
auth = base64.b64encode(("admin:" + os.environ["GLPW"]).encode()).decode()
H = {"Authorization": "Basic " + auth, "Accept": "application/json",
     "Content-Type": "application/json", "X-Requested-By": "cli"}
def call(method, path, data=None):
    body = None if data is None else json.dumps(data).encode()
    req = urllib.request.Request(url + path, method=method, headers=H, data=body)
    with urllib.request.urlopen(req, timeout=15) as r:
        b = r.read()
        return json.loads(b) if b else None
title, new = sys.argv[1], sys.argv[2]
for e in call("GET", "/api/events/definitions?per_page=100")["event_definitions"]:
    if e["title"] == title:
        os.umask(0o077)
        json.dump(e, open("/root/gl-eventdef-backup-%s.json" % e["id"], "w"), ensure_ascii=False, indent=1)
        print("舊：", e.get("event_summary_template"))
        e["event_summary_template"] = new
        call("PUT", "/api/events/definitions/" + e["id"] + "?schedule=true", e)
        print("新：", call("GET", "/api/events/definitions/" + e["id"]).get("event_summary_template"))
EOF2
python3 /root/gl-tpl/summary.py "PVE 任務失敗警報" '${source.pve_task_node} 的 ${source.pve_task_name} 失敗${if source.pve_vmid}（VM／CT ${source.pve_vmid}）${end}'
```

| 片段 | 意思 |
| --- | --- |
| `gl-eventdef-backup-<id>.json` | 改之前把整份告警設定備份起來 |
| 單引號 `'${source…}'` | 不讓 bash 把 `${…}` 當成自己的變數 |
| `?schedule=true` | 更新後讓告警繼續排程 |
| `${if source.pve_vmid}…${end}` | 有 VM／CT 編號才顯示括號那段 |

看到的結果：`舊： PVE 任務失敗：${source.message}`、`新： ${source.pve_task_node} 的 ${source.pve_task_name} 失敗${if source.pve_vmid}（VM／CT ${source.pve_vmid}）${end}`。

**④ 再測一次**：等上一封的 Grace（5 分鐘）過了才送，否則會被擋下：

```bash
logger -p daemon.warning "end task UPID:node10:TEST:TEST:TEST:vzstart:999:root@pam: GRAYLOG-SUMMARY-TEMPLATE-TEST-2"
```

看到的結果：摘要是 **`node10 的 vzstart 失敗（VM／CT 999）`**。欄位變數 `${source.欄位名}` 和 `${if}` 在 Summary Template 裡都能用。

**還原**：`python3 /root/gl-tpl/summary.py "PVE 任務失敗警報" 'PVE 任務失敗：${source.message}'`。

### 第七步：其他告警的摘要

第六步確認 `${source.欄位}` 可以用之後，先盤點全部告警的摘要（只讀取）：

```bash
cat > /root/gl-tpl/summary-list.py <<'EOF2'
import json, os, base64, urllib.request
url = os.environ["GL_URL"].rstrip("/")
auth = base64.b64encode(("admin:" + os.environ["GLPW"]).encode()).decode()
req = urllib.request.Request(url + "/api/events/definitions?per_page=100",
      headers={"Authorization": "Basic " + auth, "Accept": "application/json"})
for e in sorted(json.load(urllib.request.urlopen(req, timeout=15))["event_definitions"], key=lambda x: x["title"]):
    c = e.get("config") or {}
    print("==", e["title"])
    print("   摘要:", e.get("event_summary_template") or "（空白：信裡會顯示說明）")
    print("   分組:", c.get("group_by") or "（無）", "| 查詢:", (c.get("query") or "")[:90])
EOF2
python3 /root/gl-tpl/summary-list.py
```

**看到的結果**：Ceph、Corosync、Node 離線、儲存 ×3、WireGuard 是空白；多次驗證失敗、DSM 登入失敗、DSM 管理員登入是固定文字；PVE 服務異常是 `PVE 服務異常：${source}`（`${source}` 是整筆訊息，不是欄位，寫法不對）。

**批次修改工具**：讀一個「告警名稱 → 新摘要」的 JSON，改之前把全部告警備份成一個檔案：

```bash
cat > /root/gl-tpl/summary-bulk.py <<'EOF2'
import json, os, sys, base64, urllib.request, time
url = os.environ["GL_URL"].rstrip("/")
auth = base64.b64encode(("admin:" + os.environ["GLPW"]).encode()).decode()
H = {"Authorization": "Basic " + auth, "Accept": "application/json",
     "Content-Type": "application/json", "X-Requested-By": "cli"}
def call(method, path, data=None):
    body = None if data is None else json.dumps(data).encode()
    req = urllib.request.Request(url + path, method=method, headers=H, data=body)
    with urllib.request.urlopen(req, timeout=15) as r:
        b = r.read()
        return json.loads(b) if b else None
NEW = json.load(open(sys.argv[1]))
defs = call("GET", "/api/events/definitions?per_page=100")["event_definitions"]
os.umask(0o077)
bk = "/root/gl-eventdefs-backup-%s.json" % time.strftime("%Y%m%d-%H%M")
json.dump(defs, open(bk, "w"), ensure_ascii=False, indent=1)
print("已備份", len(defs), "個 →", bk)
for e in defs:
    if e["title"] in NEW:
        e["event_summary_template"] = NEW[e["title"]]
        call("PUT", "/api/events/definitions/" + e["id"] + "?schedule=true", e)
        print("已更新：", e["title"], "→", call("GET", "/api/events/definitions/" + e["id"])["event_summary_template"])
EOF2
```

**踩到的雷：「有就觸發」的告警抓不到原始欄位**。第一次把 9 個告警都改成 `…${source.message}`，用假的 Ceph 訊息測試（`logger -t ceph-mon "Health check failed: GRAYLOG-SUMMARY-TEST (TEST_ONLY)"`），摘要卻是 `Ceph 健康警告：Ceph 健康警告: count()=1.0`。原因是 3-2 清單裡「有就觸發」的告警，底層是先**計數**（`count() > 0`）再產生事件，事件沒有對應到某一筆日誌，`${source.message}` 拿到的是計數結果。原始日誌仍完整列在信裡的「相關日誌」。

| 告警類型（3-2「分組、門檻」欄） | 例子 | `${source.欄位}` |
| --- | --- | --- |
| 每筆 | PVE 任務失敗、Node 離線、服務異常、DSM 管理員登入、WireGuard | ✅ 可用 |
| 有就觸發、≥ N 次（彙總） | 每日健康回報、多次驗證失敗、DSM 登入失敗（Ceph、Corosync、儲存 ×3 在第八步改成每筆） | ❌ 只會得到 `count()=…`，改用固定說明文字 |

**最後的設定**（兩次 `summary-bulk.py`，JSON 用 `<<'EOF'` 寫入）：

| 告警 | 摘要 |
| --- | --- |
| PVE Node 狀態離線 | `節點離線或監控異常：${source.message}` |
| PVE 服務異常 | `${source.source} 服務異常：${source.message}` |
| Synology DSM 管理員登入 | `DSM 管理員登入：${source.message}` |
| WireGuard VPN 異常 | `WireGuard 異常：${source.message}` |
| Ceph 健康警告 | `Ceph 健康檢查失敗，詳細內容請看下方「相關日誌」` |
| PVE Corosync 成員離線 | `有節點離開 PVE 叢集，請看下方「相關日誌」是哪一台回報` |
| PVE 儲存空間嚴重 | `儲存空間超過 90%，請看下方「相關日誌」是哪一台、哪個儲存` |
| PVE 儲存空間警告 | `儲存空間超過 80%，請看下方「相關日誌」是哪一台、哪個儲存` |
| PVE 儲存設備離線 | `共用儲存狀態異常，請看下方「相關日誌」是哪一台、哪個儲存` |

> 上表 Ceph、Corosync、儲存 ×3 的固定文字只用到 17:09，之後改成每筆並帶出原始訊息，見第八步。
| 多次驗證失敗、DSM 登入失敗、每日健康回報 | 維持原本的固定文字 |

「每筆」類型的四個沒有另外製造事件測試（和 PVE 任務失敗同一種機制），等自然觸發時確認：

| 告警 | 自然觸發 | 結果 |
| --- | --- | --- |
| Synology DSM 管理員登入 | 2026-10-19 16:39 | ✅ 摘要是 `DSM 管理員登入：tokyo16 Connection: User [<NAS 管理員帳號>] from [<IP>] signed in to [DSM] successfully via [OTP].`；「相關日誌」的主機欄同時顯示 `tokyo16` 和 jt-ipam 查到的來源主機名稱（`${message.fields.src_host}`，第 8 節第二步），一眼看出是從哪台登入 |
| PVE Node 狀態離線、PVE 服務異常、WireGuard VPN 異常 | ⏳ 尚未觸發 | |

**還原**：備份在 `/root/gl-eventdefs-backup-<時間>.json`（每次執行各一份），把其中的設定逐一 `PUT` 回 `/api/events/definitions/<id>?schedule=true` 即可。

### 第八步：Ceph、Corosync、儲存 ×3 改成「每筆」

這 5 個告警的門檻都是 `count() > 0`，也就是「有一筆就算」，和「每筆」的觸發時機一樣。改成每筆後摘要就能帶出原始訊息；寄信頻率仍由 Grace 控制（Ceph、Corosync、儲存嚴重、儲存離線 5 分鐘，儲存警告 24 小時），**不會多寄信**，只是事件數量變多（每筆日誌一個事件）。

**① 比對兩種類型實際差在哪**（只讀取；拿已知是每筆的「PVE 任務失敗警報」當範本）：

```bash
cat > /root/gl-tpl/eventdef-compare.py <<'EOF2'
import json, os, base64, urllib.request
url = os.environ["GL_URL"].rstrip("/")
auth = base64.b64encode(("admin:" + os.environ["GLPW"]).encode()).decode()
req = urllib.request.Request(url + "/api/events/definitions?per_page=100",
      headers={"Authorization": "Basic " + auth, "Accept": "application/json"})
want = ["PVE 任務失敗警報", "Ceph 健康警告", "PVE Corosync 成員離線",
        "PVE 儲存空間嚴重", "PVE 儲存空間警告", "PVE 儲存設備離線"]
for e in json.load(urllib.request.urlopen(req, timeout=15))["event_definitions"]:
    if e["title"] not in want:
        continue
    c = e["config"]
    print("==", e["title"])
    for k in ("type", "series", "conditions", "group_by", "event_limit", "search_within_ms", "execute_every_ms"):
        print("   %-17s %s" % (k, json.dumps(c.get(k), ensure_ascii=False)))
    n = e.get("notification_settings") or {}
    print("   %-17s grace=%s 分, backlog=%s" % ("notification", (n.get("grace_period_ms") or 0)//60000, n.get("backlog_size")))
EOF2
python3 /root/gl-tpl/eventdef-compare.py
```

**看到的結果**：兩種都是 `aggregation-v1`，`group_by []`、`event_limit 100`、每 5 分鐘查 5 分鐘，只差兩個欄位：

| 欄位 | 彙總（5 個） | 每筆（PVE 任務失敗） |
| --- | --- | --- |
| `series` | `[{"type": "count", "id": "count-", "field": null}]` | `[]` |
| `conditions` | `count- > 0` | `{"expression": null}` |

**② 轉換**（先備份全部告警，再改這兩個欄位和摘要）：

```bash
cat > /root/gl-tpl/to-filter.py <<'EOF2'
import json, os, sys, base64, urllib.request, time
url = os.environ["GL_URL"].rstrip("/")
auth = base64.b64encode(("admin:" + os.environ["GLPW"]).encode()).decode()
H = {"Authorization": "Basic " + auth, "Accept": "application/json",
     "Content-Type": "application/json", "X-Requested-By": "cli"}
def call(method, path, data=None):
    body = None if data is None else json.dumps(data).encode()
    req = urllib.request.Request(url + path, method=method, headers=H, data=body)
    with urllib.request.urlopen(req, timeout=15) as r:
        b = r.read()
        return json.loads(b) if b else None
NEW = json.load(open(sys.argv[1]))
defs = call("GET", "/api/events/definitions?per_page=100")["event_definitions"]
os.umask(0o077)
bk = "/root/gl-eventdefs-backup-%s.json" % time.strftime("%Y%m%d-%H%M")
json.dump(defs, open(bk, "w"), ensure_ascii=False, indent=1)
print("已備份", len(defs), "個 →", bk)
for e in defs:
    if e["title"] in NEW:
        e["config"]["series"] = []
        e["config"]["conditions"] = {"expression": None}
        e["event_summary_template"] = NEW[e["title"]]
        call("PUT", "/api/events/definitions/" + e["id"] + "?schedule=true", e)
        n = call("GET", "/api/events/definitions/" + e["id"])
        print("已轉換：", e["title"], "| series =", n["config"]["series"], "| 摘要 =", n["event_summary_template"])
EOF2

cat > /root/gl-tpl/to-filter.json <<'EOF2'
{
 "Ceph 健康警告": "Ceph 健康警告：${source.message}",
 "PVE Corosync 成員離線": "${source.source} 回報叢集成員離線：${source.message}",
 "PVE 儲存空間嚴重": "儲存空間嚴重：${source.message}",
 "PVE 儲存空間警告": "儲存空間警告：${source.message}",
 "PVE 儲存設備離線": "儲存設備離線：${source.message}"
}
EOF2
python3 /root/gl-tpl/to-filter.py /root/gl-tpl/to-filter.json
```

| 片段 | 意思 |
| --- | --- |
| `series = []` | 拿掉計數 |
| `conditions = {"expression": None}` | 拿掉 `> 0`；Python 的 `None` 存成 JSON 的 `null` |
| `?schedule=true` | 改完繼續排程（server.log 可能出現 `re-scheduling job trigger`，屬正常，見第 10 節） |

**看到的結果**：`已備份 14 個`；5 行 `已轉換：… | series = [] | 摘要 = …`。

**③ 用假訊息測試 4 個**（儲存警告不測：Grace 24 小時，會擋掉之後真的警告）：

```bash
logger -t ceph-mon "Health check failed: GRAYLOG-FILTER-TEST (TEST_ONLY)"
logger -t corosync "[QUORUM] Members left: GRAYLOG-FILTER-TEST (TEST_ONLY)"
logger -t pve-storage-monitor "STORAGE_CRITICAL host=node10 storage=TEST_ONLY type=filesystem usage=99% threshold=90%"
logger -t pve-storage-monitor "STORAGE_UNAVAILABLE host=node10 storage=TEST_ONLY type=shared status=TEST_ONLY"
```

**看到的結果**：Graylog 17:09:42 收到 4 筆；4 封信的摘要都帶出原始訊息，不再是 `count()=1.0`：

| 信 | 摘要 |
| --- | --- |
| 【Ceph 告警】Ceph 健康警告 | `Ceph 健康警告：node10 ceph-mon: Health check failed: GRAYLOG-FILTER-TEST (TEST_ONLY)` |
| 【PVE Cluster 告警】PVE Corosync 成員離線 | `node10 回報叢集成員離線：node10 corosync: [QUORUM] Members left: GRAYLOG-FILTER-TEST (TEST_ONLY)` |
| 【PVE Storage 嚴重】PVE 儲存空間嚴重 | `儲存空間嚴重：node10 pve-storage-monitor: STORAGE_CRITICAL host=node10 storage=TEST_ONLY type=filesystem usage=99% threshold=90%` |
| 【PVE Storage 離線】PVE 儲存設備離線 | `儲存設備離線：node10 pve-storage-monitor: STORAGE_UNAVAILABLE host=node10 storage=TEST_ONLY type=shared status=TEST_ONLY` |

**還原**：把 `/root/gl-eventdefs-backup-20261019-1709.json` 裡的設定逐一 `PUT` 回 `/api/events/definitions/<id>?schedule=true`。

## 9. postfix 改用新的加密參數（2026-10-19）

**做什麼**：三台 PVE 和 PBS31 的 postfix 把舊參數 `smtp_use_tls` 換成 `smtp_tls_security_level = encrypt`。postfix 是所有告警信的出口（PVE 備份通知、PBS 通知、第 5～7 節的監控腳本），所以一次只改一台，改完立刻寄測試信。

| 名詞 | 白話解釋 |
| --- | --- |
| **`smtp_use_tls = yes`** | 舊寫法，等於「對方支援就加密，不支援就用明碼」；postfix 3.10 會出現 `will be removed` 警告 |
| **`smtp_tls_security_level`** | 新寫法；`may` 和舊寫法一樣，`encrypt` 是「一定要加密，否則不寄」 |
| **`smtp_sasl_security_options =`（空白）** | 允許用明碼方式送帳密；搭配 `may` 時，若加密被中途拿掉，Gmail 帳密可能以明碼送出 |

**盤點結果**（四台都一樣）：postfix 3.10.13，`relayhost = smtp.gmail.com:587`、`smtp_use_tls = yes`、`smtp_sasl_auth_enable = yes`、`smtp_sasl_security_options =`。

選 `encrypt` 而不是 `may`：寄信時要送 Gmail 帳密，強制加密較安全；Gmail 的 587 一定支援 STARTTLS，不影響正常寄信。

**怎麼做**：先在一台本機改（這次是 node10）：

```bash
cp -a /etc/postfix/main.cf /etc/postfix/main.cf.bak-$(date +%Y%m%d)
postconf -X smtp_use_tls
postconf -e 'smtp_tls_security_level = encrypt'
postfix check && echo "CHECK-OK"
postconf -n >/dev/null
grep -nE '^\s*(smtp_use_tls|smtp_tls_security_level)\b' /etc/postfix/main.cf
systemctl reload postfix
```

| 片段 | 意思 |
| --- | --- |
| `cp -a … .bak-日期` | 改之前備份，出事直接複製回來 |
| `postconf -X smtp_use_tls` | 從 `main.cf` 刪掉舊參數 |
| `postconf -e '… = encrypt'` | 加上新參數 |
| `postfix check` | 設定沒錯才印 `CHECK-OK` |
| `postconf -n >/dev/null` | 只看警告；`will be removed` 應該消失 |
| `systemctl reload postfix` | 新設定生效，不中斷正在寄的信 |

寄測試信，收件人從第 5 節的設定檔讀：

```bash
TO=$(grep -oP '^MAIL_TO="?\K[^"]+' /root/.graylog-monitor.conf)
echo "postfix TLS 設定更新測試，來自 $(hostname)" | mail -s "【測試】$(hostname) postfix 改用 smtp_tls_security_level" "$TO"
journalctl --since "2 min ago" --no-pager | grep -E 'postfix/.*status=' | tail -3
```

**看到的結果**：`CHECK-OK`、沒有警告、`smtp_tls_security_level = encrypt`，`status=sent (250 2.0.0 OK …)`，Gmail 收到信。

確認第一台沒問題後，其餘兩台節點從 node10 依序執行，任一步失敗就還原並停止：

```bash
for h in node11 node12; do
  echo "===== $h ====="
  ssh -o BatchMode=yes root@$h '
    B=/etc/postfix/main.cf.bak-$(date +%Y%m%d)
    cp -a /etc/postfix/main.cf "$B"
    postconf -X smtp_use_tls
    postconf -e "smtp_tls_security_level = encrypt"
    if ! postfix check; then cp -a "$B" /etc/postfix/main.cf; echo "CHECK 失敗，已還原"; exit 1; fi
    postconf -n >/dev/null
    grep -nE "^\s*(smtp_use_tls|smtp_tls_security_level)\b" /etc/postfix/main.cf
    systemctl reload postfix
    TO=$(grep -oP "^MAIL_TO=\"?\K[^\"]+" /root/.graylog-monitor.conf)
    echo "postfix TLS 設定更新測試，來自 $(hostname)" | mail -s "【測試】$(hostname) postfix 改用 smtp_tls_security_level" "$TO"
    sleep 15
    journalctl --since "1 min ago" --no-pager | grep -E "postfix/.*status=" | tail -1
  ' || { echo "!!! $h 失敗，停止"; break; }
done
```

PBS31 不在叢集的 SSH 互信裡（也不該為此加進去），到 PBS31 本機執行同一段修改指令；它沒有 `/root/.graylog-monitor.conf`，收件人改用 `read -p "收件 Gmail：" TO`（單獨貼上）。

**看到的結果**：

| 主機 | 新參數所在行 | 測試信 |
| --- | --- | --- |
| node10 | 30 | ✅ `status=sent`，已收到 |
| node11 | 31 | ✅ `status=sent`，已收到 |
| node12 | 30 | ✅ `status=sent`，已收到 |
| pbs31 | 30 | ✅ `status=sent`，已收到 |

**萬一寄不出去**（`status=deferred`、`TLS is required, but was not offered`），在該台還原：

```bash
cp -a /etc/postfix/main.cf.bak-<日期> /etc/postfix/main.cf && systemctl reload postfix
```

## 10. 常見問題

| 現象 | 原因 | 怎麼辦 |
| --- | --- | --- |
| --- | --- | --- |
| 告警信看不出是哪台出問題 | 預設範本只把整筆訊息倒出來 | 10/19 已改中文範本，「相關日誌」直接列出主機（第 8 節）；腳本產生的訊息依 4-1 的表判讀 |
| 收到【PVE 任務告警】，摘要寫「node10 的 vzstart 失敗（VM／CT 999）」 | 這是第 8 節第六步的結構化摘要：哪個節點、什麼任務、哪台 VM／CT | 完整錯誤在「相關日誌」那一行；到該節點 **Tasks** 看同一筆任務的日誌 |
| 摘要出現 `count()=1.0` | 「有就觸發」的告警是彙總事件，`${source.…}` 拿不到原始日誌 | 門檻是「有一筆就算」的告警，改成每筆（`series` 清空、`conditions` 設為 `{"expression": null}`，第 8 節第八步）；≥ N 次的告警只能用固定說明文字 |
| 用 API 更新告警後，server.log 出現 `ERROR [EventProcessorExecutionJob] The end of the timerange to process is in the future, re-scheduling job trigger …` | `?schedule=true` 重新排程時，觸發時間比現在早一點，Graylog 發現範圍還沒走完，就自動延後重跑 | 自動修正的通知，告警不受影響；10/19 兩次批次修改（15:36、15:43）各出現 5 筆。到 Alerts → Event Definitions 確認都是 Enabled 即可 |
| 信裡時間寫 `2026-10-19T15:36:40.000+08:00`，要不要再加 8 小時？ | 不用。`+08:00` 是**時區標記**（ISO 8601 格式），表示這已經是 UTC+8 的台灣時間；同一瞬間的 UTC 會寫成 `07:36:40.000Z` | 直接讀 `T` 後面的時間即可。決定維持這個格式，不另外改成 `yyyy-MM-dd HH:mm:ss`（改格式是否會把時區轉回 UTC 未確認） |
| 收到【NAS 連不上】或 `[tokyo16]` 複寫失敗信 | NAS 或複寫出問題 | 依第 6 節「收到信時怎麼查」 |
| Graylog 搜不到快照複寫的紀錄 | 複寫日誌在套件自己的日誌頁，不在 DSM 記錄中心 | 到 Snapshot Replication → 日誌查看或匯出 CSV |
| DSM API 登入回 402 | 一般帳號用了自訂的 `session` 名稱，或沒有 DSM 應用程式權限 | `session=webui`，並允許 DSM 權限 |
| `read -s` 讀進來的密碼少一個字 | 沒加 `-r` 時反斜線會被吃掉 | 改用 `read -rs` |
| 收到【備份檢查異常】信 | 有 VM／CT 太久沒備份、驗證失敗或沒被備份 | 依第 7 節「收到信時怎麼查」 |
| 失敗信混在每天的成功信裡沒看到 | PVE、PBS 成功也會寄信 | Gmail 篩選器：主旨含「失敗」→ 加星號、標示為重要 |
| 收到【Graylog 異常】信 | Graylog 本身出問題，信是節點直接寄的 | 依第 5 節「收到異常信時怎麼查」 |
| 早上沒收到【每日健康回報】 | 告警鏈某處斷了（含 Gmail 寄信失敗） | 先看有沒有【Graylog 異常】信；再到 Search 搜 `"GRAYLOG_DAILY_HEARTBEAT"`、看 Event Definition 的 Last Matched |
| `read -s` 存進去的不是 token | `read -s` 那行和下一段指令一起貼上，下一行被當成輸入 | `read -s` 單獨貼上、輸入完再貼下一段；token 改用 API 建立直接寫檔（第 5 節） |
| 每秒處理量常常是 0 | 日誌是一陣一陣進來的 | 判斷「有沒有在收」改用累計數字（第 5 節） |

## 11. 待辦

| 項目 | 說明 |
| --- | --- |
| 「儲存空間警告」的新摘要 | 第八步沒有用假訊息測（Grace 24 小時會擋掉真的警告），自然觸發時確認摘要是 `儲存空間警告：… STORAGE_WARNING host=…` |
| 「每筆」告警的新摘要 | DSM 管理員登入已確認（10/19）；Node 離線、服務異常、WireGuard 自然觸發時，確認摘要顯示正常 |
| 每月看一次 Snapshot Replication | 補上第 6 節抓不到的「排程被改掉」情況：確認六個任務都是「成功」、最近一次執行是前一天 |
| 單節點故障演練 | 和 PVE HA 文件第 15 節一起做：一台失聯時，確認「節點離線」告警、另兩台第 5、6 節的監控與 postfix 寄信都正常，記錄收信時間 |
| 其他新告警的測試 | 每個新告警都安排安全、可控的測試事件，記錄原始訊息、欄位、事件、收信時間與 Grace 下的重複通知情形 |

## 12. 延伸閱讀與下載

- [把 PVE、PBS 與 NAS 的日誌集中到 Graylog（一）：收集、分類與寄信設定](https://kbwangtw.github.io/IT-Knowledge-Base/docs/pve/proxmox-graylog-syslog-pipeline-sop/)：上篇
- [PVE 告警實測紀錄（更新至 2026-09-22）](https://kbwangtw.github.io/IT-Knowledge-Base/docs/pve/graylog-pve-alert-validation-2026-09-18/)：告警的真實日誌證據與 logger 安全測試
- [不再把 PVE 8006 開到網際網路：改用 WireGuard 連回家](https://kbwangtw.github.io/IT-Knowledge-Base/docs/pve/wireguard-remote-access-replace-8006/)：WireGuard VPN 異常告警的建置
- [把 PVE／PBS 通知改成繁體中文](https://kbwangtw.github.io/IT-Knowledge-Base/docs/pve/proxmox-zh-tw-notification/)：PVE／PBS 本身寄的通知信（和 Graylog 告警是兩套機制）
- [PVE HA 放置策略](https://kbwangtw.github.io/IT-Knowledge-Base/docs/pve/pve-ha-placement-policy/)：單節點故障演練（第 15 節）
- [Graylog 官方文件：Alerts and Notifications](https://go2docs.graylog.org/current/interacting_with_your_log_data/alerts.html)

[下載同版 Markdown]({{ '/assets/downloads/Graylog_Alerts_Monitoring_public.md' | relative_url }})：文字版與本文同步。
