---
layout: default
title: "Grafana 13.3 新版整理：這次更新了什麼、要不要升級"
date: 2026-11-02
categories: [Grafana, Release]
permalink: /docs/pve/grafana-13-3-release-notes/
last_modified_at: 2026-11-02
---

# Grafana 13.3 新版整理：這次更新了什麼、要不要升級

> **一句話**：Grafana 13.3（官方部落格標示 2026-10-29 發布）主打「變數可以跨儀表板共用」和「全新外觀」，但這兩項加上 Notebooks 都還是**公開預覽（Public Preview）**，自架版要手動開功能開關，正式環境先別急著全面啟用。

| 項目 | 內容 |
| --- | --- |
| 適合誰看 | 已經在用 Grafana（例如本站的戰情中心系列）、想知道新版值不值得升級的人 |
| 資料來源 | Grafana 官方部落格 [Grafana 13.3 release](https://grafana.com/blog/grafana-13-3-release-all-the-latest-features/)（整理自原文，**尚未在本環境實測**） |
| 日期 | 2026-11-02 整理 |
| 結論 | ✅ 已整理功能清單與開關名稱；⏳ 本環境升級與實測尚未進行（見待辦） |

## 1. 先認識幾個名詞

| 名詞 | 白話解釋 |
| --- | --- |
| **Dashboard（儀表板）** | 一頁放很多圖表的畫面，戰情中心就是一個 Dashboard |
| **Variable（變數）** | 儀表板上方的下拉選單，例如選「環境」「叢集」，圖表會跟著變 |
| **Public Preview（公開預覽）** | 功能已可用，但還在調整，內容可能改變，不建議直接用在重要環境 |
| **GA（一般可用）** | 正式版功能，可放心使用 |
| **Feature toggle（功能開關）** | 自架版用來「手動打開」預覽功能的設定項目 |
| **Grafana Assistant** | Grafana 內建的 AI 助手，可用對話建立或修改儀表板 |
| **Notebooks** | 把圖表、查詢結果與筆記放在同一份文件的功能，適合記錄調查過程 |

## 2. 這次更新一覽

| 功能 | 狀態 | 自架版功能開關 |
| --- | --- | --- |
| 跨儀表板變數 | 公開預覽 | `grafana.dashboardGlobalVariables` |
| Notebooks | 公開預覽（Cloud 逐步推出） | `dashboard.notebooks` |
| UI 視覺改版（第一階段） | 公開預覽 | `grafana.visualDesignRefresh` |
| Assistant 儀表板規劃 | 公開預覽 | 原文未提及 |
| 快速還原 Assistant 編輯（Undo turn） | **GA** | 原文未提及 |

另外，原文提到 13.3 也包含資料視覺化、Alerting（告警）與 Git Sync 的更新，但**未列出細節**，需看官方 changelog。

## 3. 各功能說明

### 3.1 跨儀表板變數（Cross-dashboard variables）

- **解決什麼問題**：以前每個儀表板都要各自建「環境」「叢集」變數，設定重複、容易不一致。現在定義一次，多個儀表板共用。
- **管理位置**：`Dashboards > Variables`
- **兩種範圍**：

| 範圍 | 誰可以用 |
| --- | --- |
| Global | 組織內所有儀表板 |
| Folder | 只有同一個資料夾內的儀表板 |

- **怎麼用**：編輯儀表板 → 側邊欄新增變數 → 選「Global or folder variable」，可一個一個或一次加入。
- **權限**：檢視者仍可切換變數的值，但變數的「設定」由中央統一管理。
- **對本站的意義**：戰情中心（Wazuh、LibreNMS、Prometheus）三張儀表板若有共用的選擇器，之後可以集中管理（推測，需實測）。

### 3.2 Notebooks

- 在一份可編輯的文件裡，整合儀表板、Explore 與 Grafana Assistant 的發現，並附上筆記。
- 可手動建立，也可請 Assistant 建立；新的 Notebooks 頁面支援搜尋、篩選、編輯與匯出。
- 常見用途：資料異常排查、記錄調查過程、事後檢討（post-incident review）。

### 3.3 UI 視覺改版（第一階段）

原文稱這是自 Grafana 7 以來最大的視覺更新，但強調「是外觀改版，不是重新設計」，操作流程與導覽不變。

| 變更 | 說明 |
| --- | --- |
| 新預設主題 | 深色／淺色都重新調色，主要按鈕改為高對比實心樣式 |
| 圓角與邊框 | 邊框更柔和，卡片、面板、抽屜更有層次 |
| 元件尺寸 | 輸入框、下拉選單、按鈕、標籤的比例更一致 |
| 字型層級 | 用字重與字級區分重點 |

- 自架版啟用 `grafana.visualDesignRefresh`，**可隨時切回舊設計**。
- 外掛：原文表示無重大變更；使用標準元件與主題 token 的外掛會自動套用新樣式，自訂樣式的外掛可自行安排遷移。

### 3.4 Assistant 儀表板規劃（Dashboard plans）

描述想監控的內容後，Assistant 先在對話中給出「規劃」（標題、分頁或列、面板、視覺化類型、變數），確認後才建置。

1. 選 **Preview**：開啟唯讀版本，可繼續對話調整
2. 滿意後選 **Build it**：產生並儲存儀表板

### 3.5 快速還原 Assistant 編輯（Undo turn）

Assistant 改完儀表板後，可用 **Undo turn** 還原；一次請求改了多個面板時可全部一起還原。此項為 GA。

## 4. 要不要升級？

```text
目前版本 → 看官方升級指南 → 先在測試環境升級
   ↓
功能開關（預設關閉）
   ├─ 想試跨儀表板變數 → grafana.dashboardGlobalVariables
   ├─ 想試新外觀       → grafana.visualDesignRefresh（可切回）
   └─ 想試 Notebooks   → dashboard.notebooks
```

| 風險／盲點 | 建議 |
| --- | --- |
| 三個主要功能都是預覽 | 正式環境保持預設關閉，先在測試環境試 |
| 原文**未列出升級注意事項**，只給官方升級指南連結 | 升級前讀升級指南與完整 changelog，不要只看部落格 |
| Assistant 相關功能需要連到 Grafana 提供的 AI 服務（推測，原文未說明資料流向） | 本站原則是資料不上雲，啟用前先確認資料流向，沒確認前不要開 |
| 升級前未備份 | 升級前備份 Grafana 的資料庫（`grafana.db`）與 `grafana.ini`，並對 PVE 上的 LXC 先做快照 |

## 常見問題

| 現象 | 怎麼辦 |
| --- | --- |
| 找不到跨儀表板變數的選項 | 自架版要先啟用 `grafana.dashboardGlobalVariables`，並重啟 Grafana（推測，未實測） |
| 新外觀不喜歡 | 關閉 `grafana.visualDesignRefresh` 即可切回舊設計 |
| Notebooks 看不到 | Cloud 是逐步推出；自架版需啟用 `dashboard.notebooks` |

## 待辦

- [ ] 確認本環境目前的 Grafana 版本與升級路徑
- [ ] 在測試環境升級到 13.3，實測三個功能開關
- [ ] 評估跨儀表板變數能否整合三張戰情中心儀表板
- [ ] 確認 Grafana Assistant 的資料流向後，再決定是否啟用
- [ ] 實測完成後，把結果補進本文結論

## 延伸閱讀

- [Grafana 13.3 官方部落格](https://grafana.com/blog/grafana-13-3-release-all-the-latest-features/)
- [What's new in Grafana（官方文件）](https://grafana.com/docs/grafana/latest/whatsnew/)
- [用 Grafana 建立戰情中心（三）：接上 Prometheus（Ceph 與 PVE）](../grafana-war-room-prometheus/)
