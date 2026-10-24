---
layout: default
title: "DL380 G7 換 RAID 卡電池改裝 1 GB Cache 後開不了機：事件紀錄與檢討"
date: 2020-07-30
categories: [Hardware, HPE, RAID, Incident, Blogger 舊文]
permalink: /docs/blogger/hardware/hpe-dl380g7-p410i-cache-upgrade-incident/
last_modified_at: 2026-10-24
---

# DL380 G7 換 RAID 卡電池改裝 1 GB Cache 後開不了機：事件紀錄與檢討

> **一句話**：P410i 電池壞了，到貨的新電池接頭不同、只能連同 1 GB Cache 一起換；換上後 RAID 控制器發現 Cache 大小和原設定不符，把邏輯磁碟停用，連換回舊件都開不了機；最後**拔掉 SAS 線、只讓控制器先認回舊 Cache，再接回硬碟**才恢復。

| 項目 | 內容 |
| --- | --- |
| 適合誰看 | 要更換 RAID 卡電池／Cache 的工程師；想了解現場維修事前確認的人 |
| 環境 | HPE ProLiant DL380 G7；Smart Array P410i，原 512 MB Cache + 電池（BBWC） |
| 日期 | 2020-07-30（原文發表於 Blogger，2026-10-24 改寫為新手版） |
| 結論 | ✅ 恢復開機（舊 Cache，電池仍故障）⚠️ 檢討：未確認料號相容與備份就更換 |

## 1. 先認識幾個名詞

| 名詞 | 白話解釋 |
| --- | --- |
| **P410i** | DL380 G7 內建的 RAID 控制器 |
| **Cache（快取記憶體）** | RAID 卡上的記憶體，加快寫入速度 |
| **BBWC（Battery-Backed Write Cache）** | 有電池保護的 Cache：突然斷電時，電池讓 Cache 資料撐到寫回硬碟 |
| **FBWC** | 用快閃記憶體與電容保護的新款 Cache，接頭與 BBWC 不同 |
| **RAID Configuration** | 陣列設定，存在硬碟上與控制器上 |
| **UID 燈** | 機器前後的藍色識別燈，用來確認是哪一台 |
| **料號（P/N、SPS、AS#）** | HPE 零件的編號；同功能不同料號可能不能互換 |

## 2. 事件經過

```text
電池故障 → 新電池接頭不同 → 連同 1 GB Cache 一起換
  → 開不了機，RAID BIOS 看不到陣列
  → 換回舊 512 MB Cache + 電池 → 仍開不了機（邏輯磁碟被停用）
  → 拔 SAS 線、只接舊 Cache 開機讓控制器認回 → 關機接回 SAS 線
  → 開機看得到原 RAID，進入作業系統 ✅
```

## 3. 更換前的標準動作（這次有做）

| 順序 | 動作 |
| --- | --- |
| 1 | 客戶以正常程序關閉作業系統 |
| 2 | 開啟 UID 燈，確認後方是哪一台，拔除網路線 |
| 3 | 確認前面板 LED 為恆亮橘燈，等 30 秒後拔電源線 |
| 4 | 拆上蓋與 PCI 擴充卡 |
| 5 | 比對新舊 Cache 與電池料號 |

## 4. 出問題的地方

**發現**：新舊料號不同，**新舊電池接頭大小也不同**；新電池只能搭配新的 1 GB Cache。

**做了什麼**：在**沒有確認** 512 MB 升級成 1 GB 是否有影響的情況下，就把新的 1 GB Cache 與電池裝上。

**結果**：無法進入作業系統；進 RAID BIOS 看不到任何陣列。換回舊的 512 MB Cache 與電池後，仍然開不了機，控制器顯示：

![P410i 顯示 Unsupported Array Configuration，邏輯磁碟已停用（原作者照片）]({{ '/docs/blogger/hardware/images/dl380g7-p410i-unsupported-config.jpg' | relative_url }})

![Invalid drive movement 警告（原作者照片）]({{ '/docs/blogger/hardware/images/dl380g7-p410i-invalid-drive-movement.jpg' | relative_url }})

## 5. 諮詢過程

