---
layout: default
title: "Lenovo SR650 的 ESXi 6.5 看不到 RAID 與硬碟狀態：安裝 LSI Provider VIB"
date: 2018-09-28
categories: [Hardware, Lenovo, VMware, RAID, Blogger 舊文]
permalink: /docs/blogger/hardware/vmware-esxi65-lsi-provider-sr650/
last_modified_at: 2026-10-24
---

# Lenovo SR650 的 ESXi 6.5 看不到 RAID 與硬碟狀態：安裝 LSI Provider VIB

> **一句話**：用 Lenovo 客製 ESXi 6.5 安裝後系統能跑，但「監控 → 硬體」看不到 RAID 卡與硬碟；從 Lenovo 官網下載驅動包，取出 `vmware-esx-provider-lsiprovider.vib`，用 SSH 以 `esxcli software vib install` 安裝並重開機，就看得到每顆硬碟的狀態。

| 項目 | 內容 |
| --- | --- |
| 適合誰看 | ESXi 主機想監看 RAID 與硬碟健康狀態的人 |
| 環境 | Lenovo ThinkSystem SR650；RAID 930-16i 4GB Flash；VMware ESXi 6.5（Lenovo 客製 ISO） |
| 日期 | 2018-09-28（原文發表於 Blogger，2026-10-24 改寫為新手版） |
| 結論 | ✅ 安裝 LSI Provider 後，ESXi 顯示控制器與所有硬碟狀態 |

## 1. 先認識幾個名詞

| 名詞 | 白話解釋 |
| --- | --- |
| **VIB** | ESXi 的軟體套件格式（驅動、外掛都是 VIB） |
| **CIM Provider（LSI Provider）** | 讓 ESXi 能讀取 RAID 卡狀態的元件 |
| **`esxcli`** | ESXi 的命令列管理工具 |
| **維護模式** | ESXi 安裝軟體或重開前的模式，先把 VM 關機或搬走 |
| **MegaRAID Storage Manager（MSM）** | 在其他電腦上管理 LSI RAID 卡的圖形工具 |

## 2. 整體流程

```text
① 確認問題：ESXi 監控 → 硬體 → 儲存區 → 沒有資料
② 從 Lenovo 官網下載 RAID 驅動包 → 解壓縮取出 lsiprovider.vib
③ ESXi 開啟 SSH → 關閉所有 Guest OS
④ 把 .vib 上傳到 ESXi（datastore）→ 移到 /tmp
⑤ esxcli software vib install → 重開機
⑥ 監控 → 硬體 → 儲存區：看到控制器與每顆硬碟 ✅
⑦（選做）在其他電腦安裝 MegaRAID Storage Manager 管理 RAID
```

## 3. 步驟一：確認問題

**看到什麼**：ESXi 網頁介面 **監控 → 硬體 → 儲存區** 顯示「沒有資料可用」，並提示 Small Footprint CIM Broker（SFCBD）沒有回報資料、可能需要安裝供應商的 CIM 提供者。

## 4. 步驟二：下載 LSI Provider

**怎麼做**：到 Lenovo 支援網站搜尋 SR650，下載 **mpt3sas／RAID 驅動包（VMware 版）**，解壓縮後找到 `vmware-esx-provider-lsiprovider.vib`。

> 原作者同時下載了 StorCLI 的 VMware 版（命令列 RAID 管理工具），但未確認是否必要。

## 5. 步驟三：開啟 SSH 並上傳檔案

**怎麼做**：

1. 在 ESXi 主機的 Console 按 **F2** → **Troubleshooting Options** → 啟用 **SSH**（或在網頁介面 主機 → 動作 → 服務 → 啟用 SSH）。
2. 關閉主機上所有 Guest OS。
3. 用 WinSCP，或網頁介面的「資料存放區瀏覽器」，把 `.vib` 上傳到 `datastore1`。
4. SSH 登入 ESXi，把檔案從 `/vmfs/volumes/datastore1` 移到 `/tmp`。

## 6. 步驟四：安裝 VIB

```text
esxcli software vib install -v /tmp/vmware-esx-provider-lsiprovider.vib --no-sig-check
```

| 片段 | 意思 |
| --- | --- |
| `software vib install` | 安裝 VIB；已裝過要升級時改成 `upgrade` |
| `-v <路徑>` | 指定 VIB 檔案的**完整路徑** |
| `--no-sig-check` | 不檢查簽章；原廠驅動通常有簽章，能不加就不加 |

**應該看到什麼**：

```text
Installation Result
   Message: The update completed successfully, but the system needs to be rebooted for the changes to be effective.
   Reboot Required: true
   VIBs Installed: LSI_bootbank_lsiprovider_500.04.V0.39-0006
```

## 7. 步驟五：重開機並確認

**怎麼做**：重新開機 ESXi。

**應該看到什麼**：**監控 → 硬體 → 儲存區** 列出 RAID 930-16i 控制器、Port，以及每顆硬碟（狀態「綠色／ONLINE」）。

## 8. （選做）用 MegaRAID Storage Manager 管理

可以在同網段的電腦（或某台 VM）安裝 MegaRAID Storage Manager 連到 ESXi，查看陣列並設定郵件通知。這部分原作者參考 vixual.net 的教學，重點：

| 重點 | 說明 |
| --- | --- |
| 找不到主機 | ESXi 要有 IP，hostname 不可是 `localhost`；必要時在用戶端 `hosts` 檔加入對應 |
| 網卡太多找不到 | 在 MSM 的 Configure Host 勾選顯示網路上所有系統 |
| 郵件通知 | ESXi 不能自己寄信，要在 MSM 裡指定 SMTP 伺服器 |

詳細畫面請看延伸閱讀中的原教學。

## 9. 常見問題

| 現象 | 怎麼辦 |
| --- | --- |
| `esxcli` 說找不到檔案 | `-v` 要用完整路徑（`/tmp/...`） |
| 安裝說簽章不符 | 確認下載的是對應版本；必要時才加 `--no-sig-check` |
| 裝完還是沒資料 | 確認已重開機；`esxcli software vib list | grep lsi` 確認有安裝 |
| 忘了關 SSH | 用完記得關閉，降低被入侵風險 |

## 10. 延伸閱讀

- [vixual.net：在 VMware ESXi 監控 LSI MegaRAID（原作者參考的教學）](http://www.vixual.net/blog/archives/60)
- [Lenovo 資料中心支援](https://datacentersupport.lenovo.com/)
- [Blogger 原文](https://kbwangtw.blogspot.com/2018/09/vm-esx-65-megaraid-driver-vmware.html)
