---
layout: default
title: "Wazuh 4.14.8 升級到 4.14.9 SOP（All-in-one，LXC）"
date: 2026-11-02
categories: [PVE, Wazuh, Upgrade]
permalink: /docs/pve/wazuh-4-14-9-upgrade-sop/
last_modified_at: 2026-11-02
---

# Wazuh 4.14.8 升級到 4.14.9 SOP（All-in-one，LXC）

> **一句話**：Wazuh Dashboard 提示有新 patch 4.14.9；這篇是 2026-11-02 實際升級 All-in-one 的完整紀錄：備份、依序升級 Indexer、Manager、Filebeat、Dashboard，再逐項驗收。中央元件與 18 台 Agent 已全部升級並驗收完成；Agent 先手動升級 6 台，再用 Wazuh 內建的 `agent_upgrade` 腳本依序升級其餘。

| 項目 | 內容 |
| --- | --- |
| 適合誰看 | 自己用 LXC 架設 Wazuh All-in-one、想升級 patch 版本的人 |
| 環境 | PVE 叢集上的 LXC（Ubuntu 22.04），Wazuh All-in-one，Cluster 為 Disabled（單節點），18 台 Agent |
| 日期 | 2026-11-02 實測 |
| 版本 | 4.14.8 → 4.14.9（2026-10-14 發布） |
| 風險 | 中：升級期間 Indexer、Manager、Dashboard 會中斷；有快照與 PBS 備份即可還原 |
| 實測中斷時間 | Filebeat 與 Dashboard 停止約 10～17 分鐘（含逐步確認時間；Indexer 停機時間未精確記錄） |
| 結論 | ✅ 中央元件（Indexer、Manager、Filebeat、Dashboard）升級完成並驗收；✅ 18 台 Agent 全部升級為 4.14.9（2026-11-02～03），升級不需重新註冊，`agent_upgrade -l` 回報 `All agents are updated.`；⏳ 兩個無關但尚未釐清的觀察（DC01 的 DFSR 警告、Graylog 與 wireguard 是誰升級的，見 8.9） |

