---
layout: default
title: "兩台獨立 PVE 之間搬 VM：用 qm remote-migrate 線上搬移（PBS 虛擬機實測）"
date: 2026-11-05
categories: [PVE, PBS, 遷移]
permalink: /docs/pve/pve-standalone-vm-live-migration/
last_modified_at: 2026-11-06
---

# 兩台獨立 PVE 之間搬 VM：用 qm remote-migrate 線上搬移（PBS 虛擬機實測）

> **一句話**：兩台沒組叢集的 PVE，也能用 `qm remote-migrate --online` 把一台開著的 VM 直接搬過去；本次把 332 GB 的 PBS 虛擬機從 node220 搬到 node221 只花 18 分 34 秒，但來源是 ZFS、目標不是 ZFS 時，**必須用線上搬移，停機搬移會失敗**。

| 項目 | 內容 |
| --- | --- |
| 適合誰看 | 有兩台各自獨立的 PVE（沒有叢集），要把某台 VM 搬到另一台的人 |
| 環境 | node220、node221 皆為 PVE 9.2.25，**沒有組叢集**；要搬的是 VMID 200（主機名稱 PBS206，Proxmox Backup Server 4.2 的虛擬機） |
| 日期 | 2026-11-05 |
| 結論 | ✅ 已結案（2026-11-06）：線上搬移完成（耗時 00:18:34，兩顆磁碟共約 332 GB）<br>✅ node221 上 VM 200 為 `running`，磁碟、網卡、CPU 設定與預期相符，沒有 `lock`<br>✅ PBS 介面與 datastore 正常，手動備份與還原成功；兩台 PVE 的 `PBS206` storage 都是 active（使用者回報）<br>✅ 舊 VM 已刪除（`qm unlock 200` 後 `qm destroy 200 --purge`），node220 上沒有殘留磁碟<br>⚠️ datastore Verify 未執行：搬移後 datastore 上沒有排程備份的資料，無從驗證；建議 datastore 有資料後再補跑 |

## 1. 先認識幾個名詞

| 名詞 | 白話解釋 |
| --- | --- |
| **獨立節點（standalone）** | 一台 PVE 自己管自己，沒有和別台組成叢集。叢集內的搬移是內建功能；獨立節點之間要用 `remote-migrate` |
| **`qm remote-migrate`** | 把 VM 從這台 PVE 搬到**另一個 PVE 環境**的指令。靠對方的 API（8006 埠）和一把 API token 運作 |
| **API token** | 給程式用的臨時通行證，不用輸入帳號密碼。搬完要刪掉 |
| **指紋（fingerprint）** | 對方 PVE 憑證的身分證字號。指令要附上，用來確認「連到的真的是那台」，而不是被偷換的主機 |
| **線上搬移（`--online`）** | VM 開著就搬：磁碟用 QEMU 的「區塊鏡像」邊複製邊同步寫入，記憶體再接著搬，最後一瞬間切換過去 |
| **停機搬移** | VM 關機後才搬：直接複製磁碟，沒有區塊鏡像這一段 |
| **區塊鏡像（NBD）** | QEMU 把磁碟內容透過網路同步到對方的功能，目標是哪種儲存都可以 |
| **`zfs send` 串流** | ZFS 專用的資料傳輸格式，只有對方也是 ZFS 才收得下 |
| **CPU type** | 虛擬機看到的 CPU 型號。`host` 表示「原封不動給你這台主機的 CPU」；`x86-64-v2-AES` 是比較通用的型號 |
| **pending（待生效）** | VM 開著時用 `qm set` 改的設定，要整個 VM 重啟才會套用，在那之前只是「已登記、未生效」 |
| **VMID** | VM 的編號，搬過去的 VMID 在目標主機上不能已被占用 |

## 2. 全貌

