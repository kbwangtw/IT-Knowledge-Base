---
layout: default
title: "Cisco 瘦 AP 怎麼找到無線控制器：三種常用方法與手動指定 WLC"
date: 2015-10-08
categories: [Network, Cisco, Wireless, Blogger 舊文]
permalink: /docs/blogger/network/cisco-lightweight-ap-join-controller/
last_modified_at: 2026-10-24
---

# Cisco 瘦 AP 怎麼找到無線控制器：三種常用方法與手動指定 WLC

> **一句話**：瘦 AP 開機後會依序用三種方法找無線控制器（WLC）：**①同網段廣播 → ②聽附近 AP 空中廣播（OTAP）→ ③自己記住的 WLC IP**；前兩種幾乎不用設定，第三種要用 Console 線手動告訴 AP「控制器在哪」。

| 項目 | 內容 |
| --- | --- |
| 適合誰看 | AP 插上去卻一直加入不了 WLC 的人 |
| 環境 | Cisco 瘦 AP（Lightweight AP）＋ Cisco 無線控制器 |
| 日期 | 2015-10-08（原文發表於 Blogger，2026-10-24 改寫為新手版） |
| 結論 | ✅ 三種常用尋找方法與適用情境 ✅ 手動指定 WLC 的指令（舊版語法） ⏳ 新版 CAPWAP 語法、DHCP Option 43、DNS 為補充，未實測 |

## 1. 先認識幾個名詞

| 名詞 | 白話解釋 |
| --- | --- |
| **瘦 AP（Lightweight AP）** | 自己不存設定，必須靠 WLC 才能運作的 AP |
| **WLC（Wireless LAN Controller）** | 無線控制器，集中管理所有瘦 AP 的設定與漫遊 |
| **Discovery** | AP 開機後「尋找 WLC」的過程 |
| **OTAP（Over The Air Provisioning）** | 透過無線電波，讓新 AP 從已加入的 AP 那裡得知 WLC 在哪 |
| **LWAPP／CAPWAP** | AP 與 WLC 之間的通訊協定；LWAPP 是舊版，CAPWAP 是新版 |
| **Console 線** | 接到 AP 的 Console 孔、用終端機軟體操作 CLI 的線 |

## 2. 全貌：AP 找 WLC 的順序

```text
AP 開機、取得 IP
  │
  ▼
① 區域廣播（Local IP Subnet Discovery）
  │ 同網段有 WLC → 找到、加入
  ▼ 找不到
② 空中廣播（OTAP）
  │ 附近有已加入 WLC 的 AP → 跟著找到 WLC
  ▼ 找不到
③ AP 自己儲存的 WLC IP（Locally Stored Controller IP Address）
  │ 之前設定過、或手動設定過 → 用該 IP 連 WLC
  ▼ 還是找不到
（補充）DHCP Option 43／DNS → 見第 6 節
```

## 3. 方法一：區域廣播（Local IP Subnet Discovery）

**做什麼**：AP 先用廣播的方式，在自己所在的網段尋找 WLC。**AP 與 WLC 在同一網段**時，這是最快也最簡單的方式。

**怎麼做**：只要把 AP 接上電源與網路就好。

**應該看到什麼**：AP 開機後自動出現在 WLC 的 AP 清單中。

## 4. 方法二：空中廣播（Over The Air Provisioning，OTAP）

**做什麼**：當網路線上廣播找不到 WLC 時，第二步改用無線電波，找看看**附近有沒有其他 AP 已經有 WLC 的資訊**，有的話就跟著找到 WLC。

**怎麼做**：把新 AP 放在**已經加入 WLC 的瘦 AP 附近**。

> 補充：新版 WLC 預設通常已關閉 OTAP，以官方文件為準（未實測）。若依賴這個方法加入不了，請改用其他方法。

## 5. 方法三：AP 自己儲存的 WLC IP（Locally Stored Controller IP Address）

**做什麼**：如果空中也聽不到其他 AP，第三步就是看**AP 自己有沒有被設定過 WLC 的資訊**（WLC 的 IP 位址），有的話就直接用這個 IP 去找 WLC。

**怎麼做**：用 Console 線接到 AP，在 CLI 輸入下列指令，告訴 AP 控制器在哪：

```text
lwapp ap controller ip add x.x.x.x
```

如果環境**沒有 DHCP**可以先分配 IP 給 AP，就要先替瘦 AP 設定自己的 IP：

```text
lwapp ap ip address x.x.x.x x.x.x.x
```

| 片段 | 意思 |
| --- | --- |
| `lwapp ap controller ip add x.x.x.x` | 告訴 AP「WLC 的 IP 是 x.x.x.x」（把第一個 x.x.x.x 換成 WLC 的位址） |
| `lwapp ap ip address x.x.x.x x.x.x.x` | 手動指定 AP 自己的 IP 與子網路遮罩（前者是 IP、後者是遮罩） |

> **語法版本提醒**：上面是舊版 LWAPP 的指令。新版（CAPWAP）AP 的對應語法推測為 `capwap ap controller ip address <WLC IP>`、`capwap ap ip address <AP IP> <遮罩>`，**未在原作者環境實測**，請以你的 AP 韌體與 Cisco 官方文件為準。

**應該看到什麼**：AP 重新開機或重新啟動 Discovery 後，出現在 WLC 的 AP 清單中。

## 6. 補充：大型或跨網段環境常用的方法（非原文內容）

> 原文只列出上面三種「比較常用的方法」；以下是 Cisco 官方文件中常見的另外兩種，補充給跨網段環境參考，未在原作者環境實測。

| 方式 | 原理 | 你要做什麼 |
| --- | --- | --- |
| DHCP Option 43 | DHCP 發 IP 給 AP 時，順便帶上 WLC 的位址 | 在 DHCP 伺服器設定 Option 43 |
| DNS | AP 查詢 `CISCO-CAPWAP-CONTROLLER.<網域>`（舊版為 `CISCO-LWAPP-CONTROLLER`） | 在 DNS 建立這筆記錄，指向 WLC |

## 7. 常見問題

| 現象 | 怎麼辦 |
| --- | --- |
| AP 一直重開或燈號循環 | 先確認 AP 有沒有拿到 IP；沒有 DHCP 就用方法三手動設定 AP 的 IP |
| 跨網段加入不了 | 廣播過不了路由器，改用方法三、DHCP Option 43 或 DNS |
| 只靠 OTAP 加入不了 | 新版 WLC 預設可能已關閉 OTAP；改用其他方法 |
| 手動指定後仍加入不了 | 確認 AP 與 WLC 之間路由、防火牆是否放行 CAPWAP／LWAPP 相關連接埠；以官方文件為準 |
| 加入後馬上掉線 | WLC 韌體是否支援這個 AP 型號 |
| 指令打了顯示不認識 | 韌體較新，LWAPP 語法已換成 CAPWAP，請改用新版指令 |

## 8. 待辦

- [ ] 用實體 AP 實測 CAPWAP 版指令，補上實際輸出

## 9. 延伸閱讀

- [Cisco：Lightweight AP (LAP) Registration to a WLC](https://www.cisco.com/c/en/us/support/docs/wireless/5500-series-wireless-controllers/119286-lap-notjoin-wlc-tshoot.html)
- [Cisco 2504 無線控制器（一）：Console 初始設定精靈](../cisco-wlc2504-setup-1-wizard/)
- [Cisco 胖 AP 基本設定](../cisco-autonomous-ap-basic/)
- [Blogger 原文](https://kbwangtw.blogspot.com/2015/10/cisco-apcontroller-1.html)