> **關於指令**：指令依官方 [All-in-one 升級指南](https://documentation.wazuh.com/current/upgrade-guide/upgrading-central-components.html)整理，並已在本環境實測；若與官方當下版本不同，以官方為準。4.14.9 的內容見下方第 1 節（來源：官方 [4.14.9 Release notes](https://documentation.wazuh.com/4.14/release-notes/release-4-14-9.html)，2026-10-14 發布）。

## 1. 4.14.9 改了什麼（跟本環境有關的重點）

此版為累積更新，內容以 bug 修復與安全強化為主。官方頁面**沒有列出 CVE 編號、breaking changes、升級注意事項與 Filebeat 變更**；與 Indexer 相關的只有 #39041。

| 項目 | 變更 | 對本環境的意義 |
| --- | --- | --- |
| #39041（Manager） | 修正 indexer connector 與 `wazuh-states-*` 索引不同步；記錄 `_bulk`、`_delete_by_query` 的失敗，DELETED 文件不再誤刪 ID 前綴相同的文件 | 與 Indexer 資料有關，升級後留意 Manager 日誌與 Dashboard 的 Inventory 資料是否正常 |
| #39051（Manager） | 修正漏洞掃描器在 CTI feed 處理積壓時停滯 | 弱點偵測（Vulnerability Detection）資料更新更穩定 |
| #38474（Manager） | 修正 Debian backports 套件造成的漏洞誤報 | 弱點數量**可能下降**（推測，未實測），升級後比對前後數字時要把這點算進去 |
| #39471（Manager） | API access log 預設不再寫入 `run_as` 原文；`run_as` 上限由 8 KB 提高到 64 KB，新增 `auth_context_max_payload_size` | 一般用不到；若看 API 日誌的格式有變，是預期內 |
| #38449、#39539（Manager） | cluster 握手期限與連線上限；`wazuh-authd` 關閉 30 秒內未完成的閒置註冊連線 | 本環境 Cluster 為 Disabled，影響小 |
| #38894（Manager） | API 純文字 access log 會跳脫路徑中的控制字元 | 防止偽造日誌，無需動作 |
| #38679、#39047、#39166、#39474（Ruleset） | 修正多個 SCA 檢查（靜默失敗、誤判通過、拼字） | SCA（Configuration Assessment）結果**可能改變**，通過率不同不代表主機變差（推測） |
| #39124（Agent） | 修正預設 nodiff 清單未保護 `/etc/shadow` 與真正金鑰路徑 | 升級 Agent 後 FIM 對敏感檔案不再顯示內容差異 |
| #38277、#40084（Agent，Windows） | 修正 MSI 待重新開機時升級損壞、`netsh` 與 `route-null` active response 自 4.14.7 起失敗 | 若有 Windows Agent，升級後優先驗證 |
| #39148 | 嵌入式 Python 升到 3.10.21 | 無需動作 |
| Dashboard #9141、#9313 | 修正 Server API 授權標頭被覆寫、模組啟用狀態顯示 | 升級後 Dashboard 顯示可能與之前略有不同 |

完整清單（含 macOS、FIM eBPF、各 wodle 的修復）請看官方原頁。

## 2. 先認識幾個名詞

| 名詞 | 白話解釋 |
| --- | --- |
| **All-in-one** | Indexer、Manager、Dashboard 全部裝在同一台，本環境就是這樣 |
| **Wazuh Indexer** | 存放告警資料的資料庫（OpenSearch 系列） |
| **Wazuh Manager** | 接收各台 Agent 回報、套用規則、產生告警的主程式 |
| **Filebeat** | 把 Manager 的告警送進 Indexer 的搬運工 |
| **Wazuh Dashboard** | 網頁介面 |
| **Agent** | 裝在各台被監控主機上的小程式 |
| **patch 版本** | 版號最後一碼（4.14.8 → 4.14.9），通常是修 bug 與安全問題，風險比跨 minor（4.14 → 4.15）低 |
| **shard allocation** | Indexer 把資料分片分配給節點的機制；升級前先暫停，避免重啟時亂搬資料 |
| **快照（snapshot）** | PVE 對 LXC 的瞬間還原點；本篇用來當「後悔藥」 |

## 3. 全貌

```text
讀 release notes
   ↓
快照 + PBS 備份（後悔藥）
   ↓
記錄升級前狀態（版本、服務、設定檔）；暫時啟用 apt 來源
   ↓
① Indexer ─→ ② Manager ─→ ③ Filebeat 模組與範本 ─→ ④ Dashboard
   ↓
apt 來源註解回去 ─→ 驗收（版本、告警、API、Grafana、jt-ipam）
   ↓
⑤ 各台 Agent（先處理 Disconnected 的兩台）
```

重點：

- **順序固定**：Indexer → Manager → Filebeat → Dashboard，最後才升 Agent。
- **升級期間會中斷**：Agent 會先把事件暫存在本機，Manager 回來後再補送（推測，依 Agent 預設行為，未實測）。實測：Manager 重啟後 Agent 全部自動重連，數量與升級前相同。
- **不要同時升級 Grafana**：兩邊同時變動，出問題時分不清原因。

## 4. 升級前準備

### 4.1 確認目前狀態

做什麼 → 記錄升級前的版本、服務與 Agent，當作驗收基準。

```bash
dpkg -l | grep -E "wazuh|filebeat" | awk '{print $2, $3}'
systemctl is-active wazuh-indexer wazuh-manager filebeat wazuh-dashboard
/var/ossec/bin/agent_control -ls | head -30
```

看到的結果：wazuh-indexer、wazuh-manager、wazuh-dashboard 都是 `4.14.8-1`，filebeat 是 `7.10.2-2`；四個服務都是 `active`；Agent 18 台（16 台 Active、2 台 Disconnected，Disconnected 是用戶端類型的主機）。

### 4.2 備份

| 備份 | 做法 | 為什麼 |
| --- | --- | --- |
| LXC 快照 | PVE 對這台 CT 建立快照，例如 `pre-wazuh-4.14.9` | 最快的還原方式 |
| PBS 備份 | 手動跑一次這台 CT 的備份 | 快照與 CT 在同一個儲存池，壞了一起壞 |
| 設定檔 | 下方指令 | 升級後比對有沒有被改動 |

```bash
mkdir -p /root/wazuh-pre-4.14.9
cp -a /var/ossec/etc /root/wazuh-pre-4.14.9/ossec-etc
cp -a /etc/wazuh-indexer /root/wazuh-pre-4.14.9/indexer-etc
cp -a /etc/wazuh-dashboard /root/wazuh-pre-4.14.9/dashboard-etc
cp -a /etc/filebeat /root/wazuh-pre-4.14.9/filebeat-etc
ls /root/wazuh-pre-4.14.9
```

應該看到：`dashboard-etc  filebeat-etc  indexer-etc  ossec-etc` 四個目錄。

> 本環境另有自己加的設定：`api.yaml` 的 `host`、55000 與 9201 的 nftables 規則、`indexer-proxy` 服務。升級後都要再確認，詳見 [Wazuh 維運（二）](../wazuh-lxc-ubuntu2204-operations/)。

### 4.3 暫時啟用 Wazuh 的 apt 來源

做什麼 → 安裝完成後，Wazuh 的 apt 來源常被註解掉（避免誤升級）。這時 `apt-cache madison` 查不到任何 Wazuh 套件，要先暫時啟用。

```bash
ls /etc/apt/sources.list.d/
cat /etc/apt/sources.list.d/wazuh.list
```

本環境看到 `deb` 那行前面有 `#`。處理方式：先備份，再拿掉 `#`，確認三個套件都有 `4.14.9-1`。

```bash
cp -a /etc/apt/sources.list.d/wazuh.list /root/wazuh-pre-4.14.9/wazuh.list.bak
sed -i 's/^#deb/deb/' /etc/apt/sources.list.d/wazuh.list
apt-get update
apt-cache madison wazuh-indexer wazuh-manager wazuh-dashboard | grep 4.14.9
```

| 片段 | 意思 |
| --- | --- |
| `sed -i 's/^#deb/deb/'` | 拿掉行首的 `#` |
| `apt-get update` | 重新讀取來源，應出現 `packages.wazuh.com`，沒有 `NO_PUBKEY` |
| `grep 4.14.9` | 三個套件都要列出 `4.14.9-1` |

> 啟用期間**不要**執行不帶套件名的 `apt upgrade`，它可能一次升級所有 Wazuh 套件、打亂順序。只用 `apt-get install <套件>=4.14.9-1`。升級全部完成後要註解回去（見第 6 節）。

### 4.4 取得 Indexer 管理帳號與密碼

後面要用 `curl` 暫停與恢復 shard allocation，需要 Indexer 的管理帳號（網頁登入的管理員通常就是同一組）。

```bash
read -s -p "Indexer 密碼: " P; echo
curl -sk -u "<管理帳號>:$P" https://127.0.0.1:9200/_cluster/health?pretty
```

| 片段 | 意思 |
| --- | --- |
| `read -s -p` | 把密碼讀進變數 `P`，輸入時不顯示、不留在指令歷史 |
| `<管理帳號>` | 要換成實際帳號（連同 `<` `>` 一起換掉） |
| `_cluster/health` | 查叢集健康度 |

看到的結果：`status` 為 `yellow`、`number_of_nodes` 為 1、`active_shards` 為 150、`unassigned_shards` 為 30。

> `yellow` 在單節點是預期狀態：沒有第二台機器可放副本分片，所以那 30 個副本一直是未分配。升級後只要維持同樣的數字就算正常。

## 5. 升級步驟

> 以下指令都在 Wazuh 的 LXC 內，用 root 執行；同一個終端機要保留 `P` 變數。

### 5.1 ① 升級 Indexer

做什麼 → 先停掉寫入端、暫停 shard allocation，再升級套件。

```bash
systemctl stop filebeat wazuh-dashboard
curl -sk -u "<管理帳號>:$P" -X PUT https://127.0.0.1:9200/_cluster/settings -H 'Content-Type: application/json' -d '{"persistent":{"cluster.routing.allocation.enable":"primaries"}}'
curl -sk -u "<管理帳號>:$P" -X POST https://127.0.0.1:9200/_flush
systemctl is-active filebeat wazuh-dashboard wazuh-indexer
```

| 片段 | 意思 |
| --- | --- |
| `stop filebeat wazuh-dashboard` | 先停寫入端與網頁 |
| `allocation.enable: primaries` | 暫停副本分片重新分配，避免重啟時資料亂搬 |
| `_flush` | 把記憶體中的資料寫到磁碟 |

看到的結果：第一個 curl 回傳 `"acknowledged":true`；`_flush` 回傳 `failed` 為 0；最後一行依序是 `inactive`、`inactive`、`active`。

本次 `_flush` 回報 `total 122, successful 121, failed 0`，有 1 個分片既未成功也未失敗，原因未確認。停 Indexer 前先確認沒有主分片卡住：

```bash
curl -sk -u "<管理帳號>:$P" "https://127.0.0.1:9200/_cat/shards?h=index,shard,prirep,state" | grep -v STARTED | awk '{print $3, $4}' | sort | uniq -c
```

看到的結果：只有 `30 r UNASSIGNED`（副本），沒有任何 `p`（主分片）。接著停 Indexer 並安裝：

```bash
systemctl stop wazuh-indexer
apt-get install wazuh-indexer=4.14.9-1
```

看到的結果：`Unpacking wazuh-indexer (4.14.9-1) over (4.14.8-1)`、`Setting up wazuh-indexer (4.14.9-1)`，沒有設定檔提問。Wazuh 套件安裝後**不會自動啟動**，要手動啟動。

比對設定、啟動並確認：

```bash
diff -rq /root/wazuh-pre-4.14.9/indexer-etc /etc/wazuh-indexer
systemctl daemon-reload
systemctl start wazuh-indexer
sleep 60
curl -sk -u "<管理帳號>:$P" https://127.0.0.1:9200/_cluster/health?pretty | grep -E "status|number_of_nodes|active_shards\"|unassigned_shards"
```

看到的結果：`diff` 沒有輸出（設定與升級前一致）；`status` 為 `yellow`、`active_shards` 150、`unassigned_shards` 30，與基準相同。最後恢復 allocation：

```bash
curl -sk -u "<管理帳號>:$P" -X PUT https://127.0.0.1:9200/_cluster/settings -H 'Content-Type: application/json' -d '{"persistent":{"cluster.routing.allocation.enable":null}}'
dpkg -l wazuh-indexer | awk 'END{print $2, $3}'
```

看到的結果：`"acknowledged":true`、`"persistent":{}`；套件為 `4.14.9-1`。Indexer 自己回報的 `number` 是 `7.10.2`，那是底層 OpenSearch 版本，Wazuh 4.14.x 沿用，不是異常。

### 5.2 ② 升級 Manager

```bash
apt-get install wazuh-manager=4.14.9-1
systemctl daemon-reload
systemctl enable --now wazuh-manager
sleep 20
systemctl is-active wazuh-manager
diff -rq /root/wazuh-pre-4.14.9/ossec-etc /var/ossec/etc
grep -n "host" /var/ossec/api/configuration/api.yaml
```

看到的結果：`active`、`4.14.9-1`；`diff` 只有兩項：`internal_options.conf` differ（套件自己管理的檔案，預期內）、`ossec.conf.new`（因為 `ossec.conf` 改過，套件不覆蓋，另存新版預設值，預期內）；`api.yaml` 的 `host` 與升級前一致。

**比對 `ossec.conf` 與 `ossec.conf.new`**：官方指南說，`ossec.conf` 改過時，新版新增的設定要手動加入。

```bash
diff /var/ossec/etc/ossec.conf /var/ossec/etc/ossec.conf.new
```

`diff` 中 `<` 是目前設定、`>` 是新版預設。本次逐項判斷：

| 差異 | 目前 | 新版預設 | 處理 |
| --- | --- | --- | --- |
| `agents_disconnection_alert_time` | `1m`（自訂） | `0` | 保留現有 |
| indexer `host` | `127.0.0.1:9200` | `0.0.0.0:9200` | 保留現有（Indexer 只對本機） |
| 憑證檔名 | `wazuh-server.pem` | `filebeat.pem` | 保留現有（要與實際憑證一致） |
| 檔案後段的自訂區塊（journald、`dpkg.log`、轉送 Graylog 的 `syslog_output`、自訂監控指令） | 有 | 沒有 | 都是自己加的，保留 |
| `nodiff` | 只有 1 行 | 另外保護 `/etc/ssl/private/`、`/etc/pki/tls/private/`、`/etc/shadow`、`/etc/gshadow` 等 | **加入**（對應 4.14.9 的 #39124） |

加入 `nodiff`（先備份，依內容定位插入，再測試設定語法）：

```bash
cp -a /var/ossec/etc/ossec.conf /root/wazuh-pre-4.14.9/ossec.conf.before-nodiff
sed -i '/<nodiff>\/etc\/ssl\/private.key<\/nodiff>/a\    <nodiff type="sregex">^/etc/ssl/private/|^/etc/pki/tls/private/</nodiff>\n    <nodiff>/etc/shadow</nodiff>\n    <nodiff>/etc/shadow-</nodiff>\n    <nodiff>/etc/gshadow</nodiff>\n    <nodiff>/etc/gshadow-</nodiff>' /var/ossec/etc/ossec.conf
grep -n "nodiff" /var/ossec/etc/ossec.conf
/var/ossec/bin/wazuh-analysisd -t; echo "exit=$?"
```

看到的結果：6 行 `nodiff`（原本 1 行加新增 5 行）、`exit=0`。再重啟 Manager 讓設定生效：

```bash
systemctl restart wazuh-manager
sleep 20
systemctl is-active wazuh-manager
tail -n 5 /var/ossec/logs/ossec.log
```

看到的結果：`active`；日誌顯示 `IndexerConnector initialized successfully for index: wazuh-states-inventory-*`，沒有 `ERROR`。

### 5.3 ③ 升級 Filebeat 模組與範本

Filebeat 套件本身已是 `7.10.2-2`，要更新的是 Wazuh 的模組與告警範本。**Filebeat 此時仍是停止的。**

```bash
cp /etc/filebeat/filebeat.yml /etc/filebeat/filebeat.yml.old
curl -fs https://packages.wazuh.com/4.x/filebeat/wazuh-filebeat-0.5.tar.gz | tar -xvz -C /usr/share/filebeat/module
curl -fso /etc/filebeat/wazuh-template.json https://raw.githubusercontent.com/wazuh/wazuh/v4.14.9/extensions/elasticsearch/7.x/wazuh-template.json
chmod go+r /etc/filebeat/wazuh-template.json
python3 -m json.tool /etc/filebeat/wazuh-template.json > /dev/null && echo "template OK"
apt-get install filebeat
diff /etc/filebeat/filebeat.yml.old /etc/filebeat/filebeat.yml && echo "filebeat.yml 未被改動"
```

| 片段 | 意思 |
| --- | --- |
| `curl -fs ... \| tar -xvz` | 下載並解壓 Wazuh 的 Filebeat 模組（`-f` 讓下載失敗時直接報錯） |
| `wazuh-template.json`（`v4.14.9`） | 告警欄位的資料格式定義 |
| `json.tool` | 確認範本是合法 JSON，避免只下載到錯誤頁 |
| `diff ... .old` | 確認設定沒被套件覆蓋 |

看到的結果：`tar` 列出 `wazuh/alerts/...`、`wazuh/archives/...` 等檔案；`template OK`；`filebeat is already the newest version (7.10.2-2)`；`filebeat.yml 未被改動`。

測試連線、上傳管線與範本，最後才啟動 Filebeat（官方是先啟動再 setup，本次調整成先測試，失敗時比較好判斷）：

```bash
filebeat test output
filebeat setup --pipelines
filebeat setup --index-management -E output.logstash.enabled=false
systemctl daemon-reload
systemctl enable --now filebeat
```

看到的結果：`talk to server... OK`；`Loaded Ingest pipelines`；`Index setup finished.`。`ILM policy and write alias loading not enabled.` 是正常訊息，Wazuh 的 Filebeat 設定沒有啟用 ILM。

確認 Filebeat 真的有持續寫入（Filebeat 自己的日誌在 `/var/log/filebeat/`，`journalctl` 只有啟停紀錄）：

```bash
tail -n 5 /var/log/filebeat/filebeat
curl -sk -u "<管理帳號>:$P" "https://127.0.0.1:9200/wazuh-alerts-*/_count?pretty" | grep count
sleep 60
curl -sk -u "<管理帳號>:$P" "https://127.0.0.1:9200/wazuh-alerts-*/_count?pretty" | grep count
```

看到的結果：日誌出現 `Connection to backoff(elasticsearch(https://127.0.0.1:9200)) established`；兩次計數從 `145027` 增加到 `145034`，代表持續寫入。

日誌另有 `Template wazuh already exists and will not be overwritten.`：`filebeat.yml` 沒有 `setup.template.overwrite`（只有 `setup.ilm.overwrite: true`，兩者不同），所以 Filebeat 預設不覆蓋既有範本。把現行範本存成檔案，與 4.14.9 的範本比對欄位定義（唯讀，不改任何東西）：

```bash
curl -sk -u "<管理帳號>:$P" https://127.0.0.1:9200/_template/wazuh -o /root/wazuh-pre-4.14.9/live-template.json
python3 -c "
import json
live = json.load(open('/root/wazuh-pre-4.14.9/live-template.json'))['wazuh']
new = json.load(open('/etc/filebeat/wazuh-template.json'))
print('mappings:', 'SAME' if live.get('mappings') == new.get('mappings') else 'DIFFERENT')
"
```

看到的結果：`mappings: SAME`，不需要強制覆蓋。若是 `DIFFERENT`，再執行 `filebeat setup --index-management -E output.logstash.enabled=false -E setup.template.overwrite=true` 套用（只影響之後新建的索引）。

### 5.4 ④ 升級 Dashboard

```bash
cp /etc/wazuh-dashboard/opensearch_dashboards.yml /etc/wazuh-dashboard/opensearch_dashboards.yml.old
apt-get install wazuh-dashboard=4.14.9-1
```

官方指南說，安裝時若詢問設定檔，要選擇**替換成新版**（輸入 `Y`），再手動套回自訂設定，並確認 `server.ssl.key`、`server.ssl.certificate` 與 `/etc/wazuh-dashboard/certs/` 的檔案一致。本次**沒有出現設定檔提問**，所以要驗證設定沒被改：

```bash
diff /etc/wazuh-dashboard/opensearch_dashboards.yml.old /etc/wazuh-dashboard/opensearch_dashboards.yml && echo "設定檔未被改動"
ls /etc/wazuh-dashboard/ | grep -E "dpkg|\.new|\.old"
grep -nE "ssl|host|port|opensearch.hosts" /etc/wazuh-dashboard/opensearch_dashboards.yml
ls -l /etc/wazuh-dashboard/certs/
```

看到的結果：`設定檔未被改動`；沒有 `.dpkg-new`；`opensearch.hosts` 仍是 `127.0.0.1:9200`、`server.port: 443`、SSL 已啟用；`certs/` 裡的 `root-ca.pem`、`wazuh-dashboard.pem`、`wazuh-dashboard-key.pem` 都在。若設定檔被替換，要把 `opensearch.username`、`opensearch.password`、憑證路徑等自訂內容從 `.old` 套回去（`password` 那行不要貼到任何地方）。

啟動：

```bash
systemctl daemon-reload
systemctl enable --now wazuh-dashboard
sleep 60
systemctl is-active wazuh-dashboard
journalctl -u wazuh-dashboard -n 8 --no-pager | cut -c1-200
ls -l /usr/share/wazuh-dashboard/data/wazuh/config/
```

看到的結果：`active`；日誌出現 `Server running at https://0.0.0.0:443`；`wazuh.yml`（Wazuh 外掛連 Manager API 的設定）完整保留。

## 6. 收尾：把 apt 來源註解回去

```bash
sed -i 's/^deb /#deb /' /etc/apt/sources.list.d/wazuh.list
cat /etc/apt/sources.list.d/wazuh.list
apt-get update 2>&1 | tail -n 3
```

看到的結果：`#deb [signed-by=...] https://packages.wazuh.com/4.x/apt/ stable main`；`apt-get update` 只剩 Ubuntu 的來源。

## 7. 驗收

| 檢查 | 指令／位置 | 本次結果 |
| --- | --- | --- |
| 套件版本 | `dpkg -l \| grep -E "wazuh\|filebeat"` | wazuh 三個套件 `4.14.9-1`，filebeat `7.10.2-2` ✅ |
| 服務 | `systemctl is-active wazuh-indexer wazuh-manager filebeat wazuh-dashboard indexer-proxy` | 五個都是 `active` ✅ |
| 連接埠 | `ss -ltn \| grep -E ":55000\|:9200\|:9201\|:443"` | 443、9200（本機）、9201、55000 都在 LISTEN ✅ |
| nftables | `nft list ruleset \| grep -E "55000\|9201"` | 55000 只放行本機與指定來源、其餘 drop；9201 只放行指定來源、其餘 drop ✅ |
| Dashboard 版本 | 網頁 → Dashboard management → App Settings（API Connections 表格）；Server management → Status 可看 Manager information | `v4.14.9`、Agents 18 ✅ |
| Agent | `/var/ossec/bin/agent_control -ls \| awk -F, '{print $4}' \| sort \| uniq -c` | 16 Active、1 Active/Local、2 Disconnected，與升級前相同 ✅ |
| 告警持續寫入 | `_count` 兩次比較 | 145027 → 145034 ✅ |
| Grafana | `journalctl -u grafana-server --since '-10min' \| grep "Plugin Request Completed"` | `Wazuh Alerts` 資料來源 `status=ok` ✅ |
| jt-ipam | `pct exec 103 -- journalctl -u jt-ipam-sync --since '-30min' --no-pager \| grep -iE "wazuh\|ERROR"` | Manager 重啟後連續兩次同步成功：`fetched 19`、`updated 18`、`matched_ip 18`、`ambiguous_ip 0` ✅ |

> jt-ipam 同步的日誌很長，`tail -20` 只會看到最後的 LibreNMS 與 AdGuard，要用 `grep -iE "wazuh|ERROR"` 才看得到 Wazuh 那一段。

## 8. ⑤ 升級各台 Agent（18 台全部完成）

> 本節記錄實際做法。前 6 台（ubclient、WinClient、grafana、ProxCenter、librenms、IPAM）手動升級（8.3、8.4、8.6）；其餘改用 Wazuh 內建的 `agent_upgrade`，並以腳本 [`tools/wazuh-agent-upgrade`](https://github.com/kbwangtw/it-knowledge-base/tree/main/tools/wazuh-agent-upgrade) 一次一台、失敗就停（8.7）；Windows Server 三台手動升級（8.8）。Agent 版本不能高於 Manager，所以要在 Manager 升完之後才做（本次已完成）。**8.3 的 `pct push`、`pct exec` 寫法沒有實際使用**，實際是在容器內直接 `wget` 與 `dpkg -i`（8.6 的 grafana、ProxCenter、librenms、IPAM）。

### 8.1 原則

| 原則 | 說明 |
| --- | --- |
| 一次一台、先小量試 | 先升 1 台低影響的主機，確認回報正常，再依序升其他台 |
| 不加 Wazuh 套件庫 | 沿用 [第一篇](../wazuh-lxc-ubuntu2204-sop/) 的做法：下載 .deb 用 `dpkg -i` 安裝，日後 `apt upgrade` 不會連帶升級 Agent |
| 升級不需要重新註冊 | 升級會保留原本的設定與金鑰（`client.keys`）；**升級時不要再帶 `WAZUH_MANAGER` 等變數**，避免被當成全新安裝。已在 ubclient 與 WinClient 實測：升級後 Manager 端仍是原本的 Agent ID，沒有出現第二筆 |
| 避開重要時段 | PVE 節點避開備份時段；DNS 兩台、網域控制站兩台各自分開時間 |
| 每台升完立即驗證 | 版本、服務、在 Manager 端的狀態，三項都對才做下一台 |

### 8.2 順序

先在 Manager 端確認每台 Agent 的作業系統與版本（Windows 與 Linux 的升級方式不同）：

```bash
/var/ossec/bin/agent_control -ls
/var/ossec/bin/agent_control -i <Agent ID> | grep -iE "name|ip|os|version|status"
```

| 批次 | 對象 | 做法 | 備註 |
| --- | --- | --- | --- |
| 0 | 2 台 Disconnected | 先確認是已下線（可從 Manager 移除）還是異常（先修再升） | 用戶端類型的主機，可能只是沒開機 |
| 1 | 1 台低影響的 Linux 容器 | 先試做，確認「升級不需重新註冊」的假設 | 例如 Grafana 或監控類容器 |
| 2 | 其餘 Linux 容器 | 一次一台，每台升完驗證 | 容器用 `pct push` 與 `pct exec` |
| 3 | 兩台 DNS 容器 | **分開時間**，一台升完驗證後再做另一台 | DNS 服務不能同時受影響（Agent 重啟只有幾秒，通常不影響 DNS，仍分開做） |
| 4 | 3 台 PVE 節點 | 一次一台，避開備份時段 | 直接在節點上操作 |
| 5 | 備份伺服器與其他 | 一次一台 | |
| 6 | Windows 主機（網域控制站等） | **最後做，一次一台，不同時段** | 見 8.4 |

### 8.3 Linux（Debian／Ubuntu）

在容器所在的 PVE 節點上操作，`<CTID>` 換成實際 ID：

```bash
cd /tmp && [ -f wazuh-agent_4.14.9-1_amd64.deb ] || wget https://packages.wazuh.com/4.x/apt/pool/main/w/wazuh-agent/wazuh-agent_4.14.9-1_amd64.deb
pct exec <CTID> -- dpkg -l wazuh-agent | awk 'END{print $2, $3}'
pct push <CTID> /tmp/wazuh-agent_4.14.9-1_amd64.deb /tmp/wazuh-agent_4.14.9-1_amd64.deb
pct exec <CTID> -- dpkg -i /tmp/wazuh-agent_4.14.9-1_amd64.deb
pct exec <CTID> -- bash -c 'systemctl daemon-reload && systemctl restart wazuh-agent && sleep 5 && systemctl is-active wazuh-agent'
pct exec <CTID> -- dpkg -l wazuh-agent | awk 'END{print $2, $3}'
pct exec <CTID> -- rm -f /tmp/wazuh-agent_4.14.9-1_amd64.deb
```

| 片段 | 意思 |
| --- | --- |
| 第 1 行 | 節點上準備 .deb（下載過就略過） |
| 第 2 行 | 記錄升級前的版本 |
| `pct push` | 把 .deb 推進容器 |
| `dpkg -i` | 直接升級，不帶註冊變數 |
| `restart` | 重啟 Agent，套用新版 |
| 最後的 `dpkg -l` | 確認版本是 `4.14.9-1` |

PVE 節點本身則直接在節點上執行（不用 `pct`）：

```bash
cd /tmp && [ -f wazuh-agent_4.14.9-1_amd64.deb ] || wget https://packages.wazuh.com/4.x/apt/pool/main/w/wazuh-agent/wazuh-agent_4.14.9-1_amd64.deb
dpkg -i ./wazuh-agent_4.14.9-1_amd64.deb
systemctl daemon-reload
systemctl restart wazuh-agent
systemctl is-active wazuh-agent
```

每台升完，在 Wazuh 的 CT 確認這台 Agent：

```bash
/var/ossec/bin/agent_control -i <Agent ID> | grep -iE "version|status"
```

應該看到：版本 `Wazuh v4.14.9`、狀態 `Active`。

### 8.4 Windows

- 4.14.9 修了兩個 Windows 相關問題：MSI 升級遇到「待重新開機」時，重啟後 Agent 損壞（#38277）；`netsh` 與 `route-null` active response 自 4.14.7 起失敗（#40084）。
- 升級前先確認該主機**沒有待重新開機的項目**（先完成 Windows Update 並重開機），再升級。
- 安裝檔是 `wazuh-agent-4.14.9-1.msi`，可用 GUI 安裝，或在系統管理員的命令提示字元以 `msiexec.exe /i wazuh-agent-4.14.9-1.msi /q` 靜默安裝（命令依官方文件，未實測）。
- 網域控制站兩台分開時段，一台升完驗證 Active 之後再做另一台。

### 8.5 全部完成後

- 確認所有 Agent 版本為 4.14.9：Dashboard 的 Agents 頁依版本排序檢視。
- 觀察弱點數量與 SCA 通過率的變化（見待辦）。
- 把實測結果補進本文，並移除「尚未實測」標註。

### 8.6 實測紀錄：ubclient 與 WinClient（2026-11-02）

兩台原本是 Disconnected（沒開機），開機後 Agent 自動重連，版本都是 4.14.8，並在開機後等 5 分鐘再動手。

**ubclient（Ubuntu 26.04.1 LTS，x86_64，用 .deb 安裝、沒有 Wazuh 套件庫）**

事前檢查（唯讀）：

```bash
cat /etc/os-release | head -2
uname -m
dpkg -l wazuh-agent | awk 'END{print $2, $3}'
systemctl is-active wazuh-agent
ls /etc/apt/sources.list.d/ | grep -i wazuh
sudo grep -A2 '<server>' /var/ossec/etc/ossec.conf
```

`/var/ossec` 只有 root 能讀，所以最後一行要加 `sudo`。備份與下載後升級：

```bash
sudo cp -a /var/ossec/etc ~/ossec-etc-pre-4.14.9
cd /tmp && wget https://packages.wazuh.com/4.x/apt/pool/main/w/wazuh-agent/wazuh-agent_4.14.9-1_amd64.deb
sudo dpkg -i /tmp/wazuh-agent_4.14.9-1_amd64.deb
sudo systemctl daemon-reload
sudo systemctl restart wazuh-agent
sleep 5
systemctl is-active wazuh-agent
dpkg -l wazuh-agent | awk 'END{print $2, $3}'
```

看到的結果：`Unpacking wazuh-agent (4.14.9-1) over (4.14.8-1)`，沒有設定檔提問；`active`；`wazuh-agent 4.14.9-1`。

**踩到的雷**：第一次 `dpkg -i` 出現 `dpkg frontend lock was locked by /usr/bin/python3.14 process with pid 4376`，沒有安裝成功（但後面的 `restart` 仍會執行，Agent 只是重啟、版本沒變）。用 `ps -fp 4376` 看到是 `aptd`（Ubuntu 開機後的套件管理背景程式），同時登入畫面顯示「系統需要重新啟動」。**不要刪除 lock 檔案，也不要強制結束程式**；等它釋放後重試 `dpkg -i`，本次直接成功。

**WinClient（Windows 11 Pro）**

事前檢查（系統管理員的 PowerShell）：

```powershell
Get-Service WazuhSvc | Select-Object Name, Status
(Get-Item "C:\Program Files (x86)\ossec-agent\wazuh-agent.exe").VersionInfo.FileVersion
Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending'
Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
(Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name PendingFileRenameOperations -ErrorAction SilentlyContinue).PendingFileRenameOperations
```

**踩到的雷**：兩個 `Test-Path` 都是 `False`，但 `PendingFileRenameOperations` 有 8 筆，包含 OneDrive 與 Edge 的更新殘留，以及 `C:\Config.Msi\*.rbf`（MSI 的回復檔）。這是「待重新開機」的跡象，與 4.14.9 修的 #38277（待重開機時 MSI 升級會損壞）同類，所以**先重新開機**，開機後最後一項沒有輸出才升級。判斷待重開機要看三項，不能只看兩個 `Test-Path`。

備份、下載、升級：

```powershell
New-Item -ItemType Directory -Force C:\Temp | Out-Null
Copy-Item "C:\Program Files (x86)\ossec-agent" C:\Temp\ossec-agent-pre-4.14.9 -Recurse
Test-Path C:\Temp\ossec-agent-pre-4.14.9\client.keys
Invoke-WebRequest -Uri "https://packages.wazuh.com/4.x/windows/wazuh-agent-4.14.9-1.msi" -OutFile "C:\Temp\wazuh-agent-4.14.9-1.msi"
Get-Item C:\Temp\wazuh-agent-4.14.9-1.msi | Select-Object Name, Length
$p = Start-Process msiexec.exe -ArgumentList '/i','C:\Temp\wazuh-agent-4.14.9-1.msi','/q','/l*v','C:\Temp\wazuh-agent-upgrade.log' -Wait -PassThru
"ExitCode: " + $p.ExitCode
```

| 片段 | 意思 |
| --- | --- |
| `Copy-Item ... ossec-agent` | 備份整個 Agent 目錄（含 `client.keys`、`ossec.conf`） |
| `Get-Item ... Length` | MSI 約 6 MB（6,045,696 bytes），只有幾 KB 代表下載到錯誤頁 |
| `msiexec /i ... /q` | 靜默升級，**不帶 `WAZUH_MANAGER`** |
| `/l*v ...log`、`ExitCode` | 留下詳細記錄與退出碼；`0` 成功、`3010` 成功但要重開機，其他代表失敗 |

看到的結果：`WazuhSvc` 為 `Running`、版本 `v4.14.9`、`client.keys` 仍在。

**兩台在 Manager 端的驗證**：

```bash
/var/ossec/bin/agent_control -i <Agent ID> | grep -iE "version|status"
/var/ossec/bin/agent_control -ls | grep -ic <Agent 名稱>
```

兩台都是 `Wazuh v4.14.9`、`Active`，第二行回傳 `1`（沒有重新註冊）。

### 8.7 腳本升級：`agent_upgrade`（2026-11-02～03）

做什麼 → 在 Wazuh Manager 主機上，用內建的 `agent_upgrade` 由 Manager 下載升級包（WPK）推給 Agent。不需要任何主機的 SSH 或密碼，也不用在每台手動下載 `.deb`。

先確認 Manager 能用、列出還沒升級的 Agent（唯讀）：

```bash
/var/ossec/bin/agent_upgrade -h
/var/ossec/bin/agent_upgrade -l
```

| 片段 | 意思 |
| --- | --- |
| `-h` | 顯示這個版本支援的參數（`-a` 指定 Agent、`-v` 版本、`--package_type` 等） |
| `-l` | 列出 Manager 認為過期的 Agent；全部升完會顯示 `All agents are updated.` |

本次看到的結果：`-l` 列出 12 台（網域與用戶端以外的都在內），代表 Manager 可以連到官方下載升級包。

**為什麼不直接用 `-a` 一次升全部**：一次推多台，失敗時分不清是哪一台、也沒有逐台驗證與人工確認的機會。所以包成腳本：

| 保護 | 說明 |
| --- | --- |
| 一次一台 | 升完確認「版本為目標版本且 Active」才做下一台，兩台之間間隔 60 秒 |
| 失敗就停 | 任何一台失敗、逾時、查不到版本，整批停止，後面的不會被動到 |
| 升級前檢查 | 該 Agent 必須是 Active 且版本為 `v4.14.8`；Manager 也必須已是 `4.14.9` |
| 預設只預演 | 沒加 `--run` 只列出會做什麼，不動任何東西 |
| Windows 略過 | 作業系統為 Windows 的一律略過（要先清待重開機項目，見 8.8），另有 `HARD_SKIP` 清單 |
| 重要主機要確認 | DNS、PVE 節點、備份伺服器每台要人工輸入 `y` |

用法：

```bash
./wazuh-upgrade-agents.sh 013            # 預演
./wazuh-upgrade-agents.sh --run 013      # 實際執行
```

腳本先用假的 `agent_control` 與 `agent_upgrade` 測過邏輯（預演、成功、非 Active、版本不符、逾時、Windows 略過、人工確認、前一台失敗時不動後面的），再在真實環境先對一台試跑，成功後才放開。

**實測結果**（每台約 1～1.5 分鐘，`agent_upgrade` 會等到升級完成才回來）：

| 日期 | Agent | 結果 |
| --- | --- | --- |
| 11-02 | ai（013）先試跑 | `Agent 013 upgraded: Wazuh v4.14.8 -> v4.14.9`，驗證成功 |
| 11-03 | AdGuard（008）、Pihole（009） | 兩台**分開**升級，各自前後用 `nslookup` 測 DNS，升級後解析正常 |
| 11-03 | pbs31（017） | 升級後 `proxmox-backup`、`proxmox-backup-proxy` 都是 `active` |
| 11-03 | node11、node10、node12（001～003） | 一次一台，升級前用 `pvesh get /nodes/$(hostname)/tasks --source active` 確認沒有進行中的工作，升級後 `pve-cluster`、`pvedaemon`、`pveproxy` 都是 `active`、`Nodes: 3`、`Quorate: Yes` |

> 4.14.8 的 Agent 若沒有 `find` 指令，WPK 升級會失敗（4.14.9 才修，#38431）。本次容器與節點都沒遇到。

**升級前的檢查**（用於 DNS、PVE 節點、備份伺服器這類不能隨便動的主機）：

```bash
nslookup <網域名稱> <DNS 位址>          # DNS 升級前後各測一次
pvesh get /nodes/$(hostname)/tasks --source active --output-format text   # 在每台 PVE 節點
grep -E "schedule|starttime" /etc/pve/jobs.cfg                           # 備份排程時間
systemctl is-active pve-cluster pvedaemon pveproxy; pvecm status | grep -E "Quorate|Nodes"   # 節點升級後
systemctl is-active proxmox-backup proxmox-backup-proxy                  # pbs31 升級後
```

備份排程在晚上（本環境為 21:00～22:00），選上午升級、離備份很遠。`jobs.cfg` 在叢集共用的 `/etc/pve`，三台節點看到的一樣。

### 8.8 Windows Server：ca、DC02、DC01（2026-11-03）

三台都是 Windows Server 2025 Standard，不能用腳本，沿用 WinClient 的流程（8.6）：事前檢查、備份、MSI 升級、驗證。

**順序**：先 `ca`（非網域控制站），再 DC02，等一段時間後 DC01；一次一台、不同時段。

**網域控制站升級前後各確認一次網域服務**（系統管理員的 PowerShell）：

```powershell
Get-Service NTDS, DNS, Netlogon, kdc | Select-Object Name, Status
dcdiag /q
```

看到的結果：四個服務都是 `Running`；`dcdiag /q` 沒有輸出代表正常。`ca` 另外確認 `CertSvc`（憑證服務）仍是 `Running`。

| Agent | 事前檢查 | 升級 | 驗證 |
| --- | --- | --- | --- |
| ca（016） | `PendingFileRenameOperations` 只有 1 筆 Edge 更新殘留，判斷與 Agent 檔案無關，**不重開機** | `ExitCode: 0` | `v4.14.9`、`CertSvc` 仍 `Running`、Manager 端 `Active` 且只有 1 筆 |
| DC02（014） | 全部乾淨（無待重開機、無待處理項目、`dcdiag /q` 無輸出） | `ExitCode: 0` | `v4.14.9`、四個網域服務 `Running`、`dcdiag /q` 無輸出、Manager 端 `Active` 且只有 1 筆 |
| DC01（015） | 待重開機項目乾淨、網域服務 `Running`，但 `dcdiag /q` 有 `DFSREvent` 警告（見 8.9） | 手動 MSI，同 DC02 流程 | `v4.14.9`、網域服務 `Running`、`dcdiag /q` 輸出與升級前相同；Manager 端 `Active` 且只有 1 筆 |

**`ca` 為什麼沒有重開機**：判斷待重開機要看三項（`RebootPending`、`RebootRequired`、`PendingFileRenameOperations`）。`ca` 只剩一筆 Edge 更新殘留，沒有 `Config.Msi\*.rbf`（MSI 的回復檔），而 4.14.9 的 MSI 把「待重開機」判斷縮小到 Agent 自己的檔案（#39746）。這是依版本說明做的判斷，升級成功驗證了它（`ExitCode: 0`）。

### 8.9 結果與尚未釐清的觀察

**結果**：Manager 端 `agent_upgrade -l` 回報 `All agents are updated.`，18 台全部是 `Wazuh v4.14.9`、`Active`，每台只有 1 筆（沒有任何一台重新註冊）。

**尚未釐清（不影響升級結果）**：

| 項目 | 觀察 | 狀態 |
| --- | --- | --- |
| DC01 的 `DFSREvent` 警告 | `dcdiag /q` 回報「最近 24 小時 SYSVOL 開始共用時發生警告或錯誤事件」。升級前後輸出相同，DC02 全程乾淨，所以多半是升級之前就有、與 Agent 升級無關，但 `DFSREvent` 只看 24 小時，無法完全排除（推測）。查法：`Get-WinEvent -FilterHashtable @{LogName='DFS Replication'; Level=2,3; StartTime=(Get-Date).AddHours(-24)}`、`net share \| findstr /i "SYSVOL NETLOGON"`、`repadmin /replsummary` | ⏳ 待查 |
| Graylog、wireguard 是誰升的 | 11-02 17:04 用腳本升級 ai，同日 21:07 再跑時，這兩台已是 4.14.9，不是我們升的。可能是手動升級、Dashboard 的升級按鈕或其他維運腳本。查法：`grep -i "agents/upgrade" /var/ossec/logs/api.log`、容器內 `grep wazuh-agent /var/log/dpkg.log` | ⏳ 待查 |
| AdGuard 升級前的 DNS 逾時 | 升級前第一次 `nslookup` 出現兩次逾時後才回應，升級後沒有；逾時發生在升級前，與升級無關。可能是第一次查詢沒有快取、上游較慢（推測） | 觀察 |

## 9. 還原

| 狀況 | 怎麼辦 |
| --- | --- |
| 升級中途失敗、服務起不來 | 在 PVE 把這台 CT 還原到 `pre-wazuh-4.14.9` 快照 |
| 快照有問題 | 從 PBS 備份還原 |
| 只有設定被改掉 | 從 `/root/wazuh-pre-4.14.9` 取回設定檔，重啟對應服務 |
| `ossec.conf` 改壞 | 取回 `ossec.conf.before-nodiff` |

還原後記得確認 Agent 能重新連回、Dashboard 版本為 4.14.8。

## 常見問題

| 現象 | 怎麼辦 |
| --- | --- |
| `apt-cache madison` 查不到任何 Wazuh 套件 | Wazuh 的 apt 來源被註解了，見 4.3 暫時啟用；升級完再註解回去 |
| `curl` 回 `Unauthorized` | 先檢查指令裡的 `<管理帳號>` 是否換成實際帳號（連 `<` `>` 一起換掉）；再檢查密碼。要改 `_cluster/settings` 必須是管理帳號，唯讀帳號（例如給 Grafana 用的）不行 |
| 忘了 Indexer 管理帳號密碼 | 網頁登入的管理員通常就是同一組；也可從 `/root/wazuh-install-files.tar` 的 `wazuh-passwords.txt` 找（若曾用 `wazuh-passwords-tool` 重設過，裡面是舊密碼）。重設密碼會牽動 Filebeat 與 Manager 的 keystore，也可能讓 Grafana 帳號消失，**不要在升級當下做** |
| Linux Agent 升級時 `dpkg frontend lock was locked by ... process` | 另一個程式（常見是開機後的 `aptd` 或自動更新）占用套件管理員，**這次沒有安裝成功**。不要刪 lock 檔案、不要強制結束程式；用 `ps -fp <PID>` 看是誰，等它釋放後重試 `dpkg -i`（見 8.6） |
| Windows Agent 升級前，`Test-Path` 都是 `False`，但 `PendingFileRenameOperations` 有內容（尤其含 `Config.Msi\*.rbf`） | 這仍是「待重開機」，先重開機，開機後該項沒有輸出再用 MSI 升級（見 8.6） |
| 腳本顯示「已是 v4.14.9，略過」，但那台不是你升級的 | 先確認不是自己或其他自動化做的：`grep -i "agents/upgrade" /var/ossec/logs/api.log`（Manager）、`grep wazuh-agent /var/log/dpkg.log`（該主機）；在釐清前不影響其他台的升級 |
| `agent_upgrade` 腳本整批停下來 | 腳本會印出是哪一台、為什麼（非 Active、版本不符、逾時）。**不要重跑**，先用 `agent_control -i <ID>` 看狀態，並在該主機看 `/var/ossec/logs/upgrade.log`；Agent 升級失敗時 Wazuh 會自動回復舊版 |
| 網域控制站 `dcdiag /q` 有輸出（例如 `DFSREvent`） | 升級前就有的話先不要動它，查清楚（8.9）；Agent 停在 4.14.8 沒有急迫性，Manager 是 4.14.9 時舊一版的 Agent 仍可回報 |
| 把上一段輸出也貼進終端機，出現一堆 `command not found` | 無害，那些文字被當成指令執行但沒有效果；以後只複製指令那幾行 |
| `_flush` 回報 total 與 successful 差 1，failed 為 0 | 停 Indexer 前用 `_cat/shards` 確認沒有主分片未啟動，只有副本 `UNASSIGNED` 就可繼續 |
| jt-ipam 日誌只看到 LibreNMS、AdGuard | `tail -20` 太短，改用 `grep -iE "wazuh\|ERROR"` |
| Dashboard 升級後一直轉圈 | 等 1～2 分鐘；仍不行看 `journalctl -u wazuh-dashboard -n 50` |
| Dashboard 顯示 Offline | 先確認 Indexer 與 Manager 都是 active，再重新整理 |
| `filebeat test output` 失敗 | 確認 Indexer 已啟動、憑證路徑沒被覆蓋；下載模組失敗（`curl: (22)`）可能是網路限制 |
| 日誌出現 `Template wazuh already exists and will not be overwritten` | Filebeat 預設不覆蓋既有範本；用 5.3 的比對確認欄位定義是否相同 |
| jt-ipam 或 Grafana 連不上 | 檢查 `api.yaml` 的 host、nftables 55000 規則、`indexer-proxy`，見 [Wazuh 維運（二）](../wazuh-lxc-ubuntu2204-operations/) |
| Grafana 資料來源憑證錯誤 | 若 Indexer 憑證或 root CA 有變，更新資料來源的 CA，見 [Grafana 戰情中心（一）](../grafana-war-room-wazuh/) |

## 待辦

- [x] 讀 4.14.9 release notes：無 breaking change、無 CVE 編號（官方頁面未列出）
- [x] 建立快照與 PBS 備份
- [x] 升級 Indexer、Manager、Filebeat、Dashboard 並驗收（2026-11-02）
- [x] 驗收本環境特有項目：`api.yaml` host、55000 與 9201 規則、`indexer-proxy`、Grafana、jt-ipam
- [x] 升級 2 台 Disconnected 的用戶端（ubclient、WinClient）並驗證「升級不需重新註冊」（8.6）
- [x] 升級其餘 16 台 Agent（第 8 節）：腳本升級 ai、AdGuard、Pihole、pbs31、三個 PVE 節點，手動升級 ca、DC02、DC01；`agent_upgrade -l` 回報 `All agents are updated.`
- [x] 確認 `ca`（Agent 016）的作業系統：Windows Server 2025 Standard，已手動升級
- [ ] 查 DC01 的 `DFSREvent` 警告（8.9）：確認 `SYSVOL`、`NETLOGON` 共用、`repadmin /replsummary` 的 `fails` 為 0，並判斷是升級前就存在
- [ ] 查 Graylog、wireguard 是誰升級的（8.9）
- [ ] 腳本已在真實環境成功執行（ai、AdGuard、Pihole、pbs31、三個節點），可視需要把 `HARD_SKIP` 預設值調整為只含 Windows
- [ ] 觀察弱點數量與 SCA 通過率的前後差異（#38474、SCA 修正可能造成變動）
- [ ] 視需要清理 `/var/ossec/etc/ossec.conf.new`
- [ ] Wazuh 穩定後，再排 Grafana 13.3 升級（見 [Grafana 13.3 新版整理](../grafana-13-3-release-notes/)）

## 延伸閱讀

- [Wazuh 4.14 Release notes](https://documentation.wazuh.com/4.14/release-notes/index.html)
- [Wazuh 官方升級指南](https://documentation.wazuh.com/current/upgrade-guide/index.html)
- [在 PVE Cluster 用 LXC 架設 Wazuh（一）：安裝與接上 Agent](../wazuh-lxc-ubuntu2204-sop/)
- [Wazuh 維運（二）：資料保留、告警調校、弱點修補與整合](../wazuh-lxc-ubuntu2204-operations/)
