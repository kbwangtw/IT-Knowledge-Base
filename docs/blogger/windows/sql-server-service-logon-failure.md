---
layout: default
title: "SQL Server 服務因登入失敗無法啟動：更新服務帳戶密碼（摘要）"
date: 2011-02-25
categories: [Windows, SQL Server, Troubleshooting, Blogger 舊文, 轉貼摘要]
permalink: /docs/blogger/windows/sql-server-service-logon-failure/
last_modified_at: 2026-10-24
---

# SQL Server 服務因登入失敗無法啟動：更新服務帳戶密碼（摘要）

> **一句話**：SQL Server 服務是用某個 Windows 帳戶身分執行的；那個帳戶的密碼改了、服務裡記的卻還是舊密碼，服務就會因「不明帳戶或密碼錯誤」啟動失敗。到「服務」裡把該服務的登入密碼改成正確的即可。

| 項目 | 內容 |
| --- | --- |
| 適合誰看 | SQL Server 突然起不來，事件檢視器出現登入失敗訊息的人 |
| 性質 | **摘要**：原文內容整理自微軟知識庫文章（未註明出處），這裡只用自己的話整理重點 |
| 日期 | 2011-02-25（原發表於 Blogger，2026-10-24 改為摘要） |

## 1. 先認識幾個名詞

| 名詞 | 白話解釋 |
| --- | --- |
| **服務帳戶** | Windows 服務在背景執行時使用的身分 |
| **預設執行個體／具名執行個體** | 一台主機可裝多套 SQL Server；預設的服務名稱是 `MSSQLSERVER`，具名的是 `MSSQL$<名稱>` |
| **SQL Server Agent** | 負責排程工作的服務，同樣有自己的服務帳戶 |

## 2. 處理重點

```text
事件檢視器看到登入失敗 → 開啟「服務」（services.msc）
  → 找到 SQL Server 服務（MSSQLSERVER 或 MSSQL$<名稱>）
  → 內容 → 登入 → 輸入目前正確的密碼兩次 → 確定 → 啟動服務
  → SQL Server Agent（SQLAgent 或 SQLAgent$<名稱>）也用同一帳戶的話，一併修改
```

| 服務 | 預設執行個體 | 具名執行個體 |
| --- | --- | --- |
| SQL Server | `MSSQLSERVER` | `MSSQL$<執行個體名稱>` |
| SQL Server Agent | `SQLAgent` | `SQLAgent$<執行個體名稱>` |

> 新版 SQL Server 建議改用 **SQL Server 組態管理員** 修改服務帳戶與密碼，它會同時處理相關權限。

## 3. 預防

| 做法 | 說明 |
| --- | --- |
| 服務帳戶用專用帳號 | 不要用個人帳號，避免本人改密碼時服務跟著掛掉 |
| 使用受管理服務帳戶（gMSA） | 密碼由網域自動輪替，不需要手動更新 |

## 4. 延伸閱讀

- [Microsoft Learn：設定 Windows 服務帳戶與權限](https://learn.microsoft.com/en-us/sql/database-engine/configure-windows/configure-windows-service-accounts-and-permissions)
- [Blogger 原文](https://kbwangtw.blogspot.com/2011/02/ms-sqlsql-server.html)
