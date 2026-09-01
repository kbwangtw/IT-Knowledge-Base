---
layout: default
title: "Proxmox VE / Proxmox Backup Server 繁體中文通知模板安裝"
date: 2026-09-01
categories: [PVE, PBS, Notification]
---

# Proxmox VE / Proxmox Backup Server 繁體中文通知模板安裝

## 摘要

[proxmox-zh-tw-notification](https://github.com/kbwangtw/proxmox-zh-tw-notification) 為 Proxmox VE 9.x 與 Proxmox Backup Server 4.x 提供繁體中文通知模板。它使用 Proxmox 官方支援的 template override 目錄，不修改 `/usr/share` 內由套件管理器維護的原廠模板。

PVE 涵蓋 vzdump VM／CT 備份通知的主旨、純文字與 HTML 內容；PBS 涵蓋 Garbage Collection、Prune、Verification、Sync 與 Package Updates。腳本只改變通知內容，不會建立通知 target 或 matcher。

## 支援與驗證狀態

| 產品 | 支援範圍 | 驗證狀態 |
|---|---|---|
| Proxmox VE 9.x | vzdump VM／CT 備份通知 | **PVE 9.2.11 已完成實機完整生命週期驗證** |
| Proxmox Backup Server 4.x | GC、Prune、Verification、Sync、Package Updates | **PBS 4.2.5 模板已完成；實機安裝驗證尚待進行** |

PVE 9.2.11 已完成：

```text
install → 中文 vzdump email → uninstall/restore
        → state cleanup → reinstall → 成功
```

> PBS 4.2.5 目前只能視為「模板完成」，不能宣稱已通過與 PVE 相同的實機 install／uninstall 驗證。

## 安裝前注意事項

- 必須以 `root` 權限執行，且主機需能存取 `raw.githubusercontent.com`。
- 先確認既有 override 模板；腳本會備份，但仍建議納入變更紀錄。
- PVE 叢集的 `/etc/pve` 由 pmxcfs 管理；不要在每個節點同時重複寫入。
- 通知 target 與 matcher 仍須在 Proxmox 管理介面設定。

## 安裝

### PVE

```bash
curl -fsSL https://raw.githubusercontent.com/kbwangtw/proxmox-zh-tw-notification/main/install.sh | bash -s -- --pve
```

### PBS

```bash
curl -fsSL https://raw.githubusercontent.com/kbwangtw/proxmox-zh-tw-notification/main/install.sh | bash -s -- --pbs
```

### 模式參數

| 參數 | 行為 |
|---|---|
| `--auto` | 預設；偵測主機已安裝的 PVE、PBS，或兩者 |
| `--pve` | 只安裝 PVE 模板 |
| `--pbs` | 只安裝 PBS 模板 |
| `--all` | 同時安裝 PVE 與 PBS 模板 |

不帶參數等同 `--auto`：

```bash
curl -fsSL https://raw.githubusercontent.com/kbwangtw/proxmox-zh-tw-notification/main/install.sh | bash
```

## 模板目標路徑

| 產品 | Override 目錄 |
|---|---|
| PVE | `/etc/pve/notification-templates/default/` |
| PBS | `/etc/proxmox-backup/notification-templates/default/` |

專案不會修改 `/usr/share/pve-manager/templates/` 或 `/usr/share/proxmox-backup/templates/`。模板在下一封通知產生時載入，安裝與移除後都**不需要重新啟動 PVE 或 PBS 服務**。

## PVE Cluster 與 pmxcfs

`/etc/pve` 不是一般磁碟目錄，而是 pmxcfs 叢集設定檔系統。叢集具有 quorum 且 pmxcfs 可寫時，在一個節點寫入模板後會同步到其他節點。

```bash
pvecm status
mount | grep /etc/pve
```

若叢集失去 quorum，`/etc/pve` 可能變成唯讀。應先修復 quorum／pmxcfs，不要用權限指令強行繞過。

## 備份、first-install state 與還原

若目標目錄已有模板，每次安裝前會完整備份到：

```text
/var/backups/proxmox-zh-tw-notification/<產品>-<UTC時間戳>/
```

首次安裝某產品時，原始 override 狀態另存於：

```text
/var/lib/proxmox-zh-tw-notification/<產品>/original/
```

同一產品後續 reinstall 不會覆寫這份 first-install snapshot。state 也記錄目標目錄與本專案管理的檔名，讓 `uninstall.sh` 精準移除並還原。安裝器會先取得所有模板才修改目標；複製失敗時會嘗試回復本次變更。

uninstall 只處理安裝記錄中的檔案，還原首次安裝前模板後清除該產品 state；`/var/backups` 的歷史備份不會自動刪除。

## 移除

### PVE

```bash
curl -fsSL https://raw.githubusercontent.com/kbwangtw/proxmox-zh-tw-notification/main/uninstall.sh | bash -s -- --pve
```

### PBS

```bash
curl -fsSL https://raw.githubusercontent.com/kbwangtw/proxmox-zh-tw-notification/main/uninstall.sh | bash -s -- --pbs
```

也可使用 `--auto` 或 `--all`。uninstall 的 `--auto` 會依 `/var/lib/proxmox-zh-tw-notification/` 的安裝記錄決定移除產品。

## 安裝後驗證

```bash
# PVE
find /etc/pve/notification-templates/default -maxdepth 1 -type f -name '*.hbs' -print

# PBS
find /etc/proxmox-backup/notification-templates/default -maxdepth 1 -type f -name '*.hbs' -print
```

接著從 **Datacenter / Notifications** 傳送測試通知，或執行對應工作並檢查新通知。PBS 實機驗證時應分別覆蓋 GC、Prune、Verification、Sync 與 Package Updates。

## Troubleshooting

### `/etc/pve` 唯讀或無法寫入

```bash
pvecm status
systemctl status pve-cluster
mount | grep /etc/pve
```

先修復 quorum 或 pmxcfs，不要直接改權限。

### 為什麼 PVE 不能使用 `chmod`、`install -m` 或 `cp -a`

pmxcfs 不是一般 POSIX 檔案系統，權限與 metadata 由它管理：

- `chmod` 可能不受支援或被拒絕。
- `install -m` 複製後會設定 mode，因此可能失敗。
- `cp -a` 會保留權限、時間等 metadata，也可能觸發不支援的操作。

所以專案對 PVE 目標使用一般 `cp`；PBS 的一般檔案系統目錄才使用 `install -m 0644`。

### 安裝成功但仍收到英文通知

- 確認通知類型由本專案涵蓋，且目標目錄與檔名正確。
- 產生一封新通知；舊郵件不會被改寫。
- 確認工作由正確的 PVE cluster 或 PBS 主機執行。
- Proxmox 更新若改變官方模板變數，先比較上游模板與本專案版本。

### `--auto` 找不到產品

確認產品與版本後可明確使用 `--pve` 或 `--pbs`；不要在非 Proxmox 主機強制執行。

### uninstall 找不到安裝記錄

若 state 已被手動刪除，不要猜測原始模板；請從 `/var/backups/proxmox-zh-tw-notification/` 選擇正確時間點人工復原。

## 原始專案

- GitHub：[kbwangtw/proxmox-zh-tw-notification](https://github.com/kbwangtw/proxmox-zh-tw-notification)
- [install.sh](https://github.com/kbwangtw/proxmox-zh-tw-notification/blob/main/install.sh)
- [uninstall.sh](https://github.com/kbwangtw/proxmox-zh-tw-notification/blob/main/uninstall.sh)
