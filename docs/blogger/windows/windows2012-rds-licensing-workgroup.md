---
layout: default
title: "Windows Server 2012 無網域單機安裝遠端桌面服務與授權（摘要）"
date: 2015-06-29
categories: [Windows, RDS, Blogger 舊文, 轉貼摘要]
permalink: /docs/blogger/windows/windows2012-rds-licensing-workgroup/
last_modified_at: 2026-10-24
---

# Windows Server 2012 無網域單機安裝遠端桌面服務與授權（摘要）

> **一句話**：沒有網域的單機要讓多人同時遠端桌面，要安裝「遠端桌面工作階段主機」與「遠端桌面授權」兩個角色、啟用授權伺服器、安裝 RDS CAL，再用群組原則指定授權伺服器與授權模式。

| 項目 | 內容 |
| --- | --- |
| 適合誰看 | 工作群組（無 AD）環境要開放多人遠端桌面的人 |
| 性質 | **轉貼摘要**：原文引用自展碁國際的技術文章（53 張圖），這裡只整理流程重點，詳細畫面請看原文 |
| 日期 | 2015-06-29（原轉貼於 Blogger，2026-10-24 改為摘要） |

## 1. 先認識幾個名詞

| 名詞 | 白話解釋 |
| --- | --- |
| **RDS（遠端桌面服務）** | 讓多人同時遠端登入同一台伺服器 |
| **RD 工作階段主機** | 實際讓使用者登入的角色 |
| **RD 授權** | 管理 RDS CAL 的角色 |
| **RDS CAL** | 每位使用者或每台裝置連線需要的授權，分「每使用者」與「每裝置」 |
| **Open 大量授權** | 企業常見的授權購買方式，安裝時選對應的授權類型 |

## 2. 流程重點

```text
① 新增角色：用「角色型或功能型安裝」（無網域時不能用 RDS 的快速部署精靈）
     勾選 RD 工作階段主機、RD 授權
② 啟用授權伺服器：開啟「遠端桌面授權管理員」→ 啟用伺服器
③ 安裝授權：在授權管理員安裝 RDS CAL（依購買方式選，例如 Open 大量授權）
④ 指定授權：gpedit.msc → 遠端桌面工作階段主機 → 授權
     設定「使用指定的遠端桌面授權伺服器」（填本機）與授權模式（每裝置／每使用者）
```

| 注意事項 | 說明 |
| --- | --- |
| 只是遠端管理 | 系統預設允許 2 個管理連線，**不需要**安裝 RDS 角色與 CAL |
| 無網域只能用「每裝置」CAL 才能被正確追蹤 | 工作群組環境中「每使用者」CAL 不會被授權伺服器追蹤（推測依微軟說明，未在原文實測） |
| 寬限期 | 未設定授權時有 120 天寬限期，到期後無法連線 |

## 3. 延伸閱讀

- [原文來源（展碁國際，已無法連線）](http://i-services.dsmynas.org/wordpress/?p=4432)
- [Microsoft Learn：授權 RDS 部署](https://learn.microsoft.com/en-us/windows-server/remote/remote-desktop-services/rds-client-access-license)
- [Blogger 轉貼頁](https://kbwangtw.blogspot.com/2015/06/windows-server-2012.html)
