---
layout: default
title: "HPE DL360 Gen11 + Windows Server 2019：裝置管理員的 Coprocessor 驚嘆號（Intel QAT）"
date: 2026-11-27
categories: [Hardware, HPE, ProLiant DL360 Gen11, Windows Server]
permalink: /docs/hardware/hpe/dl360-gen11-ws2019-qat-coprocessor-driver/
last_modified_at: 2026-11-27
---

# HPE DL360 Gen11 + Windows Server 2019：裝置管理員的 Coprocessor 驚嘆號（Intel QAT）

> **一句話**：HPE 驅動程式都裝完了，裝置管理員還剩一個「Coprocessor」顯示驚嘆號（Code 28）。這是 CPU 內建的 Intel QAT 加速器，不是硬體故障；到 Intel 官網下載 QAT driver（Hardware Version 2.0）安裝即可。

| 項目 | 內容 |
| --- | --- |
| 適合誰看 | 第一次在新一代 Intel 伺服器上裝 Windows，裝完 driver 還剩一個驚嘆號的人 |
| 環境 | HPE ProLiant DL360 Gen11（第 4／5 代 Intel Xeon Scalable）、Windows Server 2019 |
| 日期 | 2026-11-27 |
| 需要準備 | 能上網下載 Intel driver 的電腦、主機的系統管理員帳號 |
| 風險 | 低：只是安裝 driver；但 Intel 官網目前沒有把 Windows Server 2019 列在 HW 2.0 driver 的支援清單（見「注意事項」） |
| 結論 | ✅ 已確認驚嘆號裝置是 Intel QAT（`DEV_4942`，Intel 401xx Accelerator）<br>⏳ 到 Intel 官網下載 QAT driver 安裝，安裝結果待回報 |

## 1. 先認識幾個名詞

| 名詞 | 白話解釋 |
| --- | --- |
| **裝置管理員** | Windows 裡查看所有硬體與 driver 狀態的地方；黃色驚嘆號代表這個硬體沒有正常運作 |
| **Code 28** | 「這個裝置的 driver 沒有安裝」。Windows 認得有這個硬體，但找不到對應的 driver |
| **Coprocessor（協同處理器）** | 幫 CPU 分擔特定工作的晶片；Windows 不知道它是什麼時，就用這個通用名稱顯示 |
| **Intel QAT（QuickAssist Technology）** | Intel 內建在 CPU 裡的硬體加速器，專門做加解密與壓縮，讓 CPU 核心少做這些工作 |
| **Hardware ID** | 每種硬體的「身分證字號」，`VEN_` 是廠商、`DEV_` 是型號；拿它就能查出這是什麼硬體 |
| **HW Version 2.0** | QAT 的硬體世代；第 4／5 代 Xeon 內建的 QAT 屬於 2.0，要用 2.0 的 driver |
| **SPP／SUM** | HPE 的整包韌體與 driver 光碟（Service Pack for ProLiant）及其更新工具（Smart Update Manager） |

## 2. 全貌

```text
DL360 Gen11
  └─ 第 4／5 代 Intel Xeon
        └─ 內建 Intel QAT 加速器（PCI bus 243，DEV_4942）
                │
Windows Server 2019 安裝完 + HPE driver 裝完
                │
        Windows 沒有 QAT driver → 裝置管理員顯示「Coprocessor」⚠ Code 28
                │
        Intel 官網下載 QAT driver（HW Version 2.0）→ 安裝 → 重開機 → 驚嘆號消失
```

## 3. 步驟 1：確認驚嘆號裝置是什麼

**做什麼**：先確認這個 Coprocessor 真的是 QAT，避免裝錯 driver。

**怎麼做**：

1. 開啟裝置管理員，在「Coprocessor」上按右鍵 →「內容」。
2. `一般` 頁籤看位置與錯誤碼。
3. 切到 `詳細資料` 頁籤，「屬性」選 `Hardware Ids`。

**這次看到的結果**：

| 欄位 | 內容 |
| --- | --- |
| 裝置類型／製造商 | Other devices／Unknown |
| 位置 | PCI bus 243, device 0, function 0 |
| 裝置狀態 | The drivers for this device are not installed. (Code 28)<br>There are no compatible drivers for this device. |
| 事件（Events） | `Device PCI\VEN_8086&DEV_4942&SUBSYS_00008086&REV_01\3&9d66511&0&00 requires further installation.` |

Hardware ID 逐段說明：

| 片段 | 意思 |
| --- | --- |
| `VEN_8086` | 廠商是 Intel |
| `DEV_4942` | 型號是 Intel 401xx Accelerator，也就是第 4／5 代 Xeon 內建的 QAT |
| `REV_01` | 硬體版本 |

→ 確定是 Intel QAT，不是故障，也不是 HPE 的 driver 漏裝。

