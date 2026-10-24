---
layout: default
title: "CentOS 6 雙網卡綁定 bond0（摘要）"
date: 2015-09-10
categories: [Linux, CentOS, Network, Blogger 舊文, 轉貼摘要]
permalink: /docs/blogger/linux/centos6-bonding/
last_modified_at: 2026-10-24
---

# CentOS 6 雙網卡綁定 bond0（摘要）

> **一句話**：CentOS 6 用 `ifcfg-bond0` 設定 IP，`ifcfg-eth0`、`ifcfg-eth1` 標成 bond0 的成員（`MASTER=bond0`、`SLAVE=yes`），再在 modprobe 設定中載入 bonding 模組並指定模式。

| 項目 | 內容 |
| --- | --- |
| 適合誰看 | 維護舊版 CentOS 6 的人 |
| 性質 | **摘要**：原文為簡體中文、未註明出處，推測為轉貼（未確認），這裡只用自己的話整理流程 |
| 日期 | 2015-09-10（原發表於 Blogger，2026-10-24 改為摘要） |

> CentOS 6 已於 2020 年停止支援。新系統（RHEL／Rocky 8 以後）請改用 `nmcli` 建立 bond。

## 1. 流程重點

```text
① /etc/sysconfig/network-scripts/ 複製 ifcfg-eth0 為 ifcfg-bond0
② ifcfg-bond0：DEVICE=bond0、BOOTPROTO=static、填 IP／遮罩／閘道、ONBOOT=yes
③ ifcfg-eth0、ifcfg-eth1：BOOTPROTO=none、MASTER=bond0、SLAVE=yes、ONBOOT=yes
④ /etc/modprobe.d/ 的設定檔加入：bond0 使用 bonding 模組，miimon=100、mode=6
⑤ 重啟網路服務，用 cat /proc/net/bonding/bond0 確認
```

| 設定 | 放在哪 | 意思 |
| --- | --- | --- |
| IP、閘道 | `ifcfg-bond0` | IP 只設在 bond0 |
| `MASTER=bond0`、`SLAVE=yes` | `ifcfg-eth0`、`ifcfg-eth1` | 宣告這張卡屬於 bond0 |
| `mode=6`、`miimon=100` | modprobe 設定 | balance-alb 模式、每 0.1 秒檢查連線 |

各模式的差異請看〈Ubuntu 12.04 雙網卡 Bonding〉的模式比較表。

## 2. 延伸閱讀

- [Ubuntu 12.04 雙網卡 Bonding：設定檔與 7 種模式怎麼選](../ubuntu-1204-bonding/)
- [Blogger 原文](https://kbwangtw.blogspot.com/2015/09/centos-64.html)
