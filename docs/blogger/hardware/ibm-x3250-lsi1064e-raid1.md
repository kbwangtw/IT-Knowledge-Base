---
layout: default
title: "IBM X3250 在 uEFI 裡用 LSI 1064e 建立 RAID 1（Mirror）"
date: 2011-08-11
categories: [Hardware, IBM, Server, RAID, Blogger 舊文]
permalink: /docs/blogger/hardware/ibm-x3250-lsi1064e-raid1/
last_modified_at: 2026-10-24
---

# IBM X3250 在 uEFI 裡用 LSI 1064e 建立 RAID 1（Mirror）

> **一句話**：開機按 **F1** 進 uEFI → System Settings → Adapters and UEFI Drivers → 選 LSI 裝置 → SAS1064e → RAID Properties → **Create IM Volume**，用**空白鍵**把兩顆硬碟的 RAID Disk 改成 Yes，按 **C** 建立並存檔。

| 項目 | 內容 |
| --- | --- |
| 適合誰看 | 要在 IBM（現 Lenovo）System x 入門伺服器上做兩顆硬碟鏡像的人 |
| 環境 | IBM System x3250；LSI SAS1064e 內建 RAID；兩顆 250 GB SATA 全新硬碟 |
| 日期 | 2011-08-11（原文發表於 Blogger，2026-10-24 改寫為新手版） |
| 結論 | ✅ RAID 1 建立，狀態 Optimal |

## 1. 先認識幾個名詞

| 名詞 | 白話解釋 |
| --- | --- |
| **uEFI（F1 Setup）** | IBM 伺服器的設定畫面，取代傳統 BIOS |
| **LSI SAS1064e** | 主機板內建的 RAID 晶片 |
| **IM Volume（Integrated Mirror）** | 兩顆硬碟做鏡像，也就是 RAID 1 |
| **IME Volume** | 3～8 顆硬碟的進階鏡像，可加熱備援 |
| **IS Volume（Integrated Striping）** | RAID 0：速度快、沒有備援 |
| **Optimal** | 陣列狀態正常 |

## 2. 整體流程

```text
F1 → System Settings → Adapters and UEFI Drivers → Enter（重新整理）
  → LSI Logic Fusion MPT SAS Driver 底下的裝置 → SAS1064e → RAID Properties
  → Create IM Volume → 第一顆 RAID Disk 改 Yes → 選 D（清除資料）
  → 第二顆 RAID Disk 改 Yes → 按 C 建立 → Save changes then exit this menu
  → 等候建立 → RAID Properties 查看狀態 → 離開並重開
```

## 3. 步驟一：進入 LSI 設定

**怎麼做**：開機時按 **F1** 進入 uEFI，依序選：

| 畫面 | 選擇 |
| --- | --- |
| System Configuration and Boot Management | **System Settings** |
| System Settings | **Adapters and UEFI Drivers** |
| Adapters and UEFI Drivers | 看到「Please press ENTER to refresh this page」→ 按 **Enter** |
| Available Adapters and Drivers | 移到 **LSI Logic Fusion MPT SAS Driver** 底下的裝置 |
| LSI Logic MPT Setup Utility | 選 **SAS1064e** 按 Enter |
| Adapter Properties | 選 **RAID Properties** |

![uEFI 的 System Settings（原作者照片）]({{ '/docs/blogger/hardware/images/x3250-uefi-system-settings.jpg' | relative_url }})

## 4. 步驟二：建立 IM Volume

**怎麼做**：選 **Create IM Volume**（只做兩顆鏡像）。

![選擇 Create IM Volume（原作者照片）]({{ '/docs/blogger/hardware/images/x3250-lsi-create-im-volume.jpg' | relative_url }})

**選第一顆硬碟**：游標移到第一顆硬碟 **RAID Disk** 欄位的 `[No]`，按**空白鍵**改成 `[Yes]`。

系統會問要保留還是刪除原本的資料：

| 按鍵 | 意思 |
| --- | --- |
| **M** | 保留現有資料，轉成鏡像（會進行同步） |
| **D** | 清除陣列中所有硬碟的資料，建立新的鏡像 |

![保留（M）或清除（D）資料的選擇（原作者照片）]({{ '/docs/blogger/hardware/images/x3250-lsi-keep-or-delete.jpg' | relative_url }})

> 原作者是全新硬碟，所以選 **D**。**硬碟上有資料時請選 M**，否則資料會被清掉。

**選第二顆硬碟**：同樣把第二顆的 `[No]` 用空白鍵改成 `[Yes]`。

![兩顆硬碟的 RAID Disk 都改成 Yes（原作者照片）]({{ '/docs/blogger/hardware/images/x3250-lsi-raid-disk-yes.jpg' | relative_url }})

## 5. 步驟三：建立並存檔

**怎麼做**：兩顆都是 Yes 後按 **C**（Create array），選 **Save changes then exit this menu**。

**應該看到什麼**：出現「Processing...may take up to 1 minute / Creating RAID Array...」。

## 6. 步驟四：確認狀態

**怎麼做**：回到 Adapter Properties，再選一次 **RAID Properties**。

**應該看到什麼**：陣列類型 IM，Status 為 **Optimal**，兩顆硬碟分別是 Primary 與 Secondary。

![RAID 狀態 Optimal（原作者照片）]({{ '/docs/blogger/hardware/images/x3250-lsi-status-optimal.jpg' | relative_url }})

## 7. 步驟五：離開

**怎麼做**：一路按 Esc 離開，選 **Exit the Configuration Utility and Restart**；出現「The action required is 'Stop Controller'」時按 **Enter（YES）**。

## 8. 常見問題

| 現象 | 怎麼辦 |
| --- | --- |
| Adapters 清單是空的 | 先按 Enter 重新整理頁面 |
| 按 Enter 改不了 No／Yes | 要用**空白鍵** |
| 不小心選了 D，資料不見了 | 無法復原；有資料的硬碟一定要選 M，並事先備份 |
| 狀態是 Resyncing | 正在同步，完成後會變 Optimal |

## 9. 延伸閱讀

- [IBM X346 ServeRAID 錯誤碼 2807：換卡後接受新的電池](../ibm-serveraid-error-2807/)
- [Blogger 原文](https://kbwangtw.blogspot.com/2011/08/f1-uefi-system-setting-adapters-and.html)
