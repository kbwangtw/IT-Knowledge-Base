---
layout: default
title: "FortiGate IP/MAC 綁定（摘要與原文連結）"
date: 2021-09-02
categories: [Network, Fortinet, Firewall, Blogger 舊文, 轉貼摘要]
permalink: /docs/blogger/network/fortigate-ip-mac-binding/
last_modified_at: 2026-10-24
---

# FortiGate IP/MAC 綁定（摘要與原文連結）

> **一句話**：IP/MAC 綁定讓 FortiGate 檢查「這個 IP 是不是由指定的那張網卡送出」，對不上就擋；通常搭配 DHCP 保留位址一起設定。

| 項目 | 內容 |
| --- | --- |
| 適合誰看 | 想限制內網只有登記過的電腦才能上網的人 |
| 性質 | **轉貼摘要**：原文為他人撰寫，這裡只整理重點，指令細節請看原文與官方文件 |
| 日期 | 2021-09-02（原轉貼於 Blogger，2026-10-24 改為摘要） |

## 1. 先認識幾個名詞

| 名詞 | 白話解釋 |
| --- | --- |
| **MAC 位址** | 網卡出廠時的硬體編號 |
| **IP/MAC 綁定（Binding）** | 把 IP 和 MAC 配成一對，防火牆只放行配對正確的封包 |
| **DHCP 保留位址（Reserved address）** | 讓 DHCP 永遠發同一個 IP 給同一張網卡 |

## 2. 重點整理

```text
① DHCP 保留位址（固定 IP 的設備可略過）
② 建 IP/MAC 綁定表
③ 開啟防火牆的綁定檢查（出外網、連防火牆本身、未登記主機要不要擋）
④ 在內網介面啟用 IP/MAC 檢查
```

- 四件事都在 FortiOS CLI 完成；第 ④ 步沒做，前面設了也不會檢查。
- 第 ④ 步的介面名稱要依實際接線（例如 `internal` 或 `internal1`）。

## 3. 原文提醒的注意事項（摘要）

| 注意事項 | 說明 |
| --- | --- |
| 改 IP 時機 | 最好等使用者關機後再改，讓設備重新拿 IP；不能停機就要小心 IP 衝突 |
| DHCP 範圍 | 有保留表，陌生電腦仍可能從 DHCP 拿到 IP，要控制發放範圍 |
| 同網段伺服器 | 綁定只管經過防火牆的流量；同網段的伺服器，使用者自己設 IP 仍連得到 |

## 4. 延伸閱讀

- [原文（Ivan IT' Notes，他人撰寫）](http://it-ivan.blogspot.com/2011/08/fortigate-ipmac.html)
- [Fortinet 文件庫](https://docs.fortinet.com/)
- [Blogger 轉貼頁](https://kbwangtw.blogspot.com/2021/09/fortigate-ipmac.html)
