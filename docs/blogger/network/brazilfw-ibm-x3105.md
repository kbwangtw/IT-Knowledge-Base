---
layout: default
title: "用舊伺服器 IBM X3105 裝 BrazilFW 免費路由器，補上流量監控"
date: 2013-10-30
categories: [Network, Firewall, Linux, Blogger 舊文]
permalink: /docs/blogger/network/brazilfw-ibm-x3105/
last_modified_at: 2026-10-24
---

# 用舊伺服器 IBM X3105 裝 BrazilFW 免費路由器，補上流量監控

> **一句話**：使用者反映網路慢，但 Juniper NS-5GT／SSG-20 沒有流量統計圖；拿一台閒置的 IBM X3105 裝免費路由軟體 BrazilFW 3.0.258，換上相容網卡、改用固定 IP 撥接，並加裝 BandwidthD、L7 Firewall、DansGuardian 等套件來觀察流量。

| 項目 | 內容 |
| --- | --- |
| 適合誰看 | 想用舊電腦做一台有流量監控的路由器的人 |
| 環境 | IBM X3105 伺服器、Intel PRO/100 桌上型網卡 × 2、BrazilFW 3.0.258（32 位元） |
| 日期 | 2013-10-30（原文發表於 Blogger，2026-10-24 改寫為新手版） |
| 結論 | ✅ BrazilFW 安裝完成並可上網 ✅ 加裝監控與過濾套件 |

> BrazilFW 已多年未更新，現在要做同樣的事，建議改用 pfSense 或 OPNsense。

## 1. 先認識幾個名詞

| 名詞 | 白話解釋 |
| --- | --- |
| **BrazilFW** | 以 Linux 為基礎的免費路由／防火牆系統，可裝在舊電腦上 |
| **PPPoE** | ADSL／光世代的撥接上網方式 |
| **BandwidthD** | 依 IP 統計流量並畫圖的工具 |
| **L7 Firewall** | 依應用程式類型（第 7 層）辨識與過濾流量 |
| **DansGuardian** | 網頁內容過濾 |
| **SqStat** | 查看 Squid 代理伺服器即時連線 |

## 2. 安裝過程重點

```text
下載 BrazilFW 3.0.258 ISO → 安裝到 IBM X3105
  → 內建網卡不支援 → 換兩張 Intel PRO/100
  → 外網卡 eth1 從固定 IP 改 PPPoE → 連不上（疑似 bug）
  → 刪除原本的 Internet 連線，重新新增「固定 IP 撥接」→ 正常
  → 安裝外掛套件
```

## 3. 踩到的兩個雷

| 問題 | 處理方式 |
| --- | --- |
| IBM X3105 主機板內建網卡，BrazilFW 抓不到 | 改用兩張舊的 Intel PRO/100 桌上型網卡，相容性良好 |
| 把外網卡從固定 IP 改成 PPPoE 後無法連線 | 不要直接修改；**刪除原本的 Internet 連線，重新新增一個**，直接設定為固定 IP 撥接 |

## 4. 加裝套件

部分套件內建，部分要另外下載安裝：

![BrazilFW 的 Addons 選單（原作者截圖）]({{ '/docs/blogger/network/images/brazilfw-addons-menu.png' | relative_url }})

| 套件 | 用途 | 備註 |
| --- | --- | --- |
| BandwidthD | 每個 IP 的流量統計圖 | **安裝前要先裝 Check System，並先啟動 MySQL** |
| L7 Firewall、SqStat | 應用程式過濾、代理伺服器連線監看 | 從 BrazilFW 社群的 addons 下載 |
| DansGuardian | 網頁內容過濾 | 從 BrazilFW 官方 addons 下載 |
| NTOP、MySAR、phpMyAdmin | 流量分析、Squid 報表、資料庫管理 | 選單中可見 |

## 5. 常見問題

| 現象 | 怎麼辦 |
| --- | --- |
| 開機後找不到網卡 | 換成 Intel 等相容性高的網卡 |
| 改撥接方式後不能上網 | 刪除舊的 Internet 連線重新建立 |
| BandwidthD 裝不起來 | 先裝 Check System、啟動 MySQL |

## 6. 延伸閱讀

- [在 IBM X3105 安裝 pfSense 2.1：Squid 透明代理與流量監控](../pfsense-ibm-x3105-squid/)
- [BrazilFW SourceForge 頁面](https://sourceforge.net/projects/brazilfw/)
- [Blogger 原文](https://kbwangtw.blogspot.com/2013/10/ibm-x3105-brazilfw-30258.html)
