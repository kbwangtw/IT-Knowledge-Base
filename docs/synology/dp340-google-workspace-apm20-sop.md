---
layout: default
title: "用 DP340 備份 Google Workspace：先授權，再逐項驗證"
categories: [Synology, APM, Google Workspace, Backup]
last_modified_at: 2026-09-18
---

# 用 DP340 備份 Google Workspace：先授權，再逐項驗證

本篇整理 DP340／ActiveProtect Manager 2.0 連接 Google Workspace 的建置方式，以及第一次還原測試。目標是保護 Gmail、行事曆、聯絡人和 Drive，並確認需要時能取回資料。

**目前只有部分驗證完成：Drive 已做過檔案還原；Gmail 備份曾失敗，原因尚未結案；行事曆與聯絡人的還原證據仍待補。**

> 首次測試紀錄：2026-09-10。這是 APM 2.0 當時的操作與計畫，實際選項、授權和支援範圍應以部署中的版本核對。每日備份是本案規劃，不代表所有服務已連續成功執行。

## 先理解它怎麼工作

Google Workspace 的資料透過授權連線備份到 DP340。Google 端要允許指定服務帳戶，在核准範圍內存取組織使用者資料；DP340 端則決定保護哪些人、哪些服務、多久備份一次。

| 名稱 | 白話用途 |
| --- | --- |
| Service Account | 給系統使用的服務帳戶 |
| JSON key | 服務帳戶登入用的憑證，需保護 |
| Client ID | 在 Google 管理端辨識這個授權對象 |
| Domain-wide Delegation | 由管理員允許服務帳戶在指定範圍內代表使用者 |
| OAuth scope | 明確列出允許存取的功能範圍 |
| Protection Plan | 在 APM 設定保護對象、內容與排程 |

備份存在同一台 DP340，和有另一份異地副本是不同的事。本文的異地／離線副本屬後續規劃，未列為已完成。

## 建置前先準備

確認 DP340 儲存空間、DNS、時間同步與 HTTPS 443 連線；核對已安裝的 APM 版本及必要授權。Google 端需要能完成授權設定的管理權限，並先整理要保護的使用者與群組。

準備一份清單：每個帳號要備份 Gmail、Calendar、Contacts、My Drive 中的哪些項目；Shared Drive 也要依實際支援選項另行核對。不要只選了群組名稱，就以為所有服務都已包含。

## 建置順序：照著「連線 → 授權 → 計畫」走

### 1. 在 APM 建立 Google Workspace 連線

從雲端應用程式進入 Google Workspace 建置精靈，確認組織與備份目的地。介面名稱可能隨版本調整，以下以當時流程說明。

### 2. 依精靈準備服務帳戶與 JSON 憑證

JSON 檔交給 APM 使用，保存在受控位置。不要放進 GitHub、共用截圖或一般聊天訊息。

憑證更換後應重新驗證 APM 連線，並核對服務帳戶與 Client ID 的對應；不要假設換了檔案就一定完成所有授權更新。

### 3. 在 Google 管理端設定全網域委派

填入對應的 Client ID，以及**該版本精靈或官方文件要求的 scopes**。本文沒有收錄完整 scope 清單，不自行拼出一份可直接貼上的清單。

備份與還原可能需要不同能力，不要一律簡化成「只讀就一定夠」，也不要為了排錯無限制擴大授權。先確認失敗的是哪一個服務、哪一個操作。

### 4. 回到 APM 驗證連線，再設定還原選項

連線驗證成功，只表示這一步通過。接著依需求確認 Recovery 相關選項，不能把有某個選項當成已完成還原測試。

### 5. 建立備份計畫，逐項核對保護範圍

本案規劃每日備份，選使用者／群組後，再核對每種服務。保留政策與容量需求另外記錄；範例群組數量不是實測結果。

### 6. 等到工作結束，再判定成功

