---
layout: default
title: "RHEL 7 的 Network Teaming（摘要）"
date: 2014-12-29
categories: [Linux, RHEL, Network, Blogger 舊文, 轉貼摘要]
permalink: /docs/blogger/linux/rhel7-network-teaming/
last_modified_at: 2026-10-30
---

# RHEL 7 的 Network Teaming（摘要）

> **一句話**：RHEL 7 除了傳統的 Bonding，多了 **teamd（Network Teaming）** 可以把多張網卡組合使用；設定方式和 bonding 類似：建一個 `team0` 介面，指定 runner（例如 activebackup），再把實體網卡設為它的 TeamPort。

| 項目 | 內容 |
| --- | --- |
| 適合誰看 | 維護 RHEL／CentOS 7 的人 |
| 性質 | **轉貼摘要**：原文轉貼自恆逸教育訓練中心的技術文章，這裡只整理概念；第 3 節設定範例依 Red Hat 官方文件補充（原站已失效） |
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

## 3. 設定範例（依 Red Hat 官方文件整理，非原文內容）

> 原文網站已消失，以下整理自 RHEL 7 Networking Guide 第 8 章〈Configure Network Teaming〉，不是原文作者寫的。IP 為範例，網卡名稱請換成自己的。

### 3-1 安裝 teamd

teamd 預設**沒有安裝**，要先裝：

```text
yum install teamd
```

### 3-2 建立 ifcfg 檔

都放在 `/etc/sysconfig/network-scripts/`。

team 介面（`ifcfg-team0`）：

```text
DEVICE=team0
DEVICETYPE=Team
ONBOOT=yes
BOOTPROTO=none
IPADDR=192.0.2.1
PREFIX=24
TEAM_CONFIG='{"runner": {"name": "activebackup"}, "link_watch": {"name": "ethtool"}}'
```

每張實體網卡各一個檔（例如 `ifcfg-team0-enp1s0`）：

```text
DEVICE=enp1s0
HWADDR=<MAC 位址>
DEVICETYPE=TeamPort
ONBOOT=yes
TEAM_MASTER=team0
TEAM_PORT_CONFIG='{"prio": 100}'
```

| 片段 | 意思 |
| --- | --- |
| `DEVICETYPE=Team`／`TeamPort` | 這個檔是 team 介面本身／加入 team 的網卡 |
| `TEAM_CONFIG` 的 `runner` | 運作模式，這裡是主備（activebackup） |
| `link_watch: ethtool` | 用網卡連線狀態判斷哪條線斷了 |
| `TEAM_MASTER=team0` | 這張網卡屬於 team0 |
| `TEAM_PORT_CONFIG` 的 `prio` | 優先順序，數字大的優先當主要線路 |

### 3-3 啟用並確認

```text
ifup team0
teamdctl team0 state view
```

應該看到什麼：`teamdctl` 顯示 runner 是 `activebackup`，列出兩張網卡，其中一張是目前使用中（active port）。拔掉使用中的那條線，再執行一次，active port 應該換成另一張。

| 其他常用 `teamdctl` 指令 | 用途 |
| --- | --- |
| `teamdctl team0 state view -v` | 顯示更詳細的狀態 |
| `teamdctl team0 config dump` | 以 JSON 顯示目前設定 |
| `teamdctl team0 port remove enp1s0` | 把網卡移出 team |

官方文件也提到：RHEL 7 的 teaming **不是取代** bonding，兩者都能用；runner 除了 activebackup，還有 broadcast、random、roundrobin、loadbalance、lacp（lacp 需要交換器端也設定 link aggregation）。

## 4. 延伸閱讀

- [原文（恆逸教育訓練中心，原站已無法連線，改連 Wayback Machine 2015-01-02 封存版）](https://web.archive.org/web/20150102060419/http://www.uuu.com.tw:80/Public/content/article/141229tips.htm)
- [Red Hat 文件：RHEL 7 Networking Guide 第 8 章 Configure Network Teaming](https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/7/html/networking_guide/ch-configure_network_teaming)
- [Ubuntu 12.04 雙網卡 Bonding：7 種模式比較](../ubuntu-1204-bonding/)
- [Blogger 轉貼頁](https://kbwangtw.blogspot.com/2014/12/rhel-7network-teaming.html)
