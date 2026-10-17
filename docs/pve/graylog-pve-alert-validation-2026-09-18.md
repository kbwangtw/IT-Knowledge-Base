---
layout: default
title: "PVE 告警實測：三項核心告警完整驗證成功"
date: 2026-09-18
last_modified_at: 2026-10-17
categories: [PVE, Graylog, Alert]
permalink: /docs/pve/graylog-pve-alert-validation-2026-09-18/
---

# PVE 告警實測：三項核心告警完整驗證成功

> **一句話**：告警設好不算數，要**故意製造一筆假事件**，親眼看到 Graylog 觸發、Gmail 收到正式告警信，才算驗證完成；本篇把 PVE 的三項核心告警都這樣走過一遍。

| 項目 | 內容 |
| --- | --- |
| 適合誰看 | 剛在 Graylog 建好告警、想確認它真的會寄信的人 |
| 環境 | Graylog 7.1.9；PVE node10（PVE 9.2.20） |
| 日期 | 2026-09-18 初次驗證；2026-09-22 改良與結案 |
| 結論 | ✅ PVE 服務異常、✅ PVE 多次驗證失敗、✅ PVE 任務失敗警報，三項都確認 Last Matched 與正式 Gmail 收信 |

本篇接續 [把 PVE、PBS 與 NAS 的日誌集中到 Graylog]({{ '/docs/pve/proxmox-graylog-syslog-pipeline-sop/' | relative_url }})。結果依當次操作與收信確認整理；本次文件改寫沒有重新操作 Graylog 或 PVE。

## 1. 先認識幾個名詞

| 名詞 | 白話解釋 |
| --- | --- |
| **Pipeline／Rule** | Graylog 收到日誌後的「分類規則」，例如幫訊息貼上 `event_category=authentication` 標籤 |
| **Stream** | 依條件把訊息分流到不同「資料夾」，本案是 Infrastructure Syslog |
| **Event Definition** | 告警的條件：多久查一次、查什麼、達到多少筆就觸發 |
| **Notification** | 觸發後要做什麼，本案是寄 Email |
| **Last Matched** | Event Definition 上次真的被觸發的時間；`Never` 代表從沒觸發過 |
| **Grace Period** | 觸發後多久內不重複寄信，避免洗信箱 |
| **Group by** | 分組計數，例如每台主機各自算次數 |
| **logger** | Linux 指令，可以手動送一筆 syslog，用來製造**假的**測試訊息 |

## 2. 驗證流程長什麼樣

```text
在 node10 製造一筆測試訊息（logger 或 systemd-run）
  → Syslog 送到 Graylog
  → Pipeline 貼上分類標籤（device_type、event_category…）
  → 分流到 Infrastructure Syslog Stream
  → Event Definition 依條件觸發（Last Matched 更新）
  → Notification 寄出正式 Gmail
```

> ⚠️ **「Execute Test Notification」收到信，不等於告警會觸發。** 測試信只證明「寄信設定」可用；要看到 Last Matched 更新、收到**正式**告警信，才算整條鏈路通過。

## 3. 驗證狀態總表

| 告警 | 狀態 | 驗證範圍 |
| --- | --- | --- |
| PVE 服務異常 | ✅ 2026-09-18 | Pipeline → Event matched → Gmail；測試服務已清理 |
| PVE 多次驗證失敗 | ✅ 2026-09-22 | 加入 Group by source；node10 三筆安全測試 → Last Matched → 正式 Gmail |
| PVE 任務失敗警報 | ✅ 2026-09-22 | 修正 PVE 9.2.20 漏報；logger → Pipeline → Event Definition → Gmail |

## 4. 告警一：PVE 服務異常

**做什麼**：當 PVE 上有 systemd 服務失敗時寄信。

**Event Definition 設定**：

| 設定 | 值 |
| --- | --- |
| Title | PVE 服務異常 |
| Stream | Infrastructure Syslog |
| Search within | 5 minutes |
| Execute every | 5 minutes |
| Priority | High |
| Grace Period | 5 minutes |

Query：

```text
device_type:"pve" AND event_category:"system_error" AND message:"Failed with result"
```

**怎麼測**：在 node10 建一個「一定會失敗」的暫時服務：

```bash
systemd-run --unit=graylog-alert-test.service /bin/false
```

`/bin/false` 這個程式什麼都不做、直接回傳失敗，所以 systemd 會記下一筆 `Failed with result`。

**看到的結果**：Graylog 收到失敗訊息；Pipeline 貼上 `device_type=pve`、`event_category=system_error`；「PVE 服務異常」Event matched，Gmail 收到正式告警。整條「PVE → Syslog → Pipeline → Event → Email」都通過。

**測完要清理**：

```bash
systemctl reset-failed graylog-alert-test.service   # 清掉這筆失敗紀錄
systemctl --failed                                  # 確認沒有其他失敗服務
```

本次清理後回到 **0 個 failed units**。

## 5. 告警二：PVE 多次驗證失敗

