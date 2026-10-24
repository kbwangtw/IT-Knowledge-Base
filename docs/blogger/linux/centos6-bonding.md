---
layout: default
title: "CentOS 6.4 雙網卡綁定 bond0：ifcfg 與 modprobe 設定"
date: 2015-09-10
categories: [Linux, CentOS, Network, Blogger 舊文]
permalink: /docs/blogger/linux/centos6-bonding/
last_modified_at: 2026-10-24
---

# CentOS 6.4 雙網卡綁定 bond0：ifcfg 與 modprobe 設定

> **一句話**：CentOS 6 做雙網卡綁定要改四個地方：`ifcfg-bond0` 放 IP、`ifcfg-eth0`／`ifcfg-eth1` 標成 bond0 的成員（`MASTER=bond0`、`SLAVE=yes`），最後在 `/etc/modprobe.d/dist.conf` 載入 bonding 模組並指定 `mode=6`、`miimon=100`。

| 項目 | 內容 |
| --- | --- |
| 適合誰看 | 維護舊版 CentOS 6、想把兩張網卡合成一個邏輯網卡的人 |
| 環境 | CentOS 6.4；兩張網卡 eth0、eth1 |
| 日期 | 2015-09-10（原文發表於 Blogger，2026-10-24 改寫為新手版；原文為簡體中文，這裡改為繁體） |
| 結論 | ✅ bond0 設定檔與模組設定完成 ⏳ 重啟網路與驗證指令為補充，未在原作者環境實測 |

> ⚠️ CentOS 6 已於 2020 年停止支援，只適合維護舊系統。新系統（RHEL／Rocky 8 以後）請改用 `nmcli` 建立 bond。

## 1. 先認識幾個名詞

| 名詞 | 白話解釋 |
| --- | --- |
| **Bonding（網卡綁定）** | 把多張實體網卡合成一個邏輯網卡 bond0，一起提供頻寬或互相備援 |
| **bond0** | 綁定後的邏輯網卡，**IP 只設在這裡** |
| **Master／Slave** | bond0 是 Master（主），綁進去的 eth0、eth1 是 Slave（成員） |
| **`miimon=100`** | 每 100 毫秒檢查一次網路線／網卡連線狀態，斷線就切換 |
| **`mode=6`（balance-alb）** | 負載平衡＋容錯，**交換器不需要任何設定** |
| **ifcfg-ethX** | CentOS／RHEL 存放網卡設定的檔案，位於 `/etc/sysconfig/network-scripts/` |

## 2. 整體流程

```text
① 進入 /etc/sysconfig/network-scripts/ 看有哪些網卡設定檔
        │
② 複製 ifcfg-eth0 成 ifcfg-bond0
        │
③ 編輯三個檔案
   ifcfg-bond0 → IP、遮罩、閘道（IP 只設這裡）
   ifcfg-eth0  → MASTER=bond0, SLAVE=yes
   ifcfg-eth1  → MASTER=bond0, SLAVE=yes
        │
④ /etc/modprobe.d/dist.conf 加上 bonding 模組與 mode=6、miimon=100
        │
⑤ 重啟網路並驗證（補充）
```

## 3. 步驟一：查看主機網卡

**做什麼**：先確認系統有哪些網卡設定檔。

```text
[root@web ~]# cd /etc/sysconfig/network-scripts/
[root@web network-scripts]# ll
-rw-r--r--. 1 root root 212 Mar 20 22:15 ifcfg-eth0
-rw-r--r--  1 root root 212 Mar 23 19:10 ifcfg-eth1
```

**應該看到什麼**：有 `ifcfg-eth0` 與 `ifcfg-eth1` 兩個檔案。（原文的主機名稱在 `web` 與 `web1` 之間混用，應是同一台。）

## 4. 步驟二：複製出 ifcfg-bond0

**做什麼**：用 eth0 的設定檔當範本，複製成 bond0 的設定檔。

```text
[root@web network-scripts]# cp ifcfg-eth0 ifcfg-bond0
```

**應該看到什麼**：目錄下多了 `ifcfg-bond0`。

> 補充（非原文，未實測）：eth0 的檔案若含有 `HWADDR=`（網卡 MAC）或 `UUID=` 之類行，下一步編輯 bond0 時**要刪掉**，否則 bond0 可能綁到單一網卡的 MAC。

## 5. 步驟三：編輯三個設定檔

### 5-1 ifcfg-bond0（IP 設在這裡）

```text
[root@web network-scripts]# vim ifcfg-bond0
DEVICE=bond0
BOOTPROTO=static
IPADDR=192.0.2.210
NETMASK=255.255.255.0
GATEWAY=192.0.2.254
ONBOOT=yes
USERCTL=no
```

