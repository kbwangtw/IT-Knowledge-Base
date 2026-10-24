---
layout: default
title: "Cisco ACL 插入或調整規則順序（摘要與原文連結）"
date: 2023-08-22
categories: [Network, Cisco, ACL, Blogger 舊文, 轉貼摘要]
permalink: /docs/blogger/network/cisco-acl-sequence/
last_modified_at: 2026-10-24
---

# Cisco ACL 插入或調整規則順序（摘要與原文連結）

> **一句話**：新版 Cisco IOS 的 ACL 每一條規則都有序號，可以用序號把新規則插到中間，也可以重新編號；不用再像以前那樣整份 ACL 刪掉重打。

| 項目 | 內容 |
| --- | --- |
| 適合誰看 | 要在既有 ACL 中間加一條規則的人 |
| 性質 | **轉貼摘要**：原文為他人撰寫，這裡只整理重點，詳細內容請看原文 |
| 日期 | 2023-08-22（原轉貼於 Blogger，2026-10-24 改為摘要） |

## 1. 先認識幾個名詞

| 名詞 | 白話解釋 |
| --- | --- |
| **ACL（Access Control List）** | 存取控制清單：一條一條規則，決定哪些封包可以通過 |
| **序號（Sequence number）** | 每條規則前面的編號，ACL 依序號由小到大比對，比中就停 |
| **重新編號（resequence）** | 把規則序號重新排成固定間隔，留出插入空間 |

## 2. 重點整理

```text
舊做法：整份 ACL 複製到記事本 → 修改 → 刪掉舊 ACL → 貼回新的（中間會有空窗）
新做法：直接用序號插入、刪除單條規則
```

- 進入具名 ACL 設定模式後，在規則前面加上序號，就能插到指定位置（例如序號 10 和 20 之間用 15）。
- 用 `no <序號>` 可以只刪除那一條。
- 序號間隔不夠用時，可以用 `ip access-list resequence` 把序號重新排開。
- 原文也提醒：不是每次修改都要重新編號，有需要時再做即可。

> 為什麼順序重要：ACL 比中第一條就停止，太寬鬆的規則放在前面，後面較嚴格的規則就永遠用不到。

## 3. 延伸閱讀

- [原文（他人撰寫）](https://blog.90.vc/archives/158)
- [Cisco 官方：IP Access List Entry Sequence Numbering](https://cisco.com/en/US/docs/ios-xml/ios/sec_data_acl/configuration/15-e/sec-acl-seq-num.html)
- [Blogger 轉貼頁](https://kbwangtw.blogspot.com/2023/08/cisco-acl.html)
