---
layout: default
title: "Cisco 胖 AP（Autonomous AP）基本設定：SSID、BVI、WEP 與 WPA-PSK"
date: 2015-11-03
categories: [Network, Cisco, Wireless, Blogger 舊文]
permalink: /docs/blogger/network/cisco-autonomous-ap-basic/
last_modified_at: 2026-10-24
---

# Cisco 胖 AP（Autonomous AP）基本設定：SSID、BVI、WEP 與 WPA-PSK

> **一句話**：胖 AP 不靠控制器，要自己設好 SSID、開啟兩個無線電、給 BVI 一個管理 IP，三步就能連；之後再補 ARP cache、時間、DNS、SNMP，最後加上加密——加密的規則是「**加密設在 Radio、驗證設在 SSID，而且先加密、後驗證**」。

| 項目 | 內容 |
| --- | --- |
| 適合誰看 | 手上有一台獨立運作的 Cisco AP（例如 1131AG），想讓它能用、再慢慢加安全設定的人 |
| 環境 | Cisco Aironet 1131AG（Autonomous／胖 AP，802.11a 與 802.11g 雙無線電） |
| 日期 | 2015-11-03（原文發表於 Blogger，2026-10-24 改寫為新手版） |
| 結論 | ✅ 三步驟讓 AP 可用 ✅ 常用基本設定 ✅ WEP、WPA-PSK 設法與驗證流程 ⏳ 改用 WPA2（AES）的做法為補充，未實測 |

> ⚠️ 原文示範的 **WEP** 與 **WPA-TKIP** 都已經能在短時間內被破解，只適合了解原理或測試，**不要用在正式環境**。正式環境請看第 7 節的 WPA2-PSK（AES）。

## 1. 先認識幾個名詞

| 名詞 | 白話解釋 |
| --- | --- |
| **胖 AP（Autonomous AP）** | 設定存在自己身上、獨立運作的 AP；相對的「瘦 AP」要靠無線控制器才能運作 |
| **SSID** | 無線網路的名稱，手機、筆電搜尋 Wi-Fi 時看到的那個名字 |
| **`dot11Radio 0／1`** | AP 上的兩個無線電介面。1131AG 的 0 是 802.11a（5 GHz）、1 是 802.11g（2.4 GHz）；**預設是關閉的** |
| **BVI（Bridge Virtual Interface）** | 把有線與無線橋接在一起的虛擬介面；AP 靠它跟實體網路溝通，**管理 IP 就設在這裡** |
| **guest-mode** | 讓 AP 廣播 SSID，裝置的 Wi-Fi 清單才看得到；為了安全可以不開，但連線端就要自己輸入 SSID |
| **Open 驗證** | Cisco 對「不需要帳號、不問身分」的驗證方式的稱呼，名字叫開放，但搭配 WEP／PSK 時仍然需要金鑰 |
| **WEP** | 最早的無線加密，用一把固定的金鑰；很容易被破解 |
| **WPA-PSK** | 預先共用金鑰（Pre-Shared Key）：不用 RADIUS 等驗證伺服器，所有人用同一組密碼連線 |
| **TKIP** | WPA 第一代的加密方式，會動態更換金鑰，比 WEP 強但現在也不安全 |
| **ARP cache** | 讓 AP 記住 ARP 對應，減少不必要的廣播封包 |

## 2. 整體流程

```text
Part 1  快速讓 AP 可用
 ① 建立 SSID（先用 open 驗證，確認能通）
 ② 兩個 dot11Radio：套用 SSID 並 no shutdown
 ③ BVI 1：DHCP 或手動給管理 IP
        │
        ▼  先用電腦連看看
Part 2  常用基本設定
 ④ ARP cache → 時間（NTP／手動）→ DNS → SNMP
        │
        ▼
Part 3  加密驗證
 ⑤ 加密方式 → 設在 Radio（interface dot11Radio）
 ⑥ 驗證方式 → 設在 SSID（dot11 ssid）
    ※ 一定先設加密、再設驗證
```

## 3. Part 1：快速讓胖 AP 可用

### 步驟一：建立 SSID

**做什麼**：先建一個 SSID，驗證先用 open，只求能通；加上 `guest-mode` 方便初次連線時看得到名稱。

**怎麼做**：

```text
ap#config t
ap(config)#dot11 ssid MySSID
ap(config-ssid)#authentication open
ap(config-ssid)#guest-mode
```

| 片段 | 意思 |
| --- | --- |
| `dot11 ssid MySSID` | 建立（或進入）名稱為 MySSID 的 SSID 設定 |
| `authentication open` | 設定時一定要同時指定驗證方式，先用開放驗證讓它能通 |
| `guest-mode` | 廣播 SSID，初始化連線方便；為了安全可以不設，但連線端就要自己輸入 SSID |