```text
【搬移前】                                【搬移後】
node220 (獨立 PVE)                        node221 (獨立 PVE)
  VM 200 (PBS206)  ── 開機中 ──┐            VM 200 (PBS206) 執行中
   scsi0  32 GB  (local-zfs)   │            scsi0  32 GB  (local-lvm)
   scsi1 300 GB  (hddpool)     │            scsi1 300 GB  (VM_Store，dir)
                               │
          qm remote-migrate --online
          ├─ 1. 用 API token 登入 node221 的 8006
          ├─ 2. 在 node221 建立空磁碟，用區塊鏡像把兩顆磁碟同步過去
          ├─ 3. 記憶體搬過去，最後一瞬間切換
          └─ 4. node220 的舊 VM 停止；因為加了 --delete 0，設定與磁碟都保留
```

## 3. 為什麼選線上搬移？本次評估過程

| 做法 | 結果 |
| --- | --- |
| 停機搬移（先關機再 `remote-migrate`） | ❌ 1 秒內中止：`no matching import/export format found for storage 'VM_Store'`（見第 9 節） |
| **線上搬移（`--online`）** | ✅ 成功，18 分 34 秒 |
| 備份再還原（`vzdump` + `qmrestore`） | 未採用。scsi1 設了 `backup=0`，要暫時改成 1 才會一起備份，而且需要暫存空間 |
| 先組成兩節點叢集再搬 | 未採用。兩節點叢集沒有 quorum（多數決），一台掛掉另一台會被鎖住，不建議為了搬一次 VM 就組 |

## 4. 搬移前先確認這些

### 4-1 要搬的 VM

在 node220 執行：

```bash
qm config 200
```

| 看什麼 | 本次看到 | 為什麼重要 |
| --- | --- | --- |
| `hostpci*`、`usb*` | 無 | 有 passthrough 的設備無法搬 |
| `ide2`（光碟） | 掛著 `local:iso/proxmox-backup-server_4.2-1.iso` | ISO 放在來源的 `local`，搬移前先退掉（第 5-2 節）。**未實測不退會怎樣**，這是預防做法 |
| 磁碟 | `scsi0` 在 `local-zfs`（32 GB）、`scsi1` 在 `hddpool`（300 GB，是 PBS 的 datastore，`backup=0`） | 決定目標 storage 對應，也決定搬移時間 |
| `cpu:` | `host` | 兩台 CPU 世代不同時要改（見 4-2） |
| `net0` 的 `bridge=` | `vmbr0` | 目標主機要有同名橋接，或搬移時用 `--target-bridge` 指定 |

### 4-2 兩台的 CPU 要相容

| 節點 | CPU | 世代 |
| --- | --- | --- |
| node220（來源） | Xeon E3-1270 v5 | Skylake（較新） |
| node221（目標） | Xeon E5-2620 v2 | Ivy Bridge（較舊） |

VM 的 CPU type 原本是 `host`，guest 會看到 Skylake 才有的指令集，搬到較舊的 CPU 上，執行中的程式**可能**當機（推測，本次沒有實測 `host` 的結果，直接依穩妥做法改成通用型號）。所以搬之前先把 CPU type 改成 `x86-64-v2-AES`（第 5-3 節）。

### 4-3 目標主機

在 node221 執行：

```bash
pvesm status --content images
ip -br link show vmbr0
qm list
free -h
```

| 看什麼 | 本次看到 |
| --- | --- |
| 可放虛擬磁碟的 storage | `VM_Store`（dir，可用約 1.06 TB）、`local-lvm`（lvmthin，可用約 449 GB） |
| `vmbr0` | 存在，狀態 UP |
| 目標 VMID 200 是否被占用 | 沒有，只有另一台既有 VM（VMID 101） |
| 可用記憶體 | `available` 52 GiB（總共 62 GiB），搬來的 4 GB 沒問題 |

**注意**：目標 storage 必須允許放「Disk image」內容類型，否則不會出現在 `--content images` 的清單裡。

### 4-4 兩台之間的網路

在 node220 執行：

```bash
curl -k -s -o /dev/null -w "%{http_code}\n" https://<node221 IP>:8006
```

應該看到 `200`。沒有回應就不要往下，先修網路。

## 5. 動手做

### 5-1 停用備份排程

