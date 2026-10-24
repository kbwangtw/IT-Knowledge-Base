---
layout: default
title: "Cisco VLAN ACL：讓 VLAN 20、30 互不相通，但都能連 VLAN 10"
date: 2018-07-20
categories: [Network, Cisco, ACL, VLAN, Blogger 舊文]
permalink: /docs/blogger/network/cisco-vlan-acl/
last_modified_at: 2026-10-24
---

# Cisco VLAN ACL：讓 VLAN 20、30 互不相通，但都能連 VLAN 10

> **一句話**：L3 交換器開了 `ip routing` 後所有 VLAN 都互通；要擋掉 VLAN 20 ↔ 30，可以用 **VLAN Access-Map（方法一）** 或在 **VLAN 介面套 ACL（方法二）**，兩種都有效，差別在被擋時對方看到的回應。

| 項目 | 內容 |
| --- | --- |
| 適合誰看 | 想讓某些部門網段互相隔離，但共用伺服器網段的人 |
| 環境 | Cisco Catalyst L3 交換器，已啟用 `ip routing` |
| 日期 | 2018-07-20（原文發表於 Blogger，2026-10-24 改寫為新手版） |
| 結論 | ✅ 兩種方法都能擋住 VLAN 20 ↔ 30 ✅ VLAN 10 仍與所有網段互通 |

## 1. 先認識幾個名詞

| 名詞 | 白話解釋 |
| --- | --- |
| **ACL（Access Control List）** | 一條條「允許／拒絕」規則，由上往下比對 |
| **萬用遮罩（Wildcard mask）** | ACL 用的遮罩，和子網路遮罩相反：`0.0.0.255` 表示最後一段任意 |
| **VLAN Access-Map（VACL）** | 套在整個 VLAN 上的過濾，VLAN 內、外的流量都會檢查 |
| **`ip access-group ... in`** | 把 ACL 套在介面上，`in` 表示檢查「進入這個介面」的封包 |
| **`permit ip any any`** | 其他全部放行；ACL 最後有一條看不見的「全部拒絕」，不加這行其他流量也會被擋 |

## 2. 環境與目標

```text
               L3 交換器（ip routing）
      ┌───────────────┼───────────────┐
   VLAN 10         VLAN 20         VLAN 30
 192.0.2.254     198.51.100.254   203.0.113.254
 （共用伺服器）     （部門 A）        （部門 B）

目標：10 ↔ 20 ✅   10 ↔ 30 ✅   20 ↔ 30 ❌
```

> 原文的網段是內網位址，這裡改用三組示範位址。

VLAN 介面設定（兩種方法共用）：

```text
interface Vlan10
 ip address 192.0.2.254 255.255.255.0
interface Vlan20
 ip address 198.51.100.254 255.255.255.0
interface Vlan30
 ip address 203.0.113.254 255.255.255.0
```

## 3. 先寫好 ACL（兩種方法共用）

```text
access-list 103 deny   ip 198.51.100.0 0.0.0.255 203.0.113.0 0.0.0.255
access-list 103 permit ip any any
access-list 104 deny   ip 203.0.113.0 0.0.0.255 198.51.100.0 0.0.0.255
access-list 104 permit ip any any
```

| 片段 | 意思 |
| --- | --- |
| `103`、`104` | ACL 編號；100～199 是延伸 ACL，可以同時比對來源和目的 |
| `deny ip <來源> <遮罩> <目的> <遮罩>` | 從 VLAN 20 去 VLAN 30 的封包拒絕（104 則相反） |
| `permit ip any any` | 其他都放行，所以 VLAN 10 不受影響 |

## 4. 方法一：VLAN Access-Map

```text
vlan access-map vlan20 10
 match ip address 103
 action forward
vlan access-map vlan30 10
 match ip address 104
 action forward
vlan filter vlan20 vlan-list 20
vlan filter vlan30 vlan-list 30
```

| 片段 | 意思 |
| --- | --- |
| `vlan access-map vlan20 10` | 建一個叫 `vlan20` 的過濾表，第 10 條規則 |
| `match ip address 103` | 用 ACL 103 來判斷 |
| `action forward` | 符合 ACL `permit` 的就轉送；被 `deny` 的會被丟掉 |
| `vlan filter vlan20 vlan-list 20` | 把這個過濾表套到 VLAN 20 |

**看到的結果**：VLAN 20 的電腦 ping VLAN 30，**沒有任何回應**，只看到逾時：

```text
Request timeout for icmp_seq 0
Request timeout for icmp_seq 1
```

## 5. 方法二：在 VLAN 介面套 ACL

```text
interface vlan 20
 ip access-group 103 in
interface vlan 30
 ip access-group 104 in
```

**看到的結果**：除了逾時，交換器還會**回一個「被過濾器禁止」的訊息**：

```text
Request timeout for icmp_seq 13
36 bytes from 198.51.100.254: Communication prohibited by filter
```

## 6. 兩種方法怎麼選

| | 方法一：VLAN Access-Map | 方法二：介面 ACL |
| --- | --- | --- |
| 檢查範圍 | 整個 VLAN（包含同 VLAN 內） | 只有經過路由（跨 VLAN）的流量 |
| 被擋時對方看到 | 只有逾時，像主機不存在 | 收到「prohibited by filter」 |
| 排錯 | 較難，看不出是被擋 | 容易，一看就知道是 ACL |
| 適合 | 不想讓對方知道有過濾 | 一般內部隔離、方便維護 |

## 7. 常見問題

| 現象 | 怎麼辦 |
| --- | --- |
| 套了之後整個 VLAN 都斷了 | ACL 少了最後的 `permit ip any any` |
| 20 → 30 擋住了，30 → 20 還通 | 單向只擋一邊；兩個 VLAN 各要套一個方向的 ACL |
| 不確定有沒有比中 | `show access-lists` 看每條規則後面的 matches 計數 |

## 8. 延伸閱讀

- [Cisco 3850 新增 VLAN 並讓網段互通](../cisco-3850-vlan-routing/)
- [Cisco ACL 插入或調整規則順序](../cisco-acl-sequence/)
- [Blogger 原文](https://kbwangtw.blogspot.com/2018/07/cisco-vlan-acl.html)
