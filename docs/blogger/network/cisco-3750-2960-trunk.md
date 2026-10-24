---
layout: default
title: "Cisco 3750 與 2960 之間設定 Trunk"
date: 2018-07-20
categories: [Network, Cisco, VLAN, Blogger 舊文]
permalink: /docs/blogger/network/cisco-3750-2960-trunk/
last_modified_at: 2026-10-24
---

# Cisco 3750 與 2960 之間設定 Trunk

> **一句話**：兩台交換器之間要跑多個 VLAN，就把對接的 Port 兩端都設成 Trunk；3750 要多一行指定 `dot1q` 封裝，2960 只支援 dot1q 所以不用。

| 項目 | 內容 |
| --- | --- |
| 適合誰看 | 核心交換器往下接樓層交換器、要讓多個 VLAN 一起過去的人 |
| 環境 | Cisco 3750（核心）Port Fa1/0/48 ↔ Cisco 2960（樓層）Port Gi0/48 |
| 日期 | 2018-07-20（原文發表於 Blogger，2026-10-24 改寫為新手版） |
| 結論 | ✅ 兩端 Trunk 建立，VLAN 可跨交換器使用 |

## 1. 先認識幾個名詞

| 名詞 | 白話解釋 |
| --- | --- |
| **Trunk** | 一條線同時跑多個 VLAN，封包會加上 VLAN 標籤 |
| **802.1Q（dot1q）** | 目前通用的 VLAN 標籤標準 |
| **ISL** | Cisco 早期自家的標籤格式，已淘汰；3750 兩種都支援，所以要明確指定 dot1q |

## 2. 接線圖

```text
Cisco 3750  Fa1/0/48 ════ Trunk（dot1q）════ Gi0/48  Cisco 2960
```

## 3. 步驟一：3750 端

```text
interface FastEthernet1/0/48
 switchport trunk encapsulation dot1q
 switchport mode trunk
```

| 片段 | 意思 |
| --- | --- |
| `switchport trunk encapsulation dot1q` | 指定用 802.1Q 標籤；**要先下這行**，3750 才接受設成 trunk |
| `switchport mode trunk` | 固定成 Trunk，不自動協商 |

## 4. 步驟二：2960 端

```text
interface GigabitEthernet0/48
 switchport mode trunk
```

> 2960 只支援 dot1q，所以沒有 `encapsulation` 這個指令，下了反而會報錯。

## 5. 步驟三：確認

```text
show interfaces trunk
```

**應該看到什麼**：兩端都列出這個 Port，`Mode` 是 `on`、`Encapsulation` 是 `802.1q`、`Status` 是 `trunking`，下面列出允許通過的 VLAN。

## 6. 常見問題

| 現象 | 怎麼辦 |
| --- | --- |
| 3750 下 `switchport mode trunk` 報錯 | 先下 `switchport trunk encapsulation dot1q` |
| 2960 找不到 `encapsulation` 指令 | 正常，2960 不需要 |
| 某個 VLAN 過不去 | 兩台都要建立該 VLAN；`show interfaces trunk` 檢查 allowed 清單 |
| 出現 native VLAN mismatch 訊息 | 兩端的 native VLAN 要一致（預設都是 1） |

## 7. 延伸閱讀

- [Cisco Port Channel：兩條線綁成一條 Trunk](../cisco-port-channel/)
- [Blogger 原文](https://kbwangtw.blogspot.com/2018/07/cisco-3750-trunk-port.html)
