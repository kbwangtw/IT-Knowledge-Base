---
layout: default
title: "PVE 更新後逐台重開（人不在現場）：維護模式加 noout，一次一台"
date: 2026-11-05
categories: [PVE, Ceph, HA]
permalink: /docs/pve/pve-rolling-reboot-after-update/
last_modified_at: 2026-11-05
---

# PVE 更新後逐台重開（人不在現場）：維護模式加 noout，一次一台

> **一句話**：三台節點的套件更新完，裝了新核心，要重開才會生效；人不在現場、沒有主控台，所以用 `reboot`（不是關機）加「維護模式」一次重開一台，服務自己搬走、Ceph 一直有兩台在線，全程沒有中斷，三台都換成新核心。

| 項目 | 內容 |
| --- | --- |
| 適合誰看 | 管理 PVE 叢集、更新完套件想安全重開節點，而且可能人不在現場的人 |
| 環境 | PVE 9.2 三節點（node10／11／12）、Ceph（97 個 PG）、14 個 HA 服務（CT／VM）、HA 的 `shutdown_policy=migrate` |
| 日期 | 2026-11-05 |
| 結論 | ✅ 三台都從 `7.0.14-26-pve` 換成 `7.0.14-28-pve` ✅ 全程 `reboot`、沒有關機、沒有人在現場 ✅ 重開後 `HEALTH_OK`、97 個 PG `active+clean`、14 個服務 `started` ⏳ 重開後第一次排程備份（當晚 21:00～22:00）的結果還沒看到 |

## 1. 先認識幾個名詞

| 名詞 | 白話解釋 |
| --- | --- |
| **維護模式（node maintenance）** | 告訴 HA「這台節點要維護」：HA 會先把上面的服務搬走，再讓你重開；解除後服務會搬回來 |
| **`noout`** | Ceph 的旗標：OSD 暫時離線時，不要開始搬資料。重開一台節點的幾分鐘內不需要重平衡 |
| **`reboot`** | 重新開機，節點會自己再起來。和關機（`poweroff`、`shutdown`）不同：**關機後，沒有遠端電源就開不回來** |
| **執行中的核心** | `uname -r` 看到的，是上次開機載入的核心 |
| **已安裝的核心** | `/boot/vmlinuz-*` 裡有的；比執行中的新，就要重開才會換 |
| **scrub／deep scrub** | Ceph 例行的資料檢查，PG 仍然是 `active+clean`（健康） |

## 2. 為什麼不能「整叢集關機再開機」

三台是迷你主機，**應該沒有 BMC／IPMI**（依機型推測，未確認）；有沒有 Wake-on-LAN、可不可以遠端斷電，也沒有確認（未確認）。所以人不在現場時：

| 做法 | 人不在現場 |
| --- | --- |
| `poweroff`／`shutdown` | 節點不會自己開機，可能回不來 |
| `reboot` | 節點會自己起來 ✅ |
| 三台同時重開 | 一旦新核心起不來，沒有人能處理 |
| **一次一台** | 最多一台出事，另外兩台仍有 quorum 與 Ceph（2/3） ✅ |

## 3. 全貌

```text
先判斷要不要重開（核心有沒有變）
   ↓
重開前檢查（防火牆、套件、grub、HA、Ceph）
   ↓
設 Ceph noout（只設一次）
   ↓
 ┌─ 對節點 A：進維護模式 → 確認清空 → 從別台 reboot → 等回來 → 驗收 → 解除維護模式
 ├─ 對節點 B：同上
 └─ 對節點 C：同上（有 VPN 的 CT 所在節點放最後）
   ↓
全部完成：解除 noout → 最後驗收
```

## 4. 步驟一：判斷要不要重開（唯讀）

**做什麼**：重開前先確認真的需要，不要為了「更新過」就重開。

```bash
for n in node10 node11 node12; do echo "== $n"; ssh root@$n 'uname -r; pveversion | head -1; ls /var/run/reboot-required 2>&1 | head -1; apt list --upgradable 2>/dev/null | grep -vc "^Listing"'; done
for n in node10 node11 node12; do echo "== $n"; ssh root@$n "dpkg -l 'proxmox-kernel-*' | grep '^ii' | awk '{print \$2, \$3}'; ls /boot/vmlinuz-*"; done
for n in node10 node11 node12; do echo "== $n"; ssh root@$n "grep ' upgrade ' /var/log/dpkg.log | tail -25 | awk '{print \$1, \$4, \$5, \$6}'"; done
```

