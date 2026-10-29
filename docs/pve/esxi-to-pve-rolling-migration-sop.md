---
layout: default
title: "從 VMware ESXi 滾動式轉換到 PVE：新機先上、舊機回收（規劃 SOP）"
date: 2026-10-29
categories: [PVE, VMware, Unity, 遷移]
permalink: /docs/pve/esxi-to-pve-rolling-migration-sop/
last_modified_at: 2026-10-29
---

# 從 VMware ESXi 滾動式轉換到 PVE：新機先上、舊機回收（規劃 SOP）

> **一句話**：先買兩台新 server 建好 PVE，把 VM 一批一批從舊 ESXi 搬過來；每清空一台舊 ESXi，就重裝成 PVE 加入叢集，最後三台舊機全部變成 PVE 節點。整個過程新舊並行，隨時可以退回。

| 項目 | 內容 |
| --- | --- |
| 適合誰看 | 手上有 VMware 環境、想轉到 PVE，但只有少數幾台 server、沒有「多一整套」硬體可以先搬的人 |
| 現況 | 3 台 DL360 Gen10（ESXi 6.7）＋ 1 台 Dell EMC Unity 380（FC 連線，VM 放在 VMFS datastore） |
| 目標 | 2 台新 server 先建 PVE 叢集；舊 3 台 ESXi 清空後陸續加入，最終 5 節點 |
| 儲存 | 同一台 Unity，另開 LUN 經 FC HBA 掛給 PVE，使用 shared LVM |
| 日期 | 2026-10-29 規劃；新 server 規格尚在候補階段 |
| 目前狀態 | ⏳ **這是規劃文件，尚未實測**。步驟依官方文件與一般做法整理；推測與未確認處都有標明，實際做完後再回頭更新 |

**這篇怎麼讀**：

- 第 1～3 節：弄懂名詞、全貌，先算容量。
- 第 4～8 節：照順序做，每一節都是「做什麼 → 怎麼做 → 應該看到什麼」。
- 第 9 節：這個方案的風險；第 10 節：可能遇到的狀況。

## 1. 先認識幾個名詞

| 名詞 | 白話解釋 |
| --- | --- |
| **ESXi** | VMware 的虛擬化主機系統，裝在實體 server 上 |
| **VMFS** | ESXi 專用的檔案系統，VM 的磁碟檔放在上面；PVE **不能**直接用它 |
| **PVE（Proxmox VE）** | 免費的虛擬化平台，用 KVM 跑 VM |
| **叢集（Cluster）** | 多台 PVE 組成一組，一起管理，VM 可以在節點間搬移 |
| **Quorum（法定票數）** | 叢集要超過一半的節點在線才敢做決定，避免「分裂」成兩組各自為政 |
| **QDevice** | 一台放在叢集外的小機器，只負責投一票。2 節點叢集需要它，否則一台壞掉就失去多數 |
| **FC（Fibre Channel）／HBA** | 連儲存的專用光纖網路；HBA 是 server 上的 FC 介面卡（常被誤打成「FBA」） |
| **LUN** | 儲存設備切出來給 server 使用的一顆「虛擬硬碟」 |
| **Zoning** | 在 SAN switch 上設定「哪個 HBA 可以看到哪個儲存 port」 |
| **Multipath** | 同一顆 LUN 有多條路徑，一條斷了自動走另一條 |
| **Shared LVM** | 把多台 PVE 都看得到的 LUN 切成 LVM，讓 VM 磁碟放在共用空間，才能 live migration |
| **Live migration** | VM 不關機，從一個節點搬到另一個節點；共用儲存時只搬記憶體 |
| **HA（高可用）** | 節點掛了，PVE 自動在別台把 VM 重新啟動 |
| **PBS** | Proxmox Backup Server，專門存 PVE 備份 |

## 2. 全貌：新機先上、舊機回收

