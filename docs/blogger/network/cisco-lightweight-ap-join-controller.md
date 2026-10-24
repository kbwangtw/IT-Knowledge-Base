---
layout: default
title: "Cisco 瘦 AP 怎麼找到無線控制器（摘要）"
date: 2015-10-08
categories: [Network, Cisco, Wireless, Blogger 舊文, 轉貼摘要]
permalink: /docs/blogger/network/cisco-lightweight-ap-join-controller/
last_modified_at: 2026-10-24
---

# Cisco 瘦 AP 怎麼找到無線控制器（摘要）

> **一句話**：瘦 AP 開機後會依序嘗試幾種方法尋找 WLC：同網段廣播、從附近 AP 聽到的資訊、自己記住的 WLC 位址；跨網段的大型環境則常用 DHCP Option 43 或 DNS 告訴 AP 控制器在哪。

| 項目 | 內容 |
| --- | --- |
| 適合誰看 | AP 插上去卻一直加入不了 WLC 的人 |
| 性質 | **摘要**：原文未註明出處，推測為整理自他人文章（未確認），這裡只用自己的話整理重點 |
| 日期 | 2015-10-08（原發表於 Blogger，2026-10-24 改為摘要） |

## 1. 先認識幾個名詞

| 名詞 | 白話解釋 |
| --- | --- |
| **瘦 AP（Lightweight AP）** | 要靠 WLC 才能運作的 AP |
| **Discovery** | AP 尋找 WLC 的過程 |
| **DHCP Option 43** | DHCP 發 IP 時順便告訴 AP「WLC 的位址是什麼」 |

## 2. AP 尋找控制器的常見方式

| 方式 | 原理 | 你要做什麼 |
| --- | --- | --- |
| 同網段廣播 | AP 和 WLC 在同一網段，廣播一下就找到 | AP 接電、接網路即可；最簡單 |
| 鄰近 AP 告知（OTAP） | 附近已加入的 AP 透過無線電告訴新 AP | 新 AP 放在已加入的 AP 旁邊；新版 WLC 預設關閉此功能 |
| AP 自己記住的位址 | 以前加入過或手動設定過 WLC 位址 | 用 Console 在 AP 上設定 WLC 位址 |
| DHCP Option 43 | DHCP 回應裡帶 WLC 位址 | 在 DHCP 伺服器設定 Option 43 |
| DNS | AP 查詢 `CISCO-CAPWAP-CONTROLLER.<網域>` | 在 DNS 建立這筆記錄指向 WLC |

```text
AP 開機 → 拿到 IP → 依序嘗試上面各種方式 → 收到 WLC 回應 → 加入並下載設定
```

> 原文的手動設定指令是較舊的 LWAPP 語法；新版 AP（CAPWAP）指令格式不同，請以官方文件為準。

## 3. 排錯小提示

| 現象 | 先檢查 |
| --- | --- |
| AP 一直重開或燈號循環 | AP 有沒有拿到 IP；和 WLC 是否同網段 |
| 跨網段加入不了 | DHCP Option 43 或 DNS 記錄有沒有設定 |
| 加入後馬上掉線 | WLC 韌體是否支援這個 AP 型號 |

## 4. 延伸閱讀

- [Cisco：Lightweight AP (LAP) Registration to a WLC](https://www.cisco.com/c/en/us/support/docs/wireless/5500-series-wireless-controllers/119286-lap-notjoin-wlc-tshoot.html)
- [Cisco 2504 無線控制器（一）：Console 初始設定精靈](../cisco-wlc2504-setup-1-wizard/)
- [Blogger 原文](https://kbwangtw.blogspot.com/2015/10/cisco-apcontroller-1.html)