| 片段 | 意思 |
| --- | --- |
| `uname -r`、`pveversion` | 目前**執行中**的核心與 PVE 版本 |
| `/var/run/reboot-required` | 系統是否要求重開；**PVE 不一定會建立這個檔**，所以「沒有」不能證明不用重開 |
| `apt list --upgradable` 的數字 | 還有幾個套件沒更新；不是 0 就先更新完再重開，不要重開兩次 |
| `dpkg -l 'proxmox-kernel-*'`、`ls /boot/vmlinuz-*` | **已安裝**的核心有哪些 |
| `grep ' upgrade ' /var/log/dpkg.log` | 最近升級了哪些套件 |

**看到的結果**（2026-11-05）：

| 項目 | 結果 |
| --- | --- |
| 執行中的核心 | 三台都是 `7.0.14-26-pve` |
| 已安裝的核心 | 三台都有 `7.0.14-25`、`-26`、`-28`；**`-28` 比執行中的新** |
| `pveversion` | 9.2.25（10/29 是 9.2.24） |
| `/var/run/reboot-required` | 三台都沒有（`No such file`） |
| 可更新套件 | 三台都是 `0` |
| 今天升級的重點 | `proxmox-kernel-7.0` 7.0.14-26 → 7.0.14-28、`grub` 全套 2.12-9+pmx2 → pmx4、`pve-firmware`、`ifupdown2`、`pve-firewall` 6.0.7、`proxmox-firewall` 1.2.4、`pve-container`、`ceph-fuse` 20.2.5-pve1 等 |

**判斷**：有比執行中新的核心，所以要重開。如果只有 `pve-manager` 之類的 PVE 套件更新、核心沒變，通常**不用重開**（PVE 服務在套件升級時已自動重啟；`pve-qemu-kvm` 要讓已在跑的 VM 重啟或遷移才會用新版）。

## 5. 步驟二：重開前的檢查（唯讀）

這次更新碰到三個「出錯會讓節點連不上」的東西：`grub`（開機載入程式）、`ifupdown2`（網路）、`pve-firewall`，所以多做幾項：

```bash
for n in node10 node11 node12; do echo "== $n"; ssh root@$n 'pve-firewall status; dpkg --audit | head -3; grep -c "7.0.14-28" /boot/grub/grub.cfg; proxmox-boot-tool status 2>&1 | head -4; grep -E "^GRUB_DEFAULT" /etc/default/grub'; done
pvesh get /cluster/firewall/options
ha-manager status | grep -E 'ct:|vm:'
for n in node10 node11 node12; do echo "== $n"; ssh root@$n 'qm list; pct list'; done
grep -i '^ha' /etc/pve/datacenter.cfg
ceph -s | grep -E 'health|pgs|mon:|osd:'
```

| 預期 | 意思 |
| --- | --- |
| `Status: enabled/running` | 套件升級沒有讓防火牆停掉，`pvesh get /cluster/firewall/options` 的 `enable` 仍是 `1` |
| `dpkg --audit` 沒輸出 | 沒有安裝到一半的套件 |
| `grep -c "7.0.14-28" /boot/grub/grub.cfg` 大於 0 | 新核心已登記到 grub 選單（這次是 11） |
| `GRUB_DEFAULT=0` | 預設開機項目是選單第一個，也就是最新核心 |
| `proxmox-boot-tool status` 報 `/etc/kernel/proxmox-boot-uuids does not exist` | **不是錯誤**：這三台直接用 grub 開機，不是由 `proxmox-boot-tool` 管理 ESP |
| `ha: shutdown_policy=migrate` | 節點關機或重開時，HA 會先搬走服務 |
| `ceph -s` | `HEALTH_OK`、97 個 PG `active+clean`、**沒有 `noout`** |

**看到的結果**：以上全部符合。服務位置：node10 有 CT103、105、112、113、114、vm:106；node11 有 CT100、110（ProxCenter）、115；node12 有 CT101、102、109（WireGuard）、vm:107、vm:111；VM 104、108 不在 HA、都是 `stopped`。

## 6. 步驟三：重開順序

| 順序 | 節點 | 原因 |
| --- | --- | --- |
| 1 | node11 | 服務較少，先拿它試；若沒起來，還有兩台 |
| 2 | node10 | 服務最多（Graylog、Wazuh、Grafana、DC01 等） |
| 3 | node12 | **最後**：WireGuard（CT109）在這台，VPN 只會在最後斷一次 |

**不要在要重開的那台自己下指令**：從另一台的 terminal 下 `ssh root@<節點> reboot`，這樣重開後你還有一個活著的視窗可以監看。

