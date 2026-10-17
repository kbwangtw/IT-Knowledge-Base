---
layout: default
title: "Nutanix 收到高風險安全警示：要等歲修嗎？VM 要關機嗎？"
permalink: /docs/nutanix/nutanix-security-advisory-upgrade-guide/
date: 2026-10-06
categories: [Nutanix, AOS, AHV, LCM, Security]
last_modified_at: 2026-10-17
---

# Nutanix 收到高風險安全警示：要等歲修嗎？VM 要關機嗎？

> **一句話**：收到 Nutanix 高風險安全警示時，大多數情況**不必等歲修、也不必關 VM**：LCM 會一台一台輪流更新，VM 自動搬走；前提是叢集有多一台的餘裕，而且 VM 都能線上搬移。

| 項目 | 內容 |
| --- | --- |
| 適合誰看 | 第一次處理 Nutanix 安全更新、要決定時程與是否停機的人 |
| 性質 | **規劃參考，尚未在本環境實測**（2026-10-06 整理） |
| 依據 | Nutanix 公開文件與一般實務；時間是經驗值，會因版本、硬體（NX、Dell XC、HPE DX、Lenovo HX）、Hypervisor（AHV 或 ESXi）與 VM 負載而不同 |

> 操作前請以 Nutanix Portal 上對應版本的文件為準。

## 1. 先認識幾個名詞

| 名詞 | 白話解釋 |
| --- | --- |
| **NXSA** | Nutanix Security Advisory，原廠發布的安全警示編號 |
| **AOS** | Nutanix 的儲存與叢集軟體 |
| **AHV** | Nutanix 自家的虛擬化平台（Hypervisor） |
| **CVM** | Controller VM：每台主機上負責儲存的特殊虛擬機 |
| **LCM** | Life Cycle Manager：Nutanix 內建的升級工具 |
| **Rolling upgrade** | 輪流升級：一次只處理一台，其他台繼續服務，所以不用整體停機 |
| **Live migrate** | 線上搬移：VM 不關機，從一台主機搬到另一台 |
| **N+1** | 少了任何一台主機，其餘主機仍能容納全部 VM |
| **NCC** | Nutanix 的健康檢查工具 |

## 2. 結論先看

| 問題 | 簡答 |
| --- | --- |
| 要等歲修嗎？ | 一般不用。Critical 且已有公開攻擊程式 → 數天內處理；High 且管理網段已隔離 → 依 patch policy 排程（常見 30 天內） |
| 要找原廠嗎？ | 不確定版本是否受影響、需要多段升級、非 NX 硬體、ESXi 環境、無外網（dark site）、NCC 有 FAIL 時，建議開 case |
| VM 要關機嗎？ | 一般不用，VM 會自動 live migrate。無法搬移的 VM（GPU passthrough、綁定主機、掛本機裝置）要事先手動關機 |
| 不關機會失敗或變很慢嗎？ | 條件符合就不會失敗，只是多出搬移時間。資源不足或大記憶體 VM 才可能卡住或逾時 |
| 沒出錯要多久？ | 4 節點只升 AOS + AHV：預留約 4～6 小時；加上 firmware：預留一整天 |

## 3. 收到警示，先判斷有多急

### 3-1 確認自己有沒有受影響

- 看警示（NXSA 編號）列出的受影響元件與版本。
- 到 Prism 核對目前的 AOS、AHV、Prism Central、NCC、firmware 版本。
- 有些漏洞只影響某個元件（例如只有 Prism Central，或只有 BMC firmware），**不一定要整套升級**。

### 3-2 評估實際暴露程度

| 狀況 | 建議時程 |
| --- | --- |
| Critical、已有公開攻擊程式，或管理介面可從外部／大範圍內網連到 | 盡快處理（數天內），不等歲修 |
| High，管理網段已隔離 | 依公司 patch policy 排程（常見 30 天內） |
| 原廠有暫時緩解措施（例如關閉服務、限制 ACL） | 先做緩解，再排正式更新 |

### 3-3 什麼時候要開 Support Case

- 無法判斷目前版本是否受影響
- 版本落差大、需要多段升級（先用 Upgrade Paths 工具確認）
- 硬體不是 Nutanix NX 系列，firmware 相容性要另外確認
- Hypervisor 是 ESXi，要配合 VMware 版本相容性
- dark site（沒有外網），要手動下載 LCM bundle
- 升級前 NCC 出現 FAIL 或 WARN，不確定能不能忽略

