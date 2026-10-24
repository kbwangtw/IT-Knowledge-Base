---
layout: default
title: "Blogger 舊文（2011–2025）"
permalink: /docs/blogger/
last_modified_at: 2026-10-24
---

# Blogger 舊文（2011–2025）

> **一句話**：這裡是從舊部落格「IT、MIS 資訊黑手的維修記錄」搬過來的文章，2026-10-24 全部改寫成新手版；轉貼別人的文章只留重點摘要和原文連結。

| 項目 | 內容 |
| --- | --- |
| 原部落格 | [kbwangtw.blogspot.com](https://kbwangtw.blogspot.com/)（共 62 篇） |
| 已搬移 | **62 篇全部完成**（2026-10-24）；短篇的校園網站報修紀錄合併成一頁 |
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

### 2-3 Cisco 無線網路

| 文章 | 原發表 | 適合什麼時候看 |
| --- | --- | --- |
| [Cisco 2504 無線控制器（一）：Console 初始設定精靈](network/cisco-wlc2504-setup-1-wizard/) | 2015-10 | 第一次設定 WLC |
| [Cisco 2504 無線控制器（二）：用網頁設定兩個 SSID 與密碼](network/cisco-wlc2504-setup-2-ssid/) | 2015-10 | 設定 SSID 與 WPA2 密碼 |
| [Cisco 2504 無線控制器（三）：應用程式統計與 5 GHz 頻道調整](network/cisco-wlc2504-setup-3-rf-tuning/) | 2015-10 | 看流量統計、調頻道減少干擾 |
| [Cisco 瘦 AP 怎麼找到無線控制器](network/cisco-lightweight-ap-join-controller/)（摘要） | 2015-10 | AP 加入不了 WLC |
| [Cisco 胖 AP（Autonomous AP）基本設定](network/cisco-autonomous-ap-basic/)（摘要） | 2015-11 | 單獨一台 Cisco AP 要能用 |

### 2-4 HPE 交換器

| 文章 | 原發表 | 適合什麼時候看 |
| --- | --- | --- |
| [HPE 5130 四台用 IRF 堆疊成一台](network/hpe-5130-irf-stack/) | 2018-07 | 多台交換器堆疊成一台管理 |
| [HPE 5700 核心與 5130 堆疊之間的 LACP](network/hpe-5700-5130-lacp/) | 2018-07 | 核心往下接堆疊，要備援 |
| [HPE 5130 忘記密碼、重設與取消 IRF](network/hpe-5130-password-reset/) | 2018-07 | 不知道密碼；要拆堆疊 |
| [HPE Aruba 1930／1920S 網頁介面切 VLAN](network/hp-1930s-vlan/) | 2022-01 | 第一次在 HP 交換器切 VLAN |

### 2-5 防火牆與資安

| 文章 | 原發表 | 適合什麼時候看 |
| --- | --- | --- |
| [FortiGate 60D 兩廠之間建立 Site-to-Site IPsec VPN](network/fortinet-60d-site-to-site-vpn/) | 2014-04 | 兩個據點內網要互通 |
| [FortiGate 只允許指定外網 IP ping 到 WAN](network/fortigate-local-in-policy-ping/) | 2020-08 | 限制誰能 ping 防火牆 |
| [FortiGate 110C 讓特定電腦用另一個公開 IP 上網](network/fortigate-110c-ip-pool-outbound/) | 2011-04 | 某台電腦要固定用某個 IP 出去 |
| [FortiGate IP/MAC 綁定](network/fortigate-ip-mac-binding/)（轉貼摘要） | 2021-09 | 只讓登記過的電腦上網 |
| [Cisco 3560G 當路由、ASA 5505 用透通模式管控上網](network/cisco-3560g-asa5505-transparent/) | 2015-02 | 不改 IP 架構加一台防火牆 |
| [Palo Alto PA-200 第一次安裝](network/paloalto-pa200-globalprotect/) | 2016-09 | 第一次接觸 Palo Alto |
| [在 IBM X3105 安裝 pfSense 2.1：Squid 透明代理與內容過濾](network/pfsense-ibm-x3105-squid/) | 2013-11 | 用免費防火牆做上網快取與過濾 |
| [pfSense 依 IP 限制頻寬](network/pfsense-bandwidth-limit/)（轉貼摘要） | 2014-08 | 少數人佔滿線路 |
| [用舊伺服器裝 BrazilFW 免費路由器](network/brazilfw-ibm-x3105/) | 2013-10 | 想用舊電腦做路由並看流量 |
| [裝完 Sophos 端點防護後登入黑畫面](network/sophos-endpoint-black-screen/) | 2022-01 | 部署防毒後使用者登入異常 |

## 3. 伺服器硬體與 UPS

### 3-1 HP／HPE 伺服器

| 文章 | 原發表 | 適合什麼時候看 |
| --- | --- | --- |
| [HPE Gen10 透過 iLO 5 網頁更新 BIOS 與 iLO 韌體](hardware/hpe-ilo5-bios-firmware-upgrade/) | 2020-07 | 第一次幫伺服器更新韌體 |
| [DL380 G7 改裝 1 GB Cache 後開不了機：事件紀錄與檢討](hardware/hpe-dl380g7-p410i-cache-upgrade-incident/) | 2020-07 | 要換 RAID 卡電池或 Cache |
| [HP ML10 Gen9：Intel RST 建 RAID 1 並安裝 Windows 2012](hardware/hp-ml10-gen9-rst-raid-windows2012/) | 2016-09 | ML10 Gen9 做鏡像並裝 Windows |
| [HP ML10 v2 安裝 Windows 2012 R2：B120i RAID 與驅動](hardware/hp-ml10-v2-b120i-windows-2012r2/) | 2015-06 | Windows 安裝時看不到硬碟 |
| [用隨身碟裝 Windows 2016 出現 0x80070026](hardware/hp-ml10-windows2016-install-wim-0x80070026/) | 2017-05 | 安裝說找不到 install.wim |
| [HP DL120 G6 加裝光碟機](hardware/hp-dl120g6-optical-drive/) | 2011-08 | 第一次幫伺服器加光碟機 |

### 3-2 IBM／Lenovo 伺服器與 VMware

| 文章 | 原發表 | 適合什麼時候看 |
| --- | --- | --- |
| [Lenovo SR650 的 ESXi 6.5 看不到 RAID 狀態：安裝 LSI Provider](hardware/vmware-esxi65-lsi-provider-sr650/) | 2018-09 | ESXi 監控看不到硬碟健康 |
| [Lenovo TS150 加 NVS315 安裝 Windows 2016 藍屏](hardware/lenovo-ts150-windows2016/) | 2019-05 | 加了顯示卡就裝不了系統 |
| [IBM X3250 用 LSI 1064e 建立 RAID 1](hardware/ibm-x3250-lsi1064e-raid1/) | 2011-08 | 舊款 IBM 伺服器做鏡像 |
| [IBM X346 ServeRAID 錯誤碼 2807：換卡後接受新電池](hardware/ibm-serveraid-error-2807/) | 2016-12 | ServeRAID 報錯、換卡 |
| [IBM X336 系統碟換大顆不重灌](hardware/ibm-x336-scsi-disk-upgrade/) | 2011-02 | 系統碟空間不夠 |

### 3-3 UPS

| 文章 | 原發表 | 適合什麼時候看 |
| --- | --- | --- |
| [APC Smart-UPS 換新電池後 Battery 燈還在閃](hardware/apc-smart-ups-battery-reset/) | 2023-08 | 換了電池，UPS 還是一直閃燈 |

## 4. Windows 與常用工具

| 文章 | 原發表 | 適合什麼時候看 |
| --- | --- | --- |
| [PuTTY、Tera Term、SecureCRT 自動存 Log 與改配色](windows/terminal-putty-teraterm-securecrt-log/) | 2021-06 | 想留下每次連線的操作紀錄 |
| [Windows 2008 格式化 18 TB RAID 5 失敗：配置單位改 8K](windows/windows2008-format-large-raid5-8k/) | 2014-03 | 大容量磁碟格式化失敗 |
| [EPSON L550 在 Windows 10 安裝 Fax Utility](windows/epson-l550-fax-utility-win10/) | 2021-07 | 事務機能印不能傳真 |
| [SQL Server 服務因登入失敗無法啟動](windows/sql-server-service-logon-failure/)（摘要） | 2011-02 | 改了帳號密碼後 SQL 起不來 |
| [Windows 10 上 Outlook 2010 點連結一直詢問程式](windows/outlook-2010-link-prompt-windows10/)（摘要） | 2016-05 | 舊版 Outlook 點連結跳視窗 |
| [Windows Server 2012 無網域安裝遠端桌面服務與授權](windows/windows2012-rds-licensing-workgroup/)（轉貼摘要） | 2015-06 | 工作群組環境開放多人遠端 |
| [在 Windows Server 2012 R2 安裝 MSE](windows/mse-on-windows-server-2012r2/)（轉貼摘要，已不建議） | 2016-07 | 參考用 |

## 5. Linux 與 NAS

| 文章 | 原發表 | 適合什麼時候看 |
| --- | --- | --- |
| [Ubuntu 12.04 雙網卡 Bonding：7 種模式怎麼選](linux/ubuntu-1204-bonding/) | 2014-10 | Linux 雙網卡備援與加頻寬 |
| [RHEL／CentOS 7 把網卡名稱改回 eth0](linux/rhel7-rename-nic-eth0/) | 2021-12 | 舊腳本寫死 eth0 |
| [在 Ubuntu 12.04 安裝 Moodle 2.7](linux/moodle27-ubuntu1204/) | 2014-10 | 自架線上課程平台 |
| [CentOS 6 雙網卡綁定 bond0](linux/centos6-bonding/)（摘要） | 2015-09 | 維護舊版 CentOS |
| [RHEL 7 的 Network Teaming](linux/rhel7-network-teaming/)（轉貼摘要） | 2014-12 | 認識 teamd |
| [QNAP 當 LDAP、Synology 加入並提供 RADIUS](linux/qnap-synology-ldap-radius/) | 2017-09 | 沒有 AD 也想統一帳密 |

## 6. 校園網站維護

| 文章 | 原發表 | 適合什麼時候看 |
| --- | --- | --- |
| [校園「動態網頁模組系統」常見問題](linux/school-dynaweb-troubleshooting/)（合併 4 篇） | 2011-02 | 學校 PHP 網站報修：MySQL 停止、上傳失敗 |
| [網頁寶典系統安裝在 Synology NAS：config.inc 設定](linux/campus-config-inc-synology/) | 2011-04 | 把 PHP 校園系統裝在 NAS 上 |

## 7. 公告

| 文章 | 原發表 |
| --- | --- |
| [YouTube 頻道與虛擬平台轉換紀錄](announcements/) | 2024-09、2025-03 |
