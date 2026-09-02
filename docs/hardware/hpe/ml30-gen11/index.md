---
layout: default
title: "HPE ProLiant ML30 Gen11：硬體擴充、NVMe UEFI 驗證與儲存規劃"
date: 2026-09-02
categories: [Hardware, HPE, ML30 Gen11]
---

# HPE ProLiant ML30 Gen11：硬體擴充、NVMe UEFI 驗證與儲存規劃

## 摘要與目前進度

本文記錄一台 HPE ProLiant ML30 Gen11 的實機擴充與 UEFI 驗證。已完成 **P65741-B21 iLO/NIC/M.2/COM Port Kit**、DB9 Serial Port 與 Samsung SSD 990 PRO 1TB 的實體安裝；UEFI 已成功辨識 NVMe。後續規劃安裝 **Windows Server 2025 English**，以 990 PRO 作為 OS／System Disk，另以 2 顆 SATA HDD 透過 **Intel VROC SATA RAID** 建立 RAID 1 Data Volume。

> 截至 2026-09-02，作業系統與 RAID 1 尚未安裝／建立。本文只記錄已完成的硬體與 UEFI 驗證，以及後續規劃，不代表 Windows Server 2025 部署已完成。

## 本次硬體與規劃

| 項目 | 本次狀態 |
|---|---|
| Slim Optical Drive | 原機若要安裝，需另購 `P65102-B21` Enablement Kit |
| iLO／M.2／COM 擴充 | `P65741-B21` 已到貨並完成安裝 |
| M.2 NVMe | Samsung SSD 990 PRO 1TB 已安裝，UEFI 辨識成功 |
| iLO 管理網路 | Dedicated iLO RJ45 已安裝；與 Embedded NIC 1 Shared iLO 分開說明 |
| Serial Port | DB9 Serial Port 已安裝於後方 I/O |
| OS 規劃 | Windows Server 2025 English，990 PRO 作 OS／System Disk；尚未安裝 |
| Data 規劃 | 2 × SATA HDD，以 Intel VROC SATA RAID 建 RAID 1；尚未建立 |

## Slim Optical Drive：原機還需要 Enablement Kit

HPE QuickSpecs 將內接 Slimline ODD 列為選配，並註明選擇內接 ODD 時需要 **HPE ProLiant ML30 Optical Disk Drive Slimline Enablement Kit（P65102-B21）**；該 ODD Bay Kit 會占用一個 media bay。換言之，只有 Slim Optical Drive 本體不等於安裝所需托架／面板／線材已齊全，下單時必須把 Enablement Kit 一併核對。

| 項目 | HPE 料號 | 說明 |
|---|---|---|
| ML30 Optical Disk Drive Slimline Enablement Kit | `P65102-B21` | 內接 Slimline ODD 所需；占用 1 個 media bay |
| 9.5 mm SATA DVD-ROM Optical Drive | `726536-B21` | ODD 本體；仍需搭配 Enablement Kit |
| 9.5 mm SATA DVD-RW Optical Drive | `726537-B21` | ODD 本體；仍需搭配 Enablement Kit |

![已裝入機箱前方的 Slimline 光碟機](images/slim-odd-front.jpg)

![Slimline 光碟機後方線材與模組區](images/slim-odd-cabling.jpg)

## P65741-B21 套件到貨與功能

本次加購 **HPE ProLiant ML30 Gen11 iLO/NIC/M.2/COM Port Kit（P65741-B21）**。HPE User Guide 將這個多功能模組的用途列為：

- 一個 M.2 NVMe SSD 插槽；
- iLO Dedicated Management Network Port；
- Serial Port，透過隨附線材接至後方 DB9。

![P65741-B21 套件到貨開箱，包含多功能板、DB9 線材、支架與固定零件](images/p65741-kit-unboxed.jpg)

照片僅用來記錄本次到貨內容；功能與安裝方式仍以 HPE User Guide 為準。

## 實機安裝結果

### 擴充板與主機板

![P65741-B21 已安裝於 ML30 Gen11 主機板，M.2 插槽尚未裝入 SSD](images/p65741-installed-mainboard.jpg)

擴充板已固定於主機板專用接頭。本張照片是 SSD 到貨前的狀態，可清楚看到模組上的 M.2 插槽。

### 後方 iLO Dedicated RJ45 與 DB9 Serial Port

![機殼後方新增的 iLO Dedicated RJ45 與 DB9 Serial Port](images/ilo-dedicated-serial-rear.jpg)

