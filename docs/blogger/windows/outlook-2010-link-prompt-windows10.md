---
layout: default
title: "Windows 10 上 Outlook 2010 點連結一直問要用哪個程式開啟（摘要）"
date: 2016-05-11
categories: [Windows, Outlook, Troubleshooting, Blogger 舊文, 轉貼摘要]
permalink: /docs/blogger/windows/outlook-2010-link-prompt-windows10/
last_modified_at: 2026-10-24
---

# Windows 10 上 Outlook 2010 點連結一直問要用哪個程式開啟（摘要）

> **一句話**：Windows 10 + IE 11 為預設瀏覽器 + Outlook 2007／2010 時，點信中連結會一直跳出「要用哪個程式開啟」；原因是登錄檔少了 `htmlfile\shell\opennew\command`，微軟提供自動修正工具，也可以手動補上這個機碼。

| 項目 | 內容 |
| --- | --- |
| 適合誰看 | 升級 Windows 10 後，舊版 Outlook 點連結一直跳視窗的人 |
| 性質 | **摘要**：原文為轉貼微軟知識庫 KB3094186 的英文全文，這裡只用中文整理重點 |
| 日期 | 2016-05-11（原轉貼於 Blogger，2026-10-24 改為摘要） |

> Outlook 2007／2010 與 IE 11 都已停止支援，這篇只留給還在維護舊環境的人參考。

## 1. 先認識幾個名詞

| 名詞 | 白話解釋 |
| --- | --- |
| **登錄檔（Registry）** | Windows 存放設定的資料庫，用 `regedit` 編輯 |
| **機碼（Key）** | 登錄檔裡像資料夾的層級 |
| **HKEY_CLASSES_ROOT** | 記錄「什麼檔案類型用什麼程式開」的區域 |

## 2. 重點整理

| 項目 | 內容 |
| --- | --- |
| 發生條件 | Windows 10、IE 11 設為預設瀏覽器、Outlook 2007 或 2010 |
| 原因 | 登錄檔缺少 `HKEY_CLASSES_ROOT\htmlfile\shell\opennew\command` |
| 解法一 | 執行微軟提供的自動修正工具（Easy fix） |
| 解法二 | 關閉 Outlook，用 `regedit` 在 `htmlfile\shell` 底下建立 `opennew\command`，(預設) 值依「新分頁」或「新視窗」開啟的需求填入 KB 文中提供的命令 |

> ⚠️ 修改登錄檔前先匯出備份；值的內容請照官方 KB 原文輸入。

## 3. 延伸閱讀

- [Microsoft KB3094186（英文原文）](https://support.microsoft.com/en-us/kb/3094186)
- [Blogger 原文](https://kbwangtw.blogspot.com/2016/05/edge-outlook-2010.html)
