---
layout: default
title: "EPSON L550 在 Windows 10 21H1 安裝 Fax Utility：先換成原廠驅動"
date: 2021-07-21
categories: [Windows, Printer, Troubleshooting, Blogger 舊文]
permalink: /docs/blogger/windows/epson-l550-fax-utility-win10/
last_modified_at: 2026-10-24
---

# EPSON L550 在 Windows 10 21H1 安裝 Fax Utility：先換成原廠驅動

> **一句話**：Windows 自動裝的驅動可以列印，但 Fax Utility 不認它；先裝 EPSON 原廠驅動，在印表機內容把驅動改成 **EPSON L550 Series**，再安裝 Fax Utility，Office 裡才會出現傳真印表機。

| 項目 | 內容 |
| --- | --- |
| 適合誰看 | 多功能事務機能印不能從電腦傳真的人 |
| 環境 | Windows 10 21H1；EPSON L550 噴墨事務機；EPSON Fax Utility |
| 日期 | 2021-07-21（原文發表於 Blogger，2026-10-24 改寫為新手版） |
| 結論 | ✅ 改用原廠驅動後 Fax Utility 安裝成功，Office 可選 L550 Series (FAX) |

## 1. 先認識幾個名詞

| 名詞 | 白話解釋 |
| --- | --- |
| **Windows 內建驅動** | 接上印表機時 Windows 自動安裝的通用驅動，功能較少 |
| **原廠驅動** | 廠商官網下載的完整驅動 |
| **Fax Utility** | EPSON 的電腦傳真軟體，會新增一台「(FAX)」虛擬印表機 |

## 2. 流程

```text
Fax Utility 安裝時要求先裝 EPSON 驅動
  → 下載 EPSON 原廠驅動並安裝
  → 印表機內容 → 進階 → 驅動程式改選「EPSON L550 Series」
  → 再安裝 Fax Utility
  → Office 列印清單出現「EPSON L550 Series (FAX)」
```

## 3. 步驟一：安裝原廠驅動

**怎麼做**：到 EPSON 台灣官網下載 L550 Series 的 Windows 驅動並安裝（原廠客服提供的做法）。

## 4. 步驟二：切換驅動程式

**怎麼做**：**設定 → 印表機與掃描器** → EPSON L550 Series → **印表機內容** → **進階**頁 → **驅動程式**下拉選單選 **EPSON L550 Series**。

![印表機內容中選擇 EPSON L550 Series 驅動（原作者截圖）]({{ '/docs/blogger/windows/images/epson-l550-driver-select.png' | relative_url }})

> 清單最上面的 `EPSON ESC/P-R V4 Class Driver` 是 Windows 自動裝的，不要選它。

## 5. 步驟三：安裝 Fax Utility

**怎麼做**：執行 EPSON Fax Utility 安裝程式。

**應該看到什麼**：這次不再要求先安裝驅動，可以順利完成；印表機清單多出 **EPSON L550 Series (FAX)**，Word 等 Office 程式列印時可選它來傳真。

![印表機清單出現 L550 Series (FAX)（原作者截圖）]({{ '/docs/blogger/windows/images/epson-l550-fax-printer.png' | relative_url }})

## 6. 常見問題

| 現象 | 怎麼辦 |
| --- | --- |
| Fax Utility 一直說要先裝驅動 | 驅動還是 Windows 內建的；照步驟二切換 |
| 清單沒有 (FAX) 印表機 | Fax Utility 沒裝成功，重新安裝 |
| 切換驅動後不能列印 | 重新開機；或移除印表機後只用原廠驅動重新加入 |

## 7. 延伸閱讀

- [EPSON 台灣驅動下載](https://www.epson.com.tw/)
- [Blogger 原文](https://kbwangtw.blogspot.com/2021/07/epson-l550-fax-utility-win10-21h1.html)
