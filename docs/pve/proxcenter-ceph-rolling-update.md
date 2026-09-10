---
layout: default
title: "ProxCenter 執行 PVE／Ceph Rolling Update：疑難排解紀錄"
date: 2026-08-26
categories: [PVE, ProxCenter, Ceph]
---

<div class="kb-hero">
<h1>ProxCenter 執行 PVE／Ceph Rolling Update：疑難排解紀錄</h1>
<p>三節點 Proxmox VE／Ceph 叢集使用 ProxCenter 執行 Rolling Update，記錄 Repository 誤判、SSH 網段選錯與 sudo 權限不足三項卡關的排除過程。</p>
<div class="kb-badges"><span class="kb-badge">PVE</span><span class="kb-badge">ProxCenter</span><span class="kb-badge">Ceph</span></div>
</div>

## 摘要

三節點 Proxmox VE 叢集使用 ProxCenter 執行 Rolling Update 時，先後遇到 Repository 驗證誤判、SSH 自動選錯網段，以及非 root SSH 使用者未通過通用免密碼 sudo 檢查。逐項排除後，流程成功進入套件升級與節點健康驗證。

本文不包含密碼、Private Key、Token Secret 或完整憑證。

## 環境概觀

- 三節點：`node10`、`node11`、`node12`
- 管理／SSH 網段範例：`192.168.10.0/24`
- Corosync 專用網段範例：`172.16.10.0/24`
- Ceph：3 MON、3 OSD
- dedicated SSH user：`proxcenter`
- 節點間採人工批准

| 用途 | node10 | node11 | node12 |
|---|---|---|---|
| 管理／ProxCenter SSH | `192.168.10.10` | `192.168.10.11` | `192.168.10.12` |
| Corosync Cluster | `172.16.10.10` | `172.16.10.11` | `172.16.10.12` |

> 位址均為 RFC 1918 私有網段。它們不是密碼，但公開文件仍應視實際需求改成 placeholder。

## 最後可用的 Rolling Update 設定

```text
Update order                         node12 → node11 → node10
Migrate non-HA VMs                  ON
Shutdown VMs with local storage     OFF
Automatically reboot if needed      ON
Set Ceph noout during maintenance   ON
Abort on failure                    ON
Manual approval between each node   ON
Minimum healthy nodes               2
Wait for Ceph HEALTH_OK             ON
```

SSH Addresses 不使用 Auto-detect，而是固定管理網段：

```text
node12 → 192.168.10.12 vmbr0 (gw)
node11 → 192.168.10.11 vmbr0 (gw)
node10 → 192.168.10.10 vmbr0 (gw)
```

## 執行前基線

先從任一健康節點確認叢集沒有既存故障：

```bash
pvecm status
ceph -s
ha-manager status
```

本次基線為：

```text
PVE Cluster   3 Nodes / 3 Votes / Quorate: Yes
Corosync      172.16.10.10、.11、.12
Ceph          HEALTH_OK
OSD           3 up / 3 in
HA            quorum OK
LRM           node10、node11、node12 全部 active
```

這一步很重要：如果更新後出問題，才有明確的「更新前正常狀態」可以比較。

## Dedicated SSH user 的建立與驗證

ProxCenter 不使用 root 密碼登入，而是使用獨立帳號 `proxcenter` 與 SSH Key。三個節點都必須完成相同設定。

### 連線層驗證

先確認 ProxCenter 的 **Test SSH Connection** 三台都成功。若要在節點端確認實際登入來源，可查看：

```bash
journalctl --since "10 minutes ago" | grep -Ei 'sshd|proxcenter'
```

成功時可看到類似：

```text
Accepted publickey for proxcenter from 192.168.10.30
```

這只能證明 SSH Key 可用，不能證明 Rolling Update 的 sudo 權限完整，也不能證明 Rolling Update 使用了同一個節點 IP。

### sudoers 語法與非互動測試

每次調整 `/etc/sudoers.d/proxcenter` 後都先驗證語法：

```bash
visudo -c -f /etc/sudoers.d/proxcenter
```

必須得到：

```text
/etc/sudoers.d/proxcenter: parsed OK
```

