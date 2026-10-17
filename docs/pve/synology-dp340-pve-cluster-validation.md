---
layout: default
title: "用 DP340 備份 PVE：先把還原測試安排好"
date: 2026-09-02
last_updated: 2026-09-04
categories: [PVE, Synology, Backup, Recovery, DR, Ceph]
last_modified_at: 2026-10-17
---

# 用 DP340 備份 PVE：先把還原測試安排好

> **一句話**：這是一份「用 Synology DP340 備份三台 PVE」的**演練計畫**：不只要看到備份完成，還要確認還原得回來、資料對得上、知道要花多久。

| 項目 | 內容 |
| --- | --- |
| 適合誰看 | 第一次規劃備份還原演練的人 |
| 環境 | PVE 9.2.11 三節點；DP340（APM 2.0-88101） |
| 範圍 | VM（依當時紀錄未包含 LXC，後續版本支援需另外核對） |
| 狀態 | ⏳ **待驗收計畫**：結果表還沒填完，有影片不代表全部測試通過 |
| 日期 | 建立 2026-09-02；環境更新至 2026-09-04 |

> 文中 IP 都是文件示範位址（管理網 192.0.2.0/24、內部網段 198.51.100.0/24），照做前請換成自己的位址。

## 1. 先認識幾個名詞

| 名詞 | 白話解釋 |
| --- | --- |
| **DP340** | Synology 的備份一體機，透過 APM（ActiveProtect Manager）管理 |
| **還原點** | 某一次備份的時間點，還原時從這裡挑 |
| **Corosync** | PVE 叢集節點之間「互相確認還活著」的通訊；斷掉會影響整個叢集 |
| **Quorum** | 叢集多數節點在線，才允許修改設定 |
| **Ceph** | 三台 PVE 共用的分散式儲存 |
| **SHA256** | 檔案的「指紋」；還原後指紋一樣，代表內容一模一樣 |
| **RTO／RPO** | 最多能中斷多久／最多能遺失多久的資料（事先約定的目標） |

## 2. 這次要回答的五個問題

1. 能不能完成第一次完整備份？
2. VM 資料改變後，下一份備份有沒有存到改變？
3. 能不能還原回**原本的節點**？
4. 能不能還原到**另一個節點**？
5. 還原後連續觀察 30 分鐘，系統與服務穩不穩定？

> 「30 分鐘」是計畫中的觀察長度，不是已通過的結果，也不是正式的 RTO。

## 3. 環境與限制

| 項目 | 配置 |
| --- | --- |
| PVE | node10／node11／node12，PVE 9.2.11 |
| 每台網路 | 兩個 2.5GbE |
| 每台系統碟 | 512GB M.2 |
| 每台 Ceph 碟 | 2TB M.2 |
| DP340 | 管理 1GbE、資料 10GbE |
| APM | 2.0-88101 |
| 管理網 | 192.0.2.0/24 |
| 資料／Corosync 網 | 198.51.100.0/24 |
| DP340 位址 | 對應網段的 .18；完整設定依現場核對 |

> DP340 有 10GbE，**不代表**單台 PVE 備份能跑到 10Gbps；PVE 只有 2.5GbE，還有其他共用資源會影響速度。

## 4. 為什麼先只測一台 VM？

本案 **Corosync 和備份共用資料網**，而且沒有 QoS、ACL 或流量限制的測試結果。一次開很多備份，可能把網路塞滿、影響叢集通訊。

**做法**：先用一台 VM、一個工作測試，同時觀察 quorum、Corosync、Ceph 和網路負載，再決定要不要增加同時備份的數量。

> ⚠️ 出現節點失聯、quorum 異常、Ceph 明顯惡化或正式服務受影響時，**先停止擴大測試**並查原因。

## 5. 演練前準備

- [ ] 選一台允許測試的 VM，記下 CPU、記憶體、磁碟、bridge、VLAN、MAC、IP 和必要服務
- [ ] 放入可辨認的測試資料，記下時間、內容與 SHA256，供還原後比對
- [ ] 記下叢集與 Ceph 的基線，確認空間、主控台、備份帳號與連線可用
- [ ] 確認目標 VMID 沒人用；規劃測試網路，避免同名、同 MAC、同 IP 和重複排程
- [ ] 在已安裝的 APM 版本核對權限與實際還原選項；CBT、即時還原等功能沒驗證前不算已具備
- [ ] 記錄 DP340 韌體、APM build、保留政策與測試時間

> 演練**預設不拔電、不刪正式 VM、不覆寫原磁碟**。有破壞性的情境要另外安排與核准，不能混進一般還原測試。

## 6. 五個測試，分開留下結果

