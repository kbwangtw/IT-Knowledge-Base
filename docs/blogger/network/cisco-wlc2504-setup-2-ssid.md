---
layout: default
title: "Cisco 2504 無線控制器基本設定（二）：用網頁設定兩個 SSID 與密碼"
date: 2015-10-08
categories: [Network, Cisco, Wireless, Blogger 舊文]
permalink: /docs/blogger/network/cisco-wlc2504-setup-2-ssid/
last_modified_at: 2026-10-24
---

# Cisco 2504 無線控制器基本設定（二）：用網頁設定兩個 SSID 與密碼

> **一句話**：用瀏覽器登入 WLC，把精靈建好的 SSID 改成「廣播 + WPA2-PSK 密碼」，再新增第二個 SSID 用同樣方式設定，最後 **Apply** 並 **Save Configuration**。

| 項目 | 內容 |
| --- | --- |
| 適合誰看 | WLC 精靈跑完、要設定 SSID 密碼的人 |
| 環境 | Cisco 2504，接續（一）；SSID：Contoso、Contoso-1 |
| 日期 | 2015-10-08（原文發表於 Blogger，2026-10-24 改寫為新手版） |
| 結論 | ✅ 兩個 SSID 都啟用、廣播、使用預先共用金鑰（PSK） |

## 1. 先認識幾個名詞

| 名詞 | 白話解釋 |
| --- | --- |
| **WLAN ID** | WLC 裡每個 SSID 的編號，精靈建的是 1 |
| **Broadcast SSID** | 讓手機、筆電的無線清單看得到這個名稱 |
| **Layer 2 Security** | 無線連線本身的加密與驗證方式 |
| **PSK（Pre-Shared Key）** | 大家共用一組密碼，不需要 RADIUS 伺服器 |
| **AES／TKIP** | 加密演算法；**AES 是目前標準，TKIP 已淘汰** |
| **Apply／Save Configuration** | Apply 讓設定生效；Save Configuration 才會寫入，重開機不會消失 |

## 2. 流程

```text
瀏覽器登入 WLC → Advanced
  → WLANs → WLAN ID 1（Contoso）
      General：Broadcast SSID 打勾
      Security → Layer 2：WPA2 + AES、PSK、輸入密碼 → Apply
  → Create New → Contoso-1 → Status 打勾 → 同樣設定 Layer 2 → Apply
  → Save Configuration
```

## 3. 步驟一：登入並切到進階介面

**怎麼做**：瀏覽器開啟 `https://<WLC 管理 IP>`，用（一）設定的管理帳密登入，點畫面上的 **Advanced** 進入完整設定介面。

## 4. 步驟二：修改第一個 SSID

1. 上方選 **WLANs**，點 WLAN ID 的數字 **1**。

![WLANs 清單（原作者截圖）]({{ '/docs/blogger/network/images/wlc2504-wlans-list.png' | relative_url }})

2. **General** 頁：確認 **Status** 是 Enabled，**Broadcast SSID** 打勾。

![General 頁面：Status、Broadcast SSID（原作者截圖）]({{ '/docs/blogger/network/images/wlc2504-wlan-general.png' | relative_url }})

3. **Security → Layer 2**：Layer 2 Security 選 **WPA+WPA2**，勾選 **WPA2 Policy** 與加密方式。

![Layer 2 安全性設定（原作者截圖）]({{ '/docs/blogger/network/images/wlc2504-layer2-security.png' | relative_url }})

4. **Authentication Key Management**：取消 802.1X、勾選 **PSK**，PSK Format 選 ASCII，輸入無線密碼。

![PSK 設定（原作者截圖）]({{ '/docs/blogger/network/images/wlc2504-wpa-psk.png' | relative_url }})

5. 按右上角 **Apply**。

> 原文（2015 年）勾選了 WPA Policy 與 TKIP，是為了相容當年的舊網卡。**現在建議只勾 WPA2 Policy + AES**，不要開 WPA／TKIP，安全性較高，速度也不會被拖慢。

## 5. 步驟三：新增第二個 SSID

1. WLANs 頁右上選 **Create New** → **Go**。
2. 輸入 Profile Name 和 SSID：`Contoso-1`，按 **Apply**。
3. 在 General 頁把 **Status** 勾選為 Enabled。

![第二個 SSID 的 General 頁（原作者截圖）]({{ '/docs/blogger/network/images/wlc2504-second-ssid.png' | relative_url }})

4. 照步驟二的第 3～4 點設定 **Security → Layer 2** 和 PSK 密碼。
5. 按 **Apply**。

## 6. 步驟四：存檔

**怎麼做**：按畫面右上方的 **Save Configuration**。

**應該看到什麼**：WLANs 清單出現兩筆，Admin Status 都是 Enabled，Security Policies 顯示 `[WPA2][Auth(PSK)]`；手機搜尋得到兩個 SSID，輸入密碼可以連上。

## 7. 常見問題

| 現象 | 怎麼辦 |
| --- | --- |
| 手機看不到 SSID | Broadcast SSID 沒勾、Status 沒啟用，或 AP 還沒加入 WLC |
| 重開機後新 SSID 不見 | 只按了 Apply，沒按 Save Configuration |
| 舊設備連不上 | 可能只支援 WPA／TKIP；建議汰換設備，而不是降低整個網路的安全性 |
| Security Policies 還是顯示 802.1X | Authentication Key Management 的 802.1X 沒取消 |

## 8. 延伸閱讀

- [Cisco 2504 無線控制器（一）：Console 初始設定精靈](../cisco-wlc2504-setup-1-wizard/)
- [Cisco 2504 無線控制器（三）：應用程式統計與 5 GHz 頻道調整](../cisco-wlc2504-setup-3-rf-tuning/)
- [Blogger 原文](https://kbwangtw.blogspot.com/2015/10/cisco-2504-wireless-controller_8.html)
