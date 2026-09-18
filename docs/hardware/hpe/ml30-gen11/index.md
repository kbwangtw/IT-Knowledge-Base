---
layout: default
title: "ML30 Gen11 擴充紀錄：哪些零件裝好了？哪些還要測？"
date: 2026-09-04
categories: [Hardware, HPE, ML30 Gen11]
last_modified_at: 2026-09-18
---

# ML30 Gen11 擴充紀錄：哪些零件裝好了？哪些還要測？

這台 HPE ProLiant ML30 Gen11 已裝上光碟機、P65741-B21 擴充套件與 Samsung 990 PRO 1TB，並完成 Windows Server 2025 安裝。UEFI 和 Windows 都認得到相關儲存裝置。

**本篇證明的是這台機器的實際結果，不等於 HPE 已認證該消費型 SSD，也不代表所有同型主機都能不檢查配件就照裝。**

> 紀錄日期：2026-09-04。Windows 安裝日期為 2026-09-02。照片中的序號與識別資料已遮蔽。

## 先看最後的配置

| 位置 | 裝置 | 用途與結果 |
| --- | --- | --- |
| P65741-B21 的 M.2 插槽 | Samsung SSD 990 PRO 1TB | 作業系統碟，UEFI／Windows 已辨識 |
| 內建 SATA／Intel VROC | 兩顆 1TB SATA HDD | 組成 RAID 1，作為資料碟 |
| 機殼前方 | Slimline 光碟機 | 已安裝，搭配 P65102-B21 套件 |
| 後方擴充介面 | 專用 iLO RJ45、DB9 | 已安裝介面，完整連線與長時間檢查待補 |
| 作業系統 | Windows Server 2025 Standard English | 24H2，build 26100.32230 |

OS 放 NVMe、資料放 SATA RAID 1，是本次採用的配置。RAID 1 是兩顆資料碟的鏡像安排，不是把 NVMe 也一起放進陣列。

## 1. 光碟機：買到機身，還不一定能直接裝

本次用 P65102-B21 Slimline ODD Enablement Kit 完成安裝。726536-B21 是 DVD-ROM、726537-B21 是 DVD-RW；除了光碟機本體，還要核對套件、線材與 media bay。

![已裝入機箱前方的 Slimline 光碟機](images/slim-odd-front.jpg)

![Slimline 光碟機後方線材與模組區](images/slim-odd-cabling.jpg)

照片可看到前方已裝入的光碟機與後方線材。下單前要依實際機型組態核對，不要把「有光碟機料號」當成「所有固定零件都包含」。

## 2. P65741-B21：一次補上幾個介面

這個 iLO/NIC/M.2/COM Port Kit 帶來專用 iLO 網路埠、DB9 序列埠和 M.2 插槽。本次已完成主機板與後方介面的安裝。

![P65741-B21 套件到貨開箱，包含多功能板、DB9 線材、支架與固定零件](images/p65741-kit-unboxed.jpg)

![P65741-B21 已安裝於 ML30 Gen11 主機板，M.2 插槽尚未裝入 SSD](images/p65741-installed-mainboard.jpg)

![機殼後方新增的 iLO Dedicated RJ45 與 DB9 Serial Port](images/ilo-dedicated-serial-rear.jpg)

iLO 原本就存在，並可透過 shared 網路模式使用 NIC1。新增套件是提供專用管理埠，不是安裝後才「產生 iLO」。

硬體介面裝上與專用網路驗證是兩件事：專用埠的連線、設定和管理功能還要另測。

## 3. Samsung 990 PRO：本機能辨識，不代表官方認證

![Samsung SSD 990 PRO 1TB 已安裝於 P65741-B21 的 M.2 插槽；唯一識別資訊已遮蔽](images/samsung-990-pro-installed-redacted.jpg)

本次裝入 Samsung SSD 990 PRO 1TB，UEFI 顯示：

| 項目 | 實際讀值 |
| --- | --- |
| 容量 | 1000204 MB |
| 韌體 | 5B2QJXD7 |
| 裝置位置 | Embedded NVMe M.2 Drive 1 |
| 插槽 | Slot 20 |
| Populated／Enabled | Yes／Yes |