### 步驟二：把 SSID 套用到無線電並開啟

**做什麼**：1131AG 有兩個無線電（802.11a 在 `dot11Radio 0`、802.11g 在 `dot11Radio 1`），**預設都是關閉**，要進介面把 SSID 掛上去再打開。

```text
ap(config)#int dot11Radio 0
ap(config-if)#ssid MySSID
ap(config-if)#no shutdown
ap(config)#int dot11Radio 1
ap(config-if)#ssid MySSID
ap(config-if)#no shutdown
```

### 步驟三：設定 BVI

**做什麼**：胖 AP 靠 BVI 讓實體網路與無線網路互通，所以要給它一個實體網路的 IP。**如果環境有 DHCP，這一步可以略過**，因為預設會自己抓。

用 DHCP：

```text
ap(config-if)#int bvi 1
ap(config-if)#ip addr dhcp
```

或手動指定 IP（以下用文件示範網段）：

```text
ap(config-if)#int bvi 1
ap(config-if)#ip addr 192.0.2.3 255.255.255.0
```

**應該看到什麼**：用自己的電腦或手機連連看這個 SSID，連得上就代表 Part 1 完成。

## 4. Part 2：常用基本設定

### ARP Cache

AP 的運作像 Hub，廣播是它必做的事。開啟 ARP cache 後，AP 收到 ARP 封包會先比對快取，**不在快取裡就不廣播、直接丟掉**，藉此減少廣播封包（原作者提到效能提升「感受不到」，但可以減少廣播）。

```text
ap(config)#dot11 arp-cache
```

### 時間

想跟 NTP 伺服器同步時間：

```text
ap(config)#sntp server <NTP 伺服器>
```

或直接手動設定時間，再用 `show clock` 確認：

```text
ap#clock set 12:21:00 3 Sep 2010
ap#show clock
```

> 原文範例的 NTP 位址已改成 `<NTP 伺服器>`，請換成你環境內可用的 NTP。`clock set` 的日期只是原文示範，請設成當下的實際時間。

### DNS

環境沒有 DHCP 可自動給 DNS 的話，可以手動指定：

```text
ap(config)#ip name-server <DNS 伺服器>
```

### SNMP

需要讓網管軟體讀取 AP 狀態時開啟。最後面可選 `ro`（Read Only，唯讀）或 `rw`（Read and Write，可寫）：

```text
ap(config)#snmp-server community <自訂字串> ro
```

> 原文範例用的 community 是 `public`。這是人人都知道的預設值，請改成自訂字串並盡量用 `ro`；`rw` 等於把設備的寫入權限交給知道字串的人。

## 5. Part 3：加密驗證的兩條規則

胖 AP 最常用的是 **WEP** 與 **WPA-PSK** 兩種。因為胖 AP 通常不會連到 RADIUS 之類的驗證平台（瘦 AP 才需要），沒有驗證平台時，就用 PSK 取代。設定前請先記住兩件事：

| 規則 | 說明 |
| --- | --- |
| **驗證方式設在 SSID 下，加密方式設在無線訊號（Radio）下** | 兩者位置不同，搞混就設不起來 |
| **一定先設加密，再設驗證** | 要先有金鑰，驗證方式才能引用它 |

## 6. WEP 與 WPA-PSK 的設定（原文做法，僅供了解原理）

### 6-1 先看驗證流程，才懂為什麼這樣設

WEP 驗證基本上**不看人、只看那把金鑰**：

```text
Client                                             AP
  │── Authentication Request ─────────────────────▶│
  │◀──── Authentication Response + Challenge ──────│  （AP 丟一段明文）
  │── 用 WEP 金鑰加密這段明文 (Association Request) ▶│
  │◀──── 比對金鑰、符合就回 Association Confirmation│
```

這就是連線時會跳出視窗請你輸入密碼（passphrase）的原因：Client 用你輸入的金鑰把資料加密送給 AP，AP 用自己設定的金鑰解開，解得開就回 Association Confirmation。

### 6-2 設定 WEP

**怎麼做**：先到無線訊號下設定加密——先設 key 1～4，`size` 可選 40 或 128；40 要設 10 位的金鑰、128 要設 26 位的金鑰，這就是 Client 連線時要輸入的密碼。再指定模式為 WEP：

```text
ap(config)#inter dot11Radio 0
ap(config-if)#encryption key 1 size 40 <10位金鑰>
ap(config-if)#encryption mode wep mandatory key-hash
```

然後進到 SSID，驗證方式指定為**開放**：

```text
ap(config)#dot11 ssid MySSID
ap(config-ssid)#authentication open
```

