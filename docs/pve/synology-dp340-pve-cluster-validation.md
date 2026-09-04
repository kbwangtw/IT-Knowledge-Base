---
layout: default
title: "Synology DP340 × PVE Cluster：備份與原機／異機還原演練計畫"
date: 2026-09-02
last_updated: 2026-09-04
categories: [PVE, Synology, Backup, Recovery, DR, Ceph]
---

<style>
.kb-hero{padding:2rem;border-radius:18px;background:linear-gradient(135deg,#15324a,#245f73);color:#fff;margin:1rem 0 1.5rem}.kb-hero h1{margin:0 0 .75rem;color:#fff;line-height:1.25}.kb-hero p{margin:.4rem 0;max-width:58rem}.kb-badges{display:flex;flex-wrap:wrap;gap:.5rem;margin-top:1rem}.kb-badge{padding:.3rem .65rem;border:1px solid rgba(255,255,255,.35);border-radius:999px;background:rgba(255,255,255,.1);font-size:.85rem}.kb-alert{border-left:5px solid #d97706;background:#fff7ed;padding:1rem 1.1rem;border-radius:8px;margin:1.25rem 0}.kb-info{border-left:5px solid #2563eb;background:#eff6ff;padding:1rem 1.1rem;border-radius:8px;margin:1.25rem 0}.kb-toc{background:#f5f7f8;border:1px solid #d8e0e5;border-radius:14px;padding:1rem 1.25rem;margin:1.5rem 0}.kb-toc ol{columns:2}.kb-grid{display:grid;grid-template-columns:repeat(3,minmax(0,1fr));gap:1rem;margin:1rem 0}.kb-card{border:1px solid #d8e0e5;border-radius:14px;padding:1rem;background:#fff}.kb-card h3{margin-top:0;color:#15324a}.test-card{border:1px solid #d8e0e5;border-radius:16px;margin:1.35rem 0;overflow:hidden}.test-head{display:flex;align-items:center;gap:.8rem;background:#15324a;color:#fff;padding:1rem 1.2rem}.test-num{display:grid;place-items:center;min-width:2.2rem;height:2.2rem;border-radius:50%;background:#fff;color:#15324a;font-weight:700}.test-body{padding:1.1rem 1.25rem}.verify-tag{display:inline-block;background:#fff3cd;color:#664d03;border:1px solid #ffecb5;border-radius:6px;padding:.25rem .5rem;font-size:.85rem;font-weight:600}.result-table{display:block;overflow-x:auto;white-space:nowrap}.kb-signoff{display:grid;grid-template-columns:repeat(3,1fr);gap:1rem;margin-top:1.5rem}.kb-signoff>div{border-bottom:1px solid #666;padding:1.2rem .25rem .25rem}.video-grid{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:1rem;margin:1rem 0}.video-card{border:1px solid #d8e0e5;border-radius:14px;overflow:hidden;background:#fff}.video-card h3,.video-card p{margin:.85rem 1rem}.video-frame{position:relative;padding-top:56.25%;background:#111}.video-frame iframe{position:absolute;inset:0;width:100%;height:100%;border:0}.print-only{display:none}@media(max-width:760px){.kb-grid,.kb-signoff{grid-template-columns:1fr}.kb-toc ol{columns:1}.kb-hero{padding:1.35rem}.result-table{font-size:.88rem}.video-grid{grid-template-columns:1fr}}@media print{.site-header,.site-footer,.kb-toc,.video-frame{display:none!important}.wrapper{max-width:none!important}.kb-hero{background:none!important;color:#000;border:2px solid #333;padding:1rem}.kb-hero h1{color:#000}.kb-card,.test-card,.video-card{break-inside:avoid}.test-head{background:#eee!important;color:#000}.print-only{display:block}.result-table{white-space:normal;font-size:9pt}}
</style>

<div class="kb-hero">
<h1>Synology DP340 × PVE Cluster<br>備份與原機／異機還原演練計畫</h1>
<p>適用於 Proxmox VE 9.2.11 三節點叢集、Ceph VM_Pool，以及 Synology DP340 ActiveProtect Manager 2.0-88101。本文聚焦於 <strong>PVE 虛擬機（VM）</strong>的備份、原節點還原、跨節點還原與災難復原驗證。</p>
<div class="kb-badges"><span class="kb-badge">PVE 9.2.11</span><span class="kb-badge">APM 2.0-88101</span><span class="kb-badge">Ceph VM_Pool</span><span class="kb-badge">VM Backup</span><span class="kb-badge">Same-Node Restore</span><span class="kb-badge">Cross-Node Restore</span></div>
</div>

<div class="kb-alert"><strong>重要限制（截至 2026-09-04）：</strong>Synology ActiveProtect Manager（APM）2.0 支援 Proxmox VE 虛擬機（VM）備份與還原，但<strong>目前不支援 Proxmox VE LXC Container 備份</strong>。本文件所有 DP340 備份與還原演練均以 <strong>VM</strong> 為測試對象。LXC 請另行使用 Proxmox Backup Server（PBS）、<code>vzdump</code> 或其他相容方案保護。後續版本支援狀態請以 Synology 官方規格為準。</div>

<div class="kb-alert"><strong>版本聲明：</strong>本文件是驗證計畫，不是產品功能保證。API Token、增量備份、Instant Restore、跨節點還原、storage mapping、還原後自動開機及網路設定等行為，仍須依實際 APM、DP340 韌體、PVE 版本與 Synology 官方相容矩陣驗證。</div>

<nav class="kb-toc" aria-label="章節導覽"><strong>章節導覽</strong><ol>
<li><a href="#objective">目的與成功標準</a></li><li><a href="#environment">環境基線</a></li><li><a href="#network">網路與資料路徑</a></li><li><a href="#prepare">前置準備</a></li><li><a href="#cases">演練案例</a></li><li><a href="#videos">演練影片</a></li><li><a href="#signoff">結果與簽核</a></li><li><a href="#operations">維運建議</a></li>
</ol></nav>

<h2 id="objective">1. 演練目的與成功標準</h2>

本演練用來驗證 DP340 是否能從指定還原點，將 PVE 虛擬機（VM）還原至原節點，並在來源節點不可用時還原至另一個健康節點。還原後必須完成 VM 開機、網路、應用服務與資料一致性驗證。

- 備份成功，還原點時間符合預期 RPO。
- 備份資料走指定 Data 網段，並確認 Corosync、quorum 與 Ceph 維持健康。
- 原機及異機還原完成，目標 storage 為 Ceph VM_Pool，VM 服務與測試資料正常。
- VMID、MAC、IP、hostname、HA 與排程不與既有系統衝突。
- 保存 APM／PVE 工作紀錄、RPO、RTO、吞吐量、截圖、影片與 checksum。

<h2 id="environment">2. 實際環境基線</h2>

| 元件 | 實際設定 |
|---|---|
| PVE Cluster | 3 個節點：Node10、Node11、Node12；Proxmox VE 9.2.11 |
| 每節點網路 | 2 張 2.5GbE NIC |
| 系統碟 | 每節點 512 GB M.2 SSD × 1，安裝 PVE |
| Ceph 資料碟 | 每節點 2 TB M.2 SSD × 1，加入 Ceph 儲存池 |
| PVE Storage | Ceph 儲存池內的 VM_Pool，供 3 節點共同使用 |
| 備份設備 | Synology DP340 |
| 管理平台 | ActiveProtect Manager（APM）2.0-88101 |
| APM 2.0 Proxmox 保護對象 | **PVE 虛擬機（VM）**；截至 2026-09-04 不支援 LXC Container 備份 |
| Management / Service | 192.168.10.0/24；DP340 管理介面使用此網段 |
| Data / Corosync | 172.16.10.0/24；DP340 10G Data 介面與 PVE Data／Corosync 共網 |
| 流量控制 | 目前未設定 QoS、ACL 或備份速率限制 |

<div class="kb-info"><strong>Ceph 基準：</strong>正式演練前須重新保存 <code>ceph -s</code>、<code>pvesm status</code> 與 PVE Ceph 畫面，並確認沒有 recovery、rebalance 或重大 scrub。</div>

<h2 id="network">3. 網路拓撲與資料路徑</h2>

~~~text
Management / Service：192.168.10.0/24
管理者 ── TL-SG108-M2（2.5G）
              ├── Node10：192.168.10.10（2.5G）
              ├── Node11：192.168.10.11（2.5G）
              ├── Node12：192.168.10.12（2.5G）
              └── DP340 Management：192.168.10.18（1G）

Data / Cluster / Corosync：172.16.10.0/24
DP340 Data：172.16.10.18（10G）── TL-SX-1008
                          ├── Node10：172.16.10.10（2.5G）
                          ├── Node11：172.16.10.11（2.5G）
                          └── Node12：172.16.10.12（2.5G）
                               ├── Backup / Restore Data
                               └── Cluster / Corosync

三節點 Ceph ── VM_Pool ── VM
~~~

<div class="kb-grid">
<div class="kb-card"><h3>管理路徑</h3>192.168.10.0/24 用於 PVE／APM 管理，不承載大量備份。</div>
<div class="kb-card"><h3>資料路徑</h3>DP340 Data 介面為 10G，但單一 PVE 節點為 2.5G，因此單節點吞吐上限仍受 PVE 端限制。</div>
<div class="kb-card"><h3>共網風險</h3>Backup Data 與 Corosync 共用 172.16.10.0/24，應先以單一 Node、單一備份工作驗證，再逐步增加負載。</div>
</div>

<div class="kb-alert"><strong>停止條件：</strong>如發生 quorum 改變、節點離線、Corosync 延遲／丟包、非預期 fencing／reboot、Ceph 健康惡化、VM_Pool I/O 異常或管理介面失聯，立即停止新增備份／還原工作並保存證據。</div>

<h2 id="prepare">4. 演練前置準備</h2>

### 4.1 測試工作負載

至少選 2 台測試 VM，建議 Windows／Linux 各 1 台。記錄 VMID、名稱、來源節點、CPU、RAM、磁碟、實際使用量、MAC、IP、bridge、hostname、HA、服務 port 與 VM_Pool 位置，並建立帶時間戳的測試檔案與 SHA-256。

> **LXC 不列入本次 DP340／APM 2.0 測試。** 截至 2026-09-04，APM 2.0 不支援 Proxmox VE LXC Container 備份；LXC 請另以 PBS、vzdump 或其他相容備份機制建立獨立 SOP 與還原演練。

### 4.2 PVE 與 Ceph 基線

~~~bash
pveversion -v
pvecm status
ha-manager status
ceph -s
pvesm status
~~~

三節點、quorum、MON／OSD、Ceph health 與 VM_Pool 容量均正常才能開始。演練不得與 Ceph recovery、rebalance、重大 scrub 或節點維護同時進行。

### 4.3 DP340 串接

1. 從 Management／Service 網段登入 DP340 APM。
2. 確認 DP340 Data 介面為 172.16.10.18/24，且路由設定符合預期。
3. 使用專用 PVE 帳號／API Token；Secret 僅存密碼庫，不使用日常 root 帳號。
4. 新增 PVE 保護來源時，優先使用 PVE 節點的 Data 網段位址。
5. 確認 APM 可探索 3 個節點、測試 VM 與預期 storage。
6. APM 2.0 的 Proxmox VE 保護對象以 VM 為主；LXC Container 不列入備份工作。

<span class="verify-tag">需依實際版本驗證</span> API 權限、Token、TLS、叢集探索、VM 支援與 storage mapping。

<h2 id="cases">5. 備份及原機／異機還原演練</h2>

<section class="test-card"><div class="test-head"><span class="test-num">01</span><strong>完整備份與共網壓力基線</strong></div><div class="test-body">

1. 錄製 PVE、Ceph、VM_Pool 與測試 VM 前置狀態。
2. 在 APM 先以單一 VM、單一工作執行完整備份。
3. 記錄 job ID、來源節點、開始／結束時間、還原點、資料量與平均／峰值頻寬。
4. 監控 PVE Data 介面、DP340 Data 介面、交換器埠、Corosync、quorum 與 Ceph。

<h4>Pass</h4>備份成功、還原點可選，Cluster／Corosync／Ceph 無新增異常，且大量備份流量未誤走 Management 網段。
</div></section>

<section class="test-card"><div class="test-head"><span class="test-num">02</span><strong>增量備份與測試資料</strong></div><div class="test-body">

1. 在測試 VM 建立帶時間戳的檔案並記錄 SHA-256。
2. 再次執行備份，記錄時間、邏輯異動量、實際傳輸量與 DP340 容量變化。
3. 確認新還原點晚於測試檔案建立時間。

<h4>Pass</h4>第二次備份成功，後續還原可取得測試檔案且 checksum 相符。
<h4>注意</h4><span class="verify-tag">需依實際版本驗證</span> CBT、增量鏈、去重／壓縮與 APM 統計口徑。
</div></section>

<section class="test-card"><div class="test-head"><span class="test-num">03</span><strong>原機還原（Same-Node Restore）</strong></div><div class="test-body">

1. 記錄來源節點、VMID、MAC、IP、VM_Pool volume 與所選還原點。
2. 依核准流程關機並隔離、重新命名或刪除原測試 VM。
3. 在 APM 執行原機還原；若產品支援，優先採新 VMID 並關閉還原後自動開機。
4. 記錄提交、VM 建立完成、可開機、OS Ready 與服務可用時間。
5. 首次開機前核對 VMID、MAC、IP、bridge、hostname、HA 與開機順序。
6. 驗證 OS、網路、服務、測試檔案、SHA-256 與磁碟所在 storage。

<h4>Pass</h4>原節點還原成功，資料與服務正常，沒有重複 VMID／MAC／IP 或非預期 HA 動作。
</div></section>

<section class="test-card"><div class="test-head"><span class="test-num">04</span><strong>異機還原（Cross-Node Restore）</strong></div><div class="test-body">

1. 確認目標節點 online、quorum、Ceph 與 VM_Pool 容量正常。
2. 關機並隔離來源 VM；未評估 HA、Ceph 與 fencing 前，不建議直接拔除實體節點電源。
3. 在 APM 選擇還原點、健康節點、新 VMID 與 VM_Pool。
4. 還原完成後先核對 VMID、MAC、IP、bridge、hostname 與 HA，再啟動 VM。
5. 驗證 OS、網路、服務、測試檔案與 checksum，並再次檢查 Cluster 與 Ceph。

<h4>Pass</h4>VM 在另一節點啟動並提供服務，資料完整，VM_Pool、Corosync、quorum 與 Ceph 維持正常。
<h4>注意</h4><span class="verify-tag">需依實際版本驗證</span> 跨節點還原、VMID／MAC、storage mapping 與自動開機行為。
</div></section>

<section class="test-card"><div class="test-head"><span class="test-num">05</span><strong>穩定性觀察與收尾</strong></div><div class="test-body">

1. 還原 VM 至少觀察 30 分鐘，記錄服務 health、CPU、RAM、磁碟 I/O 與應用 log。
2. 執行 read-only 測試；經核准後才做可回復的寫入／讀回驗證。
3. 確認原 VM 與還原 VM 沒有重複 IP、排程、外部連線或 production automation。
4. 保存 APM／PVE job log、前後狀態、截圖、影片與 checksum。
5. 依核准結果保留、關機或清理還原 VM。

<h4>Pass</h4>服務穩定，Cluster／Ceph 回到基線，證據與副本處置完整。
</div></section>

<h2 id="videos">6. 已提供的演練影片</h2>

<div class="video-grid">
<article class="video-card">
<div class="video-frame"><iframe src="https://www.youtube-nocookie.com/embed/N4TgeOz_Oz4" title="Synology DP340 備份 PVE Cluster 演練影片" loading="lazy" allow="accelerometer; autoplay; clipboard-write; encrypted-media; gyroscope; picture-in-picture; web-share" allowfullscreen></iframe></div>
<h3>備份演練</h3>
<p><a href="https://youtu.be/N4TgeOz_Oz4" target="_blank" rel="noopener noreferrer">在 YouTube 開啟備份影片</a></p>
</article>
<article class="video-card">
<div class="video-frame"><iframe src="https://www.youtube-nocookie.com/embed/6kksyT5lLUw" title="Synology DP340 還原 PVE Cluster 演練影片" loading="lazy" allow="accelerometer; autoplay; clipboard-write; encrypted-media; gyroscope; picture-in-picture; web-share" allowfullscreen></iframe></div>
<h3>還原演練</h3>
<p><a href="https://youtu.be/6kksyT5lLUw" target="_blank" rel="noopener noreferrer">在 YouTube 開啟還原影片</a></p>
</article>
</div>

<div class="kb-info"><strong>證據判讀：</strong>影片僅是演練佐證，正式 Pass／Fail 仍須配合 APM／PVE job log、還原點、RPO／RTO、Corosync／Ceph 前後狀態與測試資料 checksum。</div>

<h2 id="signoff">7. 結果與 Sign-off</h2>

<div class="result-table">

| ID | 項目 | 預期結果 | 實際結果／證據 | 數據 | 判定 |
|---|---|---|---|---|---|
| 01 | 完整備份／共網壓力 | 還原點可用；Corosync／Ceph 穩定 | ______ | ___ GB；___ min；峰值 ___ Gbps | ☐ Pass ☐ Fail |
| 02 | 增量備份 | 新還原點與測試資料可辨識 | ______ | 異動 ___ GB；傳輸 ___ GB；___ min | ☐ Pass ☐ Fail |
| 03 | 原機還原 | 原節點、VM_Pool、服務、checksum 正常 | ______ | RPO ___；Boot RTO ___；Service RTO ___ | ☐ Pass ☐ Fail |
| 04 | 異機還原 | 異節點、VM_Pool、服務、checksum 正常 | ______ | RPO ___；Boot RTO ___；Service RTO ___ | ☐ Pass ☐ Fail |
| 05 | 穩定性／收尾 | 觀察正常；證據與副本處置完整 | ______ | 觀察 ___ min；影片 SHA-256 ______ | ☐ Pass ☐ Fail |

</div>

<div class="kb-signoff"><div>執行人／日期</div><div>系統負責人／日期</div><div>見證／核准人／日期</div></div>

<h2 id="operations">8. 演練後維運建議</h2>

<div class="kb-grid">
<div class="kb-card"><h3>離峰備份</h3>Data 與 Corosync 共網且無 QoS；大型備份建議安排於離峰時段，先維持一次一個 Node，再依實測結果調整排程與同時工作數。</div>
<div class="kb-card"><h3>VM 定期還原</h3>至少每季輪流對受 DP340 保護的 VM 執行原機／異機還原；重大升級後追加 smoke test。</div>
<div class="kb-card"><h3>LXC 另行保護</h3>截至目前 APM 2.0 不支援 Proxmox VE LXC Container 備份，請以 PBS、vzdump 或其他方案建立獨立保留政策與還原演練。</div>
<div class="kb-card"><h3>Ceph</h3>監控 VM_Pool 容量與 OSD 健康；演練不與 recovery、rebalance 或重大 scrub 同時執行。</div>
<div class="kb-card"><h3>網路改善</h3>若 Corosync 指標惡化，評估備份限速、QoS，或新增介面／網段分離 Data 與 Corosync。</div>
<div class="kb-card"><h3>版本與權限</h3>API Token 採專用帳號、密碼庫與輪替；每次記錄 APM、DP340 韌體、PVE、Ceph 與交換器設定。</div>
</div>

---

**目前版本基線：** ActiveProtect Manager 2.0-88101、Proxmox VE 9.2.11；DP340 韌體版本待補記。

**重要限制（截至 2026-09-04）：** APM 2.0 的 Proxmox VE 備份目前不支援 LXC Container；LXC 備份與還原需另行規劃。後續版本請以 Synology 官方規格為準。

**文件狀態：** 待完成完整備份、原機還原、異機還原與證據留存後簽核。

**敏感資訊：** 文件、錄影與截圖不得包含 Token Secret、密碼、Private Key、Cookie、完整憑證或可重用 Session。
