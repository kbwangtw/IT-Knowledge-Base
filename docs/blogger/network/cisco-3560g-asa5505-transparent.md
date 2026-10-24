---
layout: default
title: "Cisco 3560G 當路由、ASA 5505 用透通模式管控上網"
date: 2015-02-05
categories: [Network, Cisco, ASA, Firewall, Blogger 舊文]
permalink: /docs/blogger/network/cisco-3560g-asa5505-transparent/
last_modified_at: 2026-10-24
---

# Cisco 3560G 當路由、ASA 5505 用透通模式管控上網

> **一句話**：ISP 只給一個對外 IP，路由交給 3560G 做；ASA 5505 設成**透通模式（transparent）**夾在中間，不做 NAT、不佔 IP，只負責過濾內部電腦的上網流量，管理用另一組私有網段。

| 項目 | 內容 |
| --- | --- |
| 適合誰看 | 想在既有網路中「無痛」加一台防火牆，不想改 IP 架構的人 |
| 環境 | Cisco Catalyst 3560G（L3）、Cisco ASA 5505；內部 3 個 /24 網段；ISP 給 1 個對外 IP |
| 日期 | 2015-02-05（原文發表於 Blogger，2026-10-24 改寫為新手版） |
| 結論 | ✅ 內部三個網段閘道互通 ✅ 可連到 3560G WAN 介面與 ASA 管理 IP |

## 1. 先認識幾個名詞

| 名詞 | 白話解釋 |
| --- | --- |
| **透通模式（Transparent Firewall）** | 防火牆像一條「會檢查封包的網路線」，不當路由器、不改 IP，前後設備感覺不到它存在 |
| **路由模式（Routed）** | ASA 的預設模式，自己當閘道、通常也做 NAT |
| **bridge-group** | 把 inside、outside 綁成同一個橋接群組，透通模式的核心 |
| **BVI（Bridge Virtual Interface）** | 橋接群組的管理 IP |
| **nameif／security level** | 介面名稱與信任等級；inside 預設 100（最信任）、outside 預設 0 |
| **secondary IP** | 同一個 VLAN 介面上的第二組 IP |

## 2. 架構

```text
ISP 路由器（<ISP 閘道>）
        │
   ASA 5505（透通模式，管理 IP 在 <管理網段>.253）
     Eth0/0 = outside（VLAN 2）   Eth0/1 = inside（VLAN 1）
        │
   3560G Port 48（VLAN 2「wan」）
     主要 IP：<ISP 給的 IP>        次要 IP：<管理網段>.254（和 ASA 同網段，方便管理）
        │  ip routing
   VLAN 1：三個內部網段的閘道
     192.0.2.254 ／ 198.51.100.254 ／ 203.0.113.254
```

> 原文作者已把客戶的真實 IP 換成虛擬 IP；這裡再改成示範位址與代稱，套用時換成你的環境。

| 代稱 | 意思 |
| --- | --- |
| `<ISP 給的 IP>`、`<ISP 閘道>` | ISP 提供的對外 IP 與預設閘道 |
| `<管理網段>` | 另外規劃、只用來管理 ASA 的私有網段（原文用一組 /24） |

## 3. 步驟一：ASA 改成透通模式並綁定介面

```text
ciscoasa# configure terminal
ciscoasa(config)# firewall transparent
ciscoasa(config)# interface Ethernet0/0
ciscoasa(config-if)# switchport access vlan 2
ciscoasa(config-if)# no shutdown
ciscoasa(config-if)# interface Ethernet0/1
ciscoasa(config-if)# switchport access vlan 1
ciscoasa(config-if)# no shutdown
ciscoasa(config-if)# interface vlan 2
ciscoasa(config-if)# nameif outside
ciscoasa(config-if)# bridge-group 1
ciscoasa(config-if)# interface vlan 1
ciscoasa(config-if)# nameif inside
ciscoasa(config-if)# bridge-group 1
```

| 片段 | 意思 |
| --- | --- |
| `firewall transparent` | 切換成透通模式（**會清除既有設定**，請在全新設備上做） |
| `switchport access vlan 2／1` | ASA 5505 的 Port 是交換器 Port，先指定屬於哪個 VLAN |
| `nameif outside／inside` | 命名介面，系統自動設定 security level 0／100 |
| `bridge-group 1` | 兩個介面放進同一個橋接群組 |

**應該看到什麼**：設定 nameif 時出現 `INFO: Security level for "outside" set to 0 by default.`（inside 則是 100）。

## 4. 步驟二：ASA 管理 IP 與路由

