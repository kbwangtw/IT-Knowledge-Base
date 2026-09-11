---
layout: default
title: "DP340 + APM 2.0 Google Workspace 備份與還原演練計畫"
categories: [Synology, APM, Google Workspace, Backup]
---

<div class="kb-hero">
<h1>DP340 + APM 2.0 Google Workspace 備份與還原演練計畫</h1>
<p>透過 ActiveProtect Manager 2.0 的 Google Workspace 連線精靈，建置 Gmail、日曆、聯絡人與雲端硬碟的每日備份，並記錄實際還原測試結果。</p>
<div class="kb-badges"><span class="kb-badge">Synology DP340</span><span class="kb-badge">APM 2.0</span><span class="kb-badge">Google Workspace</span><span class="kb-badge">Backup</span></div>
</div>

<div class="kb-alert"><strong>文件狀態：</strong>草稿，commit 前請依「敏感資訊去敏感化規範」章節檢查一次。<strong>適用版本：</strong>Synology ActiveProtect Manager (APM) 2.0（2026/9/4 發布，新增 Google Workspace 支援）。<strong>維護單位：</strong>Infra Team。<strong>最後更新：</strong>請填入實際日期。</div>

<div class="kb-info"><strong>備註：</strong>Google Workspace protection 是 APM 2.0 才新增的功能，官方文件與 UI 措辭仍可能持續調整，若後續版本 UI 有變動，請同步更新本文件對應章節。</div>

---

## 目錄

1. 架構總覽
2. 建置前準備 Checklist
3. 建置步驟(Step 1–10)
4. Google Workspace 授權設定注意事項(Domain-wide Delegation / Client ID / OAuth Scope)
5. 服務對應設定(Gmail / Calendar / Contacts / Drive)
6. 建置完成 Checklist
7. Backup Activity 驗證方式
8. Troubleshooting
9. Restore 測試建議
10. Daily / Weekly / Monthly 維運 SOP
11. 敏感資訊去敏感化規範
12. 版本紀錄

---

## 1. 架構總覽

```
Google Workspace (SaaS)
   │  OAuth 2.0 Service Account + Domain-wide Delegation (HTTPS 443)
   ▼
DP340 (ActiveProtect Manager 2.0)
   │  雲端應用程式 → Google Workspace Protection Plan
   ▼
DP340 本地儲存(備份伺服器:DP340)
   │  (建議) 異地 / 離線 copy,符合 3-2-1 原則
   ▼
異地儲存(Vault / 另一台 NAS / Cloud Storage,依企業需求規劃)
```

**保護範圍**:Gmail、Google 日曆、Google 聯絡人、Google 我的雲端硬碟(My Drive)。

---

## 2. 建置前準備 Checklist

| 項目 | 說明 | 完成 |
|---|---|---|
| DP340 初始設定完成 | 硬體上架、磁碟陣列、基本網路設定 | ☐ |
| APM 2.0 版本確認 | 確認已升級至 2.0(舊版無 Google Workspace 支援) | ☐ |
| 網路連線正常 | DP340 可對外連通 Google API endpoints(443) | ☐ |
| DNS / Internet 正常 | 解析正常、無 proxy 阻擋 | ☐ |
| 系統時間正確 | NTP 同步,時間誤差會影響 OAuth token 驗證 | ☐ |
| Google Workspace Super Admin 帳號 | 有權限執行 Domain-wide Delegation 設定者 | ☐ |
| 授權/License 確認 | 已與代理商確認 GW connector 是否佔用額外保護額度 | ☐ |
| 要保護的使用者/部門清單 | 先盤點好,避免建置時臨時決定 | ☐ |
| 儲存容量評估 | 依使用者數量、Gmail/Drive 資料量估算所需空間 | ☐ |

---

## 3. 建置步驟

### Step 1｜確認 DP340 前置狀態

確認以下項目皆正常:

- DP340 已完成初始設定
- ActiveProtect Manager 2.0 運作正常
- 網路連線正常
- DNS / Internet 正常
- 系統時間正常(建議設定 NTP,避免手動誤差)

> **風險提醒**:系統時間偏差會導致後續 OAuth 授權驗證失敗,建議建置前先確認 NTP 同步狀態。

### Step 2｜建立 Google Workspace 連線

路徑:**ActiveProtect Manager → 雲端應用程式**

開始建立 Google Workspace 網域連線,APM 會進入 Google Workspace 連線精靈,依畫面指示逐步操作。

### Step 3｜取得服務帳戶金鑰(Service Account Key)

APM 會要求建立/取得 Service Account 相關資訊。