> 其他 Intel 加速器的 ID 也可能出現類似的驚嘆號（例如 `0B25` 是 DSA、`0CFE` 是 IAA、`2710` 是 DLB），**這篇只處理 QAT**。

## 4. 步驟 2：下載 QAT driver

**做什麼**：取得對應硬體世代的 driver。

**怎麼做**：

1. 到 Intel 下載中心，找「**Intel QuickAssist Technology (Intel QAT) Driver for Windows – Hardware Version 2.0**」（連結見「延伸閱讀」）。
2. 下載後，在 PowerShell 核對檔案雜湊值，確認檔案完整、沒被竄改：

```powershell
Get-FileHash .\<下載的檔名>.zip -Algorithm SHA256
```

| 片段 | 意思 |
| --- | --- |
| `Get-FileHash` | 計算檔案的雜湊值（像檔案的指紋） |
| `-Algorithm SHA256` | 用 SHA256 計算，和 Intel 下載頁公布的值比對 |

**應該看到什麼**：算出來的值和 Intel 下載頁上的 SHA256 完全一樣。

> ⚠️ 不要下載「HW Version 1.x」或「Customer Enabling (CE) Release」，那是給舊款 C62x chipset 用的，不適用 `DEV_4942`。

## 5. 步驟 3：安裝並驗證

**做什麼**：安裝 driver，確認驚嘆號消失。

**怎麼做**：

1. 把下載的檔案複製到主機上並解壓縮。
2. 以系統管理員身分執行安裝程式，安裝細節依套件內附的 Getting Started Guide 進行。
3. 重新開機。
4. 回到裝置管理員檢查。

**應該看到什麼**：Coprocessor 的驚嘆號消失，裝置改顯示在 Intel QAT 相關類別底下。

## 注意事項

| 項目 | 說明 |
| --- | --- |
| OS 支援範圍 | Intel 官網目前的 HW 2.0 driver 只列出 Windows Server 2022、2025，**沒有列出 2019**。裝在 2019 上屬於非官方驗證組合，交付前要確認裝置運作正常 |
| 先看 HPE 有沒有 | 如果 HPE 支援網站的 DL360 Gen11、Windows Server 2019 頁面有 QAT 元件，優先使用 HPE 打包的版本 |
| SUM 遠端更新抓不到 | 透過 iLO 遠端執行 SUM 只會盤點韌體，偵測不到 QAT driver；要在主機的 Windows 上執行 SUM |
| 不裝會怎樣 | 沒有應用程式使用 QAT 加速時，不影響系統運作；驚嘆號只是外觀問題 |
| 長期建議 | 客戶如果要用 SQL Server 2022 的 QAT 備份壓縮等功能，建議改用 Windows Server 2022 或 2025 |

## 常見問題

| 現象 | 怎麼辦 |
| --- | --- |
| HPE driver 全裝完了，還是剩一個 Coprocessor 驚嘆號 | 查 Hardware ID；是 `VEN_8086&DEV_4942` 就是 QAT，照步驟 2、3 安裝 |
| Intel 安裝程式拒絕安裝（OS 版本不符） | 先找 HPE 是否有 2019 版本的 QAT 元件；沒有的話，可在裝置管理員停用該裝置，或在 RBSU（BIOS）關閉 QAT，並在交付文件註明「不影響運作」 |
| 下載到 HW 1.x 或 CE Release 的 driver | 裝不上或不對應；重新下載 HW Version 2.0 |
| 用 iLO 遠端跑 SUM，清單裡沒有 QAT | 正常現象；改在主機 OS 上執行 SUM，或手動下載安裝 |
| Hardware ID 不是 `DEV_4942` | 是別的加速器（DSA、IAA、DLB 等），不要裝 QAT driver，另外查對應的 driver |

## 待辦

- [ ] 回報 Intel QAT driver 在 Windows Server 2019 上的安裝結果（版本號、是否成功、驚嘆號是否消失）
- [ ] 查證 HPE 支援網站是否有 DL360 Gen11、Windows Server 2019 專用的 QAT 元件

## 延伸閱讀

- [Intel 知識庫 000095905：Device Manager Shows Missing Drivers for Coprocessor](https://www.intel.com/content/www/us/en/support/articles/000095905.html)
- [Intel QAT Driver for Windows – Hardware Version 2.0 下載頁](https://www.intel.com/content/www/us/en/download/765502/intel-quickassist-technology-intel-qat-driver-for-windows-for-hardware-version-2-0.html)
- [HPE Advisory a00146894：iLO 遠端 SUM 不會更新 QAT driver](https://www.findbugzero.com/operational-defect-database/vendors/hpe/defects/a00146894en_us)
- [Dell R770 + PERC H965i：安裝 Windows Server 2025 看不到硬碟怎麼辦](../../dell/dell-r770-h965i-windows-server-2025-driver/)
