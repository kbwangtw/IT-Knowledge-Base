---
layout: default
title: "IBM X336 系統碟從 36 GB 換成 146 GB，不重灌：備份、換碟、還原、擴充分割區"
date: 2011-02-25
categories: [Hardware, IBM, Server, Backup, Blogger 舊文]
permalink: /docs/blogger/hardware/ibm-x336-scsi-disk-upgrade/
last_modified_at: 2026-10-24
---

# IBM X336 系統碟從 36 GB 換成 146 GB，不重灌：備份、換碟、還原、擴充分割區

> **一句話**：用 Backup Exec System Recovery（BESR）把整顆系統碟備份到 USB 外接硬碟，換上 146 GB 硬碟重建 RAID，用 BESR 開機光碟還原（**勾選還原 MBR**），最後用磁碟工具把剩下的未配置空間併進來。

| 項目 | 內容 |
| --- | --- |
| 適合誰看 | 舊伺服器系統碟空間不夠，想換大顆硬碟但不想重灌的人 |
| 環境 | IBM eServer xSeries 336；SCSI 熱插拔硬碟 36.4 GB → 146 GB；Windows；Symantec Backup Exec System Recovery |
| 日期 | 2011-02-25（原文發表於 Blogger，2026-10-24 改寫為新手版） |
| 結論 | ✅ 系統搬到 146 GB 硬碟並正常開機 ✅ 分割區擴大 |

> ⚠️ 換碟前確認備份檔可以讀取、大小合理。這個流程中原硬碟是唯一的退路，**還原成功前不要清除原硬碟**。

## 1. 先認識幾個名詞

| 名詞 | 白話解釋 |
| --- | --- |
| **BESR** | Symantec 的整機備份還原軟體（後來改名 Symantec System Recovery，已停售） |
| **整機映像備份** | 把整個分割區包含作業系統一起備份，還原後可直接開機 |
| **MBR** | 硬碟最前面的開機紀錄，沒有它就開不了機 |
| **未配置空間** | 硬碟上還沒分割、沒格式化的空間 |
| **PXE 開機** | 從網路開機；這台 X336 用不了一般的 WinPXE 工具 |

## 2. 整體流程

```text
① 在原系統安裝 BESR → 備份系統分割區到 USB 外接硬碟 → 檢查備份檔 → 關機
② 換上 146 GB 硬碟 → 進 RAID BIOS 建立 RAID
③ BESR 開機光碟 → 還原（勾選「還原 MBR」）→ 約 1 小時
④ 重開 → 能進 Windows → 看到 36.4 GB 分割區 + 未配置空間
⑤ 用磁碟工具（原文用 Hiren's BootCD 裡的 Acronis Disk Director）擴大分割區
```

## 3. 步驟一：備份系統

**為什麼不用網路開機工具**：原作者實測 X336 無法用 WinPXE 開機，所以改在原本的系統裡安裝 BESR 做備份。

**怎麼做**：在原系統安裝 BESR，把系統（或整顆硬碟的分割區）備份到 USB 外接硬碟。

**應該看到什麼**：備份檔大小和已用空間相近；確認無誤後再關機。

## 4. 步驟二：換硬碟並建立 RAID

**怎麼做**：換上 146 GB SCSI 硬碟，開機進 RAID BIOS 建立陣列。

## 5. 步驟三：從 BESR 光碟還原

**怎麼做**：用 BESR 開機光碟開機 → 還原我的電腦 → 選擇 USB 硬碟上的備份 → **勾選「還原 MBR」**。

**應該看到什麼**：還原約 1 小時完成。

> 原作者遇到還原時**無法調整分割區大小**，還原後仍是原本的 36.4 GB，剩下的空間另外處理。

## 6. 步驟四：開機確認

**應該看到什麼**：重開後出現 Windows 登入畫面；登入後在磁碟管理中看到兩塊：原本的 36.4 GB 分割區，以及一大塊未配置空間。

## 7. 步驟五：擴大分割區

**怎麼做**：重開機，用 Hiren's BootCD 裡的 Acronis Disk Director 把未配置空間併入系統分割區。

> 現在的 Windows Server（2008 之後）可直接在「磁碟管理」對系統分割區按「延伸磁碟區」，不一定需要第三方工具。

## 8. 常見問題

| 現象 | 怎麼辦 |
| --- | --- |
| 還原後開不了機 | 還原時沒勾「還原 MBR」 |
| 還原後只有原來的大小 | 正常（這個版本的限制），用磁碟工具或 Windows 延伸磁碟區擴大 |
| 備份軟體找不到 USB 硬碟 | 開機光碟可能缺 USB 驅動；換一個 USB 孔或改用其他外接方式 |

## 9. 延伸閱讀

- [Blogger 原文](https://kbwangtw.blogspot.com/2011/02/ibm-e336-servermirror.html)