```text
階段 A  建置          ESXi×3（跑全部 VM）      PVE×2（新，空的）＋ QDevice
階段 B  第一批搬遷    ESXi-1 的 VM  ────────→  PVE×2
階段 C  回收第 1 台   ESXi-1 清空 → 重裝 PVE → 加入   （PVE×3，ESXi×2）
階段 D  回收第 2 台   再搬一批 → ESXi-2 清空 → 轉 PVE  （PVE×4，ESXi×1）
階段 E  收尾          最後一批搬完 → 觀察期 → ESXi-3 轉 PVE（PVE×5，ESXi×0）
```

| 階段 | 做什麼 | 完成的判斷 | 章節 |
| --- | --- | --- | --- |
| 0 | 盤點 VM、算容量、確定新 server 規格 | 有清單、RAM 下限算出來 | 3、4 |
| A | 新 server 裝好 PVE、接上 FC、掛 LUN、建叢集與 QDevice | 測試 VM 能 live migration | 5 |
| B | 一批 VM 從 ESXi 匯入 PVE | 這批 VM 在 PVE 上正常運作 | 6 |
| C～E | 清空的舊 ESXi 重裝成 PVE 並加入叢集 | `pvecm status` 顯示節點數增加且 Quorate | 7 |
| 收尾 | 回收舊 VMFS LUN、清 Unity 設定 | Unity 上沒有舊 ESXi 的殘留 | 8 |

為什麼這樣排：**新舊並行**，ESXi 一直都在，任何一批 VM 出問題都可以退回原樣；而且每台舊機都是「清空後」才動，不會在有 VM 的機器上動手術。

## 3. 事前盤點與容量估算

### 3-1 已知的現況數字

以下是從 vSphere 與 Unisphere 畫面讀到的數字（**只有其中一台 ESXi**，另外兩台尚未取得）：

| 項目 | 數字 |
| --- | --- |
| 型號與 CPU | ProLiant DL360 Gen10、Xeon Silver 4210 @ 2.20GHz，40 個邏輯處理器 |
| ESXi 版本 | 6.7.0（build 19898906），已連續運作 240 天 |
| 虛擬機數量 | 14 台 |
| CPU | 已用 15.09 GHz／容量 43.9 GHz（約 34%） |
| 記憶體 | 已用 307.41 GB／容量 511.66 GB（約 60%） |
| 資料存放區 | 已用 16.6 TB／容量 60.08 TB（Unity 提供） |
| NIC | 6 張 |
| Unity | Unity 380，OE 5.2.0.5.173；FC 埠畫面顯示 4 個 In use、2 個 Available（是否為每個 SP 的數字，未確認） |

> ESXi 6.7 已經過了 VMware 的一般支援期限，這也是轉換的理由之一。

### 3-2 推測：三台合計

**推測**另外兩台的使用量與這台相近，三台合計約：

| 資源 | 推測合計 | 算法 |
| --- | --- | --- |
| RAM | 約 920 GB | 307.41 × 3 |
| CPU | 約 45 GHz | 15.09 × 3 |
| VM 數量 | 約 42 台 | 14 × 3 |

⚠️ 這些是推測，**請以三台 ESXi 的實際數字取代**。同時要看「配置量」（VM 設定的 RAM 總和），不只是目前使用量。

### 3-3 新 server 的 RAM 不必一次買到 1 TB

滾動式轉換是「先搬一批、回收一台、再搬下一批」，新 server 只需要先扛第一批：

| 時間點 | PVE 需要承載的 VM（推測） | 說明 |
| --- | --- | --- |
| 階段 B | 約一台 ESXi 的量：300 GB 多 | 兩台新 server 平均分擔，每台約 150～200 GB |
| 階段 C 完成後 | 約兩台 ESXi 的量：600 GB 多 | 已有 3 個 PVE 節點分攤 |
| 階段 E 完成後 | 約 920 GB | 5 個 PVE 節點分攤，N+1 很寬鬆 |

建議新 server 每台 RAM 取「**第一批 VM 的配置量 ÷ 2 再加 30% 餘裕**」，並考慮「一台壞了另一台能暫時扛起第一批」。以現有數字推估，**每台 384～512 GB 起跳**；如果要在只有 2 個 PVE 節點的階段就啟用自動 HA，才需要每台都能扛下全部已搬來的 VM。