**做什麼**：搬移期間 PBS 服務會有短暫中斷，而且 datastore 有寫入會讓鏡像更久。所以先暫停會寫入這台 PBS 的備份任務。

**怎麼做**：在 node220、node221 的 Datacenter → Backup，停用會寫入 PBS206 的任務，並確認目前沒有備份正在跑。

**應該看到**：兩台都沒有執行中的備份任務。

> 本次搬移前，這台 VM 本來就是關機狀態（node221 上的 `PBS206` storage 顯示 inactive、`No route to host`），所以沒有備份在寫入。

### 5-2 退掉光碟

**做什麼**：ISO 在來源主機的 `local`，目標主機沒有，搬移前先退掉。

```bash
qm set 200 --ide2 none,media=cdrom
```

**應該看到**：`update VM 200: -ide2 none,media=cdrom`。VM 開著或關著都可以做。

### 5-3 改 CPU type 並確認已生效

**做什麼**：把 `host` 改成通用型號，讓兩台 CPU 相容。

```bash
qm set 200 --cpu x86-64-v2-AES
qm pending 200
```

**重要**：VM 開著時，這個設定只是 pending，**要重啟才會真正套用**。如果 VM 本來就開著：

```bash
qm reboot 200
```

| 指令 | 意思 |
| --- | --- |
| `qm set 200 --cpu x86-64-v2-AES` | 把 CPU type 改成兩台都支援的通用型號 |
| `qm pending 200` | 列出設定；有 `new` 開頭的項目代表還沒生效 |
| `qm reboot 200` | 由 PVE 重啟（停掉再重開 QEMU 程序），會套用 pending 的設定；在 guest 裡按重開機**不會**套用 |

**應該看到**：`qm pending 200` 全部是 `cur` 開頭，沒有 `new`，且 `cur cpu: x86-64-v2-AES`；`qm status 200` 是 `status: running`。

> 線上搬移需要 VM 是開機狀態。如果它本來關著，就 `qm start 200`。

### 5-4 在 node221 建 API token

**做什麼**：建一把臨時 token，讓 node220 能登入 node221 的 API。

```bash
pveum user token add root@pam mig --privsep 0 --output-format json
```

| 片段 | 意思 |
| --- | --- |
| `root@pam mig` | 替 `root@pam` 建一把叫 `mig` 的 token |
| `--privsep 0` | token 沿用該使用者的完整權限（不另外限縮）。**權限等同 root，用完要刪** |
| `--output-format json` | 以一行 JSON 輸出，比預設的表格好複製，不會夾到邊框 |

**應該看到**：一行 JSON，`value` 欄位就是 secret。**secret 只會出現這一次**，立刻用雙擊選取複製，不要把完整值貼進任何文件或聊天。

### 5-5 在 node220 取得指紋、整理變數

**做什麼**：取得 node221 的 8006 埠**實際出示**的憑證指紋，並把 secret 存進變數。

先關掉歷史展開（後面指令裡的 `!` 會被 bash 誤判，見第 9 節）：

```bash
set +H
```

取得指紋：

```bash
FP=$(openssl s_client -connect <node221 IP>:8006 </dev/null 2>/dev/null | openssl x509 -noout -fingerprint -sha256 | cut -d= -f2)
echo "$FP" | tr ':' '\n' | wc -l
```

輸入 secret 並統一成帶連字號的格式：

```bash
read -rs TOKEN
TOKEN=$(echo "$TOKEN" | tr -d '-')
TOKEN2="${TOKEN:0:8}-${TOKEN:8:4}-${TOKEN:12:4}-${TOKEN:16:4}-${TOKEN:20:12}"
echo ${#TOKEN} ${#TOKEN2}
```