## 7. 步驟四：每一台重開的流程

### 7-1 第一台開始前，設一次 `noout`

```bash
ceph osd set noout
ceph osd dump | grep '^flags'
```

**應該看到**：`flags` 那行有 `noout`。整輪結束才解除。

### 7-2 進維護模式、確認節點清空

```bash
ha-manager crm-command node-maintenance enable node11
sleep 60
ha-manager status | grep -E 'ct:|vm:'
ssh root@node11 'pct list; qm list'
```

| 預期 | 意思 |
| --- | --- |
| 該節點的服務陸續搬到另外兩台 | 維護模式正在清空節點 |
| 服務會先出現 `relocate`（CT）或 `migrate`（VM） | 搬家中，再看一次直到都是 `started` |
| 14 個服務最終都 `started`、位置不在這台、沒有 `error` | 搬完了 |
| 該節點的 `pct list`、`qm list` 沒有輸出 | 清空，可以重開 |

CT 搬家是「停了再啟動」，每個約 1～2 分鐘；VM（沒有 PCI 直通）是線上遷移，不中斷。**服務最多的 node10 搬了數分鐘**，要耐心看。

### 7-3 從別台重開，等它回來

```bash
ssh root@node11 reboot
for i in $(seq 1 90); do ssh -o ConnectTimeout=3 root@node11 uname -r 2>/dev/null && break; sleep 5; done
```

**應該看到**：幾分鐘後印出 `7.0.14-28-pve`。迴圈最長約 10 分鐘。

> **停損**：10 分鐘還沒回來，就不要再重開別台；那一台之後要到現場處理，另外兩台仍有 quorum 與 Ceph，服務都在它們上面。

### 7-4 回來後驗收（唯讀）

```bash
ssh root@node11 'uname -r; pve-firewall status; systemctl is-active pve-cluster corosync pveproxy pve-ha-lrm'
pvecm status | grep -E 'Quorate|Nodes:'
corosync-cfgtool -s | grep -E 'LINK ID|nodeid'
ceph -s | grep -E 'health|pgs|mon:|osd:'
ceph health detail
```

| 預期 | 意思 |
| --- | --- |
| `7.0.14-28-pve` | 新核心生效 |
| `enabled/running`、四個 `active` | 防火牆與叢集服務正常 |
| `Nodes: 3`、`Quorate: Yes` | 叢集完整 |
| LINK 0、LINK 1 對其他兩台都 `connected` | 兩條 Corosync link 都通 |
| `HEALTH_WARN` 只有 `OSDMAP_FLAGS: noout flag(s) set`、`osd: 3 up`、MON 3 個 quorum | `noout` 是我們設的，所以會有這個 WARN |
| 97 個 PG `active+clean` | OSD 剛重新上線時可能短暫 `degraded`，**等全部回來再做下一步** |

### 7-5 解除維護模式、等服務回來

```bash
ha-manager crm-command node-maintenance disable node11
sleep 60
ha-manager status | grep -E 'ct:|vm:'
```

**應該看到**：原本屬於這台的服務搬回來（位置可能因 `ha-rebalance` 和重開前不同，兩種都可以接受），14 個服務全部 `started`、沒有 `error`、`relocate`、`migrate`。穩定之後才換下一台。

## 8. 步驟五：全部完成後

```bash
ceph osd unset noout
ceph osd dump | grep '^flags'
ceph -s | grep -E 'health|pgs|mon:|osd:'
for n in node10 node11 node12; do ssh root@$n 'uname -r'; done
ha-manager status | grep -E 'ct:|vm:|node12'
for n in node10 node11 node12; do echo "== $n"; ssh root@$n 'pve-firewall status; systemctl is-active pve-ha-lrm'; done
```

| 預期 | 意思 |
| --- | --- |
| `flags` 沒有 `noout`（只剩 `sortbitwise,recovery_deletes,purged_snapdirs,pglog_hardlimit`） | 旗標已清掉 |
| `health: HEALTH_OK`、97 `active+clean`、`osd: 3 up 3 in` | 叢集完全健康 |
| 三台都是 `7.0.14-28-pve` | 整輪完成 |
| 14 個服務 `started`；各節點 `lrm` 是 `active`、沒有 `maintenance` | 沒有節點還留在維護模式 |
| 三台防火牆 `enabled/running` | 重開後設定與服務都正常 |

**一定要記得 `unset noout`**：留著的話，日後 OSD 真的故障時，Ceph 不會自動處理。

## 9. 這次的實測結果

