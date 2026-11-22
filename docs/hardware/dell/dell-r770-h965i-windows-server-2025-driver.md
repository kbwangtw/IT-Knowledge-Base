---
layout: default
title: "Dell R770 + PERC H965i：安裝 Windows Server 2025 看不到硬碟怎麼辦"
date: 2026-11-22
categories: [Hardware, Dell, PowerEdge R770, Windows Server]
permalink: /docs/hardware/dell/dell-r770-h965i-windows-server-2025-driver/
last_modified_at: 2026-11-22
---

# Dell R770 + PERC H965i：安裝 Windows Server 2025 看不到硬碟怎麼辦

> **一句話**：RAID 1 明明做好了，Windows Server 2025 安裝畫面卻是空的；原因是安裝媒體沒有 RAID 卡的 driver，用 iDRAC Virtual Media 掛一個「driver 映像檔」載入後，磁碟就出現了，再用 `diskpart` 轉成 GPT 即可安裝。

| 項目 | 內容 |
| --- | --- |
| 適合誰看 | 第一次在 Dell 伺服器上裝 Windows、遇到「找不到硬碟」的人 |
| 環境 | Dell PowerEdge R770、PERC H965i（2 顆 480G SSD 做 RAID 1）、iDRAC Virtual Media 掛載 Windows Server 2025 ISO |
| 日期 | 2026-11-22 |
| 需要準備 | 在 Dell 支援網站下載的 PERC H965i Windows driver、能執行 ImDisk 的 Windows 電腦 |
| 風險 | 低：全新空碟；但 `clean` 會清掉磁碟分割表，下指令前要確認選對磁碟 |
| 結論 | ✅ RAID 1 狀態正常（Virtual Disk Ready、約 446 GiB）<br>✅ UEFI 開機模式確認<br>✅ driver 映像檔掛載成功，Setup 認得 PERC H965i<br>✅ `diskpart` 看到 446 GB 的 DELL RAID 磁碟，並成功轉成 GPT<br>⏳ 轉成 GPT 後完成安裝，尚未回報結果（見待辦） |

## 1. 先認識幾個名詞

| 名詞 | 白話解釋 |
| --- | --- |
| **PERC H965i** | Dell 伺服器的 RAID 卡，負責把多顆硬碟組成一個「虛擬磁碟」給作業系統用 |
| **Virtual Disk（VD）** | RAID 組好後呈現的那一顆「邏輯硬碟」，Windows 看到的是它，不是後面的實體 SSD |
| **RAID 1** | 兩顆硬碟存同一份資料（鏡像），壞一顆還能運作；容量只有單顆大小（480G 的 SSD 格式化後約 446 GiB） |
| **driver（驅動程式）** | 讓作業系統認得硬體的小程式；沒有它，Windows 看不到 RAID 卡後面的磁碟 |
| **iDRAC** | Dell 伺服器的遠端管理介面，可以在瀏覽器裡看畫面、掛載 ISO |
| **Virtual Media** | iDRAC 的功能：把你電腦上的 ISO／映像檔，假裝成插在伺服器上的光碟或 USB |
| **ISO / IMG** | ISO 是光碟映像檔；IMG 是一整個磁碟區的映像檔，這篇用它來裝 driver |
| **ImDisk** | 免費 Windows 工具，可以建立虛擬磁碟並存成映像檔 |
| **UEFI / GPT** | 新式開機方式與對應的分割表格式；Windows Server 2025 安裝在 UEFI 機器上要用 GPT |
| **diskpart** | Windows 內建的磁碟管理指令工具，安裝畫面按 Shift+F10 就能用 |

## 2. 全貌

```text
Windows Server 2025 ISO ──(iDRAC Virtual Media：CD/DVD)────┐
driver 映像檔（.img）  ──(iDRAC Virtual Media：Removable)──┤
                                                            ▼
                                                R770 開機 → Windows Setup
                                                            │
        PERC H965i ── RAID 1 ── Virtual Disk（約 446 GiB）──┘
        （Setup 內建沒有 driver，所以清單是空的）
                                │
          Load driver 載入 → 磁碟出現 → diskpart 轉 GPT → 安裝
```

## 3. 步驟 1：先確認 RAID 本身沒問題

**做什麼**：排除「RAID 根本沒建好」。

**怎麼做**：開機按 **F2** 進 System Setup。

