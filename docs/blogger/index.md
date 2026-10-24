---
layout: default
title: "Blogger 舊文（2011–2025）"
permalink: /docs/blogger/
last_modified_at: 2026-10-24
---

# Blogger 舊文（2011–2025）

> **一句話**：這裡是從舊部落格「IT、MIS 資訊黑手的維修記錄」搬過來的文章，2026-10-24 起逐篇改寫成新手版；轉貼別人的文章只留重點摘要和原文連結。

| 項目 | 內容 |
| --- | --- |
| 原部落格 | [kbwangtw.blogspot.com](https://kbwangtw.blogspot.com/)（共 62 篇） |
| 已搬移 | 14 篇（第一～二批） |
| 注意 | 多數文章年代較早，設備與軟體版本可能已停產；照做前先確認自己的版本 |

## 1. 怎麼看這區的文章

| 標記 | 意思 |
| --- | --- |
| 一般文章 | 原作者自己的實作紀錄，改寫成「做什麼 → 怎麼做 → 應該看到什麼」 |
| **轉貼摘要** | 原文是別人寫的，這裡只整理重點，詳細內容請點原文連結 |

## 2. 網路設備

### 2-1 Cisco 交換器：VLAN、Trunk、ACL

| 文章 | 原發表 | 適合什麼時候看 |
| --- | --- | --- |
| [Cisco 3850 新增 VLAN、分配 Port、讓兩個網段互通](network/cisco-3850-vlan-routing/) | 2015-10 | 第一次在 L3 交換器切 VLAN |
| [Cisco 3750 與 2960 之間設定 Trunk](network/cisco-3750-2960-trunk/) | 2018-07 | 兩台交換器之間要跑多個 VLAN |
| [Cisco Port Channel：兩條線綁成一條 Trunk](network/cisco-port-channel/) | 2018-07 | 上行或伺服器要備援、加頻寬 |
| [Cisco VLAN ACL：讓 VLAN 20、30 互不相通](network/cisco-vlan-acl/) | 2018-07 | 部門網段隔離，共用伺服器網段 |
| [Cisco ACL 插入或調整規則順序](network/cisco-acl-sequence/)（轉貼摘要） | 2023-08 | 要在既有 ACL 中間加規則 |
| [Edge-core ES4612 接 Cisco 3500XL 被 Spanning Tree 擋住](network/edgecore-es4612-cisco-3500xl-stp/) | 2011-03 | 不同廠牌交換器對接一直被 block |

### 2-2 Cisco 救援、重設與密碼

| 文章 | 原發表 | 適合什麼時候看 |
| --- | --- | --- |
| [Cisco 3850 改 Install 模式失敗開不了機：用隨身碟救回來](network/cisco-3850-bundle-to-install-recovery/) | 2022-02 | 3850 開機停在 `switch:` |
| [Cisco Catalyst 3850 恢復原廠設定（IOS XE）](network/cisco-catalyst-3850-factory-reset/) | 2024-12 | 清空 3850，或不知道密碼 |
| [Cisco 3750X／3850 等交換器恢復原廠設定](network/cisco-switch-factory-reset/) | 2015-10 | 舊款 IOS 交換器清空設定 |
| [Cisco Nexus 3548 忘記 admin 密碼](network/cisco-nexus-3548-password-recovery/) | 2021-11 | Nexus 密碼遺失 |
| [Cisco Router／Switch 用 confreg 0x2142 回復原廠](network/cisco-router-switch-reset-confreg/)（轉貼摘要） | 2014-05 | 路由器忘記密碼 |

### 2-3 其他廠牌交換器與防火牆

| 文章 | 原發表 | 適合什麼時候看 |
| --- | --- | --- |
| [HPE Aruba 1930／1920S 網頁介面切 VLAN](network/hp-1930s-vlan/) | 2022-01 | 第一次在 HP 交換器切 VLAN |
| [FortiGate IP/MAC 綁定](network/fortigate-ip-mac-binding/)（轉貼摘要） | 2021-09 | 只讓登記過的電腦上網 |

## 3. 硬體與 UPS

| 文章 | 原發表 | 適合什麼時候看 |
| --- | --- | --- |
| [APC Smart-UPS 換新電池後 Battery 燈還在閃](hardware/apc-smart-ups-battery-reset/) | 2023-08 | 換了電池，UPS 還是一直閃燈 |
