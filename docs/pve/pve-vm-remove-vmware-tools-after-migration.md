---
layout: default
title: "VMware 搬到 PVE 後，Windows VM 開機跳出 VMware Tools 錯誤：移除失敗（1603）的處理"
date: 2026-11-07
categories: [PVE, VMware, Windows, 遷移]
permalink: /docs/pve/pve-vm-remove-vmware-tools-after-migration/
last_modified_at: 2026-11-07
---

# VMware 搬到 PVE 後，Windows VM 開機跳出 VMware Tools 錯誤：移除失敗（1603）的處理

> **一句話**：Windows VM 從 VMware 搬到 PVE 之後，每次登入都跳出 `VMware Tools unrecoverable error`；正常移除又失敗（1603），所以改成「清掉 MSI 註冊 → 刪服務 → 刪開機自動執行 → 刪檔案 → 刪驅動」，最後再把 PVE 的 Guest Agent 套用起來，彈窗就消失了。

| 項目 | 內容 |
| --- | --- |
| 適合誰看 | 剛把 Windows VM 從 VMware 搬到 PVE，VM 裡還留著 VMware Tools 的人 |
| 環境 | PVE 主機（kernel 7.0.14-28-pve）上的 Windows Server 2019 VM；機型 `pc-i440fx-11.1`、UEFI（`ovmf`）、網卡 VirtIO、磁碟 SATA |
| 日期 | 2026-11-07 |
| 風險 | 中：要刪服務、檔案、驅動；動手前先做 snapshot；操作請用 PVE 的 noVNC console，不要只靠遠端桌面 |
| 結論 | ✅ 已完成：VMware 服務、資料夾、驅動、開機自動執行項目都已清除，重開機後彈窗消失；PVE 端 `qm agent <VMID> ping` 沒有錯誤 |

## 1. 先認識幾個名詞

| 名詞 | 白話解釋 |
| --- | --- |
| **VMware Tools** | 裝在 VM 裡的「輔助工具包」，讓 VMware 平台能和 VM 溝通（驅動、時間同步、關機通知等） |
| **`vmtoolsd.exe`** | VMware Tools 的主程式。一個以服務執行，一個在每次登入時啟動（`-n vmusr`） |
| **MSI／Product Code（GUID）** | Windows 的安裝套件格式。每個安裝的軟體有一組 GUID，`msiexec /x <GUID>` 就是用它來移除 |
| **Custom Action** | MSI 安裝或移除過程中，由廠商自己加進去執行的小程式。它失敗，整個移除就會跟著失敗 |
| **`0xc0000096`** | Windows 錯誤碼 `STATUS_PRIVILEGED_INSTRUCTION`：程式做了它沒有權限做的 CPU 動作 |
| **QEMU Guest Agent** | PVE 版的「輔助工具」，讓 PVE 能查 VM 狀態、乾淨關機、取得 IP |
| **VirtIO 驅動** | PVE（KVM）專用的虛擬網卡、磁碟驅動，效能比模擬真實硬體好 |
| **pending（PVE）** | PVE 把設定「先存起來、等 VM 重新啟動才套用」的狀態 |
| **`pnputil`** | Windows 內建的驅動管理指令，可以列出、刪除驅動套件 |
| **Run 登錄機碼** | Windows 登錄檔裡的「開機／登入自動執行清單」 |

## 2. 為什麼會跳出這個錯誤？

```text
VM 原本在 VMware 上：vmtoolsd 與 VMware 主機溝通 → 正常
        ↓ 搬到 PVE（KVM）
VM 裡的 VMware Tools 還在，但現在沒有 VMware 主機可以溝通
        ↓
每次登入 → Run 清單啟動 vmtoolsd.exe -n vmusr → 崩潰 → 彈出 0xc0000096
```

> **推測（未直接證實）**：VMware Tools 是透過 VMware 專屬的通道與主機溝通，在 PVE 上沒有這個通道，所以崩潰。移除後彈窗消失，間接支持這個說法。

## 3. 動手前：先確認這台 VM 現在跑在哪

| VM 現在跑在 | 怎麼辦 |
| --- | --- |
| **VMware（ESXi／vSphere）** | **不要移除**。改成修復或重裝 Tools，並檢查 Tools 與 ESXi 版本是否相容 |
| **PVE／KVM／Hyper-V** | 照本文移除 VMware Tools，改用對應平台的工具 |

