---
layout: default
title: "pfSense 依 IP 限制頻寬（摘要）"
date: 2014-08-14
categories: [Network, pfSense, QoS, Blogger 舊文, 轉貼摘要]
permalink: /docs/blogger/network/pfsense-bandwidth-limit/
last_modified_at: 2026-10-24
---

# pfSense 依 IP 限制頻寬（摘要）

> **一句話**：pfSense 可以用 **Limiter** 為上傳、下載各建一條限速管道，再在 LAN 的防火牆規則中套用，讓每個 IP 的頻寬有上限，避免少數人佔滿線路。

| 項目 | 內容 |
| --- | --- |
| 適合誰看 | 多人共用線路、上傳常被佔滿的人 |
| 性質 | **摘要**：原文為他人撰寫的簡體中文圖文教學、未註明出處，這裡只用自己的話整理概念，原圖不轉載 |
| 日期 | 2014-08-14（原轉貼於 Blogger，2026-10-24 改為摘要） |

## 1. 先認識幾個名詞

| 名詞 | 白話解釋 |
| --- | --- |
| **Limiter** | pfSense 的限速器，設定頻寬上限 |
| **Mask（Source／Destination addresses）** | 讓限速「每個 IP 各自計算」，而不是全部 IP 共用一個上限 |
| **In／Out pipe** | 規則套用時分別指定上傳與下載用哪個 Limiter |

## 2. 概念流程

```text
① Firewall → Traffic Shaper → Limiters
     建立「上傳」Limiter：頻寬上限，Mask 選 Source addresses
     建立「下載」Limiter：頻寬上限，Mask 選 Destination addresses
② Firewall → Rules → LAN：編輯（或新增）放行規則
     Advanced → In／Out pipe 分別選上傳、下載 Limiter
③ 套用後，用測速網站確認每台電腦的速度上限
```

## 3. 原文情境

原作者的環境是一個 LAN、三條 WAN 負載平衡，其中兩條是 ADSL；上傳頻寬較小，有人大量上傳時會影響其他人，所以設定了限速。

## 4. 延伸閱讀

- [pfSense 官方文件：Limiters](https://docs.netgate.com/pfsense/en/latest/trafficshaper/limiters.html)
- [Blogger 轉貼頁](https://kbwangtw.blogspot.com/2014/08/blog-post.html)
