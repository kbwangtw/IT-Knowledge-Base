---
layout: default
title: "把 PVE／PBS 通知改成繁體中文"
date: 2026-09-01
categories: [PVE, PBS, Notification]
last_modified_at: 2026-10-16
---
{% raw %}

# 把 PVE／PBS 通知改成繁體中文

> **一句話**：Proxmox 寄來的備份通知信預設是英文；這篇用一組「中文範本」把信件內容換成繁體中文，而且隨時可以改回來。

| 項目 | 內容 |
| --- | --- |
| 適合誰看 | 第一次接觸 Proxmox 通知、看不太懂英文備份信的人 |
| 需要的權限 | PVE 或 PBS 主機的 root |
| 花費時間 | 約 10 分鐘（含確認） |
| 風險 | 低：只換信件文字，不影響備份本身；安裝前會自動備份，可以完整還原 |
| 驗證程度 | PVE 9.2.11 已完整實測（2026-09-01）；PBS 4.2.5 的範本已準備，完整流程**尚未實測** |

## 1. 先認識幾個名詞

讀下去之前，先把這幾個詞弄清楚：

| 名詞 | 白話解釋 |
| --- | --- |
| **PVE**（Proxmox VE） | 跑虛擬機和容器的平台，本環境是三台主機組成的叢集 |
| **PBS**（Proxmox Backup Server） | 專門存放 PVE 備份的伺服器 |
| **通知（Notification）** | PVE／PBS 在某件事發生時自動寄出的信，例如「備份完成」「驗證失敗」 |
| **範本（Template）** | 信件的「格式模板」。系統把實際資料（主機名稱、成功或失敗、大小）填進範本裡的空格，就變成一封信 |
| **`.hbs` 檔** | 範本檔案的格式（Handlebars）。裡面像 `{{fqdn}}` 這種雙大括號，就是「要填資料的空格」 |
| **覆寫目錄（override）** | Proxmox 官方預留的資料夾：只要在這裡放同名的範本，系統就會改用你的版本，不必修改原廠檔案 |

用一個例子看懂範本。這是 PVE 備份信的**主旨範本**：

```text
【PVE 備份通知】 {{fqdn}}：{{status-text}}
```

寄信時，系統會把 `{{fqdn}}` 換成主機名稱、`{{status-text}}` 換成結果，變成：

```text
【PVE 備份通知】 node10.example：備份成功
```

## 2. 它怎麼運作

```text
備份工作結束
   ↓
PVE 準備寄信：先看「覆寫目錄」有沒有範本
   ├─ 有（安裝了中文範本）→ 用中文範本
   └─ 沒有                  → 用原廠的英文範本（/usr/share 底下）
   ↓
填入實際資料 → 寄出
```

重點有三個：

- **不改原廠檔案**：中文範本放在覆寫目錄，原廠的英文範本（`/usr/share` 底下）完全不動。套件更新時不會被覆蓋，也不會造成衝突。
- **只換文字**：收件人是誰、什麼情況要寄、透過哪個信箱寄，都還是由原本的「通知設定」決定。
- **不用重開服務**：範本是「寄信當下」才讀取，裝好後下一封通知就會是中文。

| 產品 | 覆寫目錄 |
| --- | --- |
| PVE | `/etc/pve/notification-templates/default/` |
| PBS | `/etc/proxmox-backup/notification-templates/default/` |

> PVE 的 `/etc/pve` 是**叢集共用**的資料夾（由 pmxcfs 管理）：在一台放好，三台都看得到，所以只需要安裝一次。

## 3. 它翻譯了哪些信？

| 產品 | 通知 | 什麼時候會寄 |
| --- | --- | --- |
| PVE | vzdump 備份（純文字與 HTML 兩種格式） | VM／容器備份工作結束時 |
| PBS | Garbage Collection（GC） | 清理不再使用的備份資料區塊後 |
| PBS | Prune | 依保留規則刪除舊備份後 |
| PBS | Verification | 檢查備份資料是否完整後 |
| PBS | Sync | 從另一台 PBS 同步備份後 |
| PBS | Package Updates | 有套件可以更新時 |

PBS 的每種通知都有「成功」（`-ok`）和「失敗」（`-err`）兩份範本。

## 4. 程式放在哪裡