再到 PVE 主機看 VM 設定：

```bash
qm config <VMID>
```

| 要看的欄位 | 為什麼 |
| --- | --- |
| `net0` | 要是 `virtio` 或 `e1000`。如果是 `vmxnet3`，移除 Tools 後 Windows 會失去這張網卡的驅動，VM 會斷網 |
| `sata0`／`scsi0`／`virtio0` | 磁碟匯流排。**移除過程中不要改**，驅動沒準備好就改成 VirtIO，Windows 會開不了機 |
| `agent` | 注意：`qm config` 預設會顯示「含 pending 的設定」，看到 `agent: 1` 不代表已套用，見 4-10 |

本次的狀況：`net0` 已是 VirtIO，VM 內也確認了 `Red Hat VirtIO Ethernet Adapter` 狀態 `Up`、`QEMU-GA` 服務 `Running`，所以不需要再裝 virtio-win。

## 4. 動手做

### 4-0 先做 snapshot（PVE 主機）

```bash
qm snapshot <VMID> before-vmtools-removal
```

**應該看到**：列出 `snapshotting 'drive-...'` 的訊息。本次還出現 `skipping guest filesystem freeze - disabled in VM options`（推測：VM 選項沒開啟備份時凍結檔案系統，不影響 snapshot 建立）。

> 這個 snapshot 不含 RAM（沒有加 `--vmstate`），還原後相當於「當機後重開」。**驗收完成後再刪**（見第 7 節）。

### 4-1 查出 Product Code，試正常移除

以**系統管理員** PowerShell 在 VM 內執行：

```powershell
Get-WmiObject Win32_Product | Where-Object Name -like "VMware Tools*" | Select Name, IdentifyingNumber
```

**應該看到**：`VMware Tools` 與一組 `{GUID}`。

```powershell
$p = Start-Process msiexec.exe -ArgumentList '/x "{<ProductCode>}" /qn /norestart /L*v C:\vmtools-uninstall.log' -Wait -PassThru
$p.ExitCode
```

| 片段 | 意思 |
| --- | --- |
| `/x "{GUID}"` | 依 Product Code 移除 |
| `/qn` | 不顯示介面 |
| `/norestart` | 不自動重開機 |
| `/L*v 路徑` | 寫出詳細 log，失敗時用來查原因 |
| `-Wait -PassThru` | 等它結束，才能取得真正的結束碼 |

| 結束碼 | 意思 |
| --- | --- |
| `0` | 成功 |
| `3010` | 成功，需要重開機 |
| 其他 | 失敗，看 log |

**本次結果**：`1603`（Fatal error during installation）。

### 4-2 從 log 找出真正的失敗點

`1603` 只是通用的「嚴重錯誤」，原因在 log 裡。搜 `Return value 3` 沒有結果（本次 log 是繁體中文介面，且失敗發生在 Custom Action），改搜 Custom Action：

```powershell
Select-String -Path C:\vmtools-uninstall.log -Pattern "CustomAction.*returned actual error|Error \d{4}" -Encoding Unicode | Select -First 10
```

**本次輸出**：

```text
CustomAction VM_LogStart returned actual error code 1603 (note this may not be 100% accurate if translation happened inside sandbox)
CustomAction VM_SendMsiLogToHostOnError returned actual error code 1603 (note this may not be 100% accurate if translation happened inside sandbox)
```

再用行號看前後文（行號依你的 log 調整，本次失敗點在第 743 行附近）：

```powershell
Get-Content C:\vmtools-uninstall.log -Encoding Unicode | Select -Index (730..750)
```

**本次前後文**（節錄）：

```text
Doing action: VM_LogStart
動作開始 14:36:14: VM_LogStart。
CustomAction VM_LogStart returned actual error code 1603
Doing action: VM_SendMsiLogToHostOnError
動作結束 14:36:14: VM_LogStart。傳回值 3。
CustomAction VM_SendMsiLogToHostOnError returned actual error code 1603
動作結束 14:36:14: INSTALL。傳回值 3。
```

| 觀察 | 意思 |
| --- | --- |
| `VM_LogStart` 之前的動作都是 `傳回值 1` | 前面沒有更早的錯誤 |
| `VM_LogStart` 約 0.35 秒就 `傳回值 3` | 移除程式的第一個 Custom Action 就失敗 |
| `VM_SendMsiLogToHostOnError` 也失敗 | 這個動作是「把 log 傳給 VMware 主機」，推測在 PVE 上傳不出去 |
| `INSTALL 傳回值 3` | 整個移除中止 |

