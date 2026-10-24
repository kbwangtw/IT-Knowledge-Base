---
layout: default
title: "APC Smart-UPS 換新電池後 Battery 燈還在閃：用序列埠重設電池參數"
date: 2023-08-23
categories: [Hardware, UPS, APC, Blogger 舊文]
permalink: /docs/blogger/hardware/apc-smart-ups-battery-reset/
last_modified_at: 2026-10-24
---

# APC Smart-UPS 換新電池後 Battery 燈還在閃：用序列埠重設電池參數

> **一句話**：用 APC 專用的序列線接電腦，以終端機軟體進入 UPS 的 Smart 模式，把電池常數改回機型對應的正確值；看到 `BYE` 就完成，Battery 燈不再閃。

| 項目 | 內容 |
| --- | --- |
| 適合誰看 | 換過電池，但 UPS 還是亮 Battery 燈、一直顯示放電（Discharge）的人 |
| 環境 | APC Smart-UPS SUA1000／SUA1500／SUA2000／SU3000NET 等；一台有 COM Port 的電腦 |
| 日期 | 2023-08-23（原文發表於 Blogger，2026-10-24 改寫為新手版） |
| 結論 | ✅ 重設後 Battery 燈不再閃，UPS 恢復正常充電 |

> ⚠️ 這是 APC 的維修模式，改錯值可能讓 UPS 判斷電量錯誤。先準備好機型對照表（第 7 節），**只改電池常數**，其他不要動。

## 1. 先認識幾個名詞

| 名詞 | 白話解釋 |
| --- | --- |
| **Serial Port／COM Port** | 電腦上的 9 針序列埠；新電腦多半沒有，要用 USB 轉 Serial 轉接線 |
| **終端機軟體** | 用文字跟設備溝通的程式，例如 Tera Term、PuTTY；舊版 Windows 有內建「超級終端機」 |
| **Smart 模式** | UPS 接受單一字元指令的維修模式，進入後會回應 `SM` |
| **電池常數** | UPS 用來估算電池狀態的設定值，換電池或判斷錯誤時要重設 |
| **Baud rate（傳輸速率）** | 序列通訊的速度，兩端要一致，這裡是 2400 |

## 2. 整體流程

```text
準備：正確的序列線 → 拔 USB 線 → 關掉佔用 COM Port 的 PowerChute
  │
  ▼
連線：終端機設 2400 / 8 / N / 1 → 按 Shift+Y 出現 SM
  │
  ▼
檢查：P（負載%）、f（電量%）
  │
  ▼
重設：1 按兩次（PROG）→ 0 看目前值 → 用 + / - 調成對照表的值 → Shift+R 出現 BYE
```

## 3. 步驟一：準備正確的序列線

**做什麼**：確認你手上的線是 UPS 能用的那一條。

| 線材 | 能不能用 |
| --- | --- |
| UPS 隨機附的**黑色**序列線（接頭編號 940-0024 系列） | ✅ 可以 |
| 多機／網路版 PowerChute Business Edition 附的**灰色**線（940-0023 系列） | ❌ 不行 |
| 一般市售的標準序列線 | ❌ 腳位不相容 |
| 新款 UPS：RJ-45 轉 Serial 的 APC 線 | ✅ 可以 |

![APC UPS 序列線（RJ-45 轉 DB9）]({{ '/docs/blogger/hardware/images/apc-ups-serial-cable.jpg' | relative_url }})

## 4. 步驟二：把 COM Port 讓出來

**做什麼**：確保沒有別的東西搶 UPS 的通訊。

| 檢查 | 為什麼 |
| --- | --- |
| 拔掉 UPS 的 **USB 線** | UPS 的 USB 和序列埠不能同時用，有 USB 時會優先走 USB |
| BIOS 裡 Serial Port 是 **Enable** | 關掉的話系統看不到 COM Port |
| 關閉 PowerChute 程式（工作管理員結束） | 它會佔住 COM Port |
| 有裝 PowerChute Business Edition 就先**解除安裝** | 它常駐佔用 COM Port，不移除連不上 |

## 5. 步驟三：設定終端機並進入 Smart 模式

**怎麼做**：Windows Vista 之後沒有超級終端機，下載 [Tera Term](https://teratermproject.github.io/) 執行 `ttermpro.exe`。

1. 新連線選 **Serial**，選正確的 COM Port。
2. **Setup → Serial port** 設定：

| 項目 | 值 |
| --- | --- |
| Baud rate | **2400** |
| Data | 8 |
| Parity | none |
| Stop | 1 |
| Flow control | Xon/Xoff 或 none |

3. 在畫面按 **Shift + Y**（大寫 Y）。

**應該看到什麼**：畫面回 `SM`，代表已進入 Smart 模式。沒有出現就回步驟二檢查。

## 6. 步驟四：先看目前狀態（只讀取）

| 輸入 | UPS 回應 |
| --- | --- |
| `P` | 目前負載百分比 |
| `f` | 電池電量百分比 |

> 這兩個指令只讀取、不會改設定，可以安心先試。

## 7. 步驟五：重設電池常數

**做什麼**：把電池常數改成你這台機型的正確值。

**怎麼做**：

| 順序 | 輸入 | 意思／應該看到什麼 |
| --- | --- | --- |
| 1 | `1` 按兩次（中間間隔一下） | 進入程式設定，出現 `PROG` |
| 2 | `0` | 顯示目前的電池常數；狀況不好的 UPS 通常落在 `0x`～`2x` |
| 3 | `+` 或 `-` | 一格一格調整數值，直到符合對照表 |
| 4 | **Shift + R**（大寫 R） | 存檔並離開，出現 `BYE` 就完成 |

**要調成多少**：依機型查對照表**最後一欄**（例如表中 SUA1500 是 `8B`）。原文的步驟以 `8C` 當例子，**實際請以你的機型在表上的值為準**。

![APC Smart-UPS 各機型參數對照表（原作者紙本筆記，含手寫備註）]({{ '/docs/blogger/hardware/images/apc-ups-model-parameters.jpg' | relative_url }})

> 表格下方的手寫備註是原作者的現場筆記，含意**未確認**，不要照著輸入。

## 8. 步驟六：確認與電池測試

| 檢查 | 應該看到的結果 |
| --- | --- |
| UPS 面板 | Battery 燈不再閃；電池若沒飽，會開始正常充電 |
| （選做）電池充飽並放置冷卻後，再進 Smart 模式輸入 `D` | UPS 執行電池自我測試 |

完成後直接關閉終端機，接回 USB 線、重新開啟 PowerChute。

## 9. 常見問題

| 現象 | 怎麼辦 |
| --- | --- |
| 按 Shift+Y 沒有 `SM` | 線材不對（看第 3 節）、USB 線沒拔、COM Port 被 PowerChute 佔用、Baud rate 不是 2400 |
| 終端機說 COM Port 無法開啟 | 有程式佔用：結束 PowerChute 或解除安裝 Business Edition |
| 調好之後燈還是閃 | 電池本身可能真的老化，先充飽再用 `D` 測試；新電池仍失敗就聯絡原廠 |
| 對照表找不到我的機型 | 不要自己猜；查 APC 官方技術文件或洽原廠 |

## 10. 待辦

- [ ] 補上 Tera Term 連線設定截圖

## 11. 延伸閱讀

- [Tera Term 官方網站](https://teratermproject.github.io/)
- [Blogger 原文](https://kbwangtw.blogspot.com/2023/08/apc-ups-discharge-battery-led.html)
