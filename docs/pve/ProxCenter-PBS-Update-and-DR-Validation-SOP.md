---
layout: default
title: "ProxCenter v1.4.9／PBS 4.2.5 更新與 Restore／DR 驗證 SOP"
date: 2026-09-11
categories: [PVE, PBS, ProxCenter, DR]
permalink: /docs/pve/ProxCenter-PBS-Update-and-DR-Validation-SOP/
---

# ProxCenter v1.4.9／PBS 4.2.5 更新與 Restore／DR 驗證 SOP

本文件整合 PBS31 套件更新、API Token 403 排查、重新開機驗收，以及先前 CT110 → CT210 的 Restore／DR 實測。ProxCenter 負責集中 Refresh／檢視 PBS 更新，真正套件升級在 **PBS31 Shell／SSH** 執行；還原演練則驗證到 CT210 的 Docker 服務與 Frontend。

紀錄整理日：2026-09-11。數值依使用者提供的實測紀錄與既有 [Restore／DR Runbook](proxcenter-pbs-restore-dr-runbook.md) 整理，並非本文件編寫時重新連線設備執行的結果。不同時間點的驗證分別列示；未提供的 snapshot ID、job ID、耗時及逐套件完整清單不予臆測。

## 導覽

- [環境與網路](#environment)
- [證據分類與產品限制](#evidence)
- [更新前檢查](#precheck)
- [API Token 403 排查](#token)
- [Repository 與更新流程](#update)
- [重新開機與驗收](#postcheck)
- [Restore／DR 操作](#restore)
- [Rollback 與故障排查](#recovery)
- [驗收與參考資料](#acceptance)

<a id="environment"></a>
## 1. 環境與網路

| 項目 | 本次設定 |
|---|---|
| 管理平台 | ProxCenter v1.4.9 |
| 備份伺服器 | PBS31，PBS 4.2.5（套件 `proxmox-backup-server 4.2.5-1`） |
| 管理網路 | `192.168.10.0/24` |
| 備份／資料網路 | `172.16.10.0/24` |
| PBS31 management | `192.168.10.31/24` |
| PBS31 backup/data | `172.16.10.31/24` |
| ProxCenter 正式 CT | CT110，管理 IP `192.168.10.30`；先前演練新增資料 NIC `172.16.10.30/24` |
| ProxCenter PBS Base URL | `https://172.16.10.31:8007` |
| PVE 備份 storage | `PBS31`，server `172.16.10.31`，datastore `Tokyo16` |
| Tokyo16 CIFS | `//172.16.10.16/PBS_BK_Folder` → `/mnt/tokyo16` |
| Restore 目標 | PVE `node12`、CT210、`VM_Pool` |
| DR 測試 IP／入口 | `192.168.10.210`／`http://192.168.10.210:3000` |

```text
管理網 192.168.10.0/24
  ProxCenter CT110 .30 ── PBS31 .31
          │ 第二 NIC         │ backup/data NIC
資料網 172.16.10.0/24         │
  ProxCenter .30 ────── PBS31 .31 ── CIFS Tokyo16 .16
  PVE node12 ───────── PBS31 storage     /PBS_BK_Folder
       └─ Restore → CT210 / VM_Pool
                       └─ 管理測試 IP 192.168.10.210:3000
```

管理與備份流量分網規劃；第二 NIC 不另設 default gateway，避免改變原管理路徑。ProxCenter 與 PVE 應能到達同一 PBS 資料端點。雙 NIC 不等於已完成安全隔離，仍須檢查路由、防火牆與實際流量路徑。

本文依本次需求保留內部位址及 Token ID（識別名稱），**不包含 Token Secret、密碼、Cookie、Private Key 或完整憑證**。CIFS credentials、PBS 設定備份與 DR 複本可能含認證資訊，必須保存在受控位置，不得提交 Git。

<a id="evidence"></a>
## 2. 證據分類與適用限制

### 實測結果

- 舊 credential 呼叫更新資料庫出現 403；建立新 Token、對 user/token 設定 `/ → Admin`、重新填入 credential 後 Refresh 成功。
- PBS31 完成套件升級及 reboot；新 kernel、雙 NIC、Tokyo16 自動掛載、PVE 備份清單與 ProxCenter 更新狀態均通過驗收。
- 先前 Restore 在增加 ProxCenter 第二 NIC、對齊 PBS Base URL 並關閉 LXC Override name 後成功；改 IP 後 CT210 可啟動，四個 Docker containers healthy。

### 產品限制（依本次版本／UI 行為記錄）

ProxCenter v1.4.9 的 PBS Update UI 可以 Refresh package database、列出更新及檢視 Repository；本次 UI 說明 PBS API 不提供 direct upgrade endpoint，實際升級需使用 PBS Shell／SSH。因此 **Refresh 成功不代表已執行 `apt dist-upgrade`**。此處保留本次 UI 的產品限制描述，不延伸宣稱所有未來版本都相同；升版後應重新核對 [PBS API 文件](https://pbs.proxmox.com/docs/api-viewer/index.html) 與 ProxCenter release notes。

### 推測／待原廠確認事項

| 項目 | 已知證據 | 尚不能下的結論／待確認內容 |
|---|---|---|
| 舊 Token 403 根因 | 多項 credential／ACL 變更後成功 | 無法單獨證明是舊 Token 損壞、ACL 設定、權限傳遞或 credential 儲存問題；需要去敏感化的有效權限與日誌比對 |
| PBS endpoint mapping | 同一 PBS 使用不同 IP 時失敗；對齊資料 IP 後成功 | 可能以 endpoint 字串識別；內部比對演算法、多 IP／DNS alias 支援需原廠確認 |
| LXC Override name | 開啟時 PVE 400；關閉後成功 | 疑似送出 LXC schema 不接受的 `name` 欄位；未取得完整 request payload／修正版本前不宣稱已定位原始碼 Bug |
| 後續版本 Upgrade 支援 | v1.4.9 本次導向 Shell／SSH | 不推定其他 ProxCenter／PBS 版本已新增或仍缺少直接升級能力 |

<a id="precheck"></a>
## 3. 更新前 pre-check

以下為重複操作時的檢查程序；只有後文明列數值的項目才是本次已記錄結果。

- [ ] 安排維護時段，確認 backup、restore、verify、prune、GC、sync 等工作已完成或暫停排程，避免與升級／reboot 重疊。
- [ ] 確認可使用主控台／遠端管理介面救援，不只依賴即將重啟的 SSH。
- [ ] 將 PBS、APT sources、網路、掛載設定及必要金鑰備份到受控位置，確認有可用的獨立備份／復原方式。
- [ ] 記錄已安裝版本、執行中 kernel、NIC、路由、datastore 來源及容量；確認 OS、`/boot`、datastore 有足夠空間。
- [ ] 確認 Tokyo16 是正確 CIFS 掛載；不能只看到 `/mnt/tokyo16` 目錄存在就認定正常。
- [ ] PVE `PBS31` active，能列出預期備份；ProxCenter 可登入並檢視 PBS31。
- [ ] 暫不移除舊 kernel、不執行 ZFS pool feature upgrade，保留故障回復選項。

在 **PBS31 Shell／SSH** 以具備管理權限的帳號執行：

```bash
proxmox-backup-manager versions
uname -r
systemctl --failed --no-pager
systemctl status proxmox-backup proxmox-backup-proxy --no-pager
ip -br addr
ip route
findmnt --mountpoint /mnt/tokyo16
df -h / /boot /mnt/tokyo16
dpkg --audit
apt-mark showhold
```

確認 `findmnt` 的來源為 `//172.16.10.16/PBS_BK_Folder`，類型為 `cifs`。若掛載不存在，停止涉及 datastore 的工作，先修復掛載；不要讓備份寫入掛載點下的 OS 本機目錄。

在 **PVE node12**：

```bash
pvesm status --storage PBS31
pvesm list PBS31
```

若已有 failed services、套件不完整、storage inactive、容量不足或進行中任務，先釐清並修復，再進入更新流程。

<a id="token"></a>
## 4. API Token 403：排查與本次解法

### 錯誤與處置

ProxCenter Refresh package database 曾回報：

```text
PBS 403 /nodes/localhost/apt/update: permission check failed
```

1. 確認連到預期的 PBS31、credential 所屬 user／Token ID 正確，帳號與 Token 未停用或過期。403 應優先查授權，不能當成網路完全不通。
2. 在 PBS 建立新 Token：`proxcenter@pbs!proxcenter-v2`。
3. 分別檢查 user `proxcenter@pbs` 與 token `proxcenter@pbs!proxcenter-v2` 的 ACL；本次兩者都在 `/` 授予 `Admin`，並確認更新端點的有效權限。
4. 在 ProxCenter PBS31 connection 重新填入 Token ID 與新 Secret，儲存 credential。Secret 僅輸入受保護的 credential 欄位，**不要貼入命令、日誌、文件或截圖**。
5. 重新執行 **Inventory → PBS31 → Updates → Refresh package database**，確認不再出現 403、可正常列出套件更新。
6. 新 credential 及其他依賴驗證完成後，盤點舊 Token 使用者，再依輪替流程停用舊 Token；不要先刪除仍被其他服務使用的 credential。

**實測結果：** 完成上述新 Token／ACL／credential 更新後，Refresh package database 成功。

依 [PBS 使用者管理文件](https://pbs.proxmox.com/docs/user-management.html)，Token 權限仍受所屬 user 權限限制，不能只檢查其中一方。`/ → Admin` 是本次排障成功的高權限設定，**不是已驗證的最小權限方案**；後續應在測試環境逐項縮減權限，重新驗證 Refresh、清單及 Restore 所需操作。此次並未實測較小權限組合。

<a id="update"></a>
## 5. Repository 與 PBS 更新

### 5.1 Repository 檢查

| Repository | 本次狀態 |
|---|---|
| Debian Trixie | enabled |
| Debian Trixie security（`trixie-security`） | enabled |
| Debian Trixie updates（`trixie-updates`） | enabled |
| PBS `pbs-no-subscription` | enabled |
| PBS enterprise | disabled |

在 PBS UI 與 APT 設定交叉核對，涵蓋傳統 `.list` 與 deb822 `.sources`：

```bash
grep -R -n -E '^(deb |Types:|URIs:|Suites:|Components:|Enabled:|Signed-By:)' /etc/apt/sources.list /etc/apt/sources.list.d/
apt-cache policy
```

若系統僅使用 `.sources`，不存在 `/etc/apt/sources.list` 的提示本身不代表 Repository 壞掉。需檢查是否混用不同 Debian 發行版、重複來源或遺留 enterprise 啟用項；deb822 用 `Enabled: no` 停用。此處只記錄本次狀態，不提供覆蓋整份 sources 的指令。

依 [PBS Repository 官方說明](https://pbs.proxmox.com/docs/installation.html#debian-package-repositories)，no-subscription 與 enterprise 的驗證／支援定位不同；本次使用 no-subscription 不代表所有正式環境都應停用 enterprise。有訂閱環境應依其維護政策選擇來源。

### 5.2 在 PBS31 執行更新

逐步執行並查看各步輸出，不能把 ProxCenter UI Refresh 當成 OS 升級：

```bash
apt update
apt list --upgradable
apt -s dist-upgrade
```

`apt -s dist-upgrade` 是模擬，不會安裝套件。確認沒有下載／簽章錯誤，逐項檢閱將升級、安裝及移除的套件；若出現預期外移除、關鍵套件衝突或來源不符，停止處理。本次實際完成的摘要如下；未來不要求套件數必須相同。

確認後再執行：

```bash
apt dist-upgrade
```

保留互動確認，不直接加 `-y`；遇到設定檔差異先比對再決定。完成前勿中斷套件設定。這是 PBS 4.2.5 環境內的套件更新紀錄，不是 PBS 跨大版本升級 SOP，也不應在 node12 誤執行這組 PBS 更新步驟。

### 5.3 本次實測摘要

```text
9 upgraded, 1 newly installed, 0 removed
```

| 元件 | 更新前 | 更新後 |
|---|---|---|
| Kernel | `7.0.14-12-pve` | `7.0.14-16-pve` |
| ZFS | `2.4.3-pve1` | `2.4.4-pve1` |
| pve-firmware | `3.18-5` | `3.18-6` |
| PBS | 本流程環境 PBS 4.2.5 | 確認 PBS 4.2.5／`4.2.5-1` |

新 kernel 安裝與 initramfs 建立完成；未 reboot 前 `uname -r` 仍可能顯示舊 kernel，不能以套件已安裝取代執行中版本驗證。

<a id="postcheck"></a>
## 6. Reboot 前後 post-check

### 6.1 Reboot 前

在 PBS31：

```bash
dpkg --audit
ls -l /boot/vmlinuz-7.0.14-16-pve /boot/initrd.img-7.0.14-16-pve
systemctl status proxmox-backup proxmox-backup-proxy --no-pager
systemctl --failed --no-pager
findmnt --mountpoint /mnt/tokyo16
```

確認 APT 正常結束、開機檔存在、PBS services 正常、Tokyo16 正確掛載且沒有進行中任務。**本次 `systemctl --failed --no-pager` = 0 failed（`0 loaded units listed`）。** 注意參數是 `--failed`，不是 `--fail`；一般 loaded units 清單不是故障數。

確認維護窗口與救援主控台可用後，在 PBS31 執行：

```bash
reboot
```

### 6.2 Reboot 後：PBS31

重新登入後：

```bash
uname -r
systemctl --failed --no-pager
systemctl status proxmox-backup proxmox-backup-proxy --no-pager
findmnt --mountpoint /mnt/tokyo16
df -h /mnt/tokyo16
ip -br addr
ip route
```

| 檢查 | 本次結果 |
|---|---|
| `uname -r` | `7.0.14-16-pve` |
| Failed units | 0 |
| Tokyo16 | CIFS `//172.16.10.16/PBS_BK_Folder` → `/mnt/tokyo16`，reboot 後自動掛載成功 |
| `df -h` | 約 2.7T total／703G used／2.0T available／27% |
| Management NIC | `192.168.10.31/24` 正常 |
| Backup/data NIC | `172.16.10.31/24` 正常 |

這是本次 CIFS 自動掛載成功紀錄，不代表所有 CIFS/NAS 組合都具相同效能、故障語意或原廠支援。重新部署時仍需獨立驗證掛載依賴、認證、斷線復原與還原能力。

### 6.3 Reboot 後：PVE node12

```bash
pvesm status --storage PBS31
pvesm list PBS31
```

**實測結果：** `PBS31` 為 `active`，可列出備份。這驗證 PVE → PBS 的存取與備份清單，不能單靠清單推定每份備份均可完整還原。

### 6.4 Reboot 後：ProxCenter

1. **Inventory → PBS31 → Updates → Refresh package database**。
2. 確認 `0 updates available`／`System is up to date`，沒有 403。
3. **Backups → PBS31 / Tokyo16**，核對備份與驗證狀態。

| Tokyo16 UI 項目 | 本次最終結果 |
|---|---|
| Total snapshots | 141（61 VM snapshots、80 container snapshots） |
| Verified | 141/141 |
| Used | 約 702.16 GiB |
| Available | 約 1.92 TiB |
| Total | 約 2.61 TiB |

`df` 與 UI 的單位、四捨五入及取樣時間可能不同，以上各自保留原始顯示。`141/141 verified` 是當時顯示的驗證狀態，沒有證據表示這次更新後重新執行了全部 verify jobs；CT110 還原成功是另一項較早的 DR 證據。`0 updates` 也只代表該次 Refresh 時點與已設定 Repository 的狀態。

<a id="restore"></a>
## 7. CT110 → CT210 Restore／DR SOP

### 7.1 Restore pre-check

在 node12 檢查：

```bash
pvecm status
pvesm status
pvesm status --storage PBS31
pvesm list PBS31
pct status 110
pct config 110
pct status 210
```

- [ ] Cluster quorate，PBS31 active；Tokyo16 目標 snapshot 可列出，記錄 snapshot 時間與識別碼。
- [ ] `VM_Pool` 有足夠容量，VMID 210 未使用；若已存在，停止並另選 VMID，禁止覆寫。
- [ ] 保存來源 CT 的 bridge、VLAN、MTU、firewall、MAC、IP、gateway、rootfs 與額外掛載設定。
- [ ] 保留測試 IP `192.168.10.210`，透過 IPAM／DHCP／設備清單確認未佔用；ping 沒回應本身不能證明 IP 空閒。
- [ ] DR 複本可能帶有正式 API credentials 與排程，先規劃管理端點存取限制、停用自動化，避免複本操作正式環境。
- [ ] 所有 NIC 都要檢查；若 snapshot 包含第二 NIC，資料網 IP 也需更換或隔離，不能只改管理 IP。

### 7.2 PBS endpoint mapping 問題

曾出現：

```text
No PVE storage on node node12 maps to PBS datastore Tokyo16
```

當時 ProxCenter Base URL 是 `https://192.168.10.31:8007`，PVE PBS storage server 是 `172.16.10.31`。先以 `pvesm` 確認 PVE 備份路徑正常，再替 ProxCenter 增加第二 NIC，讓它可達 `172.16.10.31`；本次資料 NIC 為 `172.16.10.30/24`，不設第二個 default gateway。

在 ProxCenter guest 驗證介面、路由及資料網可達性：

```bash
ip -br addr
ip route
ping -c 4 172.16.10.31
curl -I https://172.16.10.31:8007
```

TLS 憑證需與連線方式相容；必要時指定受信任 CA。若僅為排查自簽憑證而暫用 `curl -k -I`，只能證明取得 HTTP response，不能證明伺服器身分可信，不能作為永久忽略 TLS 驗證的設定。

將 ProxCenter PBS Base URL 改為 `https://172.16.10.31:8007`，儲存後重新測試。**實測：Restore mapping 成功。** 不需因本案例反覆新增 PVE storage；根因分類見第 2 節待確認事項。

### 7.3 Restore 設定與 Override name workaround

| 欄位 | 本次值 |
|---|---|
| Source | CT110 ProxCenter，PBS31／Tokyo16 |
| Target node | node12 |
| New VMID | 210 |
| Target Storage | VM_Pool |
| Unique MAC | ON |
| Start after restore | OFF |
| Override name | OFF |

曾因開啟 LXC Override name 出現：

```text
PVE API 400
/nodes/node12/lxc/
name property is not defined in schema
```

**實測 workaround：** 關閉 Override name 後成功。重試前先查看失敗 job 是否留下 CT／磁碟；不要盲目覆寫或刪除殘留資源。需要 hostname 時，待還原後以 PVE 支援的 LXC hostname 設定處理。這個錯誤本身不能證明備份損毀。

### 7.4 啟動前修改 IP

```bash
pct status 210
pct config 210
```

確認 CT210 停止、Restore 完成、rootfs 位於 `VM_Pool`（本次 `VM_Pool:vm-210-disk-0,size=10G`），且 MAC 與 CT110 不同。**Unique MAC 不會更改靜態 IP。**

在 PVE CT210 → Network 編輯原有 net0，將 `192.168.10.30/24` 改為 `192.168.10.210/24`，保留正確的 bridge、gateway、firewall、新 MAC 及其他原有欄位，再以 `pct config 210` 核對。本次管理 gateway 為 `192.168.10.1`、bridge 為 `vmbr0`、firewall 為 `1`。

若使用 `pct set 210 -net0 ...`，先由目前設定組成完整參數並保留必要欄位，不可直接用簡化範例覆蓋 VLAN／MTU／MAC 等設定。若 IP 由 guest OS 管理，需在停止時掛載 rootfs 修改，或先隔離網路再調整。包含第二 NIC 的備份，必須一併處理資料網重複位址。

### 7.5 啟動與應用程式 post-check

在 node12：

```bash
pct start 210
pct status 210
ping -c 4 192.168.10.210
pct enter 210
```

接著在 **CT210 guest**：

```bash
ip -br addr
ip route
systemctl --failed --no-pager
docker ps
docker ps -a
ss -lntp
```

**實測結果：** CT210 running、ping 成功；以下四個 containers 全部 healthy：

- `proxcenter-orchestrator`
- `proxcenter-frontend`
- `proxcenter-weasyprint`
- `proxcenter-postgres`

Frontend 實際 listen／host port mapping 是 **3000，不是 443**。在可達管理網的主機測試：

```bash
curl -I http://192.168.10.210:3000
```

用瀏覽器開啟 `http://192.168.10.210:3000`，驗證登入頁與基本 UI。不要因 `https://192.168.10.210` 無回應判定 Restore 失敗；也不要僅靠 containers healthy 就宣稱所有業務功能已驗證。

演練完成後退出 guest，在 node12 關閉測試複本並確認 stopped：

```bash
pct shutdown 210 --timeout 60
pct status 210
```

以上關機是收尾程序，本文不將其冒充本次新取得的執行結果。保留去敏感化的 snapshot／job ID、操作時間、結果及實際 RTO；本次沒有足夠時間資料可宣稱特定 RTO／RPO。

<a id="recovery"></a>
## 8. 風險、Rollback 與故障排查

### 8.1 停止條件與回復原則

以下是預備處置，**本次成功升級／Restore 未實測 rollback**。

| 階段／風險 | 回復處置 | 恢復服務前條件 |
|---|---|---|
| `apt update` 或模擬不符預期 | 不執行實際升級；核對 sources、簽章、hold、相依性與原始設定備份 | 索引正常、模擬內容經檢閱 |
| 套件設定中斷 | 不立即 reboot；先查 `/var/log/apt/history.log`、`/var/log/apt/term.log`、`dpkg --audit`。依錯誤評估 `dpkg --configure -a` 或先模擬修復相依性；不可盲目移除套件 | 套件設定完成、PBS services／開機檔正常 |
| 新 kernel 無法開機／NIC 異常 | 透過主控台從既有開機選單選擇保留的 `7.0.14-12-pve`，保留診斷資料，再修復新 kernel／驅動／開機設定 | 舊 kernel 可開機且 storage、NIC、PBS 驗證通過 |
| 全系統升級後功能異常 | 依事前建立的 OS／設定備份與救援計畫復原；不要假設 `apt dist-upgrade` 有一鍵 rollback | 確認資料相容性與復原點；避免舊 OS 回寫不相容 datastore |
| ZFS 相容性 | 本流程不做 `zpool upgrade`；舊 kernel 開機只回退 kernel，不會一併回退 ZFS userspace、firmware 或 pool features | 依實際 pool／模組版本確認可存取，不能把舊 kernel 當完整系統 rollback |
| CIFS 掛載失敗 | 暫停 datastore 寫入，查網路、NAS share、credentials 與 mount unit；不要重建／格式化 datastore | 正確 CIFS source、容量及 PBS／PVE 存取正常 |
| Base URL 變更造成管理中斷 | 從受控紀錄恢復原 connection 設定以恢復管理；原 endpoint mapping 問題可能再現 | TLS／credential／路由驗證完成後再重試 Restore |
| Restore 複本異常／衝突 | 關閉或隔離 CT210；保持 CT110 及來源備份不變。依 job log 盤點資源，再決定保留或重新以新 VMID 還原 | IP／MAC／所有 NIC 不衝突，複本自動化受控 |

如需還原 PBS OS，必須保護獨立 datastore，不可將救援安裝指向 Tokyo16 資料或格式化備份儲存。升級、reboot、掛載調整及 DR 啟動都可能影響備份可用性，應逐階段驗收後才恢復原排程。

### 8.2 故障排查表

| 現象 | 優先檢查 | 處置／判定 |
|---|---|---|
| Refresh 403 `/nodes/localhost/apt/update` | PBS endpoint、user/token 有效 ACL、credential 是否更新 | 本次新 Token＋兩者 `/ → Admin`＋重填 credential 後成功；舊 Token 根因未單獨證明 |
| APT enterprise 授權／下載錯誤 | 訂閱狀態、enterprise 是否仍啟用、是否有重複 `.list`／`.sources` | 依本次 no-subscription 政策核對來源，不關閉簽章驗證 |
| UI 能 Refresh 但無法直接 Upgrade | v1.4.9 的 PBS Upgrade 提示 | 本次產品流程要求 PBS Shell／SSH 執行升級 |
| 更新後仍跑舊 kernel | 是否 reboot、bootloader 選項與新 initramfs | 先確認新開機檔及服務健康再 reboot；之後以 `uname -r` 驗證 |
| systemd 顯示很多 units | 是否用了 `--failed --no-pager` | loaded 數不等於 failed 數；正確篩選後再判讀 |
| `/mnt/tokyo16` 存在但容量像 OS | `findmnt --mountpoint /mnt/tokyo16` 的 source/type | 停止寫入，修復 CIFS 掛載後再驗證；不得只用目錄存在作為依據 |
| Reboot 後 CIFS 未掛載 | `systemctl status mnt-tokyo16.mount --no-pager`、`journalctl -b -u mnt-tokyo16.mount --no-pager`、NAS／網路 | 核對實際 mount unit、開機網路依賴及受保護 credentials；日誌去敏感化 |
| PBS31 inactive／清單失敗 | PBS services、172.16.10.31 路由／8007、憑證、PVE credential、datastore | 修正後重跑 `pvesm status --storage PBS31`／`pvesm list PBS31` |
| Restore mapping 失敗 | ProxCenter Base URL 與 PVE PBS server 是否一致 | 本次第二 NIC＋`https://172.16.10.31:8007` 成功；內部 mapping 機制待確認 |
| LXC 400 `name property is not defined` | Override name 與失敗 job 殘留 | 關閉 Override name、確認目標 VMID 狀態再重試 |
| Unique MAC ON 仍 IP 衝突 | 所有 NIC 及 guest 靜態 IP | 啟動前將管理 IP 改為 `.210`，其餘 NIC 更換／隔離 |
| 443 無回應 | `docker ps`、`ss -lntp`、firewall | 本次應使用 `http://192.168.10.210:3000` |
| Docker unhealthy | `docker ps -a`、指定 container 日誌及資源 | 去敏感化後分析；不可貼出完整環境變數或包含 Secret 的 inspect 結果 |

<a id="acceptance"></a>
## 9. 驗收與維護紀錄

### 本次已記錄的結果

- [x] 新 API Token credential 可成功 Refresh package database。
- [x] Repository：Trixie／security／updates 與 PBS no-subscription 啟用、enterprise 停用。
- [x] `apt dist-upgrade`：9 upgraded／1 newly installed／0 removed。
- [x] Kernel、ZFS、pve-firmware 更新到第 5 節所列版本。
- [x] Reboot 前 failed units 0；reboot 後 kernel `7.0.14-16-pve`、failed units 0。
- [x] PBS31 雙 NIC 正常，Tokyo16 CIFS reboot 後自動掛載成功。
- [x] node12 `PBS31` active，`pvesm list PBS31` 可列備份。
- [x] ProxCenter 最終 `0 updates available`／`System is up to date`。
- [x] Tokyo16 顯示 141 snapshots／141/141 verified，容量如第 6 節。
- [x] 先前 CT110 → node12 CT210／VM_Pool Restore 成功；啟動前改管理 IP，ping 成功、四個 containers healthy、Frontend port 3000。

### 每次維護仍須另外完成

- [ ] 記錄維護窗口、操作者、起訖時間、APT 結果與 PBS／ProxCenter／PVE 版本。
- [ ] 保存去敏感化證據；填寫 snapshot／job ID、verify 執行時間及實際還原耗時。
- [ ] 確認測試複本關閉／隔離，再恢復原有工作排程。
- [ ] 觀察下一次正常備份與必要的抽樣還原；本次未提供新的完整備份工作結果。
- [ ] 另行規劃最小權限驗證、Token 輪替與原廠問題回報。

## 10. 相關文件與來源

- [先前 ProxCenter + PBS Restore／DR Runbook](proxcenter-pbs-restore-dr-runbook.md)：本 repo 的 CT110 → CT210 實測細節。
- [ProxCenter PVE／Ceph Rolling Update](proxcenter-ceph-rolling-update.md)：PVE／Ceph 更新另有流程，勿與 PBS Shell 更新混用。
- [PBS 官方 Repository 文件](https://pbs.proxmox.com/docs/installation.html#debian-package-repositories)：來源設定與 repository 定位。
- [PBS 官方使用者與 Token 權限文件](https://pbs.proxmox.com/docs/user-management.html)：使用者、Token、ACL 與權限限制。
- [PBS 官方 API Viewer](https://pbs.proxmox.com/docs/api-viewer/index.html)：後續版本核對入口；不是本次 ProxCenter UI 提示的獨立原廠確認。

原廠文件用於核對一般機制，不能當成本站內部版本、容量或工作結果的證據。實測結果以本次使用者提供的紀錄為準。