| 片段 | 意思 |
| --- | --- |
| `s_client -connect …:8006` | 直接問 node221 的 API 埠出示哪張憑證，取到的才是實際在用的那張（`pvenode cert info` 可能列出兩張，容易選錯） |
| `cut -d= -f2` | 把 `sha256 Fingerprint=` 前綴切掉，只留指紋本身 |
| `wc -l` | 算指紋有幾組，應該是 `32` |
| `read -rs TOKEN` | 以不顯示、不留歷史的方式輸入 secret |
| `tr -d '-'` 再用 `${TOKEN:起點:長度}` 補回 | 本次複製時 secret 曾少了連字號（變成 32 字元），所以先全部去掉，再依 8-4-4-4-12 補回；不論貼進來帶不帶連字號都能處理 |

**應該看到**：指紋那行輸出 `32`；最後一行輸出 `32 36`。

### 5-6 先用 curl 驗證 token

**做什麼**：不真的搬移，只用 token 問一次版本，確認認證沒問題。

```bash
curl -k -s -H "Authorization: PVEAPIToken=root@pam!mig=${TOKEN2}" https://<node221 IP>:8006/api2/json/version
```

**應該看到**：`{"data":{"version":"9.2.25", ...}}`。回傳空白或 `401` 就是 secret 不對，不要往下，見第 9 節。

### 5-7 執行線上搬移

**做什麼**：把 VM 200 搬到 node221。建議先開 `tmux`，避免 SSH 斷線把搬移中斷。

```bash
tmux new -s mig
```

