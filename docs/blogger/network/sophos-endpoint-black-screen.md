---
layout: default
title: "裝完 Sophos 端點防護後登入黑畫面：元凶是舊版自然輸入法"
date: 2022-01-17
categories: [Security, Sophos, Windows, Troubleshooting, Blogger 舊文]
permalink: /docs/blogger/network/sophos-endpoint-black-screen/
last_modified_at: 2026-10-24
---

# 裝完 Sophos 端點防護後登入黑畫面：元凶是舊版自然輸入法

> **一句話**：Windows 10 裝 Sophos Endpoint 後，使用者登入只剩黑畫面；交叉測試後確認是**舊版自然注音輸入法（V1.00.0000，綠色圖示）**和 Sophos 衝突，移除舊版輸入法就恢復正常。

| 項目 | 內容 |
| --- | --- |
| 適合誰看 | 部署 Sophos 等端點防護後，有電腦登入變黑畫面的人 |
| 環境 | Windows 10（21H2）、Sophos Endpoint、自然注音輸入法 V1.00.0000、Microsoft Teams（含 Teams Machine-Wide Installer） |
| 日期 | 2022-01-17（原文發表於 Blogger，2026-10-24 改寫為新手版） |
| 結論 | ✅ 移除舊版自然輸入法後正常 ⚠️ 不是每台都會發生 |

## 1. 先認識幾個名詞

| 名詞 | 白話解釋 |
| --- | --- |
| **端點防護（Endpoint）** | 裝在每台電腦上的防毒、防勒索軟體 |
| **Ctrl+Alt+Del 畫面** | 有「變更密碼、工作管理員、登出」等選項的安全畫面 |
| **交叉測試** | 一次只改一個變因，找出真正的原因 |
| **Teams Machine-Wide Installer** | Teams 的全機安裝程式，每個使用者登入時會自動安裝 Teams |

## 2. 症狀與排查過程

```text
安裝 Sophos → 重開機 → 登入畫面正常
  → 使用者登入 → 只有黑畫面（沒有桌布、圖示）
  → Ctrl+Alt+Del 的選項按了也沒反應，只能登出

懷疑對象：Sophos ×（自然輸入法舊版／Teams／Teams Machine-Wide Installer）
  → 交叉測試 → 確認是舊版自然輸入法
```

## 3. 處理方式

**最終解法**：到「新增或移除程式」移除**舊版自然注音輸入法**（V1.00.0000，綠色圖示），重開機後登入正常。

**原作者過程中用過的暫時解法**（在確認真正原因之前）：

| 順序 | 做法 |
| --- | --- |
| 1 | 移除 Sophos 和 Teams，重開機 |
| 2 | **先**裝 Sophos，**再**裝 Teams |

> 這個做法當時也能恢復，但根本原因是輸入法，所以建議直接處理輸入法。

## 4. 同一時期的另一個小問題

2021 年 12 月版的 Skype 會閃退：移除後重新安裝新版即可。

## 5. 常見問題

| 現象 | 怎麼辦 |
| --- | --- |
| 黑畫面時什麼都不能按 | 從 Ctrl+Alt+Del 登出，改用系統管理員帳號登入，再移除輸入法 |
| 不確定是哪個軟體 | 一次移除一個再測試；先從輸入法、會議軟體這類常駐程式開始 |
| 使用者還要用自然輸入法 | 改裝新版或改用 Windows 內建注音（未實測新版是否相容） |

## 6. 延伸閱讀

- [Blogger 原文](https://kbwangtw.blogspot.com/2022/01/sophos.html)
