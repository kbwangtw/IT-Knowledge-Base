---
layout: default
title: "Cisco 胖 AP（Autonomous AP）基本設定（摘要）"
date: 2015-11-03
categories: [Network, Cisco, Wireless, Blogger 舊文, 轉貼摘要]
permalink: /docs/blogger/network/cisco-autonomous-ap-basic/
last_modified_at: 2026-10-24
---

# Cisco 胖 AP（Autonomous AP）基本設定（摘要）

> **一句話**：胖 AP 不靠控制器，自己就要設好 SSID、開啟無線電、設定 BVI 管理 IP，再加上加密；原文介紹的 WEP、WPA-TKIP 都已不安全，現在請改用 **WPA2-PSK（AES）**。

| 項目 | 內容 |
| --- | --- |
| 適合誰看 | 手上有一台獨立運作的 Cisco AP（例如 1131AG）要讓它能用的人 |
| 性質 | **摘要**：原文未註明出處，推測為整理自他人文章（未確認），這裡只用自己的話整理重點 |
| 日期 | 2015-11-03（原發表於 Blogger，2026-10-24 改為摘要） |

> ⚠️ 原文示範的 **WEP** 和 **WPA-TKIP** 都能在幾分鐘內被破解，不要在正式環境使用。

## 1. 先認識幾個名詞

| 名詞 | 白話解釋 |
| --- | --- |
| **胖 AP（Autonomous AP）** | 自己保存設定、獨立運作的 AP |
| **`dot11Radio 0／1`** | AP 上的兩個無線電，分別是 2.4 GHz 與 5 GHz；預設是關閉的 |
| **BVI（Bridge Virtual Interface）** | 有線與無線橋接後的虛擬介面，AP 的管理 IP 設在這裡 |
| **guest-mode** | 廣播 SSID，讓裝置在清單上看得到 |

## 2. 設定的順序

```text
① 建立 SSID（先用開放驗證確認能通）
② 進兩個 dot11Radio 介面：套用 SSID、no shutdown
③ BVI 1：用 DHCP 或手動設定管理 IP
④ 常用設定：ARP cache、NTP、DNS、SNMP
⑤ 加上加密：先在 Radio 設加密方式，再到 SSID 設驗證方式
```

## 3. 重點整理

| 重點 | 說明 |
| --- | --- |
| 無線電預設關閉 | 兩個 `dot11Radio` 都要 `no shutdown`，否則看不到 SSID |
| 驗證設在 SSID、加密設在 Radio | 這是 Cisco 胖 AP 的設計，搞混就會設定失敗 |
| 先加密、後驗證 | 要先有金鑰，驗證方式才能引用它 |
| 開放驗證（open）只是「流程」 | 搭配 PSK 時仍然需要密碼，名稱容易讓人誤會 |
| SNMP community 不要用 `public` | 預設值人人都知道，改成自訂字串並限制唯讀 |
| NTP、DNS | 範例中的伺服器位址請換成你自己環境的 |

建議的 WPA2-PSK 設定方向（取代原文的 WEP／TKIP）：

```text
interface dot11Radio 0
 encryption mode ciphers aes-ccm
ssid <SSID名稱>
 authentication open
 authentication key-management wpa version 2
 wpa-psk ascii <無線密碼>
```

> 上面是依 Cisco Autonomous AP 指令格式整理的建議，未在原作者環境實測；不同 IOS 版本細節可能不同。

## 4. 延伸閱讀

- [Cisco 瘦 AP 怎麼找到無線控制器](../cisco-lightweight-ap-join-controller/)
- [Blogger 原文](https://kbwangtw.blogspot.com/2015/11/cisco-ap.html)
