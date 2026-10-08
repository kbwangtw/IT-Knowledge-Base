---
layout: default
title: "把三台 PVE 的日誌集中到 Graylog"
date: 2026-09-17
categories: [PVE, Graylog, Syslog]
permalink: /docs/pve/proxmox-graylog-syslog-pipeline-sop/
last_modified_at: 2026-10-08
---

# 把三台 PVE 的日誌集中到 Graylog

日誌分散在三台主機時，要查「哪台出錯、哪個工作失敗」得逐台找。本次把 node10、node11、node12 的日誌送進 Graylog，再替訊息加上來源、類型與任務狀態，做成任務監控看板，並接上 PVE 任務失敗 Email 警報。

> 紀錄期間：2026-09-17～2026-09-22；Graylog 7.1.9，部署於 LXC。9/22 依 Proxmox VE 9.2.20 真實 log 修正 Task Failed，並以 logger 安全測試確認 Pipeline → Event Definition → Gmail 完整成功；多次驗證失敗加入 Group by source 後也完整驗證成功。PVE 服務異常維持已完成狀態。

9/18 已完成告警設定與 Gmail SMTP 排錯；9/22 完成上述兩項改良與正式收信驗證。本次文件更新依操作紀錄整理，沒有重新操作 Graylog 或 PVE，也沒有為測試破壞 VM／CT／Ceph。本文仍不是最新版全部規則的匯出檔。

