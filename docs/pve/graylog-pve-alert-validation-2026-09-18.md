---
layout: default
title: "PVE 告警實測：三項核心告警完整驗證成功"
date: 2026-09-18
last_modified_at: 2026-09-22
categories: [PVE, Graylog, Alert]
permalink: /docs/pve/graylog-pve-alert-validation-2026-09-18/
---

# PVE 告警實測：三項核心告警完整驗證成功

本篇接續 [Graylog Syslog 與 Pipeline 主文件]({{ '/docs/pve/proxmox-graylog-syslog-pipeline-sop/' | relative_url }})，記錄 2026-09-18 在 Graylog 7.1.9 與 PVE node10 的告警設定及實測結果。結果依當次操作對話與收信確認整理；本次文件更新沒有重新操作 Graylog 或 PVE 主機。

> **2026-09-22 最新狀態：**PVE 多次驗證失敗加入 Group by source，PVE 任務失敗警報修正 PVE 9.2.20 漏報；兩者均確認 Last Matched 與正式 Gmail 收信。第 2～7 節保留 9/18 歷史紀錄，第 8～10 節記錄 9/22 改良與驗收。

## 1. 驗證狀態總表（更新至 2026-09-22）

| 告警 | 狀態 | 驗證範圍 |
| --- | --- | --- |
| PVE 服務異常 | 已完成（2026-09-18） | Pipeline → Event matched → Gmail；測試服務已清理 |
| PVE 多次驗證失敗 | 完整驗證成功（2026-09-22） | Group by source；node10 三筆安全測試 → Last Matched → 正式 Gmail |
| PVE 任務失敗警報 | 完整驗證成功（2026-09-22） | PVE 9.2.20 Rule 修正；logger → Pipeline → Event Definition → Gmail |

**測試通知成功不等於 Event 已觸發；本次兩項結案均另確認正式告警收信。**

## 2. PVE 服務異常：完整鏈路已驗證

### Event Definition 設定

| 設定 | 值 |
| --- | --- |
| Title | PVE 服務異常 |
| Stream | Infrastructure Syslog |
| Search within | 5 minutes |
| Execute every | 5 minutes |
| Priority | High |
| Grace Period | 5 minutes |

Query：

~~~text
device_type:"pve" AND event_category:"system_error" AND message:"Failed with result"
~~~

### 產生可控制的服務失敗

在 node10 以 `systemd-run` 建立暫時測試服務，執行 `/bin/false` 產生失敗結果：

~~~bash
systemd-run --unit=graylog-alert-test.service /bin/false
~~~

本次確認 Graylog 收到服務失敗訊息，Pipeline 產生 `device_type=pve` 與 `event_category=system_error`，訊息符合上述 Query；「PVE 服務異常」Event 成功 matched，Gmail 也收到真正的告警通知。這項驗證涵蓋「PVE → Syslog → Pipeline → Event → Email」。

### 測試後清理

~~~bash
systemctl reset-failed graylog-alert-test.service
systemctl --failed
~~~

本次清理後 `systemctl --failed` 回到 **0 個 failed units**。

## 3. Authentication Pipeline 分類

規則名稱：`PVE - Authentication Events`。

本次規則條件包含 message 中有 `pam_unix`，並排除包含 `cron` 的訊息；符合時設定 `event_category=authentication`。此處記錄已確認的條件與輸出，沒有將未保存的完整規則原始碼補成可匯入版本。

`device_type=pve` 與 `pve_cluster=PVE-Cluster` 由既有 PVE 來源識別流程提供。測試時應查看最終訊息欄位，確認其他分類規則沒有將 authentication 覆寫成其他類別。

## 4. 2026-09-18 歷史設定：PVE 多次驗證失敗

| 設定 | 值 |
| --- | --- |
| Title | PVE 多次驗證失敗 |
| Priority | High |
| Enable | yes |
| Stream | Infrastructure Syslog |
| Search within | 5 minutes |
| Execute every | 5 minutes |
| Aggregation / Trigger | `count() >= 3` |
| Group by | 無 |
| Grace Period | 5 minutes |
| Message Backlog | 50 messages |
| Notification | PVE 驗證失敗通知 |

Query：

~~~text
device_type:"pve" AND event_category:"authentication" AND (message:failure OR message:failed)
~~~

無 Group by，因此目前門檻是上述 Stream 與 Query 內所有符合訊息的合計，不是每個節點或帳號各自累積三次。Message Backlog 50 是通知相關訊息的設定，不是觸發門檻。