### 5-1 分類規則：先認出「驗證事件」

規則名稱：`PVE - Authentication Events`。

- 條件：message 裡有 `pam_unix`，並**排除**含 `cron` 的訊息（cron 也會用 pam，但不是登入）。
- 符合時：設定 `event_category=authentication`。
- `device_type=pve`、`pve_cluster=PVE-Cluster` 由既有的 PVE 來源識別流程提供。

這裡記錄的是已確認的條件與輸出，沒有把未保存的完整規則原始碼補成可匯入版本。測試時要看最終訊息欄位，確認沒有被其他規則覆寫成別的類別。

### 5-2 寄信設定：Email Notification

| 設定 | 值 |
| --- | --- |
| Title | PVE 驗證失敗通知 |
| Type | Email Notification |
| Subject | `[PVE 安全告警] ${event_definition_title}` |
| Sender／Recipient | 延續既有設定；本篇不公開地址 |
| Timezone | Taipei（UTC+08:00） |
| Body／HTML Body Template | 維持 Graylog 預設 |

按 **Execute Test Notification** 後，Gmail 收到測試信，時間顯示 `+08:00`。

> 測試信裡的 `Event Definition Test Title`、`test-dummy-v1`、`TEST_NOTIFICATION_ID` 都是測試資料，**不能**當作告警真的觸發的證據。

### 5-3 9/18 的第一版設定

| 設定 | 值 |
| --- | --- |
| Title | PVE 多次驗證失敗 |
| Priority | High |
| Stream | Infrastructure Syslog |
| Search within／Execute every | 5 minutes／5 minutes |
| Aggregation／Trigger | `count() >= 3` |
| Group by | 無 |
| Grace Period | 5 minutes |
| Message Backlog | 50 messages |
| Notification | PVE 驗證失敗通知 |

Query：

```text
device_type:"pve" AND event_category:"authentication" AND (message:failure OR message:failed)
```

- **沒有 Group by** 的意思是：三台主機的訊息**合起來算**，node10、node11、node12 各一筆也可能湊滿 3 筆。
- Message Backlog 50 是「信裡附幾筆相關訊息」，不是觸發門檻。

**9/18 的測試**：在 node10 送三筆假的驗證失敗訊息（第一筆先送，確認欄位後再送後兩筆）：

```bash
logger -p auth.warning "pam_unix(proxmox-ve-auth:auth): authentication failure; GRAYLOG-AUTH-ALERT-TEST"
logger -p auth.warning "pam_unix(proxmox-ve-auth:auth): authentication failure; GRAYLOG-AUTH-ALERT-TEST-2"
logger -p auth.warning "pam_unix(proxmox-ve-auth:auth): authentication failure; GRAYLOG-AUTH-ALERT-TEST-3"
```

| 指令片段 | 意思 |
| --- | --- |
| `-p auth.warning` | 用「驗證類、警告等級」送出 |
| `GRAYLOG-AUTH-ALERT-TEST` | 自訂標記，方便在 Graylog 搜尋 |

在 Graylog Search 選 **Last 5 minutes** 搜 `"GRAYLOG-AUTH-ALERT-TEST"`，第一筆展開後確認：

| 欄位／分流 | 結果 |
| --- | --- |
| source | node10 |
| device_type | pve |
| event_category | authentication |
| pve_cluster | PVE-Cluster |
| Stream | Infrastructure Syslog |

再用 Event Definition 同一個 Query 搜尋，三筆都在。這是**合成日誌測試**，不是真的打錯帳密。

9/18 當時建好後列表顯示 `Last Matched = Never`，送完三筆後還沒回去確認 Last Matched，所以當天只算「三筆入庫＋測試信」，**沒有**算完整驗證。

### 5-4 9/22 改良：加 Group by source，完整驗證

**為什麼要改**：沒有 Group by 時，三台各一筆也會被合計成 3 筆而誤報。

**怎麼改**：在 **Filter & Aggregation → Group by Field(s)** 加入 `source`。改完後 node10、node11、node12 **各自計數**，同一台在 5 分鐘內至少 3 筆才觸發。（依主機分組，不是依帳號分組。）

**最終設定**：

| 設定 | 值 |
| --- | --- |
| Title | PVE 多次驗證失敗 |
| Stream | Infrastructure Syslog |
| Search within／Execute every | 5 minutes／5 minutes |
| Group by Field(s) | `source` |
| Aggregation | `count() >= 3` |
| Grace Period | 5 minutes |
| Message Backlog | 50 |
| Notification | PVE 驗證失敗通知 |

Query 不變。

**測試**：node10 連續送三筆合成 syslog：

```bash
logger -p auth.warning "pam_unix(proxmox-ve-auth:auth): authentication failure; GRAYLOG-AUTH-GROUPBY-TEST-1"
logger -p auth.warning "pam_unix(proxmox-ve-auth:auth): authentication failure; GRAYLOG-AUTH-GROUPBY-TEST-2"
logger -p auth.warning "pam_unix(proxmox-ve-auth:auth): authentication failure; GRAYLOG-AUTH-GROUPBY-TEST-3"
```

