---
layout: default
title: "Cisco ACL 插入或調整規則順序（摘要與原文連結）"
date: 2023-08-22
categories: [Network, Cisco, ACL, Blogger 舊文, 轉貼摘要]
permalink: /docs/blogger/network/cisco-acl-sequence/
last_modified_at: 2026-10-30
---

# Cisco ACL 插入或調整規則順序（摘要與原文連結）

> **一句話**：新版 Cisco IOS 的 ACL 每一條規則都有序號，可以用序號把新規則插到中間，也可以重新編號；不用再像以前那樣整份 ACL 刪掉重打。

| 項目 | 內容 |
| --- | --- |
| 適合誰看 | 要在既有 ACL 中間加一條規則的人 |
| 性質 | **轉貼摘要**：原文為他人撰寫，這裡只整理重點；第 3 節指令依 Cisco 官方文件補充（原站已失效） |
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

## 3. 指令與規則（依 Cisco 官方文件整理，非原文內容）

> 原文網站已消失，以下內容整理自 Cisco IOS 15.2E 官方文件〈IP Access List Entry Sequence Numbering〉，不是原文作者寫的。IP 為範例。

### 3-1 預設編號規則

| 規則 | 說明 |
| --- | --- |
| 沒指定序號 | 第一條是 10，之後每條加 10；新增的規則一律放在最後面 |
| 序號上限 | 2147483647；超過會出現 `Exceeded maximum sequence number` |
| 序號重複 | 會出現 `Duplicate sequence number`，不會覆蓋 |
| 重開機後 | 序號**不會存進設定檔**，重開後會從 10 開始、每次加 10 重新編號 |

### 3-2 插入、刪除一條規則

做什麼：在序號 10 和 20 之間插入一條，再把它刪掉。

```text
Switch# configure terminal
Switch(config)# ip access-list standard OFFICE-IN
Switch(config-std-nacl)# 15 permit 192.0.2.5 0.0.0.0
Switch(config-std-nacl)# no 15
Switch(config-std-nacl)# end
```

| 片段 | 意思 |
| --- | --- |
| `ip access-list standard OFFICE-IN` | 進入具名 ACL 設定模式（舊式編號 ACL 也可以把編號當名稱，例如 `ip access-list extended 150`） |
| `15 permit ...` | 指定序號 15，插在 10 和 20 之間 |
| `no 15` | 只刪除序號 15 那一條 |

### 3-3 重新編號

```text
Switch(config)# ip access-list resequence OFFICE-IN 100 15
```

| 片段 | 意思 |
| --- | --- |
| `OFFICE-IN` | 要重新編號的 ACL 名稱 |
| `100` | 第一條改成 100 |
| `15` | 之後每條間隔 15 |

### 3-4 確認結果

```text
Switch# show ip access-lists OFFICE-IN
```

應該看到什麼：每條規則前面都有序號，順序和你預期的一致。

### 3-5 限制

- 不支援 dynamic、reflexive 與 firewall ACL。
- 用舊式 `access-list 1 permit ...` 全域指令建立的編號 ACL，要改用 `ip access-list standard 1` 這種具名模式才能用序號編輯。

## 4. 常見問題

| 現象 | 怎麼辦 |
| --- | --- |
| 重開機後序號變了 | 正常：序號不會存進設定，重開後重新從 10 開始；規則順序不變 |
| 想插入卻沒有空號 | 先 `ip access-list resequence` 把間隔拉開 |
| 出現 `Duplicate sequence number` | 那個序號已經有規則，換一個沒用過的號碼 |

## 5. 延伸閱讀

- [原文（他人撰寫，原網址已失效，改連 Wayback Machine 2021-07-25 封存版）](https://web.archive.org/web/20210725183759/https://blog.90.vc/archives/158)
- [Cisco 官方：IP Access List Entry Sequence Numbering](https://cisco.com/en/US/docs/ios-xml/ios/sec_data_acl/configuration/15-e/sec-acl-seq-num.html)
- [Blogger 轉貼頁](https://kbwangtw.blogspot.com/2023/08/cisco-acl.html)
