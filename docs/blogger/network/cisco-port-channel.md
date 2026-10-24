---
layout: default
title: "Cisco Port Channel：兩條線綁成一條 Trunk，頻寬加倍又能容錯"
date: 2018-07-26
categories: [Network, Cisco, LACP, Blogger 舊文]
permalink: /docs/blogger/network/cisco-port-channel/
last_modified_at: 2026-10-24
---

# Cisco Port Channel：兩條線綁成一條 Trunk，頻寬加倍又能容錯

> **一句話**：把 Port 47、48 用 LACP 綁成 Port-channel 1 並設成 Trunk，對接伺服器的 NIC Team 或下層交換器；一條線斷了，另一條照常運作。

| 項目 | 內容 |
| --- | --- |
| 適合誰看 | 要讓伺服器雙網卡或樓層交換器上行有備援、多頻寬的人 |
| 環境 | Cisco Catalyst（L3 核心），Fa1/0/47、Fa1/0/48 |
| 日期 | 2018-07-26（原文發表於 Blogger，2026-10-24 改寫為新手版） |
| 結論 | ✅ Port-channel 1 建立，承載多個 VLAN |

## 1. 先認識幾個名詞

| 名詞 | 白話解釋 |
| --- | --- |
| **Port Channel（EtherChannel）** | 多條實體線路當成一條邏輯線路使用 |
| **LACP** | 兩端自動協商綁定的標準協定（802.3ad） |
| **active／passive** | LACP 模式：active 會主動發協商封包；passive 只回應。兩端**至少一端要 active** |
| **NIC Team** | 伺服器端把多張網卡綁在一起，對應交換器的 Port Channel |
| **Edge Switch** | 接使用者電腦的樓層交換器 |

## 2. 架構

```text
核心交換器                                     Edge Switch／伺服器
Fa1/0/47 ─┐                                ┌─ Port A
          ├─ Port-channel 1（Trunk）═══════┤
Fa1/0/48 ─┘                                └─ Port B
```

## 3. 步驟一：建立邏輯介面 Port-channel 1

```text
interface Port-channel1
 switchport trunk encapsulation dot1q
 switchport mode trunk
```

> 因為要承載多個 VLAN，所以設成 Trunk。只跑一個 VLAN 的話改成 `switchport mode access` 和 `switchport access vlan <ID>`。

## 4. 步驟二：把實體 Port 加入群組

```text
interface range FastEthernet1/0/47 - 48
 channel-group 1 mode passive
 switchport trunk encapsulation dot1q
 switchport mode trunk
```

| 片段 | 意思 |
| --- | --- |
| `interface range FastEthernet1/0/47 - 48` | 同時設定 47、48 兩個 Port |
| `channel-group 1` | 加入編號 1 的群組，對應 `Port-channel1` |
| `mode passive` | LACP 被動模式，等對方發起協商；**對端要設 active** |
| 實體 Port 也設 trunk | 實體 Port 和 Port-channel 的設定要一致，否則無法綁定 |

## 5. 步驟三：確認

```text
show etherchannel summary
```

**應該看到什麼**：`Po1(SU)` 後面列出 `Fa1/0/47(P)`、`Fa1/0/48(P)`。

| 代號 | 意思 |
| --- | --- |
| `S`／`U` | Layer 2／使用中 |
| `P` | 已成功綁進群組 |
| `s` 或 `I` | 掛起或獨立，表示沒綁成功 |

## 6. 常見問題

| 現象 | 怎麼辦 |
| --- | --- |
| 兩條線都沒綁成功 | 兩端都設 passive 就不會協商，至少一端改 active |
| 只有一個 Port 是 `P` | 檢查兩個 Port 的速度、雙工、VLAN 設定是否完全一致 |
| 伺服器端網路時通時斷 | NIC Team 模式要用 LACP（802.3ad），不能用一般的負載平衡模式 |

## 7. 延伸閱讀

- [Cisco 3750 與 2960 之間設定 Trunk](../cisco-3750-2960-trunk/)
- [Blogger 原文](https://kbwangtw.blogspot.com/2018/07/cisco-port-channel.html)
