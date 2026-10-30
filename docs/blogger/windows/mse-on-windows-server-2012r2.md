---
layout: default
title: "在 Windows Server 2012 R2 安裝 Microsoft Security Essentials（摘要）"
date: 2016-07-27
categories: [Windows, Security, Blogger 舊文, 轉貼摘要]
permalink: /docs/blogger/windows/mse-on-windows-server-2012r2/
last_modified_at: 2026-10-30
---

# 在 Windows Server 2012 R2 安裝 Microsoft Security Essentials（摘要）

> **一句話**：MSE 官方不支援 Server 版 Windows，原文作者的做法是用相容模式並加上 `/disableoslimit` 參數強制安裝；**MSE 已於 2023 年停止更新，現在請改用 Microsoft Defender**。

| 項目 | 內容 |
| --- | --- |
| 適合誰看 | 參考用；現在不建議照做 |
| 性質 | **轉貼摘要**：原文轉貼自他人部落格（2014-10-22），這裡用自己的話整理重點並附原文連結 |
| 日期 | 2016-07-27（原轉貼於 Blogger，2026-10-24 改為摘要） |

> ⚠️ **不要在正式環境使用**：MSE 沒有病毒碼更新就等於沒有防護。Windows Server 2016 起內建 Microsoft Defender；Windows Server 2012 R2 可透過 Microsoft Defender for Endpoint 的方案取得防護。

## 1. 原文做法重點

```text
下載 mseinstall.exe → 內容 → 相容性：以 Windows 7 相容模式執行
  → 以系統管理員開啟命令提示字元 → 切到檔案所在資料夾
  → 執行 mseinstall /disableoslimit
```

### 步驟

1. 下載 MSE 安裝檔 `mseinstall.exe`。
2. 在檔案上按右鍵 → 內容 → 相容性 → 勾選「以相容模式執行這個程式」，選 **Windows 7** → 確定。
3. 以系統管理員身分開啟命令提示字元，切到安裝檔所在的資料夾，例如：

   ```text
   cd C:\Users\%username%\Downloads
   ```

4. 執行：

   ```text
   mseinstall /disableoslimit
   ```

應該看到什麼：原文表示這樣就能在 Windows Server 2012 R2 上正常安裝。原文沒有提到安裝後更新病毒碼或驗證的步驟。

| 重點 | 說明 |
| --- | --- |
| `/disableoslimit` | 略過作業系統版本檢查的參數 |
| 相容模式選 Windows 7 | 讓安裝程式以為自己在用戶端 Windows 上執行 |
| 最新版裝不起來 | 原文作者遇到新版用這個方法裝不起來，改用舊版 4.6.305.0（分 32／64 位元） |
| 微軟官方立場 | 不支援在 Server 版使用 |

> 原文提供的下載連結是 adf.ly 短網址，不是微軟官方網址，這裡不轉貼。MSE 已停止更新，也不建議再去找舊版安裝檔。

## 2. 延伸閱讀

- [原文（他人撰寫）](http://g-egg.blogspot.tw/2014/10/microsoft-security-essentials-windows.html)
- [Microsoft Learn：Windows Server 上的 Microsoft Defender 防毒](https://learn.microsoft.com/en-us/microsoft-365/security/defender-endpoint/microsoft-defender-antivirus-on-windows-server)
- [Blogger 轉貼頁](https://kbwangtw.blogspot.com/2016/07/microsoft-security-essentials-windows.html)
