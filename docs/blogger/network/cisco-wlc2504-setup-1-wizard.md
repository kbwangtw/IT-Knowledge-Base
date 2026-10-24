---
layout: default
title: "Cisco 2504 無線控制器基本設定（一）：Console 初始設定精靈"
date: 2015-10-08
categories: [Network, Cisco, Wireless, Blogger 舊文]
permalink: /docs/blogger/network/cisco-wlc2504-setup-1-wizard/
last_modified_at: 2026-10-24
---

# Cisco 2504 無線控制器基本設定（一）：Console 初始設定精靈

> **一句話**：先把 2504 韌體更新到 **8.1.102.0**，再用 Console 跑完初始設定精靈：系統名稱、管理帳密、管理 IP、虛擬閘道、第一個 SSID、國碼 TW，存檔重開後就能用瀏覽器登入做後續設定。

| 項目 | 內容 |
| --- | --- |
| 適合誰看 | 第一次設定 Cisco 無線控制器（WLC）的人 |
| 環境 | Cisco 2504 Wireless Controller、AP1702I × 2；兩個 SSID（範例名稱 Contoso、Contoso-1），WPA/WPA2 密碼驗證 |
| 日期 | 2015-10-08（原文發表於 Blogger，2026-10-24 改寫為新手版） |
| 結論 | ✅ 精靈完成、設定存檔重開 → 接（二）用網頁設定 SSID 安全性 |

> ⚠️ 原作者特別強調（說了三次）：**韌體一定要先更新到 Software Version 8.1.102.0**，尤其搭配 AP1702I 時，舊版會讓你吃足苦頭。

## 1. 先認識幾個名詞

| 名詞 | 白話解釋 |
| --- | --- |
| **WLC（Wireless LAN Controller）** | 集中管理所有 AP 的設備；SSID、密碼、頻道都在這裡設，AP 自己不存設定 |
| **瘦 AP（Lightweight AP）** | 要靠 WLC 才能運作的 AP；相對的「胖 AP」可以獨立運作 |
| **SSID** | 無線網路名稱 |
| **管理介面（Management Interface）** | WLC 的管理 IP，AP 和管理者都連這個位址 |
| **虛擬閘道（Virtual Gateway）** | WLC 內部用的虛擬位址，給網頁驗證、DHCP 轉送使用；必須是網路上**不會用到**的位址 |
| **LAG** | 把 WLC 多個實體 Port 綁成一條，增加頻寬與容錯 |
| **Mobility／RF Group** | 一群互相協調頻道與漫遊的 WLC 名稱 |

## 2. 環境規劃

```text
           核心交換器
               │
      ┌────────┴─────────┐
   WLC 2504            AP × 2（Contoso-AP1、Contoso-AP2）
   管理 IP 192.0.2.222     192.0.2.219、192.0.2.223
   閘道   192.0.2.1
   DNS／DHCP 192.0.2.2
```

> 原文用內網位址，這裡改用示範位址；套用時換成你自己的網段。

## 3. 步驟一：用 Console 進入設定精靈

**做什麼**：電腦用 Console 線連上 WLC，開機後依序回答精靈的問題。

**怎麼做**：下表是原作者的回答（左邊是問題，右邊是輸入的值）：

| 精靈問題 | 回答 | 說明 |
| --- | --- | --- |
| Would you like to terminate autoinstall? | `yes` | 不要等網路自動下載設定 |
| System Name | `WLC2504` | 控制器名稱 |
| Enter Administrative User Name | `<管理帳號>` | 不要用 `admin`、`cisco` 這類好猜的名字 |
| Enter Administrative Password | `<管理密碼>` | 3～24 字元 |
| Enable Link Aggregation (LAG) | `yes` | 多個 Port 綁成一條 |
| Management Interface IP Address | `192.0.2.222` | WLC 管理 IP |
| Management Interface Netmask | `255.255.255.0` | |
| Management Interface Default Router | `192.0.2.1` | 預設閘道 |
| Management Interface VLAN Identifier | `0` | 0 = 不帶 VLAN 標籤（untagged） |
| Management Interface DHCP Server IP Address | `192.0.2.2` | 發 IP 給無線用戶的 DHCP 伺服器 |
| Virtual Gateway IP Address | 原文 `1.1.1.1` | 見下方說明 |
| Multicast IP Address | `239.0.1.1` | AP 群播用，私有群播位址 |
| Mobility/RF Group Name | `ContosoGroup` | |
| Network Name (SSID) | `Contoso` | 第一個 SSID |
| Configure DHCP Bridging Mode | `no` | |
| Allow Static IP Addresses | `yes` | 允許用戶自己設固定 IP |
| Configure a RADIUS Server now? | `no` | 用密碼驗證，不接 RADIUS |
| Enter Country Code list | `TW` | **一定要設對**，決定可用頻道與功率 |
| Enable 802.11b／a／g Network | `yes` | 2.4 GHz 與 5 GHz 都開 |
| Enable Auto-RF | `yes` | 自動調整頻道與功率 |
| Enter the date／time | 當下日期時間 | 原文 `10/08/15`、`09:05:35` |
| Would you like to configure IPv6 parameters | `no` | |
| Configuration correct? | `yes` | 存檔並重開 |

> **虛擬閘道說明**：2015 年常見範例用 `1.1.1.1`，但這個位址現在是公開的 DNS 服務，用了會讓用戶連不到它。Cisco 目前建議改用**不會被路由的位址**，例如 `192.0.2.1` 這類示範網段。

## 4. 步驟二：存檔重開

**應該看到什麼**：

```text
Configuration saved!
Resetting system with new configuration...
（重開機）
Starting Management Services:
   Web Server:    CLI:    Secure Web: ok
(Cisco Controller)
Enter User Name (or 'Recover-Config' this one-time only to reset configuration to factory defaults)
User:
```

出現 `User:` 登入提示就完成了。

> 精靈過程中出現 `Error: failed to disable Day0 ssid. return Code : 7`，原作者照常完成，沒有影響後續使用。

## 5. 常見問題

| 現象 | 怎麼辦 |
| --- | --- |
| AP1702I 加入不了或怪怪的 | 先把 WLC 更新到 8.1.102.0 以上 |
| 精靈某題輸入錯誤 | 繼續完成，之後在網頁介面修改；或登入時輸入 `Recover-Config` 回到出廠重跑精靈 |
| 用戶連不到 1.1.1.1 這個 DNS | 虛擬閘道佔用了 1.1.1.1，改成不會被路由的位址 |
| 頻道很少或訊號弱 | 國碼要設 `TW` |

## 6. 延伸閱讀

- [Cisco 2504 無線控制器（二）：用網頁設定兩個 SSID 與 WPA 密碼](../cisco-wlc2504-setup-2-ssid/)
- [Cisco 2504 無線控制器（三）：應用程式統計與 5 GHz 頻道調整](../cisco-wlc2504-setup-3-rf-tuning/)
- [Cisco 瘦 AP 怎麼找到控制器](../cisco-lightweight-ap-join-controller/)
- [Blogger 原文](https://kbwangtw.blogspot.com/2015/10/cisco-2504-wireless-controller.html)
