---
layout: default
title: "用 DP340 備份 Google Workspace：先授權，再逐項驗證"
categories: [Synology, APM, Google Workspace, Backup]
last_modified_at: 2026-10-17
---

# 用 DP340 備份 Google Workspace：先授權，再逐項驗證

> **一句話**：讓 Synology DP340 定期備份公司的 Gmail、行事曆、聯絡人和 Google Drive；重點是「授權要設對」和「每個服務都要實際還原過，才算真的有備份」。

| 項目 | 內容 |
| --- | --- |
| 適合誰看 | 第一次用備份設備保護 Google Workspace 的人 |
| 設備 | Synology DP340／ActiveProtect Manager（APM）2.0 |
| 首次測試 | 2026-09-10 |
| 目前狀態 | ✅ Drive 已還原測試成功；❌ Gmail 備份曾失敗、原因未結案；⏳ 行事曆與聯絡人的還原證據待補 |

> 這是 APM 2.0 當時的操作與計畫，實際選項、授權與支援範圍要以你正在用的版本核對。每日備份是本案的規劃，**不代表**所有服務都已連續成功執行。

## 1. 先認識幾個名詞

| 名詞 | 白話解釋 |
| --- | --- |
| **Service Account（服務帳戶）** | 專門給「系統」用的 Google 帳號，不是給人登入的 |
| **JSON key** | 服務帳戶登入用的憑證檔，等同密碼，必須保護好 |
| **Client ID** | Google 管理後台用來辨識「是哪個服務帳戶」的編號 |
| **全網域委派（Domain-wide Delegation）** | 管理員允許服務帳戶「代表公司裡的使用者」存取資料，範圍由下面的 scope 限制 |
| **OAuth scope** | 授權清單：明確列出允許存取哪些功能（例如讀信、讀行事曆） |
| **Protection Plan** | 在 APM 裡設定「保護誰、保護什麼、多久備份一次」 |

## 2. 它怎麼運作

```text
Google 管理後台：允許服務帳戶在指定 scope 內存取使用者資料（全網域委派）
        ↓
DP340／APM：用 JSON key 以服務帳戶身分連線
        ↓
Protection Plan：決定保護哪些人、哪些服務、多久一次
        ↓
資料備份進 DP340
```

> ⚠️ 備份存在**同一台** DP340，和「另有一份異地副本」是兩回事。異地／離線副本是後續規劃，尚未完成。

## 3. 建置前先準備

| 項目 | 確認內容 |
| --- | --- |
| DP340 | 儲存空間、DNS、時間同步、HTTPS 443 對外連線 |
| APM | 已安裝的版本與必要授權 |
| Google 端 | 能完成授權設定的管理員權限 |
| 保護清單 | 每個帳號要備份 Gmail、Calendar、Contacts、My Drive 的哪些項目；Shared Drive 依實際支援選項另外核對 |

> 不要只選了群組名稱，就以為所有服務都已包含。

## 4. 建置步驟：連線 → 授權 → 計畫

### 4-1 在 APM 建立 Google Workspace 連線

從「雲端應用程式」進入 Google Workspace 建置精靈，確認組織與備份目的地。介面名稱可能隨版本調整，以下以當時流程說明。

### 4-2 依精靈準備服務帳戶與 JSON 憑證

- JSON 檔交給 APM 使用，存在受控的位置。**不要放進 GitHub、共用截圖或聊天訊息**。
- 更換憑證後，要重新驗證 APM 連線，並核對服務帳戶與 Client ID 的對應；不要以為換了檔案就完成所有授權更新。

### 4-3 在 Google 管理後台設定全網域委派

填入 Client ID，以及**該版本精靈或官方文件要求的 scopes**。本文沒有收錄完整 scope 清單，也不自己拼一份可直接貼上的清單。

> 備份和還原可能需要不同的權限，不要一律簡化成「唯讀就夠」；排錯時也不要無限制擴大授權。先確認失敗的是**哪個服務、哪個操作**。

### 4-4 回到 APM 驗證連線，再設定還原選項

連線驗證成功只代表這一步通過。接著依需求確認 Recovery 相關選項；看到有某個選項，不代表已經完成還原測試。

### 4-5 建立備份計畫，逐項核對保護範圍

本案規劃每日備份：選好使用者／群組後，再**逐項**核對每種服務。保留政策和容量需求另外記錄。

### 4-6 等工作結束，再判定成功

Backup Activity 出現進度，只代表工作**開始了**。要看每個帳號、每個服務的**最終狀態**、時間、錯誤，以及有沒有產生可用的還原點。