| 要看的地方 | 應該看到什麼 |
| --- | --- |
| `Device Settings` → PERC H965i → `Configuration Management` → `View Disk Group Properties` | Virtual Disk 狀態 **Ready**，RAID1，約 446 GiB，Secured：No |
| `System BIOS` → `Boot Settings` | `Boot Mode` 是 **UEFI** |

**這次看到的結果**：`Virtual Disk 1: GenericR1, RAID1, 446.625GiB, Ready`，Boot Mode 為 UEFI。到這裡可以確定 RAID 正常，問題在 driver。

## 4. 步驟 2：準備 driver 映像檔

**做什麼**：把 driver 裝進一個 200 MB 的映像檔，之後用 Virtual Media 掛給伺服器。

為什麼不直接掛第二個 ISO？因為 Virtual Media 的 **CD/DVD 位置只有一個**，已經被 Windows ISO 佔用；driver 改用「Removable Disk（抽取式磁碟）」位置掛載。

### 2-1 取得 driver

1. 用 Service Tag 到 Dell 支援網站，下載 **PERC H965i** 的 Windows driver。
2. 若是 `.exe`，執行後選擇「解壓縮」，不要直接安裝。
3. 確認資料夾裡有 `.inf`、`.sys`、`.cat`。

### 2-2 用 ImDisk 建立映像檔

1. 開啟 ImDisk，按 `Mount new...`。
2. 設定如下：

| 欄位 | 設定 | 為什麼 |
| --- | --- | --- |
| Image file | 留白 | 先建一個空白的記憶體磁碟 |
| Size of virtual disk | 200 Megabytes | 比 driver 大小多一些即可 |
| Drive letter | 任一未使用的字母 | 例如 D |
| Device type | Harddisk volume | |
| Removable media | 勾選 | 讓系統當成 USB 隨身碟 |
| Read-only media | 不勾 | 才能複製檔案進去 |

3. 按 OK，系統會要求格式化：選 **FAT32**、快速格式化。
4. 把 driver 資料夾整個複製進去。

### 2-3 存成 `.img`

1. 在 ImDisk 選取該磁碟，按 `Save image...`，檔名自訂（例如 `Drive.img`）。
2. 跳出「Select option for saving disk image」時，選第二個：**offset 0，不建立 MBR**（因為磁碟是直接格式化的，沒有分割表）。
3. 若出現 `Cannot lock the drive`，代表檔案總管正開著該磁碟；關掉視窗再存最保險，確認沒有程式在寫入的話按「確定」也可以。
4. 看到 `Successfully saved the contents of drive ... to image file` 代表完成。

**應該看到什麼**：存好的 `.img` 約 200 MB。

> ⚠️ 這個虛擬磁碟是**記憶體**做的，還沒存成 `.img` 之前不要 `Remove`，否則內容會消失。

### 2-4 驗證映像檔

1. `Remove` 原本的虛擬磁碟。
2. `Mount new...` 重新掛載 `.img`（`Virtual disk drive accesses image file directly`、勾 `Read-only media`）。
3. 打開確認 `.inf`、`.sys`、`.cat` 都在，再 `Remove`。**一定要先卸載，iDRAC 才讀得到。**

## 5. 步驟 3：在 iDRAC 掛載並開機

1. 開啟 iDRAC Virtual Console → `Virtual Media`。
2. `CD/DVD`：掛 Windows Server 2025 ISO。
3. `Removable Disk`：掛上一步的 `.img`（這次畫面顯示為「映射到可移動磁盤（只讀）」）。
4. 重開機，按 **F11** → One-shot UEFI Boot Menu → 選 **Virtual CD/DVD/ISO**。
5. 出現 `Press any key to boot from CD or DVD` 時，立刻按任意鍵。

## 6. 步驟 4：載入 driver

**做什麼**：讓 Setup 認得 PERC H965i。

**怎麼做**：在「選取要安裝 Windows Server 的位置」畫面，點 `載入驅動程式` → `瀏覽`，選到含 `.inf` 的資料夾。

**應該看到什麼**：驅動程式清單出現 `PERC H965i Front`（檔案為 `mpi3drv.inf`），選取後按「安裝」。

載入後磁碟清單會出現磁碟，但**這次出現了兩個異常**：

| 看到的 | 實際情況 |
| --- | --- |
| 「磁碟 0 磁碟分割 1」顯示 **16.0 TB**、類型「未知」，並警告「Windows Server 無法安裝在磁碟 0 磁碟分割 1 上」 | 畫面誤判；實際是 446 GB 的 RAID 磁碟（見下一步）。**原因未確認**，推測是磁碟還沒有分割表 |
| 「磁碟 1 磁碟分割 1」200.0 MB，類型「主要」 | 這是我們掛的 driver 映像檔，不是安裝目標 |