| 片段 | 意思 |
| --- | --- |
| `encryption key 1 size 40 <金鑰>` | 設定第 1 把 WEP 金鑰，長度 40 bit；128 bit 要 26 位 |
| `encryption mode wep mandatory` | 強制使用 WEP，不加密的連線不放行 |
| `key-hash` | 金鑰在設定檔中以雜湊顯示（補充說明，非逐字原文） |

> 原文說 40 bit 金鑰是「十位元的文字」。WEP 金鑰其實是 **10 個十六進位字元**（128 bit 為 26 個），這是補充，未在原作者環境逐一驗證。

**常見疑問：不是設 WEP 嗎？驗證怎麼是 open？**

Cisco 的「開放驗證」流程如下：

```text
Client                                    AP
  │── Authentication Request ─────────────▶│
  │◀──────── Authentication Response ──────│
  │── Association Request ────────────────▶│
  │◀──────── Association Confirmation ─────│
```

跟上面 WEP 流程比一下，**整個流程是一樣的**。說穿了 WEP 只是在開放驗證裡多了一個「金鑰確認」機制，所以 Cisco 仍把 WEP 歸類為開放式驗證。

> 這也解釋了 Part 1：我們只設 `authentication open`、沒有設任何加密，所以不用輸入密碼就能使用 AP。

### 6-3 設定 WPA-PSK（TKIP）

**怎麼做**：一樣先到無線頻道指定加密方式。因為是 WPA，會用 TKIP 動態更換金鑰來加強安全：

```text
ap(config)#inter dot11Radio 0
ap(config-if)#encryption mode ciphers tkip
```

再進 SSID 設定驗證。因為只是 WPA-PSK，不需要 EAP 驗證，用 open 即可；`key-management` 指定用 WPA，最後設定 PSK（也就是 Client 連線的密碼）：

```text
ap(config)#dot11 ssid MySSID
ap(config-ssid)#authentication open
ap(config-ssid)#authentication key-management wpa
ap(config-ssid)#wpa-psk ascii <無線密碼>
```

| 片段 | 意思 |
| --- | --- |
| `encryption mode ciphers tkip` | 在 Radio 上指定使用 TKIP 加密 |
| `authentication open` | 驗證流程仍是開放式的四個步驟 |
| `authentication key-management wpa` | 金鑰管理使用 WPA |
| `wpa-psk ascii <密碼>` | 設定預先共用金鑰（以文字格式） |

**應該看到什麼**：設完之後會發現，WPA-PSK 的驗證流程仍然是 open 的那四個步驟，**比 WEP 強的地方在於 TKIP 會自動更換金鑰**，所以「較為」安全（原作者特別強調是「較為」）。

## 7. 補充：正式環境請改用 WPA2-PSK（AES）

> 以下依 Cisco Autonomous AP 指令格式整理，**非原文內容，未在原作者環境實測**；不同 IOS 版本細節可能不同，請以官方文件為準。

```text
interface dot11Radio 0
 encryption mode ciphers aes-ccm
!
dot11 ssid MySSID
 authentication open
 authentication key-management wpa version 2
 wpa-psk ascii <無線密碼>
```

兩個 Radio 都要記得套用，設完用 `show running-config` 檢查。

## 8. 常見問題

| 現象 | 怎麼辦 |
| --- | --- |
| 設好了卻看不到 SSID | 兩個 `dot11Radio` 都要 `no shutdown`，並且各自 `ssid MySSID`；也確認有沒有設 `guest-mode` |
| 連得上 SSID 但拿不到 IP | 檢查有線端 DHCP；BVI 是否有 IP；AP 與網路線是否接在正確的 VLAN |
| 驗證設定一直報錯或被拒 | 順序反了：要**先**在 Radio 設加密、**再**在 SSID 設驗證 |
| 設了 WEP 但驗證寫 open，是不是設錯？ | 沒錯，Cisco 把 WEP 當作 open 的一種，差別只在金鑰確認 |
| 原文寫成 `WPS-PSK`、`Cler-text`、`authenticaion` | 原文筆誤，正確是 WPA-PSK、clear-text、authentication，本頁已更正 |
| SNMP 被掃到 | community 不要用 `public`；用 `ro`；必要時限制可存取的來源 |

## 9. 待辦

- [ ] 在實體 AP 上實測第 7 節 WPA2（AES）設定，確認指令與 IOS 版本
- [ ] 補上 `show dot11 associations` 查看連線 Client 的畫面

## 10. 延伸閱讀

- [Cisco 瘦 AP 怎麼找到無線控制器](../cisco-lightweight-ap-join-controller/)
- [Blogger 原文](https://kbwangtw.blogspot.com/2015/11/cisco-ap.html)
