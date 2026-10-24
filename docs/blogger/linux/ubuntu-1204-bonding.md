---
layout: default
title: "Ubuntu 12.04 雙網卡 Bonding：設定檔與 7 種模式怎麼選"
date: 2014-10-01
categories: [Linux, Ubuntu, Network, Blogger 舊文]
permalink: /docs/blogger/linux/ubuntu-1204-bonding/
last_modified_at: 2026-10-24
---

# Ubuntu 12.04 雙網卡 Bonding：設定檔與 7 種模式怎麼選

> **一句話**：安裝 `ifenslave` 後，在 `/etc/network/interfaces` 把 eth0、eth1 設成 bond0 的成員，IP 設在 bond0 上；交換器沒設定的話選 **mode 6（balance-alb）**，最省事又有負載平衡與容錯。

| 項目 | 內容 |
| --- | --- |
| 適合誰看 | Linux 伺服器有兩張網卡，想增加頻寬或備援的人 |
| 環境 | Ubuntu 12.04 LTS x86_64；主機板內建兩個有線網路埠（eth0、eth1） |
| 日期 | 2014-10-01（原文發表於 Blogger，2026-10-24 改寫為新手版） |
| 結論 | ✅ eth0、eth1 綁成 bond0（mode 6） |

> Ubuntu 18.04 之後改用 **Netplan**（`/etc/netplan/*.yaml`）設定 bonding，觀念相同、寫法不同。

## 1. 先認識幾個名詞

| 名詞 | 白話解釋 |
| --- | --- |
| **Bonding** | 把多張實體網卡綁成一張虛擬網卡（bond0） |
| **Master／Slave** | bond0 是主介面；eth0、eth1 是成員 |
| **miimon** | 每隔多少毫秒檢查一次網卡連線狀態，100 表示 0.1 秒 |
| **ifenslave** | Ubuntu 上設定 bonding 用的套件 |

## 2. 架構

```text
            bond0（IP 設在這裡，mode 6）
           ┌──────┴──────┐
         eth0           eth1
           │              │
      交換器 Port A   交換器 Port B   （mode 6 不需要交換器設定）
```

## 3. 步驟一：安裝套件

```text
sudo aptitude install ifenslave-2.6
```

## 4. 步驟二：設定 /etc/network/interfaces

```text
auto lo
iface lo inet loopback

auto eth0
iface eth0 inet manual
    bond-master bond0

auto eth1
iface eth1 inet manual
    bond-master bond0

auto bond0
iface bond0 inet static
    address <你的 IP>
    netmask <你的遮罩>
    gateway <你的閘道>
    bond-slaves none
    bond-mode 6
    bond-miimon 100
```

| 片段 | 意思 |
| --- | --- |
| `iface eth0 inet manual` | 實體網卡本身不設 IP |
| `bond-master bond0` | 這張網卡屬於 bond0 |
| `bond-slaves none` | 成員由上面各網卡自己宣告，這裡不重複列 |
| `bond-mode 6` | 使用 balance-alb 模式 |
| `bond-miimon 100` | 每 100 毫秒檢查連線 |

> 原文 bond0 寫 `inet manual`，但設定了位址；設固定 IP 時應寫 `inet static`。

**DNS**：原作者在 `/etc/resolv.conf` 加入中華電信 HiNet 的 DNS 伺服器。

## 5. 步驟三：確認

```text
cat /proc/net/bonding/bond0
```

**應該看到什麼**：Bonding Mode 顯示 adaptive load balancing，兩個 Slave Interface 的 MII Status 都是 `up`。

**檢查網卡是否支援**：安裝 `net-tools` 後執行 `mii-tool`，兩張網卡都顯示 `link ok` 才適合綁定；舊款或速率不同的網卡可能不支援。

## 6. 模式怎麼選

| 模式 | 名稱 | 負載平衡 | 容錯 | 交換器要設定嗎 | 一句話 |
| --- | --- | --- | --- | --- | --- |
| 0 | balance-rr | ✅ 輪流送 | ✅ | 需要（Port Channel） | 封包輪流從每張卡送出 |
| 1 | active-backup | ❌ | ✅ | 不用 | 平常只用一張，壞了換另一張 |
| 2 | balance-xor | ✅ 依 MAC 分配 | ✅ | 需要 | 同一目的地固定走同一張卡 |
| 3 | broadcast | ❌ | ✅ | 不用 | 每個封包所有網卡都送一份 |
| 4 | 802.3ad（LACP） | ✅ 進出都加總 | ✅ | **需要 LACP** | 最標準，需交換器支援 |
| 5 | balance-tlb | ✅ 只有送出 | ✅ | 不用 | 送出依負載分配，接收用一張 |
| 6 | balance-alb | ✅ 送出＋接收 | ✅ | 不用 | tlb 再加上接收負載平衡；網卡驅動要能改 MAC |

> 原作者推薦 **mode 6**。兩張 1G 網卡在 mode 6 下，對外送出可接近 2G；接收依連線分散。交換器有設 LACP 的話，mode 4 最理想。

## 7. 常見問題

| 現象 | 怎麼辦 |
| --- | --- |
| 重開後 bond0 沒有起來 | 確認 ifenslave 已安裝；設定檔縮排與拼字（`bond-master`） |
| mode 0／4 設了反而斷線 | 這兩種需要交換器設定 Port Channel／LACP |
| `mii-tool` 顯示沒有 link | 網卡或線材問題，先排除再綁定 |

## 8. 延伸閱讀

- [CentOS 6 雙網卡綁定（摘要）](../centos6-bonding/)
- [Cisco Port Channel：兩條線綁成一條 Trunk](../../network/cisco-port-channel/)
- [Linux Kernel 文件：Bonding](https://www.kernel.org/doc/Documentation/networking/bonding.txt)
- [Blogger 原文](https://kbwangtw.blogspot.com/2014/10/ubuntu-1204lts-bonding.html)
