---
layout: default
title: "HP ML10 v2 安裝 Windows Server 2012 R2：開啟 B120i RAID 與載入驅動"
date: 2015-06-29
categories: [Hardware, HPE, Server, RAID, Windows, Blogger 舊文]
permalink: /docs/blogger/hardware/hp-ml10-v2-b120i-windows-2012r2/
last_modified_at: 2026-10-24
---

# HP ML10 v2 安裝 Windows Server 2012 R2：開啟 B120i RAID 與載入驅動

> **一句話**：先在 BIOS（F9）把 SATA 改成 **Dynamic Smart Array B120i RAID** 模式，用 SSA 光碟建好 RAID，安裝 Windows 時從隨身碟載入 **B120i 驅動**才看得到硬碟；裝好後再補 iLO、顯示卡、ACU 等驅動。

| 項目 | 內容 |
| --- | --- |
| 適合誰看 | 第一次在 HP 入門伺服器上做 RAID 並安裝 Windows 的人 |
| 環境 | HP ProLiant ML10 v2；HP Dynamic Smart Array B120i（主機板內建 RAID）；Windows Server 2012 R2；本機沒有光碟機 |
| 日期 | 2015-06-29（原文發表於 Blogger，2026-10-24 改寫為新手版） |
| 結論 | ✅ RAID 建立 ✅ Windows 安裝並補齊驅動 |

## 1. 先認識幾個名詞

| 名詞 | 白話解釋 |
| --- | --- |
| **B120i** | 主機板內建的「軟體 RAID」控制器，需要驅動程式作業系統才認得 |
| **RBSU（F9 設定）** | HP 伺服器的 BIOS 設定畫面 |
| **SSA（Smart Storage Administrator）** | HP 設定 RAID 的工具，做成開機光碟使用；舊名 ACU |
| **iLO** | 伺服器上的遠端管理晶片 |
| **iLO 通道介面驅動（CHIF）** | 讓作業系統和 iLO 溝通的驅動 |

## 2. 整體流程

```text
開機按 F9 → SATA 改成 B120i RAID 模式
  → 用 SSA 開機光碟建立 RAID（外接光碟機）
  → 下載 B120i 驅動，解壓到隨身碟
  → Windows 2012 R2 安裝時「載入驅動程式」→ 看到 RAID 磁碟 → 安裝
  → 裝好後依序裝：iLO 通道介面驅動 → iLO 管理控制器驅動 → 顯示卡 → ACU
```

## 3. 步驟一：BIOS 改成 RAID 模式

**怎麼做**：開機時按 **F9** 進入設定。

![開機畫面顯示 B120i 控制器與 F9 Setup（原作者照片）]({{ '/docs/blogger/hardware/images/ml10v2-post-b120i.jpg' | relative_url }})

依序選 **System Options** → **SATA Controller Options** → **Embedded SATA Configuration** → **Enable Dynamic HP Smart Array B120i RAID Support**。

![System Options 選單（原作者照片）]({{ '/docs/blogger/hardware/images/ml10v2-rbsu-system-options.jpg' | relative_url }})

![SATA Controller Options（原作者照片）]({{ '/docs/blogger/hardware/images/ml10v2-sata-controller-options.jpg' | relative_url }})

## 4. 步驟二：用 SSA 建立 RAID

**怎麼做**：從 HPE 官網下載 SSA 的 ISO，燒成 DVD（4.7 GB 光碟），用**外接光碟機**開機，建立 RAID（操作和舊版 ACU 相同）。

> 這台沒有內建光碟機，所以需要外接式光碟機；也可以用 iLO 的虛擬光碟掛 ISO（需授權）。

## 5. 步驟三：準備 B120i 驅動並安裝 Windows

**怎麼做**：

1. 在其他電腦下載 **HP Dynamic Smart Array B120i/B320i SATA RAID 控制器驅動程式**，解壓縮放到隨身碟。
2. 用 Windows Server 2012 R2 安裝光碟開機，同時插上隨身碟。
3. 選擇安裝位置時看不到硬碟 → 按 **載入驅動程式**，指向隨身碟的驅動資料夾。

**應該看到什麼**：載入後出現 RAID 建好的邏輯磁碟，選它繼續安裝。

## 6. 步驟四：補裝驅動程式

Windows 裝好後，到 HPE 官網下載（需登入帳號）並**依序**安裝：

| 順序 | 驅動 |
| --- | --- |
| 1 | HP ProLiant iLO 3/4 通道介面驅動程式（Windows x64） |
| 2 | HP ProLiant iLO 3/4 管理控制器驅動程式套件（Windows Server 2008/2012 x64） |
| 3 | 顯示卡驅動程式 |
| 4 | HP ProLiant Array Configuration Utility（Windows 64 位元），在 Windows 裡管理 RAID |

> 原文附的下載連結是 2015 年的 HPE 舊網址，多已失效；請到 HPE 支援網站搜尋機型「ProLiant ML10 v2」。

## 7. 常見問題

| 現象 | 怎麼辦 |
| --- | --- |
| Windows 安裝時看不到硬碟 | 沒有載入 B120i 驅動；或 BIOS 沒改成 RAID 模式 |
| 載入驅動後還是看不到 | 驅動版本要對應作業系統；確認 RAID 已經建立 |
| 裝驅動時說找不到 iLO | 先裝「通道介面驅動」再裝「管理控制器驅動」 |
| 沒有光碟機 | 用外接 USB 光碟機，或把 ISO 做成開機隨身碟 |

## 8. 延伸閱讀

- [HP ML10 Gen9：Intel RST 建 RAID 1 並安裝 Windows 2012](../hp-ml10-gen9-rst-raid-windows2012/)
- [HPE 支援中心](https://support.hpe.com/)
- [Blogger 原文](https://kbwangtw.blogspot.com/2015/06/hp-proliant-ml10-v2-windows-2012-r2.html)
