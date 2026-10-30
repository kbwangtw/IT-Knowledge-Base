---
layout: default
title: "PBS 更新後，怎麼確認備份還能用？"
date: 2026-09-11
categories: [PVE, PBS, ProxCenter, DR]
permalink: /docs/pve/ProxCenter-PBS-Update-and-DR-Validation-SOP/
last_modified_at: 2026-10-29
---

# PBS 更新後，怎麼確認備份還能用？

> **一句話**：更新 PBS 要分三段確認：**更新前**能停、能回來、找得到資料；**重開後**從主機一路查到 PVE 讀得到備份；**還原演練**證明備份真的開得起來。三段的證據要分開看，不能混為一談。

| 項目 | 內容 |
| --- | --- |
| 適合誰看 | 第一次更新 PBS、不確定更新完要查什麼的人 |
| 環境 | ProxCenter 1.4.9；PBS31（PBS 4.2.5 → 4.2.8）；PVE 三節點 |
| 日期 | 2026-09-11 首次；2026-10-13 kernel 更新；2026-10-14 清理舊 kernel；2026-10-24 kernel -23 → -25；2026-10-29 kernel -25 → -26；2026-10-30 清理 -23 |
| 結論 | ✅ 更新與重開後服務正常、PVE 讀得到 141 份備份；✅ CT110 還原成 CT210 可開機；✅ 四台 kernel 一致為 -23、舊 kernel 清理完成；✅ 10/24 再更新到 -25，並清掉 -22 和 PVE 的 6.17（第 11 節）；✅ 10/29 更新到 -26（第 12 節），10/30 清掉 -23，四台剩 -25、-26（12-2）；⏳ 業務功能與完整 RTO／RPO 未驗證 |

> 文中 IP 都是文件示範位址（管理網 192.0.2.0/24、內部網段 198.51.100.0/24）；照做前請換成自己的位址。

> **兩件事要分開看**：更新成功，不代表重新測過所有備份；備份顯示 Verify OK，也不等於應用程式已成功還原。

## 1. 先認識幾個名詞

| 名詞 | 白話解釋 |
| --- | --- |
| **PBS（Proxmox Backup Server）** | 專門存 PVE 備份的伺服器 |
| **Datastore** | PBS 上存放備份的空間；本案叫 Tokyo16 |
| **CIFS 掛載** | 把 NAS 的網路資料夾掛成本機目錄；本案 Tokyo16 實際在 NAS 上 |
| **Verify** | PBS 檢查備份資料有沒有損壞，不等於實際還原 |
| **API token** | 給程式（ProxCenter）用的登入憑證 |
| **ACL** | 權限設定：誰對哪個路徑有什麼權限 |
| **`apt -s`** | 模擬執行（simulate），只顯示會做什麼，不真的做 |
| **RTO／RPO** | 多久能恢復服務／最多會遺失多久的資料 |

## 2. 本次環境

| 元件 | 本次用途 |
| --- | --- |
| ProxCenter 1.4.9／CT110 | 管理介面，原管理位址 192.0.2.30 |
| PBS31／PBS 4.2.5 | 備份伺服器；管理網 192.0.2.31、資料網 198.51.100.31 |
| Tokyo16 | PBS datastore；資料來自 CIFS 掛載 `/mnt/tokyo16`，來源 `//198.51.100.16/PBS_BK_Folder` |
| PVE node12 | 還原演練的目標節點 |
| CT210／VM_Pool | 新的測試容器與儲存位置 |
| 192.0.2.210:3000 | 測試容器的網頁入口 |

> ⚠️ **資料夾存在不代表網路磁碟已掛上**。沒掛上時，備份會寫進本機的空目錄，必須查實際掛載來源。

## 3. 本次到底確認了哪些事