| 片段 | 意思 |
| --- | --- |
| `DEVICE=bond0` | 這張邏輯網卡的名稱 |
| `BOOTPROTO=static` | 固定 IP（不用 DHCP） |
| `IPADDR` `NETMASK` `GATEWAY` | IP、遮罩、閘道；範例使用文件示範網段，請換成你的 |
| `ONBOOT=yes` | 開機自動啟動 |
| `USERCTL=no` | 不允許一般使用者控制這張網卡 |

### 5-2 ifcfg-eth0

```text
[root@web1 network-scripts]# vim ifcfg-eth0
DEVICE=eth0
ONBOOT=yes
BOOTPROTO=none
MASTER=bond0
SLAVE=yes
USERCTL=no
```

### 5-3 ifcfg-eth1

```text
[root@web1 network-scripts]# vim ifcfg-eth1
DEVICE=eth1
ONBOOT=yes
BOOTPROTO=none
MASTER=bond0
SLAVE=yes
USERCTL=no
```

| 片段 | 意思 |
| --- | --- |
| `BOOTPROTO=none` | 這張實體網卡自己**不設 IP** |
| `MASTER=bond0` | 屬於 bond0 |
| `SLAVE=yes` | 身分是 bond0 的成員 |

**應該看到什麼**：eth0、eth1 兩個檔案內容幾乎一樣，只有 `DEVICE` 不同；IP 只出現在 `ifcfg-bond0`。

## 6. 步驟四：載入 bonding 模組

**做什麼**：告訴系統 bond0 使用 bonding 驅動程式，並指定運作模式。

```text
[root@web1 ~]# vim /etc/modprobe.d/dist.conf
```

在檔案最後面加入以下內容：

```text
# 載入 bonding 模組，對外虛擬網路介面設備為 bond0
alias bond0 bonding
options bond0 miimon=100 mode=6
```

| 片段 | 意思 |
| --- | --- |
| `alias bond0 bonding` | bond0 這個介面使用 bonding 模組 |
| `options bond0 miimon=100 mode=6` | 每 0.1 秒檢查連線狀態；使用 mode 6（balance-alb）：負載平衡＋容錯，**交換器不需設定** |

> 各模式（0～6）差異與怎麼選，請看 [Ubuntu 12.04 雙網卡 Bonding](../ubuntu-1204-bonding/) 的模式比較表。原作者在 Ubuntu 一篇推薦 mode 6。

## 7. 步驟五：重啟網路與驗證（補充，非原文內容）

> 原文到上一步為止。以下是常見的收尾做法，**未在原作者環境實測**。

```text
[root@web ~]# service network restart
[root@web ~]# cat /proc/net/bonding/bond0
```

**應該看到什麼**：`/proc/net/bonding/bond0` 顯示 `Bonding Mode: adaptive load balancing`（mode 6）、`MII Status: up`，並列出 eth0、eth1 兩個 Slave Interface。

> ⚠️ 遠端 SSH 操作時，`service network restart` 可能讓你斷線。請在主機旁或透過 Console、iDRAC／iLO 等管理介面進行。

## 8. 常見問題

| 現象 | 怎麼辦 |
| --- | --- |
| `cat /proc/net/bonding/bond0` 找不到檔案 | bonding 模組沒載入：檢查 `/etc/modprobe.d/dist.conf` 內容，或 `modprobe bonding` 手動載入試試 |
| bond0 起來了但不通 | 檢查 IP、遮罩、閘道；確認 eth0／eth1 的 `MASTER`、`SLAVE` 沒打錯 |
| 重啟後只有一張網卡有作用 | 檢查另一張網卡的網路線、交換器 Port；看 `/proc/net/bonding/bond0` 的 MII Status |
| 複製出來的 bond0 綁到某一張網卡的 MAC | 刪除 `ifcfg-bond0` 裡的 `HWADDR` 行（補充，未實測） |
| mode 0／4 設定後反而斷線 | 這兩種需要交換器設定 Port Channel／LACP；沒設就用 mode 6 |
| 想用在新系統 | CentOS 6 已停止支援；新系統請改用 `nmcli` 建立 bond，或看〈RHEL 7 Network Teaming〉 |

## 9. 待辦

- [ ] 在舊環境實測第 7 節的重啟與驗證輸出，補上實際畫面

## 10. 延伸閱讀

- [Ubuntu 12.04 雙網卡 Bonding：設定檔與 7 種模式怎麼選](../ubuntu-1204-bonding/)
- [RHEL 7 的 Network Teaming](../rhel7-network-teaming/)
- [Blogger 原文](https://kbwangtw.blogspot.com/2015/09/centos-64.html)