**建置操作影片：**

<div class="video-grid"><article class="video-card"><div class="video-frame"><iframe src="https://www.youtube-nocookie.com/embed/SZIe91ktVag" title="DP340 + APM 2.0 Google Workspace 備份建置操作影片" loading="lazy" allow="accelerometer; autoplay; clipboard-write; encrypted-media; gyroscope; picture-in-picture; web-share" allowfullscreen></iframe></div><h3>建置操作影片</h3><p><a href="https://youtu.be/SZIe91ktVag" target="_blank" rel="noopener noreferrer">在 YouTube 開啟原始影片</a></p></article></div>

## 5. 第一次實測結果（2026-09-10）

| 服務 | 結果 | 還缺什麼 |
| --- | --- | --- |
| Drive | ✅ 建立測試檔 → 備份 → 刪除並清空垃圾桶 → 用資料夾還原取回 | 完整時間戳、checksum、更多樣本 |
| Gmail | ❌ 管理員帳號的備份曾失敗 | 錯誤原因、修復、再次成功的證據 |
| Calendar | ⏳ 沒有完整還原紀錄 | 事件還原與內容驗證 |
| Contacts | ⏳ 沒有完整還原紀錄 | 聯絡人還原與欄位比對 |

- Drive 操作約 15 分鐘，但沒有完整的起訖時間，**不能當作正式的 RTO**（復原時間目標）。
- 測試刪除只能用「已確認有備份的**專用測試資料**」，不能把清空正式資料當成日常驗證步驟。

<div class="video-grid"><article class="video-card"><div class="video-frame"><iframe src="https://www.youtube-nocookie.com/embed/v6DeSETPUSg" title="DP340 Google Workspace 備份還原驗證紀錄" loading="lazy" allow="accelerometer; autoplay; clipboard-write; encrypted-media; gyroscope; picture-in-picture; web-share" allowfullscreen></iframe></div><h3>備份還原驗證紀錄</h3><p><a href="https://youtu.be/v6DeSETPUSg" target="_blank" rel="noopener noreferrer">在 YouTube 開啟原始影片</a></p></article></div>

## 6. 失敗時先查哪裡

| 現象 | 排查方向 |
| --- | --- |
| 連線驗證失敗 | 網路、時間、JSON、服務帳戶與 Client ID |
| 部分服務成功、部分失敗 | 該服務的授權範圍、帳號的服務狀態、詳細錯誤 |
| 工作有進度，但沒有還原點 | 最終狀態、部分失敗、實際選取的範圍 |
| 還原時選不到目標或失敗 | 該版本的還原限制、權限、目標對象 |
| 新使用者沒被備份 | 群組／使用者選取與計畫涵蓋範圍 |

> 以上是排查方向，**不是**本案 Gmail 已確認的原因。處理完要重跑失敗的項目並保存結果，不能拿 Drive 成功來代替 Gmail 的驗收。

## 7. 日常維護節奏（建議）

| 頻率 | 做什麼 |
| --- | --- |
| 每天 | 看各服務最終結果、失敗帳號、最新還原點 |
| 每週 | 核對新進／離職帳號、群組、容量與配額 |
| 每月 | 抽樣還原，檢查憑證與授權有沒有變動 |
| 每季或重大變更後 | 較完整的多服務還原演練，檢查異地副本計畫 |

這是建議，不是已執行的紀錄。每次測試都記下備份點、原始內容、還原時間與比對結果，才能追蹤真正的恢復能力。

## 8. 公開紀錄前的資料保護

移除 JSON 私鑰、token、完整憑證和可識別的使用者資料。Scope 本身只是權限名稱，和私鑰不同，但仍應避免公開不必要的組織帳號對應和完整管理畫面。

## 9. 待辦

| 項目 | 說明 |
| --- | --- |
| Gmail 備份失敗 | 查出原因、修復、取得再次成功的證據 |
| Calendar、Contacts 還原 | 實際還原並比對內容 |
| Drive 還原補證據 | 完整時間戳、checksum、多個樣本 |
| 異地／離線副本 | 規劃第二份備份 |

## 10. 延伸閱讀

- [DP340 顯示省下 75% 空間，該怎麼看？](https://kbwangtw.github.io/IT-Knowledge-Base/docs/synology/dp340-google-workspace-apm20-dedup-test/)：Guest OS 與 Workspace 的**合併**容量統計，不能當作每個服務都備份成功的證據