| 測試 | 做法 | 通過時要有的證據 |
| --- | --- | --- |
| 第一次備份 | 對指定 VM 完成一份備份 | 最終成功日誌、還原點時間、處理量 |
| 資料變更後備份 | 修改測試檔、記下新時間與 SHA256，再備份 | 新還原點與資料版本對照；不能只看進度條 |
| 原節點還原 | 還原到**另一個測試用 VMID**，避免覆蓋 | 工作成功、可開機、資料與服務驗證 |
| 其他節點還原 | 核對另一台的儲存、網路、裝置相容性後還原 | 實際目標節點與同樣的驗證資料 |
| 穩定與收尾 | 觀察 30 分鐘，再關閉或隔離副本 | 系統／Ceph／網路狀態與收尾紀錄 |

- 如果版本有「還原後自動開機」選項，測試時先**關掉**，檢查副本設定後再啟動。
- Unique MAC 不會自動解決靜態 IP 和應用排程的衝突；也要確認 HA 不會自動把測試副本拉起來。
- 還原後不能只看到桌面就算數；要驗證備份點的測試資料、必要的應用功能和外部連線。

## 7. 時間怎麼記，才有比較意義

| 指標 | 記法 |
| --- | --- |
| 還原耗時 | 還原工作開始 → 完成 |
| 開機恢復耗時 | 還原開始 → 作業系統可以登入 |
| 服務恢復耗時 | 還原開始 → 必要服務驗收完成 |
| 還原點距離 | 模擬事故時間 和 所選備份點 的差距 |
| RTO／RPO 是否達標 | 用事先約定的起算點和目標比較，並核對實際資料 |

> 正式 RTO 如果從「事故發生」起算，就要把選擇備份和準備時間算進去，不能拿「還原開始」起算的較短數字代替。

## 8. 演練影片

影片幫助理解操作畫面；正式驗收仍要把時間碼、日誌和結果表對起來。

<div class="video-grid"><article class="video-card"><div class="video-frame"><iframe src="https://www.youtube-nocookie.com/embed/N4TgeOz_Oz4" title="Synology DP340 備份 PVE Cluster 演練影片" loading="lazy" allow="accelerometer; autoplay; clipboard-write; encrypted-media; gyroscope; picture-in-picture; web-share" allowfullscreen></iframe></div><h3>備份演練</h3><p><a href="https://youtu.be/N4TgeOz_Oz4" target="_blank" rel="noopener noreferrer">在 YouTube 開啟備份影片</a></p></article><article class="video-card"><div class="video-frame"><iframe src="https://www.youtube-nocookie.com/embed/6kksyT5lLUw" title="Synology DP340 還原 PVE Cluster 演練影片" loading="lazy" allow="accelerometer; autoplay; clipboard-write; encrypted-media; gyroscope; picture-in-picture; web-share" allowfullscreen></iframe></div><h3>還原演練</h3><p><a href="https://youtu.be/6kksyT5lLUw" target="_blank" rel="noopener noreferrer">在 YouTube 開啟還原影片</a></p></article></div>

## 9. 結果表（每次演練填寫）

| 項目 | 結果 | 證據／時間碼 |
| --- | --- | --- |
| 完整備份 | 待填 | 待填 |
| 變更後備份與資料對照 | 待填 | 待填 |
| 原節點還原 | 待填 | 待填 |
| 其他節點還原 | 待填 | 待填 |
| 開機、檔案、應用測試 | 待填 | 待填 |
| 30 分鐘穩定觀察 | 待填 | 待填 |
| 測試副本收尾 | 待填 | 待填 |
| RTO／RPO 目標與結果 | 待填 | 待填 |

| 紀錄欄位 | 內容 |
| --- | --- |
| 日期、執行人、覆核人 | 待填 |
| VMID、來源快照、目標節點與儲存 | 待填 |
| 備份／還原開始與結束時間 | 待填 |
| 邏輯資料量、實際傳輸量與速率 | 待填，標明單位 |
| 異常、影響與後續負責人 | 待填 |
| 最終：通過／部分通過／未通過 | 待填，寫明理由 |

## 10. 演練後怎麼維護

- 保留完整工作日誌與設定版本，定期抽樣還原。
- 版本、網路或 storage 改動後重新檢查。
- 測試副本要關閉、隔離或依核准範圍清除，確認正式 VM、HA、排程和網路都回到預期狀態。

## 11. 延伸閱讀

- [Ubuntu VM 從 PBS 還原：6 分 38 秒代表什麼？](https://kbwangtw.github.io/IT-Knowledge-Base/docs/pve/ubuntu-vm112-pbs-disaster-recovery/)：示範如何把「還原成功」和「完整應用驗收」分開描述