> **實務建議**：Critical 等級的更新，就算自己會做，也可以先開一張 **proactive case**，告知預計時間與目標版本。原廠有時會先幫忙看 log 與相容性；升級當天出問題，也比較快找到人。

## 4. 更新時，VM 要不要關機？

一般不需要。AHV 環境的流程大致是：

```text
AOS 升級：一次重開一台 CVM
   → 期間該主機上 VM 的磁碟存取，自動改走其他主機的 CVM（Autopathing），VM 不受影響
AHV 升級：先把該主機上的 VM 線上搬到其他主機
   → 主機進入維護模式 → 升級、重開 → 換下一台
```

### 不關機的前提

| 風險點 | 說明 |
| --- | --- |
| 剩餘資源不足（不是 N+1） | 一台離線時，其他台要容納全部 VM；不夠的話 VM 搬不走，升級會卡住或失敗 |
| 無法搬移的 VM | GPU passthrough、部分版本的 vGPU、設定 host affinity、掛本機 USB／CD-ROM 的 VM，要事先手動關機 |
| 大記憶體、寫入頻繁的 VM | 例如大型資料庫，搬移可能很久，甚至逾時失敗 |
| Agent VM（防毒、備份 appliance 等） | 通常隨主機一起關機，屬正常行為，但要先通知相關團隊 |

### 不關機會讓更新變慢嗎？

- **不會造成無法更新**，前提是上表條件都符合。
- **時間會稍微增加**：每台要等 VM 搬完。一般 VM 每台約數十秒到數分鐘，大記憶體 VM 明顯更久。
- 全部關機能省下搬移時間，但等於自己製造停機，失去輪流升級的意義。只有**資源不足或有不能搬的 VM** 時才建議關機。

## 5. 沒出錯的話要多久？

一般經驗值，**不是精確數字**；節點越多大致按比例增加：

| 項目 | 每個節點約 | 4 節點參考 |
| --- | --- | --- |
| 升級前準備（NCC、LCM inventory、pre-check） | — | 30～60 分鐘 |
| Prism Central 升級 | — | 30～60 分鐘 |
| AOS 升級（CVM 逐台重開） | 15～30 分鐘 | 1～2 小時 |
| AHV 升級（含 VM 搬移與主機重開） | 30～60 分鐘 | 2～4 小時 |
| Firmware（BIOS、BMC、磁碟等，需進 Phoenix） | 45～90 分鐘以上 | 3～6 小時 |

**只升 AOS + AHV：4 節點建議預留半天（約 4～6 小時）；含 firmware 預留一整天。**

## 6. 建議的升級順序

1. 執行 NCC health check，確認 Data Resiliency 是 **OK**
2. 確認備份完成（重要 VM 另做 snapshot 或備份）
3. 更新 LCM framework 與 NCC
4. Prism Central
5. AOS
6. AHV（或 ESXi）
7. Firmware（依警示內容決定是否需要）

## 7. 容易忽略的盲點

| 盲點 | 說明 |
| --- | --- |
| Prism Central 與 Prism Element 版本相容性 | 只升一邊可能讓管理功能異常，先查 Compatibility Matrix |
| 備份軟體相容性 | Veeam、Commvault 等對 AOS 版本有支援清單 |
| 監控誤報 | 升級時 CVM 與主機會重開，先暫停告警或通知 NOC |
| ESXi 環境 | VM 搬移靠 vMotion／DRS，要確認 DRS 設定與 vCenter 版本相容 |

## 8. 待補（實際執行後填寫）

| 項目 | 狀態 |
| --- | --- |
| 本環境 AOS／AHV 版本、節點數、Hypervisor | 待填 |
| 對應警示 NXSA 編號與受影響元件 | 待填 |
| 是否開 proactive case | 待填 |
| 實際各階段耗時 | 待實測 |
| 無法搬移的 VM 清單與處理方式 | 待填 |

## 9. 延伸閱讀

部分頁面需要 Nutanix Portal 帳號：

- [Nutanix Security Advisories](https://portal.nutanix.com/page/documents/security-advisories)
- [Upgrade Paths](https://portal.nutanix.com/page/upgradePaths)
- [Compatibility & Interoperability Matrix](https://portal.nutanix.com/page/compatibility-interoperability-matrix)
- LCM User Guide：在 Nutanix Portal 搜尋「Life Cycle Manager Guide」
