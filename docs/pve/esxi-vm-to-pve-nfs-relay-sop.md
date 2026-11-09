---
layout: default
title: "把 ESXi 上的 Windows＋SQL Server 虛擬機搬到獨立 PVE（一）：NFS 中轉、掛上磁碟與開機驗證"
date: 2026-11-07
categories: [PVE, VMware, 遷移]
permalink: /docs/pve/esxi-vm-to-pve-nfs-relay-sop/
last_modified_at: 2026-11-07
---

# 把 ESXi 上的 Windows＋SQL Server 虛擬機搬到獨立 PVE（一）：NFS 中轉、掛上磁碟與開機驗證

> **一句話**：把一台 700 GB（C 槽 200 GB＋D 槽 500 GB）、跑 Windows Server 2019 與 SQL Server 2019 的虛擬機，從 ESXi 搬到一台獨立的 PVE：先確認網路真的是 1 Gbps，再用 ESXi 的 `vmkfstools` 經 NFS 把磁碟複製到 PVE；C 碟轉成 qcow2、D 碟因為空間不夠直接掛 VMDK；兩顆磁碟都掛好才開機，13 個資料庫全部 ONLINE、`DBCC CHECKDB` 無錯誤，**複製只花 1 小時 49 分**。

| 項目 | 內容 |
| --- | --- |
| 適合誰看 | 要把 ESXi 上跑 Windows＋資料庫的虛擬機搬到一台獨立 PVE（沒有叢集、沒有共用儲存），想一次搞懂整個流程的人 |
| 環境 | 來源：獨立的 ESXi 主機，VM 是 UEFI 開機、8 vCPU、32 GB RAM、兩顆 thick 磁碟（C 200 GB、D 500 GB）、1 支 USB 軟體鎖。目標：PVE 9.2.25 單機（node221），兩組 HP Smart Array P420i 的 RAID 5：一組放系統與 LVM-thin，一組放 `VM_Store`（ext4 目錄儲存，1.1 TB） |
| 日期 | 2026-11-07 |
| 結論 | ✅ 兩顆磁碟搬完，Windows 開機成功，SQL Server 與 SQL Agent 自動啟動<br>✅ 13 個資料庫全部 ONLINE，`DBCC CHECKDB` 無任何輸出（沒有發現損壞）<br>✅ USB 軟體鎖直通成功，ERP 讀得到；使用者電腦實際連線正常<br>✅ 重開機測試通過（SQL、IP、USB、Guest Agent 都自動恢復）<br>⚠️ 開機碟改 VirtIO SCSI 失敗，維持 SATA（見下篇）<br>⚠️ RAID 控制器的寫入快取故障未修，SQL 的實際負載表現待上班日觀察（見下篇） |

