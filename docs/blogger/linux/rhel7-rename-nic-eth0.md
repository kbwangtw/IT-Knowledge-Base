---
layout: default
title: "RHEL／CentOS 7 把網卡名稱 eno*、ens* 改回 eth0"
date: 2021-12-08
categories: [Linux, RHEL, CentOS, Network, Blogger 舊文]
permalink: /docs/blogger/linux/rhel7-rename-nic-eth0/
last_modified_at: 2026-10-30
---

# RHEL／CentOS 7 把網卡名稱 eno*、ens* 改回 eth0

> **一句話**：在 GRUB 開機參數加上 `net.ifnames=0 biosdevname=0` 關掉新式命名，把 `ifcfg-eno*` 設定檔改名並修改 `NAME`、`DEVICE`，重開機後網卡就叫 eth0、eth1……；**一定要在本機 Console 操作**，用 SSH 改會斷線。

| 項目 | 內容 |
| --- | --- |
| 適合誰看 | 舊程式或腳本寫死 eth0，新系統網卡名稱卻變成 eno5、ens192 的人 |
| 環境 | RHEL 7／CentOS 7；4 張網卡（原名 eno5～eno8） |
| 日期 | 2021-12-08（原文發表於 Blogger，2026-10-24 改寫為新手版） |
| 結論 | ✅ 重開後網卡改用傳統名稱 |

> ⚠️ 請用 **root 在實體鍵盤螢幕（或 iLO／VM Console）** 操作；SSH、Telnet 會在改網卡時斷線，設定可能只做一半。

## 1. 先認識幾個名詞

| 名詞 | 白話解釋 |
| --- | --- |
| **可預測網卡命名** | RHEL 7 起依主機板位置命名（eno1、ens192、enp3s0），不會因開機順序亂跳 |
| **`net.ifnames=0`** | 關閉 systemd 的新式命名 |
| **`biosdevname=0`** | 關閉 Dell 等廠牌的 BIOS 命名（em1、p1p1） |
| **GRUB** | 開機管理程式，開機參數寫在這裡 |
| **ifcfg 檔** | `/etc/sysconfig/network-scripts/ifcfg-<名稱>`，每張網卡一個設定檔 |

## 2. 整體流程

```text
① 停用 NetworkManager
② /etc/sysconfig/grub 加上 net.ifnames=0 biosdevname=0（並重產 grub.cfg）
③ ifcfg-eno5～eno8 改名
④ 修改每個檔案裡的 NAME、DEVICE
⑤ reboot
⑥ 啟用 NetworkManager，ifconfig 確認
```

## 3. 步驟一：停用 NetworkManager

```text
systemctl stop NetworkManager
systemctl disable NetworkManager
```

## 4. 步驟二：修改 GRUB 開機參數

```text
vi /etc/sysconfig/grub
```

在 `GRUB_CMDLINE_LINUX="..."` 引號內的最後面加上 `net.ifnames=0 biosdevname=0`：

```text
GRUB_CMDLINE_LINUX="rd.lvm.lv=rhel/swap crashkernel=auto rd.lvm.lv=rhel/root rhgb quiet net.ifnames=0 biosdevname=0"
```

接著重新產生 GRUB 設定（原文未列出，但需要這一步才會生效）：

```text
grub2-mkconfig -o /boot/grub2/grub.cfg
```

> UEFI 開機的機器，輸出路徑是 `/boot/efi/EFI/redhat/grub.cfg`（CentOS 為 `.../EFI/centos/grub.cfg`）。

## 5. 步驟三：設定檔改名

```text
cd /etc/sysconfig/network-scripts/
mv ifcfg-eno5 ifcfg-eth0
mv ifcfg-eno6 ifcfg-eth1
mv ifcfg-eno7 ifcfg-eth2
mv ifcfg-eno8 ifcfg-eth3
```

> 原文的指令把檔案改成 `ifcfg-eno0`～`eno3`，但關閉新式命名後系統產生的名稱是 **eth0～eth3**；設定檔名稱與 `DEVICE` 必須和實際網卡名稱一致，所以這裡改用 eth。

## 6. 步驟四：修改 NAME 與 DEVICE

每個檔案都要改，以 eth0 為例：

```text
vi /etc/sysconfig/network-scripts/ifcfg-eth0
NAME=eth0
DEVICE=eth0
```

| 檔案 | NAME／DEVICE |
| --- | --- |
| `ifcfg-eth0` | `eth0` |
| `ifcfg-eth1` | `eth1` |
| `ifcfg-eth2` | `eth2` |
| `ifcfg-eth3` | `eth3` |

> 檔案裡若有 `HWADDR=`（MAC 位址）可以保留，能確保名稱對應到正確的實體網卡。

## 7. 步驟五：重開機並恢復 NetworkManager

```text
reboot
systemctl start NetworkManager
systemctl enable NetworkManager
ifconfig
```

**應該看到什麼**：`ifconfig`（或 `ip a`）列出 eth0～eth3，IP 設定正確。

## 8. 常見問題

| 現象 | 怎麼辦 |
| --- | --- |
| 重開後名稱沒變 | 沒有執行 `grub2-mkconfig`；或改錯 UEFI／BIOS 對應的 grub.cfg |
| 網卡名稱變了但沒有 IP | ifcfg 檔名、`NAME`、`DEVICE` 三者要一致 |
| 改到一半 SSH 斷線 | 用 Console 登入繼續完成 |
| 網卡順序跟以前不同 | 在 ifcfg 加上 `HWADDR=` 綁定 MAC |

## 9. 延伸閱讀

- [Red Hat 文件：RHEL 7 Networking Guide 第 11 章 Consistent Network Device Naming](https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/7/html/networking_guide/ch-consistent_network_device_naming)（原本的「停用」小節已從官方文件移除；本章開頭註明 Red Hat 不支援停用一致性命名的系統）
- [Blogger 原文](https://kbwangtw.blogspot.com/2021/12/redhat-7centos-7-eno-eth0.html)
