---
layout: default
title: "Cisco 2504 無線控制器基本設定（三）：應用程式統計與 5 GHz 頻道調整"
date: 2015-10-15
categories: [Network, Cisco, Wireless, Blogger 舊文]
permalink: /docs/blogger/network/cisco-wlc2504-setup-3-rf-tuning/
last_modified_at: 2026-10-24
---

# Cisco 2504 無線控制器基本設定（三）：應用程式統計與 5 GHz 頻道調整

> **一句話**：開啟 **Application Visibility** 才能在 Monitor 看到用戶在用哪些應用；5 GHz 頻寬設成 **80 MHz**、相鄰 AP 手動錯開頻道；確定沒有老舊網卡的話，關掉低速率減少干擾。

| 項目 | 內容 |
| --- | --- |
| 適合誰看 | WLC 已能上網，想看流量統計、調整無線品質的人 |
| 環境 | Cisco 2504 + AP1702I（802.11ac），接續（二） |
| 日期 | 2015-10-15（原文發表於 Blogger，2026-10-24 改寫為新手版） |
| 結論 | ✅ Monitor 顯示應用程式統計 ✅ 5 GHz 80 MHz、手動頻道 ✅ 關閉 54 Mbps 以下速率 |

## 1. 先認識幾個名詞

| 名詞 | 白話解釋 |
| --- | --- |
| **Application Visibility（AVC）** | 辨識流量屬於哪個應用（網頁、影音、社群等）並統計 |
| **頻道（Channel）** | 無線電波使用的頻率區段；相鄰 AP 用同頻道會互相干擾 |
| **頻寬（Channel Width）** | 一次用多寬的頻率；80 MHz 速度快，但佔用 4 個 20 MHz 頻道 |
| **Global／Custom** | 頻道由 WLC 自動決定／手動指定 |
| **Data Rate（速率）** | 無線連線允許的速度；低速率是給舊網卡用的，會拖慢整體效率 |

## 2. 調整項目一覽

```text
① WLANs → WLAN → QoS：Application Visibility = Enabled
② WIRELESS → Access Points → Radios → 802.11a/n/ac → 選 AP → Configure
     頻寬 80 MHz、頻道 Custom（相鄰 AP 錯開）
③ WIRELESS → 802.11a/n/ac → High Throughput：關閉 54 Mbps 以下
```

## 3. 步驟一：開啟應用程式統計

**怎麼做**：**WLANs** → 點 WLAN ID → **QoS** 頁 → **Application Visibility** 勾選 Enabled → Apply。

**應該看到什麼**：一段時間後，**Monitor** 頁出現「Applications by usage」圓餅圖，列出 http、ssl、各大網站服務等流量比例。

![Monitor 頁的應用程式統計（原作者截圖）]({{ '/docs/blogger/network/images/wlc2504-application-visibility.png' | relative_url }})

## 4. 步驟二：調整 5 GHz 頻寬與頻道

**怎麼做**：**WIRELESS** → **Access Points** → **Radios** → **802.11a/n/ac** → 要調整的 AP 右邊選 **Configure**：

| 欄位 | 設定 |
| --- | --- |
| Channel Width | **80 MHz** |
| Assignment Method | **Custom**，從 153、149、157、161 中選一個 |

![RF Channel Assignment：80 MHz、Custom 153（原作者截圖）]({{ '/docs/blogger/network/images/wlc2504-rf-channel-80mhz.png' | relative_url }})

**頻道怎麼分**：

```text
AP 很靠近 → 一定要用不同頻道，否則互相干擾
AP 距離遠 → 可以重複使用同一頻道（訊號傳不到彼此）
```

> 注意：80 MHz 會把 149～161 四個頻道當成一組；兩台相鄰 AP 都設 80 MHz 時，從這組裡選不同主頻道仍會重疊。AP 多、距離近時，改用 40 MHz 或分配到其他頻段較好（建議，未實測）。

## 5. 步驟三：關掉用不到的低速率

**前提**：確定環境中**沒有**只支援 802.11a／b 的舊網卡。

**怎麼做**：**WIRELESS** → **802.11a/n/ac** → **High Throughput (802.11n/ac)**，把 54 Mbps 以下的速率取消勾選 → Apply → Save Configuration。

![High Throughput 速率清單（原作者截圖）]({{ '/docs/blogger/network/images/wlc2504-data-rates.png' | relative_url }})

**為什麼**：只要有一台裝置用低速率連線，它佔用空中時間就特別久，大家都會變慢；關掉後干擾和等待都會減少。

## 6. 常見問題

| 現象 | 怎麼辦 |
| --- | --- |
| Monitor 沒有應用程式圖表 | Application Visibility 沒開，或開啟後還沒有足夠流量 |
| Channel Width 選項是灰的 | 要先把 Assignment Method 改成 Custom |
| 改完後某些舊電腦連不上 | 關掉的低速率是它需要的；把對應速率開回來 |
| 兩台 AP 中間訊號很差 | 頻道重疊；錯開頻道或縮小頻寬 |

## 7. 延伸閱讀

- [Cisco 2504 無線控制器（二）：用網頁設定兩個 SSID 與密碼](../cisco-wlc2504-setup-2-ssid/)
- [Blogger 原文](https://kbwangtw.blogspot.com/2015/10/cisco-2504-wireless-controller_15.html)
