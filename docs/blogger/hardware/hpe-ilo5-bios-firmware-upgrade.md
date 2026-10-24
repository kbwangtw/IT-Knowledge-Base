---
layout: default
title: "HPE Gen10 伺服器透過 iLO 5 網頁更新 BIOS 與 iLO 韌體"
date: 2020-07-30
categories: [Hardware, HPE, iLO, Firmware, Blogger 舊文]
permalink: /docs/blogger/hardware/hpe-ilo5-bios-firmware-upgrade/
last_modified_at: 2026-10-24
---

# HPE Gen10 伺服器透過 iLO 5 網頁更新 BIOS 與 iLO 韌體

> **一句話**：先在 iLO 記下目前版本，到 HPE 官網下載新版 BIOS（`.flash`）與 iLO（`.bin`），在 iLO 的 **Firmware & OS Software → Upgrade Firmware** 上傳；BIOS 要**重開機**才生效，iLO 會**自動重啟**。

| 項目 | 內容 |
| --- | --- |
| 適合誰看 | 第一次幫 HPE DL／ML 伺服器更新韌體的人 |
| 環境 | HPE ProLiant DL／ML Gen10（iLO 5）；原文更新到 BIOS 2.16（2020-05-25）、iLO 5 2.18（2020-07-10） |
| 日期 | 2020-07-30（原文發表於 Blogger，2026-10-24 改寫為新手版） |
| 結論 | ✅ BIOS 與 iLO 都更新完成，重開後確認版本 |

> ⚠️ 更新韌體前先確認有最近的備份，並選在可以重開機的維護時段；更新過程中**不要斷電**。

## 1. 先認識幾個名詞

| 名詞 | 白話解釋 |
| --- | --- |
| **iLO 5** | HPE Gen10 伺服器的遠端管理晶片，有自己的網頁介面 |
| **BIOS（System ROM）** | 主機板韌體，`.flash` 檔 |
| **iLO 韌體** | iLO 本身的韌體，`.bin` 檔 |
| **SPP（Service Pack for ProLiant）** | HPE 的整包韌體更新光碟，一次更新所有元件 |

## 2. 整體流程

```text
iLO 登入 → Information → Overview：記下目前 iLO、BIOS 版本
  → 官網下載新版 BIOS、iLO → 解壓縮到操作的電腦
  → Firmware & OS Software → Firmware → Upgrade Firmware
      ① 上傳 BIOS 的 .flash → Flash → 完成後重開機
      ② 上傳 iLO 的 .bin   → Flash → iLO 自動重啟
  → 回 Firmware 頁確認版本
```

## 3. 步驟一：記下目前版本

**怎麼做**：瀏覽器登入 iLO → 左側 **Information** → **Overview**，記下 iLO Firmware Version 與 System ROM 版本。

## 4. 步驟二：下載新版韌體

**怎麼做**：到 HPE 支援網站搜尋你的機型，下載 BIOS（System ROM）與 iLO 5 韌體，解壓縮到操作的電腦上。

| 韌體 | 原文使用的版本 | 檔案類型 |
| --- | --- | --- |
| BIOS | 2.16_05-25-2020（2020-06-08 發布） | `.flash` |
| iLO 5 | 2.18（2020-07-10 發布） | `.bin` |

> 請下載**你機型**的最新版，不要照抄版本號。

## 5. 步驟三：更新 BIOS

**怎麼做**：

1. 左側 **Firmware & OS Software** → 中間 **Firmware**：查看所有元件目前的版本。
2. 右邊點 **Upgrade Firmware**。
3. 選 **Local file** → 瀏覽 → 選解壓縮後副檔名為 **`.flash`** 的檔案（確認檔名版本正確）→ 按綠色 **Flash**。
4. 出現警告訊息，確認後繼續。

**應該看到什麼**：畫面上方依序顯示「接收中」與「更新中」的狀態；完成後提示需要**重新開機**才會啟用新版 BIOS。重開機後回 Firmware 頁確認版本。

## 6. 步驟四：更新 iLO

**怎麼做**：同樣在 **Upgrade Firmware** → **Local file** → 選副檔名為 **`.bin`** 的檔案 → **Flash**。

**應該看到什麼**：流程和 BIOS 相同（部分英文字略有差異）；完成後 **iLO 會自動重啟**，網頁會斷線一陣子。重新登入後到 Firmware 頁確認版本。

> iLO 重啟**不影響**伺服器上正在執行的作業系統。

## 7. 常見問題

| 現象 | 怎麼辦 |
| --- | --- |
| 上傳後說檔案格式不符 | BIOS 選 `.flash`、iLO 選 `.bin`；確認下載的是對應機型 |
| BIOS 更新完版本沒變 | 還沒重開機 |
| iLO 網頁連不上 | 正在自動重啟，等幾分鐘 |
| 要一次更新所有元件（網卡、RAID 卡等） | 改用 SPP 開機光碟 |

## 8. 延伸閱讀

- [HPE 支援中心](https://support.hpe.com/)
- [Blogger 原文（含當時的下載連結與參考影片）](https://kbwangtw.blogspot.com/2020/07/hpe-dlml-server-upgrade-ilo-5-bios.html)
