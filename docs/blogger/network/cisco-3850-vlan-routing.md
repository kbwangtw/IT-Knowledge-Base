---
layout: default
title: "Cisco 3850 新增 VLAN、分配 Port、讓兩個網段互通"
date: 2015-10-07
categories: [Network, Cisco, VLAN, Blogger 舊文]
permalink: /docs/blogger/network/cisco-3850-vlan-routing/
last_modified_at: 2026-10-24
---

# Cisco 3850 新增 VLAN、分配 Port、讓兩個網段互通

> **一句話**：在 3850 上新增 VLAN 2 給伺服器用、把 Port 11～24 劃進去，兩個 VLAN 介面各設一個閘道 IP，最後打開 `ip routing`，兩個網段就能透過交換器互通。

| 項目 | 內容 |
| --- | --- |
| 適合誰看 | 第一次在 Cisco L3 交換器上切 VLAN、想讓不同網段互通的人 |
| 環境 | Cisco Catalyst 3850（L3 交換器） |
| 日期 | 2015-10-07（原文發表於 Blogger，2026-10-24 改寫為新手版） |
| 結論 | ✅ VLAN 1、VLAN 2 各自有 Port 和閘道 IP ✅ 開啟 `ip routing` 後兩段互通 |

## 1. 先認識幾個名詞

| 名詞 | 白話解釋 |
| --- | --- |
| **VLAN** | 在一台交換器上切出好幾個互不相通的網段 |
| **VLAN 1** | 出廠預設的 VLAN，所有 Port 一開始都在這裡 |
| **Access Port** | 只屬於一個 VLAN 的 Port，接電腦、伺服器用 |
| **VLAN 介面（SVI，`interface vlan X`）** | 交換器在某個 VLAN 裡的「虛擬網卡」，設上 IP 就成為該網段的閘道 |
| **`ip routing`** | 讓 L3 交換器在 VLAN 之間轉送封包，沒開的話各 VLAN 仍然不通 |
| **`interface range`** | 一次設定一整段 Port，不用一個一個打 |

## 2. 要做到的架構

```text
                     Cisco 3850（ip routing）
           ┌──────────────────┴──────────────────┐
     VLAN 1（預設）                         VLAN 2「Server」
     閘道 192.0.2.54/24                     閘道 198.51.100.1/24
     Port 1～10、光纖 Port 1～4              Port 11～24
```

> 原文的網段是內網位址，這裡改用示範位址；套用時換成你自己的網段。

## 3. 步驟一：建立 VLAN 2

```text
Switch> enable
Switch# configure terminal
Switch(config)# vlan 2
Switch(config-vlan)# name Server
Switch(config-vlan)# exit
```

## 4. 步驟二：把 Port 11～24 劃進 VLAN 2，並設閘道 IP

```text
Switch(config)# interface range GigabitEthernet1/0/11-24
Switch(config-if-range)# switchport mode access
Switch(config-if-range)# switchport access vlan 2
Switch(config-if-range)# exit
Switch(config)# interface vlan 2
Switch(config-if)# ip address 198.51.100.1 255.255.255.0
Switch(config-if)# exit
```

| 片段 | 意思 |
| --- | --- |
| `GigabitEthernet1/0/11-24` | 第 1 台交換器、第 0 號模組、Port 11 到 24 |
| `switchport mode access` | 這些 Port 只屬於一個 VLAN |
| `switchport access vlan 2` | 指定那個 VLAN 是 2 |
| `interface vlan 2` + `ip address` | 給 VLAN 2 一個閘道位址，伺服器的預設閘道就設這個 |

## 5. 步驟三：確認 VLAN 1 的 Port 與閘道 IP

```text
Switch(config)# interface range GigabitEthernet1/0/1-10
Switch(config-if-range)# switchport mode access
Switch(config-if-range)# switchport access vlan 1
Switch(config-if-range)# exit
Switch(config)# interface range GigabitEthernet1/1/1-4
Switch(config-if-range)# switchport mode access
Switch(config-if-range)# switchport access vlan 1
Switch(config-if-range)# exit
Switch(config)# interface vlan 1
Switch(config-if)# ip address 192.0.2.54 255.255.255.0
Switch(config-if)# exit
```

| 片段 | 意思 |
| --- | --- |
| `GigabitEthernet1/1/1-4` | 第 1 號模組，也就是上行的光纖 Port 1～4 |

## 6. 步驟四：開啟路由，讓兩段互通

```text
Switch(config)# ip routing
Switch(config)# end
Switch# write memory
```

**應該看到什麼**：

| 檢查 | 結果 |
| --- | --- |
| `show vlan brief` | VLAN 2「Server」底下列出 Gi1/0/11～24 |
| `show ip interface brief` | Vlan1、Vlan2 都是 `up/up`，IP 正確 |
| VLAN 1 的電腦 ping VLAN 2 的伺服器 | 通（兩邊的預設閘道要設成各自的 VLAN 介面 IP） |

## 7. 常見問題

| 現象 | 怎麼辦 |
| --- | --- |
| 指令被拒絕，像 `interfacr` | 打錯字；Cisco 可以縮寫，但不能拼錯（原文就有這個筆誤） |
| 兩個 VLAN 還是不通 | 確認有 `ip routing`；電腦的預設閘道是否設成 VLAN 介面 IP |
| `interface vlan 2` 顯示 down | 該 VLAN 裡至少要有一個 Port 是 up 的 |
| 重開機後設定不見 | 沒做 `write memory` |

## 8. 延伸閱讀

- [Cisco VLAN ACL：讓 VLAN 20、30 互不相通](../cisco-vlan-acl/)
- [Blogger 原文](https://kbwangtw.blogspot.com/2015/10/cisco-3850-vlan.html)
