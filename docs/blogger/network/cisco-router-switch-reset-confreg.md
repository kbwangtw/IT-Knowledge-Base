---
layout: default
title: "Cisco Router／Switch 用 confreg 0x2142 回復原廠（摘要）"
date: 2014-05-02
categories: [Network, Cisco, Troubleshooting, Blogger 舊文, 轉貼摘要]
permalink: /docs/blogger/network/cisco-router-switch-reset-confreg/
last_modified_at: 2026-10-24
---

# Cisco Router／Switch 用 confreg 0x2142 回復原廠（摘要）

> **一句話**：開機時按 Ctrl+Break 進 ROMMON，把 configuration register 改成 `0x2142` 讓設備略過舊設定開機，進去後改回 `0x2102` 並 `write erase`，重開就是出廠狀態。

| 項目 | 內容 |
| --- | --- |
| 適合誰看 | 忘記密碼、要把 Cisco 路由器清回出廠的人 |
| 性質 | **轉貼摘要**：原文引用自他人文章（短網址已失效），這裡用自己的話整理流程 |
| 日期 | 2014-05-02（原轉貼於 Blogger，2026-10-24 改為摘要） |

## 1. 先認識幾個名詞

| 名詞 | 白話解釋 |
| --- | --- |
| **ROMMON** | 路由器的開機救援模式（提示字元 `rommon>`） |
| **Configuration register（confreg）** | 決定開機行為的數值 |
| **`0x2142`** | 開機時**略過**開機設定 |
| **`0x2102`** | 正常值：開機時讀取開機設定 |

## 2. 流程

```text
Console 連線 → 開機時按 Ctrl+Break → rommon>
  → confreg 0x2142 → reset（重開，略過舊設定）
  → 設定精靈回答 no → enable → conf t
  → config-register 0x2102（一定要改回來）→ exit
  → write erase → reload
```

| 關鍵步驟 | 為什麼重要 |
| --- | --- |
| 改回 `0x2102` | 忘了改，之後每次開機都會略過設定，看起來像設定一直不見 |
| `write erase` | 真正把舊設定清掉 |

> 這個做法主要用在 **Cisco 路由器**；Catalyst 交換器多半是用 Mode 鍵，請看〈Cisco 3750X／3850 等交換器恢復原廠設定〉。

## 3. 延伸閱讀

- [Cisco 3750X／3850 等交換器恢復原廠設定](../cisco-switch-factory-reset/)
- [Blogger 轉貼頁](https://kbwangtw.blogspot.com/2014/05/cisco-router-switch.html)