> ⚠️ **重要注意事項**:服務帳戶金鑰檔案(JSON Key)**務必妥善保存**,遺失可能無法復原,需要在 Google Cloud Console 重新建立並重新走一次授權流程。
>
> 建議做法:
> - 金鑰檔案不要放在一般共用資料夾,建議存放於受限存取的密碼/機密管理系統(例如公司的 Vault / Password Manager)
> - 不要以任何形式(含截圖)放入 GitHub 或其他版控系統
> - 記錄金鑰建立日期與負責人,方便日後輪替(key rotation)

### Step 4｜Google Workspace 全網域委派(Domain-wide Delegation)

進入 **Google 管理控制台 → API 控制項 → 網域範圍委派(Domain-wide Delegation)**,新增 API 用戶端:

- 填入 APM 提供的 **Client ID**
- 填入 APM 提供的 **OAuth Scope**

> 詳細注意事項請見第 4 章「Google Workspace 授權設定注意事項」。

### Step 5｜完成授權

回到 APM,完成 Google Workspace 授權後,讓 APM 驗證 Google Workspace 網域,確認網域可以正常加入(狀態顯示已驗證/已連線)。

### Step 6｜設定自動還原(Recovery)相關選項

依服務類型設定自動還原相關選項,涵蓋:

- Gmail
- Google 日曆
- Google 聯絡人
- Google 我的雲端硬碟(My Drive)

依企業實際需求選擇要啟用的服務與還原設定。

### Step 7｜建立自動備份規則

建立 **Daily Backup** 規則,並指定:

- **備份伺服器**:DP340

> 建議排程避開營業時間,避免大量 API 呼叫影響 Google Workspace 使用體驗;首次全量備份時間可能較長,需預留足夠時間窗口。

### Step 8｜選擇 Google Workspace 使用者/群組

從 Google Workspace 使用者清單中,依企業實際需求選擇要保護的使用者或部門群組(例如各功能部門帳號)。

> 建議:先以小範圍(例如 IT 部門)做 POC 驗證,確認流程與資料完整性後,再擴大到全公司範圍。

### Step 9｜設定使用者服務範圍

針對已選取的使用者/群組,設定要保護的服務範圍,包含:

- 郵件(Gmail)
- 行事曆(Calendar)
- 聯絡人(Contacts)
- 雲端硬碟(Drive)

並套用備份規則:**Daily Backup → DP340**

> 此畫面(設定完成後的服務對應清單)可作為「建置完成」的佐證截圖,建議存檔留存。

### Step 10｜確認備份工作已啟動

路徑:**活動 → 備份活動**

確認 Gmail 及其他 Google Workspace 相關工作負載已出現在備份活動清單中,狀態顯示:

- 狀態:**正在備份**
- 備份伺服器:**DP340**

代表備份工作已成功啟動執行。

### 操作影片參考

<div class="video-grid"><article class="video-card"><div class="video-frame"><iframe src="https://www.youtube-nocookie.com/embed/SZIe91ktVag" title="DP340 + APM 2.0 Google Workspace 備份建置操作影片" loading="lazy" allow="accelerometer; autoplay; clipboard-write; encrypted-media; gyroscope; picture-in-picture; web-share" allowfullscreen></iframe></div><h3>建置操作影片</h3><p><a href="https://youtu.be/SZIe91ktVag" target="_blank" rel="noopener noreferrer">在 YouTube 開啟原始影片</a></p></article></div>

> 本影片為 Step 1–10 建置流程的操作紀錄；若後續 APM UI 有變動，請以官方畫面為準，並同步更新本文件對應章節。

---

## 4. Google Workspace 授權設定注意事項

### Domain-wide Delegation

- 只在 Google 管理控制台的 **API 控制項 → 網域範圍委派** 新增 APM 提供的 Client ID,**不要**額外開放給其他非必要的應用程式
- 每次新增/異動委派設定,建議記錄操作人、日期、原因,方便稽核

### Client ID

- Client ID 本身不是機密資訊(不等同密碼),但仍建議不要公開張貼在對外可見的頻道
- 若日後金鑰輪替,Client ID 可能連帶變更,委派設定需同步更新

### OAuth Scope

- **最小權限原則**:只授權備份實際需要的 Scope(對應 Gmail / Calendar / Contacts / Drive 唯讀存取即可,除非有還原寫入需求)
- 授權範圍設定錯誤(過寬或過窄)是常見的建置卡關原因,設定後務必回到 APM 端測試驗證是否能正常拉取資料
- 建議在文件中額外附上「本次實際使用的 Scope 清單」內部版本(**不要**放進公開 GitHub repo,詳見第 11 章)