![UEFI Storage Device Information；三顆硬碟序號已遮蔽](images/uefi-storage-device-info-redacted.jpg)

![UEFI 顯示 NVMe Slot 20 已 populated 且 enabled](images/uefi-nvme-slot-20.jpg)

這些證據支持「已安裝且可被系統辨識」，還不包含耐久度、故障回報、長時間負載或所有韌體組合的驗證。

## 4. SATA RAID 1：先把開機模式與驅動查清楚

本次兩顆 SATA HDD 透過 Intel VROC 組成 RAID 1。依當時文件與操作紀錄，規劃時需核對：

- UEFI 開機模式，以及 BIOS 的 SATA 模式；原預設為 AHCI。
- 陣列設定流程，本案不是透過 Intelligent Provisioning 自動完成。
- 作業系統所需的 VROC 驅動，不能假設 SPP 已包含全部需要的版本。
- 磁碟架與尺寸的相容配置，不混用未確認的組合。

變更儲存模式或陣列設定前，要先確認是否已有資料與備份；本文是組裝驗證紀錄，不能作為現有資料碟直接改陣列的指令。

## 5. Windows Server 2025：已完成哪一層驗證？

![Windows Server 2025 與 Device Manager 實機驗證；主機名稱已遮蔽](images/windows-server-2025-validation-redacted.jpg)

Windows Server 2025 Standard English 已安裝，裝置管理員可辨識儲存裝置與控制器。這支持基本安裝與裝置辨識結果。

若要交付正式長期運轉，仍要補查 AMS、iLO 事件、溫度、驅動與韌體搭配，以及長時間負載。不能只因桌面正常就把整台硬體驗收全部勾完。

## 6. 前方風扇／導風罩要不要加？

P65106-B21 Front PCI Fan and Baffle Kit 是否需要，取決於完整 SKU 與擴充配置。本案尚待依完整組態核對，不能直接說每台 ML30 Gen11 都必須加裝，或一律不需要。

## 交付前的核對表

| 項目 | 本紀錄狀態 |
| --- | --- |
| 光碟機與線材安裝 | 已確認 |
| P65741-B21 實體安裝 | 已確認 |
| 990 PRO 的 UEFI 辨識 | 已確認 |
| SATA RAID 1 與 Windows 裝置辨識 | 已確認 |
| Windows Server 2025 安裝 | 已確認 |
| 專用 iLO 網路完整驗證 | 待補 |
| AMS、溫度、事件與長時間負載 | 待補 |
| P65106-B21 是否必要 | 待完整 SKU 核對 |

## 官方資料來源

- [HPE ProLiant ML30 Gen11 QuickSpecs](https://www.hpe.com/psnow/doc/a50007008enw.html)
- [HPE ProLiant ML30 Gen11 Server User Guide：iLO-M.2-serial module option](https://support.hpe.com/hpesc/public/docDisplay?docId=sd00003390en_us&page=GUID-ECB17AD0-D417-4423-8953-388D17BBFB94.html)
- [HPE ProLiant ML30 Gen11 Server User Guide：iLO-M.2-serial module components](https://support.hpe.com/hpesc/public/docDisplay?docId=sd00003390en_us&docLocale=en_US&page=GUID-7DED8FBE-383D-4227-B481-30FCE01C26F9.html)
- [HPE ProLiant ML30 Gen11 Server User Guide：Installing the iLO-M.2-serial module](https://support.hpe.com/hpesc/public/docDisplay?docId=sd00003390en_us&docLocale=en_US&page=GUID-8BC7ACD9-F979-4D26-BEEE-F709C64C7B95.html)
- [HPE ProLiant ML30 Gen11 Server User Guide：Intel VROC support](https://support.hpe.com/hpesc/public/docDisplay?docId=sd00003390en_us&page=GUID-473A3C6B-AA6C-4C0C-89B1-4A3AD962BB15.html)
- [HPE Intel VROC Gen11 OS-specific guides and downloads](https://hpe.com/support/VROC-Gen11-UG)

查證日期：2026-09-04。HPE 可能更新 QuickSpecs、地區 SKU、支援矩陣與驅動下載位置；採購或部署前應再查最新版本。