測試必須使用 `sudo -n`，因為 Rolling Update 無法在背景工作中輸入密碼：

```bash
sudo -u proxcenter sudo -n /usr/sbin/ha-manager status
sudo -u proxcenter sudo -n /usr/bin/apt --version
sudo -u proxcenter sudo -n /usr/bin/ceph -s
sudo -u proxcenter sudo -n -l /usr/sbin/reboot
```

最後一條只列出 reboot 權限，不要在測試時真的執行 reboot。

## 故障時間線總覽

| 階段 | 看到的現象 | 真正原因 | 驗證方式 |
|---|---|---|---|
| Verify #1 | Repository Issues (6) | 三台各有兩個 `.BAK` 被掃描 | 只移 node10 後變 6 → 4 |
| Verify #2 | All checks passed | Repository 誤判已排除 | 三台 `.BAK` 移出後歸零 |
| Rolling Update #1 | Maintenance sudo 錯誤；之後 SSH timeout | sudo 與節點位址是兩個獨立問題 | Log 顯示 `172.16.10.12:22` |
| Rolling Update #2 | 改用管理 IP 後仍報 lacks passwordless sudo | 特定命令 allowlist 不符合 generic probe | `sudo -n true` 失敗 |
| Rolling Update #3 | 成功執行 `apt full-upgrade` | 管理 IP 與 sudo 前置條件均修正 | Log 進到 Verifying node health |

## 1. APT 正常，但 Verify 回報 Repository Issues

手動 `apt update` 正常，ProxCenter 卻固定回報每台兩個錯誤。檢查發現 `/etc/apt/sources.list.d/` 留有 `*.BAK`，內容包含已停用的 Enterprise URL。APT 不使用這些備份檔，但 ProxCenter 仍掃描到它們。

先只在一台節點做可回復測試：

```bash
mkdir -p /root/apt-source-backup
mv /etc/apt/sources.list.d/*.BAK /root/apt-source-backup/
grep -Rni 'enterprise.proxmox.com' /etc/apt/ 2>/dev/null
apt update
```

重新 Verify 後問題數量由 6 降為 4，證實誤判來源；其餘節點做相同處理後歸零。

### 為什麼先只動 node10

如果一開始就同時修改三台，Verify 歸零時仍無法證明是哪一個動作有效。先只處理 node10，可以建立很清楚的因果證據：

```text
修改前：Repository Issues (6)
只移 node10 的兩個 .BAK
修改後：Repository Issues (4)
```

node10 的兩個錯誤精確消失後，才把相同動作套用到 node11、node12。

### Repository 實際健康檢查

除了 `apt update`，也檢查套件來源：

```bash
apt-cache policy
grep -Rni 'enterprise.proxmox.com' /etc/apt/ 2>/dev/null
grep -RniE 'enterprise|no-subscription' /etc/apt/sources.list.d/ 2>/dev/null
```

本次實際啟用的是 `download.proxmox.com` 的 PVE／Ceph no-subscription repository；Enterprise URL 只存在備份檔中。

**經驗：** 管理工具可能自行掃描設定目錄，備份檔不應留在正式設定目錄中。

## 2. Rolling Update 選錯 SSH 網段

Test SSH Connection 曾成功，Rolling Update 卻嘗試連線 Corosync 網段並 timeout。原因是 Rolling Update Configuration 使用 **Auto-detect**，選到叢集專用網卡。

修正為明確指定管理位址：

```text
node10 → 192.168.10.10
node11 → 192.168.10.11
node12 → 192.168.10.12
```

不需修改 Corosync，也不應只為管理工具開放叢集專用網段的 SSH 路由。

### 為什麼 SSH Test 綠燈仍會失敗

一般連線設定已能走 `192.168.10.x`，但 Rolling Update Configuration 的 SSH Addresses 仍是 Auto-detect。兩個流程實際使用的 address 不一致，因此出現看似矛盾的結果：

```text
Test SSH Connection       成功
Rolling Update apt SSH    timeout to 172.16.10.12:22
```

故障發生後不應調整 Corosync，也不應為 `172.16.10.0/24` 新增管理路由；正確做法是在 Rolling Update 畫面固定 `192.168.10.x`。

## 3. Maintenance mode 顯示 lacks passwordless sudo