**結論**：移除程式在第一個動作就停了，重試 `msiexec` 沒有意義。

### 4-3 確認系統還是原狀

用登錄檔查，不要再用 `Win32_Product`（它會逐一驗證所有 MSI，很慢，還可能觸發副作用）：

```powershell
Get-ItemProperty HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*, HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\* -ErrorAction SilentlyContinue |
  Where-Object DisplayName -like "VMware*" | Select DisplayName, PSChildName
Get-Service | Where-Object Name -match "VMTools|VGAuth|vmvss|vmware"
Test-Path "C:\Program Files\VMware\VMware Tools"
Get-WmiObject Win32_PnPSignedDriver | Where-Object Manufacturer -like "VMware*" | Select DeviceName, DriverVersion
```

**本次結果**（清除前）：

| 項目 | 結果 |
| --- | --- |
| 服務 | `VGAuthService` Running、`VMTools` Running、`vmvss` Stopped |
| 資料夾 | `C:\Program Files\VMware\VMware Tools` 存在 |
| 驅動 | 只有 `VMware Pointing Device`，版本 `12.5.12.0` |

代表移除在第一步就停了，沒有「移除到一半」的狀況。

### 4-4 清除 MSI 註冊

因為 Custom Action 擋住了正常移除，改用 Microsoft 官方的 **Program Install and Uninstall troubleshooter**（支援頁面名稱：*Fix problems that block programs from being installed or removed*）：以系統管理員執行 → 選 **Uninstalling** → 選清單中的 **VMware Tools**。

它只會清掉 MSI 註冊資訊，**服務、檔案、驅動仍在**，所以後面還要手動清。清完用 4-3 的第一段登錄檔指令確認：

**應該看到**：沒有任何輸出。本次結果：已執行 troubleshooter，登錄檔查詢沒有輸出（MSI 註冊已清掉）。

### 4-5 停掉並刪除服務

```powershell
Stop-Service VMTools, VGAuthService -Force -ErrorAction SilentlyContinue
Get-Process vmtoolsd, VGAuthService, vmacthlp -ErrorAction SilentlyContinue | Stop-Process -Force
sc.exe delete VMTools
sc.exe delete VGAuthService
sc.exe delete vmvss
```

| 片段 | 意思 |
| --- | --- |
| `Stop-Service -Force` | 先停服務，避免檔案被占用 |
| `Stop-Process -Force` | 確保殘留程序結束 |
| `sc.exe delete` | 刪除服務登錄，重開機後才完全消失 |

> ⚠️ 一定要寫 `sc.exe`。在 PowerShell 裡 `sc` 是 `Set-Content` 的別名，打 `sc delete ...` 不會刪服務。

**本次結果**：三個都回 `[SC] DeleteService 成功`。

### 4-6 刪掉開機自動執行的項目（彈窗的來源）

先看，不要盲刪：

```powershell
Get-ItemProperty HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run | Format-List
Get-ScheduledTask | Where-Object TaskName -like "*VMware*"
```

**本次結果**：

| 項目 | 內容 | 處理 |
| --- | --- | --- |
| `VMware User Process` | `"C:\Program Files\VMware\VMware Tools\vmtoolsd.exe" -n vmusr` | **刪除**（每次登入都會啟動，推測是彈窗來源） |
| `SecurityHealth` | Windows 安全性通知圖示 | 保留 |
| 列印驅動的啟動項 | 與 VMware 無關 | 保留 |
| 排程工作 | 沒有 VMware 相關 | 無需處理 |

```powershell
Remove-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run" -Name "VMware User Process"
```

| 片段 | 意思 |
| --- | --- |
| `-Path` | Run 登錄機碼 |
| `-Name` | 只刪這一個值，其他項目不動 |

### 4-7 刪除安裝資料夾

先確認上層底下只有 `VMware Tools`：

```powershell
Get-ChildItem "C:\Program Files\VMware" | Select Name
```

**本次結果**：只有 `VMware Tools`。

```powershell
Remove-Item "C:\Program Files\VMware\VMware Tools" -Recurse -Force
Get-ChildItem "C:\Program Files\VMware" -Force
Remove-Item "C:\Program Files\VMware" -Force
Test-Path "C:\Program Files\VMware"
```

