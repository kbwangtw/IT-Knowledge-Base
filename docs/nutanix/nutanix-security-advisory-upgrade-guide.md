---
layout: default
title: "Nutanix 收到高風險安全警示：要等歲修嗎？VM 要關機嗎？"
permalink: /docs/nutanix/nutanix-security-advisory-upgrade-guide/
date: 2026-10-06
categories: [Nutanix, AOS, AHV, LCM, Security]
last_modified_at: 2026-10-06
---

# Nutanix 收到高風險安全警示：要等歲修嗎？VM 要關機嗎？

收到 Nutanix 寄來的 High／Critical 安全警示（NXSA）時，最常出現三個問題：要等歲修還是馬上更新？更新時 VM 要不要關機？沒出錯的話要花多久？

**AOS／AHV 透過 LCM 做 rolling upgrade，一次處理一台，設計上不需停機。大多數情況不必等歲修，也不必把 VM 關機。前提是叢集有 N+1 的剩餘資源，而且 VM 都能 live migrate。**

> 整理日期：2026-10-06。性質：**規劃參考，尚未在本環境實測**。依 Nutanix 公開文件與一般實務整理；時間數字是經驗值，實際會因 AOS／AHV 版本、硬體廠牌（NX、Dell XC、HPE DX、Lenovo HX）、Hypervisor（AHV 或 ESXi）與 VM 負載而不同。操作前請以 Nutanix Portal 對應版本文件為準。

## 結論先看

| 問題 | 簡答 |
| --- | --- |
| 要等歲修嗎？ | 一般不用。Critical 且已有公開利用 → 數天內處理；High 且管理網段已隔離 → 依 patch policy 排程（常見 30 天內） |
| 要找原廠嗎？ | 版本是否受影響不確定、需多段升級、非 NX 硬體、ESXi 環境、dark site、NCC 有 FAIL 時，建議開 case |
| VM 要關機嗎？ | 一般不用，VM 會自動 live migrate。無法遷移的 VM（GPU passthrough、綁 host、掛本機裝置）要事先手動關機 |
| VM 不關機會失敗或變很慢嗎？ | 條件符合就不會失敗；只會多出遷移時間。資源不足或大記憶體 VM 才可能卡住或逾時 |
| 沒出錯要多久？ | 4 節點只升 AOS + AHV：預留約 4～6 小時；加 firmware：預留一整天 |

## 1. 收到警示，先判斷要多急

### Step 1：確認是否受影響

- 看警示（NXSA 編號）列出的受影響元件與版本。
- 到 Prism 核對目前的 AOS、AHV、Prism Central、NCC、firmware 版本。
- 有些漏洞只影響某個元件（例如只有 Prism Central，或只有 BMC firmware），不一定要整套升級。

### Step 2：評估實際暴露程度

| 狀況 | 建議時程 |
| --- | --- |
| Critical，已有公開 exploit，或管理介面可從外部／大範圍內網存取 | 盡快處理（數天內），不等歲修 |
| High，管理網段已隔離 | 依公司 patch policy 排程（常見 30 天內） |
| 官方有暫時緩解措施（workaround），例如關閉服務、限制 ACL | 先做緩解，再排正式更新 |

### Step 3：什麼時候要開 Support Case

- 無法判斷目前版本是否受影響
- 版本落差大，需多段升級（先用 Upgrade Paths 工具確認）
- 硬體不是 Nutanix NX 系列，firmware 相容性需另外確認
- Hypervisor 是 ESXi，要配合 VMware 版本相容性
- dark site（無外網），需手動下載 LCM bundle
- 升級前 NCC health check 出現 FAIL 或 WARN，且不確定能否忽略

**實務建議：** Critical 等級的更新，就算自己會做，也可以先開一張 proactive case，告知預計時間與目標版本。原廠有時會先幫忙看 log 與相容性；升級當天出問題，也比較快找到人。

## 2. 更新時，VM 要不要關機？

一般不需要。AHV 環境的流程大致是：

