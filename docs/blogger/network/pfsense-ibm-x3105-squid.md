---
layout: default
title: "在 IBM X3105 安裝 pfSense 2.1：Squid 透明代理、內容過濾與流量監控"
date: 2013-11-01
categories: [Network, pfSense, Firewall, Proxy, Blogger 舊文]
permalink: /docs/blogger/network/pfsense-ibm-x3105-squid/
last_modified_at: 2026-10-24
---

# 在 IBM X3105 安裝 pfSense 2.1：Squid 透明代理、內容過濾與流量監控

> **一句話**：在舊伺服器裝 pfSense 2.1，加裝 Squid（代理快取）、LightSquid（報表）、DansGuardian（內容過濾），把 Squid 設成**透明代理**，再用 NAT 把 80 Port 導到過濾服務；流量監控則參考官方文件的多種工具。

| 項目 | 內容 |
| --- | --- |
| 適合誰看 | 想用 pfSense 做上網快取、網頁過濾與流量監控的人 |
| 環境 | IBM X3105 伺服器；pfSense 2.1-RELEASE（i386 LiveCD） |
| 日期 | 2013-11-01（原文發表於 Blogger，2026-10-24 改寫為新手版） |
| 結論 | ✅ Squid 透明代理 ✅ DansGuardian 黑名單 ✅ 流量監控工具 |

> pfSense 2.1 與當年的套件（DansGuardian、LightSquid）多已停止維護。現在做同樣的事，請用新版 pfSense／OPNsense 內建的套件，概念相同。

## 1. 先認識幾個名詞

| 名詞 | 白話解釋 |
| --- | --- |
| **pfSense** | 以 FreeBSD 為基礎的免費防火牆系統 |
| **Squid** | 代理伺服器，可快取網頁、記錄上網紀錄 |
| **透明代理（Transparent Proxy）** | 使用者電腦不用設定 Proxy，防火牆自動把網頁流量導給 Squid |
| **Parent Proxy** | 代理再往上一層交給另一個代理處理 |
| **DansGuardian** | 網頁內容過濾，依黑名單或關鍵字擋網站 |
| **Port Forward（NAT）** | 把進來的某個 Port 轉到指定的位址與 Port |

## 2. 架構

```text
內網電腦 ──HTTP 80──▶ pfSense
                       │ NAT：LAN 的 80 → 過濾服務的 Port
                       ▼
                 DansGuardian（內容過濾）
                       │ Parent Proxy：127.0.0.1:3128
                       ▼
                 Squid（快取、紀錄）──▶ Internet
```

## 3. 步驟一：安裝 pfSense

下載 pfSense 2.1-RELEASE（i386 LiveCD）安裝到伺服器。基本安裝步驟原作者參考 Mobile01 上的教學文章（見延伸閱讀）。

## 4. 步驟二：安裝 Squid 相關套件

**怎麼做**：**System → Packages**，安裝 `squid`、`lightsquid`、`dansguardian` 三個套件。

| 套件 | 用途 |
| --- | --- |
| squid | 代理快取 |
| lightsquid | 依使用者與網站產生上網報表 |
| dansguardian | 內容過濾 |

## 5. 步驟三：Squid 設成透明代理

**怎麼做**：**Services → Proxy server → General settings**：

| 欄位 | 設定 |
| --- | --- |
| Proxy interface | LAN |
| Allow users on interface | 勾選 |
| Transparent proxy | **勾選** |
| Bypass proxy for Private Address Space destination | 勾選（連內網不走代理） |
| Enable logging | 勾選，Log 放在 `/var/squid/logs`，保留 7 天 |
| Proxy port | `3128` |

![Squid 一般設定：透明代理（原作者截圖）]({{ '/docs/blogger/network/images/pfsense-squid-transparent-proxy.png' | relative_url }})

## 6. 步驟四：DansGuardian 設定

| 設定頁 | 設定 |
| --- | --- |
| Parent proxy | Proxy IP `127.0.0.1`、Port `3128`（交給本機 Squid），逾時 30 秒 |
| Blacklist | List on：Banned only；Update frequency：Every day；Blacklist URL 填入公開的黑名單來源 |

![DansGuardian 黑名單設定（原作者截圖）]({{ '/docs/blogger/network/images/pfsense-dansguardian-blacklist.png' | relative_url }})

## 7. 步驟五：NAT 導流與防火牆規則

**怎麼做**：**Firewall → NAT → Port Forward** 新增一條：介面 LAN、協定 TCP、目的 Port HTTP，Redirect target IP 填 pfSense 的 LAN IP，Redirect target port 填 DansGuardian 監聽的 Port。

> 原文截圖中 Redirect target port 為 `8080`；請以 DansGuardian 設定的 Port 為準。

## 8. 流量監控工具

pfSense 官方文件列出多種監控方式，可依需要安裝：

| 工具 | 特點 |
| --- | --- |
| pftop、iftop、trafshow | 命令列即時查看 |
| 內建圖表（Status → Traffic Graph） | 不用安裝 |
| BandwidthD、Darkstat、NTOP | 依 IP 統計並畫圖 |
| Netflow、vnstat | 長期統計 |

原作者另外啟用了 miniupnp 和 NTOP（參考 Mobile01 教學）。

## 9. 常見問題

| 現象 | 怎麼辦 |
| --- | --- |
| HTTPS 網站沒被過濾 | 透明代理只攔得到 HTTP（80）；HTTPS 需要另外的解密機制 |
| 開啟 Squid 後內網服務連不到 | 勾選「Bypass proxy for Private Address Space」 |
| 黑名單沒有更新 | 確認黑名單網址仍有效、更新頻率設定 |

## 10. 延伸閱讀

- [用舊伺服器 IBM X3105 裝 BrazilFW](../brazilfw-ibm-x3105/)
- [pfSense 官方文件](https://docs.netgate.com/pfsense/en/latest/)
- [Mobile01：pfSense 安裝教學（原作者參考）](http://www.mobile01.com/topicdetail.php?f=300&t=251659&p=1)
- [Blogger 原文](https://kbwangtw.blogspot.com/2013/11/pfsense-21ibm-x3105-server.html)
