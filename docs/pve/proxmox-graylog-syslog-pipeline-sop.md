---
layout: default
title: "把三台 PVE 的日誌集中到 Graylog"
date: 2026-09-17
categories: [PVE, Graylog, Syslog]
permalink: /docs/pve/proxmox-graylog-syslog-pipeline-sop/
last_modified_at: 2026-09-18
---

# 把三台 PVE 的日誌集中到 Graylog

日誌分散在三台主機時，要查「哪台出錯、哪個工作失敗」得逐台找。本次把 node10、node11、node12 的日誌送進 Graylog，再替訊息加上來源、類型與任務狀態，做成任務監控看板，並接上 PVE 任務失敗 Email 警報。

> 紀錄期間：2026-09-17～2026-09-18；Graylog 7.1.9，部署於 LXC。三台來源、既有任務看板、Task Failed 規則模擬與 Gmail 實際收取測試信已有驗證；Event Definition 已啟用並儲存通知綁定。尚未完成「新的 PVE 故障 → 自動建立 Event → Email 收件」端到端測試。本文保留有紀錄的規則原始碼，沒有完整最新版規則匯出檔可供直接匯入。

9/18 更新重點：完成「PVE 任務失敗警報」與「PVE 任務失敗通知」，排除 Gmail SMTP 驗證問題。本次文件更新只整理既有操作與測試結果，沒有重新操作 Graylog 或 PVE 主機。

> **2026-09-18 後續實測：**服務異常告警已 matched 並收到 Gmail；多次驗證失敗已建立且三筆測試訊息入庫，Last Matched 與真正告警信仍待確認。請接續閱讀 [PVE 告警實測紀錄](https://kbwangtw.github.io/IT-Knowledge-Base/docs/pve/graylog-pve-alert-validation-2026-09-18/)。

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

最後三段是已儲存的告警設定。規則模擬和測試信各自成功，不代表已用一筆新的真實失敗事件跑完整條鏈路。

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
| PVE - Task Failed | 已模擬驗證產生 pve_event_type=task_failed、pve_task_status=failed |
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

以下是當時核對並通過 Rule Simulation 的 `PVE - Task Failed`：

~~~text
rule "PVE - Task Failed"
when
    has_field("message") &&
    contains(to_string($message.message), "end task UPID:") &&
    contains(to_string($message.message), "failed:")
then
    set_field("pve_event_type", "task_failed");
    set_field("pve_task_status", "failed");
end
~~~

Simulation 使用這筆真實失敗格式：

~~~text
node10 pvedaemon[4129114]: <root@pam> end task UPID:node10:00022D58:0191F4A8:6AAA40A2:vncproxy:100:root@pam: command '/usr/bin/termproxy' failed: exit code 1
~~~

結果確實產生 `pve_event_type = task_failed` 與 `pve_task_status = failed`，因此規則保留不動。這項驗證證明此樣本可被規則辨識；不代表所有 PVE 失敗格式都已覆蓋，也不是新訊息通過完整 Stream／Pipeline／Alert 的驗收。

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

建立與綁定完成時，Last Matched 仍是 Never，當時沒有新的失敗命中紀錄。這本身不能用來判定規則壞掉，也不能當作自動告警已通過的證據。後續須觀察一筆新事件是否落入搜尋時間範圍並產生通知。

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

## 目前完成與待辦

目前已完成第一種 PVE 告警的設定與分段驗證，可以從這裡接下一階段；完整監控系統尚未驗收完成。

| 範圍 | 目前進度／驗證界線 |
| --- | --- |
| Syslog／Stream | 三台 PVE 接收與 Infrastructure Syslog 已驗證 |
| Pipeline | 主機、服務、任務、認證、系統錯誤分類已建立；既有五種服務事件測試與任務欄位紀錄保留 |
| Task Failed | 歷史真實失敗已找到，Rule Simulation 產生兩個失敗欄位；未回填歷史索引 |
| Event Definition | PVE 任務失敗警報已啟用，每 5 分鐘查最近 5 分鐘，High |
| Email | Gmail AUTH 成功且 Graylog 測試信實際收到 |
| 通知綁定 | 已儲存，Grace Period 5 minutes、Message Backlog 0 |
| Dashboard | 既有任務看板八個 Widget 的紀錄保留；整體 Infrastructure Dashboard 待完善 |
| 端到端測試 | 新故障經 Syslog、Pipeline、Event 到自動 Email 收件，仍待驗證 |

後續依序處理：

1. **其他重要 PVE alerts**：挑選需要人處理的服務異常、認證異常等事件；不用把每個分類都變成 Email。
2. **改善 Email event details**：驗證 Summary Template，補齊 node、task、VM／CT ID、UPID 與錯誤內容；評估 Custom Fields、Backlog 與模板後再實測。
3. **完善 Dashboard**：沿用既有任務看板，核對失敗、警告、啟動數，再加入節點、服務、登入等統計與異常明細。
4. **端到端故障測試**：另行安排安全、可控制的測試事件，逐段記錄原始訊息、分類欄位、Event、實際收件時間，以及 Grace Period 下的重複通知情形。

畫面 0 errors/s 只表示當下沒有顯示處理錯誤，不取代欄位抽查或告警測試。Synology、TP-Link 後續整合仍未列入完成範圍。

## 可下載文字版

[下載同版 Markdown]({{ '/assets/downloads/Proxmox_Graylog_SOP_public.md' | relative_url }})。文字版與本文同步；倉庫若仍保留較早的 Word 檔，屬歷史附件，不代表已同步這次改寫。