完整設定、真實 log 證據與 logger 安全測試分別記錄於 [PVE 告警實測紀錄（更新至 2026-09-22）](https://kbwangtw.github.io/IT-Knowledge-Base/docs/pve/graylog-pve-alert-validation-2026-09-18/)。

## 先認識四個名詞

| 名稱 | 白話意思 | 本案名稱 |
| --- | --- | --- |
| Input | 收日誌的入口 | Syslog UDP 1514 |
| Stream | 把相關訊息放在一起 | Infrastructure Syslog |
| Pipeline | 替訊息分類、拆出欄位的規則 | Infrastructure Syslog |
| Index Set | 決定訊息存在哪一組索引 | infra_syslog |

本次實際索引可見 infra_syslog_0。看板只是呈現資料，來源分類與欄位解析要先做好。

~~~text
三台 PVE → rsyslog → Graylog UDP 1514
  → Infrastructure Syslog Stream
  → 分類與欄位解析
  → infra_syslog 索引
    ├─ 搜尋與「PVE 任務監控」看板
    └─ pve_event_type:task_failed
       →「PVE 任務失敗警報」Event Definition
       →「PVE 任務失敗通知」→ Gmail
~~~

9/22 已以新的 logger 合成訊息驗證最後三段與正式 Gmail 收信；這是告警鏈路驗收，不是真實 VM／CT 故障操作。

## 1. 先讓三台日誌都進得來

在各 PVE 節點設定轉送；192.0.2.24 是文件示範位址，請替換成自己的 Graylog：

~~~bash
cat > /etc/rsyslog.d/60-graylog.conf <<'EOF'
# Forward PVE syslog messages to Graylog
*.* @192.0.2.24:1514
EOF
~~~

先檢查語法，成功後才重啟：

~~~bash
rsyslogd -N1
systemctl restart rsyslog
systemctl status rsyslog --no-pager
~~~

這裡單一 @ 表示 UDP。Graylog 也要有對應的 UDP 1514 Input。完成後逐台搜尋 source，確認 node10、node11、node12 都有新訊息，不只看服務顯示 running。

## 2. 第一層：認出主機，再標記一般事件

Stage 0 放三類規則：

| 規則 | 在做什麼 |
| --- | --- |
| PVE - Identify Cluster Nodes | source 是三台節點之一時，加入 device_type=pve、pve_cluster=PVE-Cluster |
| PVE-Authentication Events | 標記認證相關訊息 |
| Infrastructure - System Errors | 找 DENIED、failed、error 等字樣，標記 system_error |

一般錯誤的文字比對是初步分類，不能單靠一個 error 字樣就判定整個服務故障；仍須看原訊息。

可產生可辨識的測試訊息：

~~~bash
logger -p auth.info -t pam_unix "Graylog authentication pipeline test"
logger -p kern.warning -t INFRA_ERROR_TEST "DENIED Graylog infrastructure system error test"
~~~

回到 Graylog 開啟訊息，核對來源與新增欄位。訊息收到了、欄位卻沒有出現，問題可能在規則或 Pipeline 與 Stream 的連接。

### 規則改名後，Stage 也要檢查

本次曾出現：

~~~text
Rule PVE - System Errors has been renamed or removed. This rule will be skipped.
~~~

原因是 Stage 還引用舊名稱。移除舊引用，再加入新的 Infrastructure - System Errors 後恢復。規則清單裡有新名稱，不代表所有 Stage 已自動更新。

## 3. 第二層：把 systemd 的服務事件分出來

Stage 1 判讀 systemd 相關訊息中的 Started、Stopped、Starting、Stopping、Reached target，標記 event_category=service。

本次已測過五種訊息。規則使用 Source Code Editor 編輯，避免把「systemd 且任一事件文字」誤設成全部條件都必須成立：

~~~text
rule "PVE - Service Events"
when
    contains(to_string($message.message), "systemd", true)
    &&
    (
        contains(to_string($message.message), "Started", true)
        ||
        contains(to_string($message.message), "Stopped", true)
        ||
        contains(to_string($message.message), "Starting", true)
        ||
        contains(to_string($message.message), "Stopping", true)
        ||
        contains(to_string($message.message), "Reached target", true)
    )
then
    set_field("event_category", "service");
end
~~~

測試範例：

~~~bash
logger -p daemon.info -t systemd "Started graylog-pipeline-test.service - Graylog Pipeline Test Service"
logger -p daemon.info -t systemd "Stopped graylog-pipeline-test.service - Graylog Pipeline Test Service"
logger -p daemon.info -t systemd "Starting graylog-pipeline-test.service - Graylog Pipeline Test Service"
logger -p daemon.info -t systemd "Stopping graylog-pipeline-test.service - Graylog Pipeline Test Service"
logger -p daemon.info -t systemd "Reached target graylog-pipeline-test.target - Graylog Pipeline Test Target"
~~~

本案 Stage 1、Stage 2 使用「None or more rules on this stage match」的繼續條件。不要把某一類沒有命中，誤設成所有後續處理都停止。Stage 0 的來源識別也必須能讓預期的 PVE 訊息通過。

## 4. 第三層：辨認 PVE 任務與結果

PVE 的 pvedaemon 日誌會出現 UPID，也就是工作的識別資料。最基本的分類規則如下：

~~~text
rule "PVE - Task Events"
when
    contains(to_string($message.message), "pvedaemon", true)
    &&
    contains(to_string($message.message), "UPID:", true)
then
    set_field("event_category", "pve_task");
end
~~~

這段只把訊息分成 pve_task，**不會自動完成所有任務欄位解析**。

### 已建立的 Pipeline 規則

目前 PVE 規則連到 Infrastructure Syslog。下表整理規則職責；Stage 編排沿用前述紀錄，沒有把未取得的完整設定推測成可直接匯入的版本。

| 規則 | 用途／可核對的結果 |
| --- | --- |
| PVE - Identify Cluster Nodes | 識別 node10、node11、node12，標記 PVE 與叢集來源 |
| PVE - Parse Task UPID | 拆解任務識別資料，供節點、任務、VM／CT 與使用者欄位使用 |
| PVE - Service Events | 分類 systemd 服務事件 |
| PVE - Task Events | 將含 pvedaemon 與 UPID 的訊息分類為 pve_task |
| PVE - Task Started | 分類任務開始，與結束結果分開 |
| PVE - Task Success | 分類成功結果 |
| PVE - Task Warning | 分類警告結果 |
| PVE - Task Failed | 9/22 修正非 `: OK` 的結束訊息分類；安全測試完整告警鏈路成功 |
| PVE-Authentication Events | 分類認證事件；不等於已建立認證告警 |
| Infrastructure - System Errors | 一般錯誤分類；不能取代任務結果判讀 |

最新版任務欄位：

| 欄位 | 代表什麼 |
| --- | --- |
| pve_event_type | 事件類型 |
| pve_task_name | 工作名稱 |
| pve_task_node | 執行節點 |
| pve_vmid | VM／CT 編號；有些任務沒有這個值 |
| pve_task_user | 執行使用者 |
| pve_task_status | started、success、warning 或 failed |

初期規則曾用 task_status，後續改為 pve_task_status。新看板應使用後者，不能把初期範例當作完整最新版。本紀錄沒有保存最新版全部解析原始碼，因此不提供拼湊的「一鍵匯入」。

三台任務來源已有驗證，node11、node12 的 pveupdate／aptupdate 也有真實成功事件。

### 搜尋不到時，先放寬條件

本次用 source:node10 AND "UPID:" 查最近 5 分鐘沒有結果；改查 pvedaemon 並延長到 15 分鐘，才找到訊息：

~~~text
source:node10 AND pvedaemon
~~~

零筆結果可能只是時間或查詢條件不同，不等於日誌沒送到。先找到原訊息，再核對分類欄位。

### Task Failed：用歷史失敗樣本確認規則

9/18 建立告警時，`pve_event_type:task_failed` 的預覽為 0。先在 Infrastructure Syslog 查最近 24 小時的 `message:"end task"`，得到 34 筆任務結束訊息，三台節點都有資料；再加上失敗條件，最近 24 小時為 0。延長至最近 7 天後，才找到 1 筆歷史失敗：

| 項目 | 歷史紀錄 |
| --- | --- |
| 時間 | 2026-09-16 07:09:32（原搜尋畫面時間，時區未另核對） |
| Source | node10 |
| Task | vncproxy |
| VMID | 100 |
| 原始結果 | command '/usr/bin/termproxy' failed: exit code 1 |

使用的原始訊息搜尋條件：

~~~text
message:"end task" AND message:failed
~~~

這筆舊訊息已有 device_type=pve、event_category=system_error、pve_cluster=PVE-Cluster，但沒有 pve_event_type。它早於本次任務分類規則；新增 Pipeline 規則不會自動替已寫入索引的歷史訊息補欄位。因此沒有為了這筆舊資料改壞既有規則，也沒有把告警的正式搜尋範圍留在 7 天。

9/18 舊規則要求 `end task UPID:` 且包含 `failed:`，僅通過該歷史樣本模擬，會漏掉 PVE 9.2.20 的 `migration aborted`、`CT is locked (backup)`、`unable to get PID for CT ... (not running?)`。以下為 **2026-09-22 修正後的最終 `PVE - Task Failed`**：

~~~text
rule "PVE - Task Failed"
when
    has_field("message") &&
    contains(to_string($message.message), "end task UPID:") &&
    !ends_with(to_string($message.message), ": OK")
then
    set_field("pve_event_type", "task_failed");
    set_field("pve_task_status", "failed");
end
~~~

Simulation 使用這筆真實失敗格式：

~~~text
node10 pvedaemon[4129114]: <root@pam> end task UPID:node10:00022D58:0191F4A8:6AAA40A2:vncproxy:100:root@pam: command '/usr/bin/termproxy' failed: exit code 1
~~~

結果確實產生 `pve_event_type = task_failed` 與 `pve_task_status = failed`，因此 9/18 當時未修改規則；9/22 已依新證據修正。這項驗證證明此樣本可被規則辨識；不代表所有 PVE 失敗格式都已覆蓋，也不是新訊息通過完整 Stream／Pipeline／Alert 的驗收。

### 2026-09-22 修正理由與驗收

真實 PVE 9.2.20 成功 Task 以 `: OK` 結尾；`PVE - Task Success` 已使用 `end task UPID:` 加上 `ends_with(..., ": OK")`，不需修改。Failed 改為所有包含 `end task UPID:` 且不是 `: OK` 結尾的訊息，避免維護一長串錯誤字串並解決漏報。

node10 的安全測試使用以下合成訊息，沒有實際操作 VM／CT 999：

~~~bash
logger -p daemon.warning "end task UPID:node10:TEST:TEST:TEST:vzstart:999:root@pam: GRAYLOG-PVE-TASK-FAILED-TEST"
~~~

已確認 `device_type=pve`、`event_category=pve_task`、`pve_cluster=PVE-Cluster`、`pve_event_type=task_failed`、`pve_task_name=vzstart`、`pve_task_node=node10`、`pve_task_status=failed`、`pve_task_user=root@pam`、`pve_vmid=999`，並 Routed into streams `Infrastructure Syslog`。Event Definition Last Matched 更新為幾分鐘前，Gmail 正式告警已收到。真實 log 是修正依據，logger 是鏈路安全測試，沒有為測試破壞 VM／CT／Ceph。

## 5. 看板：先看整體，再看異常明細

9/17 的既有紀錄已包含「PVE 任務監控」八個 Widget；9/18 本輪聚焦告警與 SMTP，未重新逐項驗收看板。這份基礎看板保留，後續再整合節點、服務與登入等 Infrastructure Dashboard 內容。

| 區塊 | 內容 |
| --- | --- |
| 四個數字 | failed、warning、success、started |
| 狀態趨勢 | 看不同狀態隨時間的變化 |
| 節點統計 | 哪個節點有多少完成事件 |
| 任務種類統計 | 哪一類工作最多 |
| 最近異常 | 逐筆列出 warning／failed |

每個 Widget 都明確限制 Infrastructure Syslog Stream，時間範圍使用最近一天到現在。不要只因 Dashboard 名稱正確，就以為每個 Widget 都選到正確 Stream。

節點與種類統計排除 started，避免把同一工作的開始和結束都混進完成統計：

~~~text
pve_task_status:success OR pve_task_status:warning OR pve_task_status:failed
~~~

分組使用 pve_task_node 或 pve_task_name，並略過空值。最近異常使用：

~~~text
pve_task_status:warning OR pve_task_status:failed
~~~

明細依 timestamp 由新到舊，顯示時間、節點、任務、VMID、使用者與狀態。VMID 空白不一定是解析失敗，先確認那種任務是否本來就沒有 VMID。

## 6. 建立「PVE 任務失敗警報」

在 Alerts → Event Definitions 建立條件，Rule Simulation 成功後，正式設定回到每 5 分鐘查最近 5 分鐘：

| 欄位 | 已儲存設定 |
| --- | --- |
| Title | PVE 任務失敗警報 |
| Description | 偵測 Proxmox VE 任務執行失敗事件 |
| Priority | High（清單顯示 3） |
| Condition Type | Filter & Aggregation |
| Search Query | pve_event_type:task_failed |
| Stream | Infrastructure Syslog |
| Search within the last | 5 minutes |
| Execute search every | 5 minutes |
| Enable scheduling／Status | Yes／enabled |
| Create Events | Filter has results |
| Event Limit | 100 |
| Custom Fields | 第一版未新增 |

當時填入的 Event Summary Template 是 `PVE 任務失敗：${source.message}`。**尚未用實際 Event 驗證這個變數能否帶出原始訊息**，因此不能宣稱信件已完整顯示故障原因；這項列入後續改善。

建立與綁定完成時，Last Matched 仍是 Never，當時沒有新的失敗命中紀錄。這本身不能用來判定規則壞掉，也不能當作自動告警已通過的證據。9/22 已以新 logger 測試訊息確認 Last Matched 更新與正式 Gmail 收信。

## 7. Gmail SMTP：從連線查到帳號驗證

Graylog 的 Email Transport 放在 `/etc/graylog/server/server.conf`；Notification 則是在網頁設定通知名稱、收件人和內容，兩者都要完成。

以下只記錄本次確認的非機密設定。帳號以佔位文字表示，**刻意省略密碼設定行**，不是可直接覆蓋主機設定檔的完整範本：

~~~ini
transport_email_enabled = true
transport_email_hostname = smtp.gmail.com
transport_email_port = 587
transport_email_use_auth = true
transport_email_auth_username = <GMAIL_ACCOUNT>
transport_email_from_email = <GMAIL_ACCOUNT>
transport_email_socket_connection_timeout = 10s
transport_email_socket_timeout = 10s
transport_email_use_tls = true
transport_email_use_ssl = false
~~~

這次使用 587 搭配 STARTTLS（use_tls=true），use_ssl=false 不代表沒有加密。`transport_email_auth_password` 在主機端私下設定為驗證成功的 Gmail App Password；本文、附件與 Git 歷史更新均不包含它的值，也不保存可逆的 Base64 密碼。

### 實際排錯順序與結論

| 步驟 | 觀察到什麼 | 如何判讀／處理 |
| --- | --- | --- |
| Email Transport | 曾出現未啟用 Email Transport 的系統通知 | 設定 SMTP 並重啟後，要核對通知時間，不能把舊警告當成新結果 |
| 收件人格式 | server.log 出現 AddressException、Domain contains illegal character；地址多了一個 @ | 修正收件地址。此問題與後續 SMTP AUTH 535 分開處理 |
| Notification 儲存 | 曾停在未儲存表單，清單沒有該通知 | 先建立並儲存「PVE 任務失敗通知」，之後在既有項目上測試 |
| 日誌時序 | journalctl 未查到相關新紀錄；server.log 尾端仍是舊地址錯誤 | 沒有新 log 不代表寄信成功；不能反覆拿舊錯誤推斷本次原因 |
| TCP 587 | `nc -vz smtp.gmail.com 587` 顯示 `587 (submission) open` | 當時主機可連線至 Gmail 587；另有 DNS fwd/rev mismatch 提示，但 TCP 實測成功 |
| STARTTLS／憑證 | OpenSSL 顯示 `Verification: OK`、`Verify return code: 0 (ok)`，TLS 1.3 握手成功 | 當時 TLS 與憑證鏈驗證正常，轉查 SMTP AUTH |
| App Password 格式 | 原先 19 字元，移除 3 個空格後成為 16 字元 | 格式修正後仍失敗；長度正確不等於 Google 接受密碼 |
| 舊密碼驗證 | 互動式 SMTP 測試回傳 `SMTPAuthenticationError(535, ...)` 與 `5.7.8 Username and Password not accepted` | 舊憑證未被 Gmail 接受，不能只靠改 TLS 或 Notification 解決 |
| 新密碼驗證 | 重新產生 App Password，以不回顯的方式輸入測試，得到 `SMTP AUTH SUCCESS` | 新憑證已通過驗證；沒有在聊天或文件中記錄密碼 |
| Graylog 實測 | 私下更新主機設定、重啟後服務為 active (running)，再測既有 Notification | Gmail 實際收到 Graylog Test Notification Email，使用者另行確認「收到信了」 |

本案可確認的結論是：TCP 與 STARTTLS 已通過，舊 App Password 的 AUTH 失敗；更換新的 App Password 後，AUTH 與 Graylog 測試寄信成功。紀錄不足以判定舊密碼究竟被撤銷、抄錯或因其他帳戶原因失效，不再推測。

當時用來分層檢查的兩條指令如下，僅供日後排錯參考，本次整理沒有執行它們：

~~~bash
nc -vz smtp.gmail.com 587
openssl s_client -starttls smtp -connect smtp.gmail.com:587 -crlf
~~~

檢查重點是連線與憑證驗證結果，不需要公開整份憑證或認證對話。SMTP AUTH 測試採互動、不回顯的密碼輸入，避免把密碼寫在命令列、截圖或原始紀錄中。Graylog UI 顯示 Notification executed successfully 也不能取代實際收信確認。

## 8. 把 Email Notification 掛回告警

| 項目 | 最後確認狀態 |
| --- | --- |
| Notification Title | PVE 任務失敗通知 |
| Notification Type | Email Notification |
| Description | 當 Proxmox VE 任務執行失敗時發送警報通知 |
| Subject | 【Graylog 警報】${event_definition_title} |
| Sender／Email recipient(s) | 已核對正確的 Gmail 地址；公開文件不列實際地址 |
| Time zone | Taipei；測試信顯示 +08:00 |
| Body／HTML Body Template | 保留 Graylog 預設模板 |
| 測試收件 | 2026-09-18 實際收到測試信；信內時間 14:28:26.023+08:00 |

收信確認後，回到 Alerts → Event Definitions →「PVE 任務失敗警報」→ Edit → Notifications，加入既有「PVE 任務失敗通知」。最後 Summary 顯示：

| 欄位 | 已確認值 |
| --- | --- |
| Notification | PVE 任務失敗通知（Email Notification） |
| Grace Period | 5 minutes |
| Message Backlog | 0 |

Grace Period 設為 5 分鐘，用於限制重複通知；實際連續事件下的通知行為仍待測。Message Backlog=0，所以 Summary 出現 `Notifications will not include any messages.`：信件不附帶 backlog 原始訊息，並非通知沒有綁定。

按下 **Update event definition** 後，畫面顯示 `Event Definition "PVE 任務失敗警報" was updated successfully.`，確認通知綁定已儲存。這與只在下拉選單選到通知、尚未完成儲存不同。

## 9. 套件更新（2026-10-03）

Graylog 容器（CT105，Debian 12 bookworm）有 9 個套件待更新：6 個 Debian 安全性更新（openssl、libssl3、libexpat1、liblzma5、xz-utils、tzdata）、2 個 MongoDB 用戶端工具（mongodb-database-tools、mongodb-mongosh），以及 opensearch 2.19.5 → 2.19.6。MongoDB 伺服器與 graylog-server 不在清單中，沒有版本相容問題。

**更新前**：確認三個服務 active、OpenSearch `green`，並建立快照（說明一律用英文，避免 listsnapshot 亂碼）：

~~~bash
pct exec 105 -- systemctl is-active graylog-server mongod opensearch
pct exec 105 -- curl -s 'http://127.0.0.1:9200/_cluster/health?pretty' | grep -E '"status"|number_of_nodes'
pct snapshot 105 pre-apt-20261003 --description "Before apt upgrade (opensearch 2.19.6, openssl)"
~~~

**更新順序**：停止 graylog-server → `apt-get upgrade`（`--force-confold` 保留現有設定檔）→ 重啟 mongod（套用新版 OpenSSL）→ 重啟 opensearch 並等到 `green` → 啟動 graylog-server，等 `/api/system/lbstatus` 回 `ALIVE`。

注意事項：

- **opensearch 與 graylog-server 被 `apt-mark hold` 鎖定**（Graylog 安裝說明的建議，避免 `apt upgrade` 意外升級成不相容版本），所以第一次 `apt-get upgrade` 只更新了其他 8 個套件。以 `apt-mark showhold` 確認，`apt-get -s install opensearch` 模擬確認沒有其他相依變動後，另做有控制的升級。
- OpenSearch 剛重啟時健康狀態會短暫為 `red`（分片載入中），要用 `_cluster/health?wait_for_status=green&timeout=120s` 等待，不能只看第一次回應。
- 停止期間 PVE 節點以 UDP 送來的 syslog 會漏收。

**opensearch 有控制的升級**（先建新快照，暫時解鎖、只升級這一個套件、立即重新鎖定）：

~~~bash
pct snapshot 105 pre-opensearch-2196 --description "Before opensearch 2.19.5 to 2.19.6"
# 容器內執行
systemctl stop graylog-server
apt-mark unhold opensearch
DEBIAN_FRONTEND=noninteractive apt-get -y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold install opensearch
apt-mark hold opensearch
systemctl restart opensearch
curl -s 'http://127.0.0.1:9200/_cluster/health?wait_for_status=green&timeout=120s'
curl -s http://127.0.0.1:9200 | grep '"number"'        # 執行中的版本
systemctl start graylog-server
curl -s http://<Graylog 位址>:9000/api/system/lbstatus  # ALIVE
~~~

**結果**：OpenSearch 2.19.6、`green`、分片 100%；Graylog `ALIVE`，啟動後沒有新的 ERROR；`apt-mark showhold` 仍為 graylog-server、opensearch；已無待更新套件。

確認運作正常後已刪除兩個快照（`pct delsnapshot 105 <名稱>`，2026-10-04）。

**Debian 13 升級：暫緩（2026-10-04 查證）**

| 項目 | 查證結果 |
| --- | --- |
| Graylog 官方支援 | 官方相容性表列出 Debian 12（依搜尋結果摘要，官方文件網站本環境無法直接開啟）；GitHub issue「Support for Debian/trixie v13」（Graylog2/graylog2-server #23512，2025-08-30 提出）仍為 Open，沒有官方回覆或時程 |
| MongoDB | 套件庫依 Debian 版本分開發布，目前使用 `bookworm/mongodb-org/8.0`。2026-10-04 自容器實測 `repo.mongodb.org/apt/debian/dists/trixie/mongodb-org/8.0` 與 `8.2` 的 Release 檔皆回 **200**，官方套件庫已提供 trixie 版本 |
| Graylog、OpenSearch 套件 | 內建 Java、不分 Debian 版本，影響較小 |
| 急迫性 | Debian 12 仍在長期支援期間，持續收到 `oldstable-security` 更新 |

（2026-10-06 已以測試容器驗證可行，見第 10 節。）

結論：維持 Debian 12，持續套用安全性更新。MongoDB 的條件已具備，**剩下的條件**：Graylog 官方相容性表列入 Debian 13（或 #23512 有官方回覆）；若 Debian 12 長期支援即將結束而 Graylog 仍未支援，改以新建容器重新安裝、再搬移資料的方式進行。升級時 MongoDB 套件來源要一併由 `bookworm` 改為 `trixie`。

確認 MongoDB 套件庫（在 PVE 節點執行，200 代表已提供）：

~~~bash
for v in 8.0 8.2; do echo -n "mongodb $v trixie: "; pct exec 105 -- curl -s -o /dev/null -w '%{http_code}\n' https://repo.mongodb.org/apt/debian/dists/trixie/mongodb-org/$v/Release; done
~~~

參考：[Graylog Compatibility Matrix](https://go2docs.graylog.org/current/downloading_and_installing_graylog/compatibility_matrix.htm)、[Graylog2/graylog2-server#23512](https://github.com/Graylog2/graylog2-server/issues/23512)。

## 10. Debian 13 升級測試（2026-10-06）

Graylog 官方尚未列入 Debian 13，因此先以**複製出的測試容器**驗證，正式機不受影響。

**建立隔離的測試容器**（CT 905，放在記憶體較充裕的節點）：

~~~bash
pct snapshot 105 pre-clone-trixie --description "Source for Debian 13 upgrade test clone"
pct clone 105 905 --full --snapname pre-clone-trixie --hostname graylog-test --target node12
pct delsnapshot 105 pre-clone-trixie
# 在 node12：改用臨時 IP、不指定 MAC（自動產生新的）、先拔網路線
pct set 905 --net0 name=eth0,bridge=vmbr0,firewall=1,ip=<臨時 IP>/24,gw=<閘道>,link_down=1
pct set 905 --onboot 0
pct start 905
pct exec 905 -- systemctl disable --now wazuh-agent graylog-server   # 避免 Agent 身分衝突與重複告警
# 確認後才接上網路（保留自動產生的 MAC）
pct set 905 --net0 name=eth0,bridge=vmbr0,firewall=1,ip=<臨時 IP>/24,gw=<閘道>,hwaddr=<自動產生的 MAC>
~~~

注意：

- 複製品的 IP、MAC、Wazuh Agent 身分與正式機相同，**必須先斷網**再改 IP、停用 Agent 與 graylog-server。
- 臨時 IP 先以 ping 確認沒有回應（`Destination Host Unreachable` 代表 ARP 也無人回應）；本案曾誤用未確認的範例 IP，立即改回已確認的位址。
- Graylog 的 `http_bind_address` 寫死正式機 IP，只在測試容器內改成臨時 IP（OpenSearch、MongoDB 綁 127.0.0.1，不受影響）。

**升級步驟**（容器內執行）：停止 opensearch、mongod → 備份套件來源 → Debian 與 MongoDB 套件來源的 `bookworm` 改為 `trixie`（OpenSearch、Graylog 套件來源不分版本，不需改）→ `apt-get update` → `upgrade --without-new-pkgs` → `full-upgrade`（皆 `--force-confold`）→ `autoremove`。

~~~bash
sed -i 's/\bbookworm\b/trixie/g' /etc/apt/sources.list
grep -rl bookworm /etc/apt/sources.list.d/ | xargs -r sed -i 's/\bbookworm\b/trixie/g'
~~~

**結果**：173 個套件升級後，`full-upgrade` 再升級 84、新增 55、移除 20；Debian 13.7；`apt-mark showhold` 仍為 graylog-server、opensearch。重開機後：

| 項目 | 結果 |
| --- | --- |
| 系統 | Debian 13 (trixie)，`systemctl is-system-running` 為 running，無失敗服務 |
| MongoDB | active，v8.0.32 |
| OpenSearch | active，green，分片 100% |
| Graylog | 7.1.9，`/api/system/lbstatus` 為 ALIVE，啟動後無新的 ERROR |
| 網頁 | 以臨時 IP 登入正常，Search、Streams、Pipelines 等頁面皆可開啟 |

測試容器的 Graylog 只暫時啟動驗證，完成後停止，避免背景執行告警規則寄出重複告警信。

**升級後發現的套件來源問題**（服務都正常，但會讓之後收不到更新）：

| 套件來源 | 問題 | 處理 |
| --- | --- | --- |
| MongoDB | `trixie/mongodb-org/8.0` 的 Release 檔存在（HTTP 200），但**沒有任何套件**；`apt-cache policy` 只剩 `/var/lib/dpkg/status`，系統沿用原本 bookworm 版本的 8.0.32 | MongoDB 套件來源**維持 bookworm**（bookworm 版本在 Debian 13 上可正常執行），改回後版本表出現 8.0.14～8.0.32 |
| OpenSearch（金鑰格式） | Debian 13 的 apt 改用 `sqv` 驗證簽章，無法讀取以 `gpg --keyring` 匯入的 GnuPG keybox 格式（`file` 顯示 `GPG keybox database`），錯誤為 `Failed to parse keyring ... EOF` | 匯出成標準格式：`gpg --no-default-keyring --keyring <檔案> --export > <新檔>`，`file` 顯示 `OpenPGP Public Key` |
| OpenSearch（SHA1） | 2.x 套件庫仍以 2021 年的金鑰 `C5B7 4989 65EF D1C2 924B A9D5 39D3 1987 9310 D3FC` 簽署，該金鑰的綁定簽章使用 SHA1；sqv 自 2026-02-01 起拒絕（`SHA1 is not considered secure`）。重新下載 `opensearch.pgp` 仍是同一把未更新的金鑰；`opensearch-release.pgp` 是 2025 年的新金鑰（`A8B2 D9E0 4CD5 1FEF 6AA2 DB53 BA81 D999 8119 1457`），但 2.x 套件庫尚未改用它簽署（`Missing key C5B7…`） | **無法解決**，OpenSearch 在 Debian 13 上無法透過 apt 更新 |

注意：升級過程中第 4 步的 `apt-get update` 仍是 Debian 12 的 apt（gpgv），所以不會報錯；要升級完成後以新的 apt 再執行一次 `apt-get update`，才會發現金鑰問題。

**結論：正式機暫緩升級**。Debian 12 上三個套件來源都能正常更新；升級到 Debian 13 會讓 OpenSearch 收不到更新（除非放寬整台主機 apt 的 SHA1 規則）。**可以升級的條件**：OpenSearch 2.x 套件庫改用新金鑰簽署。確認方式（在任一台可連網的主機上，看 InRelease 由哪一把金鑰簽署）：

~~~bash
curl -s https://artifacts.opensearch.org/releases/bundle/opensearch/2.x/apt/dists/stable/InRelease | gpg --verify 2>&1 | grep -iE 'key|using'
~~~

顯示的金鑰變成 `A8B2…1457`（或其他以 SHA256 簽署的金鑰）時，即可依本節步驟升級，並同時處理：MongoDB 套件來源維持 bookworm、OpenSearch 金鑰改為新金鑰的標準格式。

測試完成後已刪除測試容器（`pct stop 905 && pct destroy 905 --purge`，連同 Ceph 上的磁碟），臨時 IP 一併釋出。之後要再測試，從 CT105 重新複製即可（6.7 GB，約 1 分鐘）。

**正式機升級計畫**（待上述條件成立後執行）：與測試相同的步驟，差異如下。

| 項目 | 正式機做法 |
| --- | --- |
| 時段 | 停機約 20～30 分鐘，期間 UDP syslog 會漏收，選離峰時段，避開 21:00 備份 |
| 保護 | 確認前一晚 PBS 備份成功，升級前建立快照 |
| 服務 | 升級前先停止 graylog-server；Wazuh Agent 維持啟用；`http_bind_address` 不需修改 |
| 重開機 | CT105 為 HA 資源，從容器內執行 `reboot` |
| 驗證 | 同測試項目，另確認 Wazuh Agent、LibreNMS 輪詢、Graylog 收到新日誌 |
| 收尾 | 正式機確認正常後刪除測試容器（`pct destroy 905 --purge`），快照觀察數天後刪除 |

## 11. 加入 PBS 的日誌（2026-10-08）

PBS31 是獨立主機（PBS 4，Debian 13），先前只有 Wazuh Agent 與 SNMP，日誌未送到 Graylog。沿用三台 PVE 的 UDP 1514 Input 與 Infrastructure Syslog stream，Graylog 不需新增 Input。

**PBS 端**：Debian 13 預設只有 journald，PBS31 沒有安裝 rsyslog（`/etc/rsyslog.d/` 只有 postfix 套件放的 `postfix.conf`），先安裝再加轉送設定。避開 21:00 排程備份時段。

~~~bash
apt update                 # 企業版套件來源回報 401 可忽略
apt install rsyslog        # 確認只有安裝、沒有移除任何套件
cat > /etc/rsyslog.d/60-graylog.conf <<'EOF'
# Forward PBS syslog messages to Graylog
*.* @192.0.2.24:1514
EOF
rsyslogd -N1               # End of config validation run. Bye.
systemctl restart rsyslog
systemctl is-active rsyslog; systemctl is-enabled rsyslog   # active / enabled
systemctl is-active proxmox-backup-proxy                    # active：備份服務未受影響
logger -t GRAYLOG_TEST "PBS31 graylog forwarding test"
~~~

在 Graylog 以 `source:pbs31 AND GRAYLOG_TEST` 找到測試訊息，確認 Received by 為 Syslog UDP 1514、Routed into streams 為 Infrastructure Syslog、存入 infra_syslog 索引。

**Pipeline**：原有的 PVE - Identify Cluster Nodes 只認得三台 PVE，新增規則並加入 Infrastructure Syslog 的 Stage 0：

~~~text
rule "PBS - Identify Backup Server"
when
    to_string($message.source) == "pbs31"
then
    set_field("device_type", "pbs");
    set_field("pbs_server", "pbs31");
end
~~~

儲存前先用規則編輯頁的 Rule Simulation（JSON：`{"source": "pbs31", "message": "test"}`）確認會加上 `device_type`、`pbs_server`。加入 Stage 0 後再以 `logger -t GRAYLOG_TEST "PBS31 pipeline test"` 實測，`source:pbs31 AND device_type:pbs` 找到訊息且兩個欄位都存在。

Graylog 訊息的 timestamp 以 UTC 顯示（比台灣時間少 8 小時），可在個人設定的 Time zone 改為 Asia/Taipei，只影響自己的顯示。

待辦：

- PBS 任務（備份、GC、Verify、Sync）的日誌來自 proxmox-backup-proxy，與 PVE 的 pvedaemon 格式不同，現有「PVE 任務失敗警報」不適用。待排程備份產生真實日誌後，依實際格式建立 PBS 任務分類與失敗告警。
- PVE - Authentication Events 的描述只涵蓋 PVE 節點，確認 PBS 的登入與 sudo 事件是否需要一併分類。

## 目前完成與待辦

截至 2026-09-22，三項核心告警已完成所述測試範圍；其他監控項目與通知明細仍待完善。

| 範圍 | 目前進度／驗證界線 |
| --- | --- |
| Syslog／Stream | 三台 PVE 與 PBS31 接收與 Infrastructure Syslog 已驗證（PBS 於 2026-10-08 加入，見第 11 節） |
| Pipeline | 主機、服務、任務、認證、系統錯誤分類已建立；既有五種服務事件測試與任務欄位紀錄保留 |
| PVE 任務失敗警報 | 完整驗證成功：PVE 9.2.20 Rule 修正後，logger → Pipeline → Event → Gmail；未回填歷史索引 |
| PVE 多次驗證失敗 | 完整驗證成功：Group by source，node10 三筆 → Last Matched → 正式 Gmail |
| PVE 服務異常 | 維持已完成（9/18 Pipeline、Event、Gmail） |
| Event Definition | PVE 任務失敗警報已啟用，每 5 分鐘查最近 5 分鐘，High |
| Email | Gmail AUTH、測試信及上述三項正式告警均已確認 |
| 通知綁定 | 已儲存，Grace Period 5 minutes、Message Backlog 0 |
| Dashboard | 既有任務看板八個 Widget 的紀錄保留；整體 Infrastructure Dashboard 待完善 |
| 端到端測試 | 9/22 logger 安全測試經 Syslog、Pipeline、Event 到正式 Gmail 已完成；不等同真實 VM／CT 故障操作 |

後續依序處理：

1. **其他重要 PVE alerts**：接續評估 Ceph、Cluster／Corosync、儲存空間、節點異常等事件；不用把每個分類都變成 Email。
2. **改善 Email event details**：驗證 Summary Template，補齊 node、task、VM／CT ID、UPID 與錯誤內容；評估 Custom Fields、Backlog 與模板後再實測。
3. **完善 Dashboard**：沿用既有任務看板，核對失敗、警告、啟動數，再加入節點、服務、登入等統計與異常明細。
4. **後續測試範圍**：現有安全測試鏈路已完成；其他新增告警另行安排安全、可控制的測試事件，逐段記錄原始訊息、分類欄位、Event、實際收件時間，以及 Grace Period 下的重複通知情形。

畫面 0 errors/s 只表示當下沒有顯示處理錯誤，不取代欄位抽查或告警測試。Synology、TP-Link 後續整合仍未列入完成範圍。

## 可下載文字版

[下載同版 Markdown]({{ '/assets/downloads/Proxmox_Graylog_SOP_public.md' | relative_url }})。文字版與本文同步；倉庫若仍保留較早的 Word 檔，屬歷史附件，不代表已同步這次改寫。