安裝腳本與範本放在本知識庫的 [`tools/proxmox-zh-tw-notification/`](https://github.com/kbwangtw/IT-Knowledge-Base/tree/main/tools/proxmox-zh-tw-notification)（2026-10-16 從原本的獨立 repository 併入，之後只維護這一份）：

```text
tools/proxmox-zh-tw-notification/
├── install.sh      # 安裝
├── uninstall.sh    # 移除並還原
├── pve/default/    # PVE 範本（3 個檔案）
└── pbs/default/    # PBS 範本（18 個檔案）
```

## 5. 動手做：PVE

### 5-1 安裝前檢查

PVE 叢集要先確認「叢集正常、共用資料夾可以寫入」：

```bash
pvecm status | grep -i quorate      # 要看到 Quorate: Yes
mount | grep /etc/pve               # 要看到 /etc/pve 有掛載
```

> **為什麼要檢查？** 叢集失去多數節點（quorum）時，`/etc/pve` 會變成唯讀，安裝會失敗。

### 5-2 安裝

```bash
curl -fsSL https://raw.githubusercontent.com/kbwangtw/IT-Knowledge-Base/main/tools/proxmox-zh-tw-notification/install.sh | bash -s -- --pve
```

這行指令在做什麼：

| 片段 | 意思 |
| --- | --- |
| `curl -fsSL <網址>` | 從 GitHub 下載安裝腳本（`-f` 下載失敗就停止） |
| `\| bash` | 把下載的腳本交給 bash 執行 |
| `-s -- --pve` | 傳給腳本的參數：只安裝 PVE 的範本 |

> ⚠️ **「下載後直接執行」的風險**：這種寫法會執行網路上**當下**的腳本內容。正式環境比較謹慎的做法是先下載、看過內容再執行：
>
> ```bash
> curl -fsSLO https://raw.githubusercontent.com/kbwangtw/IT-Knowledge-Base/main/tools/proxmox-zh-tw-notification/install.sh
> less install.sh          # 看過內容
> bash install.sh --pve
> ```
>
> 本機執行時，腳本找不到同目錄的範本，會自動從 GitHub 下載範本。

腳本參數：`--pve`、`--pbs`、`--all`（兩種都裝）、`--auto`（自動判斷，預設）。知道主機是哪一種時，明確指定比較容易確認它做了什麼。

### 5-3 確認有裝上

```bash
find /etc/pve/notification-templates/default -maxdepth 1 -type f -name '*.hbs' -print
```

應該看到三個檔案：`vzdump-subject.txt.hbs`、`vzdump-body.txt.hbs`、`vzdump-body.html.hbs`。

### 5-4 確認真的變成中文

檔案在不代表信件正確，**一定要收到一封真的備份信**才算完成：在 PVE 網頁對一台 VM／容器手動執行一次備份（Backup now），確認收到的信是中文、主機名稱與大小等資料都有正確帶入。

> 網頁 **Datacenter → Notifications** 的「測試通知」用的是另一種通用範本，不會用到備份範本，所以**不能**用它判斷備份信有沒有翻譯成功。

## 6. 動手做：PBS（尚未完整實測）

步驟和 PVE 相同，參數改成 `--pbs`：

```bash
curl -fsSL https://raw.githubusercontent.com/kbwangtw/IT-Knowledge-Base/main/tools/proxmox-zh-tw-notification/install.sh | bash -s -- --pbs
find /etc/proxmox-backup/notification-templates/default -maxdepth 1 -type f -name '*.hbs' -print   # 應有 18 個檔案
```

接著等待 GC、Verify 等工作下一次執行，確認收到的信是中文。完成實測後，把結果補進本文。

## 7. 想改回原本的英文

```bash
# PVE
curl -fsSL https://raw.githubusercontent.com/kbwangtw/IT-Knowledge-Base/main/tools/proxmox-zh-tw-notification/uninstall.sh | bash -s -- --pve
# PBS（移除流程同樣尚未實測）
curl -fsSL https://raw.githubusercontent.com/kbwangtw/IT-Knowledge-Base/main/tools/proxmox-zh-tw-notification/uninstall.sh | bash -s -- --pbs
```

移除會刪掉中文範本；如果安裝前覆寫目錄裡原本就有你自己的範本，會還原成安裝前的樣子。移除後一樣觸發一封通知確認。

## 8. 安裝時它幫你備份了什麼

| 位置 | 用途 |
| --- | --- |
| `/var/backups/proxmox-zh-tw-notification/<產品>-<時間>/` | 每次安裝前，覆寫目錄若已有檔案就整份備份一次 |
| `/var/lib/proxmox-zh-tw-notification/<產品>/original/` | **第一次安裝前**的原始狀態，移除時靠它還原 |

- 重新安裝不會覆蓋「第一次安裝前的狀態」，所以裝幾次都能還原回最初的樣子。
- ⚠️ `/var/lib/proxmox-zh-tw-notification/` **不要當成暫存檔刪掉**，刪了就無法自動還原。
- 移除時備份目錄不會自動刪除，需要時自行清理。
- 程式從獨立 repository 併入知識庫後，這兩個位置**沒有改變**，以前裝的版本可以直接用新位置的 `uninstall.sh` 移除。

## 9. 本環境的實測紀錄

| 日期 | 產品 | 內容 | 結果 |
| --- | --- | --- | --- |
| 2026-09-01 | PVE 9.2.11 | 安裝 → 收到中文備份信 → 移除並還原 → 清掉 state 後重新安裝 | ✅ 全部正常 |
| — | PBS 4.2.5 | 安裝、收信、移除 | ⏳ 尚未實測 |
| 2026-10-16 | 程式碼 | 併入知識庫 `tools/`；以測試目錄執行安裝、移除，原有自訂範本正確還原 | ✅ |

## 10. 常見問題

| 現象 | 可能原因與檢查 |
| --- | --- |
| `/etc/pve` 不能寫入 | 叢集失去 quorum，或 pve-cluster 服務異常：`pvecm status`、`systemctl status pve-cluster` |
| 出現 chmod 或權限錯誤 | `/etc/pve` 的權限由 pmxcfs 管理，不是一般資料夾；腳本對 PVE 已用一般複製處理，若仍出錯請回報 |
| 裝好了還是英文 | ① 看的是不是安裝後的**新**信 ② 這種信有沒有在第 3 節的清單裡 ③ 範本是否放在正確產品的目錄 |
| 自動判斷找不到產品 | 用 `--pve` 或 `--pbs` 明確指定 |
| 移除時說找不到安裝紀錄 | 檢查 `/var/lib/proxmox-zh-tw-notification/`；不要以為沒訊息就是還原成功，先對照第 8 節的備份 |

## 11. 升級 PVE／PBS 之後要注意

Proxmox 更新時，官方範本偶爾會**新增或改名變數**（`{{...}}` 裡的名稱）。中文範本是依當時的官方範本翻譯的，升級後如果變數變了，信件可能少資料或顯示異常。

**升級後的檢查**：手動執行一次備份，確認備份信內容完整。有問題時先移除中文範本（第 7 節）恢復正常寄信，再比對新版官方範本（PVE：`/usr/share/pve-manager/templates/default/`；PBS：`/usr/share/proxmox-backup/templates/default/`）更新翻譯。

## 12. 待辦

| 項目 | 說明 |
| --- | --- |
| 封存原本的獨立 repository | 在 `kbwangtw/proxmox-zh-tw-notification` 的 README 最上方加註「已併入 IT-Knowledge-Base `tools/proxmox-zh-tw-notification/`，不再維護」，再到 Settings → Danger Zone → **Archive this repository**。封存後舊網址仍可下載，已寫在別處的舊指令不會失效 |
| PBS 中文通知實測 | 在 PBS31 依第 6 節安裝 → 等 GC、Verify、Prune 等工作執行，確認收到中文信、資料正確 → 依第 7 節移除並確認還原 → 結果補進第 9 節。可與「PBS 任務失敗通知」一起規劃（PBS 本身能在工作失敗時寄信） |

## 13. 延伸閱讀

- [Proxmox VE 官方文件：Notifications](https://pve.proxmox.com/pve-docs/chapter-notifications.html)：通知的目標（Target）、比對規則（Matcher）與範本
- [Proxmox Backup Server 官方文件：Notifications](https://pbs.proxmox.com/docs/notifications.html)
- [Handlebars 語法](https://handlebarsjs.com/guide/)：想自己修改範本時參考
- 本知識庫：[把三台 PVE 的日誌集中到 Graylog](../proxmox-graylog-syslog-pipeline-sop/)：Graylog 告警信是另一套機制，中文化方式不同
{% endraw %}