1. **AOS 升級**：一次重開一台 CVM（Controller VM）。期間該 host 上 VM 的 I/O 會自動改走其他節點的 CVM（Autopathing），VM 不受影響。
2. **AHV 升級**：先把該 host 上的 VM live migrate 到其他 host，進入維護模式，升級並重開，再換下一台。

### 不關機的前提

| 風險點 | 說明 |
| --- | --- |
| 叢集剩餘資源不足（非 N+1） | 一台 host 離線時，其他 host 要容納全部 VM。不夠的話 VM 遷不走，升級會卡住或失敗 |
| 無法遷移的 VM | GPU passthrough、部分版本的 vGPU、設定 host affinity、掛本機 USB／CD-ROM 的 VM，要事先手動關機 |
| 大記憶體、寫入頻繁的 VM | 例如大型資料庫，live migration 可能很久，甚至逾時失敗 |
| Agent VM（防毒、備份 appliance 等） | 通常隨 host 一起關機，屬正常行為，但要先通知相關團隊 |

### 不關機會讓更新變慢嗎？

- **不會造成無法更新**，前提是上表條件都符合。
- **時間會稍微增加**：每台 host 要等 VM 遷完。一般 VM 每台約數十秒到數分鐘，大記憶體 VM 會明顯更久。
- 全部關機能省遷移時間，但等於自己製造停機，失去 rolling upgrade 的意義。只有**資源不足或有不能遷移的 VM** 時才建議關機。

## 3. 沒出錯的話，要多久？

以下是一般經驗值，**不是精確數字**，節點越多大致按比例增加：

| 項目 | 每個節點約 | 4 節點叢集參考 |
| --- | --- | --- |
| 升級前準備（NCC check、LCM inventory、pre-check） | — | 30～60 分鐘 |
| Prism Central 升級 | — | 30～60 分鐘 |
| AOS 升級（CVM 逐台重開） | 15～30 分鐘 | 1～2 小時 |
| AHV 升級（含 VM 遷移與 host 重開） | 30～60 分鐘 | 2～4 小時 |
| Firmware（BIOS、BMC、磁碟等，需進 Phoenix） | 45～90 分鐘以上 | 3～6 小時 |

**只升 AOS + AHV：4 節點建議預留半天（約 4～6 小時）；含 firmware 預留一整天。**

## 4. 建議的升級順序

1. 執行 NCC health check，確認 Data Resiliency 為 **OK**
2. 確認備份完成（重要 VM 加做 snapshot 或備份）
3. 更新 LCM framework 與 NCC
4. Prism Central
5. AOS
6. AHV（或 ESXi）
7. Firmware（依警示內容決定是否需要）

## 5. 容易忽略的盲點

- **Prism Central 與 Prism Element 版本相容性**：只升一邊可能讓管理功能異常，先查 Compatibility Matrix。
- **備份軟體相容性**：Veeam、Commvault 等對 AOS 版本有支援清單，升級前要確認。
- **監控誤報**：升級時 CVM 與 host 會重開，先暫停告警或通知 NOC。
- **ESXi 環境**：VM 遷移靠 vMotion／DRS，要確認 DRS 設定與 vCenter 版本相容。

## 待補（實際執行後填寫）

| 項目 | 狀態 |
| --- | --- |
| 本環境 AOS／AHV 版本、節點數、Hypervisor | 待填 |
| 對應警示 NXSA 編號與受影響元件 | 待填 |
| 是否開 proactive case | 待填 |
| 實際各階段耗時 | 待實測 |
| 無法遷移的 VM 清單與處理方式 | 待填 |

## 參考資源

以下部分頁面需 Nutanix Portal 帳號登入：

- [Nutanix Security Advisories](https://portal.nutanix.com/page/documents/security-advisories)
- [Upgrade Paths](https://portal.nutanix.com/page/upgradePaths)
- [Compatibility & Interoperability Matrix](https://portal.nutanix.com/page/compatibility-interoperability-matrix)
- LCM User Guide：在 Nutanix Portal 搜尋「Life Cycle Manager Guide」
