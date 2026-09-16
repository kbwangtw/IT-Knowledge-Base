---
layout: default
title: "Office 2024 VL MAK 啟用失敗 0xC004C020：額度超限排查與 KMS 遷移建議"
permalink: /docs/licensing/office-2024-vl-mak-activation-limit-exceeded/
date: 2026-09-16
categories: [Licensing, Office, Windows, KMS, MAK]
---

<div class="kb-hero">
<h1>Office 2024 VL MAK 啟用失敗 0xC004C020</h1>
<p>ospp.vbs 反覆 /inpkey 與 /act 皆回報「Multiple Activation Key has exceeded its limit」，排查金鑰型態、額度歸屬與後續處置方向。</p>
<div class="kb-badges"><span class="kb-badge">Office 2024 VL</span><span class="kb-badge">MAK</span><span class="kb-badge">ospp.vbs</span><span class="kb-badge">Licensing</span></div>
</div>

> 本文記錄一次實機 `ospp.vbs` 操作與錯誤訊息解讀。金鑰為敏感資訊，本文僅保留末 5 碼供比對，其餘以 `•` 遮蔽；不代表已核實金鑰合法性或來源。

## 1. 問題現象

在 `C:\Program Files\Microsoft Office\Office16` 目錄下，以系統管理員權限執行 `ospp.vbs` 匯入產品金鑰並嘗試啟用，`/inpkey` 每次都回報成功，但接續的 `/act` 一律失敗，重複執行 `/inpkey` → `/act` 數次結果相同。

## 2. 環境

| 項目 | 內容 |
|---|---|
| 軟體 | Microsoft Office（Office16 目錄，含 Office 2024 元件） |
| 授權型態 | Volume License（VL），MAK 通路 |
| 工具 | `ospp.vbs`（Office Software Protection Platform script） |
| 金鑰型態 | Multiple Activation Key（MAK） |

## 3. 診斷指令與實機輸出

```bat
cscript ospp.vbs /inpkey:•••••-•••••-•••••-•••••-8T4PW
cscript ospp.vbs /act
cscript ospp.vbs /dstatus
```

`/inpkey` 每次都回報：

```text
<Product key installation successful>
```

`/act` 每次都回報同一組錯誤：

```text
SKU ID: 44a07f51-8263-4b2f-b2a5-70340055c646
LICENSE NAME: Office 24, Office24Standard2024VL_MAK_AE1 edition
LICENSE DESCRIPTION: Office 24, RETAIL(MAK) channel
Last 5 characters of installed product key: 8T4PW
ERROR CODE: 0xC004C020
ERROR DESCRIPTION: The activation server reported that the Multiple Activation Key has exceeded its limit.
```

`/dstatus` 顯示目前處於開箱寬限期，尚未真正啟用成功：

```text
PRODUCT ID: 00503-08309-68568-AA367
SKU ID: 44a07f51-8263-4b2f-b2a5-70340055c646
LICENSE NAME: Office 24, Office24Standard2024VL_MAK_AE1 edition
LICENSE DESCRIPTION: Office 24, RETAIL(MAK) channel
LICENSE STATUS:  ---OOB_GRACE---
ERROR CODE: 0x4004F00C
ERROR DESCRIPTION: The Software Licensing Service reported that the application is running within the valid grace period.
REMAINING GRACE: 29 days  (42278 minute(s) before expiring)
```

`/inpkey` 成功只代表金鑰格式正確、已寫入本機登錄；不代表金鑰已通過微軟啟用伺服器驗證。真正決定能否啟用的是接續的 `/act`。

## 4. 錯誤碼解讀

`0xC004C020`／`The activation server reported that the Multiple Activation Key has exceeded its limit.`

- 這組金鑰是 **MAK（Multiple Activation Key）**，屬於 Office 2024 Standard VL（Volume License）授權，透過 MAK 通路啟用。
- MAK 的可啟用次數有上限，且**由微軟啟用伺服器端計數**，不是本機或這台電腦的限制。
- 這個錯誤代表：該組金鑰累計啟用次數已達到微軟後端記錄的上限，伺服器直接拒絕本次啟用要求。

`OOB_GRACE`（Out-of-Box Grace，開箱寬限期）代表軟體目前仍可正常使用，但尚未完成真正啟用；寬限期（本次紀錄為 29 天）內若未成功啟用，逾期後會進入功能受限模式。

## 5. 為什麼重複 /inpkey 與 /act 沒有用

MAK 的啟用次數上限綁在金鑰本身，記錄在微軟雲端的啟用伺服器，不是本機狀態。反覆執行 `/inpkey`（重新輸入同一把已超額的金鑰）與 `/act`（重新送出啟用請求）只是對雲端伺服器重複提出同一個會被拒絕的請求，問題不會因為在本機重試而改變。

## 6. 處置建議

| 情境 | 建議做法 |
|---|---|
| 屬於公司／組織採購的正版 VL 授權 | 聯繫內部 IT 或該組織的 Volume Licensing Service Center（VLSC）管理者，確認金鑰剩餘啟用次數；若額度確實用盡，需向微軟或經銷商申請補發／更換金鑰 |
| 金鑰來源不明或非透過正規採購取得 | 應視為授權風險，改由正規管道（Microsoft 365 訂閱、或向微軟／授權經銷商）取得合法授權，不建議持續嘗試啟用 |
| 短期內需先能使用 | 目前仍在開箱寬限期內可正常使用；務必在寬限期截止前解決啟用問題，避免進入功能受限模式 |

## 7. 企業環境的替代方案：KMS

若組織需要大量機器啟用 Office VL，逐台以 MAK 手動 `/act` 不易管理，且 MAK 次數有限。較適合的方式是：

- **KMS（Key Management Service）**：內網部署 KMS 主機，用戶端啟用時連回 KMS 主機取得啟用，理論上不限次數，但用戶端需定期（通常 180 天週期內）重新連線續約。
- **ADBA（Active Directory-based Activation）**：透過 AD 網域完成啟用，適合已有 AD 環境的組織。

MAK 較適合少量、獨立、不常連內網的機器；KMS／ADBA 較適合大量、常態連線內網的機器。

## 8. 風險與後續建議

- 不要在額度超限的情況下持續重試 `/act`；這不會改變伺服器端的計數結果，也無助於排查根因。
- 若金鑰合法性存疑，應先確認來源，避免使用來路不明的 MAK／KMS 金鑰，可能違反授權條款並帶來合規風險。
- 寬限期內應優先確認金鑰額度與授權歸屬，避免逾期後影響業務使用的 Office 應用程式。
- 若組織長期有大量機器需啟用 Office／Windows VL，建議評估導入 KMS 或 ADBA，降低 MAK 額度管理負擔。

## 9. 參考資訊

- 本文所述錯誤碼與描述均來自 `ospp.vbs` 實機輸出，未查證微軟官方文件版本差異；不同 Office 版本的 `ospp.vbs` 參數與訊息可能略有差異。
- 金鑰型態（MAK／KMS／Retail）判讀方式：`ospp.vbs /dstatus` 的 `LICENSE DESCRIPTION` 欄位會標示 `RETAIL(MAK) channel` 或 `VOLUME_KMSCLIENT channel` 等通路資訊，可作為初步判斷依據。
