---
layout: default
title: "Synology DP340 × APM 2.0：Google Workspace 備份建置 SOP"
date: 2026-09-10
last_updated: 2026-09-10
categories: [Synology, DP340, ActiveProtect, APM 2.0, Google Workspace, Backup, SOP]
---

# Synology DP340 × ActiveProtect Manager 2.0：Google Workspace 備份建置 SOP

> 本文件整理自實際 Synology DP340 + ActiveProtect Manager 2.0（APM 2.0）操作紀錄，目的為建立工程師可重複執行的 Google Workspace 備份建置流程。
>
> **重要：** 本文件以實際操作流程為主，不代表所有 Google Workspace 租戶、APM 版本或授權組合均具有完全相同的可用選項。正式導入前，應依實際版本與官方文件確認支援範圍。

## 1. 文件目的

建立 Google Workspace 至 Synology DP340 的集中式備份流程，透過 APM 2.0 完成 Google Workspace 授權、服務設定、保護原則與備份工作建立，並確認 DP340 已開始執行備份。

## 2. 適用範圍

- Synology DP340
- ActiveProtect Manager 2.0
- Google Workspace
- Google Workspace 管理員環境
- 企業 IT 工程師／系統管理員

## 3. 建置流程總覽

```text
Google Workspace
       │
       │ Google API / 授權
       ▼
ActiveProtect Manager 2.0
       │
       │ Protection / Backup Plan
       ▼
Synology DP340
       │
       └── Backup Activity
```

完整流程：

1. 確認 DP340 與 APM 2.0 正常
2. 建立 Google Workspace 連線
3. 依 APM 精靈要求準備 Google Workspace 授權資訊
4. 設定 Google Workspace 全網域委派（Domain-wide Delegation）
5. 完成 APM 與 Google Workspace 的授權驗證
6. 設定 Google Workspace 備份服務
7. 建立自動備份規則
8. 選擇需要保護的使用者／服務
9. 指定 DP340 作為備份目的地
10. 執行備份並確認 Backup Activity

## 4. 前置條件

### 4.1 DP340

- DP340 已完成基本安裝與網路設定。
- ActiveProtect Manager 2.0 可正常登入。
- DP340 可正常連線 Internet。
- DNS 與系統時間正常。
- 備份儲存空間已依 Google Workspace 資料量完成容量評估。

### 4.2 Google Workspace

- 具備 Google Workspace 管理員權限。
- 可進入 Google Admin Console。
- 可依 APM 精靈要求設定 API／授權相關項目。
- 建置過程中產生的服務帳戶金鑰或授權檔案必須安全保存。

> **安全注意事項：** 不得將服務帳戶金鑰、OAuth Secret、Private Key、Token、完整憑證或任何租戶敏感資訊提交至 GitHub。

## 5. 建立 Google Workspace 連線

1. 登入 DP340 的 ActiveProtect Manager 2.0。
2. 進入 Google Workspace／雲端應用程式相關設定。
3. 啟動新增 Google Workspace 保護來源的流程。
4. 依 APM 精靈提供的資訊準備 Google Workspace 授權環境。
5. 記錄 APM 要求的必要資訊，但不要將敏感憑證寫入本文件。

## 6. Google Workspace 全網域委派

APM 與 Google Workspace 整合時，需要依實際 APM 精靈要求完成 Google Workspace 的授權設定。

### 6.1 Google Admin Console

進入 Google Admin Console 的 API／安全性控制項，依 APM 2.0 當前版本要求完成 **Domain-wide Delegation（全網域委派）**。

### 6.2 Client ID

將 APM／服務帳戶流程所產生或指定的 Client ID，依 APM 指示加入 Google Workspace 的全網域委派設定。

### 6.3 OAuth Scope

將 APM 精靈提供的 OAuth Scope 完整加入 Google Workspace。

> 不要自行猜測或修改 Scope。不同 APM 版本與服務組合可能要求不同授權範圍，應以實際 APM 畫面與官方文件為準。

## 7. 完成 Google Workspace 授權

1. 回到 ActiveProtect Manager 2.0。
2. 填入 APM 要求的 Google Workspace 網域／授權資訊。
3. 執行連線驗證。
4. 確認 APM 能正常識別 Google Workspace 租戶。
5. 若驗證失敗，優先檢查：
   - Client ID 是否正確。
   - Domain-wide Delegation 是否已生效。
   - OAuth Scope 是否完整。
   - Google Workspace 管理員權限是否足夠。
   - 服務帳戶／金鑰是否正確。
   - DP340 是否可以正常連線 Google 服務。

## 8. 設定 Google Workspace 備份服務

依實際操作流程，進入 Google Workspace 保護設定後，選擇需要保護的 Workspace 服務。

本次實際操作畫面包含以下服務：

- Gmail
- Google Calendar
- Google Contacts
- Google Drive

實際可備份項目與細部功能，仍應以目前使用的 APM 2.0 版本與 Google Workspace 環境顯示為準。

## 9. 建立自動備份規則

建立 Google Workspace Protection／Backup Plan。

本次操作採用每日備份（Daily Backup）作為實際操作範例，並指定 DP340 作為備份設備。

### 建議命名

```text
GW-DAILY-BACKUP
```

### 基本設定