### 3-4 VM 盤點表（每台 VM 一列）

> **有網頁版可以直接填**：[ESXi 轉 PVE 盤點清單](https://kbwangtw.github.io/IT-Knowledge-Base/docs/pve/esxi-to-pve-inventory/)。可輸入每台 VM、各 ESXi 主機容量，自動算出 RAM 下限，並追蹤每批搬遷與各階段驗收。資料只存在你的瀏覽器，不會上傳；可匯出 CSV／JSON。

| 要記錄的欄位 | 為什麼要 |
| --- | --- |
| 名稱、用途、負責人 | 決定搬遷順序與誰來驗收 |
| OS（Windows／Linux 與版本） | Windows 要先處理 VirtIO driver |
| CPU、RAM、磁碟大小與數量 | 算容量、決定匯入時間 |
| 開機方式（BIOS／UEFI） | PVE 要設成一樣，否則開不了機 |
| 是否有 RDM、直通裝置、vGPU | 這些不能直接匯入，要另外規劃 |
| 是否有 snapshot | 匯入前要先處理（刪除或合併） |
| 是否依賴 vCenter 功能（vApp、DRS 規則、標籤） | PVE 沒有對應功能，要另想辦法 |
| 可接受的停機時間、維護窗口 | 決定「一般匯入」或「live import」 |

## 4. 新 server 規格建議（候補比較用）

| 項目 | 建議 | 備註 |
| --- | --- | --- |
| CPU | 2 顆，核心數不低於現有單台 | 新舊 CPU 世代不同時，見 5-6 |
| RAM | 每台 384～512 GB 起跳 | 見 3-3；DIMM 要平均插滿 channel（依 HPE QuickSpecs） |
| 開機碟 | 2 × SSD，做 RAID1 | 只裝 PVE，不放 VM |
| **FC HBA** | **每台 2 個 port** | 請查 HPE 對該型號的 HBA 相容清單，並確認 Linux 內建 driver（QLogic：`qla2xxx`，Emulex：`lpfc`）。具體型號本文未確認 |
| 網路 | 至少 4 個 port：2 個 bond（管理＋VM）、2 個 corosync | 有預算再加 2 個 10／25GbE，給 migration、備份與匯入 |
| 電源與 iLO | 雙電源、iLO Advanced | iLO 5 的 watchdog 對 HA 有用；遠端 console 方便 |

## 5. 階段 A：建置新叢集

### 5-1 兩台新 server 安裝 PVE

**做什麼**：把兩台新 server 裝成 PVE，版本與設定保持一致。

**怎麼做**：

1. 用 HPE SPP 先更新 BIOS、iLO 5、HBA、NIC 韌體。
2. 開機碟用硬體 RAID1（或 HBA 模式搭配 ZFS mirror，兩台要一致）。
3. 安裝同一版本的 PVE；hostname 與管理 IP 不重複。
4. 設好 bond、`vmbr0`、corosync 專用網路（兩條 link）。

**應該看到**：兩台都能用網頁登入管理介面。

### 5-2 FC：zoning、Unity 授權、multipath

**做什麼**：讓兩台新 server 都能看到同一批 Unity LUN，而且每顆 LUN 有多條路徑。

**怎麼做**：

① 取得每台 HBA 的 WWPN（要拿去做 zoning 與登錄 Unity Host）：

```bash
cat /sys/class/fc_host/host*/port_name
cat /sys/class/fc_host/host*/port_state
```

| 片段 | 意思 |
| --- | --- |
| `port_name` | HBA 的 WWPN；zoning 與 Unity 登錄都要用 |
| `port_state` | 要是 `Online`，代表 FC 連線已通 |

② SAN switch 設定 zoning：用「一個 HBA 一個 zone」（single-initiator zoning），每個 zone 放進 Unity **SP A 與 SP B 各至少一個 port**，這樣每顆 LUN 有 4 條路徑。

③ Unity 端（Unisphere）：

1. Access → Hosts：新增每台 PVE 為一個 Host，OS 類型選 Linux，登錄對應的 WWPN。
2. 建立 LUN（建議 thin），**同時授權給所有 PVE 節點**。
3. 同一顆 LUN 要讓所有節點用**相同的 LUN ID**。

④ 兩台 PVE 各自安裝 multipath 並重新掃描：

```bash
apt install multipath-tools lsscsi
for h in /sys/class/scsi_host/host*/scan; do echo "- - -" > $h; done
multipath -ll
```

| 片段 | 意思 |
| --- | --- |
| `apt install multipath-tools` | 安裝多路徑管理程式 |
| `echo "- - -" > .../scan` | 通知系統重新掃描 SCSI 裝置，不需重開機 |
| `multipath -ll` | 列出多路徑裝置與各條路徑的狀態 |

**應該看到**：每顆 LUN 一組 `mpath` 或 WWID，底下有多條路徑，狀態是 `active ready running`（Unity 走 ALUA，會分成最佳路徑與非最佳路徑兩組）。如果只有 1 條，代表 zoning 或 Unity 授權不完整。

⚠️ **不要在正式環境執行 `multipath -F`**（清除所有 multipath 裝置）；改設定後用 restart，不要隨便 flush。

如果本機開機碟也出現在 `multipath -ll`，要把它排除（具體寫法請依 multipath-tools 文件與你的環境調整）。

### 5-3 LUN 規劃：不要只開一顆

| 風險 | 說明 |
| --- | --- |
| 影響範圍 | 單顆 LUN 出事，所有 VM 一起受影響 |
| Unity snapshot | 還原是整顆 LUN 一起回溯，無法只還原單一 VM |
| LVM 管理 | 單一 VG 的 metadata 變更集中；空間不足時全部一起受影響 |
| 效能 | 多顆 LUN 可分散 queue 與路徑 |

建議（舉例，依實際容量調整）：

```text
LUN-01  一般 VM        8 TB
LUN-02  資料庫／高 IO  4 TB
LUN-03  測試／暫存     2 TB
```

目前已用 16.6 TB（整個 datastore），Unity 剩餘約 43 TB，新 LUN 合計先抓 20～25 TB 是合理範圍（**推測**，以實際 VM 配置量為準）。

### 5-4 建立 shared LVM

**做什麼**：在一台節點上把 LUN 建成 LVM，讓整個叢集都能使用。

**怎麼做**（`<wwid>` 換成 `multipath -ll` 看到的 WWID；**只在其中一台節點執行**）：

```bash
pvcreate /dev/mapper/<wwid>
vgcreate vg_unity01 /dev/mapper/<wwid>
pvesm add lvm unity01 --vgname vg_unity01 --shared 1 --content images,rootdir
```

| 片段 | 意思 |
| --- | --- |
| `pvcreate` | 把 LUN 標成 LVM 實體磁碟（Physical Volume） |
| `vgcreate` | 建立 Volume Group，名稱 `vg_unity01` |
| `--shared 1` | 告訴 PVE 這是叢集共用的儲存；live migration 只搬記憶體，不搬磁碟 |
| `--content images,rootdir` | 放 VM 磁碟與容器根目錄 |

**應該看到**：`pvesm status` 在每個節點都顯示 `unity01` 狀態為 active。

> 傳統 thick LVM **沒有 VM snapshot**。PVE 9 對這點有 tech preview，請以所用版本的 release notes 為準（未確認）。Unity 端的 snapshot 可當「crash-consistent 的還原點」，這也是 LUN 要拆開的理由（5-3）。

> **第三方 Unity storage plugin 不列入正式環境**：GitHub 上有 `jt-pve-storage-dellemc`，README 把 Unity XT 標示為「程式碼已完成，實機測試未進行」，整體為 beta，只有 PowerVault ME4024（FC）完整實測過；且需要 PVE 9.1 以上。2026-10-29 的讀取結果如此，專案狀態會變動，使用前請重新閱讀其 README。本文的 SOP 一律用 PVE 內建的 shared LVM。

### 5-5 建叢集與 QDevice

**做什麼**：兩台新 server 組成叢集，並加上一票 QDevice。

**怎麼做**：

```bash
# node1
pvecm create <叢集名稱> --link0 <node1 corosync IP-1> --link1 <node1 corosync IP-2>
# node2
pvecm add <node1 管理 IP> --link0 <node2 corosync IP-1> --link1 <node2 corosync IP-2>
pvecm status
```

QDevice 要放在叢集**外面**的一台小機器（例如 Debian 小主機）：

```bash
# QDevice 那台
apt install corosync-qnetd
# 兩台 PVE
apt install corosync-qdevice
# 其中一台 PVE
pvecm qdevice setup <QDevice IP>
```

| 片段 | 意思 |
| --- | --- |
| `--link0`、`--link1` | corosync 用兩條獨立網路，一條斷了還有另一條 |
| `corosync-qnetd` | QDevice 伺服端，只負責投票 |
| `pvecm qdevice setup` | 把 QDevice 加進叢集 |

**應該看到**：`pvecm status` 顯示 `Quorate: Yes`，Total votes 為 3（兩台 PVE ＋ QDevice）。

### 5-6 CPU 型號：為了日後混用舊機

新 server 的 CPU 通常比舊 DL360 新。之後舊機加入、VM 要在新舊節點間搬移時，VM 的 CPU type **不要用 `host`**，改用基準型號（例如 `x86-64-v2-AES`，或硬體夠新時用 `x86-64-v3`），否則 live migration 可能因 CPU 指令集不同而失敗。

### 5-7 階段 A 驗收

- [ ] 兩台新 server 的每顆 LUN 都有預期數量的路徑
- [ ] 建立一台測試 VM 放在 `unity01`，在兩台節點間 live migration 成功
- [ ] 在 Unity 上 snapshot 該 LUN，確認流程可行（**只用測試 LUN**）
- [ ] 手動拔掉其中一條 FC 路徑，I/O 不中斷（維護窗口內做）
- [ ] 關掉其中一台節點，另一台仍保持 Quorate（QDevice 有作用）
- [ ] 備份：PBS（放 Unity 以外的儲存）已能備份、還原測試 VM

## 6. 階段 B：把 VM 從 ESXi 搬到 PVE

### 6-1 匯入工具

**做什麼**：用 PVE 內建的 ESXi 匯入功能，直接從 ESXi 主機把 VM 匯入。

**怎麼做**（PVE 8.2 起提供；ESXi 6.7 是否在支援範圍請查官方文件，**未確認**）：

1. 網頁介面 → Datacenter → Storage → Add → ESXi，輸入 ESXi 主機位址與帳密（**直接連 ESXi 主機，不連 vCenter**；官方文件對 vCenter 有限制，細節請查當前版本）。
2. 憑證若是自簽，勾選略過憑證驗證。
3. 在左邊 ESXi 儲存底下選要搬的 VM → Import，指定目的儲存 `unity01`、網路橋接與磁碟匯流排。

> 帳密請用網頁介面輸入，**不要把密碼寫在命令列**，以免留在 shell 歷史。

**應該看到**：VM 出現在 PVE 的節點底下。匯入速度取決於網路（資料是走網路搬，不是 FC 層級複製），16.6 TB 的總量建議用 10GbE 以上並分批進行。

**一般匯入與 live import**：

| 方式 | 說明 | 建議 |
| --- | --- | --- |
| 一般匯入 | 先關閉 ESXi 上的 VM，完整複製後在 PVE 開機 | 預設用這個，停機時間可預期 |
| live import | VM 先在 PVE 開機，背景繼續複製磁碟 | 官方文件對風險有提醒，閱讀後再用；網路中斷時可能有資料風險（**推測**，請以文件為準） |

**不建議**讓 PVE 直接讀 VMFS（例如用 vmfs 的 FUSE 工具）：只能唯讀，效能與穩定性不適合正式環境。

### 6-2 每台 VM 的搬遷檢查表

| 步驟 | 做什麼 |
| --- | --- |
| 搬遷前 | 確認有備份、刪除或合併 snapshot、記錄 IP 與服務清單 |
| Windows | 搬遷**前**先在 ESXi 上的 VM 內安裝 VirtIO driver；或匯入時先把磁碟設成 SATA、網卡設成 E1000，開機後裝好 driver 再改成 VirtIO |
| Linux | 確認 initramfs 含 virtio 模組（多數現代發行版預設有）；網卡名稱可能改變，檢查 netplan、network scripts 是否綁 MAC |
| 開機方式 | ESXi 是 BIOS 就用 SeaBIOS，是 UEFI 就用 OVMF（並加上 EFI Disk） |
| 搬遷後 | 移除 VMware Tools（open-vm-tools），安裝 QEMU Guest Agent，並在 VM 選項啟用 Agent |
| 驗證 | 登入、網路、服務、排程、與其他系統的連線；負責人確認 |
| 加入保護 | 加入 PBS 備份排程與 HA（若要） |

**應該看到**：這批 VM 全部在 PVE 上正常運作，ESXi 上的原 VM 只關機、**不刪除**，保留到觀察期結束。

### 6-3 階段 B 驗收

- [ ] 第一批 VM 都在 PVE 運作，負責人已確認
- [ ] 每台 VM 已有一份 PBS 備份，並抽一台做還原測試
- [ ] 目標 ESXi（例如 ESXi-1）上已沒有需要保留的 VM、範本、vCenter 依賴

## 7. 階段 C～E：把清空的舊 ESXi 轉成 PVE 節點

### 7-1 動手前要先檢查

| 檢查項目 | 為什麼 |
| --- | --- |
| **ESXi 是裝在 SD 卡或 USB 嗎？** | DL360 Gen10 常見用 HPE Dual MicroSD 開 ESXi。PVE 會頻繁寫入 log 與系統資料，**不建議裝在 SD／USB**；要確認有內接 SSD 的 bay 與控制器，沒有就要加裝 |
| 本機硬碟與 RAID | ESXi 時代的 RAID 要重做；方式要與新 server 一致 |
| FC HBA | 確認 Linux driver 支援，並記下 WWPN |
| 韌體 | 用 SPP 更新到與新 server 相近的版本 |
| 網路 | 網卡數量、bond、VLAN、corosync 專用線，與其他節點一致 |
| 該台 ESXi 上是否還有資料 | 重裝會清掉本機磁碟，先**再確認一次**沒有 VM、範本、ISO、備份檔 |

### 7-2 加入叢集的步驟（每台重複）

**做什麼**：把清空的 ESXi 重裝成 PVE，加入叢集，並讓它看到同一批 LUN。

**怎麼做**：

1. 重裝 PVE：**版本與叢集一致**，hostname 與 IP 不可與現有節點重複。
2. 取得 WWPN（5-2 ①），SAN switch 加 zoning。
3. Unity 新增這台的 Host，並**授權既有的所有 PVE LUN**。
4. 在新節點上掃描、確認 multipath（5-2 ④），路徑數要與其他節點相同。
5. 加入叢集：

```bash
pvecm add <現有節點管理 IP> --link0 <本機 corosync IP-1> --link1 <本機 corosync IP-2>
pvecm status
pvesm status
```

| 片段 | 意思 |
| --- | --- |
| `pvecm add` | 讓這台加入既有叢集（需要現有節點的認證） |
| `pvecm status` | 看節點數與 quorum |
| `pvesm status` | 儲存設定是整個叢集共用的，加入後 `unity01` 應自動出現 |

**應該看到**：`Quorate: Yes`、節點數增加、`unity01` 為 active；用一台測試 VM 在新節點上 live migration 成功。

### 7-3 QDevice 隨節點數調整

| PVE 節點數 | QDevice | 說明 |
| --- | --- | --- |
| 2 | 需要 | 否則一台掛掉就失去多數 |
| 3 | 建議移除 | 奇數節點本身就能判斷多數 |
| 4 | 可選 | 偶數節點加 QDevice 可避免 50／50 的分裂 |
| 5 | 不需要 | 奇數 |

移除指令：

```bash
pvecm qdevice remove
```

官方文件對「奇數節點加 QDevice」的說明請以所用版本為準（各版本描述是否一致，未確認）。

### 7-4 持續搬遷與回收

階段 C 完成後，重複 6、7 節：

1. 搬下一批 VM（可以搬到任何已加入的 PVE 節點）。
2. 清空下一台 ESXi，重裝成 PVE 並加入。
3. 最後一台 ESXi **留久一點**（建議 2～4 週）當 rollback，確認 PVE 運作穩定、備份與還原都驗證過，再轉換。

**轉換期間 vSphere 的狀況**：

| 狀況 | 注意 |
| --- | --- |
| ESXi 剩 2 台、1 台 | vSphere 本身的 HA／DRS 保護逐步下降；剩下的 ESXi 上 VM 少了，風險也小，但要知道 |
| vCenter 是 VM | 規劃它的去處：匯入精靈可以直連 ESXi，不一定需要 vCenter；但若 vCenter 還要管剩下的 ESXi，就要等最後才搬或停用 |
| 授權 | 注意舊 ESXi 與 vCenter 授權的到期與收回 |

### 7-5 階段 C～E 驗收（每台）

- [ ] 節點加入後，`pvecm status` 為 Quorate，節點數正確
- [ ] 所有節點的 `multipath -ll` 路徑數一致
- [ ] 測試 VM 可在新舊節點間 live migration（CPU type 為基準型號）
- [ ] iLO watchdog 正常，HA 測試一次（若有使用）
- [ ] QDevice 依 7-3 調整

## 8. 收尾

**做什麼**：全部搬完後，把舊環境清乾淨。

**怎麼做**：

| 項目 | 步驟與注意 |
| --- | --- |
| 舊 VMFS LUN | 確認所有 VM 都已搬完、備份已驗證，再從 Unity 刪除並回收空間。**刪除前務必再看一次這顆 LUN 上有沒有東西** |
| Unity 設定 | 清掉舊 ESXi 的 Host 與 Initiator |
| SAN switch | 清掉不再使用的 zone |
| 授權 | 收回 ESXi、vCenter 帳號與授權 |
| 文件 | 更新叢集架構圖、WWPN 清單、LUN 對照表、IP 表 |
| Unity 本身 | 先處理 Unisphere 看到的警告（見第 9 節）與 ESRS 設定，並確認 Unity 韌體（OE）版本在支援期內 |

**應該看到**：Unity 上只剩 PVE 使用的 Host 與 LUN。

## 9. 風險清單

| 風險 | 說明 | 對策 |
| --- | --- | --- |
| Unity 是單一故障域 | 所有 VM 都在同一台儲存；兩個 SP 只擋得了單一 SP 故障 | PBS 放在 Unity 以外，並定期做還原演練 |
| **Unity SP B 警告** | Unisphere 的 System Health 顯示 SP B Management Port、SP B Sync Replication Management Port 為 Not healthy；**推測**是線路或 link 問題，未確認 | 上線前查 Alerts 與 `uemcli /sys/res/health/fault`，必要時處理線路 |
| Unity 未設定 ESRS | 出問題時 Dell 不會主動收到通知，也沒填支援資訊 | 視合約設定 ESRS、Support Credentials、Contact Information |
| SAN switch 單點 | 若只有一台 FC switch，它也是單點故障 | 確認 fabric 架構 |
| 2 節點的 quorum | 沒有 QDevice 時，一台掛掉就失去多數 | 5-5 的 QDevice；加入第 3 台後依 7-3 調整 |
| fencing | HA 需要可靠的 watchdog | 確認 iLO 5 的 watchdog 在 PVE 上運作，再啟用 HA |
| 支援邊界 | PVE 與 Unity 的組合是否被 Dell 或 Proxmox 官方列為支援，**未確認** | 查 Dell E-Lab Navigator，評估 Proxmox 訂閱 |
| Corosync 網路 | 5 節點的 corosync 對延遲較敏感 | corosync 專用網路，不與備份、migration 流量共用 |
| 升級 | 叢集變大後，更新要逐台進行 | 先 migrate VM 走，再升級該台；一次一台 |
| 備份 | 資料不可上傳雲端 | PBS 與 PVE 都在地端；內網若無法連外，使用內部 mirror 或離線更新 |

## 10. 可能遇到的狀況

> 以下是依官方文件與一般經驗整理的**預期狀況，尚未實測**。實際做完後，請把真正踩到的雷補進來，並刪掉沒遇到的。

| 現象 | 怎麼辦 |
| --- | --- |
| `multipath -ll` 只看到 1 條路徑 | 檢查 zoning 是否包含 SP A 與 SP B、Unity 是否已授權該 Host、`port_state` 是否 Online |
| 兩台看到的同一顆 LUN，LUN ID 不一樣 | 回到 Unity 授權處，確認每個 Host 都用相同的 LUN ID |
| 本機開機碟出現在 `multipath -ll` | 把本機碟排除在 multipath 之外（依 multipath-tools 文件設定 blacklist 或 wwids） |
| 新增的節點看不到 `unity01`，或狀態為 inactive | 該節點 multipath 沒通，或 LVM 還沒掃到；`multipath -ll`、`pvscan`、`vgscan` 逐一確認 |
| Windows VM 匯入後藍屏 `INACCESSIBLE_BOOT_DEVICE` | 缺 VirtIO 儲存 driver；先把磁碟設成 SATA 開機，裝好 driver 再改成 VirtIO SCSI |
| Linux VM 匯入後沒有網路 | 網卡名稱改變或設定綁定舊 MAC；進 console 修正網路設定 |
| UEFI VM 開不了機 | 確認 BIOS 類型設為 OVMF，並已加入 EFI Disk |
| Live migration 失敗，錯誤與 CPU 有關 | VM 的 CPU type 用了 `host`；改成基準型號（5-6），關機再開 |
| 匯入速度很慢 | 資料是走網路搬；檢查匯入路徑的網路速度，改用 10GbE 以上或分批、在離峰時間進行 |
| 加入叢集時失敗 | 版本是否一致、hostname 與 IP 是否重複、corosync 網路是否互通、防火牆是否擋住 |
| `multipath -F` 後 VM 卡住 | 不要在正式環境使用它；改用 restart，並先確認該路徑沒有 I/O |

## 11. 待辦

- [ ] 取得另外兩台 ESXi 的實際 RAM、CPU 與 VM 使用量，取代 3-2 的推測
- [ ] 確認三台舊 DL360 的 ESXi 是裝在 SSD 還是 SD 卡（7-1）
- [ ] 確認 FC 是否經過 SAN switch、有幾台、新舊 HBA 型號是否一致
- [ ] 查 Unity SP B 管理 port 警告的原因（第 9 節）
- [ ] 決定新 server 規格（第 4 節）
- [ ] 完成 VM 盤點表（3-4）
- [ ] 實測後，把「可能遇到的狀況」改成真實紀錄

## 12. 延伸閱讀

- [Proxmox VE：Migrate to Proxmox VE（含 ESXi 匯入）](https://pve.proxmox.com/wiki/Migrate_to_Proxmox_VE)
- [Proxmox VE：Storage](https://pve.proxmox.com/wiki/Storage)
- [Proxmox VE：Cluster Manager（含 QDevice）](https://pve.proxmox.com/wiki/Cluster_Manager)
- [Proxmox VE：Multipath](https://pve.proxmox.com/wiki/Multipath)
- 本知識庫：[PVE HA 放置策略](https://kbwangtw.github.io/IT-Knowledge-Base/docs/pve/pve-ha-placement-policy/)：節點變多後，HA 規則怎麼分工
- 本知識庫：[整個 PVE 叢集安全關機與開機](https://kbwangtw.github.io/IT-Knowledge-Base/docs/pve/pve-cluster-full-shutdown/)：搬機房、停電維護時使用
- 本知識庫：[PBS 更新後，怎麼確認備份還能用？](https://kbwangtw.github.io/IT-Knowledge-Base/docs/pve/ProxCenter-PBS-Update-and-DR-Validation-SOP/)：備份與還原驗證