| 對象 | 回覆 |
| --- | --- |
| 料件供應商 | 料件正常、可裝在 DL380 G7；建議客戶啟動備份還原或備機，認為「應該是無解」 |
| 原廠代理商工程師 | 1 GB Cache 與電池是 DL380 G7 的相容選購件；錯誤訊息顯示是 Cache 大小或磁碟與原設定不同，控制器因此停用邏輯磁碟。建議拔硬碟後測試新件（看控制器訊息旁的進度是否轉動），再拿另一組 512 MB 做交叉測試 |
| 系統整合商工程師 | 推測原設定記錄的 Cache 是 512 MB，裝上 1 GB 後不符，所以停用邏輯磁碟，這是正常保護行為 |

> 為了避免更大的資料損失，代理商建議的兩種測試**沒有執行**。

## 6. 最後的救回步驟

**做什麼**：先讓控制器「單獨」認回原本的 Cache，再讓它看到硬碟。

| 順序 | 動作 | 看到的結果 |
| --- | --- | --- |
| 1 | 關機、拔電源線 | |
| 2 | 裝回原本的 512 MB Cache 與電池 | |
| 3 | **從主機板拔掉 SAS 線**（控制器看不到硬碟） | |
| 4 | 送電開機 | 控制器偵測到 512 MB Cache，並顯示電池故障 |
| 5 | 正常離開 RAID 控制器畫面，關機斷電 | |
| 6 | 把 SAS 線接回原位，送電開機 | 控制器偵測到**原本的 RAID 設定**（與電池故障訊息） |
| 7 | 正常離開 RAID BIOS | 進入作業系統 ✅ |

## 7. 缺失檢討

| 缺失 | 以後怎麼做 |
| --- | --- |
| 新舊料號不同，未確認就安裝 | 料號不同先查相容性與升級影響，確認後再動手 |
| 更換前沒確認客戶有沒有備份 | 動 RAID 相關零件前，**一定先確認系統與資料備份** |
| 沒告知客戶風險 | 事前說明可能的風險 |
| 責任歸屬 | 新品規格與舊品不同時一律不換；客戶堅持更換，先簽署資料遺失免責切結 |
| 經驗判斷錯誤 | 以往電池壞只換電池即可；這次因接頭不同必須連 Cache 一起換，屬不同情況 |

> 原作者當時的理解：RAID 設定存在硬碟與控制器上，理論上換 Cache 只會提升效能、不影響資料；這次的經驗顯示控制器會因 Cache 大小改變而停用邏輯磁碟（推測，未經原廠正式確認）。

## 8. 料號紀錄

| 零件 | 料號 |
| --- | --- |
| 原 512 MB Cache | P/N & AS# 013224-002；SPS 462975-001 |
| 原電池 | P/N 460499-001；SPS 462976-001；AS# 013277-001 |
| 到貨品 | HP Smart Array Controller Battery（With 1GB Cache）P/N 587324-001（571436-002） |
| 1 GB Cache | SP 505908-001；AS# 570501-002 |
| 新電池 | P/N 571436-002 |

## 9. 常見問題

| 現象 | 怎麼辦 |
| --- | --- |
| 換 Cache 後看不到陣列 | **不要**在 RAID 工具裡重建陣列（會清掉資料）；先裝回原件，照第 6 節讓控制器先認 Cache 再接硬碟 |
| 新電池接頭插不上 | 新舊世代不同，需整組更換；先確認相容與備份 |
| 只換電池 | 同料號的電池通常可以直接換，風險較低 |

## 10. 待辦

- [ ] 電池仍為故障狀態：找到同料號 512 MB 電池後再排程更換

## 11. 延伸閱讀

- [HPE：Smart Array 電池更換說明（c02912639）](https://support.hpe.com/hpesc/public/docDisplay?docId=c02912639&docLocale=zh_TW)
- [HPE 社群：BBWC 與 FBWC 的差異](https://community.hpe.com/t5/proliant-servers-ml-dl-sl/difference-between-bbwc-and-fbwc/td-p/4667799)
- [Server Fault：P410i 加大 Cache 的討論](https://serverfault.com/questions/427670/hp-p410i-array-controller-what-happens-if-i-add-memory)
- [Blogger 原文](https://kbwangtw.blogspot.com/2020/07/hpe-dl380-gen7-p410i-512m-cache-upgrade.html)
