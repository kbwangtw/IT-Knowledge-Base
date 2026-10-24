---
layout: default
title: "HP DL120 G6 加裝光碟機：滑入、鎖後方螺絲、接電源與 SATA"
date: 2011-08-11
categories: [Hardware, HPE, Server, Blogger 舊文]
permalink: /docs/blogger/hardware/hp-dl120g6-optical-drive/
last_modified_at: 2026-10-24
---

# HP DL120 G6 加裝光碟機：滑入、鎖後方螺絲、接電源與 SATA

> **一句話**：光碟機套件裝上架子後直接推進光碟機槽到底，**後方兩顆大螺絲一定要鎖**，電源接 3.5 吋磁碟機用的電源頭，SATA 線接主機板上不容易被碰到的 Port。

| 項目 | 內容 |
| --- | --- |
| 適合誰看 | 第一次幫機架式伺服器加裝光碟機的人 |
| 環境 | HP ProLiant DL120 G6；HP 原廠 DVD-ROM 套件 |
| 日期 | 2011-08-11（原文發表於 Blogger，2026-10-24 改寫為新手版） |
| 結論 | ✅ 光碟機安裝完成 |

> 開始前：伺服器正常關機、拔掉電源線，碰觸金屬機殼釋放靜電。

## 1. 先認識幾個名詞

| 名詞 | 白話解釋 |
| --- | --- |
| **ODD（Optical Disk Drive）** | 光碟機 |
| **光碟機槽（Media bay）** | 機殼前方預留給光碟機的位置 |
| **SATA 排線** | 光碟機的資料線，接到主機板 |
| **4-pin 小電源頭** | 3.5 吋軟碟／磁碟機用的電源接頭，這台的光碟機吃這個 |

## 2. 套件內容

| 零件 | 數量 |
| --- | --- |
| 光碟機 | 1 |
| SATA 排線 | 1 |
| 架子（托架） | 1 |
| 大螺絲 | 2 |
| 小螺絲 | 2 |

## 3. 步驟一：推入光碟機槽

**怎麼做**：光碟機用小螺絲固定在架子上，從前方直接插入光碟機槽，**推到底**。

![光碟機推入光碟機槽（原作者照片）]({{ '/docs/blogger/hardware/images/dl120g6-odd-insert.jpg' | relative_url }})

## 4. 步驟二：鎖上後方的兩顆大螺絲

**怎麼做**：打開上蓋，在光碟機後方找到兩個大螺絲孔，鎖上。

**為什麼**：不鎖的話，按退片鍵時整台光碟機會被推出來。

![光碟機後方的螺絲孔（原作者照片）]({{ '/docs/blogger/hardware/images/dl120g6-odd-rear-screws.jpg' | relative_url }})

## 5. 步驟三：接電源

**怎麼做**：接上電源供應器的 3.5 吋磁碟機電源頭（4-pin 小電源頭）。

![接 3.5 吋磁碟機電源頭（原作者照片）]({{ '/docs/blogger/hardware/images/dl120g6-odd-power.jpg' | relative_url }})

## 6. 步驟四：接 SATA 排線

**怎麼做**：SATA 線一端接光碟機，另一端接主機板上**最不容易被拔到**的 SATA Port（之後通常不會再拔）。

![SATA 排線接在主機板上（原作者照片）]({{ '/docs/blogger/hardware/images/dl120g6-odd-sata.jpg' | relative_url }})

## 7. 步驟五：整理線材並確認

**應該看到什麼**：線材不會卡到風扇；蓋回上蓋開機後，BIOS 開機畫面或作業系統中看得到光碟機。

![安裝完成後的機箱內部（原作者照片）]({{ '/docs/blogger/hardware/images/dl120g6-odd-done.jpg' | relative_url }})

## 8. 常見問題

| 現象 | 怎麼辦 |
| --- | --- |
| 退片時整台光碟機跑出來 | 後方大螺絲沒鎖 |
| 開機看不到光碟機 | 檢查 SATA 與電源是否接牢；BIOS 中該 SATA Port 是否啟用 |
| 線材碰到風扇 | 用束帶固定，避開風扇與散熱片 |

## 9. 延伸閱讀

- [Blogger 原文](https://kbwangtw.blogspot.com/2011/08/hp-dl120g6.html)