後方 I/O 可見新增的 Dedicated iLO RJ45 與 DB9 Serial Port。照片中的 VGA 線是現場作業連線，與此套件功能無關。

### Samsung SSD 990 PRO 1TB

![Samsung SSD 990 PRO 1TB 已安裝於 P65741-B21 的 M.2 插槽；唯一識別資訊已遮蔽](images/samsung-990-pro-installed-redacted.jpg)

Samsung SSD 990 PRO 1TB 已實際安裝完成。照片中的產品序號、PSID、QR code 與條碼已遮蔽；保留型號、容量與安裝位置作為技術紀錄。

## UEFI 實機驗證

### Storage Device Information

![UEFI Storage Device Information；三顆硬碟序號已遮蔽](images/uefi-storage-device-info-redacted.jpg)

UEFI 實測顯示：

| 欄位 | 實測值 |
|---|---|
| Capacity | `1000204 MB` |
| Drive Type | `NVMe` |
| Location | `Embedded NVMe M.2 Drive 1` |
| Model Number | `Samsung SSD 990 PRO 1TB` |
| Firmware Version | `5B2QJXD7` |

同一頁也顯示兩顆 1 TB SATA HDD 位於 `Embedded SATA Port 2 Bay 1` 與 `Bay 2`；這只能證明 UEFI 看得到兩顆實體碟，**不代表 RAID 1 已建立**。

### NVMe Slot 20

![UEFI 顯示 NVMe Slot 20 已 populated 且 enabled](images/uefi-nvme-slot-20.jpg)

另一張 UEFI 畫面顯示：

- Location：`NVMe Slot 20`
- Populated：`Yes`
- Enabled：`Yes`
- Device Name：`NVM Express Controller`

因此，本次實機可確認 990 PRO 不只是完成實體安裝，ML30 Gen11 UEFI 也已正常枚舉並啟用此 NVMe 裝置。

> **驗證邊界：** 這是本次特定 ML30 Gen11、P65741-B21 與 Samsung SSD 990 PRO 1TB 組合的實機驗證成功，不代表 HPE 官方認證 Samsung 990 PRO，也不代表所有零售 M.2 NVMe SSD 都受 HPE 支援。正式環境仍應評估韌體、溫度、耐寫度、健康監控、保固與長時間穩定性。

## Shared iLO 與 Dedicated iLO 的差異

P65741-B21 不是讓伺服器「開始具備 iLO」，而是增加獨立的管理網路介面。HPE User Guide 指出，機載 **NIC 1／iLO Shared Port** 是系統預設 iLO port；安裝模組後才可使用 **iLO Dedicated Network Port**。

| 比較項目 | Embedded NIC 1 Shared iLO | iLO Dedicated Port |
|---|---|---|
| 實體介面 | 與主機網路的 NIC 1 共用 | 獨立 RJ45，只供 iLO 管理 |
| 額外硬體 | 原機可用 | 需要 `P65741-B21` |
| 使用情境 | 減少埠與佈線 | 管理網路需要獨立實體介面／交換器 |
| 安裝後設定 | 原機預設路徑 | 依 User Guide 在 iLO 6 Configuration Utility 啟用並確認 IP |

切換到 Dedicated Port 前，應先規劃管理 VLAN、交換器、IP、DNS、監控與回復路徑，避免遠端切換後失聯。

## 後續 OS 與儲存規劃（尚未執行）

```text
HPE ProLiant ML30 Gen11
├─ P65741-B21 M.2 slot
│  └─ Samsung SSD 990 PRO 1TB
│     └─ Windows Server 2025 English：OS / System Disk（規劃）
├─ Embedded Intel VROC SATA RAID
│  ├─ SATA HDD #1
│  └─ SATA HDD #2
│     └─ RAID 1：Data Volume（規劃）
└─ iLO 6
   └─ Dedicated Management Port
```

作業系統將由使用者後續自行安裝。本文沒有把尚未執行的 Windows 安裝、開機、驅動、RAID 建立或資料碟格式化寫成已完成。

## Intel VROC SATA RAID：HPE 官方注意事項

依目前 ML30 Gen11 QuickSpecs：