## 7. 步驟 5：用 diskpart 確認並轉成 GPT

### 7-1 確認磁碟 0 是 RAID 磁碟

按 **Shift + F10** 開命令提示字元：

```text
diskpart
list disk
select disk 0
detail disk
```

| 指令 | 意思 |
| --- | --- |
| `list disk` | 列出所有磁碟與大小 |
| `select disk 0` | 選取磁碟 0 |
| `detail disk` | 顯示型號、類型、狀態 |

**這次看到的結果**：

| 項目 | 結果 |
| --- | --- |
| `list disk` | 磁碟 0：446 GB；磁碟 1：200 MB |
| `detail disk` | 型號 `DELL RAID SCSI Disk Device`、類型 RAID、狀態連線、唯讀：否、沒有磁碟區 |

→ 確定磁碟 0 就是 PERC H965i 的 Virtual Disk。

### 7-2 轉成 GPT

> ⚠️ `clean` 會清除該磁碟的分割資訊。**執行前確認選的是 446 GB 那顆（磁碟 0）**。這次是全新空碟，沒有資料損失。

```text
select disk 0
clean
convert gpt
list disk
exit
```

| 指令 | 意思 |
| --- | --- |
| `clean` | 清除磁碟上殘留的分割資訊 |
| `convert gpt` | 轉成 GPT，UEFI 機器開機需要 |
| `list disk` | 再確認，磁碟 0 的 `Gpt` 欄位要出現 `*` |

**這次看到的結果**：「DiskPart 成功地轉換了選擇的磁碟成為 GPT 格式」，`list disk` 顯示磁碟 0 為 446 GB、可用 446 GB、`Gpt` 欄位有 `*`。

## 8. 步驟 6：回安裝畫面繼續

1. `exit` 離開 diskpart，關閉命令提示字元。
2. 在選擇安裝位置的畫面按 `重新整理`。
3. 磁碟 0 應變成約 446 GB 的未配置空間，選它按「下一步」。

安裝中：

- **不要取消掛載 ISO**，Setup 還要讀取。
- 自動重開機後**不要再按 F11**；若又出現 `Press any key to boot from CD or DVD`，**不要按**，否則會回到安裝畫面。
- 裝完後，把 iDRAC Virtual Media 都取消掛載。

## 常見問題

| 現象 | 怎麼辦 |
| --- | --- |
| 安裝畫面磁碟清單完全是空的 | 沒載入 driver；先確認 RAID 的 Virtual Disk 為 Ready，再照步驟 4 載入 |
| `載入驅動程式` 瀏覽不到 driver | 確認 iDRAC 的 Removable Disk 已掛載；資料夾要選到含 `.inf` 的那一層 |
| 磁碟顯示 16.0 TB、未知，不能安裝 | 用 `diskpart` 確認真實大小，再 `clean` + `convert gpt`（步驟 5） |
| ImDisk 存檔時 `Cannot lock the drive` | 檔案總管開著該磁碟；關掉視窗後重存 |
| iDRAC 讀不到 `.img` | 本機 ImDisk 磁碟還沒 `Remove`，檔案被占用 |
| Virtual Media 只有一個 CD/DVD 位置 | driver 改用 Removable Disk 掛載，不要再掛第二個 ISO |
| 重開機又回到安裝畫面 | 看到 `Press any key to boot from CD or DVD` 時不要按鍵 |

## 待辦

- [ ] 轉成 GPT 後完成 Windows Server 2025 安裝，確認「重新整理」後磁碟 0 可選取（**目前尚未回報結果**）
- [ ] 安裝後確認裝置管理員內 PERC H965i 無黃色驚嘆號
- [ ] 更新 iDRAC、BIOS、PERC 韌體
- [ ] 查證 Dell 是否有 Windows Server 2025 專用 driver 版本（這次載入的版本號未記錄）
- [ ] 確認 16 TB 誤判的原因（目前只是推測：磁碟尚無分割表）

## 延伸閱讀

- [Dell 支援網站（用 Service Tag 查 driver）](https://www.dell.com/support)
- [Microsoft：Windows Server 安裝說明](https://learn.microsoft.com/windows-server/get-started/install-upgrade-migrate)
- [ImDisk Toolkit](https://sourceforge.net/projects/imdisk-toolkit/)