**這篇怎麼讀**：第 1～3 節弄懂名詞、全貌與空間算法；第 4～13 節照順序做，每一步都是「做什麼 → 指令 → 應該看到什麼」；遇到問題先看第 15 節，再到[下篇（踩雷與效能診斷）](https://kbwangtw.github.io/IT-Knowledge-Base/docs/pve/esxi-vm-to-pve-troubleshooting/)。

## 1. 先認識幾個名詞

| 名詞 | 白話解釋 |
| --- | --- |
| **ESXi／VMFS** | VMware 的虛擬化主機系統；VM 的磁碟檔放在它專用的 VMFS 檔案系統裡 |
| **VMDK** | VMware 的虛擬磁碟格式。一顆磁碟通常是兩個檔：**描述檔**（`xxx.vmdk`，幾百 bytes 的文字）＋**資料檔**（`xxx-flat.vmdk`，真正的內容） |
| **thick／thin** | thick 是先把空間全部配好；thin 是用多少佔多少。thick 磁碟即使檔案系統裡只用了一點，VMDK 的大部分區塊都已經配置過 |
| **`vmkfstools`** | ESXi 上用來複製、轉換 VMDK 的原生指令（只能在 ESXi 的 SSH 裡用） |
| **NFS 中轉** | PVE 把一個資料夾用 NFS 分享出去，ESXi 把它掛成 datastore，直接把 VMDK 複製進去。資料是 ESXi 直接寫進 PVE 的磁碟，不經過管理介面 |
| **`qm disk import`** | PVE 把外部磁碟檔（例如 VMDK）轉成 PVE 的磁碟格式並收進某個 VM |
| **qcow2** | PVE 常用的虛擬磁碟格式，只佔實際用到的空間，支援快照 |
| **OVMF／UEFI** | PVE 上的 UEFI 韌體。來源 VM 是 UEFI 開機，目標就要用 `--bios ovmf`＋EFI 磁碟 |
| **SATA／VirtIO** | 虛擬磁碟的「接頭」類型。SATA 是 Windows 內建驅動就能用的相容選項；VirtIO 效能較好但要先裝驅動 |
| **USB 直通（passthrough）** | 把插在 PVE 主機上的 USB 裝置整個交給某一台 VM 使用，像是軟體鎖（dongle） |
| **QEMU Guest Agent** | 裝在 VM 裡的小程式，讓 PVE 能看到 VM 的 IP、做乾淨關機 |
| **SQL Server 的資料庫狀態** | `ONLINE` 才是正常；`RECOVERY_PENDING`、`SUSPECT`、`OFFLINE` 都表示有問題 |

## 2. 全貌

```text
ESXi（來源 VM 先正常關機）
  │  esxcli storage nfs add            ← 把 PVE 的資料夾掛成 datastore
  │  vmkfstools -i … -d thin           ← 複製 VMDK（ESXi 直接寫進 PVE 磁碟）
  ▼
PVE：VM_Store/migrate/（中轉資料夾，走 NFS）
  │  C 碟：qm disk import → qcow2      ← 轉檔，需要多一份空間
  │  D 碟：空間不夠 → 直接搬進 images/<VMID>/，改名後掛 VMDK
  ▼
PVE：VM 102（SATA 掛 C、D；UEFI；網卡先斷線）
  ▼
兩顆磁碟都掛好 → 才第一次開機 → SQL、USB、網路、Guest Agent 逐項驗證
  ▼
IP／DNS 回到原本的值 → 舊 VM 做好防護（不再被開機）→ 上線
```

| 為什麼這樣排 | 說明 |
| --- | --- |
| 先量網路與空間 | 速度與空間決定整條路能不能走；網卡協商成 100 Mbps 時，700 GB 要搬將近一整天（見下篇） |
| **兩顆磁碟都掛好才開機** | 這台的 SQL Server 設成自動啟動。只掛 C 就開機，SQL 找不到 D 槽上的資料檔，資料庫會進入 `RECOVERY_PENDING` 之類的狀態，之後還得手動處理 |
| 網卡先斷線 | 新 VM 和舊 VM 同名同 IP；驗證期間不讓它上線，避免與網域、客戶端互相干擾 |
| 舊 VM 不刪 | 它是整個過程唯一完整的退路（驗證期間資料與新機完全相同） |

為什麼選 NFS 中轉，而不是 PVE 內建的 ESXi 匯入精靈：

| 做法 | 優點 | 缺點 |
| --- | --- | --- |
| **NFS 中轉（本篇）** | 複製與匯入分成兩段，哪一段失敗都能只重做那一段；D 碟空間不夠時可以選擇「不轉檔」直接掛 | 要多設定 NFS，中轉檔暫時佔空間 |
| 匯入精靈 | 一步到位，操作簡單 | 失敗只能整個重來；沒有「不轉檔」的選項 |

> **誠實說明**：本次**沒有**在同樣的網路條件下比較兩種做法的速度。測試機（100 GB）用匯入精靈花了 2 小時 40 分，但那時網路被卡在 100 Mbps，修好之後才改用 NFS 中轉，所以**不能**據此說哪個比較快。選 NFS 中轉的理由是上表的彈性。

## 3. 事前盤點與空間算法

### 3-1 這次的環境

| 項目 | 來源 VM（ESXi） | 目標（PVE） |
| --- | --- | --- |
| 作業系統 | Windows Server 2019 Standard（網域成員） | 同 |
| 韌體 | UEFI | `--bios ovmf` ＋ EFI 磁碟 |
| CPU／RAM | 8 vCPU／32 GB | 1 socket × 8 cores／32768 MB |
| 磁碟 | C 200 GB、D 500 GB，**都是 thick** | 先用 SATA 掛，之後才考慮 VirtIO |
| 網卡 | e1000e | 先 `e1000e` 斷線開機，驗證完改 `virtio` |
| 其他 | 1 支 USB 軟體鎖；SQL Server 2019，13 個資料庫；SQL Agent 有每晚備份排程 | USB 直通；排程隨 `msdb` 一起搬過來 |

### 3-2 空間怎麼算（最容易算錯的地方）

中轉檔和匯入後的新檔案**同時存在**，所以匯入某顆磁碟前，可用空間要夠放「中轉檔＋轉完的檔案」：

```text
匯入前需要的空間 ≈ 中轉檔大小 ＋ 轉完的 qcow2 大小
```

| 磁碟 | 虛擬大小 | 中轉檔實際大小 | 匯入後 qcow2 | 本次做法 |
| --- | --- | --- | --- | --- |
| C | 200 GB | 約 150 GB | 配置量 74.65%，約 149 GB | 空間足夠 → 轉 qcow2 |
| D | 500 GB | **約 499 GB** | 預估約 499 GB | `VM_Store` 剩約 295 GB → **放不下，不轉檔，直接掛 VMDK** |

> **D 碟為什麼這麼大**：資料庫總量遠小於 500 GB，但 thick 磁碟上曾經寫過的區塊（包含已刪除檔案的殘留）都會被當成資料複製。**不要用「現在用了多少」來預估複製量。** 本次 D 碟用 Windows 刪檔把用量降到 19 GB，複製量依然是 499 GB；刪檔不會讓 VMDK 縮小。

## 4. 動手做 A：複製前先檢查網路速度與空間

### 4-1 網卡協商速度

ESXi（SSH）：

```bash
esxcli network nic list
```

看你要用的那張卡的 `Speed` 欄位。**要看到 `1000`（或更高）才往下做。** 如果是 `100`，先停下來排除（原因與處理見下篇第 3 節）；這次就是因為這個，第一次複製預估要 5 個半小時。

PVE：

```bash
ethtool <網卡名稱> | grep -i -E 'speed|duplex|link detected'
```

本次 PVE 端是 `Speed: 10000Mb/s`、`Duplex: Full`、`Link detected: yes`。

### 4-2 PVE 空間

```bash
findmnt -T /mnt/pve/VM_Store
df -h /mnt/pve/VM_Store
df -h /
```

| 看什麼 | 要求 |
| --- | --- |
| `FSTYPE` | 本機檔案系統（`ext4`、`xfs`、`zfs`…）；**若是 `nfs`、`cifs` 就不要再轉匯出** |
| `VM_Store` 的 `Avail` | 要大於「最大那顆磁碟的中轉檔大小」，並依 3-2 估匯入後的空間 |
| `/` 的 `Avail` | **中轉資料夾千萬不要放在這裡**（本次系統碟只有 94 GB，見下篇第 4 節） |

## 5. 動手做 B：PVE 建立 NFS 匯出

**做什麼**：在 `VM_Store` 底下建一個中轉資料夾，只開放給那一台 ESXi 寫入。

```bash
apt list --installed 2>/dev/null | grep -i nfs-kernel-server
mkdir -p /mnt/pve/VM_Store/migrate
echo '/mnt/pve/VM_Store/migrate <ESXi IP>(rw,async,no_root_squash,no_subtree_check)' >> /etc/exports
exportfs -ra
exportfs -v
```

| 片段 | 意思 |
| --- | --- |
| `<ESXi IP>` | 只開給這一台 ESXi，不要開給整個網段 |
| `rw` | 允許寫入 |
| `no_root_squash` | 讓 ESXi 以 root 寫入；沒有這個會被拒絕 |
| `async` | 先寫進記憶體再慢慢落地，速度較好；PVE 當機時中轉檔可能不完整，但中轉檔本來就可以重做，原始 VMDK 完整保留。**較保守的做法是用 `sync`**（本次沒有比較兩者速度，因為瓶頸在網路） |
| `exportfs -ra` | 重新載入設定 |

應該看到：`exportfs -v` 列出 `/mnt/pve/VM_Store/migrate`，對象是你的 ESXi IP，選項含 `rw`、`no_root_squash`。防火牆需要放行 ESXi 到 PVE 的 `2049`、`111`。

> **目錄權限**：中轉資料夾請放在 `images/` 與 `template/` 這類 PVE 管理的目錄之外，避免被儲存掃描當成 VM 磁碟。

## 6. 動手做 C：ESXi 掛載 NFS 並複製

**做什麼**：確認 VM 已正常關機、掛載 NFS、用背景方式複製，並把進度寫進記錄檔。

### 6-1 確認 VM 關機

```bash
vim-cmd vmsvc/getallvms
vim-cmd vmsvc/power.getstate <Vmid>
```

`<Vmid>` 是第一個指令列出的數字（不是照打 `<Vmid>`，否則 shell 會報語法錯誤）。要看到 `Powered off`。**要正常關機（從 Windows 內關），不要強制斷電**，否則 D 槽上的資料庫可能不一致。

### 6-2 掛載 NFS 並測試寫入

```bash
esxcli storage nfs add --host=<PVE IP> --share=/mnt/pve/VM_Store/migrate --volume-name=pve-nfs
esxcli storage nfs list
touch /vmfs/volumes/pve-nfs/test.txt && ls -l /vmfs/volumes/pve-nfs/ && rm /vmfs/volumes/pve-nfs/test.txt
```

應該看到：`pve-nfs` 的 `Accessible`、`Mounted` 都是 `true`，`Read-Only` 是 `false`；`touch` 後看得到 `test.txt`，沒有 `Permission denied`。（`Hardware Acceleration: Not Supported` 是 NFS 的常態，不影響複製。）

### 6-3 複製（背景執行並記時間）

```bash
date > /tmp/clone.log
nohup sh -c 'vmkfstools -i /vmfs/volumes/<datastore>/<VM 資料夾>/<VM>.vmdk /vmfs/volumes/pve-nfs/<VM>-C.vmdk -d thin >> /tmp/clone.log 2>&1; date >> /tmp/clone.log' > /dev/null 2>&1 &
ps -c | grep vmkfstools
tail -c 80 /tmp/clone.log
```

| 片段 | 意思 |
| --- | --- |
| `-i` | 複製（clone）這顆 VMDK |
| `-d thin` | 目的檔用 thin 格式，**全零區塊不會真的寫出去**（本次前 10% 空白區都是瞬間跳過） |
| `nohup … &` | 放到背景，SSH 斷線也不會中斷 |
| 前後兩個 `date` | 開始與結束時間，之後用來算耗時 |

監看進度（`Ctrl+C` 只會停掉監看，不會停掉複製）：

```bash
while true; do date; tail -c 80 /tmp/clone.log; echo; sleep 60; done
```

PVE 另開視窗看實際寫入量：

```bash
watch -n 30 'du -sh /mnt/pve/VM_Store/migrate; df -h /mnt/pve/VM_Store'
```

應該看到：`Clone: xx% done.` 逐步上升；`du` 持續增加。進度百分比是依**虛擬大小**算的，前段全零區會走得特別快，**不要用百分比外推剩餘時間**，改用 `du` 增加的速度。

**要中途停掉複製**：`ps -c | grep vmkfstools` 找到 `vmkfstools` 那一行最左邊的 PID，執行 `kill <PID>`，再清掉 PVE 上不完整的中轉檔。複製不能續傳，只能重來。

### 6-4 D 碟

C 複製完、並確認 PVE 端匯入成功後，再用同樣方式複製 D 碟（`<VM>_1.vmdk` → `<VM>-D.vmdk`，記錄檔改名 `clone_d.log`）。**不要與 C 同時複製**，會搶網路與磁碟，也不好判讀速度。

## 7. 動手做 D：PVE 建立 VM 外殼

**做什麼**：建一台沒有磁碟的 VM，設定要與來源一致（CPU、RAM、UEFI），網卡先斷線。

先確認 VMID 沒被用：

```bash
qm list
```

```bash
qm create 102 --name MERP10 --ostype win10 --sockets 1 --cores 8 --memory 32768 \
  --bios ovmf --efidisk0 VM_Store:1,efitype=4m,pre-enrolled-keys=0,format=qcow2 \
  --net0 e1000e,bridge=vmbr0,link_down=1
qm config 102
```

| 片段 | 意思 |
| --- | --- |
| `--ostype win10` | Windows 10／Server 2016 以上的最佳化 |
| `--bios ovmf` ＋ `--efidisk0 …` | UEFI 韌體與存放 UEFI 設定的小磁碟（約 528 KB） |
| `pre-enrolled-keys=0` | 不預載 Secure Boot 金鑰（來源 VM 沒有開 Secure Boot，推測；未確認） |
| `--net0 …link_down=1` | 網卡**斷線**，避免驗證期間與舊 VM 衝突 |

應該看到 `bios: ovmf`、`efidisk0`、`memory: 32768`、`cores: 8`、`net0` 帶 `link_down=1`。這時 VM 還沒有任何開機磁碟，**不要啟動**。

> 來源是哪種韌體、多少 CPU／RAM，可以在 ESXi 上看 `.vmx`：`grep -i -E 'memSize|numvcpus|firmware|ethernet0.virtualDev|scsi0.virtualDev' <VM>.vmx`。有 `firmware = "efi"` 就是 UEFI，沒有就是傳統 BIOS。

## 8. 動手做 E：C 碟轉成 qcow2 並掛上

**做什麼**：把中轉檔轉成 qcow2、掛成 `sata0`，再確認檔案完整。

```bash
date
qm disk import 102 /mnt/pve/VM_Store/migrate/<VM>-C.vmdk VM_Store --format qcow2
date
qm config 102
```

應該看到：進度 `transferred … of 200.0 GiB`，最後 `successfully imported disk 'VM_Store:102/vm-102-disk-1.qcow2'`，`qm config` 多出 `unused0`。

```bash
qm set 102 --sata0 VM_Store:102/vm-102-disk-1.qcow2 --boot order=sata0
qemu-img check /mnt/pve/VM_Store/images/102/vm-102-disk-1.qcow2
qm config 102
```

| 檢查 | 預期 |
| --- | --- |
| `qemu-img check` | `No errors were found on the image.`（本次 `74.65% allocated`，約 149 GB，與中轉檔實際大小吻合） |
| `qm config` | `sata0: …vm-102-disk-1.qcow2,size=200G`、`boot: order=sata0`、沒有 `unused` |

> `qemu-img check` 只能確認**檔案結構**，不能保證 Windows 開得起來。EFI 磁碟會先佔 `vm-102-disk-0`，所以 C 碟是 `disk-1`。

確認 C 碟沒問題、且 D 碟還需要空間時，再刪掉 C 的中轉檔：

```bash
rm /mnt/pve/VM_Store/migrate/<VM>-C.vmdk /mnt/pve/VM_Store/migrate/<VM>-C-flat.vmdk
df -h /mnt/pve/VM_Store
```

## 9. 動手做 F：D 碟空間不夠，直接掛 VMDK（不轉檔）

**做什麼**：D 碟複製完成後（`Clone: 100% done.`），把兩個檔案搬進 VM 的磁碟資料夾，改名，再用 `qm set` 掛上。**同一個檔案系統內的 `mv` 是瞬間完成，也不需要額外空間。**

先在 ESXi 卸載 NFS（避免搬檔時還被使用、留下鎖定檔），再在 PVE 移除匯出：

```bash
# ESXi
esxcli storage nfs remove --volume-name=pve-nfs
esxcli storage nfs list           # 應為空
```

```bash
# PVE
sed -i '\#/mnt/pve/VM_Store/migrate#d' /etc/exports
exportfs -ra
exportfs -v                       # 應沒有輸出
ls -la /mnt/pve/VM_Store/migrate
cat /mnt/pve/VM_Store/migrate/<VM>-D.vmdk
```

描述檔是約 500 bytes 的文字，關鍵是這一行：

```text
RW 1048576000 VMFS "<VM>-D-flat.vmdk"
```

（`1048576000` 個磁區 × 512 bytes ＝ 500 GiB。）

搬檔、改名、修描述檔（**資料檔的副檔名要改掉，原因見下篇第 6 節**）：

```bash
mv /mnt/pve/VM_Store/migrate/<VM>-D-flat.vmdk /mnt/pve/VM_Store/images/102/<VM>-D.flat
mv /mnt/pve/VM_Store/migrate/<VM>-D.vmdk /mnt/pve/VM_Store/images/102/vm-102-disk-2.vmdk
sed -i 's/"<VM>-D-flat.vmdk"/"<VM>-D.flat"/' /mnt/pve/VM_Store/images/102/vm-102-disk-2.vmdk
grep -a -n 'RW' /mnt/pve/VM_Store/images/102/vm-102-disk-2.vmdk
```

| 片段 | 意思 |
| --- | --- |
| `…-D.flat` | **只有描述檔叫 `.vmdk`**，資料檔改成別的副檔名，PVE 才不會把它當成另一顆磁碟 |
| `vm-102-disk-2.vmdk` | 描述檔用 PVE 的命名規則 |
| `sed` | 描述檔裡寫著資料檔的檔名，要同步改 |
| `grep -a` | 描述檔結尾可能有空位元組，不加 `-a` 會顯示 `binary file matches`，看不到內容 |

應該看到：`RW 1048576000 VMFS "<VM>-D.flat"`。

驗證 QEMU 與 PVE 都認得：

```bash
qemu-img info /mnt/pve/VM_Store/images/102/vm-102-disk-2.vmdk
pvesm list VM_Store --vmid 102
```

| 預期 | 說明 |
| --- | --- |
| `file format: vmdk`、`virtual size: 500 GiB`，extent 的 `filename` 是 `…/<VM>-D.flat` | QEMU 依描述檔找到資料檔 |
| `pvesm list` 只列出 `disk-0.qcow2`、`disk-1.qcow2`、`disk-2.vmdk`，沒有錯誤 | PVE 不會把資料檔誤當磁碟 |

**這兩個沒過不要往下。** 通過後掛上：

```bash
qm set 102 --sata1 VM_Store:102/vm-102-disk-2.vmdk
qm config 102
```

> **不要用 `qm rescan`**：它可能把資料檔當成「未使用磁碟」加進設定，之後有人把那個 `unused` 項目刪掉，PVE 連資料檔本身一起刪。

這種做法的限制（本次未驗證到的地方）：VMDK 格式在 PVE **不能用快照**；磁碟檔還是 500 GB，之後空間夠時可用 `qm disk move` 轉成 qcow2，但搬移前要確認 `df`。

## 10. 動手做 G：第一次開機

開機前確認：

```bash
qm config 102 | grep -E '^boot|^sata|^net0|^efidisk|^bios'
```

必須同時有：`bios: ovmf`、`boot: order=sata0`、`sata0`（C）、`sata1`（D）、`net0` 帶 `link_down=1`。**ESXi 上的原 VM 必須是關機狀態。**

```bash
qm start 102
```

在 PVE 網頁開 Console。本次開機後看到的狀況：

| 項目 | 結果 |
| --- | --- |
| Windows 登入畫面 | 正常 ✅ |
| 伺服器管理員 | 磁碟空間總計 **699.38 GB**（C 200＋D 500，兩顆都被辨識）✅ |
| 網路 | 「沒有連線」（預期：網卡斷線）；事件記錄有群組原則 1129／1130（找不到網域，也是預期）✅ |
| 其他 | VMware Tools 的錯誤視窗（`Exception 0xc0000096`）：預期會出現，處理見下篇第 8 節 |

> 如果停在 UEFI 畫面或 `No bootable device`：按 `Esc` 進 UEFI 設定 → Boot Maintenance Manager → Boot From File，選 EFI 分割區裡的 `\EFI\Microsoft\Boot\bootmgfw.efi`。本次沒有遇到，但這是 UEFI VM 搬家後常見的狀況。

## 11. 動手做 H：Windows 與 SQL Server 驗證

**做什麼**：確認 SQL 服務、每個資料庫的狀態、資料檔位置，並跑完整性檢查。以下在 VM 裡的命令提示字元（系統管理員）執行。**這些全部是只讀。**

```bat
sqlcmd -S localhost -E -Q "SELECT name, state_desc FROM sys.databases"
sqlcmd -S localhost -E -W -Q "SELECT LEFT(physical_name,3) AS Drv, COUNT(*) AS Files, SUM(size)*8/1024 AS SizeMB FROM sys.master_files GROUP BY LEFT(physical_name,3)"
```

| 片段 | 意思 |
| --- | --- |
| `-S localhost` | 連本機的預設執行個體（具名執行個體要寫 `localhost\名稱`） |
| `-E` | 用目前登入的 Windows 帳號驗證 |
| `-W` | 去掉多餘空白，輸出比較不會折行 |

應該看到：13 個資料庫的 `state_desc` 全是 `ONLINE`；第二個指令顯示資料檔分布在 `C:\` 與 `D:\`。**本環境的使用者資料庫有一部分放在 C 槽（ERP 程式的資料夾下），一部分在 D 槽**，所以 C、D 兩顆都帶著資料。

完整性檢查（會把所有資料庫完整讀一遍，**資料量大要等一段時間，視窗不要關**）：

```bat
sqlcmd -S localhost -E -Q "EXEC sp_MSforeachdb N'DBCC CHECKDB([?]) WITH NO_INFOMSGS'" -o C:\r.txt
type C:\r.txt
```

| 片段 | 意思 |
| --- | --- |
| `sp_MSforeachdb` | SQL Server 內建（沒有官方文件）的老指令，對每個資料庫各執行一次；`[?]` 會被換成資料庫名稱，所以有連字號的名稱也能處理 |
| `WITH NO_INFOMSGS` | 只顯示錯誤，沒事就沒有輸出 |
| `-o C:\r.txt` | 結果寫進檔案，方便截圖貼出來 |

**`C:\r.txt` 是空的 ＝ 沒有發現損壞。** 若有 `Msg …` 開頭的訊息，**不要自己用 `REPAIR_ALLOW_DATA_LOSS` 之類的修復選項**，那會刪資料。

再確認 SQL 自己記錄「真的檢查過」：

```bat
sqlcmd -S localhost -E -W -Q "SELECT name, DATABASEPROPERTYEX(name,'LastGoodCheckDbTime') AS LastGoodCheck FROM sys.databases"
```

每個資料庫（`tempdb` 除外）的時間都是剛才檢查的時間。

SQL 啟動時有沒有出問題：

```bat
sqlcmd -S localhost -E -Q "EXEC sp_readerrorlog 0, 1, N'recovery'"
sqlcmd -S localhost -E -Q "EXEC sp_readerrorlog 0, 1, N'error'"
```

找 `Operating system error 2／3`（找不到檔案或路徑）。看到 `Registry startup parameters` 之類的啟動資訊是正常的。

> **不能用 VNC 主控台複製貼上時**：noVNC 不同步剪貼簿（見下篇第 9 節）。這幾個指令都縮成了一行，可以手打；或先接上網路改用遠端桌面。

## 12. 動手做 I：USB 軟體鎖直通

**做什麼**：把 USB key 插在 **PVE 主機**上，再交給 VM。

```bash
lsusb
dmesg | tail -15
qm set 102 --usb0 host=<VendorID>:<ProductID>
qm config 102 | grep usb
qm monitor 102
```

在 `qm monitor` 提示字元輸入 `info usb`，再輸入 `quit` 離開。

| 指令 | 用途 |
| --- | --- |
| `lsusb` | 找新出現那一行的 `xxxx:yyyy`（Vendor:Device ID） |
| `--usb0 host=xxxx:yyyy` | 依 ID 直通。換成 `host=<bus>-<port>` 則是依孔位 |
| `info usb` | 確認 VM 真的拿到裝置；本次顯示 `Speed 1.5 Mb/s`（USB 低速裝置，軟體鎖常見，不是問題） |

不要勾 USB3：一般軟體鎖是 USB 1.x／2.0 裝置，勾 USB3 可能反而認不到（視你的 key 而定，未普遍驗證）。直通之後這台 VM 綁定在這台 PVE 上，無法線上搬到別台。

Windows 裡到裝置管理員看有沒有被辨識；是否需要廠商驅動，依 key 的種類而定。本次 key 開機後就能被 ERP 讀到。**重開機後直通自動恢復**（見第 13 節的重開機測試）。

## 13. 動手做 J：網路切換、舊機防護、Guest Agent、收尾

### 13-1 換成 VirtIO 網卡並接上網路

驗證 OK 之後，要先**在 Windows 裡記下原本的靜態 IP**。換網卡後 Windows 會把新網卡當成另一張（裝置管理員裡名稱帶 `#2`），原本的靜態 IP 設定通常還留在舊的隱藏介面卡上，不會自動帶過來；本次就是新網卡先用 DHCP，之後才手動改回原本的靜態 IP。舊設定可以從登錄檔找：

```powershell
reg query HKLM\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces /s | findstr /i "IPAddress SubnetMask DefaultGateway NameServer"
```

PVE 端換網卡並取消斷線（保留 MAC）：

```bash
qm set 102 --net0 virtio=<原本的 MAC>,bridge=vmbr0
qm config 102 | grep net0
```

`netkvm` 驅動若已在驅動程式庫（`pnputil /enum-drivers | findstr /i netkvm`），Windows 會自動裝好。接著在 Windows 設回原本的**靜態 IP**（`ncpa.cpl`），並確認：

```powershell
ipconfig /all
Get-NetConnectionProfile
```

| 看什麼 | 預期 |
| --- | --- |
| `DHCP 已啟用` | 否 |
| IP、遮罩、閘道、DNS | 與原本一致 |
| `NetworkCategory` | `DomainAuthenticated`（已連上網域）|

> 驗證期間用 DHCP 拿到的 IP 不要拿來當正式位址：DHCP 租約到期可能換 IP，客戶端靠 DNS 名稱連線會因此連不到。

### 13-2 遠端桌面連不進來：防火牆規則

本次網路接上後，`netstat -an | findstr 3389` 顯示 3389 在聽，但遠端桌面連不進來。查到遠端桌面的三條防火牆規則都是 `Enabled: False`（網路類型已是網域）。把規則啟用後即可連線（也可以先 `gpupdate /force` 看網域群組原則會不會自己開）：

```powershell
Get-NetFirewallRule -DisplayGroup "遠端桌面" | Format-Table DisplayName,Enabled,Profile
Enable-NetFirewallRule -DisplayName "遠端桌面 - 使用者模式 (TCP-In)"
Enable-NetFirewallRule -DisplayName "遠端桌面 - 使用者模式 (UDP-In)"
```

（英文系統的群組名稱是 `Remote Desktop`。）只開使用者模式那兩條，`陰影` 那條不用開。網域群組原則之後可能覆蓋這個設定。連線時**直接用 IP**，不要用名稱（DNS 紀錄可能還指向舊位址）。

### 13-3 DNS 登錄與舊機防護（上線前最重要）

| 項目 | 做法 |
| --- | --- |
| DNS 紀錄 | 在這台執行 `ipconfig /registerdns`；從使用者電腦 `nslookup <主機名稱>` 確認解析到正確 IP |
| 舊 VM 保持關機 | ESXi：`vim-cmd vmsvc/power.getstate <Vmid>` 要是 `Powered off` |
| 取消自動開機 | ESXi：`vim-cmd hostsvc/autostartmanager/get_autostartseq`，清單裡不該有舊 VM |
| 就算被誤開機也不連網 | ESXi 網頁介面：舊 VM → Edit settings → 網路介面卡 → 取消「開機時連線」（要在關機狀態做）。也可以改 `.vmx` 的 `ethernet0.startConnected = "FALSE"` 後 `vim-cmd vmsvc/reload <Vmid>`（編輯前先備份 `.vmx`；這個做法本次未實測） |
| 改名並告知同事 | 把舊 VM 改名成「勿開機」之類，並讓相關同事知道 |

> **為什麼這步最重要**：新機與舊機同名同 IP。只要使用者有人寫入新機，舊機就變成過期的退路；而舊機被誤開機，會與新機搶 IP、網域帳號，資料也會分岔。

### 13-4 備份：確認排程跟過來了

SQL Agent 的排程存在 `msdb`，會隨 C 槽一起搬過來。確認：

```powershell
Get-Service | Where-Object { $_.Name -like '*SQLAGENT*' } | Format-Table Name,Status,StartType
```

```bat
sqlcmd -S localhost -E -W -Q "SELECT TOP 8 b.database_name, b.backup_finish_date, m.physical_device_name FROM msdb.dbo.backupset b JOIN msdb.dbo.backupmediafamily m ON m.media_set_id=b.media_set_id ORDER BY b.backup_finish_date DESC"
```

`SQLSERVERAGENT` 要是 `Running`、`Automatic`；第二個指令看備份寫到哪裡、上次什麼時候。**本次發現備份檔寫在同一台 VM 的 D 槽**（`D:\DBBackup\`），不算真正的備份（VM 或陣列壞掉會一起沒有）；上線前至少手動複製一份到別台機器，並安排自動複製。

### 13-5 QEMU Guest Agent

VM 要先正常關機，再掛上 virtio-win ISO（先上傳到 PVE 的 ISO 儲存），並開啟 Agent：

```bash
pvesm list local --content iso
qm set 102 --ide2 local:iso/virtio-win-0.1.302.iso,media=cdrom
qm set 102 --agent 1
qm set 102 --boot order=sata0
qm pending 102
qm start 102
```

| 片段 | 意思 |
| --- | --- |
| `--ide2 …media=cdrom` | 掛光碟。**加光碟機的動作若在 VM 運作中做，會變成「待套用」（`qm pending` 看到 `new ide2`，網頁是橘色字），要完整關機再開機才生效** |
| `--agent 1` | 開啟 Agent 通道（virtio-serial），也要重新開機才生效 |
| `--boot order=sata0` | 掛光碟時 PVE 會自動把 `ide2` 加進開機順序（`order=sata0;ide2`），這裡改回只留硬碟 |

在 Windows 裡執行光碟的 `guest-agent\qemu-ga-x86_64.msi`（只裝 Agent，不更新驅動），確認服務：

```powershell
Get-Service | Where-Object { $_.Name -like '*QEMU*' } | Format-Table Name,Status,StartType
```

回 PVE 驗證：

```bash
qm agent 102 ping
qm agent 102 network-get-interfaces
```

`ping` 沒有輸出就是成功；第二個列出 VM 的 IP。完成後退出光碟並設定開機自動啟動：

```bash
qm set 102 --ide2 none,media=cdrom
qm set 102 --onboot 1
qm config 102 | grep -E 'onboot|agent|ide2|boot'
```

### 13-6 重開機測試

正式上線前一定要重開機一次，確認冷啟動沒有問題（本次在晚間備份之後做）：

| 項目 | 預期 |
| --- | --- |
| `MSSQLSERVER`、`SQLSERVERAGENT` | `Running`、`Automatic` |
| 資料庫 | 全部 `ONLINE` |
| IP／DNS／遠端桌面 | 正常，IP 仍是靜態 |
| USB 軟體鎖、ERP | 讀得到 key |
| `qm agent 102 ping` | 沒有輸出（成功） |
| 事件記錄 | 沒有新的 Error（`Get-WinEvent -LogName System -MaxEvents 30 \| Where-Object { $_.LevelDisplayName -in 'Error','Warning' }` 沒有輸出） |

### 13-7 PVE 端收尾清單

| 項目 | 做法 |
| --- | --- |
| NFS 匯出 | `/etc/exports` 那行已刪、`exportfs -v` 沒有輸出；不再使用可 `systemctl disable --now nfs-server` |
| 中轉資料夾 | 確認是空的再 `rmdir /mnt/pve/VM_Store/migrate` |
| 驗證用的暫時磁碟、光碟 | 移除（見下篇第 7 節）；退出光碟 |
| D 碟資料檔 | `images/102/<VM>-D.flat` **不要刪**，它是 D 碟的內容 |
| ESXi | `/tmp/clone.log`、`/tmp/clone_d.log` 記完起訖時間後可刪；**舊 VM 至少保留 1～2 週**（建議值，依你們的規定）再決定刪不刪 |
| 備份 | PVE 設定檔（`/etc/pve`、`/etc/network/interfaces` 等）打包後複製到別台機器 |

## 14. 本環境的實測紀錄

| 項目 | 時間（UTC） | 結果 |
| --- | --- | --- |
| C 碟複製（`vmkfstools`，修好網路後） | 02:41:59 → 03:11:18 | **29 分 19 秒**；虛擬 200 GB、實際約 150 GB；實際寫入約 87 MiB/s |
| D 碟複製 | 03:48:57 → 05:08:22 | **1 小時 19 分 25 秒**；虛擬 500 GB、實際約 499 GB；約 107 MiB/s（接近 1 Gbps 上限） |
| 兩顆複製合計 | | 約 **1 小時 49 分** |
| C 碟 `qm disk import` | | 完成，`qemu-img check` 無錯誤，配置量 74.65%（約 149 GB）；匯入耗時沒有記錄 |
| D 碟 | | 搬進 `images/102/` 改名後直接掛 VMDK，瞬間完成 |
| 對照：網路在 100 Mbps 時 | | 匯入精靈搬 100 GB 的測試機花 **2 小時 40 分**（約 10.7 MiB/s）；NFS 複製 C 碟時預估 5 個半小時，在 17% 時中止 |
| 驗證 | | 13 個資料庫 ONLINE、`DBCC CHECKDB` 無輸出、USB 軟體鎖與 ERP 正常、重開機測試通過 |

時間為 ESXi 的 UTC，台灣時間加 8 小時。

## 15. 常見問題

| 現象 | 可能原因與處理 |
| --- | --- |
| 複製速度只有 10 MiB/s 上下 | 網卡協商成 100 Mbps，不是 NFS 的問題；見下篇第 3 節 |
| 複製到一半停在很小的檔案大小 | 中轉資料夾放在空間太小的磁碟（例如 PVE 系統碟）；見下篇第 4 節 |
| `qm set --scsi5 …` 出現 `invalid VMDK image descriptor` | PVE 把資料檔當成磁碟；見下篇第 6 節 |
| 磁碟改 VirtIO SCSI 後進修復環境 | 見下篇第 7 節；退回 SATA 即可，資料不會壞 |
| 寫入 `local-lvm` 慢到停擺、`qemu-img` 變殭屍 | RAID 5＋寫入快取故障；見下篇第 5 節 |
| 解除安裝 VMware Tools 一直 `1603` | 見下篇第 8 節 |
| 遠端桌面連不進來，但 3389 在聽 | 防火牆規則是停用的（第 13-2 節） |
| 用 VNC 主控台沒辦法複製貼上 | noVNC 不同步剪貼簿；指令改一行手打，或接上網路後用遠端桌面 |
| 在錯的節點執行了 `qm set` | 兩台 PVE 可以各有一個 VMID 102，**貼指令前看提示字元**；兩台若日後併成叢集，VMID 不能重複 |
| `grep` 顯示 `binary file matches` | 描述檔結尾有空位元組，改用 `grep -a` |
| `<Vmid>`、`<PVE IP>` 直接貼上去出現語法錯誤 | 角括號是範例佔位符，要換成實際的值再執行 |

## 16. 待辦

- [ ] 修復 HP Smart Array P420i 的寫入快取（快取模組或電容故障），並評估 `sda` 那組使用近 10 年的磁碟（細節與數據見下篇第 5 節）
- [ ] 上班日觀察 SQL 的磁碟延遲（`typeperf "\PhysicalDisk(*)\Avg. Disk sec/Write" -sc 60`），確認 RAID 5 無寫入快取下使用者的實際感受
- [ ] SQL 備份檔目前寫在 D 槽，規劃自動複製到別台機器（異地副本）
- [ ] 舊 VM 保留 1～2 週，觀察穩定後再決定是否刪除
- [ ] 開機碟與資料碟改 VirtIO SCSI（需要 virtio-win ISO 協助，目前維持 SATA）；D 碟有空間時可考慮從 VMDK 轉成 qcow2
- [ ] 清理殘留：`local-lvm` 的失敗搬移 LV（已清）、VMware 殘留驅動與資料夾（下篇第 8 節）

## 17. 延伸閱讀

- 本知識庫：[把 ESXi 上的 Windows＋SQL Server 虛擬機搬到獨立 PVE（二）：踩雷與效能診斷](https://kbwangtw.github.io/IT-Knowledge-Base/docs/pve/esxi-vm-to-pve-troubleshooting/)
- 本知識庫：[從 VMware ESXi 滾動式轉換到 PVE：新機先上、舊機回收（規劃 SOP）](https://kbwangtw.github.io/IT-Knowledge-Base/docs/pve/esxi-to-pve-rolling-migration-sop/)：整個環境（叢集、共用儲存）的規劃；本篇是單台 VM、獨立 PVE 的實作
- 本知識庫：[兩台獨立 PVE 之間搬 VM：用 qm remote-migrate 線上搬移](https://kbwangtw.github.io/IT-Knowledge-Base/docs/pve/pve-standalone-vm-live-migration/)：搬到 PVE 之後，兩台 PVE 之間怎麼搬
- [Proxmox VE：Migrate to Proxmox VE](https://pve.proxmox.com/wiki/Migrate_to_Proxmox_VE)
- [Proxmox VE：Windows VirtIO Drivers](https://pve.proxmox.com/wiki/Windows_VirtIO_Drivers)
- [Proxmox VE：QEMU/KVM Virtual Machines（含 USB passthrough 與 Guest Agent）](https://pve.proxmox.com/wiki/Qemu/KVM_Virtual_Machines)