**看到的結果**：

- Graylog Search 確認三筆的 `source` 都是 `node10`。
- 「PVE 多次驗證失敗」的 **Last Matched 已更新**。
- Gmail 收到正式的 **`[PVE 安全告警] PVE 多次驗證失敗`**（不是測試信）。

✅ **完整驗證成功。** 本次只測了 node10；沒有做「三台各一筆不應觸發」的反例測試。

## 6. 告警三：PVE 任務失敗警報（修正 PVE 9.2.20 漏報）

### 6-1 發現問題：舊規則會漏掉一些失敗

**舊規則**：`PVE - Task Failed` 要求訊息同時有 `end task UPID:` **而且**包含 `failed:`。

但 9/22 從 PVE 9.2.20 的 Task History 和 Graylog 真實日誌發現，失敗結果**不一定**有 `failed:`（下表只摘錄結果字串）：

| 真實結果字串 | 舊規則的問題 |
| --- | --- |
| `migration aborted` | 沒有 `failed:`，漏報 |
| `CT is locked (backup)` | 沒有 `failed:`，漏報 |
| `unable to get PID for CT ... (not running?)` | 沒有 `failed:`，漏報；`...` 是省略的 CT 編號 |
| `: OK` 結尾 | 成功的 Task，由 Success 規則處理 |

`PVE - Task Success` 原本就用「`end task UPID:` 加上 `: OK` 結尾」判斷，不需要改。

### 6-2 新規則：不是 OK 就算失敗

```text
rule "PVE - Task Failed"
when
    has_field("message") &&
    contains(to_string($message.message), "end task UPID:") &&
    !ends_with(to_string($message.message), ": OK")
then
    set_field("pve_event_type", "task_failed");
    set_field("pve_task_status", "failed");
end
```

**逐行說明**：

| 片段 | 意思 |
| --- | --- |
| `has_field("message")` | 訊息有內容才處理 |
| `contains(…, "end task UPID:")` | 是 PVE「工作結束」的訊息 |
| `!ends_with(…, ": OK")` | 結尾**不是** `: OK`（`!` 代表「不是」） |
| `set_field(…)` | 貼上 `task_failed`、`failed` 兩個標籤 |

**設計理由**：與其維護一長串錯誤字串，不如反過來，只要不是明確的 `: OK` 就視為失敗。2026-09-22 已儲存。

### 6-3 安全測試

```bash
logger -p daemon.warning "end task UPID:node10:TEST:TEST:TEST:vzstart:999:root@pam: GRAYLOG-PVE-TASK-FAILED-TEST"
```

這只是送出**一筆文字訊息**；`TEST` 和 `999` 都是假內容，**沒有真的動到 VM／CT 999**。本次刻意不為了測試去破壞 VM、CT 或 Ceph。

**Graylog 展開 Fields 看到**：

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

「PVE 任務失敗警報」的 **Last Matched 更新為幾分鐘前**，Gmail 也收到正式告警。

✅ **Pipeline → Event Definition → Gmail 完整驗證成功。** 真實日誌用來確認「為什麼要改規則」；logger 假訊息用來驗證「改完後整條鏈路會寄信」，兩者不混為一談。

## 7. 常見問題

| 現象 | 怎麼辦 |
| --- | --- |
| Test Notification 收到信，但告警從沒觸發 | 測試信只驗證寄信；看 Event Definition 的 Last Matched |
| Last Matched 一直是 `Never` | 用 Event Definition **同一個 Query** 搜尋，確認測試訊息有進來、欄位正確 |
| 測試訊息超過 5 分鐘才回來看 | 已經超出搜尋窗口；在同一個 5 分鐘內重送，等下一輪排程 |
| 三台各一筆就觸發 | 加 Group by `source`，讓每台各自計數 |
| 某些 Task 失敗沒告警 | 結果字串不一定含 `failed:`；改用「不是 `: OK` 結尾」判斷 |
| 擔心測試動到正式機器 | 用 `logger` 送假訊息即可，不需要真的弄壞 VM |

## 8. 變更紀錄

| 日期 | 更新 |
| --- | --- |
| 2026-09-18 | 服務異常完整驗證；驗證失敗僅確認三筆入庫與測試信 |
| 2026-09-22 | 驗證失敗加 Group by source，Last Matched 與正式 Gmail 驗證成功；Task Failed 修正 PVE 9.2.20 漏報，完整鏈路成功 |

## 9. 後續方向

Ceph、Cluster／Corosync、儲存空間、節點異常告警，以及 Email 明細和 Dashboard，後續已陸續整理在 Graylog 主文件的告警清單中；本篇只記錄這三項核心告警的驗證。

## 10. 延伸閱讀

- [把 PVE、PBS 與 NAS 的日誌集中到 Graylog]({{ '/docs/pve/proxmox-graylog-syslog-pipeline-sop/' | relative_url }})