| 項目 | 已有證據 | 還不能推論 |
| --- | --- | --- |
| PBS 更新 | 9 個套件更新、1 個新增、0 個移除 | 其他版本也會得到同樣結果 |
| 重開後服務 | kernel 已換、沒有 failed unit、PBS 服務正常 | 所有外部工作都逐筆測完 |
| 備份清單 | PVE 讀得到；UI 顯示 141 份快照，61 VM／80 CT | 更新後重新驗證了全部 141 份 |
| Verify | 畫面顯示 141／141 已驗證 | 每一份都開機還原過 |
| CT210 演練 | 四個 Docker 容器 healthy，網頁可用 | 所有正式業務功能都驗收完 |

## 4. 步驟一：更新前檢查

**做什麼**：確認「能停、能回來、找得到資料」。

- 等備份、還原、驗證等工作都結束。
- 保留管理主控台（萬一網路斷了還能操作）。
- 備份 PBS 設定，並保護其中的憑證。
- 本次**沒有**順便移除舊 kernel 或升級 ZFS pool 格式。

**在 PBS31 執行**：

```bash
proxmox-backup-manager versions                               # PBS 各元件版本
uname -r                                                      # 目前執行中的 kernel
systemctl --failed --no-pager                                 # 有沒有失敗的服務
systemctl status proxmox-backup proxmox-backup-proxy --no-pager
ip -br addr
ip route
findmnt --mountpoint /mnt/tokyo16                             # CIFS 真的有掛上嗎
df -h / /boot /mnt/tokyo16                                    # 空間夠不夠
dpkg --audit                                                  # 有沒有裝到一半的套件
apt-mark showhold                                             # 有沒有被鎖住不更新的套件
```

**在 PVE 節點執行**：

```bash
pvesm status --storage PBS31
pvesm list PBS31
```

> 清單列得出來是「連得上」的證據；「還原得了」要靠第 8 節的演練確認。

## 5. 踩雷：ProxCenter 出現 403

**錯誤訊息**：

```text
PBS 403 /nodes/localhost/apt/update: permission check failed
```

**處理**：重新建立 API token、設定使用者與 token 在 `/` 的 Admin ACL，再把憑證重新填進 ProxCenter，功能就恢復了。

- 因為同時改了好幾個地方，**無法斷定**是哪一個設定解決的。
- 這是本案採用的**高權限**解法，不是驗證過的最小權限配置。要縮小權限，得依實際 API 操作另外測試。

## 6. 步驟二：先模擬，再更新

**做什麼**：本案用 Debian Trixie、security、updates 和 pbs-no-subscription 來源，停用 enterprise 來源（這是當時的訂閱選擇，不代表所有 PBS 都要這樣改）。

**先核對來源並模擬**：

```bash
grep -R -n -E '^(deb |Types:|URIs:|Suites:|Components:|Enabled:|Signed-By:)' /etc/apt/sources.list /etc/apt/sources.list.d/
apt-cache policy
apt update
apt list --upgradable
apt -s dist-upgrade
```

| 指令 | 用途 |
| --- | --- |
| `grep -R …` | 列出所有套件來源設定 |
| `apt-cache policy` | 每個來源的優先順序 |
| `apt list --upgradable` | 哪些套件有新版 |
| `apt -s dist-upgrade` | **模擬**更新，看會裝什麼、移除什麼 |

**確認沒有不預期的移除**，才真正執行：

```bash
apt dist-upgrade
```

**本次結果**：

| 元件 | 更新前 | 更新後 |
| --- | --- | --- |
| kernel | 7.0.14-12-pve | 7.0.14-16-pve |
| ZFS | 2.4.3-pve1 | 2.4.4-pve1 |
| firmware 套件 | 3.18-5 | 3.18-6 |

在 ProxCenter 1.4.9 裡，「刷新更新清單」不等於「安裝更新」；實際安裝是在 PBS shell 完成。這只是這個版本的 UI 行為，不代表未來版本也一樣。

## 7. 步驟三：重開後，從主機一路查到 PVE

**重開前**，確認套件狀態和新 kernel 都在（重開前也要確認工作已停、有主控台可用）：