| 項目 | 設定 |
|---|---|
| 備份來源 | Google Workspace |
| 備份設備 | Synology DP340 |
| 備份頻率 | Daily（本次實作範例） |
| 保護對象 | 依企業需求選擇 |
| Gmail | 依實際需求啟用 |
| Calendar | 依實際需求啟用 |
| Contacts | 依實際需求啟用 |
| Google Drive | 依實際需求啟用 |

> 備份頻率、保留政策與保護對象應依企業 RPO、資料量、網路頻寬與法遵需求另行設計，不應直接將本次實作的 Daily 設定視為所有環境的標準值。

## 10. 選擇 Google Workspace 使用者

在 APM 的 Google Workspace 使用者清單中，依企業需求選擇要納入保護的帳號。

建議正式環境先完成使用者盤點：

- 一般使用者
- 主管／高階主管
- 財務／HR／採購等重要帳號
- 共用帳號（若環境中存在）
- 需要長期保存的離職員工帳號

> 本文件不記錄實際租戶的帳號名稱，以避免將企業內部資訊公開至版本控制系統。

## 11. 指定備份目的地

將 Protection／Backup Plan 指派至 DP340。

確認：

```text
Backup Source  : Google Workspace
Backup Server  : DP340
Backup Plan    : GW-DAILY-BACKUP
```

完成後儲存設定並啟用備份工作。

## 12. 驗證備份工作

建立備份規則後，進入 APM 的活動／工作監控畫面。

確認：

- Google Workspace 備份工作已建立。
- 備份來源為 Google Workspace。
- 備份設備顯示 DP340。
- Backup Activity 已出現。
- 工作狀態由排程／等待轉為執行或完成。
- Gmail、Calendar、Contacts、Drive 等實際選取的工作負載開始處理。

### 驗收重點

```text
Google Workspace
       │
       ▼
APM 2.0 Backup Job
       │
       ▼
DP340
       │
       ▼
Backup Activity
       │
       └── 確認工作狀態正常
```

## 13. 建置完成檢查表

- [ ] DP340 基本設定完成
- [ ] APM 2.0 正常
- [ ] Google Workspace 網域授權完成
- [ ] Domain-wide Delegation 完成
- [ ] OAuth Scope 已依 APM 要求設定
- [ ] Google Workspace 連線驗證成功
- [ ] 保護服務已選擇
- [ ] 使用者／保護對象已確認
- [ ] Backup Plan 已建立
- [ ] DP340 已指定為備份設備
- [ ] Backup Activity 已出現
- [ ] 備份工作狀態正常
- [ ] 敏感憑證未提交至 GitHub

## 14. Troubleshooting

### 14.1 Google Workspace 授權失敗

依序確認：

1. Google Workspace 管理員權限。
2. Client ID。
3. Domain-wide Delegation。
4. OAuth Scope。
5. 服務帳戶與金鑰。
6. DP340 Internet／DNS 連線。

### 14.2 找不到使用者

確認：

- Google Workspace 租戶是否正確。
- APM 授權是否成功。
- Domain-wide Delegation 是否已生效。
- 使用者是否屬於目前授權範圍。

### 14.3 Backup Activity 沒有開始

確認：

- Backup Plan 是否已啟用。
- 排程時間是否已到。
- DP340 儲存空間是否足夠。
- Internet／Google API 連線是否正常。
- APM 是否顯示錯誤或警告。

## 15. 還原測試建議

本文件主要涵蓋「備份建置」SOP。正式上線後，應另外建立 Restore SOP，至少測試：

1. 單一 Gmail 資料還原。
2. 單一 Google Drive 檔案還原。
3. Google Drive 資料夾還原。
4. Google Calendar 還原。
5. Google Contacts 還原。
6. 重要使用者資料還原。

正式環境應以實測結果建立 RTO 基準，不應在沒有測試數據的情況下直接承諾固定還原時間。

## 16. 維運建議

### Daily

- 檢查前一日備份是否成功。
- 檢查 Failed／Warning 工作。

### Weekly

- 檢查 DP340 儲存使用量。
- 檢查 Google Workspace 備份工作。
- 檢查 Protection Plan。

### Monthly

- 執行一次 Restore Drill。
- 檢查備份保留政策。
- 評估資料成長與容量。

## 17. 實際操作影片

本 SOP 對應的實際操作影片：

**Synology DP340 + APM 2.0 備份 Google Workspace**

https://youtu.be/vG2X3yn1SOM

## 18. 安全與文件管理

本知識庫為技術文件用途。提交文件前必須完成去敏感化：

- 不得提交 Google Workspace 網域名稱（若屬客戶敏感資訊）。
- 不得提交使用者完整 Email 清單。
- 不得提交服務帳戶 JSON 金鑰。
- 不得提交 OAuth Secret。
- 不得提交 Private Key。
- 不得提交 Token／Password。
- 不得提交設備序號或其他不必要的識別資訊。

## 19. 參考資料

- Synology ActiveProtect Manager：依目前版本官方文件確認實際支援範圍。
- Google Workspace Admin Help：依目前 Google Admin Console 介面確認 Domain-wide Delegation 與 API 授權設定。

> **版本註記：** 本文件建立於 2026-09-10，操作內容來自實際 DP340 + APM 2.0 建置紀錄。若 APM 或 Google Workspace 管理介面更新，應同步更新本 SOP。