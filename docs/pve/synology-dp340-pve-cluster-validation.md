---
layout: default
title: "用 DP340 備份 PVE：先把還原測試安排好"
date: 2026-09-02
last_updated: 2026-09-04
categories: [PVE, Synology, Backup, Recovery, DR, Ceph]
last_modified_at: 2026-09-18
---

# 用 DP340 備份 PVE：先把還原測試安排好

這篇是 Synology DP340 搭配三節點 PVE 的演練計畫。目的不只是看到備份完成，而是確認能還原、資料對得上，並知道需要多久。

**原紀錄的結果表尚未填完，因此本文仍是待驗收計畫，不能因為有影片就寫成全部測試通過。**

> 建立日期：2026-09-02；環境更新至 2026-09-04。當時記錄為 APM 2.0-88101、PVE 9.2.11。本案範圍是 VM；依當時紀錄未包含 LXC，後續版本支援需另外核對。

<a id="objective"></a>
## 這次要回答五個問題

1. 能不能完成第一次完整備份？
2. VM 資料改變後，下一份備份能不能保存改變？
3. 能不能還原回原節點？
4. 能不能還原到另一個節點？
5. 還原後連續觀察 30 分鐘，系統與服務是否穩定？

「30 分鐘」是計畫中的觀察長度，不是已通過結果，也不是正式的恢復時間目標。

<a id="environment"></a>
## 先記住環境限制

| 項目 | 本案配置 |
| --- | --- |
| PVE | node10／node11／node12，PVE 9.2.11 |
| 每台網路 | 兩個 2.5GbE |
| 每台系統碟 | 512GB M.2 |
| 每台 Ceph 碟 | 2TB M.2 |
| DP340 | 管理 1GbE、資料 10GbE |
| APM | 2.0-88101 |
| 管理網 | 192.168.10.0/24 |
| 資料／Corosync 網 | 172.16.10.0/24 |
| DP340 位址 | 對應網段的 .18；完整設定依現場核對 |

DP340 有 10GbE，不代表單台 PVE 備份可以跑到 10Gbps；PVE 的 2.5GbE 和其他共用資源也會影響速度。

<a id="network"></a>
## 為什麼先只測一台 VM？

本案 Corosync 和備份共用資料網，尚無 QoS、ACL 或流量限制的測試結果。若一次開很多備份，可能影響叢集通訊。

先用一台 VM、一個工作測試，觀察 quorum、Corosync、Ceph 與網路負載，再決定是否增加併發。出現節點失聯、quorum 異常、Ceph 明顯惡化或正式服務受影響時，先停止擴大測試並查原因。

<a id="prepare"></a>
## 演練前先準備

- 選一台允許測試的 VM，記下 CPU、記憶體、磁碟、bridge、VLAN、MAC、IP 與必要服務。
- 放入可辨認的測試資料，保存時間、內容與 SHA256，供還原後比較。
- 記下叢集與 Ceph 基線，確認空間、主控台、備份帳號與連線可用。
- 確認目標 VMID 尚未使用；規劃測試網路，避免同名、同 MAC、同 IP 與重複排程。
- 在已安裝的 APM 版本核對權限與實際還原選項；CBT、即時還原等行為未驗證前不列為已具備能力。
- 記錄 DP340 韌體、APM build、保留政策與測試時間，原紀錄缺的欄位要補上。

演練預設不拔電、不刪正式 VM、不覆寫原磁碟。若另有破壞性情境，需獨立安排與核准，不能混進一般還原測試。

<a id="cases"></a>
## 五個測試，分開留下結果

| 測試 | 做法 | 通過時應有的證據 |
| --- | --- | --- |
| 第一次備份 | 選指定 VM，完成一份備份 | 最終成功日誌、還原點時間、處理量 |
| 資料變更後備份 | 修改測試檔並保存新時間與 SHA256，再備份 | 新還原點與資料版本對照；不能只看進度條 |
| 原節點還原 | 還原到獨立測試 VMID，避免覆蓋 | 工作成功、可開機、資料和服務驗證 |
| 其他節點還原 | 在另一台核對儲存、網路及裝置相容性後還原 | 實際目標節點與同樣的驗證資料 |
| 穩定與收尾 | 觀察 30 分鐘，再關閉或隔離副本 | 系統／Ceph／網路狀態與收尾紀錄 |

若版本提供還原後自動開機選項，測試時先關閉，檢查副本設定再啟動。Unique MAC 不會自動解決所有靜態 IP 與應用排程衝突，也要確認 HA 不會自動拉起測試副本。

還原後不能只看桌面；要驗證備份點的測試資料、必要應用功能與外部連線。

## 時間怎麼記，才有比較意義？

先約定目標，再記實際值：

| 指標 | 本計畫的記法 |
| --- | --- |
| 還原耗時 | 還原工作開始到完成 |
| 開機恢復耗時 | 還原開始到作業系統可登入 |
| 服務恢復耗時 | 還原開始到必要服務驗收完成 |
| 還原點距離 | 模擬事故時間與所選備份點的差距 |
| RTO／RPO 達標 | 以預先約定的起算點與目標比較，另核對實際資料 |

若正式 RTO 從事故發生起算，就要把選擇備份與準備時間算進去，不能拿「還原開始」的較短值代替。

<a id="videos"></a>
## 演練影片

影片可幫助理解操作畫面；正式驗收仍要把時間碼、日誌與結果表對起來。

<div class="video-grid"><article class="video-card"><div class="video-frame"><iframe src="https://www.youtube-nocookie.com/embed/N4TgeOz_Oz4" title="Synology DP340 備份 PVE Cluster 演練影片" loading="lazy" allow="accelerometer; autoplay; clipboard-write; encrypted-media; gyroscope; picture-in-picture; web-share" allowfullscreen></iframe></div><h3>備份演練</h3><p><a href="https://youtu.be/N4TgeOz_Oz4" target="_blank" rel="noopener noreferrer">在 YouTube 開啟備份影片</a></p></article><article class="video-card"><div class="video-frame"><iframe src="https://www.youtube-nocookie.com/embed/6kksyT5lLUw" title="Synology DP340 還原 PVE Cluster 演練影片" loading="lazy" allow="accelerometer; autoplay; clipboard-write; encrypted-media; gyroscope; picture-in-picture; web-share" allowfullscreen></iframe></div><h3>還原演練</h3><p><a href="https://youtu.be/6kksyT5lLUw" target="_blank" rel="noopener noreferrer">在 YouTube 開啟還原影片</a></p></article></div>

<a id="signoff"></a>
## 結果表：留給每次演練填寫

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
| 最終通過／部分通過／未通過 | 待填，寫明理由 |

<a id="operations"></a>
## 演練後怎麼維護？

保留完整工作日誌與設定版本，定期抽樣還原；版本、網路或 storage 改動後重新檢查。測試副本要關閉、隔離或依核准範圍清除，確認正式 VM、HA、排程與網路都回到預期狀態。

[Ubuntu 從 PBS 還原的實測紀錄](https://kbwangtw.github.io/IT-Knowledge-Base/docs/pve/ubuntu-vm112-pbs-disaster-recovery/)示範了如何把「還原成功」和「完整應用驗收」分開描述。
