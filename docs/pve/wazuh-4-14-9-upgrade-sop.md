---
layout: default
title: "Wazuh 4.14.8 升級到 4.14.9 SOP（All-in-one，LXC）"
date: 2026-11-02
categories: [PVE, Wazuh, Upgrade]
permalink: /docs/pve/wazuh-4-14-9-upgrade-sop/
last_modified_at: 2026-11-02
---

# Wazuh 4.14.8 升級到 4.14.9 SOP（All-in-one，LXC）

> **一句話**：Wazuh Dashboard 提示有新 patch 4.14.9；這篇把「升級前備份 → 依序升級 Indexer、Manager、Dashboard → 驗收 → 升級各台 Agent」寫成可照做的步驟。**目前尚未實測**，升級完成後會把結果補進結論。

| 項目 | 內容 |
| --- | --- |
| 適合誰看 | 自己用 LXC 架設 Wazuh All-in-one、想升級 patch 版本的人 |
| 環境 | PVE 叢集上的 LXC（Ubuntu 22.04），Wazuh All-in-one 4.14.8，Cluster 為 Disabled（單節點） |
| 日期 | 2026-11-02 整理 |
| 目標版本 | 4.14.9（2026-10-14 發布，Dashboard 顯示 Last available patch） |
| 風險 | 中：升級期間 Indexer、Manager、Dashboard 會中斷；有快照與 PBS 備份即可還原 |
| 結論 | ✅ 已整理步驟；⏳ 實測與驗收尚未進行（見待辦） |

