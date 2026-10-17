---
layout: default
title: "Wazuh 維運（二）：資料保留、告警調校、弱點修補與整合"
date: 2026-10-02
categories: [PVE, LXC, Wazuh, Security]
permalink: /docs/pve/wazuh-lxc-ubuntu2204-operations/
last_modified_at: 2026-10-17
---
{% raw %}

# Wazuh 維運（二）：資料保留、告警調校、弱點修補與整合

> **一句話**：Wazuh 裝好只是開始；接下來要控制磁碟不被塞滿、把每天上萬筆的雜訊告警降下來、照弱點清單更新套件，再把 Wazuh 接到 jt-ipam、Graylog、Grafana，讓它真正成為日常會看的工具。

| 項目 | 內容 |
| --- | --- |
| 適合誰看 | 已經裝好 Wazuh、覺得告警太多或不知道怎麼維護的人 |
| 環境 | Wazuh 4.14.8 All-in-one（CT 112）；17 台 Agent |
| 日期 | 2026-10-02 起，持續更新到 2026-10-16 |
| 結論 | ✅ 資料保留 30 天；✅ 告警兩輪調校；✅ Critical 弱點 998 → 292；✅ 已接 jt-ipam、Graylog（VPN 告警）、Grafana |
| 上一篇 | [在 PVE Cluster 用 LXC 架設 Wazuh（一）：安裝與接上 Agent](https://kbwangtw.github.io/IT-Knowledge-Base/docs/pve/wazuh-lxc-ubuntu2204-sop/) |

> 章節編號延續安裝篇（第 0～9 節），從第 10 節開始，方便和其他文章的引用對照。文中 IP 都是文件示範位址。

## 怎麼讀這篇

| 你想做的事 | 看哪幾節 |
| --- | --- |
| 磁碟越來越滿 | 10 |
| 告警太多、想降噪 | 11（先看 11-1 找出最常觸發的規則，再看 11-3 寫法） |
| 看弱點、決定要不要修 | 12 |
| 和其他系統整合 | 13（jt-ipam）、14（WireGuard 告警）、15（Grafana） |
| 遇到問題 | 文末「常見問題」 |

## 先認識幾個名詞

| 名詞 | 白話解釋 |
| --- | --- |
| **規則（rule）／level** | 每種事件對應一條規則，level 0～15 表示嚴重程度，數字越大越嚴重 |
| **`local_rules.xml`** | 放自訂規則的檔案；降級、排除誤報都寫在這裡，升級不會被覆蓋 |
| **子規則（if_sid）** | 「當某條規則觸發、而且符合我的條件時」才套用，用來縮小調整範圍 |
| **logtest** | 把一行日誌丟進去，看會觸發哪條規則；改規則後用它驗證 |
| **ISM** | Index State Management：自動刪除太舊的索引資料 |
| **弱點偵測（Vulnerability Detection）** | 比對套件版本和 CVE 清單，列出有已知漏洞的套件 |
| **Wazuh API（55000）** | 給其他程式讀取 Agent 清單等資料的介面 |
| **syslog_output** | Wazuh 把告警轉送到其他系統（本案是 Graylog）的設定 |

## 進度表

| # | 步驟 | 狀態 | 實測紀錄 |
| --- | --- | --- | --- |
| 10 | 資料保留 | 已實測 | 2026-10-02：告警索引 ISM 保留 30 天（套用 3 個現有索引）；告警文字檔以 cron 保留 30 天 |
| 11 | 告警調校 | 第二輪完成 | 2026-10-02：第一輪修正 ai 容器根因並降級 Windows 電腦帳號、LibreNMS SNMP sudo、LXC rootcheck；第二輪降級 BITS 啟動類型、排除 VSS 登錄檔與 /etc/pve 狀態檔、清除 jt-ipam 過期設備並將 Graylog 加回 LibreNMS；10/16 以子規則 100141 處理 31301（11-13） |
| 12 | 弱點偵測與修補 | 完成 | 2026-10-06：Critical 998 → 292、High 7,132 → 2,216（約減少七成）；剩 ubclient 使用中 kernel 誤判、ai 的 ffmpeg（已限制 Bot 存取）與上游未修補項目；10/14 ubclient 套件更新並修正 logrotate 重複設定（12-6） |
| 13 | jt-ipam 整合 | 完成 | 2026-10-06：建立只能讀取 Agent 的 API 帳號；nftables 限制 55000 只允許本機與 jt-ipam；同步 17 台 Agent |
| 14 | WireGuard VPN 健康監控 | 完成 | 2026-10-13：ct:109 內部檢查（100150）＋ Manager 外部檢查 ct:109（100151）；`syslog_output` 只把 wireguard 群組送 Graylog；兩種情況的 Gmail 告警都實測收到 |
| 15 | Grafana 唯讀存取 | 完成 | 2026-10-14：socat 轉送 9201 → Indexer（Indexer 設定不動）、nftables 只允許 Grafana；Indexer 唯讀角色 `grafana_wazuh_read`；戰情中心第一版完成 |

## 10. 資料保留（30 天）

### 10-1 先看空間用在哪裡（2026-10-02 實測，17 台 Agent 上線約 2 天）

| 位置 | 大小 | 內容 |
| --- | --- | --- |
| `/var/ossec/queue/vd` | 9.9 GB | 弱點偵測內容資料庫（CVE 情資），大小相對固定 |
| `/var/ossec/queue/indexer` | 1.7 GB | 等待送往 Indexer 的佇列，需觀察是否持續成長 |
| `/var/ossec/queue/db` | 201 MB | 各 Agent 的本機資料庫 |
| `/var/lib/wazuh-indexer` | 131 MB | 全部索引 |
| `/var/ossec/logs/alerts` | 95 MB | 告警的文字檔備份（alerts.json／alerts.log），**預設永不刪除** |

每日告警索引：9/30 約 48 MB（含初始掃描）、10/01 約 42.5 MB（第一個完整的一天）。索引日期以 UTC 切分。告警本身佔用很小，磁碟主要被弱點資料庫使用。

### 10-2 Indexer：告警索引保留 30 天（ISM）

在 CT 112 內建立政策檔：

```bash
cat > /root/wazuh-alerts-30d.json <<'JSONEOF'
{
  "policy": {
    "description": "Delete wazuh-alerts indices older than 30 days",
    "default_state": "hot",
    "states": [
      {
        "name": "hot",
        "actions": [],
        "transitions": [ { "state_name": "delete", "conditions": { "min_index_age": "30d" } } ]
      },
      {
        "name": "delete",
        "actions": [ { "delete": {} } ],
        "transitions": []
      }
    ],
    "ism_template": [ { "index_patterns": ["wazuh-alerts-*"], "priority": 100 } ]
  }
}
JSONEOF
```

建立政策，並套用到**已經存在**的告警索引（`ism_template` 只會自動套用到之後新建的索引）：

```bash
curl -sk -u admin -X PUT 'https://127.0.0.1:9200/_plugins/_ism/policies/wazuh-alerts-30d' \
  -H 'Content-Type: application/json' -d @/root/wazuh-alerts-30d.json

curl -sk -u admin -X POST 'https://127.0.0.1:9200/_plugins/_ism/add/wazuh-alerts-*' \
  -H 'Content-Type: application/json' -d '{"policy_id": "wazuh-alerts-30d"}'

curl -sk -u admin 'https://127.0.0.1:9200/_plugins/_ism/explain/wazuh-alerts-*?pretty' | grep -E '"index"|policy_id'
```

每個指令都會詢問 admin 密碼。也可以在 Dashboard 的 **Index Management → Index policies** 建立同樣的政策。

**本案實測（2026-10-02）**：

| 步驟 | 結果 |
| --- | --- |
| PUT 政策 | 回傳 `"_id":"wazuh-alerts-30d"`；系統自動為 delete 動作加上重試（3 次、指數退避、初始 1 分鐘） |
| 套用到現有索引 | `"updated_indices":3`、`"failures":false` |
| explain | 9/30、10/01、10/02 三個告警索引的 `policy_id` 皆為 `wazuh-alerts-30d` |

`min_index_age` 從索引建立時間起算，9/30 的索引預計在 10/30 左右被刪除；ISM 每隔一段時間才檢查一次，實際刪除時間會稍晚。

### 10-3 Manager：告警文字檔保留 30 天

Indexer 的政策管不到 `/var/ossec/logs/alerts/`。以排程刪除 30 天前、已按日期歸檔的檔案（只處理年份子目錄，不碰目前正在寫入的 alerts.json）：

```bash
cat > /etc/cron.d/wazuh-alerts-cleanup <<'CRONEOF'
# Remove archived Wazuh alert logs older than 30 days
17 3 * * * root find /var/ossec/logs/alerts/20* -type f -mtime +30 -delete; find /var/ossec/logs/alerts/20* -mindepth 1 -type d -empty -delete
CRONEOF
chmod 644 /etc/cron.d/wazuh-alerts-cleanup
find /var/ossec/logs/alerts/20* -type f -mtime +30 | head    # 先預覽：目前應沒有符合的檔案
```

本案實測（2026-10-02）：已建立 `/etc/cron.d/wazuh-alerts-cleanup`（權限 644）；預覽沒有符合的檔案。cron 會忽略權限或擁有者不正確的設定檔且不報錯，建立後用 `ls -l` 確認為 `-rw-r--r-- root`。

### 10-4 注意

- 30 天後的告警無法再查詢。PBS 排程的保留策略（keep-daily 7、keep-last 3）也只涵蓋約一週，**沒有更長期的告警副本**；若日後有稽核或事件調查需求，需重新評估保留天數或另行封存。
- `/var/ossec/queue` 內的檔案由 Manager 管理，不要手動刪除。持續觀察 `du -sh /var/ossec/queue/*`，特別是 `indexer` 是否不斷成長。

### 10-5 定期檢查佇列與保留（2026-10-14）

在 CT 112 內執行，全部唯讀；Indexer 查詢以管理員憑證進行，不需輸入 admin 密碼：

```bash
du -sh /var/ossec/queue/* 2>/dev/null | sort -h | tail -6
df -h / | tail -1
grep -E 'queue_usage|dropped' /var/ossec/var/run/wazuh-analysisd.state
grep -E 'queue_size|total_queue_size|discarded' /var/ossec/var/run/wazuh-remoted.state
C=/etc/wazuh-indexer/certs
curl -sk --cert $C/admin.pem --key $C/admin-key.pem "https://127.0.0.1:9200/_cat/indices/wazuh-alerts-*?v&s=index&h=index,docs.count,store.size"
curl -sk --cert $C/admin.pem --key $C/admin-key.pem "https://127.0.0.1:9200/_plugins/_ism/explain/wazuh-alerts-*" | grep -o '"policy_id":"[^"]*"' | sort | uniq -c
ls -l /etc/cron.d/wazuh-alerts-cleanup; du -sh /var/ossec/logs/alerts
```

| 項目 | 10/02 | 10/14 | 判讀 |
| --- | --- | --- | --- |
| `queue/indexer` | 1.7 GB | 1.7 GB | 沒有成長，送往 Indexer 正常 |
| `queue/vd` | 9.9 GB | 12 GB | 弱點情資資料庫隨內容更新成長，持續觀察 |
| 磁碟 | — | 79 GB 用 19 GB（26%） | 充足 |
| analysisd | — | 各 `*_queue_usage` 皆 0.00，`events_dropped` 0 | 沒有積壓或丟棄 |
| remoted | — | `queue_size` 0，`discarded_count` 0 | Agent 訊息沒有被丟棄 |
| 告警索引 | 9/30 48 MB、10/01 55.6 MB（10.7 萬筆） | 調校後每天約 1,300～5,300 筆、2～6 MB | 30 天約 150 MB |
| ISM | 3 個索引套用 | 15／15 由 `wazuh-alerts-30d` 管理，最舊為 hot | 9/30 索引預計 10/30 左右刪除 |
| 告警文字檔 | 95 MB | 43 MB；清理排程權限 `-rw-r--r-- root` | 正常 |

10/08 為 18,528 筆，是當天 PVE 逐台更新（套件異動、重開機）產生，屬預期。

## 11. 告警調校

### 11-1 先找出最常觸發的規則

在 CT 112 內對 Indexer 做彙總查詢，取過去 24 小時數量最多的 15 條規則：

```bash
cat > /root/top-rules.json <<'JSONEOF'
{
  "size": 0,
  "query": { "range": { "timestamp": { "gte": "now-24h" } } },
  "aggs": {
    "rules": {
      "terms": { "field": "rule.id", "size": 15 },
      "aggs": {
        "desc":   { "terms": { "field": "rule.description", "size": 1 } },
        "level":  { "max":   { "field": "rule.level" } },
        "agents": { "terms": { "field": "agent.name", "size": 3 } }
      }
    }
  }
}
JSONEOF
curl -sk -u admin 'https://127.0.0.1:9200/wazuh-alerts-*/_search' \
  -H 'Content-Type: application/json' -d @/root/top-rules.json > /root/top-rules.out
head -c 100 /root/top-rules.out; echo     # 必須是 { 開頭；若是 Unauthorized 代表密碼錯誤
```

再用 Python 整理成表格（見本案操作紀錄）。輸出存檔時錯誤訊息也會被寫進檔案，所以存完要先看開頭。

**本案前 15 名（2026-10-02，過去 24 小時）**：

| 規則 | 等級 | 數量 | 說明 | 主要主機 | 分類 |
| --- | --- | --- | --- | --- | --- |
| 52002 | 3 | 75,070 | AppArmor DENIED | node10 | 根因待查 |
| 60137 | 3 | 13,968 | Windows User Logoff | DC02、DC01 | 正常活動 |
| 60106 | 3 | 8,003 | Windows Logon Success | DC02、DC01 | 正常活動（需保留人員登入） |
| 40704 | 5 | 6,183 | Systemd: Service exited due to a failure | ai | 根因待查 |
| 31101 | 5 | 1,865 | Web server 400 error code | librenms | 待查 |
| 750 | 5 | 1,693 | Registry Value Integrity Checksum Changed | DC01、WinClient、ca | 掃描類 |
| 510 | 7 | 1,344 | rootcheck 異常 | wazuh、AdGuard、Graylog（容器） | 掃描類 |
| 5501／5502 | 3 | 各約 1,300 | PAM 工作階段開啟／關閉 | 三台 PVE 節點 | 推測為 ProxCenter 定期登入 |
| 5402 | 3 | 1,281 | Successful sudo to ROOT | 三台 PVE 節點 | 同上 |
| 61104 | 3 | 1,012 | 服務啟動類型變更 | DC01、DC02、ca | 待查 |
| 60642 | 3 | 330 | Software protection service scheduled | ca、DC01、DC02 | 正常活動 |
| 550 | 7 | 326 | Integrity checksum changed | ubclient、node11、node12 | 掃描類 |

原則：先處理「可能有東西壞了」的類別，修好根因後告警自然消失；正常活動只針對特定主機或帳號降級，不整條關閉。

### 11-2 AppArmor DENIED（52002）與 ai 服務失敗（40704）

**追查**（node10）：

```bash
journalctl -k --since "1 hour ago" | grep 'apparmor="DENIED"' \
  | sed -E 's/.*operation="([^"]*)".*profile="([^"]*)".*name="([^"]*)".*comm="([^"]*)".*/\1 | \2 | \3 | \4/' \
  | sort | uniq -c | sort -rn | head -10
```

一小時 2,178 次皆為同一組合：namespace `lxc-113`（ai 容器）、profile `rsyslogd`、操作 `sendmsg`、目標 `/run/systemd/journal/dev-log`、程式 `systemd-journal`。容器內 Ubuntu 24.04 的 rsyslog AppArmor 規則擋下 journald 轉送日誌；容器與主機共用 kernel，紀錄寫在 node10 的 kernel 日誌，被 node10 的 Agent 收集。

40704 來自 ai 容器內的 `hermes-gateway.service`：

| 發現 | 說明 |
| --- | --- |
| 系統層級服務 | `/etc/systemd/system/hermes-gateway.service`，PID 287，自 9/29 穩定運作 |
| **使用者層級服務** | `/root/.config/systemd/user/hermes-gateway.service`（8/27 建立，非刻意設定），由 `systemd[264]`（root 的使用者層級 systemd）啟動，**restart counter 13,270** |
| 原因 | 兩個 gateway 搶同一個 Telegram Bot，使用者層級的啟動約 20 秒後失敗退出、再被重啟 |
| 網路 | `api.telegram.org` 的 DNS 優先回 IPv6，但容器沒有 IPv6 路由（`curl -6` 立即失敗，`curl -4` 回 302） |

每次失敗都印出數十行 traceback，journald 每一行都轉給 rsyslog、每一行都被 AppArmor 擋，因此兩條告警量都很大。

**處理**（node10，保留系統層級的 gateway）：

```bash
pct exec 113 -- systemctl --user --machine=root@.host disable --now hermes-gateway.service
pct exec 113 -- bash -c "ps -ef | grep -v grep | grep 'gateway run'"      # 只剩 --replace 那個
pct exec 113 -- bash -c "grep -q '^precedence ::ffff:0:0/96' /etc/gai.conf || echo 'precedence ::ffff:0:0/96  100' >> /etc/gai.conf"
pct exec 113 -- getent ahosts api.telegram.org | head -3                    # 第一筆應為 IPv4
pct exec 113 -- systemctl restart hermes-gateway
```

`/etc/gai.conf` 的 precedence 設定讓系統連線時優先使用 IPv4，不需要變更容器網路。

**驗證（處理後 10 分鐘）**：

| 檢查 | 處理前（10 分鐘） | 處理後 |
| --- | --- | --- |
| 使用者層級 gateway 失敗 | 約 30 次 | **0** |
| Telegram `Timed out` | 持續出現 | **0** |
| node10 AppArmor DENIED | 約 360 次 | **8** |

AppArmor 告警減少約 98%。剩餘的是正常日誌量造成的轉送阻擋，可再停用容器內 rsyslog 的 AppArmor 規則（容器本身仍受主機 LXC AppArmor 規則限制）：

```bash
pct exec 113 -- ln -s /etc/apparmor.d/usr.sbin.rsyslogd /etc/apparmor.d/disable/usr.sbin.rsyslogd
pct exec 113 -- apparmor_parser -R /etc/apparmor.d/usr.sbin.rsyslogd
pct exec 113 -- systemctl restart rsyslog
```

本案結果（2026-10-02）：三行指令第一次執行皆無輸出（成功）；重複執行時出現 `File exists`、`Profile doesn't exist`，代表第一次已完成，不是錯誤。`/sys/kernel/security/apparmor/profiles` 已無 rsyslogd，rsyslog 維持 active。

復原方式：刪除 `disable/` 內的連結，再以 `apparmor_parser -r` 重新載入並重啟 rsyslog。

**移除規則後仍被擋：要一併重啟 journald。** 移除規則、重啟 rsyslog 後，node10 仍出現同樣的 DENIED（profile 仍為 `rsyslogd`，對象是自 9/29 未重啟的 journald，PID 6881）；`logger` 測試訊息也沒有寫入 syslog。檢查發現 ai 容器的 `/var/log/syslog` **最後一筆停在 9/29 開機時**，也就是這三天 rsyslog 完全收不到 journald 轉送的日誌。推測 journald 既有的 socket 仍帶著舊規則的標記，重啟相關服務後解決：

```bash
pct exec 113 -- systemctl restart systemd-journald
pct exec 113 -- systemctl restart syslog.socket rsyslog
pct exec 113 -- logger -t wazuhtest "rsyslog test after journald restart"
pct exec 113 -- tail -3 /var/log/syslog      # 最後一行出現 wazuhtest 即正常
```

本案結果：syslog 出現 03:27（UTC）rsyslog 啟動紀錄與測試訊息，停擺三天的 syslog 恢復寫入。之後追蹤 node10 的 kernel 日誌，最後一筆 DENIED 發生在重啟當下的 11:27:09（台灣時間），之後不再出現，52002 告警歸零。rsyslog 啟動時的 `imklog: cannot open kernel log (/proc/kmsg): Permission denied` 是非特權容器的正常限制。

### 11-3 自訂降級規則的寫法與注意事項

正常活動的降級一律寫在 `/var/ossec/etc/rules/local_rules.xml`，做法是為原規則加一條 **level 0 的子規則**（`if_sid` 指向原規則，再加上比對條件）。level 0 不寫入告警，但事件仍會被分析，例如暴力破解偵測不受影響。

**修改流程（順序不可顛倒）**：

```bash
cp -a /var/ossec/etc/rules/local_rules.xml /var/ossec/etc/rules/local_rules.xml.bak-$(date +%F-%H%M)
# ...編輯 local_rules.xml...
/var/ossec/bin/wazuh-analysisd -t ; echo "exit=$?"            # 必須是 exit=0
systemctl restart wazuh-manager && systemctl is-active wazuh-manager
```

規則寫錯時 Manager 會無法啟動，17 台 Agent 全部斷線；**先 `-t` 再重啟**。`-t` 失敗時硬碟上的檔案已經是壞的，要立刻修正或還原備份，否則下次 CT 遷移、重開機就會起不來。

**欄位寫法**：

| 類型 | 例子 | 規則寫法 |
| --- | --- | --- |
| 靜態欄位（內建） | `srcuser`、`dstuser`、`srcip`、`dstip`、`url` | 專用標籤（`<srcip>`、`<user>`）或用 `<match>` 比對日誌文字 |
| 動態欄位（解碼器解析） | `command`、`uid`、`win.eventdata.*` | `<field name="...">` |

本案踩到的錯誤：以 `<field name="srcuser">` 撰寫時，`-t` 回報 `Field 'srcuser' is static.` 並 `exit=1`。

### 11-4 Windows 登入／登出（60137、60106）

**分析**（過去 24 小時，依帳號彙總 `data.win.eventdata.targetUserName`）：

| 帳號 | 60137 Logoff | 60106 Logon Success |
| --- | --- | --- |
| DC01$、DC02$（含 `$@網域` 寫法） | 11,874 | 7,913 |
| CA$、WINCLIENT$ | 1,788 | 86 |
| Administrator | 303 | 3 |

約 98% 是電腦帳號（`$` 結尾），屬 AD 複寫、Kerberos、群組原則等正常活動。人員帳號必須保留告警。

**做法**：只比對**已知**的電腦帳號，不比對所有 `$` 結尾的帳號。陌生或偽造的電腦帳號登入時仍會告警（攻擊者會濫用電腦帳號）；代價是新增 Windows 主機時要把名稱加入規則。

```xml
<group name="local,windows,tuning,">
  <rule id="100100" level="0">
    <if_sid>60137</if_sid>
    <field name="win.eventdata.targetUserName" type="pcre2">(?i)^(DC01|DC02|CA|WINCLIENT)\$(@.*)?$</field>
    <description>Windows logoff by known computer account (suppressed)</description>
  </rule>
  <rule id="100101" level="0">
    <if_sid>60106</if_sid>
    <field name="win.eventdata.targetUserName" type="pcre2">(?i)^(DC01|DC02|CA|WINCLIENT)\$(@.*)?$</field>
    <description>Windows logon success by known computer account (suppressed)</description>
  </rule>
</group>
```

| regex 片段 | 意思 |
| --- | --- |
| `(?i)` | 不分大小寫 |
| `^(DC01\|DC02\|CA\|WINCLIENT)` | 開頭必須是這 4 個名稱之一 |
| `\$` | 接著一個 `$` 字元 |
| `(@.*)?` | 後面可接、可不接 `@網域` |
| `$` | 到此結束 |

**驗證（套用後，在 DC02 實際登入、登出一次）**：

| 規則 | 帳號 | 判讀 |
| --- | --- | --- |
| 60106 Logon Success | `Administrator@網域`（1） | 人員登入保留 ✅ |
| 60137 Logoff | Administrator（2） | 人員登出保留 ✅ |
| 67022／67023 | administrator、DWM-n、UMFD-n | 主控台互動登入時伴隨產生（DWM、UMFD 是桌面視窗管理員與字型驅動的虛擬帳號），量少，保留 |
| — | DC01$、DC02$ | 未再出現 ✅ |

重啟後前 3 分鐘內 60137／60106 為 0（調校前約每分鐘 15 筆）。

### 11-5 PVE 節點的 sudo（5402、5501、5502）

**分析**：原先推測是 ProxCenter 定期 SSH 登入，實際日誌顯示來源是 **LibreNMS 的 SNMP 監控**：

```text
node10 sudo: Debian-snmp : PWD=/ ; USER=root ; COMMAND=/usr/local/bin/proxmox
node10 sudo: pam_unix(sudo:session): session opened for user root(uid=0) by (uid=109)
```

LibreNMS 每 5 分鐘以 SNMP 輪詢 → snmpd 的 `extend proxmox /usr/bin/sudo /usr/local/bin/proxmox` → 以 root 執行腳本讀取 PVE 資訊。每次輪詢在每台節點產生 5402（sudo）、5501（工作階段開啟）、5502（工作階段關閉）各一筆。

**降級前先確認權限安全**（任一節點）：

```bash
grep -rn 'Debian-snmp' /etc/sudoers /etc/sudoers.d/
ls -l /usr/local/bin/proxmox; ls -ld /usr/local/bin
grep -n 'proxmox' /etc/snmp/snmpd.conf
for n in node10 node11 node12; do echo -n "$n: "; ssh $n id -u Debian-snmp; done   # UID 由各節點分配，需逐台確認
```

| 項目 | 本案結果 | 判讀 |
| --- | --- | --- |
| sudoers | `Debian-snmp ALL=(ALL) NOPASSWD: /usr/local/bin/proxmox` | 只允許單一指令 ✅ |
| 腳本／目錄 | `root root`、755 | 其他人不可寫入 ✅ |
| Debian-snmp UID | 三台皆為 109 | 可共用同一條規則 |

**已收緊（2026-10-02，三台節點）**：原設定寫在 `/etc/sudoers` 第 55 行，而且位於 `@includedir /etc/sudoers.d` 之後（sudoers 以最後符合的規則為準，所以舊行一定要刪除）。改為獨立檔案，限定以 root 執行且不得帶參數（sudoers 中指令未寫參數代表允許任意參數，`""` 才代表禁止）：

```text
舊：Debian-snmp ALL=(ALL)  NOPASSWD: /usr/local/bin/proxmox      （/etc/sudoers）
新：Debian-snmp ALL=(root) NOPASSWD: /usr/local/bin/proxmox ""   （/etc/sudoers.d/librenms-snmp）
```

每一步都先 `visudo -cf` 檢查暫存檔，通過才寫入（sudoers 語法錯誤會讓整台主機的 sudo 失效）：

```bash
cat > /root/sudoers-snmp.sh <<'SUEOF'
#!/bin/bash
set -e
ts=$(date +%F-%H%M)
cp -a /etc/sudoers /root/sudoers.bak-$ts
tmp=$(mktemp)
echo 'Debian-snmp ALL=(root) NOPASSWD: /usr/local/bin/proxmox ""' > $tmp
visudo -cf $tmp >/dev/null
install -m 440 -o root -g root $tmp /etc/sudoers.d/librenms-snmp
cp /etc/sudoers $tmp
sed -i -E '/^[[:space:]]*Debian-snmp[[:space:]]+ALL=\(ALL\)[[:space:]]+NOPASSWD:[[:space:]]*\/usr\/local\/bin\/proxmox[[:space:]]*$/d' $tmp
visudo -cf $tmp >/dev/null
install -m 440 -o root -g root $tmp /etc/sudoers
rm -f $tmp
visudo -c >/dev/null && echo "$(hostname): visudo OK"
grep -rn 'Debian-snmp' /etc/sudoers /etc/sudoers.d/
echo "no args (should work): $(sudo -u Debian-snmp /usr/bin/sudo -n /usr/local/bin/proxmox 2>&1 | wc -l) lines"
echo "with arg (should be denied): $(sudo -u Debian-snmp /usr/bin/sudo -n /usr/local/bin/proxmox test 2>&1 | head -1)"
SUEOF
for n in node10 node11 node12; do ssh $n bash -s < /root/sudoers-snmp.sh; done   # 先做一台確認，再做其餘
```

本案結果：三台皆 `visudo OK`、規則只剩 `/etc/sudoers.d/librenms-snmp`；以 Debian-snmp 身分不帶參數執行可輸出 VM 資訊（行數隨各節點 VM 數量不同），帶參數則回 `sudo: a password is required`（遭拒，Wazuh 會記錄一筆 sudo 失敗，屬預期）。還原：`cp -a $(ls -t /root/sudoers.bak-* | head -1) /etc/sudoers && rm -f /etc/sudoers.d/librenms-snmp && visudo -c`。

**規則**：

```xml
<group name="local,sudo,tuning,">
  <rule id="100110" level="0">
    <if_sid>5402</if_sid>
    <match>Debian-snmp : PWD=</match>
    <field name="command">^/usr/local/bin/proxmox$</field>
    <description>sudo by Debian-snmp for LibreNMS proxmox extend (suppressed)</description>
  </rule>
  <rule id="100111" level="0">
    <if_sid>5501</if_sid>
    <match>pam_unix(sudo:session)</match>
    <field name="uid">^109$</field>
    <description>sudo session opened by Debian-snmp (suppressed)</description>
  </rule>
  <rule id="100112" level="0">
    <if_sid>5502</if_sid>
    <match>pam_unix(sudo:session)</match>
    <description>sudo session closed (suppressed; open and command are still logged)</description>
  </rule>
</group>
```

| 規則 | 條件 | 仍會告警的情況 |
| --- | --- | --- |
| 100110 | Debian-snmp **且**指令完全等於該腳本 | Debian-snmp 執行其他指令 |
| 100111 | sudo 工作階段 **且** uid 109 | 其他使用者執行 sudo |
| 100112 | sudo 工作階段關閉（日誌中沒有執行者，無法區分） | SSH 工作階段關閉 |

人員執行 sudo 時，5402（含指令）與 5501 都保留，少了關閉紀錄不影響追查。人員的 SSH 登入（5715）也不受影響。

**驗證（重啟後約 45 分鐘）**：5402 已無 `Debian-snmp`、5501 已無 uid 109 ✅。剩下的少量事件來源如下：

| 規則 | 數量 | 來源 | 處理 |
| --- | --- | --- | --- |
| 5715 SSH 登入成功 | 7 | ProxCenter 的 IP，帳號 `proxcenter`，只連 node11 | **保留** |
| 5501／5402 | 16／7 | `proxcenter`（uid 110）登入後執行 sudo | **保留** |
| 5715／5501 | 2／3 | node10 的 IP，帳號 root | 節點間 SSH，保留 |

ProxCenter 約每 6 分鐘以 SSH 登入一台節點並執行 sudo，一天約數百筆。`proxcenter` 是能以 root 操作叢集的自動化帳號，ProxCenter 被入侵時這就是攻擊路徑，因此**刻意保留**這些紀錄作為稽核軌跡；在 Dashboard 以 `data.srcuser: proxcenter` 篩選即可排除或單獨檢視。

### 11-6 容器的 rootcheck 隱藏檔誤報（510）

**分析**：`full_log` 是全文欄位，不能直接做 terms 彙總（會回傳錯誤，沒有 `aggregations`），改為抓回原始告警再用 Python 計數：

```bash
cat > /root/rootcheck.json <<'JSONEOF'
{
  "size": 2000,
  "_source": ["agent.name", "full_log"],
  "query": { "bool": { "filter": [
    { "range": { "timestamp": { "gte": "now-24h" } } },
    { "term": { "rule.id": "510" } }
  ] } }
}
JSONEOF
curl -sk -u admin 'https://127.0.0.1:9200/wazuh-alerts-*/_search' \
  -H 'Content-Type: application/json' -d @/root/rootcheck.json > /root/rootcheck.out
python3 - <<'PYEOF2'
import json, collections
d = json.load(open('/root/rootcheck.out'))
c = collections.Counter((h['_source']['agent']['name'], h['_source'].get('full_log', '')[:200]) for h in d['hits']['hits'])
for (agent, msg), n in sorted(c.items()): print(f"{agent:10} ({n}) {msg}")
PYEOF2
```

本案 24 小時 1,440 筆，**10 台 LXC 全部**觸發，內容只有兩種：

| 檔案 | 用途 |
| --- | --- |
| `/dev/.lxc-boot-id` | LXC 記錄容器開機識別碼 |
| `/dev/.lxc/proc/*`（cpuinfo、meminfo、uptime 等約 47 個） | lxcfs 提供，讓容器看到自己被分配的資源 |

rootcheck 把 `/dev` 底下以 `.` 開頭的檔案視為可能的 rootkit 藏匿檔，LXC 的正常檔案因此被誤判；每台約 48 筆、每 12 小時掃描一次。

**做法**：不關閉 `/dev` 檢查，只以完整路徑放過這兩類檔案；`/dev` 出現其他隱藏檔（例如 `/dev/.x`、`/dev/.lxc-backdoor`）仍會告警。

```xml
<group name="local,rootcheck,tuning,">
  <rule id="100120" level="0">
    <if_sid>510</if_sid>
    <regex type="pcre2">^File '/dev/\.lxc(-boot-id|/proc/[a-z_-]+)' present on /dev\. Possible hidden file\.$</regex>
    <description>rootcheck: LXC runtime file in /dev (suppressed)</description>
  </rule>
</group>
```

套用後（先 `-t` 再重啟），可手動觸發掃描驗證，不必等 12 小時：

```bash
/var/ossec/bin/agent_control -l                 # 查 Agent ID
/var/ossec/bin/agent_control -r -u 000          # Manager 本機
/var/ossec/bin/agent_control -r -u 005          # 例：librenms
```

**驗證**：觸發掃描約 20 分鐘後查詢 510，`510 total = 0`。

查詢檔若不存在，`curl -d @檔案` 會送出空查詢，Indexer 回傳全部告警（`total = 10000` 是計數上限）而沒有 `aggregations`；看到這種結果先確認查詢檔已建立。

### 11-7 調校成果（2026-10-02 第一輪）

| 規則 | 調校前（每天） | 調校後 | 方式 |
| --- | --- | --- | --- |
| 52002 AppArmor DENIED | 75,070 | 約 0 | 修正根因（11-2） |
| 40704 服務失敗 | 6,183 | 0 | 修正根因（11-2） |
| 60137／60106 Windows 登入登出 | 21,967 | 只剩人員帳號 | 子規則 100100、100101（11-4） |
| 5402／5501／5502 sudo | 約 3,900 | 只剩 ProxCenter 與人員 | 子規則 100110～100112（11-5） |
| 510 rootcheck | 1,440 | 0 | 子規則 100120（11-6） |

**尚未處理**（當時狀態）：31101／31301（librenms 的 Web 400 與 Nginx 錯誤）、61104（Windows 服務啟動類型變更）、750（登錄檔 FIM）、550（檔案 FIM）。

> 後續：61104、750、550 見 11-8；31101 見 11-9；31301 仍在觀察，見 11-9 末的觀察項目。

**維護提醒**：

- 新增 Windows 主機時，把電腦名稱加入規則 100100、100101。
- 新增 LXC 時不需修改（100120 以路徑比對，適用所有容器）。
- `local_rules.xml` 在 Wazuh 升級時會保留，但升級後仍要以 `-t` 確認規則可以載入。

### 11-8 第二輪：BITS、VSS 登錄檔、/etc/pve 狀態檔

**分析**（過去 24 小時）：

| 規則 | 每天 | 原因 |
| --- | --- | --- |
| 61104 服務啟動類型變更 | 926 | 所有 Windows 主機的 **BITS** 在「自動啟動」與「指定啟動（手動）」之間來回切換，是 Windows Update 的正常行為 |
| 750 登錄檔 FIM | 1,693 | VSS 每次建立陰影複製都更新 `HKLM\System\CurrentControlSet\Services\VSS\Diag` 的診斷時間戳 |
| 550 檔案 FIM | 326 | PVE 叢集檔案系統 `/etc/pve` 的狀態檔（`.rrd`、`.version`、`.clusterlog`、`lrm_status` 等）持續變動 |

**61104：子規則**。以服務名稱（`param4`，不受介面語言影響）比對；其他服務的啟動類型變更（例如 Windows Modules Installer，一天約 3 筆）仍告警。攻擊者濫用 BITS 是建立下載工作，記錄在另一個事件頻道，不受此規則影響。

```xml
<group name="local,windows,tuning,">
  <rule id="100130" level="0">
    <if_sid>61104</if_sid>
    <field name="win.eventdata.param4" type="pcre2">(?i)^BITS$</field>
    <description>BITS start type toggled by Windows (suppressed)</description>
  </rule>
</group>
```

事件欄位實例：`param1` = Background Intelligent Transfer Service、`param2` = 指定啟動、`param3` = 自動啟動、`param4` = BITS。

**750、550：集中式 Agent 設定**。不寫降級規則，而是讓 Agent 不掃描這些路徑，同時省下掃描資源。編輯 Manager 上的 `/var/ossec/etc/shared/default/agent.conf`（預設群組，所有 Agent 都會套用；原本只有空範本）：

```xml
<!-- Windows: VSS updates diagnostic timestamps on every shadow copy -->
<agent_config os="Windows">
  <syscheck>
    <registry_ignore arch="both">HKEY_LOCAL_MACHINE\System\CurrentControlSet\Services\VSS\Diag</registry_ignore>
  </syscheck>
</agent_config>

<!-- Linux (PVE nodes): pmxcfs runtime state files; config files stay monitored -->
<agent_config os="Linux">
  <syscheck>
    <ignore type="sregex">^/etc/pve/\.</ignore>
    <ignore>/etc/pve/ha/manager_status</ignore>
    <ignore>/etc/pve/ha/crm_commands</ignore>
    <ignore type="sregex">^/etc/pve/nodes/\w+/lrm_status$</ignore>
  </syscheck>
</agent_config>
```

```bash
chown root:wazuh /var/ossec/etc/shared/default/agent.conf
chmod 660 /var/ossec/etc/shared/default/agent.conf
/var/ossec/bin/verify-agent-conf                                  # 必須顯示 OK
grep -c 'VSS' /var/ossec/etc/shared/default/merged.mg            # ≥ 1 代表已打包給 Agent
```

注意：

- `registry_ignore` 預設只排除 32 位元檢視，要加 `arch="both"`。
- `/etc/pve` 內的 VM 設定（`qemu-server/*.conf`）、`user.cfg`、`corosync.conf`、防火牆規則**仍受監控**，這些檔案被修改一定要告警，所以只排除會自行變動的狀態檔。
- 修改 `agent.conf` **不需要重啟 Manager**；Agent 幾分鐘內自動下載新設定並自行重啟 Agent 程式（不影響主機上的服務）。

### 11-9 第二輪：LibreNMS Web 404（31101）—— jt-ipam 的過期設備

**分析**：31101 每天 1,712 筆，全部來自 ipam 主機（CT 103，執行開源的 jt-ipam）呼叫 LibreNMS API，約每 5 分鐘一輪：

| 路徑 | 原因 |
| --- | --- |
| `/api/v0/devices/12/fdb`、`/devices/12/ports?...` | jt-ipam 的 `librenms_devices` 表仍留有 device 12（graylog），但 LibreNMS 已無此設備（網頁 `/device/12` 為 404） |
| `/api/v0/resources/vlans`、`/resources/links` | 環境中沒有 VLAN 與 LLDP/CDP 鄰居資料，LibreNMS API 查無資料時回 404 |

來源追查（PVE 節點）：

```bash
grep -il 'hostname: *ipam' /etc/pve/nodes/*/lxc/*.conf          # 找出 CT 與所在節點
pct exec 103 -- systemctl list-timers --no-pager                 # jt-ipam-sync.timer 每 5 分鐘
pct exec 103 -- systemctl cat --no-pager jt-ipam-sync.service    # 加 --no-pager 避免停在分頁畫面
pct exec 103 -- journalctl -u jt-ipam-sync --since '-30min' --no-pager | tail -20
```

比對兩邊的設備清單：

```bash
# LibreNMS（CT 102）
pct exec 102 -- mysql librenms -e "select device_id, hostname, sysName, disabled, \`ignore\`, status from devices order by device_id;"
# jt-ipam（CT 103，PostgreSQL 資料庫 jt_ipam）
pct exec 103 -- su - postgres -c "psql -d jt_ipam -c 'select id, legacy_device_id, hostname, version from librenms_devices'"
```

LibreNMS 有 9 台、jt-ipam 有 10 台，多出的 legacy_device_id 12 為 graylog（kernel 版本也停留在較舊的 `-15-pve`）。jt-ipam 同步時**不會刪除** LibreNMS 已移除的設備。

**處理一：清除 jt-ipam 的過期紀錄**。先確認外鍵影響：

```bash
pct exec 103 -- su - postgres -c "psql -d jt_ipam -c \"select conrelid::regclass, conname, confdeltype from pg_constraint where confrelid = 'librenms_devices'::regclass;\""
```

本案：`arp_entries`、`fdb_entries` 為 `n`（SET NULL），`device_vlans` 為 `c`（CASCADE），沒有會擋下刪除的 `a`／`r`。備份後刪除：

```bash
pct exec 103 -- su - postgres -c "pg_dump -Fc -d jt_ipam -f /var/lib/postgresql/jt_ipam-before-graylog12-$(date +%F-%H%M).dump"
pct exec 103 -- su - postgres -c "psql -d jt_ipam -c \"select id, legacy_device_id, hostname from librenms_devices where legacy_device_id = 12 and hostname like 'graylog%';\""   # 應只有 1 筆
pct exec 103 -- su - postgres -c "psql -d jt_ipam -c \"delete from librenms_devices where legacy_device_id = 12 and hostname like 'graylog%';\""                         # DELETE 1
```

注意：直接改資料庫不會留在 jt-ipam 的稽核紀錄；有網頁刪除功能時優先使用。手動 `systemctl start jt-ipam-sync` 若距上次排程未滿 `sync_interval_seconds` 會被略過，要等下一次排程同步再驗證。

**處理二：Graylog 重新加入 LibreNMS**。Graylog 容器（CT 105）的 snmpd 套件仍在，但設定檔已刪除、服務停用。從 LibreNMS 容器複製設定：

```bash
pct pull 102 /etc/snmp/snmpd.conf /root/snmpd.conf.tmp
pct pull 102 /usr/bin/distro /root/distro.tmp                    # extend distro 使用的腳本
sed -i -e '/^rwuser /d' -e 's/^syslocation .*/syslocation Node10/' /root/snmpd.conf.tmp
pct push 105 /root/snmpd.conf.tmp /etc/snmp/snmpd.conf --perms 600
pct push 105 /root/distro.tmp /usr/bin/distro --perms 755
rm -f /root/snmpd.conf.tmp /root/distro.tmp
pct exec 105 -- systemctl enable snmpd
pct exec 105 -- systemctl restart snmpd

# 從 LibreNMS 測試（容器內沒有 MIB 檔，用數字 OID；community 不顯示在畫面上）
C=$(pct exec 102 -- awk '/^com2sec/{print $NF}' /etc/snmp/snmpd.conf)
pct exec 102 -- snmpget -v2c -c "$C" <graylog 主機名稱> .1.3.6.1.2.1.1.5.0 .1.3.6.1.2.1.1.6.0
pct exec 102 -- su - librenms -s /bin/bash -c "lnms device:add --v2c -c '$C' <graylog 主機名稱>"
unset C
```

本案加入後為 device 17（LibreNMS 的編號不重複使用）。

⚠️ 範本設定中有 `rwuser snmpuser`（具**寫入權限**的 SNMPv3 帳號）。LibreNMS 監控只需讀取，複製時已移除；其他沿用同一範本的主機需另行檢查移除。`pct exec` 時出現的 `perl: warning: Setting locale failed` 是容器內未產生 `en_US.UTF-8` 語系，不影響功能。

**處理三：剩下的空結果 404 以子規則降級**（srcip、id、url 為靜態欄位，用專用標籤）：

```xml
<group name="local,web,tuning,">
  <rule id="100140" level="0">
    <if_sid>31101</if_sid>
    <srcip>192.0.2.29</srcip>
    <id>^404$</id>
    <url>^/api/v0/resources/vlans$|^/api/v0/resources/links$</url>
    <description>LibreNMS API empty result for jt-ipam sync (suppressed)</description>
  </rule>
</group>
```

三個條件都符合才降級；其他來源、其他路徑、其他狀態碼（例如 401、403）仍告警。

**用 wazuh-logtest 直接驗證規則**：等告警數量下降要花時間，而且查詢範圍容易混到重啟前的紀錄。直接把一行實際日誌交給 `wazuh-logtest`，可立即看到解碼欄位與最後比對到的規則：

```bash
# 從查詢結果取出一行原始日誌存檔（full_log），再交給 logtest
/var/ossec/bin/wazuh-logtest < /root/vlans-line.txt 2>&1 | grep -E "id:|level:|description:|srcip|url|^\*\*Phase"
```

本案結果：Phase 2 解出 `id: '404'`、`srcip`、`url: '/api/v0/resources/vlans'`；Phase 3 為 `id: '100140'`、`level: '0'`，規則生效。

**第二輪驗證**：61104、750、550 在套用後 30 分鐘內皆為 0；jt-ipam 同步 `devices_seen=10`，不再查詢 device 12。

剩餘觀察項目：

| 項目 | 說明 |
| --- | --- |
| `devices/17/ports` 404 | Graylog 剛重新加入 LibreNMS，連接埠探索完成前查不到，預期自行消失。**10/16 確認**：最近 14 天 0 筆，已結案（11-13） |
| 31301 PHP `ctype_digit(): Argument of type null` | LibreNMS 程式在新版 PHP 的 deprecated 警告（8192），與 `ports?columns=` 請求同時出現；待評估更新 LibreNMS 或以訊息內容降級。**10/16**：實際來自 `/resources/links` 請求，已以子規則 100141 降級（11-13） |
| jt-ipam 網頁 401 | 瀏覽器開著登入已過期的 jt-ipam 頁面持續輪詢通知；401 屬認證失敗，保留告警 |

### 11-10 延伸修正：SNMP 寫入權限（rwuser）

11-9 複製 SNMP 設定時發現範本中有 `rwuser snmpuser`，因此掃描所有節點與容器。腳本只列出設定種類與帳號名稱，community 與密碼以 `***` 遮蔽：

```bash
cat > /root/snmp-rw-scan.sh <<'SCANEOF'
#!/bin/bash
# Read-only scan: list SNMP write-access settings without printing secrets
H=$(hostname)
probe='grep -hsE "^[[:space:]]*(rwuser|rwcommunity6?|createUser)" /etc/snmp/snmpd.conf /etc/snmp/snmpd.conf.d/*.conf 2>/dev/null | awk "{print \$1, (\$1==\"rwuser\" ? \$2 : \"***\")}" | sort -u | tr "\n" " "; echo "| usmUser=$(grep -c ^usmUser /var/lib/snmp/snmpd.conf 2>/dev/null) | snmpd=$(systemctl is-active snmpd 2>/dev/null)"'
echo "$H host : $(bash -c "$probe")"
for id in $(pct list | awk 'NR>1 && $2=="running"{print $1}'); do
  name=$(pct config $id | awk '/^hostname:/{print $2}')
  echo "$H CT$id($name) : $(pct exec $id -- bash -c "$probe" 2>/dev/null)"
done
SCANEOF
chmod 700 /root/snmp-rw-scan.sh
for n in node10 node11 node12; do ssh $n bash -s < /root/snmp-rw-scan.sh; done
```

**結果**：node12 節點、AdGuard、Pihole、librenms、wireguard 共 5 台有 `rwuser snmpuser`，且 v3 帳號實際存在（`usmUser=1`）。

**不能直接刪除**：LibreNMS 對 9 台設備都以 SNMPv3 `snmpuser`（authPriv）輪詢，而這 5 台的 `snmpuser` 只有 `rwuser`、沒有 `rouser`。刪掉會讓監控中斷，因此改為 `rouser`：帳號與密碼不變，只移除寫入權限。

```bash
cat > /root/snmp-ro.sh <<'ROEOF'
#!/bin/bash
# Change SNMPv3 rwuser to rouser (keep user, drop write access)
set -e
f=/etc/snmp/snmpd.conf
cp -a $f $f.bak-$(date +%F-%H%M)
sed -i 's/^\([[:space:]]*\)rwuser /\1rouser /' $f
echo "$(hostname): $(grep -E '^[[:space:]]*(rouser|rwuser)' $f | awk '{print $1,$2}' | tr '\n' ' ')"
systemctl restart snmpd
echo "snmpd=$(systemctl is-active snmpd)"
ROEOF
chmod 700 /root/snmp-ro.sh

# 容器（一台一台做，每台做完立即驗證）
pct push 109 /root/snmp-ro.sh /root/snmp-ro.sh --perms 700 && pct exec 109 -- /root/snmp-ro.sh
# 驗證：在 LibreNMS 所在節點執行，出現 Snmpget[n/...] 即讀取正常
pct exec 102 -- su - librenms -s /bin/bash -c "lnms device:poll 13 -m core" 2>&1 | tail -8
```

依序處理 wireguard → AdGuard → Pihole → librenms → node12 節點；每台都顯示 `rouser snmpuser`、`snmpd=active`，LibreNMS 輪詢 `Snmpget[3/0.05s]`。最後重跑掃描，所有主機都不再有 `rwuser`。

注意：`pct exec` 只能在容器所在的節點執行；在其他節點執行會失敗，錯誤訊息又被 `grep` 過濾時，畫面會什麼都沒有，容易誤判。

還原：`cp -a $(ls -t /etc/snmp/snmpd.conf.bak-* | head -1) /etc/snmp/snmpd.conf && systemctl restart snmpd`。

待改善（當時狀態）：Graylog 目前以 v2c 輪詢（community 明文傳送），其他設備為 v3，之後可改為 v3 一致。

> 後續：已於 11-11 改為 v3（device 17）。

### 11-11 延伸：未監控的 LXC 加入 LibreNMS（SNMPv3 SHA／AES）

掃描時發現 ipam、ProxCenter、ai、wazuh 四個容器沒有 snmpd，也不在 LibreNMS。另外發現現有 9 台設備的 SNMPv3 使用 **MD5／DES**（已過時），因此新加入的主機直接改用 **SHA／AES**；帳號與密碼沿用 `snmpuser`，LibreNMS 的演算法以設備為單位設定，可以並存。

**做法重點**：

- SNMPv3 帳號的金鑰會依各主機的 engineID 本地化，不能複製別台的 `/var/lib/snmp/snmpd.conf`，每台要重新建立帳號。
- 密碼直接從 LibreNMS 資料庫讀入變數（`devices.authpass`、`devices.cryptopass`），不顯示在畫面上，用完即清除。
- 設定只有 `rouser snmpuser priv`（唯讀、必須加密），沒有 v2c community。
- 帳號以 `createUser` 寫入 `/var/lib/snmp/snmpd.conf`，snmpd 啟動時會轉成 `usmUser` 並刪除含明文密碼的那一行；以 `createUser=0` 驗證。

安裝腳本（在 LibreNMS 所在節點執行，對象為同節點的容器）：

```bash
cat > /root/snmp-v3-add.sh <<'ADDEOF'
#!/bin/bash
# Install snmpd with a read-only SNMPv3 user (SHA/AES) in a local LXC; secrets are never printed
set -e
CT=$1; LOC=$2
[ -n "$CT" ] && [ -n "$LOC" ] || { echo "usage: $0 CTID Location"; exit 1; }
umask 077
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
AP=$(pct exec 102 -- mysql -N librenms -e "select authpass from devices where device_id=13")
PP=$(pct exec 102 -- mysql -N librenms -e "select cryptopass from devices where device_id=13")
CONTACT=$(pct exec 102 -- grep -m1 '^syscontact' /etc/snmp/snmpd.conf)
pct pull 102 /usr/bin/distro $T/distro
printf 'agentAddress udp:161\nrouser snmpuser priv\nsyslocation %s\n%s\nextend distro /usr/bin/distro\n' "$LOC" "$CONTACT" > $T/snmpd.conf
printf 'createUser snmpuser SHA "%s" AES "%s"\n' "$AP" "$PP" > $T/cu
unset AP PP
pct exec $CT -- bash -c "apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq snmpd >/dev/null"
pct exec $CT -- systemctl stop snmpd
pct push $CT $T/snmpd.conf /etc/snmp/snmpd.conf --perms 600
pct push $CT $T/distro /usr/bin/distro --perms 755
pct push $CT $T/cu /root/.snmp-cu --perms 600
pct exec $CT -- bash -c 'mkdir -p /var/lib/snmp && cat /root/.snmp-cu >> /var/lib/snmp/snmpd.conf && rm -f /root/.snmp-cu && chown Debian-snmp:Debian-snmp /var/lib/snmp/snmpd.conf 2>/dev/null || true'
pct exec $CT -- systemctl enable snmpd >/dev/null 2>&1
pct exec $CT -- systemctl restart snmpd
sleep 2
pct exec $CT -- bash -c 'echo "CT'"$CT"': snmpd=$(systemctl is-active snmpd) usmUser=$(grep -c ^usmUser /var/lib/snmp/snmpd.conf) createUser=$(grep -c ^createUser /var/lib/snmp/snmpd.conf) udp161=$(ss -ulnp | grep -c ":161 ")"'
ADDEOF
chmod 700 /root/snmp-v3-add.sh
```

PBS 這類不在 PVE 內的獨立主機使用 `snmp-v3-add-host.sh root@主機 Location`：在 LibreNMS 所在節點產生設定檔、distro 腳本、`createUser` 與安裝程式，打包後以**單一 SSH 連線**（`tar | ssh`）傳到目標主機執行，只需輸入一次密碼，結束後兩邊的暫存檔都刪除。`apt update` 若因企業版套件來源回報 401 會忽略並繼續；最後同時顯示 `proxmox-backup-proxy` 狀態，確認備份服務未受影響。避開排程備份時段（本案 21:00）執行。

其他節點上的容器使用同樣邏輯的 `snmp-v3-add-remote.sh NODE CTID Location`：暫存檔以 `scp` 傳到目標節點，所有 `pct` 指令改以 `ssh NODE` 執行，結束後兩邊的暫存檔都刪除。

加入 LibreNMS（`lnms device:add` 的 `-a` 預設為 MD5，必須明確指定 SHA；安全等級會依有無加密密碼自動判斷為 authPriv）：

```bash
cat > /root/snmp-v3-lnms.sh <<'LNMSEOF'
#!/bin/bash
# Add a host to LibreNMS with SNMPv3 SHA/AES (secrets read from LibreNMS DB, never printed)
set -e
H=$1
[ -n "$H" ] || { echo "usage: $0 hostname-or-ip"; exit 1; }
AP=$(pct exec 102 -- mysql -N librenms -e "select authpass from devices where device_id=13")
PP=$(pct exec 102 -- mysql -N librenms -e "select cryptopass from devices where device_id=13")
pct exec 102 -- su - librenms -s /bin/bash -c "lnms device:add -3 -u snmpuser -a SHA -A '$AP' -x AES -X '$PP' $H" 2>&1 | grep -v -- "$AP" | grep -v -- "$PP"
unset AP PP
pct exec 102 -- mysql librenms -e "select device_id, hostname, snmpver, authlevel, authalgo, cryptoalgo from devices where hostname='$H';"
LNMSEOF
chmod 700 /root/snmp-v3-lnms.sh
```

**本案結果**（每台一台一台執行並確認）：

| 容器 | 所在節點 | 作業系統 | LibreNMS |
| --- | --- | --- | --- |
| ai（CT113） | node10 | Ubuntu 24.04 | device 18，v3／authPriv／SHA／AES |
| ProxCenter（CT110） | node10 | Debian 13 | device 19 |
| ipam（CT103） | node10 | Debian 13 | device 20（先在 AdGuard 與 Pihole 補上 DNS 紀錄） |
| wazuh（CT112） | node12 | Ubuntu 22.04 | device 21 |
| PBS31（獨立主機） | — | Debian 13（PBS） | device 22 |

注意：

- 加入前先確認主機名稱解析得到：`pct exec 102 -- getent hosts <主機名稱>`；兩台 DNS 伺服器都要加紀錄。
- 安裝時的 `perl: warning: Setting locale failed` 是容器內沒有 `en_US.UTF-8` 語系，不影響功能。
- jt-ipam 下一次同步時會自動帶入新設備，`devices_seen` 隨之增加。
- 待改善（當時狀態）：原有 9 台由 MD5／DES 升級為 SHA／AES，並移除設定中殘留的 v2c community（LibreNMS 已不使用）。後續：已於 11-12 完成。

**Graylog 由 v2c 改為 v3**（device 17）：先備份設定，再以 `snmp-v3-add.sh 105 Node10` 覆蓋為只有 v3 的設定，接著直接修改 LibreNMS 資料庫，帳號密碼從既有 v3 設備複製（不經過畫面）：

```bash
pct exec 105 -- cp -a /etc/snmp/snmpd.conf /etc/snmp/snmpd.conf.bak-v2c-$(date +%F-%H%M)
/root/snmp-v3-add.sh 105 Node10
pct exec 102 -- mysql librenms -e "
UPDATE devices d JOIN devices s ON s.device_id = 13
SET d.snmpver = 'v3', d.authlevel = 'authPriv',
    d.authname = s.authname, d.authpass = s.authpass, d.authalgo = 'SHA',
    d.cryptopass = s.cryptopass, d.cryptoalgo = 'AES',
    d.community = NULL
WHERE d.device_id = 17;"
```

驗證：`lnms device:poll 17 -m core` 出現 `Snmpget[3/0.05s]`；以原 community 執行 `snmpget -v2c` 回 `Timeout: No Response`，確認 v2c 已失效。

### 11-12 原有主機升級為 SHA／AES 並移除 v2c

原有 7 台 Linux 主機（3 台節點、AdGuard、Pihole、librenms、wireguard）不能用 11-11 的腳本整份覆蓋設定，因為節點上有 LibreNMS 讀取 VM 資訊用的 `extend proxmox`，librenms 有 `extend distro`。改為**就地修改**。

**先唯讀檢查設定內容**（community 與密碼遮蔽）：

```bash
grep -vE '^[[:space:]]*(#|$)' /etc/snmp/snmpd.conf | sed -E \
  -e 's/^(com2sec[[:space:]]+[^[:space:]]+[[:space:]]+[^[:space:]]+[[:space:]]+).*/\1***/' \
  -e 's/^(rocommunity6?|rwcommunity6?)[[:space:]]+[^[:space:]]+/\1 ***/' \
  -e 's/^(createUser[[:space:]]+[^[:space:]]+).*/\1 ***/'
awk '/^usmUser/{print $5}' /var/lib/snmp/snmpd.conf      # 實際存在的 v3 帳號
```

本案發現：

| 主機 | 發現 |
| --- | --- |
| node12、AdGuard、wireguard、Pihole | Debian 預設的 `rocommunity`／`rocommunity6`（限 systemonly 範圍）仍開著 |
| librenms | `com2sec` 搭配 `view all`，v2c 可讀取全部資料 |
| 多台 | `rouser authPrivUser`，但該帳號不存在，無作用 |
| node11 | 多一個打錯字的 v3 帳號 `anmpuser`，沒有任何權限 |

**每台的處理**（腳本 `snmp-v3-upgrade.sh NODE host|CTID LIBRENMS_DEVICE_ID`，密碼一樣由 LibreNMS 資料庫讀入、以單一 SSH 連線傳送）：

1. 備份 `/etc/snmp/snmpd.conf` 與 `/var/lib/snmp/snmpd.conf`。
2. 刪除 `com2sec`、`rocommunity(6)`、`group … v1/v2c`、`access`、`view` 與 `rouser authPrivUser`；`extend`、`master agentx`、`includeDir` 等其他設定保留。
3. 停止 snmpd，刪除舊的 `snmpuser`（MD5／DES）與 `anmpuser` 的 `usmUser` 行，以 `createUser snmpuser SHA … AES …` 重建（密碼不變）。
4. 啟動 snmpd，將 LibreNMS 該設備的 `authalgo`、`cryptoalgo` 改為 SHA／AES，立即輪詢驗證。

核心修改：

```bash
sed -i -E '/^[[:space:]]*(com2sec|access|view|rocommunity6?)[[:space:]]/d; /^[[:space:]]*group[[:space:]]+[^[:space:]]+[[:space:]]+v(1|2c)[[:space:]]/d; /^[[:space:]]*rouser[[:space:]]+authPrivUser[[:space:]]/d' /etc/snmp/snmpd.conf
systemctl stop snmpd
sed -i -E '/^usmUser .*"(snmpuser|anmpuser)"/d' /var/lib/snmp/snmpd.conf
# 追加 createUser 行（由腳本從 LibreNMS 資料庫產生），再啟動
systemctl start snmpd
pct exec 102 -- mysql librenms -e "UPDATE devices SET authalgo='SHA', cryptoalgo='AES' WHERE device_id=<ID>;"
```

先做一台（wireguard）確認，其餘以迴圈執行，任一台輸出沒有 `poll: Snmpget` 即停止。每台都要檢查 `usm="snmpuser" createUser=0 v2c=0`，且 `extend=` 數量與原本相同（節點與 librenms 為 1）。

**結果**：7 台全部完成。node11、node12 第一次輪詢花了 5.09 秒（推測是 v3 帳號重建後的時間同步），再輪詢一次即恢復 0.05 秒。LibreNMS 中除 2 台 Synology NAS 外，全部為 v3／SHA／AES，且已無 v2c 與寫入權限。

**Synology NAS（2 台）**：在 DSM「控制台 → 終端機 & SNMP → SNMP」取消 SNMPv1／v2c，SNMPv3 的驗證協定改為 SHA、隱私權協定改為 AES，按套用；DSM 會沿用已儲存的密碼重新產生金鑰，不必重新輸入。接著只更新 LibreNMS 的演算法並輪詢：

```bash
pct exec 102 -- mysql librenms -e "UPDATE devices SET authalgo='SHA', cryptoalgo='AES' WHERE device_id IN (5,6);"
```

兩台輪詢皆為 `Snmpget[3/0.04s]`。若輪詢逾時，代表 DSM 未沿用舊密碼，改為設定新密碼：DSM 與 LibreNMS 兩邊都填新密碼，LibreNMS 端以 `read -s` 輸入、只更新這兩台的 `authpass`／`cryptopass`。

**最終狀態**：LibreNMS 監控的 15 台全部為 SNMPv3 authPriv／SHA／AES、唯讀，無 v2c community。

還原（以容器為例；節點本身在節點上執行迴圈那一行）：

```bash
pct exec <CTID> -- bash -c 'for f in /etc/snmp/snmpd.conf /var/lib/snmp/snmpd.conf; do cp -a $(ls -t $f.bak-v3upg-* | head -1) $f; done; systemctl restart snmpd'
pct exec 102 -- mysql librenms -e "UPDATE devices SET authalgo='MD5', cryptoalgo='DES' WHERE device_id=<ID>;"
```

### 11-13 LibreNMS PHP 警告（31301）與 ports 404 結案（2026-10-16）

**查詢**（Wazuh 容器內，最近 14 天每天筆數；`devices/17/ports` 的 404 以 `full_log` 片語比對）：

```bash
C=/etc/wazuh-indexer/certs
curl -sk --cert $C/admin.pem --key $C/admin-key.pem -H 'Content-Type: application/json' \
  "https://127.0.0.1:9200/wazuh-alerts-*/_search?size=0" -d '{
  "query":{"bool":{"filter":[{"range":{"timestamp":{"gte":"now-14d"}}}],
    "should":[{"term":{"rule.id":"31301"}},{"match_phrase":{"full_log":"devices/17/ports"}}],
    "minimum_should_match":1}},
  "aggs":{"r":{"terms":{"field":"rule.id"},
    "aggs":{"d":{"date_histogram":{"field":"timestamp","calendar_interval":"day","min_doc_count":1}}}}}}' \
  | python3 -m json.tool | grep -E '"key_as_string"|"key"|"doc_count"'
```

| 項目 | 10/02～10/16 | 判斷 |
| --- | --- | --- |
| `devices/17/ports` 404 | 0 筆 | Graylog 的連接埠探索完成後已消失，結案 |
| 31301 | 4,700 筆，平常每天約 259 筆（10/02～03、10/11～12 約 430～525） | 約每 5.5 分鐘一筆，與 jt-ipam 同步週期一致；10/15 jt-ipam 升級到 v1.0.11 後沒有變化 |

**樣本**（最近 3 筆，取 `full_log`）全部相同：

```text
[error] ... FastCGI sent in stderr: "PHP message: PHP Error(8192): ctype_digit(): Argument of type null will be interpreted as string in the future in /opt/librenms/includes/html/api_functions.inc.php:3229" while reading response header from upstream, client: <jt-ipam IP>, server: <LibreNMS 主機名稱>, request: "GET /api/v0/resources/links HTTP/1.1", ...
```

觸發的請求是 `/api/v0/resources/links`，不是 11-9 當時記錄的 `ports?columns=`。這個路徑在環境沒有 LLDP／CDP 鄰居資料時回 404（已由 100140 降級），LibreNMS 處理同一請求時另在 nginx 錯誤 log 留下 PHP deprecated 警告（8192，不是錯誤），由 decoder `nginx-errorlog` 觸發 31301（Nginx error message）。

**子規則**（三項條件都符合才降級；不寫行號，LibreNMS 更新後行號變動時只會讓警告重新出現）：

```xml
<group name="local,web,tuning,">
  <rule id="100141" level="0">
    <if_sid>31301</if_sid>
    <match>ctype_digit(): Argument of type null will be interpreted as string in the future in /opt/librenms/includes/html/api_functions.inc.php</match>
    <regex type="pcre2">client: 192\.0\.2\.29, server: \S+, request: "GET /api/v0/resources/links HTTP/</regex>
    <description>LibreNMS PHP deprecation on jt-ipam links sync (suppressed)</description>
  </rule>
</group>
```

套用與驗證：

```bash
cp -a /var/ossec/etc/rules/local_rules.xml /var/ossec/etc/rules/local_rules.xml.bak-$(date +%Y%m%d-%H%M)
grep -c 'id="100141"' /var/ossec/etc/rules/local_rules.xml        # 0，編號未使用
# 以 cat >> 附加上面的 group 後
/var/ossec/bin/wazuh-analysisd -t && echo "SYNTAX OK"
# 取最新一筆 31301 的原始日誌當樣本，再做一筆只改路徑的對照樣本
grep '"id":"31301"' /var/ossec/logs/alerts/alerts.json | tail -1 | python3 -c 'import json,sys; print(json.loads(sys.stdin.read())["full_log"])' > /root/links-line.txt
sed 's#/api/v0/resources/links#/api/v0/devices#' /root/links-line.txt > /root/other-line.txt
systemctl restart wazuh-manager
/var/ossec/bin/wazuh-logtest < /root/links-line.txt 2>&1 | grep -E "id:|level:" | tail -2
/var/ossec/bin/wazuh-logtest < /root/other-line.txt 2>&1 | grep -E "id:|level:" | tail -2
```

| 樣本 | 結果 |
| --- | --- |
| `/resources/links`（實際日誌） | `id: '100141'`、`level: '0'` |
| 改成 `/api/v0/devices` | `id: '31301'`、`level: '3'`，仍告警 |

上線後 30 分鐘以 `_count` 查詢 31301（`"range":{"timestamp":{"gte":"now-30m"}}`）為 0 筆（原本每 30 分鐘約 5～6 筆）。

- `full_log` 含 ANSI 顏色碼（`\u001b[31m`），從 `alerts.json` 以 Python 解析 JSON 取出，才是 logtest 能用的原始字串。
- 根治方式是 LibreNMS 修正 `api_functions.inc.php` 對空參數的處理，或 jt-ipam 不再呼叫無資料的 `links`；任一方修正後可移除 100141 與 100140 的 `links` 條件。

### 11-14 LibreNMS 裝置群組改為動態（2026-10-16）

LibreNMS 原有三個 static 群組，由人工維護成員。改為 dynamic，讓新加入的設備依欄位自動歸類。

**盤點**（LibreNMS 容器，唯讀；容器不在本機時 `pct exec` 會顯示 `Configuration file ... does not exist`，先以 `ls /etc/pve/nodes/*/lxc/<CTID>.conf` 找所在節點）：

```bash
pct exec 102 -- mysql librenms -e "SELECT device_id, hostname, os, hardware, features, sysDescr FROM devices ORDER BY device_id;"
pct exec 102 -- mysql librenms -e "SELECT id, name, type, rules FROM device_groups\G"
pct exec 102 -- mysql librenms -e "SELECT g.name, d.hostname FROM device_group_device gd JOIN device_groups g ON g.id=gd.device_group_id JOIN devices d ON d.device_id=gd.device_id ORDER BY g.name, d.hostname;"
```

| 類型 | `os` | `features` | `sysDescr` 的 kernel |
| --- | --- | --- | --- |
| PVE 節點（3） | proxmox | `Debian 13.7/PVE 9.2.21` | `-pve` |
| LXC（10） | proxmox | 只有發行版（Debian／Ubuntu） | `-pve`（共用主機 kernel） |
| pbs31（NAS 上的 VM） | proxmox | `Debian 13.7` | `-pve`（PBS 使用 Proxmox kernel） |
| Synology NAS（2） | dsm | NULL | `4.4.302+` |

- `hardware` 全部是 `Generic x86 64-bit`，無法區分實體與虛擬。
- `os` 對 LXC 也顯示 proxmox（偵測到 `-pve` kernel），不能用來排除 PVE 節點。
- 可區分的特徵：kernel 是 `-pve` 而 `features` 沒有 `PVE` 者為 LXC 或 pbs31；`features` 有 `PVE`（distro 腳本辨識出 PVE）者為節點。
- 目前未加入 Windows；UBClient、WinClient 刻意不納入 LibreNMS（監控訊息過多）。

**規則**（Devices → Manage Groups → Edit → Type 改為 Dynamic）：

| 群組 | 規則 | 成員 |
| --- | --- | --- |
| Virtual_Group | `devices.sysDescr` contains `-pve` AND `devices.features` not contains `PVE` | 10 台 LXC、pbs31 |
| Physical_Group | `devices.features` contains `PVE` | node10、node11、node12 |
| Storage_Group | `devices.os` equal `dsm` | tokyo16、melayu17 |

**結果**：三個群組 `type` 皆為 dynamic、`valid: true`；成員與修改前的 static 群組完全相同（Physical 3、Storage 2、Virtual 11）。

注意事項：

- 規則依賴 `features`（`extend distro`）。新 LXC 以 `snmp-v3-add.sh` 加入會一併安裝 distro 並自動進入 Virtual_Group；手動設定 SNMP 未裝 distro 時 `features` 為 NULL，不會進任何群組。新 PVE 節點同理，要有 distro 才會進 Physical_Group。
- 日後加入 DC01、DC02 時，Virtual_Group 加上 `OR devices.os equal windows`（環境中納管的 Windows 只有 DC，皆為 VM）。Windows Server 內建 SNMP 服務已列為淘汰，屆時評估是否改以既有 Wazuh Agent 監控即可。
- 有自己 kernel 的 VM（例如 QEMU 的 Linux VM）不符合 Virtual_Group 規則，若日後納管需另加條件（例如 hostname）。
- 檢查是否有 LibreNMS 告警規則綁定群組：`SELECT r.name, g.name FROM alert_group_map m JOIN alert_rules r ON r.id=m.rule_id JOIN device_groups g ON g.id=m.group_id;`。2026-10-16 查詢無輸出，沒有告警規則綁定群組，所有告警套用全部設備。

## 12. 弱點偵測結果與修補（2026-10-03）

### 12-1 查詢目前的弱點

Wazuh 的弱點偵測把**目前仍存在**的弱點存在 `wazuh-states-vulnerabilities-*` 索引（不是歷史告警）。Agent 每小時回報一次套件清單，套件更新後約 1 小時內會反映。在 CT 112 內：

```bash
cat > /root/vuln.json <<'JSONEOF'
{
  "size": 0,
  "aggs": {
    "sev": { "terms": { "field": "vulnerability.severity", "size": 10 } },
    "agents": { "terms": { "field": "agent.name", "size": 30 },
      "aggs": { "sev": { "terms": { "field": "vulnerability.severity", "size": 10 } } } },
    "crit_high": { "filter": { "terms": { "vulnerability.severity": ["Critical", "High"] } },
      "aggs": { "pkg": { "terms": { "field": "package.name", "size": 25 },
        "aggs": {
          "cves":   { "cardinality": { "field": "vulnerability.id" } },
          "score":  { "max": { "field": "vulnerability.score.base" } },
          "agents": { "terms": { "field": "agent.name", "size": 20 } } } } } }
  }
}
JSONEOF
curl -sk -u admin 'https://127.0.0.1:9200/wazuh-states-vulnerabilities-*/_search' \
  -H 'Content-Type: application/json' -d @/root/vuln.json > /root/vuln.out
```

再以 Python 整理為三段：嚴重度總計、各主機 Critical／High／Medium／Low、Critical／High 最多的套件（CVE 數、最高分、出現主機）。`hits.total` 顯示 10000 是計數上限。

### 12-2 判讀（更新前）

| 主機 | Critical／High | 主要來源 | 實際風險 |
| --- | --- | --- | --- |
| ubclient | 486／2,766 | 兩個 Ubuntu kernel 套件（舊版未移除），各 1,619 個 CVE | 中；kernel 套件比對也容易誤判 |
| wireguard | 304／1,357 | `linux-image-rt-amd64`（1,503 個 CVE） | LXC 使用主機 kernel，容器內的 kernel 套件從未執行，實際風險近乎零；但主機對外開放 VPN |
| DC01、DC02、CA | 各 34／638 | Windows Server（671 個 CVE），缺 Windows Update | **高** |
| ai | 40／340 | ffmpeg 系列函式庫 | 中 |
| 其他 Debian 容器與節點 | 0～20／37～162 | vim、perl、bind9 工具、libxml2、libssh2、rsync | 低～中；剛更新的節點仍列出者多為上游尚無修補 |

判讀原則：舊版 kernel 只要有安裝就會被列出；Debian 常把修補移植回舊版本，版本號看似未變；rsync 的高風險漏洞主要影響 rsync daemon（各容器 873 埠皆未監聽）。

### 12-3 容器套件更新

先唯讀掃描各容器的待更新數、容器內 kernel 套件與 rsync daemon：

```bash
probe='apt-get update -qq >/dev/null 2>&1; echo "upg=$(apt list --upgradable 2>/dev/null | grep -c upgradable) sec=$(apt list --upgradable 2>/dev/null | grep -c -- -security) kernel_pkgs=$(dpkg -l "linux-image*" 2>/dev/null | grep -c ^ii) rsyncd=$(ss -tlnp 2>/dev/null | grep -c ":873 ")"'
for id in $(pct list | awk 'NR>1 && $2=="running"{print $1}'); do
  echo "CT$id: $(pct exec $id -- bash -c "$probe" 2>/dev/null)"
done
```

每台的處理（`ct-upgrade.sh NODE CTID [purge-kernel]`，在 node10 執行）：建立快照 `pre-apt-20261003` →（wireguard）移除 `linux-image-*` → `apt-get upgrade --with-new-pkgs`（`--force-confold` 保留設定檔）→ `autoremove` → 從容器內 `reboot` → 等待 `systemctl is-system-running` 為 running／degraded，列出失敗的服務。先以影響最小的容器試做，其餘以迴圈執行，任一台不是 `running` 即停止。兩台 DNS（AdGuard、Pihole）分開執行。

| 容器 | 更新數 | 結果 |
| --- | --- | --- |
| IPAM | 13 | degraded → `openipmi.service` 失敗（容器沒有 IPMI 硬體）。由 `ipmitool` 依賴、隨 jt-ipam 安裝；以 `systemctl mask --now openipmi.service` 停用後為 running（遠端 BMC 查詢不需要本機服務） |
| ProxCenter | 8 | running |
| librenms | 77 | running |
| ai | 57 | running；剩 7 個 mesa 套件為 Ubuntu 分階段更新（`deferred due to phasing`），之後自動開放 |
| wireguard | 75 | running；容器內 kernel 套件已移除 |
| AdGuard | 44 | running |
| Pihole | 41 | running |
| Graylog、wazuh | 0 | 已是最新 |

觀察一天服務皆正常後，已刪除各容器的 `pre-apt-20261003` 快照（2026-10-04），避免持續佔用 Ceph 空間：

```bash
for n in node10 node11 node12; do ssh $n 'for id in $(pct list | awk "NR>1{print \$1}"); do pct listsnapshot $id 2>/dev/null | grep -q pre-apt-20261003 && pct delsnapshot $id pre-apt-20261003 && echo "deleted CT$id"; done'; done
```

DC01、DC02、CA 的 Windows Update 由管理者手動執行（順序 DC02 → DC01 → CA，一次一台；DC 已加入 HA，一律選「更新並重新啟動」，不要選「更新並關機」）。

### 12-4 更新後重新查詢（2026-10-05）

DC02 → DC01 → CA 的 Windows Update 與 ubclient 更新由管理者完成後重新查詢（查詢加上 `"track_total_hits": true` 取得實際總數）。

| 主機 | 更新前 Critical／High | 更新後 Critical／High | 說明 |
| --- | --- | --- | --- |
| DC01、DC02、CA | 各 34／638 | 各 **0／1** | Windows Update 完成 |
| wireguard | 304／1,357 | **0／38** | 移除容器內 kernel 套件並更新 |
| AdGuard | 18／103 | 0／38 | |
| Pihole | 16／101 | 0／37 | |
| librenms | 20／162 | 1／42 | |
| ipam | 0／85 | 0／64 | 剩 pnpm（13 個 CVE） |
| ai | 40／340 | 37／295 | 剩 ffmpeg 系列（Ubuntu universe，尚無修補） |
| Graylog | 12／114 | 12／114 | 已無待更新套件，剩餘為 Debian 12 尚未修補者 |
| ubclient | 486／2,766 | 486／2,766 | 兩個 Ubuntu kernel 套件仍在清單中，待確認 |
| 節點、pbs31、ProxCenter | 0／37～38 | 0／37～38 | 主要為 vim、libxml2，Debian 尚未發布修補 |

**ubclient 的 kernel**：目前使用 `7.0.0-38-generic`；`-31` 是 `autoremove` 刻意保留的備用版本（保留目前與前一版）。使用中的 `-38` 被列出的大量 CVE 多為誤判（Wazuh 以上游 kernel 的 CVE 比對，Ubuntu 會自行移植修補、版本號看不出來）。移除舊版（不需重開機）：

```bash
dpkg -l | grep 7.0.0-31 | awk '{print $2}'                      # 先確認清單只有 -31
sudo apt purge -y $(dpkg -l | grep 7.0.0-31 | awk '{print $2}')
dpkg -l | grep -c 7.0.0-31                                      # 0
sudo systemctl restart wazuh-agent                              # 立即重新回報套件清單
```

移除後只剩一個 kernel，下次 kernel 更新時 `-38` 會成為新的備用版本。`linux-image-generic-hwe-24.04` 中繼套件要保留。dpkg 提示 `/lib/modules/7.0.0-31-generic` 不是空的，是 DKMS 等產生的殘留檔案，確認不是使用中的 kernel 後可手動刪除。

全部合計：Critical 998 → **536**、High 7,132 → **3,587**，總筆數 9,192。Windows 主機與對外開放的 wireguard 已接近清零；剩下的 Critical 幾乎都在 ubclient 的 kernel 套件與 ai 的 ffmpeg。

**移除 ubclient 舊 kernel 後再查詢（2026-10-06）**：ubclient 由 486／2,766 降為 **243／1,389**，清單只剩使用中的 `linux-image-7.0.0-38-generic`（1,618 個 CVE，多為誤判）。

| 項目 | 修補前（10-03） | 10-05 | 10-06 |
| --- | --- | --- | --- |
| Critical | 998 | 536 | **292** |
| High | 7,132 | 3,587 | **2,216** |
| 總筆數 | 約 16,000 | 9,192 | **5,367** |

Critical 與 High 都減少約七成。剩下的 Critical 中，ubclient 使用中 kernel 的誤判占 243、ai 的 ffmpeg（已限制存取）占 37、Graylog 的 Debian 12 未修補項目占 12；Windows、wireguard、AdGuard、Pihole、節點、PBS 與 ProxCenter 皆為 0。

### 12-5 ai 的 ffmpeg：保留並確認存取限制

ffmpeg 系列（37 個 Critical）是 ai 容器剩下的主要弱點，Ubuntu universe 尚無修補。移除前先確認用途（ai 為 CT 113）：

```bash
pct exec 113 -- apt-cache rdepends --installed ffmpeg            # 沒有套件依賴它
pct exec 113 -- bash -c "apt-mark showmanual | grep -x ffmpeg"    # 手動安裝
pct exec 113 -- systemctl cat --no-pager hermes-gateway.service | grep -E 'ExecStart|WorkingDirectory'
pct exec 113 -- bash -c "grep -rIl --exclude-dir={venv,node_modules,.git,__pycache__} -i ffmpeg /usr/local/lib/hermes-agent | head"
```

結果：Hermes 的 `Dockerfile`、`nix/hermes-agent.nix` 都把 ffmpeg 列為相依套件，venv 中的 `edge_tts`（文字轉語音）會呼叫它，設定中也有語音轉文字（Whisper）與 TTS。**套件管理看不到「程式直接呼叫指令」的依賴關係**，所以 `rdepends` 為空不代表沒人使用。移除會讓語音功能失效，因此**保留**。

ffmpeg 的漏洞需要處理惡意影音檔才會觸發，對 Hermes 而言來源就是 Telegram 傳入的語音與檔案，所以改為確認誰能傳訊息給 Bot（只顯示設定名稱與筆數，不顯示內容）：

| 項目 | 結果 |
| --- | --- |
| `.env` 的 `TELEGRAM_ALLOWED_USERS` | 已被註解，未啟用 |
| `config.yaml` → `telegram.allowed_chats` | 有設定，限制可對話的聊天室 |
| `~/.hermes/pairing/telegram-approved.json` | 1 筆（配對核准的使用者） |
| `~/.hermes/pairing/telegram-pending.json` | 1 筆，自 6 月起等待核准 |

結論：Bot 以配對核准與 `allowed_chats` 限制存取，只有核准過的帳號能傳檔案進來，風險低。等待核准的那一筆若不是自己的帳號，應清除。

本案等待核准的那一筆經確認**不是管理者認識的帳號**（代表有陌生人找到 Bot 並嘗試配對），已備份後清除：

```bash
pct exec 113 -- python3 -m json.tool /root/.hermes/pairing/telegram-pending.json      # 管理者自行查看，不外傳
pct exec 113 -- bash -c "cp -a /root/.hermes/pairing/telegram-pending.json /root/.hermes/pairing/telegram-pending.json.bak && echo '{}' > /root/.hermes/pairing/telegram-pending.json"
```

**啟用白名單**（2026-10-05）：`.env` 中原本已有被註解的 `TELEGRAM_ALLOWED_USERS`。先確認該行的數字 ID 與 `telegram-approved.json` 中的帳號相同（否則啟用後連自己都會被擋），再備份並取消註解：

```bash
pct exec 113 -- sed -n '289p' /root/.hermes/.env                         # 自行比對，不外傳
pct exec 113 -- python3 -m json.tool /root/.hermes/pairing/telegram-approved.json
pct exec 113 -- cp -a /root/.hermes/.env /root/.hermes/.env.bak-$(date +%F-%H%M)
pct exec 113 -- sed -i '289s/^#[[:space:]]*//' /root/.hermes/.env
pct exec 113 -- systemctl restart hermes-gateway
```

結果：`hermes-gateway` active，管理者帳號傳訊息 Bot 正常回應。之後不在白名單內的帳號傳訊息，Bot 不回應、也無法送出配對申請。還原方式：把最新的 `.env.bak-*` 複製回 `.env` 後重啟服務。確認運作正常後，已刪除 `.env.bak-*`（內含 Bot token 等機密）與 `telegram-pending.json.bak`（陌生帳號資料）（2026-10-06）；備份檔比現行 `.env` 多 2 bytes，正是移除的 `# `，證明只修改了該行。若擔心 token 外洩，最徹底的做法是在 @BotFather 重新產生 token（`rm` 不保證資料從 Ceph 磁碟上消失）。Ubuntu 發布 ffmpeg 修補後隨一般更新套用。

### 12-6 ubclient 套件更新與 logrotate 修正（2026-10-14）

ubclient（VM 104，Ubuntu 26.04）有 21 個套件待更新：sssd 系列 15 個、bluez 系列 4 個、`python3-jwt`（安全更新）與 `libipa-hbac0t64`，全部是同版號內的小改版。

**更新前先看清單**（`apt-get -s` 只模擬，不安裝）：

```bash
sudo apt update
apt list --upgradable 2>/dev/null
sudo apt-get -s dist-upgrade | grep -E "^(Inst|Remv)" | awk '{print $1, $2}'
cat /var/run/reboot-required 2>/dev/null || echo "目前不需要重開"
```

| 檢查 | 結果 | 判讀 |
| --- | --- | --- |
| kernel（`linux-image`） | 沒有 | 不用重開 |
| `Remv` | 沒有 | 不會移除套件，用 `apt upgrade` 即可 |
| `wazuh-agent` | 不在清單 | 不用另外擋住（Agent 版本要配合 Manager） |
| sssd | `inactive`，`realm list` 沒有網域 | 沒有加入 AD，sssd 更新不影響登入（本機帳號登入） |

sssd 若有在用（AD 登入），更新時要保留原本的 SSH 連線，另開新連線確認 AD 帳號能登入後才關。本案 sssd 沒在用，因此沒有打快照，以前一晚的 PBS 備份作為保底。

```bash
sudo apt upgrade
sudo systemctl --failed --no-pager
cat /var/run/reboot-required 2>/dev/null || echo "不需要重開"
apt list --upgradable 2>/dev/null | tail -n +2
systemctl is-active wazuh-agent
```

結果：21 個套件更新完成、清單清空、不需重開、`wazuh-agent` active。但 `systemctl --failed` 列出 **`logrotate.service` failed**。

#### logrotate 失敗：cloud-init 拆套件留下重複設定

```bash
journalctl -u logrotate --since "7 days ago" --no-pager | grep -iE "error|fail" | tail -20
```

```text
error: cloud-init-base:1 duplicate log entry for /var/log/cloud-init.log
error: found error in file cloud-init-base, skipping
```

10/11 起每天都失敗，與本次更新無關。`/etc/logrotate.d/` 有兩個檔案都管 `/var/log/cloud-init*.log`，logrotate 不允許重複，便跳過其中一個並回報失敗；其他 log 照常輪替，只有 cloud-init 的 log 沒有輪替。

```bash
for f in $(grep -l "cloud-init" /etc/logrotate.d/*); do
  echo "== $f"; dpkg -S "$f"; ls -l "$f"; cat "$f"; echo
done
dpkg-query -W -f='${Package} ${Version}\n' cloud-init cloud-init-base
dpkg-query -W -f='${Conffiles}\n' cloud-init | grep logrotate
```

| 檔案 | 所屬套件 | 狀態 |
| --- | --- | --- |
| `/etc/logrotate.d/cloud-init` | `cloud-init`（2025/6） | **obsolete**：新版套件已不提供，dpkg 保留未刪 |
| `/etc/logrotate.d/cloud-init-base` | `cloud-init-base`（7/24） | 目前使用中 |

兩個套件都是 `26.1-0ubuntu3~26.04.1`，兩個檔案內容完全相同。新版 cloud-init 拆成 `cloud-init` 與 `cloud-init-base`，logrotate 設定改由 `cloud-init-base` 提供，舊檔被當成使用者設定檔留下。處理：保留套件使用中的 `cloud-init-base`，舊檔搬出目錄（不刪除，可還原）：

```bash
sudo mv /etc/logrotate.d/cloud-init /root/logrotate.d-cloud-init.bak
sudo logrotate -d /etc/logrotate.conf 2>&1 | grep -iE "duplicate|error:" || echo "沒有錯誤"
sudo systemctl start logrotate
systemctl show logrotate -p Result --value          # success
sudo systemctl --failed --no-pager | tail -1        # 0 loaded units listed.
```

結果：`success`，沒有失敗的服務。`-d` 只模擬；若用 `grep error` 過濾，會誤抓到 `cups/error_log`、`ppp-connect-errors` 這類檔名，不是錯誤。

#### 注意：`obsolete` 不等於檔案沒在用

順手用 `dpkg-query -W -f='${Conffiles}\n' | grep obsolete` 掃描整台，出現 `/etc/grub.d/10_linux`、`00_header`、`/etc/cloud/cloud.cfg` 等大量 `obsolete`。**這些檔案仍在使用，不能刪**：Ubuntu 26.04 把許多設定檔從舊套件搬到新套件，舊套件的紀錄會標 `obsolete`，新套件以正常狀態擁有同一個檔案；上面的指令沒有顯示套件名稱，看起來就像一堆廢棄檔。誤刪 `/etc/grub.d/` 的腳本，下次 `update-grub` 可能讓 VM 無法開機。

本次可以搬走 logrotate 舊檔，依據是**實際報錯**加上**舊檔只屬於舊套件、內容與新檔相同**，不是因為它標了 `obsolete`。原則：有實際錯誤或衝突時才處理單一檔案，不要把 `obsolete` 清單當成待刪清單。

更新後也建議固定跑一次 `systemctl --failed`：本次的 logrotate 失敗已存在數天，是更新後檢查才發現。

## 13. jt-ipam 整合（2026-10-06）

jt-ipam（ipam，CT 103）可同步 Wazuh Agent 清單（ID、IP、狀態、作業系統與版本、群組、最後連線時間），對應到 IPAM 的 IP，並在「缺少 Agent」頁面列出尚未安裝 Agent 的 IP。它使用 **Wazuh 伺服器 API（55000）**：先以 `/security/user/authenticate` 取得 token，再讀取 `/agents`（Wazuh 4.8 起 API 已無弱點端點，因此不讀弱點）。

### 13-1 建立最小權限的 API 帳號

官方建議的 `wazuh-wui` 具管理員權限，改為建立只能讀取 Agent 的專用帳號 `jtipam`：

| 項目 | 內容 |
| --- | --- |
| 政策 | 沿用內建 `agents_read_agents`（id 4）：只有 `agent:read`，範圍 `agent:id:*`、`agent:group:*`。Wazuh 不允許建立內容相同的政策（錯誤 4009 `The specified name or policy already exists`） |
| 角色 | 新建 `jtipam_agents_read`，只連結上述政策 |
| 帳號 | `jtipam`，密碼以 `secrets` 隨機產生、只顯示一次並存入密碼管理器 |

管理員帳號 `wazuh` 的密碼若遺失，可改用 Dashboard 設定檔 `/usr/share/wazuh-dashboard/data/wazuh/config/wazuh.yml` 中的 `wazuh-wui`（administrator 角色）執行，腳本直接讀檔、不顯示密碼：

```bash
F=/usr/share/wazuh-dashboard/data/wazuh/config/wazuh.yml
AU=$(grep -m1 -E '^\s*username:' $F | sed -E 's/^\s*username:\s*//; s/^["'\'']//; s/["'\'']\s*$//')
PW=$(grep -m1 -E '^\s*password:' $F | sed -E 's/^\s*password:\s*//; s/^["'\'']//; s/["'\'']\s*$//')
T=$(curl -sk -u "$AU:$PW" -X POST "https://127.0.0.1:55000/security/user/authenticate?raw=true"); unset PW
# 找出內建 agent:read 政策 id → POST /security/roles → POST /security/roles/<rid>/policies?policy_ids=<pid>
# → POST /security/users {username, password} → POST /security/users/<uid>/roles?role_ids=<rid>
```

驗證（以 jtipam 登入）：`/agents` 回 `error 0`、18 筆（17 Agent + Manager）；`/manager/info` 回 **HTTP 403**，證明只有讀取 Agent 的權限。

注意：**指派角色後同一秒內取得的 token 會被作廢**（Wazuh 在帳號角色變動時撤銷之前的 token，時間精度為秒），腳本中緊接著的登入測試因此回 401；稍後重新登入即正常。

### 13-2 開放 API 給 jt-ipam（先防火牆、後綁定）

資料中心防火牆未啟用，因此在 Wazuh 容器內以 nftables 限制。附加到 `/etc/nftables.conf`（nftables 服務已 enabled），獨立成一個表：

```text
table inet wazuh_api {
    chain input {
        type filter hook input priority filter - 1; policy accept;
        tcp dport 55000 ip saddr { 127.0.0.1, <jt-ipam IP> } accept
        tcp dport 55000 drop
    }
}
```

```bash
nft -c -f /etc/nftables.conf && nft -f /etc/nftables.conf && nft list table inet wazuh_api
# 防火牆生效後才改 API 綁定；務必保留 127.0.0.1（Dashboard 由本機連 API）
sed -i "80s/host: \['127.0.0.1'\]/host: ['127.0.0.1', '<Wazuh IP>']/" /var/ossec/api/configuration/api.yaml
systemctl restart wazuh-manager
ss -tlnp | grep ':55000 '          # 127.0.0.1 與 Wazuh IP 各一行
```

驗證（在 PVE 節點執行）：

```bash
pct exec 103 -- curl -sk -o /dev/null -w '%{http_code}' --max-time 5 https://<Wazuh IP>:55000/   # 401：連得到
curl -sk -o /dev/null -w '%{http_code}' --max-time 5 https://<Wazuh IP>:55000/                   # 000：被擋
```

本案第一次執行時漏做防火牆步驟，改綁定後從節點也拿到 401（API 對整個網段開放）；補上規則後節點變為 000。**一定要以「非允許來源」實際測試到被擋**，不能只測允許來源。

還原：

```bash
cp -a $(ls -t /var/ossec/api/configuration/api.yaml.bak-* | head -1) /var/ossec/api/configuration/api.yaml && systemctl restart wazuh-manager
cp -a $(ls -t /etc/nftables.conf.bak-* | head -1) /etc/nftables.conf && nft -f /etc/nftables.conf
```

### 13-3 jt-ipam 設定與結果

jt-ipam → Wazuh → 新增：API URL `https://<Wazuh IP>:55000`、使用者 `jtipam`、`verify_tls` 關閉（Wazuh API 為自簽憑證；連線仍加密，只是不驗證對方身分，帳號僅能讀取 Agent，風險有限；之後可匯入 Wazuh CA 再開啟）。

新增設定後若剛好錯過排程同步（每 5 分鐘），可手動執行 `pct exec 103 -- systemctl start jt-ipam-sync.service` 或按網頁上的同步。

結果：`wazuh_instances` 為 `https://<Wazuh IP>:55000`／`jtipam`／`verify_tls = f`，`wazuh_agents` 同步 **17 筆**；網頁列出每台 Agent 的 IP、上線狀態、作業系統與 Wazuh 4.14.8 版本。

「缺少 Agent」頁面首次同步後列出 4 筆，判讀如下（都不需要補裝）：

| 主機 | 原因 | 處理 |
| --- | --- | --- |
| Wazuh 本身 | Manager 在 API 中是 agent `000`，IP 回報為 `127.0.0.1`，對不到 IPAM 的位址 | 正常，列為例外 |
| Synology NAS ×2 | DSM 不支援安裝 Wazuh Agent | 列為例外；已由 LibreNMS（SNMPv3）監控；DSM 已確認啟用自動封鎖、2FA，並停用預設 `admin`（2026-10-06） |
| Graylog 測試容器 | Debian 13 測試用的臨時 IP，容器刪除後 IPAM 紀錄未清除 | 已在 jt-ipam 刪除該筆紀錄 |

之後此頁面若出現新的 IP，才是真正需要評估是否安裝 Agent 的主機。

待改善：匯入 Wazuh CA 後開啟 TLS 驗證；Wazuh 升級後確認 `api.yaml` 的 `host` 設定與 nftables 規則仍在。

## 14. WireGuard VPN 健康監控（2026-10-13）

ct:109（wireguard，Agent 010）加上指令監控，每 5 分鐘回報 wg0 與 WGDashboard 狀態（規則 100150）。Manager 本身也加上指令監控，每 5 分鐘從外部連 ct:109 的 10086（規則 100151），兩條都屬 `wireguard` 群組、level 10。

**Agent 停止與斷線：正常關機產生 506，不是 504。** 100151 最初接內建規則 504（`Agent disconnected`），停掉 ct:109 後沒有觸發。後續實測確認：正常關機時 Agent 會先通知 Manager，產生 **506（Wazuh agent stopped，level 3）**，不會再有 504。

| 實測（2026-10-13） | 關機方式 | 結果 |
| --- | --- | --- |
| ct:109（Agent 010） | `ha-manager set ct:109 --state stopped` | 506 |
| UBClient（Agent 011） | VM 內 `sudo poweroff` | 506；超過 17 分鐘仍無 504 |

504 應該只在 Agent 來不及通知時出現（斷電、當機、網路中斷），本次未實測。其他 Agent 若要做停止／斷線告警：正常停止接 506，異常中斷要另外實測 504；對重要服務，像 VPN 這樣從外部主動檢查較可靠。

實驗期間把 `agents_disconnection_alert_time` 由 0 改為 1m（排查「0 是否停用斷線告警」），正常關機的結果不受影響；目前設定為 1m，它對 504 的實際作用仍未驗證。

目前 `agents_disconnection_alert_time` 決定保留 1m：如果 0 在 4.14 代表停用，1m 才會在異常中斷時產生 504；如果 0 代表立刻告警，1m 也只是晚 1 分鐘。504 為 level 3，只顯示在 Wazuh Dashboard，不會寄信。異常中斷（`qm stop` 直接斷電）的 504 測試決定不做。

**順帶修正：UBClient 的 QEMU Guest Agent。** 測試時發現 UBClient（vm:104）在 PVE 設定了 `agent: 1`，但 VM 內沒有執行 Guest Agent，`qm shutdown` 因 `guest-ping` 逾時而失敗，只好從 Console 關機。在 node11 一次檢查兩台：

```bash
for id in 104 108; do
  echo "== vm:$id =="
  qm config $id | awk '/^agent:/ {print "agent:", $2}'
  qm agent $id ping 2>/dev/null && echo "Guest Agent 有回應" || echo "Guest Agent 沒有回應"
done
```

Guest Agent 沒回應時，從 PVE 主機分不出是「沒安裝」還是「沒執行」，要進 VM 確認。

| VM | 結果 | 處理 |
| --- | --- | --- |
| UBClient（Ubuntu 26.04.1 LTS） | 沒有回應；`apt` 顯示 `Selecting previously unselected package`，代表從來沒裝過 | VM 內 `sudo apt install -y qemu-guest-agent` 後 `sudo systemctl start qemu-guest-agent` |
| WinClient（Windows 10 Pro） | 原本就有回應 | 不需處理 |

Ubuntu 的 `qemu-guest-agent` 是 static unit，安裝時會顯示 `not starting it`，所以第一次要手動 start；之後開機偵測到 `/dev/virtio-ports/org.qemu.guest_agent.0` 會自動啟動，不必 `enable`；10/13 重新開機實測，UBClient 11:36:47 開機、Guest Agent 11:36:51 啟動，相差 4 秒（`qm guest exec 104 -- uptime -s` 與 `systemctl show qemu-guest-agent -p ActiveEnterTimestamp` 對照）。安裝後 `qm agent 104 ping` 有回應、`get-osinfo` 回傳 Ubuntu 26.04.1 LTS，`qm shutdown 104`、`qm shutdown 108` 都順利完成並回到 stopped。

Manager 另外新增一個 `syslog_output`，只把 `wireguard` 群組的告警以 JSON 送到 Graylog 的 Syslog UDP 1514，再由 Graylog Event Definition 寄 Gmail。這是 Wazuh 第一次把告警轉到 Graylog；其他告警仍只在 Wazuh Dashboard。

完整設定、踩雷與實測見 [不再把 PVE 8006 開到網際網路：改用 WireGuard 連回家](https://kbwangtw.github.io/IT-Knowledge-Base/docs/pve/wireguard-remote-access-replace-8006/) 第 12 節。

## 15. Grafana 唯讀存取（2026-10-14）

為了在 Grafana 戰情中心顯示告警、Agent 狀態與弱點，在本容器加了三項設定（Indexer 本身的設定與綁定位址不動）：

| 項目 | 內容 |
| --- | --- |
| `indexer-proxy.service` | socat 監聽 Wazuh IP 的 9201，轉送到 `127.0.0.1:9200`（TLS 由兩端直接加密） |
| nftables `table inet wazuh_indexer` | 9201 只允許 Grafana 主機，其他來源丟棄 |
| Indexer 角色 `grafana_wazuh_read`、帳號 `grafana` | 只能讀 `wazuh-alerts-*`、`wazuh-monitoring-*`、`wazuh-states-vulnerabilities-*`；以管理員憑證建立（`/root/grafana-indexer-user.sh`） |

升級 Wazuh 後，除了第 13 節的 `api.yaml` host 與 55000 規則，也確認 `indexer-proxy` 為 active、9201 規則仍在、`grafana` 帳號能登入。完整建置、驗證與還原見 [用 Grafana 建立戰情中心（一）：接上 Wazuh](https://kbwangtw.github.io/IT-Knowledge-Base/docs/pve/grafana-war-room-wazuh/)。

## 常見問題

| 現象 | 怎麼辦 | 參考 |
| --- | --- | --- |
| 磁碟越來越滿 | 確認 ISM 30 天與告警文字檔 cron 都在運作 | 10-2～10-5 |
| 告警太多 | 先找出最常觸發的規則，再逐條調校，不要一次關掉大量規則 | 11-1 |
| 想降低某條規則的等級 | 寫在 `local_rules.xml`，用子規則限定範圍，改完用 logtest 驗證 | 11-3 |
| 弱點數量很多 | 先更新套件；剩下的分「使用中 kernel 誤判」「上游未修補」「確認存取限制」 | 第 12 節 |
| Agent 停機沒有 504 告警 | 正常關機產生的是 506；重要服務改用從外部主動檢查 | 第 14 節 |
| 升級 Wazuh 後 jt-ipam 或 Grafana 連不上 | 檢查 `api.yaml` 的 host、nftables 規則、`indexer-proxy` 服務 | 13、15 |
| `qm shutdown` 逾時 | VM 設了 `agent: 1` 但沒裝或沒啟動 QEMU Guest Agent | 第 14 節 |

## 待辦

- [ ] 驗收「重要事件仍然偵測得到」：調校後，抽幾條關鍵規則（登入失敗、FIM、sudo）實際觸發一次
- [ ] jt-ipam、Grafana 匯入 Wazuh CA 後開啟 TLS 驗證
- [ ] node10 的 AppArmor DENIED（52002）告警調校
- [ ] 定期檢查索引佔用與保留是否正常（10-5）
- [ ] 2027 年初規劃把容器升級到 Ubuntu 24.04（升級前先快照與 PBS 備份）

## 風險與注意事項

- 資料量成長很快，要規劃 Index 保留天數（ISM），並監控 rootfs 用量。
- Indexer 對儲存 I/O 敏感；放在 Ceph 上時，觀察 Ceph 延遲是否因此上升。
- 調校時一次只改一條規則，改完用 logtest 驗證，避免把重要告警一起關掉。
- 容器作業系統為 Ubuntu 22.04.5 LTS（jammy，2026-10-04 確認；LXC 共用主機 kernel，`uname -r` 顯示的是 PVE 的 kernel）。標準支援到 2027 年 4 月，2027 年初規劃升級到 24.04（Wazuh 4.14 支援）；All-in-one 架構升級期間 Indexer、Manager、Dashboard 會一起中斷。

## 延伸閱讀

- [在 PVE Cluster 用 LXC 架設 Wazuh（一）：安裝與接上 Agent](https://kbwangtw.github.io/IT-Knowledge-Base/docs/pve/wazuh-lxc-ubuntu2204-sop/)
- [用 Grafana 建立戰情中心（一）：接上 Wazuh](https://kbwangtw.github.io/IT-Knowledge-Base/docs/pve/grafana-war-room-wazuh/)
- [不再把 PVE 8006 開到網際網路：改用 WireGuard 連回家](https://kbwangtw.github.io/IT-Knowledge-Base/docs/pve/wireguard-remote-access-replace-8006/)
- [jt-ipam 導入紀錄](https://kbwangtw.github.io/IT-Knowledge-Base/docs/network/jt-ipam-adoption-itbh/)
- [Wazuh 文件：Rules](https://documentation.wazuh.com/current/user-manual/ruleset/index.html)

{% endraw %}
