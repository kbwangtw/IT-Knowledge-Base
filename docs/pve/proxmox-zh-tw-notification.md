---
layout: default
title: "把 PVE／PBS 通知改成繁體中文"
date: 2026-09-01
categories: [PVE, PBS, Notification]
last_modified_at: 2026-10-19
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
| 驗證程度 | PVE 9.2.11 已完整實測（2026-09-01）；PBS 4.2.8 已完整實測（2026-10-19）：成功信、GC／Verify 失敗信、移除還原、重新安裝 |

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

安裝腳本與範本放在本知識庫的 [`tools/proxmox-zh-tw-notification/`](https://github.com/kbwangtw/IT-Knowledge-Base/tree/main/tools/proxmox-zh-tw-notification)（2026-10-16 從原本的獨立 repository 併入，原 repository 已於 2026-10-19 封存，之後只維護這一份）：

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

## 6. 動手做：PBS

步驟和 PVE 相同，參數改成 `--pbs`：

```bash
curl -fsSL https://raw.githubusercontent.com/kbwangtw/IT-Knowledge-Base/main/tools/proxmox-zh-tw-notification/install.sh | bash -s -- --pbs
find /etc/proxmox-backup/notification-templates/default -maxdepth 1 -type f -name '*.hbs' -print   # 應有 18 個檔案
```

接著等待 GC、Verify 等工作下一次執行，或在網頁手動執行一次（Datastore → Prune & GC → Start Garbage Collection），確認收到的信是中文。想同時確認失敗信，見第 9-1 節的做法。

## 7. 想改回原本的英文

```bash
# PVE
curl -fsSL https://raw.githubusercontent.com/kbwangtw/IT-Knowledge-Base/main/tools/proxmox-zh-tw-notification/uninstall.sh | bash -s -- --pve
# PBS
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
| 2026-10-19 | PBS 4.2.8 | 每日 GC、Verify 成功信為中文；在測試用 datastore 實測 GC 失敗、Verify 失敗、移除還原、重新安裝（做法見 9-1） | ✅ 全部正常 |
| 2026-10-16 | 程式碼 | 併入知識庫 `tools/`；以測試目錄執行安裝、移除，原有自訂範本正確還原 | ✅ |

### 9-1 PBS 失敗信與移除還原怎麼測（2026-10-19）

**做什麼**：正式環境很少失敗，等不到失敗信。做法是在 PBS 本機磁碟建一個**測試用 datastore**（`zhtest`），在它身上故意製造失敗。正式的 datastore 全程不受影響。

```text
建 zhtest ─▶ 拿掉 .chunks 權限跑 GC ─▶ 【PBS 垃圾資料回收失敗】
          ─▶ 做一份小備份、改壞一個 chunk、跑 Verify Job ─▶ 【PBS 備份驗證失敗】
          ─▶ uninstall.sh ─▶ GC ─▶ 英文信 ─▶ install.sh ─▶ GC ─▶ 中文信
          ─▶ 清理
```

| 名詞 | 白話解釋 |
| --- | --- |
| **datastore** | PBS 存放備份的地方，對應一個資料夾 |
| **chunk** | 備份被切成的一小塊資料，存在 datastore 的 `.chunks/` 底下 |
| **Verify Job** | 定期檢查備份資料有沒有損壞的排程；**只有 Verify Job 會寄驗證通知**，手動指令不會 |
| **API token** | 給程式用的登入憑證，可以只給特定權限、設有效期限 |

**① 建測試 datastore**（以下都在 PBS 主機上，以 root 執行）

```bash
proxmox-backup-manager datastore create zhtest /var/lib/zhtest-ds
proxmox-backup-manager datastore list
```

應該看到：清單多出 `zhtest`，路徑是 `/var/lib/zhtest-ds`。

**② GC 失敗信**

```bash
chmod 000 /var/lib/zhtest-ds/.chunks
proxmox-backup-manager garbage-collection start zhtest; echo "exit=$?"
chmod 750 /var/lib/zhtest-ds/.chunks
```

| 片段 | 意思 |
| --- | --- |
| `chmod 000 …/.chunks` | 拿掉存放 chunk 的資料夾權限，GC 寫不進去就會失敗 |
| `chmod 750` | 測完立刻把權限改回來 |

看到的結果：`TASK ERROR: atime safety check failed … EACCES: Permission denied`、`exit=255`，並收到**【PBS 垃圾資料回收失敗】zhtest**，「錯誤訊息」段落帶出完整的 `Permission denied` 內容。

**③ 做一份小的測試備份**

先建一個有效期限 1 天、只能操作 zhtest 的臨時 token（理由見第 10 節「`permission check failed`」）：

```bash
mkdir -p /tmp/zhtest-data
head -c 2M /dev/urandom > /tmp/zhtest-data/random.bin

umask 077
proxmox-backup-manager user generate-token root@pam zhtest --expire $(( $(date +%s) + 86400 )) > /root/zhtest-token.txt
export PBS_PASSWORD=$(grep -oP '"value"\s*:\s*"\K[^"]+' /root/zhtest-token.txt)
echo "token 密鑰長度：${#PBS_PASSWORD}"

proxmox-backup-manager acl update /datastore/zhtest DatastoreAdmin --auth-id 'root@pam!zhtest'
export PBS_FINGERPRINT=$(proxmox-backup-manager cert info | awk '/Fingerprint/ {print $NF}')
proxmox-backup-client backup zhtest.pxar:/tmp/zhtest-data --repository 'root@pam!zhtest@localhost:zhtest'
```

| 片段 | 意思 |
| --- | --- |
| `head -c 2M /dev/urandom` | 產生 2 MB 無意義的隨機資料當備份內容，不要拿真的設定檔來測 |
| `--expire $(( $(date +%s) + 86400 ))` | token 1 天後自動失效，忘了刪也不會一直有效 |
| `> /root/zhtest-token.txt` + `umask 077` | 密鑰存進只有 root 能讀的檔案，不顯示在畫面上 |
| `grep -oP '"value"…'` | 從檔案取出密鑰放進 `PBS_PASSWORD`，`proxmox-backup-client` 會自動讀這個變數 |
| `acl update /datastore/zhtest …` | 這個 token 只能碰 zhtest |
| `PBS_FINGERPRINT` | 自動確認憑證，不用回答 y/n |

看到的結果：`snapshot host/pbs31/2026-10-19T05:35:40Z  2.001 MiB`。

**④ Verify 失敗信**

改壞一個 chunk（路徑一定要是 `/var/lib/zhtest-ds/` 開頭）：

```bash
find /var/lib/zhtest-ds/.chunks -type f -mmin -60 -size +100k | head -3
CHUNK=<上面列出的第一個路徑>
printf 'CORRUPT' | dd of="$CHUNK" bs=1 seek=100 conv=notrunc
```

| 片段 | 意思 |
| --- | --- |
| `-size +100k` | 挑大一點的 chunk，確定是資料本體 |
| `dd … seek=100 conv=notrunc` | 從第 100 個 byte 覆寫 7 個字元，檔案大小不變，模擬硬碟壞軌 |

接著在網頁：**Datastore → zhtest → Verify Jobs → Add**（Job ID `zhtest-verify`，Schedule 隨意，Skip verified 不勾）→ 選取 → **Run now**。

看到的結果：task log 出現 `zhtest.pxar.didx failed: chunks could not be verified`、`Failed to verify the following snapshots/groups: host/pbs31/2026-10-19T05:35:40Z`、`queued notification`，並收到**【PBS 備份驗證失敗】zhtest**，信裡列出同一筆 snapshot。

**⑤ 移除還原，再重新安裝**

```bash
curl -fsSL https://raw.githubusercontent.com/kbwangtw/IT-Knowledge-Base/main/tools/proxmox-zh-tw-notification/uninstall.sh | bash -s -- --pbs
ls /etc/proxmox-backup/notification-templates/default/ 2>&1    # 應顯示 No such file or directory
```

網頁 **zhtest → Prune & GC → Start Garbage Collection**：收到英文的 `Garbage Collect Datastore 'zhtest' successful`。

```bash
curl -fsSL https://raw.githubusercontent.com/kbwangtw/IT-Knowledge-Base/main/tools/proxmox-zh-tw-notification/install.sh | bash -s -- --pbs
ls /etc/proxmox-backup/notification-templates/default/ | wc -l  # 應為 18
```

再跑一次 GC：收到中文的**【PBS 垃圾資料回收成功】zhtest**。

> 這次 GC log 有一行 `warning: unable to access non-existent chunk …`：那是 ④ 被 Verify 標成 `.bad` 的 chunk，屬於預期中的警告。

**⑥ 清理**

```bash
proxmox-backup-manager verify-job remove zhtest-verify
proxmox-backup-manager user delete-token root@pam zhtest
shred -u /root/zhtest-token.txt
unset PBS_PASSWORD PBS_FINGERPRINT
proxmox-backup-manager datastore remove zhtest
rm -rf /var/lib/zhtest-ds /tmp/zhtest-data
proxmox-backup-manager acl list | grep -i zhtest || echo "ACL 已清乾淨"
```

| 片段 | 意思 |
| --- | --- |
| `shred -u` | 先覆寫再刪除存有密鑰的檔案 |
| `datastore remove` | 只刪設定，資料夾要另外 `rm -rf` |
| 最後一行 | 確認 token 的權限設定也一起不見了 |

## 10. 常見問題

| 現象 | 可能原因與檢查 |
| --- | --- |
| `/etc/pve` 不能寫入 | 叢集失去 quorum，或 pve-cluster 服務異常：`pvecm status`、`systemctl status pve-cluster` |
| 出現 chmod 或權限錯誤 | `/etc/pve` 的權限由 pmxcfs 管理，不是一般資料夾；腳本對 PVE 已用一般複製處理，若仍出錯請回報 |
| 裝好了還是英文 | ① 看的是不是安裝後的**新**信 ② 這種信有沒有在第 3 節的清單裡 ③ 範本是否放在正確產品的目錄 |
| 自動判斷找不到產品 | 用 `--pve` 或 `--pbs` 明確指定 |
| 用 `chmod 000` 拿掉整個 datastore 資料夾的權限後，PBS 網頁打不開 | 網頁會去讀每個 datastore 的備份清單，log 一直出現 `list groups error on datastore … EACCES`。改回 `chmod 750` 就恢復。製造 GC 失敗只要拿掉 `.chunks` 的權限（9-1 ②） |
| `proxmox-backup-client` 用 root@pam 登入，密碼正確卻出現 `permission check failed` | 推測是 root@pam 開了兩步驟驗證，命令列無法輸入驗證碼。改用只給該 datastore 權限的臨時 API token（9-1 ③） |
| `generate-token … --output-format json` 出現 `schema does not allow additional properties` | 這個子指令不支援 `--output-format`，拿掉即可；輸出本來就是 JSON |
| 移除時說找不到安裝紀錄 | 檢查 `/var/lib/proxmox-zh-tw-notification/`；不要以為沒訊息就是還原成功，先對照第 8 節的備份 |

## 11. 升級 PVE／PBS 之後要注意

Proxmox 更新時，官方範本偶爾會**新增或改名變數**（`{{...}}` 裡的名稱）。中文範本是依當時的官方範本翻譯的，升級後如果變數變了，信件可能少資料或顯示異常。

**升級後的檢查**：手動執行一次備份，確認備份信內容完整。有問題時先移除中文範本（第 7 節）恢復正常寄信，再比對新版官方範本（PVE：`/usr/share/pve-manager/templates/default/`；PBS：`/usr/share/proxmox-backup/templates/default/`）更新翻譯。

## 12. 待辦

- [x] 封存原本的獨立 repository `kbwangtw/proxmox-zh-tw-notification`：README 最上方已加註搬家說明，並於 2026-10-19 封存（唯讀）。舊網址仍可下載，但抓到的是舊版；請一律使用本文的安裝指令
- [x] PBS 中文通知實測（2026-10-19）：成功信、GC 失敗信、Verify 失敗信都是中文且資料正確；移除後變回英文、重新安裝後恢復中文（見 9-1）

## 13. 延伸閱讀

- [Proxmox VE 官方文件：Notifications](https://pve.proxmox.com/pve-docs/chapter-notifications.html)：通知的目標（Target）、比對規則（Matcher）與範本
- [Proxmox Backup Server 官方文件：Notifications](https://pbs.proxmox.com/docs/notifications.html)
- [Handlebars 語法](https://handlebarsjs.com/guide/)：想自己修改範本時參考
- 本知識庫：[把三台 PVE 的日誌集中到 Graylog](../proxmox-graylog-syslog-pipeline-sop/)：Graylog 告警信是另一套機制，中文化方式不同
{% endraw %}