- 所有 ML30 Gen11 型號支援 Intel VROC SATA RAID；BIOS 預設仍是 SATA AHCI，VROC SATA RAID 預設停用，需由使用者在 BIOS／RBSU 或 iLO Redfish API 啟用。
- 支援 RAID 0、1、5、10，且必須使用 UEFI Boot Mode。
- VROC SATA RAID Volume 不能在 Intelligent Provisioning 建立，必須手動建立。
- VROC SATA RAID OS driver 不包含在 HPE SPP，需從 HPE Support Center 下載與作業系統相符的 driver；Windows 可使用 Intel VROC GUI／CLI 管理。
- RAID set 不可跨不同 drive form factor／drive cage；本次 990 PRO 不會加入 SATA RAID，RAID 1 僅使用兩顆 SATA HDD。
- HPE 要求在 OS 安裝 Agentless Management Service（AMS），讓系統取得磁碟溫度感測資料供風扇控制；未安裝可能造成噪音影響。
- Intel VROC SATA RAID 支援 Windows Server 與 Linux，不支援 VMware。

建立 RAID 1 前應再次確認兩顆 SATA HDD 的健康狀態、容量與重要資料備份；建立 Volume 可能清除磁碟內容。

## P65106-B21 Front PCI Fan and Baffle Kit：條件式需求

**HPE ProLiant ML30 Gen11 Front PCI Fan and Baffle Kit（P65106-B21）**不是所有 M.2 組態都一律要另購。QuickSpecs 的規則依基礎機型／機箱與所選 PCIe 選項而不同：

- 預組態 Performance Model 已包含此套件；
- 4LFF Hot Plug CTO 與 8SFF Hot Plug CTO 必須選擇；
- 4LFF Non-Hot Plug CTO 與預組態 Entry Model 若選擇 PCIe 卡，依 QuickSpecs 規則必須選擇。

因此不能只看到「裝 M.2」就一概寫成必需，也不能假設一定不需要。應以完整產品 SKU、4LFF／8SFF、Hot Plug／Non-Hot Plug、Performance／Entry／CTO、現有風扇與全部擴充選項，交由最新 QuickSpecs 與 HPE 核准組態工具判定。

## 安裝與驗證檢查清單

- [x] `P65741-B21` 套件到貨與零件外觀記錄
- [x] 擴充板固定於主機板專用接頭
- [x] iLO Dedicated RJ45 與 DB9 Serial Port 安裝完成
- [x] Samsung SSD 990 PRO 1TB 實體安裝完成
- [x] UEFI Storage Device Information 辨識型號、容量、位置與韌體
- [x] UEFI 顯示 NVMe Slot 20：Populated／Enabled = Yes
- [ ] 依完整 SKU 複核 `P65106-B21` 是否為本機必要組件
- [ ] 啟用並測試 Dedicated iLO 管理網路、登入與回復路徑
- [ ] 啟用 Intel VROC SATA RAID 並以兩顆 SATA HDD 建 RAID 1
- [ ] 安裝 Windows Server 2025 English 至 990 PRO
- [ ] 安裝相符 VROC driver、GUI／CLI、HPE AMS 與其他 HPE 驅動
- [ ] 驗證 Windows 開機、Data Volume、事件記錄、溫度、健康狀態與長時間穩定性

## 官方資料來源

- [HPE ProLiant ML30 Gen11 QuickSpecs](https://www.hpe.com/psnow/doc/a50007008enw.html)
- [HPE ProLiant ML30 Gen11 Server User Guide：iLO-M.2-serial module option](https://support.hpe.com/hpesc/public/docDisplay?docId=sd00003390en_us&page=GUID-ECB17AD0-D417-4423-8953-388D17BBFB94.html)
- [HPE ProLiant ML30 Gen11 Server User Guide：iLO-M.2-serial module components](https://support.hpe.com/hpesc/public/docDisplay?docId=sd00003390en_us&docLocale=en_US&page=GUID-7DED8FBE-383D-4227-B481-30FCE01C26F9.html)
- [HPE ProLiant ML30 Gen11 Server User Guide：Installing the iLO-M.2-serial module](https://support.hpe.com/hpesc/public/docDisplay?docId=sd00003390en_us&docLocale=en_US&page=GUID-8BC7ACD9-F979-4D26-BEEE-F709C64C7B95.html)
- [HPE ProLiant ML30 Gen11 Maintenance and Service Guide：Rear panel components](https://support.hpe.com/hpesc/public/docDisplay?docId=sd00003470en_us&docLocale=en_US&page=GUID-B9D5EAC8-F320-4390-B34B-A27EB3572DDC.html)
- [HPE Intel VROC Gen11 OS-specific guides and downloads](https://hpe.com/support/VROC-Gen11-UG)

查證日期：2026-09-02。HPE 可能更新 QuickSpecs、地區 SKU、支援矩陣與驅動下載位置；採購或部署前應再查最新版本。