`proxcenter` 原本只有特定命令的 `NOPASSWD` allowlist。特定命令可成功，ProxCenter 仍判定缺少 passwordless sudo。關鍵測試：

```bash
sudo -u proxcenter sudo -n true
echo $?
sudo -u proxcenter sudo -n id
```

`sudo -n true` 失敗代表未通過該版本的通用前置檢查。依實際錯誤要求，最終使用：

```text
proxcenter ALL=(ALL) NOPASSWD: ALL
```

並驗證：

```bash
visudo -c -f /etc/sudoers.d/proxcenter
sudo -u proxcenter sudo -n true
sudo -u proxcenter sudo -n id
```

> **安全風險：** 此帳號成為 root-equivalent。SSH Key 必須獨立保管、限制來源、定期輪替並監控登入；若新版支援精確 allowlist，應回復最小權限。

### sudoers 的實際演進

一開始採最小權限，只允許 ProxCenter 產生的 command allowlist。`ha-manager` 可執行，但 `apt`、`ceph`、`reboot` 尚未全部放行，因此先補上：

```text
proxcenter ALL=(ALL) NOPASSWD: /usr/bin/apt, /usr/bin/ceph, /usr/sbin/reboot
```

逐條測試後：

```text
ha-manager status   成功
apt --version       成功
ceph -s             成功
reboot 權限列出     成功
```

但 Rolling Update 仍報錯。最後用通用 probe 將差異鎖定：

```bash
sudo -u proxcenter sudo -n true
```

結果為：

```text
sudo: a password is required
```

這證明「指定命令可免密碼 sudo」不等於「帳號具有一般性的 passwordless sudo」。加入 `NOPASSWD: ALL` 後再測：

```bash
sudo -u proxcenter sudo -n true
echo $?
sudo -u proxcenter sudo -n id
```

預期：

```text
0
uid=0(root) gid=0(root) groups=0(root)
```

### 安全上的取捨

`NOPASSWD: ALL` 不是無害的便利設定。只要 SSH Private Key 外洩，攻擊者即可取得節點 root。採用它時至少應做到：

- Key 只存放在 ProxCenter 主機，不複用於其他服務
- 限制 SSH 來源 IP 或管理 VLAN
- 禁止密碼登入並保留登入稽核
- 定期輪替與撤銷 Key
- 更新 ProxCenter 後重新評估能否回到 command allowlist
- 將 `proxcenter` 視為特權帳號監控

## 4. 本機儲存 VM 無法自動遷移

部分 VM 位於 local storage。因首次操作關閉 **Shutdown VMs with local storage**，它們被安全跳過，而非直接關機。若節點需要 reboot，仍須安排停機窗口或先遷移磁碟。

本次 Log 的 workload 行為：

```text
VM 100   local storage   Skip
VM 105   local storage   Skip
VM 107   migrated to node11 successfully
```

`Skipping ... local storage` 在目前設定下是預期警告，不等於 migration engine 壞掉。真正要回答的是：如果 node12 需要 reboot，VM 100、105 是否允許停機？若不允許，就必須先做 storage migration 或調整架構。

## 第一次 Rolling Update 的實際過程

Verify 通過後，第一個節點 node12 開始執行：

```text
Set Ceph noout                         成功
[node12] Starting node update          成功
[node12] Enabling maintenance mode     失敗／警告
[node12] Waiting for HA migrations
[node12] Migrating non-HA VMs
VM 100、105 local storage              Skip
VM 107 → node11                        成功
[node12] apt update                     SSH timeout
```

這一段提供兩個重要結論：

1. maintenance sudo 錯誤沒有立即阻止所有後續步驟；不能只看第一個黃色警告就假設 job 已停止。
2. 最終 apt 失敗顯示的目標 IP 是 `172.16.10.12`，因此 SSH address 是另一個獨立故障。

Job 中途失敗後，不要立刻重跑。先確認：

```bash
pvecm status
ceph -s
ha-manager status
ceph osd dump | grep flags
```

確認 Quorum、HA、OSD 正常，並檢查 `noout` 是否被正常清除。

## 第二次執行前的修正與驗證