Backup Activity 出現進度，代表工作已啟動，不代表成功。查看每個帳號、每個服務的最終狀態、時間、錯誤及可用還原點。

## 建置操作影片

<div class="video-grid"><article class="video-card"><div class="video-frame"><iframe src="https://www.youtube-nocookie.com/embed/SZIe91ktVag" title="DP340 + APM 2.0 Google Workspace 備份建置操作影片" loading="lazy" allow="accelerometer; autoplay; clipboard-write; encrypted-media; gyroscope; picture-in-picture; web-share" allowfullscreen></iframe></div><h3>建置操作影片</h3><p><a href="https://youtu.be/SZIe91ktVag" target="_blank" rel="noopener noreferrer">在 YouTube 開啟原始影片</a></p></article></div>

## 第一次實測：Drive 成功，Gmail 尚未完成

| 服務 | 當時結果 | 還缺什麼 |
| --- | --- | --- |
| Drive | 建立測試檔、備份、刪除並清空垃圾桶後，使用資料夾還原取回 | 完整時間戳、checksum 與更多樣本 |
| Gmail | 管理員帳號的備份曾失敗 | 錯誤原因、修復與再次成功證據 |
| Calendar | 沒有完整還原紀錄 | 事件還原與內容驗證 |
| Contacts | 沒有完整還原紀錄 | 聯絡人還原與欄位比對 |

Drive 操作記錄約 15 分鐘，沒有完整起算點與結束點，不能當作正式 RTO。測試刪除應只用已確認備份的專用測試資料，不能把清空正式資料當日常驗證步驟。

<div class="video-grid"><article class="video-card"><div class="video-frame"><iframe src="https://www.youtube-nocookie.com/embed/v6DeSETPUSg" title="DP340 Google Workspace 備份還原驗證紀錄" loading="lazy" allow="accelerometer; autoplay; clipboard-write; encrypted-media; gyroscope; picture-in-picture; web-share" allowfullscreen></iframe></div><h3>備份還原驗證紀錄</h3><p><a href="https://youtu.be/v6DeSETPUSg" target="_blank" rel="noopener noreferrer">在 YouTube 開啟原始影片</a></p></article></div>

## 失敗時，先查哪裡？

| 現象 | 排查方向 |
| --- | --- |
| 連線驗證失敗 | 網路、時間、JSON、服務帳戶與 Client ID |
| 部分服務成功、部分失敗 | 該服務授權範圍、帳號服務狀態與詳細錯誤 |
| 工作有進度但沒有還原點 | 最終狀態、部分失敗與實際選取範圍 |
| 還原不能選目標或執行失敗 | 該版本還原限制、權限與目標對象 |
| 新使用者沒備份 | 群組／使用者選取與計畫涵蓋範圍 |

以上是排查方向，不是 Gmail 本案已確認的根因。處理完要重跑失敗項目並保存結果，不能只用 Drive 成功來代替 Gmail 驗收。

## 建議的日常維護節奏

| 頻率 | 做什麼 |
| --- | --- |
| 每天 | 看各服務最終結果、失敗帳號與最新還原點 |
| 每週 | 核對新進／離職帳號、群組、容量與配額 |
| 每月 | 抽樣還原，檢查憑證與授權變動 |
| 每季或重大變更後 | 做較完整的多服務還原演練，檢查異地副本計畫 |

這是維護建議，不是已執行的紀錄。每次測試記下備份點、原始內容、還原時間與比對結果，才能追蹤恢復能力。

## 發布紀錄前的資料保護

移除 JSON 私鑰、token、完整憑證與可識別的使用者資料。Scopes 本身是權限名稱，與私鑰不同；仍應避免把不必要的組織帳號對應和完整管理畫面公開。

[DP340 空間節省報告](https://kbwangtw.github.io/IT-Knowledge-Base/docs/synology/dp340-google-workspace-apm20-dedup-test/)是 Guest OS 與 Workspace 的合併統計，不能拿來當作每個服務備份成功的證據。
