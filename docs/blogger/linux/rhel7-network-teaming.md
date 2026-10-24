---
layout: default
title: "RHEL 7 的 Network Teaming（摘要）"
date: 2014-12-29
categories: [Linux, RHEL, Network, Blogger 舊文, 轉貼摘要]
permalink: /docs/blogger/linux/rhel7-network-teaming/
last_modified_at: 2026-10-24
---

# RHEL 7 的 Network Teaming（摘要）

> **一句話**：RHEL 7 除了傳統的 Bonding，多了 **teamd（Network Teaming）** 可以把多張網卡組合使用；設定方式和 bonding 類似：建一個 `team0` 介面，指定 runner（例如 activebackup），再把實體網卡設為它的 TeamPort。

| 項目 | 內容 |
| --- | --- |
| 適合誰看 | 維護 RHEL／CentOS 7 的人 |
| 性質 | **轉貼摘要**：原文轉貼自恆逸教育訓練中心的技術文章，這裡只整理概念，設定細節請看原文 |
| 日期 | 2014-12-29（原轉貼於 Blogger，2026-10-24 改為摘要） |

> Red Hat 已在 RHEL 9 將 teamd 標為**棄用**，新系統建議回到 bonding（用 `nmcli` 設定）。

## 1. 先認識幾個名詞

| 名詞 | 白話解釋 |
| --- | --- |
| **teamd** | RHEL 7 新的網卡組合服務 |
| **runner** | Team 的運作模式，例如 activebackup（主備）、loadbalance、lacp |
| **TeamPort** | 加入 team 的實體網卡 |

## 2. 重點整理

```text
ifcfg-team0      ：DEVICETYPE=Team，TEAM_CONFIG 指定 runner，設定 IP
ifcfg-team0-eth0 ：DEVICETYPE=TeamPort，TEAM_MASTER=team0
ifcfg-team0-eth1 ：DEVICETYPE=TeamPort，TEAM_MASTER=team0
→ 重新啟動 NetworkManager 即生效
```

| Bonding | Teaming |
| --- | --- |
| 核心模組 | 使用者空間的 teamd 服務 |
| `mode=1` 主備 | runner `activebackup` |
| `mode=4` LACP | runner `lacp` |

## 3. 延伸閱讀

- [原文（恆逸教育訓練中心）](http://www.uuu.com.tw/Public/content/article/141229tips.htm)
- [Ubuntu 12.04 雙網卡 Bonding：7 種模式比較](../ubuntu-1204-bonding/)
- [Blogger 轉貼頁](https://kbwangtw.blogspot.com/2014/12/rhel-7network-teaming.html)
