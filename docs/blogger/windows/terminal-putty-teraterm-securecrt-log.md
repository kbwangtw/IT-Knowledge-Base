---
layout: default
title: "PuTTY、Tera Term、SecureCRT 自動存 Log 與改配色"
date: 2021-06-10
categories: [Tools, Terminal, Blogger 舊文]
permalink: /docs/blogger/windows/terminal-putty-teraterm-securecrt-log/
last_modified_at: 2026-10-24
---

# PuTTY、Tera Term、SecureCRT 自動存 Log 與改配色

> **一句話**：三套終端機工具都改「預設值」，讓每次連線自動把畫面存成 Log，檔名帶主機與時間；PuTTY 和 SecureCRT 順便調整字型與配色，看得更清楚。

| 項目 | 內容 |
| --- | --- |
| 適合誰看 | 常用 Console／SSH 維護設備，想留下操作紀錄的人 |
| 環境 | Windows；PuTTY（原文用 PuTTYNG）、Tera Term、SecureCRT |
| 日期 | 2021-06-10（原文發表於 Blogger，2026-10-24 改寫為新手版） |
| 結論 | ✅ 三套工具都會自動存 Log ✅ 配色調整完成 |

> **為什麼要存 Log**：出事時可以回頭看自己下過什麼指令、設備回了什麼；交接給客戶或同事時也有憑有據。

## 1. 先認識幾個名詞

| 名詞 | 白話解釋 |
| --- | --- |
| **Default Settings／Default Session** | 預設值；改這裡，之後新建的連線都會套用 |
| **Log 檔名變數** | 檔名裡的特殊符號，會自動換成主機名稱、日期、時間 |
| **ANSI 顏色** | 終端機畫面上 8 種基本顏色；預設藍色在黑底上很難看清楚 |

## 2. 建議的 Log 資料夾與檔名

```text
C:\Log\
 ├─ putty\       putty_<主機>_<年月日>_<時間>.log
 ├─ teraterm\    teraterm_<主機>_<年月日>_<時分>.log
 └─ SecureCRT\   CRT_<主機>_<年月日>_<時分>.log
```

> 先手動建立這三個資料夾，避免工具找不到路徑。

## 3. 工具一：PuTTY

### 3-1 載入預設值

**怎麼做**：左側 **Session** → 下方選 **Default Settings** → 按 **Load**。

![PuTTY：載入 Default Settings（原作者截圖）]({{ '/docs/blogger/windows/images/putty-load-default.png' | relative_url }})

### 3-2 設定自動存 Log

**怎麼做**：左側 **Logging** → Session logging 選 **All session output** → Log file name 填：

```text
C:\Log\putty\putty_&H_&Y&M&D_&T.log
```

| 變數 | 意思 |
| --- | --- |
| `&H` | 主機名稱或 IP |
| `&Y&M&D` | 年月日 |
| `&T` | 時間 |

![PuTTY：Logging 設定（原作者截圖）]({{ '/docs/blogger/windows/images/putty-logging.png' | relative_url }})

### 3-3 字型與配色

| 設定位置 | 原作者的設定 |
| --- | --- |
| Window → Appearance → Font settings → Change | Consolas，12 |
| Window → Colours → Default Foreground → Modify | 綠色 R:0 G:255 B:0 |
| Window → Colours → ANSI Blue → Modify | R:255 G:0 B:128（黑底上比較看得清楚） |
| Window → Behaviour → Full screen on Alt-Enter | 勾選，Alt+Enter 切換全螢幕 |

### 3-4 存回預設值（不要漏）

**怎麼做**：回到 **Session** → 選 **Default Settings** → 按 **Save**。

![PuTTY：Save 回 Default Settings（原作者截圖）]({{ '/docs/blogger/windows/images/putty-save-default.png' | relative_url }})

## 4. 工具二：Tera Term

**怎麼做**：**Setup** → **Additional settings** → **Log** 頁：

![Tera Term：Setup → Additional settings（原作者截圖）]({{ '/docs/blogger/windows/images/teraterm-additional-settings.png' | relative_url }})

| 欄位 | 設定 |
| --- | --- |
| Default log file name | `teraterm_&h_%Y%m%d_%H%M.log` |
| Default log save folder | `C:\Log\teraterm` |
| Auto start logging | 勾選 |

![Tera Term：Log 頁設定（原作者截圖）]({{ '/docs/blogger/windows/images/teraterm-log.png' | relative_url }})

| 變數 | 意思 |
| --- | --- |
| `&h` | 主機名稱 |
| `%Y%m%d` | 年月日 |
| `%H%M` | 時分 |

按「確定」後，記得 **Setup → Save setup** 存檔，下次開啟才會保留。

## 5. 工具三：SecureCRT

### 5-1 設定 Log

**怎麼做**：**Options** → **Edit Default Session** → **Terminal → Log File**：

| 欄位 | 設定 |
| --- | --- |
| Log file name | `C:\Log\SecureCRT\CRT_%H_%Y%M%D_%h%m.log` |
| Start log upon connect | 勾選 |
| Append to file | 勾選 |

![SecureCRT：Log File 設定（原作者截圖）]({{ '/docs/blogger/windows/images/securecrt-log-file.png' | relative_url }})

| 變數 | 意思 |
| --- | --- |
| `%H` | 主機名稱 |
| `%Y%M%D` | 年月日 |
| `%h%m` | 時分 |

### 5-2 配色

**怎麼做**：**Terminal → Appearance** → Current color scheme 選 **Traditional**，勾選 **Narrow font** → OK。

![SecureCRT：Appearance 配色（原作者截圖）]({{ '/docs/blogger/windows/images/securecrt-appearance.png' | relative_url }})

### 5-3 套用到所有連線

**怎麼做**：出現「Apply default session changes」時選 **Change ALL sessions (no undo)**。

![SecureCRT：套用到所有 Session（原作者截圖）]({{ '/docs/blogger/windows/images/securecrt-apply-all.png' | relative_url }})

> 這個動作**無法復原**，已存的連線設定都會被覆蓋成新預設值。只想套用到新連線就選 Change Default session only。

## 6. 確認

| 檢查 | 應該看到的結果 |
| --- | --- |
| 隨便連一台設備再斷線 | `C:\Log\<工具>\` 出現一個帶主機名稱與時間的 .log 檔 |
| 打開 .log | 內容和畫面一致 |

## 7. 常見問題

| 現象 | 怎麼辦 |
| --- | --- |
| PuTTY 改了設定，下次又不見 | 沒有回 Session 頁對 Default Settings 按 Save |
| 沒有產生 Log 檔 | 資料夾不存在；先手動建立 |
| Log 裡有密碼 | PuTTY 的「Omit known password fields」要勾；其他工具注意不要在畫面上明碼輸入敏感資料 |
| Log 越來越多 | 定期壓縮或刪除舊檔；Log 也可能含敏感設定，存放位置要有權限控管 |

## 8. 延伸閱讀

- [Blogger 原文](https://kbwangtw.blogspot.com/2021/06/terminal-log.html)