建立後列表曾顯示 enabled、`Last Matched = Never`。送入三筆測試訊息後，尚未回到列表確認 Last Matched 是否更新。

## 5. Email Notification：測試信已收到

| 設定 | 值 |
| --- | --- |
| Title | PVE 驗證失敗通知 |
| Type | Email Notification |
| Subject | `[PVE 安全告警] ${event_definition_title}` |
| Sender / Recipient | 延續既有設定；本篇不重複公開地址 |
| Timezone | Taipei（UTC+08:00） |
| Body / HTML Body Template | 維持 Graylog 預設 |

執行 **Execute Test Notification** 後，Gmail 已收到測試信，時間顯示 `+08:00`。測試信中的 `Event Definition Test Title`、`test-dummy-v1`、`TEST_NOTIFICATION_ID` 是測試資料，不能當作「PVE 多次驗證失敗」真正觸發的證據。通知已掛到該 Event Definition。

## 6. logger 實測：三筆訊息已進 Graylog

先在 node10 送第一筆：

~~~bash
logger -p auth.warning "pam_unix(proxmox-ve-auth:auth): authentication failure; GRAYLOG-AUTH-ALERT-TEST"
~~~

Graylog Search 選 **Last 5 minutes**，搜尋：

~~~text
"GRAYLOG-AUTH-ALERT-TEST"
~~~

展開訊息，本次已確認：

| 欄位 / 分流 | 結果 |
| --- | --- |
| source | node10 |
| device_type | pve |
| event_category | authentication |
| pve_cluster | PVE-Cluster |
| Stream | Infrastructure Syslog |

再送第二、第三筆：

~~~bash
logger -p auth.warning "pam_unix(proxmox-ve-auth:auth): authentication failure; GRAYLOG-AUTH-ALERT-TEST-2"
logger -p auth.warning "pam_unix(proxmox-ve-auth:auth): authentication failure; GRAYLOG-AUTH-ALERT-TEST-3"
~~~

回到 Graylog，以 **Last 5 minutes** 及 Event Definition 同一個 Query 搜尋：

~~~text
device_type:"pve" AND event_category:"authentication" AND (message:failure OR message:failed)
~~~

本次最後搜尋確認三筆測試訊息都存在。這是合成日誌測試，不是實際帳號密碼登入失敗測試。

## 7. 2026-09-18 當時待辦（9/22 已完成 Event 與收信驗證）

1. 開啟「PVE 多次驗證失敗」，確認測試時段的 **Last Matched** 與 Event 紀錄。
2. 查看 Gmail 是否收到真正的 `[PVE 安全告警] PVE 多次驗證失敗`，核對時間與測試訊息，排除 Execute Test Notification 的測試信。
3. 若原訊息已超過 5 分鐘，先查原測試時段的 Event 與收信紀錄。若仍無法確認，再於同一個 5 分鐘窗口內重送上述三筆訊息並等待排程；不能只等舊訊息觸發。
4. 分別記錄 Event matched 與真正收信結果，兩項都有證據後才將此告警標為完整驗證。
5. 完成後再安排下一個重要 PVE Alert、Email 明細改善與 Dashboard 整合。

後續更新本篇時，保留本次停點與日期，另補驗證日期及結果，避免將日後完成的工作回寫成 2026-09-18 已完成。

## 8. 2026-09-22：Group by source 改良與完整驗證

本節依當日操作紀錄及使用者收信確認整理。本次文件更新沒有重新登入 Graylog、執行 logger 或操作 PVE；下列為已完成測試的紀錄。

原本 5 分鐘內 `count() >= 3` 是整個搜尋結果共同計數，例如 node10、node11、node12 各一筆也可能合計達門檻。今天在 **Filter & Aggregation → Group by Field(s)** 加入 `source`，改為 node10、node11、node12 各自獨立計算；同一個 source 在搜尋窗口內至少三筆才達到條件。這是依節點分組，不是依帳號分組。

### 最終 Event Definition 設定

| 設定 | 值 |
| --- | --- |
| Title | PVE 多次驗證失敗 |
| Stream | Infrastructure Syslog |
| Search within | 5 minutes |
| Execute every | 5 minutes |
| Group by Field(s) | `source` |
| Aggregation | `count() >= 3` |
| Grace Period | 5 minutes |
| Message Backlog | 50 |
| Notification | PVE 驗證失敗通知 |

Query 保持不變：

~~~text
device_type:"pve" AND event_category:"authentication" AND (message:failure OR message:failed)
~~~

### logger 安全測試與驗收

node10 連續送出三筆合成 syslog（不是實際帳密登入失敗）：