```text
ciscoasa(config-if)# interface bvi 1
ciscoasa(config-if)# ip address <管理網段>.253 255.255.255.0
ciscoasa(config-if)# exit
ciscoasa(config)# http server enable
ciscoasa(config)# http 0.0.0.0 0.0.0.0 inside
ciscoasa(config)# route inside 192.0.2.0 255.255.255.0 <管理網段>.254
ciscoasa(config)# route inside 198.51.100.0 255.255.255.0 <管理網段>.254
ciscoasa(config)# route inside 203.0.113.0 255.255.255.0 <管理網段>.254
ciscoasa(config)# route inside <管理網段>.0 255.255.255.0 <管理網段>.254
ciscoasa(config)# route outside 0.0.0.0 0.0.0.0 <ISP 閘道>
ciscoasa(config)# write memory
```

| 片段 | 意思 |
| --- | --- |
| `interface bvi 1` + `ip address` | 透通模式下 ASA 本身唯一的 IP，用來管理（ISP 無法多給一個，所以用私有網段） |
| `http server enable` | 開啟 ASDM 網頁管理 |
| `http 0.0.0.0 0.0.0.0 inside` | 允許 inside 任何位址管理 ASA；**正式環境建議縮小到管理電腦的網段** |
| `route inside ... <管理網段>.254` | 讓 ASA 知道內部三個網段要從 3560G 回去，ASDM 才連得到 |
| `route outside 0.0.0.0 ...` | 預設路由指向 ISP |

## 5. 步驟三：3560G 建立 WAN VLAN 與路由

```text
Switch# configure terminal
Switch(config)# vlan 2
Switch(config-vlan)# name wan
Switch(config-vlan)# exit
Switch(config)# interface GigabitEthernet0/48
Switch(config-if)# switchport mode access
Switch(config-if)# switchport access vlan 2
Switch(config-if)# exit
Switch(config)# interface vlan 2
Switch(config-if)# ip address <ISP 給的 IP> 255.255.255.0
Switch(config-if)# ip address <管理網段>.254 255.255.255.0 secondary
Switch(config-if)# exit
Switch(config)# interface vlan 1
Switch(config-if)# ip address 192.0.2.254 255.255.255.0
Switch(config-if)# ip address 198.51.100.254 255.255.255.0 secondary
Switch(config-if)# ip address 203.0.113.254 255.255.255.0 secondary
Switch(config-if)# exit
Switch(config)# ip route 0.0.0.0 0.0.0.0 <ISP 閘道>
Switch(config)# ip routing
Switch(config)# end
Switch# write memory
```

| 片段 | 意思 |
| --- | --- |
| VLAN 2 主要 IP | ISP 給的對外 IP，3560G 本身就是對外的路由器 |
| VLAN 2 `secondary` | 第二組 IP 和 ASA 管理 IP 同網段，內部電腦才能經由 3560G 連到 ASA |
| VLAN 1 三組 IP | 三個內部網段的閘道，第一組是主要、另兩組是 secondary |
| `ip route 0.0.0.0 ...` | 預設路由往 ISP |
| `ip routing` | 開啟路由，各網段才互通 |

> 原文指令有筆誤（`switchpoint mode access vlan 2`），正確寫法是上面分成兩行的 `switchport mode access` 與 `switchport access vlan 2`。

## 6. 步驟四：測試

從網段一的電腦（`192.0.2.1`）測試：

| ping 目標 | 結果 |
| --- | --- |
| 三個網段的閘道 `.254` | ✅ 通 |
| 3560G 的 WAN IP `<ISP 給的 IP>` | ✅ 通 |
| 3560G 的管理段 IP `<管理網段>.254` | ✅ 通 |
| ASA 管理 IP `<管理網段>.253` | ✅ 通 |

## 7. 常見問題

| 現象 | 怎麼辦 |
| --- | --- |
| `firewall transparent` 之後設定全不見 | 正常，切換模式會清空設定；先備份再切 |
| ASDM 連不上 ASA | 檢查 `http` 允許的來源、ASA 是否有回內部網段的 `route inside` |
| 內部電腦上不了網 | 透通模式預設只放行 inside → outside；檢查 ACL 是否擋到；ISP 端是否有回程路由 |
| 3560G 指令 `switchpoint` 錯誤 | 筆誤，應為 `switchport` |

## 8. 待辦

- [ ] 將 `http 0.0.0.0 0.0.0.0 inside` 收斂到管理電腦網段

## 9. 延伸閱讀

- [Cisco 3850 新增 VLAN 並讓網段互通](../cisco-3850-vlan-routing/)
- [Blogger 原文](https://kbwangtw.blogspot.com/2015/02/cisco-3560g-asa-5505.html)