**應該看到**：中間的 `Get-ChildItem` 沒有輸出（上層是空的才刪），最後 `Test-Path` 回 `False`。

### 4-8 刪除 VMware 滑鼠驅動

```powershell
pnputil /enum-drivers | Select-String -Context 2,5 "vmmouse"
```

**本次輸出**：

| 欄位 | 內容 |
| --- | --- |
| 發佈名稱 | `oem8.inf`（每台機器可能不同，以實際輸出為準） |
| 原始名稱 | `vmmouse.inf` |
| 提供者名稱 | VMware, Inc. |
| 驅動程式版本 | 10/27/2021 12.5.12.0 |

確認提供者是 VMware（不是 Red Hat 的 VirtIO）後再刪：

```powershell
pnputil /delete-driver oem8.inf /uninstall /force
```

| 片段 | 意思 |
| --- | --- |
| `/delete-driver oem8.inf` | 從驅動存放區刪除這個套件 |
| `/uninstall` | 同時從使用它的裝置卸載 |
| `/force` | 裝置正在使用也強制刪除 |

**本次結果**：`驅動程式套件已順利刪除`，並提示「需要將系統重新開機以完成解除安裝作業」。這時 `pnputil /enum-drivers` 已查不到 `vmmouse`，但 `Win32_PnPSignedDriver` 還會列出它，**重開機後才會消失**。

### 4-9 重開機並驗收

```powershell
Restart-Computer
```

重開機後：

```powershell
Get-Service | Where-Object Name -match "VMTools|VGAuth|vmvss"
Test-Path "C:\Program Files\VMware"
Get-WmiObject Win32_PnPSignedDriver | Where-Object Manufacturer -like "VMware*" | Select DeviceName, DriverVersion
Get-NetAdapter | Select Name, InterfaceDescription, Status
```

**本次結果**：服務無輸出；`Test-Path` 回 `False`；VMware 驅動無輸出；網卡 `Red Hat VirtIO Ethernet Adapter` 狀態 `Up`。

### 4-10 PVE 端：讓 Guest Agent 真正套用

在 PVE 主機驗證：

```bash
qm agent <VMID> ping
```

**本次先看到**：`No QEMU guest agent configured`，但 `qm config` 明明有 `agent: 1`。原因在 `qm pending`：

```bash
qm pending <VMID>
```

**本次輸出（節錄）**：

```text
new agent: 1,fstrim_cloned_disks=1
...
del ide0: none,media=cdrom
cur ...（執行中的設定，沒有 agent）
```

| 輸出 | 意思 |
| --- | --- |
| `new agent: ...` | Guest Agent 設定已寫入，但**尚未套用** |
| `cur` 清單沒有 `agent` | 執行中的 VM 還沒有 Guest Agent 通道 |
| `del ide0: none,media=cdrom` | 光碟機（掛 ISO 用）也在等待移除 |

`qm config` 預設顯示的是「含 pending 的設定」，所以看起來已經啟用。**需要把 VM 完整關機再開機**（不是只在 Windows 內重開機）：

```bash
qm shutdown <VMID>
qm status <VMID>
qm start <VMID>
```

**應該看到**：`qm status` 先是 `stopped`，開機後 `qm pending <VMID>` 只剩 `cur ...` 行（沒有 `new`、`del`），`qm agent <VMID> ping` 沒有輸出（成功時本來就沒有輸出）。

## 5. 驗收清單

| 項目 | 指令 | 應該看到 | 本次 |
| --- | --- | --- | --- |
| VMware 服務 | `Get-Service \| Where Name -match "VMTools\|VGAuth\|vmvss"` | 無輸出 | ✅ |
| 安裝資料夾 | `Test-Path "C:\Program Files\VMware"` | `False` | ✅ |
| VMware 驅動 | `Get-WmiObject Win32_PnPSignedDriver \| Where Manufacturer -like "VMware*"` | 無輸出 | ✅ |
| 網卡 | `Get-NetAdapter` | `Red Hat VirtIO Ethernet Adapter`、`Up` | ✅ |
| pending | `qm pending <VMID>` | 沒有 `new`／`del` | ✅ |
| Guest Agent | `qm agent <VMID> ping` | 無錯誤 | ✅ |
| 登入彈窗 | 重開機後登入 | 不再出現 `0xc0000096` | ✅ |

