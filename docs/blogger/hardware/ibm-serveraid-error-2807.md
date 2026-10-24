---
layout: default
title: "IBM X346 ServeRAID 錯誤碼 2807：換卡後接受新的電池"
date: 2016-12-20
categories: [Hardware, IBM, Server, RAID, Troubleshooting, Blogger 舊文]
permalink: /docs/blogger/hardware/ibm-serveraid-error-2807/
last_modified_at: 2026-10-24
---

# IBM X346 ServeRAID 錯誤碼 2807：換卡後接受新的電池

> **一句話**：X346 當機重開後出現 ServeRAID「error code=2807」，研判是 RAID 卡電池故障；換新卡後控制器發現電池（BBC）序號不同，選 **F4**、再確認**接受新的 BBC**（舊 Cache 內容會被清除）後即可開機。

| 項目 | 內容 |
| --- | --- |
| 適合誰看 | IBM 舊款伺服器 ServeRAID 報錯、更換 RAID 卡或電池的人 |
| 環境 | IBM eServer xSeries 346；ServeRAID-7k（板載）；ServeRAID BIOS 7.12.02 |
| 日期 | 2016-12-20（原文發表於 Blogger，2026-10-24 改寫為新手版） |
| 結論 | ✅ 換卡並接受新電池後開機正常 |

## 1. 先認識幾個名詞

| 名詞 | 白話解釋 |
| --- | --- |
| **ServeRAID** | IBM 伺服器的 RAID 控制器系列 |
| **BBC（Battery Backup Cache）** | 有電池保護的 Cache，斷電時保住還沒寫進硬碟的資料 |
| **Blocked logical drive** | 控制器為了保護資料，暫時鎖住的邏輯磁碟 |
| **Configuration mismatch** | 控制器記錄的設定（例如電池序號）和實際裝的不一樣 |

## 2. 事件經過

```text
當機重開 → ServeRAID：status NOT responding properly - error code=2807
  → 研判 RAID 卡電池故障 → 更換新卡
  → 開機出現 F4／F5 選項 → 依 IBM 工程師建議按 F4
  → 提示電池序號不符 → 接受新的 BBC（舊 Cache 資料會被清掉）→ 開機正常
```

## 3. 步驟一：換卡後的第一個畫面

**看到的訊息**：控制器說有一個或多個邏輯磁碟被鎖住（Blocked），提供兩個選項：

| 按鍵 | 意思 |
| --- | --- |
| **F4** | 嘗試修正問題 |
| F5 | 不做任何變更繼續 |

![ServeRAID-7k 顯示 Blocked logical drives，F4／F5 選項（原作者照片）]({{ '/docs/blogger/hardware/images/ibm-x346-serveraid-7k-f4-f5.jpg' | relative_url }})

**怎麼做**：依 IBM 工程師的指示按 **F4**。

## 4. 步驟二：接受新的 BBC

**看到的訊息**（不論按 F4 或 F5，最後都會出現）：

- 電池備份 Cache 與控制器之間設定不符（Configured 與 Installed 的 BBC 序號不同）
- 警告：BBC 中有尚未寫入硬碟的資料
- 若要救回這些資料，需關機並接回原本的磁碟，或裝回原本的 BBC
- **按 F5 接受新的 BBC**，並放棄 BBC 中的資料

**怎麼做**：按 **F5** 接受新的 BBC。

> 舊卡已經故障、無法裝回，所以只能接受新電池。Cache 裡未寫入的資料會遺失，通常量很少，但開機後要檢查重要資料與資料庫是否完整。

## 5. 步驟三：確認

**應該看到什麼**：伺服器正常進入作業系統；ServeRAID 管理工具中陣列狀態正常、電池狀態正常。

## 6. 常見問題

| 現象 | 怎麼辦 |
| --- | --- |
| 不確定 F4 還是 F5 | 先 F4 嘗試修正；最後的電池確認畫面才是 F5 接受 |
| 擔心 Cache 資料遺失 | 如果舊卡、舊電池還能用，先裝回去讓資料寫入硬碟，再更換 |
| 開機後資料庫異常 | 用資料庫的檢查工具修復，或從備份還原 |

## 7. 延伸閱讀

- [DL380 G7 換 RAID 卡電池改裝 1 GB Cache 後開不了機](../hpe-dl380g7-p410i-cache-upgrade-incident/)
- [Blogger 原文](https://kbwangtw.blogspot.com/2016/12/ibm-serveraid-error-code-2807.html)