~~~bash
logger -p auth.warning "pam_unix(proxmox-ve-auth:auth): authentication failure; GRAYLOG-AUTH-GROUPBY-TEST-1"
logger -p auth.warning "pam_unix(proxmox-ve-auth:auth): authentication failure; GRAYLOG-AUTH-GROUPBY-TEST-2"
logger -p auth.warning "pam_unix(proxmox-ve-auth:auth): authentication failure; GRAYLOG-AUTH-GROUPBY-TEST-3"
~~~

Graylog Search 確認三筆 `source` 都是 `node10`；Event Definitions 中「PVE 多次驗證失敗」的 **Last Matched 已更新**，Gmail 也收到正式 **`[PVE 安全告警] PVE 多次驗證失敗`**，不是 Execute Test Notification 測試信。

**狀態：Group by source 改良後完整驗證成功。** 本次實測來源是 node10；沒有將 node11、node12 或跨節點混合計數的反例測試寫成已執行。

## 9. 2026-09-22：PVE 9.2.20 Task Failed 相容性修正

### 真實 PVE 9.2.20 log 證據

當日 Proxmox VE 9.2.20 Task History 與 Graylog 真實 log 已確認，失敗結果不一定包含 `failed:`，至少有以下三種。下表只摘錄結果字串，省略 UPID 的部分不是完整原始 log：

| 真實結果字串 | 舊規則的問題 |
| --- | --- |
| `migration aborted` | 不包含 `failed:`，會漏報 |
| `CT is locked (backup)` | 不包含 `failed:`，會漏報 |
| `unable to get PID for CT ... (not running?)` | 不包含 `failed:`，會漏報；`...` 表示省略 CT 編號 |
| `: OK` 結尾的成功 Task | 應由 Success 規則處理 |

原 `PVE - Task Failed` 同時要求有 `end task UPID:` **且包含 `failed:`**，只能辨識部分失敗格式。`PVE - Task Success` 原本已正確使用 `end task UPID:` 加上 `ends_with(..., ": OK")`，因此不需修改。

### 最終 Rule（2026-09-22 已儲存）

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

設計理由：凡 PVE Task 結束訊息 `end task UPID:`，若不是 `: OK` 結尾就視為 failed。這樣不用維護一長串錯誤字串，並解決本次 PVE 9.2.20 已觀察到的漏報。這是目前採用的分類策略；只有明確以 `: OK` 結尾才排除，其他結束結果也會納入 failed。

### logger 安全測試：驗證告警鏈路

修正儲存後，在 node10 執行：

~~~bash
logger -p daemon.warning "end task UPID:node10:TEST:TEST:TEST:vzstart:999:root@pam: GRAYLOG-PVE-TASK-FAILED-TEST"
~~~

這只送出一筆 syslog；`TEST` 與 `999` 是測試訊息內容，**沒有真的啟動、停止或修改 VM／CT 999**。本次刻意沒有為測試去破壞 VM／CT／Ceph。

Graylog 展開 Fields 已確認：

| 欄位 | 值 |
| --- | --- |
| device_type | pve |
| event_category | pve_task |
| pve_cluster | PVE-Cluster |
| pve_event_type | task_failed |
| pve_task_name | vzstart |
| pve_task_node | node10 |
| pve_task_status | failed |
| pve_task_user | root@pam |
| pve_vmid | 999 |
| Routed into streams | Infrastructure Syslog |

「PVE 任務失敗警報」Event Definition 的 **Last Matched 更新為幾分鐘前**，且 Gmail 正式告警已收到。

**狀態：Pipeline → Event Definition → Gmail 完整驗證成功。** 真實 log 用來確認規則修正的依據；logger 合成訊息用來驗證修改後的完整處理與寄信鏈路，兩者不混稱為真實 VM／CT 故障操作。

## 10. 變更紀錄與後續

| 日期 | 更新 |
| --- | --- |
| 2026-09-18 | 服務異常完整驗證；驗證失敗當時僅確認三筆入庫與測試通知 |
| 2026-09-22 | 驗證失敗加入 Group by source，Last Matched 與正式 Gmail 驗證成功；修正 Task Failed 的 PVE 9.2.20 漏報，安全測試完整鏈路成功 |

三個核心告警（PVE 多次驗證失敗、PVE 任務失敗警報、PVE 服務異常）均已完成上述範圍的驗證。後續可安排 Ceph、Cluster／Corosync、儲存空間、節點異常告警，以及 Email 明細和 Dashboard；這些尚未列入完成項目。