> **關於指令**：指令是依官方 All-in-one 升級流程整理，**尚未實測**；若與官方當下版本不同，以官方為準。4.14.9 的內容見下方第 1 節（來源：官方 [4.14.9 Release notes](https://documentation.wazuh.com/4.14/release-notes/release-4-14-9.html)，2026-10-14 發布）。

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
記錄升級前狀態（版本、服務、設定檔）
   ↓
① Indexer ─→ ② Manager（含 Filebeat）─→ ③ Dashboard
   ↓
驗收（版本、告警、API、Grafana）
   ↓
④ 各台 Agent（先處理 Disconnected 的兩台）
```

重點：

- **順序固定**：Indexer → Manager／Filebeat → Dashboard。
- **升級期間會中斷**：Agent 會先把事件暫存在本機，Manager 回來後再補送（推測，依 Agent 預設行為，未實測）。
- **不要同時升級 Grafana**：兩邊同時變動，出問題時分不清原因。

## 4. 升級前準備

### 4.1 讀 release notes、確認目前狀態

做什麼：確認升級的內容與目前版本。

```bash
dpkg -l | grep -E "wazuh|filebeat" | awk '{print $2, $3}'
systemctl is-active wazuh-indexer wazuh-manager filebeat wazuh-dashboard
```

應該看到：四個套件都是 `4.14.8`（filebeat 版本號不同屬正常），四個服務都是 `active`。

### 4.2 備份

| 備份 | 指令／位置 | 為什麼 |
| --- | --- | --- |
| LXC 快照 | PVE 在這台 CT 建立快照，例如 `pre-wazuh-4.14.9` | 最快的還原方式 |
| PBS 備份 | 手動跑一次這台 CT 的備份 | 快照在同一個儲存池，壞了一起壞 |
| 設定檔 | 下方指令 | 升級後比對有沒有被改回預設 |

```bash
mkdir -p /root/wazuh-pre-4.14.9
cp -a /var/ossec/etc /root/wazuh-pre-4.14.9/ossec-etc
cp -a /etc/wazuh-indexer /root/wazuh-pre-4.14.9/indexer-etc
cp -a /etc/wazuh-dashboard /root/wazuh-pre-4.14.9/dashboard-etc
cp -a /etc/filebeat /root/wazuh-pre-4.14.9/filebeat-etc
cp -a /usr/share/wazuh-dashboard/data/wazuh/config /root/wazuh-pre-4.14.9/dashboard-wazuh-config 2>/dev/null
```

> 本環境另有自己加的設定：`api.yaml` 的 `host`、55000 的 nftables 規則、`indexer-proxy` 服務（9201）、Grafana 專用帳號。這些在升級後都要再確認，詳見 [Wazuh 維運（二）](../wazuh-lxc-ubuntu2204-operations/)。

### 4.3 記下升級前的基準值

```bash
/var/ossec/bin/agent_control -ls | head -30
curl -sk -u "<帳號>" https://127.0.0.1:9200/_cluster/health?pretty
```

| 片段 | 意思 |
| --- | --- |
| `agent_control -ls` | 列出所有 Agent 與狀態（預期 18 台：16 台 Active、2 台 Disconnected） |
| `-u "<帳號>"` | 只給帳號，密碼讓 curl 提示輸入，不要寫進指令與歷史紀錄 |
| `_cluster/health` | Indexer 健康度，預期 `green` 或單節點的 `yellow` |

## 5. 升級步驟

> 以下指令都在 Wazuh 的 LXC 內，用 root 執行。

### 5.1 ① 升級 Indexer

做什麼：先停掉會寫入 Indexer 的服務，暫停 shard allocation，再升級套件。

```bash
systemctl stop filebeat wazuh-dashboard
curl -sk -u "<帳號>" -X PUT https://127.0.0.1:9200/_cluster/settings \
  -H 'Content-Type: application/json' \
  -d '{"persistent":{"cluster.routing.allocation.enable":"primaries"}}'
curl -sk -u "<帳號>" -X POST https://127.0.0.1:9200/_flush
systemctl stop wazuh-indexer
apt-get update
apt-get install wazuh-indexer=4.14.9-1
systemctl daemon-reload
systemctl start wazuh-indexer
```

| 片段 | 意思 |
| --- | --- |
| `stop filebeat wazuh-dashboard` | 先停止寫入與查詢 |
| `allocation.enable: primaries` | 暫停副本分片的重新分配 |
| `_flush` | 把記憶體中的資料寫到磁碟 |
| `=4.14.9-1` | 指定版本；實際版本字串先用 `apt-cache madison wazuh-indexer` 確認 |
| `daemon-reload` | 重新載入 systemd 設定 |

接著恢復 allocation 並確認：

```bash
curl -sk -u "<帳號>" -X PUT https://127.0.0.1:9200/_cluster/settings \
  -H 'Content-Type: application/json' \
  -d '{"persistent":{"cluster.routing.allocation.enable":null}}'
curl -sk -u "<帳號>" https://127.0.0.1:9200/_cluster/health?pretty
```

應該看到：`status` 為 `green`（單節點可能是 `yellow`，與升級前一致即可）。

### 5.2 ② 升級 Manager 與 Filebeat

```bash
apt-get install wazuh-manager=4.14.9-1
apt-get install filebeat
systemctl daemon-reload
systemctl enable --now wazuh-manager
```

Filebeat 的 Wazuh 模組與範本，依官方升級指南更新（網址與檔名以官方文件當下內容為準）：

```bash
curl -s https://packages.wazuh.com/4.x/filebeat/wazuh-filebeat-0.5.tar.gz | tar -xvz -C /usr/share/filebeat/module
curl -so /etc/filebeat/wazuh-template.json https://raw.githubusercontent.com/wazuh/wazuh/v4.14.9/extensions/elasticsearch/7.x/wazuh-template.json
chmod go+r /etc/filebeat/wazuh-template.json
systemctl enable --now filebeat
filebeat test output
```

| 片段 | 意思 |
| --- | --- |
| `wazuh-filebeat-*.tar.gz` | Filebeat 的 Wazuh 模組，負責解析告警格式 |
| `wazuh-template.json` | 告警欄位的資料格式定義 |
| `filebeat test output` | 測試能不能連上 Indexer |

應該看到：`filebeat test output` 最後幾行是 `talk to server... OK`。

> 套件更新時若問你要不要覆蓋設定檔，選**保留目前的版本**（`N`），之後再比對 `/root/wazuh-pre-4.14.9` 的備份。

### 5.3 ③ 升級 Dashboard

```bash
apt-get install wazuh-dashboard=4.14.9-1
systemctl daemon-reload
systemctl enable --now wazuh-dashboard
```

等約 1～2 分鐘，網頁才會起來。

## 6. 驗收

| 檢查 | 指令／位置 | 預期 |
| --- | --- | --- |
| 版本 | `dpkg -l \| grep -E "wazuh\|filebeat"` | wazuh 三個套件為 4.14.9 |
| 服務 | `systemctl is-active wazuh-indexer wazuh-manager filebeat wazuh-dashboard` | 四個都是 `active` |
| Dashboard | 網頁 → Server management → API connections（`default`） | Version `v4.14.9`、Status `Online`、Updates status 的橘點消失 |
| Agent | `/var/ossec/bin/agent_control -ls` | 數量與 4.3 的基準一致（16 台 Active、2 台 Disconnected） |
| 告警 | Dashboard 的 Threat Hunting 看最近 15 分鐘 | 有新告警進來 |
| Indexer | `_cluster/health` | 與升級前一致 |
| 自訂規則 | `/var/ossec/bin/wazuh-logtest -t` | 無錯誤 |

本環境另外要驗證的項目：

| 檢查 | 怎麼確認 | 預期 |
| --- | --- | --- |
| API host 設定 | 看 `api.yaml` 的 `host`，與備份比對 | 與升級前相同 |
| 55000 規則 | `nft list ruleset` | 規則還在 |
| indexer-proxy | `systemctl is-active indexer-proxy`、9201 規則 | active、規則還在 |
| Grafana | 戰情中心 Wazuh 面板 | 有資料；`grafana` 帳號能登入 |
| jt-ipam | 同步一次 | 能連上 55000 |

## 7. ④ 升級各台 Agent

先處理那 2 台 Disconnected：確認是已下線的主機（可移除）還是異常（先修再升級）。

在 Debian／Ubuntu 的主機上：

```bash
apt-get update
apt-get install wazuh-agent=4.14.9-1
systemctl restart wazuh-agent
```

| 注意 | 說明 |
| --- | --- |
| Agent 版本不能高於 Manager | 所以 Agent 要在 Manager 升完之後才升 |
| 先小量試 | 先升 1～2 台確認回報正常，再依序升其他台 |
| 其他系統（Windows、NAS 等） | 依各平台安裝方式，不在本篇範圍 |

## 8. 還原

| 狀況 | 怎麼辦 |
| --- | --- |
| 升級中途失敗、服務起不來 | 在 PVE 把這台 CT 還原到 `pre-wazuh-4.14.9` 快照 |
| 快照有問題 | 從 PBS 備份還原 |
| 只有設定被改掉 | 從 `/root/wazuh-pre-4.14.9` 取回設定檔，重啟對應服務 |

還原後記得確認 Agent 能重新連回、Dashboard 版本為 4.14.8。

## 常見問題

| 現象 | 怎麼辦 |
| --- | --- |
| Dashboard 升級後一直轉圈 | 等 1～2 分鐘；仍不行看 `journalctl -u wazuh-dashboard -n 50` |
| Dashboard 顯示 Offline | 先確認 Indexer 與 Manager 都是 active，再重新整理 |
| `apt-get install` 找不到 4.14.9 | 確認 Wazuh 的 apt 來源存在，執行 `apt-get update` 與 `apt-cache madison wazuh-manager` |
| `filebeat test output` 失敗 | 確認 Indexer 已啟動、憑證路徑沒被覆蓋 |
| jt-ipam 或 Grafana 連不上 | 檢查 `api.yaml` 的 host、nftables 55000 規則、`indexer-proxy`，見 [Wazuh 維運（二）](../wazuh-lxc-ubuntu2204-operations/) |
| Grafana 資料來源憑證錯誤 | 若 Indexer 憑證或 root CA 有變，更新資料來源的 CA，見 [Grafana 戰情中心（一）](../grafana-war-room-wazuh/) |

## 待辦

- [x] 讀 4.14.9 release notes：無 breaking change、無 CVE 編號（官方頁面未列出）
- [ ] 升級後比對弱點數量與 SCA 通過率的前後差異（#38474、SCA 修正可能造成變動）
- [ ] 建立快照與 PBS 備份
- [ ] 實測升級並記錄各步驟的實際輸出與耗時（中斷多久）
- [ ] 驗收「本環境另外要驗證」的 5 項
- [ ] 升級各台 Agent；處理 2 台 Disconnected
- [ ] 升級完成後把實測結果補進本文結論，並移除未確認標註
- [ ] Wazuh 穩定後，再排 Grafana 13.3 升級（見 [Grafana 13.3 新版整理](../grafana-13-3-release-notes/)）

## 延伸閱讀

- [Wazuh 4.14 Release notes](https://documentation.wazuh.com/4.14/release-notes/index.html)
- [Wazuh 官方升級指南](https://documentation.wazuh.com/current/upgrade-guide/index.html)
- [在 PVE Cluster 用 LXC 架設 Wazuh（一）：安裝與接上 Agent](../wazuh-lxc-ubuntu2204-sop/)
- [Wazuh 維運（二）：資料保留、告警調校、弱點修補與整合](../wazuh-lxc-ubuntu2204-operations/)