| 節點 | 搬家 | 重開後 |
| --- | --- | --- |
| node11 | CT100 → node10；CT110、CT115 → node12 | `-28`；兩條 Corosync link 都通；97 個 PG `active+clean`；服務回到原位 |
| node10 | CT103、CT112 → node11；CT105、CT113、CT114 → node12；vm:106 線上遷移 → node11 | `-28`；MON 3 個 quorum；97 個 PG `active+clean`；服務回到原位 |
| node12 | CT101 → node10；CT102、CT109（WireGuard）、vm:107、vm:111 → node11 | `-28`；剛重新上線時 96 個 `active+clean`、1 個 `active+clean+scrubbing+deep`（例行檢查，不是故障）；服務回到原位 |

- 整輪約半小時（含等服務搬家與 PG 同步，依當天時間戳記推估）；全程沒有人在現場，三台都靠 `reboot` 自己回來。
- CT109（WireGuard）因 node12 進出維護模式搬了兩次，VPN 預期會各短暫中斷一次（約 1～2 分鐘；這次沒有記錄實際中斷時間）；其餘 CT 的搬家是各自的短暫重啟。
- 搬走服務時 Graylog、Wazuh 監控預期會有短暫空窗，可能寄出告警信（這次沒有逐一確認）。
- 這次用的是**維護模式**，`shutdown_policy=migrate` 沒有被用到，仍未驗證。

## 10. 常見問題

| 現象 | 怎麼辦 |
| --- | --- |
| 沒有 `/var/run/reboot-required`，需要重開嗎？ | 不能用它判斷；比對「已安裝的核心」和 `uname -r`，有比較新的就重開 |
| `proxmox-boot-tool status` 報 `/etc/kernel/proxmox-boot-uuids does not exist` | 不是錯誤，表示直接用 grub 開機，不由它管理 ESP |
| `ceph -s \| grep pgs` 只看到 `96 active+clean` | `grep` 只印含 `pgs` 的那一行，第二行（例如 `1 active+clean+scrubbing+deep`）被切掉了；用 `ceph pg stat` 或 `ceph -s \| sed -n '/pgs:/,/^$/p'` 看完整；`scrubbing` 是例行檢查，PG 仍健康 |
| 維護模式服務搬了很久 | CT 是停了再啟動，要 1～2 分鐘；超過 5 分鐘或出現 `error`，不要重開，貼 `ha-manager status` 查 |
| 節點重開超過 10 分鐘沒回來 | 不要重開別台；那台要到現場處理，另外兩台有 quorum，服務都在它們上面 |
| 重開後 `HEALTH_WARN` | 只有 `noout flag(s) set` 就正常，全部完成後 `ceph osd unset noout` |
| 重開後 Lab Ops 顯示 `Session creation failed` | CT113 搬家重啟時 DNS 可能還沒起來；只 `kill` `claude` 那個程序，不要 `pkill -f`（見[整個 PVE 叢集安全關機與開機](https://kbwangtw.github.io/IT-Knowledge-Base/docs/pve/pve-cluster-full-shutdown/)） |
| 我在要重開的那台自己下 `reboot` | 也可以，只是連線會斷；建議開另一台的 terminal 下指令，才能繼續監看 |

## 11. 待辦

- [x] 三台更新到新核心 `7.0.14-28-pve`（2026-11-05）
- [ ] 確認重開後第一次排程備份（當晚 21:00～22:00）三台都 `OK`；node11 的 VM 108 若是關機，會有已知的 `WARNINGS: 2`
- [ ] 下次若忘了進維護模式，驗證 `shutdown_policy=migrate` 真的會先搬走服務（這次沒用到）
- [ ] 確認三台有沒有 Wake-on-LAN 或可遠端斷電的做法（未確認）；有的話，人不在現場時才有退路

## 12. 延伸閱讀

- [PVE 更新重開後 HA 服務卡在 error：原因與救回步驟](https://kbwangtw.github.io/IT-Knowledge-Base/docs/pve/pve-ha-service-error-after-reboot/)
- [ProxCenter 逐台更新 PVE：三個卡關點怎麼排除？](https://kbwangtw.github.io/IT-Knowledge-Base/docs/pve/proxcenter-ceph-rolling-update/)
- [整個 PVE 叢集安全關機與開機：一鍵腳本（含 HA、Ceph）](https://kbwangtw.github.io/IT-Knowledge-Base/docs/pve/pve-cluster-full-shutdown/)
- [Proxmox VE：High Availability](https://pve.proxmox.com/pve-docs/chapter-ha-manager.html)