整段放在**同一行**執行（多行用 `\` 換行，貼上時可能被截斷）：

```bash
qm remote-migrate 200 200 "apitoken=PVEAPIToken=root@pam!mig=${TOKEN2},host=<node221 IP>,fingerprint=${FP}" --target-bridge vmbr0 --target-storage local-zfs:local-lvm,hddpool:VM_Store --online --delete 0
```

| 片段 | 意思 |
| --- | --- |
| `200 200` | 來源 VMID、目標 VMID（目標上不能已被占用） |
| `apitoken=…,host=…,fingerprint=…` | 用 token 登入目標、指定目標位址、核對憑證指紋 |
| `--target-bridge vmbr0` | VM 的網卡接到 node221 的 `vmbr0` |
| `--target-storage local-zfs:local-lvm,hddpool:VM_Store` | 儲存對應：來源 `local-zfs` 的磁碟放到 `local-lvm`，`hddpool` 的磁碟放到 `VM_Store`（格式是 `來源:目標`，逗號分隔多組） |
| `--online` | 開機狀態搬移，磁碟用區塊鏡像複製 |
| `--delete 0` | 搬完**保留**來源的舊 VM 設定與磁碟，確認新的沒問題再自己刪 |

搬移進行中，可以按 `Ctrl+b` 再按 `d` 離開 tmux，之後用 `tmux attach -t mig` 回來看。

**應該看到**：先是 `starting migration of VM 200 to node 'node221'`，接著 `copying local disk images`，一路到區塊鏡像完成：

```text
mirror-scsi0: Completed successfully.
mirror-scsi1: Completed successfully.
…
migration finished successfully (duration 00:18:34)
```

**本次實測**：兩顆磁碟共約 332 GB，耗時 00:18:34；結束時間 2026-11-05 17:01:02。

## 6. 搬完驗證

### 6-1 在 node221 看 VM 設定

```bash
qm status 200
qm config 200
```

| 項目 | 本次實測結果 |
| --- | --- |
| `qm status 200` | ✅ `running` |
| `scsi0` | ✅ `local-lvm:vm-200-disk-0`，32 GB |
| `scsi1` | ✅ `VM_Store:200/vm-200-disk-0.raw`，300 GB（`backup=0` 保留） |
| `net0` | ✅ `bridge=vmbr0`，MAC 位址與搬移前相同，PBS 介面可正常使用（使用者回報） |
| `cpu` | ✅ `x86-64-v2-AES` |
| `ide2` | ✅ `none` |

`boot` 欄位仍列著 `ide2`，但光碟已是 `none`，不影響開機。

### 6-2 確認舊 VM 沒在跑

在 node220 執行：

```bash
qm status 200
qm config 200 | grep onboot
```

本次 `qm status 200` 為 ✅ `stopped`。**舊 VM 不能再啟動**，否則兩台會用同一個 IP 與 MAC。`onboot` 沒輸出或 `onboot: 0` 都沒問題；若是 `onboot: 1`，執行 `qm set 200 --onboot 0`，避免 node220 重開機時把它又啟動起來。（本次尚未檢查 `onboot`，見待辦）

**舊 VM 會帶著 `lock: migrate`**：2026-11-06 實測，node220 上的舊 VM `qm status 200` 為 `stopped`，`qm config 200` 有 `lock: migrate`。這是用 `--delete 0` 保留舊 VM 時留下的鎖，推測用意是防止誤啟動；對它做啟動、備份等操作會出現 `TASK ERROR: VM is locked (migrate)`。**這不是故障，不要為了消除錯誤就 `qm unlock`**，要等確定刪除舊 VM 時才解鎖，刪除步驟見 7-2。

### 6-3 確認 PBS 服務本身

這部分要看 PBS 自己的介面，從 PVE 設定看不出來：

1. 登入 PBS 介面，Dashboard 與 datastore 狀態正常
2. 對 datastore 跑一次 Verify，確認搬移沒有造成資料損毀
3. 兩台 PVE 的 Datacenter → Storage 裡，名為 `PBS206` 的 storage 變成 active（搬移前顯示 inactive）
4. 恢復備份排程，手動備份一台 VM，再做一次還原測試

本次實測（2026-11-06，使用者回報）：PBS 介面與 datastore 正常，手動備份與還原都成功，兩台 PVE 的 `PBS206` storage 都是 active。**Verify 本次未執行**：datastore 上目前沒有排程備份的資料，沒有東西可驗證。之後有排程備份產生資料，建議補跑一次 Verify，再確認搬移後的資料完整性。

## 7. 收尾

### 7-1 刪掉 token、清掉變數

在 node221 執行：

```bash
pveum user token remove root@pam mig
```

本次執行時回應 `no such token 'mig' for user 'root@pam'`，表示 token 已不存在，不需要再處理。

在 node220 的 shell 執行：

```bash
unset TOKEN TOKEN2 FP
```

token 的權限等同 root，搬完就刪，不要留著。

### 7-2 刪除舊 VM

node220 上的舊 VM 200（含 `local-zfs` 32 GB、`hddpool` 300 GB 的磁碟）因為 `--delete 0` 還在。建議先**觀察一週**，確認 PBS 備份、Verify、還原都沒問題再刪。本次是搬移隔天（2026-11-06）、備份與還原成功後就決定刪除。

**刪除前確認**：`scsi1` 設了 `backup=0`，舊 VM 的 `hddpool` 磁碟是 datastore 搬移前唯一的另一份副本，刪掉就沒有退路。確認 datastore 的 Verify 已跑完、新備份有成功寫入、不再需要退路。

**1. 先確認要刪的是對的那一台**

```bash
hostname
qm status 200
qm config 200 | grep -E "name|lock|scsi"
```

本次看到：`node220`、`status: stopped`、`lock: migrate`、`name: PBS206`、`scsi0` 在 `local-zfs`、`scsi1` 在 `hddpool`。**主機名稱不是來源節點就立刻停手**，那是新 VM。

**2. 解鎖並刪除**

```bash
qm unlock 200
qm destroy 200 --purge
```

| 片段 | 意思 |
| --- | --- |
| `qm unlock 200` | 移除 `lock: migrate`，不然刪不掉。解鎖後**絕對不要啟動它** |
| `qm destroy 200` | 刪除 VM 設定，以及設定裡引用的磁碟（`scsi0`、`scsi1`） |
| `--purge` | 同時把 VMID 200 從這台的備份、複寫、HA 設定裡清掉 |

**應該看到**：`purging VM 200 from related configurations..`（本次實測）。

**3. 確認磁碟真的釋放了**

```bash
qm list
zfs list | grep vm-200
```

本次實測：`qm list` 沒有 VMID 200（只剩 node220 上原本的另一台 VM），`zfs list | grep vm-200` 沒有任何輸出，兩顆磁碟都已釋放。

### 7-3 搬完之後的風險

PBS206 現在和另一台 VM 同在 node221 上，node221 的 VM 備份也寫進同一台主機，**node221 整台壞掉時，VM 和備份會一起消失**。建議把 datastore 同步一份到別處（外接磁碟、NAS 或異地 PBS）。這是**後續建議，本次未做**，不影響這次搬移的驗收。

## 8. 本次實測紀錄

| 時間（2026-11-05） | 事件 |
| --- | --- |
| 搬移前 | `qm config 200` 確認 `cpu: host`、`ide2` 掛 ISO、`scsi0` 在 `local-zfs`、`scsi1` 在 `hddpool`；VM 為關機狀態 |
| 搬移前 | node221：`VM_Store`（dir）、`local-lvm`（lvmthin）可放磁碟；可用記憶體 52 GiB；`curl` 8006 回 `200` |
| 16:15:36 | 第一次嘗試：**停機搬移**，`remote-migrate` 帶 `--target-storage local-zfs:local-lvm,hddpool:VM_Store`，1 秒內中止，錯誤 `no matching import/export format found for storage 'VM_Store'`；`zfs list -t snapshot` 顯示 `no datasets available`，沒有殘留的 `__migration__` 快照，原 VM 不受影響 |
| 之後 | `qm set 200 --cpu x86-64-v2-AES`、`qm pending 200` 全部為 `cur`、沒有 `new`；VM 在 node220 開機 |
| 17:01:02 | 第二次嘗試：加上 `--online`，`migration finished successfully (duration 00:18:34)`；`mirror-scsi0`、`mirror-scsi1` 皆完成 |
| 搬移後 | node221 `qm status 200` 為 `running`，設定與預期相符；node220 `qm status 200` 為 `stopped` |
| 2026-11-06 | 使用者回報：PBS 介面與 datastore 正常，手動備份與還原成功 |
| 2026-11-06 | 使用者回報：兩台 PVE 的 `PBS206` storage 都是 active；datastore 上沒有排程備份的資料，Verify 無從執行 |
| 2026-11-06 | 刪除舊 VM：`qm unlock 200`、`qm destroy 200 --purge` 成功，`qm list` 無 VMID 200，`zfs list \| grep vm-200` 無輸出；node221 `pveum user token remove` 回應 `no such token 'mig'`（token 已不存在） |
| 2026-11-06 | node220 舊 VM（刪除前）：`status: stopped`、`lock: migrate`；對它操作出現 `TASK ERROR: VM is locked (migrate)`（預期行為，見 6-2）。node221 新 VM：`status: running`、`qm config 200` 沒有 `lock`（✅ 沒被鎖） |

## 9. 常見問題

| 現象 | 怎麼辦 |
| --- | --- |
| `400 Parameter verification failed. target-endpoint: invalid format` 與 `fingerprint: value does not match the regex pattern` | 指紋格式不對（含佔位文字、多餘空白或 `sha256 Fingerprint=` 前綴）。用 5-5 的指令取得，確認有 32 組，再用變數帶入，不要手動貼 |
| `-bash: !mig=: event not found` | 雙引號裡的 `!` 被 bash 當成「歷史展開」。先執行 `set +H` 關掉，只對目前這個 shell 有效 |
| `401 Authentication failed!` | secret 不對。先用 `echo ${#TOKEN}` 看長度：本次實測出現過 190（貼進去夾了其他內容）和 32（少了連字號）。用 5-5 的方式統一格式，再用 5-6 的 curl 驗證；仍不行就刪除 token 重建，secret 無法找回 |
| `qm set --cpu` 之後，CPU 還是舊的 | VM 開著時只是 pending。用 `qm pending 200` 看有沒有 `new`，用 `qm reboot 200` 讓它生效 |
| 停機搬移出現 `no matching import/export format found for storage '…'` | 來源是 ZFS 時，停機搬移用 `zfs send` 串流，目標不是 ZFS（本次是 dir 與 lvmthin）就收不下。**原因為推測**，依錯誤訊息推斷，改用 `--online`（區塊鏡像，不依賴 ZFS 串流）後成功，可作為佐證。若目標也有 ZFS storage，停機搬移應該可行（未驗證） |
| 貼上長指令被截斷，只執行到一半 | 整段放在單行貼上，貼完先看結尾是不是 `--delete 0`。本次曾有一行被截成不完整的網址，帶著 token 的 `Authorization` 標頭送到了錯誤的位址（沒有服務回應，影響很小，但這就是 token 搬完要刪的原因） |
| 備份任務沒有備份到 datastore 資料 | 本次 `scsi1` 設了 `backup=0`，`vzdump` 不會備份它。所以搬移前的退路備份只會包含系統碟，datastore 資料要靠另一份副本 |
| node221 的 PBS storage 顯示 `inactive`、`No route to host` | 本次是因為 VM 當時關機沒有回應，不是網路問題。搬完開機後兩台的 `PBS206` storage 都變回 active（2026-11-06，使用者回報） |
| 對 node220 的舊 VM 操作時出現 `TASK ERROR: VM is locked (migrate)` | 用 `--delete 0` 保留舊 VM 時，舊 VM 會留著 `lock: migrate`（用 `qm config 200 \| grep lock` 確認）。這是預期行為，推測是防止誤啟動，**不要 `qm unlock` 後再啟動它**。要刪除舊 VM 時才解鎖（`qm unlock 200` 後 `qm destroy 200 --purge`，本次實測可行）。若是 node221 上的新 VM 出現這個鎖，先確認沒有搬移任務還在跑，再處理 |
| 搬移失敗或中止 | 不要急著重試或手動刪東西。有 `--delete 0` 時來源 VM 通常還在；先檢查來源有沒有 `__migration__` 快照（`zfs list -t snapshot`）、目標有沒有殘留磁碟，再把完整訊息拿去查 |

## 10. 驗收紀錄

| 驗收項目 | 結果 | 依據 |
| --- | --- | --- |
| 線上搬移完成 | ✅ `migration finished successfully (duration 00:18:34)` | 實測輸出 |
| node221 新 VM 設定正確、沒有 `lock` | ✅ `running`，磁碟、網卡、CPU 與預期相符 | 實測輸出（2026-11-06） |
| PBS 介面與 datastore 正常 | ✅ | 使用者回報（2026-11-06） |
| 手動備份並還原一台 VM | ✅ | 使用者回報（2026-11-06） |
| 兩台 PVE 的 `PBS206` storage 為 active | ✅ | 使用者回報（2026-11-06） |
| 刪除 node220 舊 VM 與磁碟 | ✅ `qm list` 無 VMID 200、`zfs list \| grep vm-200` 無輸出 | 實測輸出（見 7-2） |
| 刪除 node221 的 token | ✅ `no such token 'mig'`，token 已不存在 | 實測輸出 |
| datastore Verify | ⚠️ 未執行：datastore 上沒有排程備份的資料 | 使用者回報；有資料後建議補跑 |
| 備份排程 | 無須處理：使用者回報目前沒有排程備份 | 使用者回報 |
| datastore 第二份副本 | 後續建議，本次未做（見 7-3） | — |

## 11. 延伸閱讀

- [Proxmox VE 官方文件：QEMU/KVM 虛擬機器（含遷移）](https://pve.proxmox.com/pve-docs/chapter-qm.html)
- [`qm` 指令手冊（remote-migrate 的完整參數）](https://pve.proxmox.com/pve-docs/qm.1.html)：指令格式請以自己版本的 `qm remote-migrate --help` 為準
- [Proxmox Backup Server 官方文件](https://pbs.proxmox.com/docs/)
- 本知識庫：[PBS 更新後，怎麼確認備份還能用？](https://kbwangtw.github.io/IT-Knowledge-Base/docs/pve/ProxCenter-PBS-Update-and-DR-Validation-SOP/)
- 本知識庫：[從 PBS 還原 ProxCenter：先複製一台，再確認能用](https://kbwangtw.github.io/IT-Knowledge-Base/docs/pve/proxcenter-pbs-restore-dr-runbook/)