```bash
dpkg --audit
ls -l /boot/vmlinuz-7.0.14-16-pve /boot/initrd.img-7.0.14-16-pve
```

**重開後**，在 PBS31 核對：

```bash
uname -r
systemctl --failed --no-pager
systemctl status proxmox-backup proxmox-backup-proxy --no-pager
findmnt --mountpoint /mnt/tokyo16
df -h /mnt/tokyo16
ip -br addr
ip route
```

**看到的結果**：

- kernel 是 7.0.14-16-pve、failed unit 0、雙網卡正常。
- CIFS 自動掛回，容量約 2.7T，使用 703G，可用 2.0T。
- PVE 上 PBS31 是 active、清單讀得到；ProxCenter 顯示沒有待更新套件。

> PBS UI 顯示的是另一種單位：使用 702.16 GiB、可用 1.92 TiB、總量 2.61 TiB。**單位不同（G vs GiB）不代表容量遺失**。

## 8. 步驟四：還原演練（CT110 → CT210）

這段是既有的還原紀錄，**不能**當成「這次更新後又完整重做一次」的證據。詳細過程見 [從 PBS 還原 ProxCenter](https://kbwangtw.github.io/IT-Knowledge-Base/docs/pve/proxcenter-pbs-restore-dr-runbook/)。

### 8-1 對齊 PBS 的連線位址

曾出現：

```text
No PVE storage on node node12 maps to PBS datastore Tokyo16
```

**原因**：PVE 用 PBS 的**資料網**位址，ProxCenter 卻用**管理網**位址。

**解法**：替 ProxCenter 加一張 198.51.100.30/24 網卡（不設預設閘道），並把 PBS endpoint 對齊到 198.51.100.31:8007，就恢復了。這證明調整後可運作，但沒有從程式碼確認產品怎麼比對。遇到相同訊息，仍要核對節點、datastore、storage 設定與連線，不能只看名稱相同。

### 8-2 先還原，暫時不要開機

| 選項 | 本次值 | 原因 |
| --- | --- | --- |
| 新 VMID | 210 | 不覆蓋正式 CT110 |
| 目標 | node12／VM_Pool | 建立獨立測試副本 |
| Unique MAC | ON | 避免網卡位址重複 |
| Start after restore | OFF | 先處理 IP 和自動工作 |
| Override name | OFF | 本版本開啟時出現 `name property is not defined in schema`（400） |

關閉 Override name 後成功；但沒有完整 request payload，不能說成已定位的程式缺陷。

### 8-3 所有網卡都查完才啟動

```bash
pct status 210
pct config 210
```

- 測試副本改用 192.0.2.210。若有第二張靜態 IP 網卡，也要避免和正式機重複。
- 修改時保留原本的 bridge、VLAN、MTU 等欄位，**不要**用一條簡化指令蓋掉整份網路設定。
- ProxCenter 副本還帶著正式的 API token 和排程。**換了新 IP 不等於完全隔離**，啟動前要安排隔離或停用會操作正式環境的自動工作。

### 8-4 確認系統和程式都起來

確認隔離後才啟動 CT210，在容器內檢查：

```bash
ip -br addr
ip route
systemctl --failed --no-pager
docker ps
docker ps -a
ss -lntp
```

**看到的結果**：proxcenter-orchestrator、frontend、weasyprint、postgres 四個容器都是 healthy。網頁在 3000 埠：

```bash
curl -I http://192.0.2.210:3000
```

這代表系統開機和基本網頁恢復；業務操作、資料內容和新備份仍要另外測。

## 9. 2026-10-13：kernel 7.0.14-19 → 7.0.14-23

PBS Web UI 的 Updates 顯示 `proxmox-kernel-7.0` 可以從 7.0.14-22 升到 7.0.14-23。照第 4 節做更新前檢查：

| 檢查 | 結果 |
| --- | --- |
| PBS | 4.2.8 |
| 執行中 kernel | **7.0.14-19-pve** |
| failed unit | 0 |
| CIFS | 有掛載，Tokyo16 2.7T，已用約 901G（34%） |
| 根目錄 | 44G，可用 36G（`/boot` 在同一分割區） |
| `apt -s dist-upgrade` | 只有 2 個 `Inst`，沒有 `Remv` |

> **發現：已安裝的是 -22，執行中的卻是 -19**。之前裝了 -22 但一直沒重開，-22 從沒真正用過。**PBS 裝完 kernel 更新要重開才會生效。**

`apt dist-upgrade` 後重開，再核對：

| 檢查 | 結果 |
| --- | --- |
| kernel | 7.0.14-23-pve |
| `proxmox-backup`、`proxmox-backup-proxy` | active、active |
| CIFS | 自動掛回，容量與重開前相同 |
| `ls /mnt/tokyo16/ct/101/ \| wc -l` | 11（10 筆備份加 owner） |
| PVE `pvesm status --storage PBS31` | active，33.72% |
| PVE `pvesm list PBS31 \| wc -l` | 141（140 筆備份加標題列） |

重開後 `systemctl --failed` 列出 `session-1.scope`。這是 root 的一個**登入連線**，不是服務；用 `loginctl list-sessions` 確認後，以 `systemctl reset-failed session-1.scope` 清除，failed unit 回到 0。

更新後 PBS31 和三台 PVE 的 kernel 一致。同日也取消了 PBS 的訂閱提示、刪除沒有規則的 Prune Job、把 Verify 改到 02:00，見 [Ceph 慢操作與備份排程](https://kbwangtw.github.io/IT-Knowledge-Base/docs/pve/ceph-bluestore-slow-op-backup-schedule/) 和 [取消訂閱提示](https://kbwangtw.github.io/IT-Knowledge-Base/docs/pve/pve9-subscription-nag-removal/)。

**維護時段**：本環境每晚 21:00～22:30 接收備份、00:00 起 GC、02:00 起 Verify，更新和重開都要避開。

## 10. 2026-10-14：清理舊 kernel

四台都在 -23 開機正常後，清掉舊 kernel。**每一步都先用 `-s` 模擬，看清楚會移除什麼再執行。**

### 10-1 先用 autoremove

```bash
uname -r
apt autoremove -s 2>/dev/null | grep -E "^Remv"
```

三台 PVE 和 PBS31 的模擬結果都只有 `proxmox-kernel-7.0.14-20-pve-signed`，沒有 ceph、pve、qemu、corosync、proxmox-backup 等套件，執行中的 -23 也不在清單裡。執行 `apt autoremove -y` 後，三台 PVE 剩下：

```text
proxmox-kernel-7.0
proxmox-kernel-7.0.14-22-pve-signed
proxmox-kernel-7.0.14-23-pve-signed
```

### 10-2 PBS31 多兩個要指定移除

PBS31 還留著 `proxmox-kernel-7.0.0-3-pve-signed` 和 `proxmox-kernel-7.0.14-19-pve-signed`。

**為什麼 autoremove 沒清掉**：`autoremove` 只移除「因相依關係自動裝進來、現在沒人需要」的套件。7.0.0-3 很可能是安裝光碟附的原始 kernel，被標記為「手動安裝」，所以不會被自動清掉。

已有 -23（使用中）和 -22（備用），這兩個用名稱指定移除：

```bash
apt remove -s proxmox-kernel-7.0.0-3-pve-signed proxmox-kernel-7.0.14-19-pve-signed | grep -E "^(Remv|Inst)"
apt remove -y proxmox-kernel-7.0.0-3-pve-signed proxmox-kernel-7.0.14-19-pve-signed
dpkg -l "proxmox-kernel-7*" | awk '/^ii/ {print $2}'               # 剩下哪些 kernel 套件
grep -oE "vmlinuz-[0-9.]+-[0-9]+-pve" /boot/grub/grub.cfg | sort -u  # 開機選單剩哪些
```

**看到的結果**：模擬只列出這兩個 `Remv`、沒有 `Inst`；移除後 PBS31 也只剩 `proxmox-kernel-7.0`、-22、-23，GRUB 開機選單只剩 `vmlinuz-7.0.14-22-pve` 和 `vmlinuz-7.0.14-23-pve`。不需要重開，也不會重啟服務。

### 10-3 `proxmox-kernel-7.0` 不能刪

它是**指標套件**，本身幾乎沒內容，作用是永遠指向最新的 7.0 版 kernel，讓 `apt upgrade` 自動裝上新 kernel。在 node10 模擬刪除：

```bash
apt-cache rdepends --installed proxmox-kernel-7.0
apt remove -s proxmox-kernel-7.0 | grep -E "^Remv"
```

```text
Reverse Depends:
  proxmox-default-kernel

Remv proxmox-ve [9.2.0]
Remv proxmox-default-kernel [2.1.0]
Remv proxmox-kernel-7.0 [7.0.14-23]
```

依賴鏈是 `proxmox-ve` → `proxmox-default-kernel` → `proxmox-kernel-7.0` → 實際 kernel。刪掉指標套件會**一路往上把 `proxmox-ve` 一起移除**，之後收不到 kernel 更新，升級時也可能缺元件。

> ⚠️ 模擬清單出現 `proxmox-ve` 就要停下來。

### 10-4 清理 kernel 的原則

1. 先 `-s` 模擬，確認 `uname -r` 的版本不在移除清單。
2. 至少保留**使用中**和**上一版**；新 kernel 有問題時，可以從開機選單選回上一版。
3. 只清有版本號的 `proxmox-kernel-7.0.14-xx-pve-signed`；`proxmox-ve`、`proxmox-default-kernel`、`proxmox-kernel-7.0` 永遠保留。
4. 移除後確認開機選單只剩預期的版本。

## 11. 2026-10-24：kernel 7.0.14-23 → 7.0.14-25

PVE 三台用 ProxCenter 更新完（見 [ProxCenter 逐台更新 PVE](https://kbwangtw.github.io/IT-Knowledge-Base/docs/pve/proxcenter-ceph-rolling-update/) 第 12 節）後，接著更新 PBS31。時間是中午，避開 21:00 備份、00:00 GC、02:00 Verify。

**更新前檢查（PBS31）**：

```bash
proxmox-backup-manager task list 2>/dev/null | grep -i running || echo "沒有執行中的工作"
findmnt --mountpoint /mnt/tokyo16 >/dev/null && echo "CIFS mounted" || echo "CIFS NOT mounted"
df -h / /mnt/tokyo16 | awk 'NR==1 || /\//'
dpkg --audit; apt-mark showhold
apt update 2>&1 | tail -1
apt list --upgradable 2>/dev/null | grep -v '^Listing' | cut -d/ -f1 | tr '\n' ' '; echo
apt -s dist-upgrade | grep -cE '^Inst'; apt -s dist-upgrade | grep -E '^Remv' || echo "沒有要移除的套件"
```

| 檢查 | 結果 |
| --- | --- |
| 執行中的工作 | 沒有 |
| CIFS | 已掛載，2.7T，已用 869G（33%） |
| 根目錄 | 44G，可用 36G |
| 可更新套件 | 11 個：`bind9-*`、`ca-certificates`、`cifs-utils`、`curl`、`libbrotli1`、`libcurl4t64`、`libexpat1`、`proxmox-kernel-7.0`、`tzdata` |
| 模擬 | 13 個 `Inst`（含新 kernel 本身），**沒有 `Remv`** |

> `echo` 的雙引號裡不要放 `!!`：bash 會把它展開成「上一個指令」的文字。只是印出來不會執行，但輸出會亂掉。

**更新、確認新 kernel，再重開**：

```bash
apt dist-upgrade
dpkg --audit
ls -t /boot/vmlinuz-* | head -2
reboot
```

`ls` 第一行是 `/boot/vmlinuz-7.0.14-25-pve`，`dpkg --audit` 沒有輸出。

**重開後驗收**：

| 檢查 | 結果 |
| --- | --- |
| `uname -r` | 7.0.14-25-pve（確實用新 kernel 開機） |
| PBS | 4.2.8（本次沒有 PBS 本身的更新） |
| failed unit | 0 |
| `proxmox-backup`、`proxmox-backup-proxy` | active、active |
| CIFS | 自動掛回 |
| 可更新套件 | 0 |
| PVE `pvesm status --storage PBS31` | active，32.53% |
| PVE `pvesm list PBS31 \| wc -l` | 151（150 筆備份加標題列） |

PBS31 和三台 PVE 的 kernel 再次一致（-25）。

### 11-1 同日清理舊 kernel

四台都在 -25 開機正常後，照第 10-4 節的原則清理。四台指令相同，用 MobaXterm 的 **MultiExec**（一次對多個分頁輸入）同時執行；不另外讓 PVE 的 root 金鑰登入 PBS31，以免 PVE 被入侵時連備份伺服器一起淪陷。

**① autoremove（先模擬）**：

```bash
echo "== $(hostname)  running: $(uname -r)"; apt autoremove -s 2>/dev/null | grep -E '^Remv' || echo 'nothing to remove'
apt autoremove -y >/dev/null 2>&1; dpkg -l 'proxmox-kernel-*' | awk '/^ii/{print $2}'; grep -oE 'vmlinuz-[0-9.]+-[0-9]+-pve' /boot/grub/grub.cfg | sort -u
```

四台模擬都只有 `Remv proxmox-kernel-7.0.14-22-pve-signed`，執行中的 -25 不在清單。執行後 PBS31 只剩 -23、-25，但 **PVE 三台的開機選單還有 `vmlinuz-6.17.13-21-pve`**。

**② PVE 三台還有 6.17 kernel**：第一次只用 `dpkg -l 'proxmox-kernel-7*'` 列，所以沒看到 6.x。

```bash
dpkg -l 'proxmox-kernel-6*' | awk '/^ii/{print $2}'
proxmox-boot-tool kernel list | grep -A3 -i pinned
apt-cache rdepends --installed proxmox-kernel-6.17
```

| 檢查 | 結果 |
| --- | --- |
| 6.x 套件 | `proxmox-kernel-6.17`（指標套件）、`proxmox-kernel-6.17.13-21-pve-signed`；推測是 PVE 9 安裝時附的原始 kernel，被標記成手動安裝，所以 autoremove 不清 |
| pinned | 沒有 |
| `rdepends` | 列出 `proxmox-default-kernel`，但**沒裝 6.17 的 PBS31 也一樣**：`rdepends` 會算到套件庫裡的舊版，不代表實際依賴 |

是否真的有依賴，以模擬為準：

```bash
apt remove -s proxmox-kernel-6.17 proxmox-kernel-6.17.13-21-pve-signed | grep -E '^(Remv|Inst)'
```

只列出這兩個 `Remv`，沒有 `proxmox-default-kernel`、`proxmox-ve`，也沒有 `Inst`，才移除：

```bash
apt remove -y proxmox-kernel-6.17 proxmox-kernel-6.17.13-21-pve-signed
dpkg -l 'proxmox-kernel-*' | awk '/^ii/{print $2}'
grep -oE 'vmlinuz-[0-9.]+-[0-9]+-pve' /boot/grub/grub.cfg | sort -u
```

**看到的結果**：四台都只剩 `proxmox-kernel-7.0`、-23、-25，開機選單只有 -23、-25。不需要重開，也沒有重啟服務。

## 12. 2026-10-29：kernel 7.0.14-25 → 7.0.14-26（用網頁更新）

這次先更新 PBS31，再用 ProxCenter 更新 PVE 三台（見 [ProxCenter 逐台更新 PVE](https://kbwangtw.github.io/IT-Knowledge-Base/docs/pve/proxcenter-ceph-rolling-update/) 第 13 節）。時間是上午 08:45 開始，離 21:00 備份還很久。

**更新前確認**（PBS 網頁）：右上角 Tasks 是 0，Administration → Updates 列出 **10 個套件**：

| 套件 | 版本 |
| --- | --- |
| `proxmox-kernel-7.0`、`proxmox-kernel-7.0.14-26-pve`（含 signed） | 7.0.14-25 → 7.0.14-26 |
| `proxmox-kernel-helper` | 9.2.0 → 9.2.1 |
| `pve-firmware` | 3.18-7 → 3.18-8 |
| `libjs-extjs`、`pbs-i18n`、`pve-xtermjs` | 網頁介面與翻譯 |
| `proxmox-offline-mirror-docs`、`proxmox-offline-mirror-helper` | 0.7.4 → 0.8.0 |

**`proxmox-backup-server` 本體（4.2.8）不在清單**，所以服務不會被更新中途重啟，只有 kernel 與 firmware 需要重開。

**怎麼做**：Administration → **Updates** → **Upgrade**，等終端機視窗跑完；再到 Server Status → **Reboot**。

**重開後的驗收**（PBS 網頁，約 3 分鐘）：

| 檢查 | 看到 |
| --- | --- |
| Uptime、Kernel Version | Uptime 約 2 分鐘；`Linux 7.0.14-26-pve` |
| Datastore Tokyo16 → Summary | 容量 2.87 TB、已用 905.49 GB（31.55%），**沒有 unavailable**（它掛在 CIFS 上，重開後要確認有掛回來） |
| Administration → Services | `chrony`、`cron`、`postfix`、`proxmox-backup`、`proxmox-backup-proxy`、`sshd`、`systemd-journald` 全部 running |
| Updates → Refresh | `No updates available` |
| Tasks | 0 |

**PVE 端也要確認連得到**（三台節點各查一次，唯讀）：

```bash
pvesm status
```

**看到的結果**：node10、node11、node12 的 `PBS31` 都是 `active`、31.56%，總量約 2.61 TiB、已用約 843 GiB，和 PBS 網頁（905.49 GB）換算後一致。`active` 只代表 PVE 查得到容量，**不代表備份一定成功**；當晚三封備份通知信才是最後驗證。

**舊 kernel 的處理**：保留使用中的 -26 和上一版 -25（新 kernel 有問題時可以從開機選單選回），**清理對象是更舊的 -23**，穩定幾天後再依第 10-4 節的原則做。

### 12-2 2026-10-30：清理舊 kernel -23

四台（PBS31、node10、node11、node12）都在 -26 開機正常、穩定一天後清理。**容器（LXC）沒有自己的 kernel，不用也不要在容器裡做**（容器裡 `uname -r` 顯示的是主機的 kernel，`apt autoremove -s` 會顯示 `nothing to remove`，沒有意義）。

先在四台各自**模擬**：

```bash
echo "== $(hostname)  running: $(uname -r)"; apt autoremove -s 2>/dev/null | grep -E '^Remv' || echo 'nothing to remove'
```

**看到的結果**：四台都是 `running: 7.0.14-26-pve`，`Remv` **只有** `proxmox-kernel-7.0.14-23-pve-signed`，執行中的 -26 與上一版 -25 都不在清單。確認後在四台各自移除：

```bash
apt autoremove -y >/dev/null 2>&1; dpkg -l 'proxmox-kernel-*' | awk '/^ii/{print $2}'; grep -oE 'vmlinuz-[0-9.]+-[0-9]+-pve' /boot/grub/grub.cfg | sort -u
```

**看到的結果**：四台都只剩 `proxmox-kernel-7.0`、`proxmox-kernel-7.0.14-25-pve-signed`、`proxmox-kernel-7.0.14-26-pve-signed`（以及 `proxmox-kernel-helper`），開機選單只有 `vmlinuz-7.0.14-25-pve`、`vmlinuz-7.0.14-26-pve`，沒有 -23。不需要重開機，也沒有重啟服務。

### 12-1 儀表板上的兩個提示，不是這次造成的

| 看到 | 原因 |
| --- | --- |
| Repository Status 黃色驚嘆號 `Non production-ready repository enabled!` | 沒有訂閱、用 no-subscription 來源，更新前就有 |
| 30 天任務摘要 Verify 失敗 1、Garbage collections 失敗 1 | 點進去看資料儲存區名稱與日期：這次是 **2026-10-19 測試中文通知時，故意在測試用的 `zhtest` datastore 製造的失敗**（GC：`EACCES: Permission denied`；Verify：1 個 chunk 驗證失敗），**不是正式的 Tokyo16**。`zhtest` 已刪除，見[中文通知文件](https://kbwangtw.github.io/IT-Knowledge-Base/docs/pve/proxmox-zh-tw-notification/) |

## 13. 常見問題：出問題時在哪裡停下來

| 現象 | 先查什麼 |
| --- | --- |
| ProxCenter 出現 403 | 使用者、token、ACL 與實際填入的憑證 |
| CIFS 沒掛上 | 掛載來源、網路與認證；不要讓資料寫進空的掛載目錄 |
| PBS active 但還原失敗 | 指定快照、還原工作日誌與目標 storage |
| CT210 開不起來 | 容器狀態、設定與啟動日誌 |
| 容器正常但網頁不通 | Docker 狀態、實際監聽埠與網路隔離規則 |
| 裝了新 kernel 但 `uname -r` 還是舊的 | 還沒重開 |
| 列 kernel 只看到 7.x，開機選單卻有 6.17 | 用 `dpkg -l 'proxmox-kernel-*'` 列全部；寫成 `7*` 會漏掉其他系列 |
| `apt-cache rdepends` 說某套件依賴舊 kernel | 它會算到套件庫裡的舊版；以 `apt remove -s` 的模擬結果為準 |
| `--failed` 出現 `session-x.scope` | 登入連線不是服務；確認後 `reset-failed` |
| 容量數字和 PBS UI 不同 | G 和 GiB 單位不同 |
| 儀表板顯示 Verify 或 GC 失敗 | 點進去看資料儲存區名稱與日期，確認是不是測試用的 datastore（第 12-1 節） |

> 回復方案要另外準備。從舊 kernel 開機只涵蓋 kernel，不代表整個 PBS、套件和 ZFS 都回到更新前。本文沒有完成整套回復演練，也沒有量到完整 RTO／RPO。

## 14. 每次維護要留下的結案資料

- **更新**：更新前後版本、重開時間、掛載來源、PBS 服務、PVE storage 狀態與工作日誌。
- **還原演練**：快照時間、還原開始與完成時間、開機時間、應用程式驗收結果。
- 演練完成後要關閉或隔離測試副本，確認不會再操作正式資源（這是收尾要求，本紀錄沒有提供關機完成的證據）。

## 15. 延伸閱讀

- [備份監控：失敗通知與每日備份檢查](https://kbwangtw.github.io/IT-Knowledge-Base/docs/pve/graylog-alerts-monitoring/)（Graylog 告警與監控（二）第 7 節）
- [從 PBS 還原 ProxCenter：先複製一台，再確認能用](https://kbwangtw.github.io/IT-Knowledge-Base/docs/pve/proxcenter-pbs-restore-dr-runbook/)
- [Ubuntu VM 從 PBS 還原：6 分 38 秒代表什麼？](https://kbwangtw.github.io/IT-Knowledge-Base/docs/pve/ubuntu-vm112-pbs-disaster-recovery/)
- [PBS 套件來源](https://pbs.proxmox.com/docs/installation.html#package-repositories)
- [PBS 使用者管理](https://pbs.proxmox.com/docs/user-management.html)
- [PBS API](https://pbs.proxmox.com/docs/api-viewer/index.html)