---

## 5. 服務對應設定摘要

| 服務 | 對應內容 | 備份頻率 | 備份伺服器 |
|---|---|---|---|
| Gmail | 郵件、附件 | Daily | DP340 |
| Google 日曆 | 行事曆事件 | Daily | DP340 |
| Google 聯絡人 | 聯絡人資料 | Daily | DP340 |
| Google 我的雲端硬碟 | My Drive 檔案 | Daily | DP340 |

> 依實際設定的群組數量調整表格內容,範例中為 7 個群組全數套用相同規則。

---

## 6. 建置完成 Checklist

| 項目 | 驗證方式 | 完成 |
|---|---|---|
| Google Workspace 網域已加入 APM 且驗證成功 | APM 雲端應用程式頁面顯示已連線 | ☐ |
| Domain-wide Delegation 設定完成 | Google 管理控制台可查到對應 Client ID | ☐ |
| Daily Backup 規則已建立 | APM 備份規則列表可查到 | ☐ |
| 目標使用者/群組已選取 | APM 使用者清單確認 | ☐ |
| 四項服務(Mail/Calendar/Contacts/Drive)皆已套用規則 | APM 服務對應畫面截圖存檔 | ☐ |
| 首次備份已成功執行 | 活動 → 備份活動,狀態非失敗 | ☐ |
| 已完成至少一次還原測試 | 見第 9 章 | ☐ |
| 已設定失敗通知(email/webhook) | APM 通知設定確認 | ☐ |
| 已規劃異地/離線 copy | 符合 3-2-1 原則 | ☐ |

---

## 7. Backup Activity 驗證方式

1. 路徑:**活動 → 備份活動**
2. 確認對應 workload(Gmail / Calendar / Contacts / Drive)出現在清單中
3. 狀態應顯示「正在備份」或「已完成」,備份伺服器欄位應為 **DP340**
4. 若長時間停留在「正在備份」未完成,參考第 8 章 Troubleshooting

---

## 8. Troubleshooting

| 問題現象 | 可能原因 | 處置方式 | 驗證 |
|---|---|---|---|
| 網域驗證失敗 | Domain-wide Delegation 尚未生效(Google 端有時需要數分鐘才會同步) | 稍候重試,或重新確認 Client ID / Scope 是否輸入正確 | APM 網域狀態顯示已驗證 |
| OAuth 授權失敗 | 系統時間偏差 / Scope 設定不完整 | 檢查 NTP 同步、重新核對 Scope 清單 | 重新執行授權流程成功 |
| 備份卡在「正在備份」不動 | API 配額限制、首次全量備份資料量過大 | 檢查 Google API 配額使用狀況,評估是否分批排程 | 備份活動狀態轉為已完成 |
| 部分使用者資料未備份 | 使用者/群組未正確勾選,或該帳號權限不足 | 回到 Step 8 確認使用者清單 | 該使用者出現在備份活動中 |
| 服務帳戶金鑰遺失 | 未妥善保管 | 於 Google Cloud Console 重新建立 Service Account 金鑰,重跑 Step 3–5 | 重新授權成功 |
| 通知未收到 | 通知設定未啟用或收件設定錯誤 | 檢查 APM 通知設定 | 手動觸發測試通知成功送達 |

---

## 9. Restore 測試建議

- **頻率**:建議至少每季執行一次還原演練,重大版本升級後(如 APM 2.x → 2.x+1)額外加測一次
- **測試範圍**:
  - 單一使用者:還原一封 Gmail 郵件、一個 Drive 檔案,確認內容/中繼資料完整
  - 抽樣還原:每次抽測 1–2 個群組,確認 Calendar / Contacts 資料可正確還原
- **驗證重點**:
  - 還原後資料內容是否與原始一致
  - 檔案權限(Drive 共用權限)是否正確還原
  - 還原耗時是否在可接受範圍內(記錄下來作為 RTO 參考)
- **記錄**:每次演練需記錄日期、測試範圍、結果、若有異常需附上處置方式,存放於維運紀錄(建議與本 SOP 分開存放,避免內部細節外流)

### 實際測試紀錄(第一次驗證)

| 項目 | 測試步驟 | 結果 | 備註 |
|---|---|---|---|
| Google 我的雲端硬碟 | 於雲端硬碟新增一份 test 檔案 → DP340 執行備份 → 於雲端硬碟本機與垃圾桶皆刪除該 test 檔案 → 於 DP340 執行還原 | ✅ Pass | 約 15 分鐘後 APM 顯示還原成功;回到雲端硬碟可看到一個 `restore` 資料夾,內含原本已刪除的 test 檔案,資料完整 |
| Gmail | 於同一次備份工作中一併勾選 <ADMIN_EMAIL> 帳號的 Gmail | ❌ Fail | 該次備份僅雲端硬碟成功,Gmail 郵件未成功備份,因此也無法執行還原 |

