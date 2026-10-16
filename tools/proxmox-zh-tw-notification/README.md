# Proxmox 繁體中文通知模板

> 本專案原為獨立 repository `kbwangtw/proxmox-zh-tw-notification`，2026-10-16 併入 IT-Knowledge-Base 的 `tools/proxmox-zh-tw-notification/`，之後只維護這一份。安裝紀錄與備份位置（`/var/lib`、`/var/backups` 下的 `proxmox-zh-tw-notification`）不變，舊版安裝可直接用本目錄的 `uninstall.sh` 移除。使用說明見知識庫文章〈把 PVE／PBS 通知改成繁體中文〉。

為 Proxmox VE 9.x 與 Proxmox Backup Server 4.x 提供繁體中文（zh-TW）通知模板。專案使用 Proxmox 官方支援的 template override 目錄，不會修改 `/usr/share` 內由套件管理器維護的原廠模板。

## 支援範圍

| 產品 | 通知類型 | 安裝位置 |
| --- | --- | --- |
| Proxmox VE 9.x | vzdump VM／CT 備份（純文字與 HTML） | `/etc/pve/notification-templates/default/` |
| Proxmox Backup Server 4.x | Garbage Collection | `/etc/proxmox-backup/notification-templates/default/` |
| Proxmox Backup Server 4.x | Prune | 同上 |
| Proxmox Backup Server 4.x | Verification | 同上 |
| Proxmox Backup Server 4.x | Sync | 同上 |
| Proxmox Backup Server 4.x | Package Updates | 同上 |

模板沿用官方檔名、Handlebars 變數及 helper，只翻譯使用者會看到的文字。

## 一行安裝

在 PVE 或 PBS 主機上以 root 權限執行：

```bash
curl -fsSL https://raw.githubusercontent.com/kbwangtw/IT-Knowledge-Base/main/tools/proxmox-zh-tw-notification/install.sh | sudo bash
```

安裝器會自動判斷主機是 PVE、PBS，或同時包含兩者。若已經是 root，可以省略 `sudo`。

### 明確指定產品

從 repository clone 後，可以指定只安裝其中一種產品：

```bash
sudo ./install.sh --pve
sudo ./install.sh --pbs
sudo ./install.sh --all
```

## 本機安裝

```bash
git clone https://github.com/kbwangtw/IT-Knowledge-Base.git
cd IT-Knowledge-Base/tools/proxmox-zh-tw-notification
sudo ./install.sh
```

腳本使用 `set -euo pipefail`，任何下載或安裝錯誤都會立即停止。透過 pipe 執行時，腳本會從 IT-Knowledge-Base 的 `main` branch（`tools/proxmox-zh-tw-notification/`）下載模板；從 clone 執行時則直接使用本機檔案。

## 備份與還原

每次安裝前，只要目標目錄中已有自訂模板，就會完整備份至：

```text
/var/backups/proxmox-zh-tw-notification/<產品>-<UTC 時間戳>/
```

首次安裝時的原始狀態另存於：

```text
/var/lib/proxmox-zh-tw-notification/<產品>/original/
```

這份狀態讓 `uninstall.sh` 能移除本專案的檔案並還原原本的自訂模板。備份目錄不會在移除時自動刪除，方便管理者自行保留或清理。

## 移除

若是透過 clone 安裝：

```bash
sudo ./uninstall.sh
```

或直接執行遠端腳本：

```bash
curl -fsSL https://raw.githubusercontent.com/kbwangtw/IT-Knowledge-Base/main/tools/proxmox-zh-tw-notification/uninstall.sh | sudo bash
```

也可使用 `--pve`、`--pbs` 或 `--all` 指定產品。預設 `--auto` 會依安裝記錄移除已安裝的模板。

## 驗證

安裝完成後可確認檔案：

```bash
# PVE
find /etc/pve/notification-templates/default -maxdepth 1 -type f -name '*.hbs' -print

# PBS
find /etc/proxmox-backup/notification-templates/default -maxdepth 1 -type f -name '*.hbs' -print
```

接著從 Proxmox 管理介面的 **Datacenter / Notifications** 傳送測試通知，或等待相對應工作下一次執行。模板會在通知產生時載入，安裝與移除都不需要重新啟動 PVE／PBS 服務。

## 專案結構

```text
.
├── install.sh
├── uninstall.sh
├── pve/default/       # PVE vzdump override templates
└── pbs/default/       # PBS job override templates
```

## 相容性與注意事項

- 目標版本為 Proxmox VE 9.x 與 Proxmox Backup Server 4.x。
- `/etc/pve` 由 pmxcfs 管理；PVE 叢集中的模板會隨該設定檔系統同步。
- 本專案不會變更 `/usr/share/pve-manager/templates/` 或 `/usr/share/proxmox-backup/templates/`。
- 本專案只改變通知內容，不會建立通知 target 或 matcher；寄件目標仍需在 Proxmox 管理介面設定。
- Proxmox 更新若新增或變更官方模板變數，請先比較上游模板再更新本專案。

## 授權

本專案採用 MIT License，詳見 [LICENSE](LICENSE)。Proxmox 是 Proxmox Server Solutions GmbH 的商標；本專案與該公司無隸屬關係。
