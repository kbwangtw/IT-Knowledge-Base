---
layout: default
title: "PVE 告警實測：服務異常已收信，驗證失敗待確認"
date: 2026-09-18
last_modified_at: 2026-09-18
categories: [PVE, Graylog, Alert]
permalink: /docs/pve/graylog-pve-alert-validation-2026-09-18/
---

# PVE 告警實測：服務異常已收信，驗證失敗待確認

本篇接續 [Graylog Syslog 與 Pipeline 主文件]({{ '/docs/pve/proxmox-graylog-syslog-pipeline-sop/' | relative_url }})，記錄 2026-09-18 在 Graylog 7.1.9 與 PVE node10 的告警設定及實測結果。結果依當次操作對話與收信確認整理；本次文件更新沒有重新操作 Graylog 或 PVE 主機。

> **目前停點：**「PVE 多次驗證失敗」已建立，三筆測試訊息已進 Graylog；本次尚未確認測試後的 Last Matched，也尚未確認真正的 Gmail Alert。下次從這兩項驗收接續。

## 1. 驗證狀態總表

| 項目 | 2026-09-18 已確認 | 尚待確認 |
| --- | --- | --- |
| PVE 服務異常 | Pipeline 分類正確、Event matched、Gmail 收到真正告警；測試服務已清理 | 本次測試鏈路已驗證 |
| PVE Authentication Pipeline | 測試訊息有 `device_type=pve`、`event_category=authentication`、`pve_cluster=PVE-Cluster`，進入指定 Stream | 其他實際登入來源的涵蓋程度需另測 |
| PVE 多次驗證失敗 | Event Definition 已建立；Last 5 minutes 搜尋有三筆測試訊息 | 測試後的 Last Matched、真正 Gmail Alert |
| PVE 驗證失敗通知 | Execute Test Notification 成功，Gmail 已收到測試信 | 由上述 Event 真正觸發的信件 |

**測試通知成功不等於 Event 已觸發；搜尋有三筆也不等於已證明排程執行時達到門檻。**

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

## 4. PVE 多次驗證失敗：設定已建立

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

## 7. 下次從這裡接續

1. 開啟「PVE 多次驗證失敗」，確認測試時段的 **Last Matched** 與 Event 紀錄。
2. 查看 Gmail 是否收到真正的 `[PVE 安全告警] PVE 多次驗證失敗`，核對時間與測試訊息，排除 Execute Test Notification 的測試信。
3. 若原訊息已超過 5 分鐘，先查原測試時段的 Event 與收信紀錄。若仍無法確認，再於同一個 5 分鐘窗口內重送上述三筆訊息並等待排程；不能只等舊訊息觸發。
4. 分別記錄 Event matched 與真正收信結果，兩項都有證據後才將此告警標為完整驗證。
5. 完成後再安排下一個重要 PVE Alert、Email 明細改善與 Dashboard 整合。

後續更新本篇時，保留本次停點與日期，另補驗證日期及結果，避免將日後完成的工作回寫成 2026-09-18 已完成。