在三台節點固定管理 IP，並逐台補齊 sudo 設定後，重新執行 Verify。此時確認：

```text
Repository                 正常
SSH Key                    正常
SSH management IP          固定為 192.168.10.x
Cluster / Quorum            正常
Ceph HEALTH_OK              正常
HA / LRM                    正常
sudo -n true                成功
```

三台必須各自通過，不應只測 node12 後就假設其他節點相同。

## 成功流程證據

```text
Rolling update started
Set Ceph noout flag
[node12] Starting node update
[node12] Enabling maintenance mode
[node12] Waiting for HA migrations
[node12] Migrating non-HA VMs
[node12] Running apt update && apt full-upgrade
[node12] Verifying node health
```

最關鍵的證據不是「按鈕變綠」，而是 Log 已不再：

```text
連線 172.16.10.12
回報 lacks passwordless sudo
```

並且確實進入：

```text
apt update && apt full-upgrade
Verifying node health
```

## 更新前檢查

- [ ] `pvecm status` 顯示 `Quorate: Yes`
- [ ] 三台節點 online
- [ ] `ceph -s` 為 `HEALTH_OK`，OSD 全部 up/in
- [ ] `ha-manager status` 顯示 quorum OK、LRM active
- [ ] SSH Address 固定為管理網段
- [ ] `visudo` 與 `sudo -n` 測試通過
- [ ] 已確認 local storage VM 的策略
- [ ] Abort on failure、Manual approval、Wait for Ceph HEALTH_OK 已開啟
- [ ] Minimum healthy nodes 設為 2

## 每台節點完成後

先不要立即批准下一台，確認：

```bash
pvecm status
ceph -s
ha-manager status
pveversion -v
```

並確認節點已重新加入、Quorum 正常、Ceph 回到 `HEALTH_OK`、HA/LRM active，且 `noout` 沒有意外殘留。

### 人工批准原則

若畫面出現 `Waiting for manual approval`，不要因上一台顯示 Completed 就立即批准。先從另一台健康節點執行檢查，確認：

- 更新節點重新加入 Cluster
- 仍是 3/3 nodes online
- Quorum 正常
- Ceph 為 HEALTH_OK
- 3 OSD 全部 up/in
- LRM active、HA services started
- PVE 套件版本合理
- 沒有 `noout` 意外殘留

全部正常才批准下一台。這讓 Rolling Update 真正做到「一次只承擔一台節點的風險」。

## 常見誤判與不要做的事

- 看到 Corosync 使用 `172.16.10.x` 不代表網路設定錯；錯的是拿它做管理 SSH。
- `apt update` 成功不代表第三方 Verify 不會掃到 `.BAK`。
- 特定命令 sudo 成功不代表 generic `sudo -n` probe 會成功。
- Job 還在執行時不要手動 migration、apt upgrade 或 reboot。
- Ceph 因節點維護短暫 degraded 時，不要立刻手動 recovery。
- Rolling Update 失敗後不要直接重跑；先查 Quorum、Ceph、HA 與 `noout`。
- 不要真的執行 reboot 來測 sudo；使用 `sudo -n -l`。

## 可重複使用的診斷命令集

### Repository

```bash
apt update
apt-cache policy
grep -Rni 'enterprise.proxmox.com' /etc/apt/ 2>/dev/null
ls -la /etc/apt/sources.list.d/
```

### Cluster／Ceph／HA

```bash
pvecm status
ceph -s
ceph osd dump | grep flags
ha-manager status
```

### SSH／sudo

```bash
journalctl --since "10 minutes ago" | grep -Ei 'sshd|sudo|proxcenter'
sudo -u proxcenter sudo -n -l
sudo -u proxcenter sudo -n true
sudo -u proxcenter sudo -n id
```

### 版本

```bash
pveversion -v
```

## 結論

本次是三個獨立條件疊加：

1. Repository Verify 掃描到停用的 `*.BAK`
2. Auto-detect 選到 Corosync 網段
3. dedicated user 的最小 sudo allowlist 不符合當時版本的通用檢查

有效的排錯策略是每次只改一個變因，並用問題數量、目標 IP、`sudo -n` exit code，以及 Cluster／Ceph／HA 健康狀態驗證。