## 6. 常見問題

| 現象 | 怎麼辦 |
| --- | --- |
| `msiexec /x` 回 `1603`，搜不到 `Return value 3` | 失敗發生在 Custom Action。改搜 `CustomAction.*returned actual error`（4-2）。如果卡在 `VM_LogStart`，重試沒有用，改走 4-4 |
| 連跑兩次 `msiexec`，log 被蓋掉 | 兩次都寫同一個檔名。第二次改叫 `vmtools-uninstall2.log`。另外，第一次沒加 `-Wait` 時，`$LASTEXITCODE` 不可靠，要用 `Start-Process -Wait -PassThru` 取結束碼 |
| `sc delete VMTools` 沒反應 | PowerShell 的 `sc` 是 `Set-Content` 別名，要寫 `sc.exe` |
| 刪了服務，`Get-Service` 還看得到 | 服務會標記為刪除，重開機後才完全消失 |
| `Win32_Product` 查很慢 | 它會逐一驗證所有 MSI。改查 `Uninstall` 登錄機碼（4-3） |
| `qm agent <VMID> ping` 說 `No QEMU guest agent configured`，但 `qm config` 有 `agent: 1` | 設定在 pending，VM 還沒完整重啟。`qm pending <VMID>` 確認，再關機開機（4-10） |
| 驅動刪了，`Win32_PnPSignedDriver` 還看得到 | 驅動還被使用，重開機後才會消失 |
| 想把磁碟順便改成 VirtIO | 不要在移除過程中做。驅動沒準備好會開不了機；要換請另外安排，先加一顆小的 VirtIO 磁碟驗證 |
| 滑鼠驅動移除後游標怪怪的 | 系統會改用預設 HID 驅動，通常沒事。準備好 noVNC 與鍵盤，必要時再重開一次 |

## 7. 實測紀錄與結論

2026-11-07，PVE 上的 Windows Server 2019 VM：

| 步驟 | 結果 |
| --- | --- |
| snapshot `before-vmtools-removal` | ✅ 建立成功 |
| `msiexec /x` 正常移除 | ❌ `1603`，卡在 `VM_LogStart` |
| 清除 MSI 註冊 | ✅ 用 troubleshooter 清除，登錄檔已查不到 VMware |
| 刪 3 個服務 | ✅ `DeleteService 成功` |
| 刪 `Run` 的 `VMware User Process` | ✅ |
| 刪資料夾 `C:\Program Files\VMware` | ✅ |
| 刪驅動 `vmmouse.inf` | ✅ 重開機後生效 |
| PVE Guest Agent | ✅ 完整關機再開機後，`pending` 清空、`ping` 無錯誤 |
| 彈窗 | ✅ 消失 |

**經驗**：

- snapshot 本次在「彈窗是否消失」還沒確認前就刪除了，等於提前放棄回滾的退路。建議**驗收全部通過、觀察一兩天後**再刪。
- 這次 VM 的網卡本來就是 VirtIO、Guest Agent 也已安裝，流程單純；如果網卡是 `vmxnet3`，要先換成 VirtIO 並確認驅動，否則移除後會斷網。

## 8. 延伸閱讀

- 本知識庫：[從 VMware ESXi 滾動式轉換到 PVE：新機先上、舊機回收（規劃 SOP）](https://kbwangtw.github.io/IT-Knowledge-Base/docs/pve/esxi-to-pve-rolling-migration-sop/)：整體搬遷規劃；搬完之後記得回頭清掉 VM 裡的 VMware Tools
- [Proxmox 官方 Wiki：Qemu-guest-agent](https://pve.proxmox.com/wiki/Qemu-guest-agent)
- [Proxmox 官方 Wiki：Windows VirtIO Drivers](https://pve.proxmox.com/wiki/Windows_VirtIO_Drivers)
- [Microsoft Learn：pnputil](https://learn.microsoft.com/windows-server/administration/windows-commands/pnputil)
- Microsoft 支援頁面：*Fix problems that block programs from being installed or removed*（Program Install and Uninstall troubleshooter）
- Broadcom Knowledge Base：*Manually uninstalling VMware Tools*（編號 1001354，依記憶寫出，**連結與內容未再核對**；手動清除登錄檔與驅動的完整流程在那篇）
