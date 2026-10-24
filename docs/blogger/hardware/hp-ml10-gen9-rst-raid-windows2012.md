---
layout: default
title: "HP ML10 Gen9：Intel RST 建立 RAID 1 並安裝 Windows Server 2012"
date: 2016-09-06
categories: [Hardware, HPE, Server, RAID, Windows, Blogger 舊文]
permalink: /docs/blogger/hardware/hp-ml10-gen9-rst-raid-windows2012/
last_modified_at: 2026-10-24
---

# HP ML10 Gen9：Intel RST 建立 RAID 1 並安裝 Windows Server 2012

> **一句話**：Gen9 和 v2 不一樣：開機按 **DEL** 進 BIOS，把 SATA Mode 從 AHCI 改成 **RAID**，存檔後才會出現 **Intel Rapid Storage Technology** 選單，建立 RAID 1；之後若停在 EFI Shell，重開按 **F12** 從光碟開機即可，安裝時**不用另外載入驅動**。

| 項目 | 內容 |
| --- | --- |
| 適合誰看 | ML10 Gen9 要做兩顆硬碟鏡像（RAID 1）並安裝 Windows 的人 |
| 環境 | HP ProLiant ML10 Gen9；兩顆 1 TB SATA 硬碟；Intel RST RAID；Windows Server 2012 Foundation |
| 日期 | 2016-09-06（原文發表於 Blogger，2026-10-24 改寫為新手版） |
| 結論 | ✅ RAID 1 建立 ✅ Windows 安裝時直接看得到磁碟 ⏳ 網卡驅動需另外下載 |

> ⚠️ 這篇是 **Gen9**；ML10 **v2** 的做法不同，請看〈HP ML10 v2 安裝 Windows Server 2012 R2〉。

## 1. 先認識幾個名詞

| 名詞 | 白話解釋 |
| --- | --- |
| **AHCI／RAID 模式** | SATA 控制器的工作方式；要做 RAID 必須改成 RAID 模式 |
| **Intel RST（Rapid Storage Technology）** | 主機板晶片組內建的 RAID 功能 |
| **RAID 1（Mirror）** | 兩顆硬碟存一樣的資料，壞一顆資料還在 |
| **RAID 0（Stripe）** | 兩顆合成一顆，速度快、容量大，但壞一顆全毀 |
| **EFI Shell** | UEFI 開機時找不到開機裝置會停留的文字畫面 |

## 2. 整體流程

```text
開機按 DEL → Advanced → SATA Configuration → SATA Mode：AHCI 改 RAID → 存檔重開
  → 再進 BIOS → Advanced → Intel(R) Rapid Storage Technology
  → Create RAID Volume → 選 RAID1(Mirror) → 選兩顆硬碟 → Create Volume → 存檔離開
  → （停在 EFI Shell）→ 重開按 F12 → Press any key to boot from CD → 安裝 Windows
  → 用另一台電腦下載網卡驅動 → 依序安裝驅動
```

## 3. 步驟一：SATA Mode 改成 RAID

**怎麼做**：開機看到 HPE 畫面時按 **DEL**（或 ESC）進入 BIOS。

![開機畫面：DEL 進設定、F12 網路開機（原作者照片）]({{ '/docs/blogger/hardware/images/ml10gen9-post.jpg' | relative_url }})

**Advanced** → **SATA Configuration** → **SATA Mode Selection** 從 `AHCI` 改成 `RAID`。

![SATA Mode Selection 改成 RAID（原作者照片）]({{ '/docs/blogger/hardware/images/ml10gen9-sata-mode-raid.jpg' | relative_url }})

## 4. 步驟二：建立 RAID 1

**怎麼做**：回到 Advanced 上一層，進入 **Intel(R) Rapid Storage Technology**。

> 如果看不到這個選項：先**存檔重開**再進 BIOS 就會出現。

| 畫面 | 操作 |
| --- | --- |
| Intel RST 首頁 | 選 **Create RAID Volume**（下方列出兩顆 Non-RAID 的 931.5 GB 硬碟） |
| RAID Level | 選 **RAID1(Mirror)** |
| Select Disks | 游標移到每顆硬碟按 **空白鍵**，出現 `[X]` 表示選取 |
| Create Volume | 建立；容量顯示約 953 GB |
| Save & Exit | 儲存並離開 |

## 5. 步驟三：從光碟開機安裝 Windows

**看到什麼**：建好 RAID 重開後，可能停在 **EFI Shell**（因為還沒有可開機的系統）。

![停在 EFI Shell（原作者照片）]({{ '/docs/blogger/hardware/images/ml10gen9-efi-shell.jpg' | relative_url }})

**怎麼做**：放入 Windows 2012 光碟，重開機時按 **F12**（原作者實測；畫面提示 F7 是 Boot Menu，若 F12 進入網路開機請改按 F7），出現「Press any key to boot from CD or DVD」時按任意鍵。

![Press any key to boot from CD or DVD（原作者照片）]({{ '/docs/blogger/hardware/images/ml10gen9-boot-from-dvd.jpg' | relative_url }})

**應該看到什麼**：安裝程式的「要安裝在何處」畫面**直接看得到** RAID 磁碟（約 931.5 GB 未配置空間），不需要載入驅動。

> 有網友反映 HP 附的光碟安裝時會出錯；遇到的話換一張 Windows 2012 光碟試試。原作者安裝過程沒有錯誤。

## 6. 步驟四：安裝驅動程式

網卡預設**沒有驅動**，裝好 Windows 後無法上網。先用另一台電腦到 HPE 支援網站下載 ML10 Gen9 的驅動（至少網卡），用隨身碟帶過來，依序安裝。

## 7. 常見問題

| 現象 | 怎麼辦 |
| --- | --- |
| BIOS 找不到 Intel Rapid Storage Technology | SATA Mode 改成 RAID 後要先存檔重開 |
| 選不到硬碟 | 用**空白鍵**選取，不是 Enter |
| 開機停在 EFI Shell | 正常，還沒有作業系統；重開按開機選單從光碟開機 |
| Windows 裝好不能上網 | 網卡驅動要另外安裝 |

## 8. 延伸閱讀

- [HP ML10 v2 安裝 Windows Server 2012 R2（B120i）](../hp-ml10-v2-b120i-windows-2012r2/)
- [HP ML10 用隨身碟裝 Windows 2016 出現 0x80070026](../hp-ml10-windows2016-install-wim-0x80070026/)
- [Blogger 原文](https://kbwangtw.blogspot.com/2016/09/hp-ml10-gen9-raidwin2012_1.html)