> **待釐清**:Gmail 未成功備份的原因尚未確認,可能與 OAuth Scope 是否涵蓋 Gmail API、Domain-wide Delegation 設定範圍,或該帳號 Gmail 服務啟用狀態有關。下次測試建議依第 8 章 Troubleshooting 排查,並記錄 APM 備份活動當下的錯誤訊息/log,確認根因後回填本節。

<div class="video-grid"><article class="video-card"><div class="video-frame"><iframe src="https://www.youtube-nocookie.com/embed/v6DeSETPUSg" title="DP340 Google Workspace 備份還原驗證紀錄" loading="lazy" allow="accelerometer; autoplay; clipboard-write; encrypted-media; gyroscope; picture-in-picture; web-share" allowfullscreen></iframe></div><h3>備份還原驗證紀錄</h3><p><a href="https://youtu.be/v6DeSETPUSg" target="_blank" rel="noopener noreferrer">在 YouTube 開啟原始影片</a></p></article></div>

---

## 10. Daily / Weekly / Monthly 維運 SOP

### Daily

- 檢查前一日 Daily Backup 是否成功(活動 → 備份活動)
- 確認無失敗/異常通知
- 確認 DP340 儲存空間使用率在安全範圍內

### Weekly

- 抽查 1–2 個使用者的備份資料是否完整(不需真正還原,可只檢視備份內容清單)
- 檢查 Google API 配額使用趨勢,是否接近上限
- 確認新加入/離職的使用者是否已同步調整保護清單(Account Discovery 若未啟用,需人工維護)

### Monthly

- 執行一次抽樣還原測試(見第 9 章)
- 檢視儲存容量成長趨勢,評估是否需要擴充
- 確認 Service Account 金鑰、Domain-wide Delegation 設定仍然有效,無異常變更紀錄
- 檢查 APM 是否有版本更新,評估升級排程

---

## 11. 敏感資訊去敏感化規範(Push 到 GitHub 前必查)

Push 到 `kbwangtw/IT-Knowledge-Base` 與 `Jianan-infra/IT-Knowledge-Base` 之前,請逐項確認以下內容**不存在**於檔案中:

| 類別 | 範例 | 處置方式 |
|---|---|---|
| 實際網域名稱 | `company.com` | 以 `<YOUR_DOMAIN>` 佔位符取代 |
| 帳號 / Email | `admin@company.com` | 以 `<ADMIN_EMAIL>` 取代,或改用角色描述(例如「Super Admin 帳號」) |
| Service Account 金鑰內容 | JSON key 檔案內容、private key | **絕對不可**出現,包含截圖 |
| Client ID / Client Secret | OAuth 用戶端 ID 實際數值 | 以 `<CLIENT_ID_REDACTED>` 取代 |
| DP340 內部 IP / hostname | `10.x.x.x`、內網主機名稱 | 以 `<DP340_INTERNAL_IP>` 取代或直接移除 |
| 實際部門/使用者清單 | ACC、ELC、HR、QA、Warehouse、Shipping 等真實對應的內部單位 | 若為公司真實組織架構,建議改用通用範例(例如「部門 A / 部門 B」),除非該資訊本身不具機敏性 |
| License / 授權序號 | APM license key | 不可出現 |
| 截圖中的浮水印/使用者資訊 | 畫面截圖若含有實際資料 | 上傳前需打碼或改用示意圖 |

**建議流程**:commit 前用 `grep` 或簡單腳本掃描檔案,搜尋常見敏感字串模式(如網域關鍵字、`@`符號後接公司網域、IP 位址格式),確認無殘留後再 push。

---

## 12. 版本紀錄

| 版本 | 日期 | 異動內容 | 異動人 |
|---|---|---|---|
| v0.1 | 待填 | 初版建立,依實際操作影片整理 Step 1–10 | 待填 |
| v0.2 | 2026-09-10 | 新增第一次實際測試紀錄:Google 雲端硬碟備份還原 Pass,Gmail 備份未成功(原因待查) | kbwangtw |


## 相關技術紀錄

- [2026-09-11 整理：六台 GuestOS + Google Workspace 合併備份重複資料刪除實測（75%／3.96x）](dp340-google-workspace-apm20-dedup-test.md)：含原始截圖、容量核算及單次觀察限制；此容量紀錄不代表 Gmail 備份問題已解決。
