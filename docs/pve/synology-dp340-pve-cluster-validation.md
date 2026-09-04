---
layout: default
title: "Synology DP340 × PVE Cluster：備份與原機／異機還原演練計畫"
date: 2026-09-02
last_updated: 2026-09-04
categories: [PVE, Synology, Backup, Recovery, DR, Ceph]
---

<style>
.kb-hero{padding:2rem;border-radius:18px;background:linear-gradient(135deg,#15324a,#245f73);color:#fff;margin:1rem 0 1.5rem}.kb-hero h1{margin:0 0 .75rem;color:#fff;line-height:1.25}.kb-hero p{margin:.4rem 0;max-width:58rem}.kb-badges{display:flex;flex-wrap:wrap;gap:.5rem;margin-top:1rem}.kb-badge{padding:.3rem .65rem;border:1px solid rgba(255,255,255,.35);border-radius:999px;background:rgba(255,255,255,.1);font-size:.85rem}.kb-alert{border-left:5px solid #d97706;background:#fff7ed;padding:1rem 1.1rem;border-radius:8px;margin:1.25rem 0}.kb-info{border-left:5px solid #2563eb;background:#eff6ff;padding:1rem 1.1rem;border-radius:8px;margin:1.25rem 0}.kb-toc{background:#f5f7f8;border:1px solid #d8e0e5;border-radius:14px;padding:1rem 1.25rem;margin:1.5rem 0}.kb-toc ol{columns:2}.kb-grid{display:grid;grid-template-columns:repeat(3,minmax(0,1fr));gap:1rem;margin:1rem 0}.kb-card{border:1px solid #d8e0e5;border-radius:14px;padding:1rem;background:#fff}.kb-card h3{margin-top:0;color:#15324a}.test-card{border:1px solid #d8e0e5;border-radius:16px;margin:1.35rem 0;overflow:hidden}.test-head{display:flex;align-items:center;gap:.8rem;background:#15324a;color:#fff;padding:1rem 1.2rem}.test-num{display:grid;place-items:center;min-width:2.2rem;height:2.2rem;border-radius:50%;background:#fff;color:#15324a;font-weight:700}.test-body{padding:1.1rem 1.25rem}.verify-tag{display:inline-block;background:#fff3cd;color:#664d03;border:1px solid #ffecb5;border-radius:6px;padding:.25rem .5rem;font-size:.85rem;font-weight:600}.result-table{display:block;overflow-x:auto;white-space:nowrap}.kb-signoff{display:grid;grid-template-columns:repeat(3,1fr);gap:1rem;margin-top:1.5rem}.kb-signoff>div{border-bottom:1px solid #666;padding:1.2rem .25rem .25rem}.print-only{display:none}@media(max-width:760px){.kb-grid,.kb-signoff{grid-template-columns:1fr}.kb-toc ol{columns:1}.kb-hero{padding:1.35rem}.result-table{font-size:.88rem}}@media print{.site-header,.site-footer,.kb-toc{display:none!important}.wrapper{max-width:none!important}.kb-hero{background:none!important;color:#000;border:2px solid #333;padding:1rem}.kb-hero h1{color:#000}.kb-card,.test-card{break-inside:avoid}.test-head{background:#eee!important;color:#000}.print-only{display:block}.result-table{white-space:normal;font-size:9pt}}
</style>

<style>
.video-grid{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:1rem;margin:1rem 0}.video-card{border:1px solid #d8e0e5;border-radius:14px;overflow:hidden;background:#fff}.video-card h3,.video-card p{margin:.85rem 1rem}.video-frame{position:relative;padding-top:56.25%;background:#111}.video-frame iframe{position:absolute;inset:0;width:100%;height:100%;border:0}@media(max-width:760px){.video-grid{grid-template-columns:1fr}}@media print{.video-frame{display:none!important}.video-card{break-inside:avoid}}
</style>

<div class="kb-hero">
<h1>Synology DP340 × PVE Cluster<br>備份與原機／異機還原演練計畫</h1>
<p>適用於 Proxmox VE 9.2.11 三節點叢集、Ceph VM_Pool，以及 Synology DP340 ActiveProtect Manager 2.0-88101。涵蓋容器與 Guest OS 的備份、原節點還原、跨節點還原及全程錄影。</p>
<div class="kb-badges"><span class="kb-badge">PVE 9.2.11</span><span class="kb-badge">APM 2.0-88101</span><span class="kb-badge">Ceph VM_Pool</span><span class="kb-badge">Same-Node Restore</span><span class="kb-badge">Cross-Node Restore</span></div>
</div>

<div class="kb-alert"><strong>版本聲明：</strong>本文件是演練計畫，不是產品功能保證。DP340 對 PVE 9.2.11、LXC／VM、API Token、增量備份、Instant Restore、跨節點還原及還原後網路設定的實際支援方式，均需依 <strong>APM 2.0-88101、DP340 韌體及官方相容矩陣實機驗證</strong>。</div>

<nav class="kb-toc" aria-label="章節導覽"><strong>章節導覽</strong><ol>
<li><a href="#objective">目的與標準</a></li><li><a href="#environment">環境基線</a></li><li><a href="#network">網路與資料路徑</a></li><li><a href="#recording">錄影與證據</a></li><li><a href="#prepare">前置準備</a></li><li><a href="#cases">演練案例</a></li><li><a href="#signoff">結果與簽核</a></li><li><a href="#operations">維運建議</a></li>
</ol></nav>

<h2 id="objective">1. 演練目的與成功標準</h2>

本演練要證明 DP340 的備份能從指定還原點，將 PVE 容器或 Guest OS 還原回原節點，並能在來源節點不可用時還原至另一個健康節點。還原後必須完成開機、網路、應用服務與資料一致性驗證。

- 備份成功，還原點時間符合預期 RPO。
- 備份資料經 172.16.10.0/24 傳輸，Corosync、quorum 與 Ceph 維持健康。
- 原機及異機還原完成，目標使用 Ceph VM_Pool，服務與測試資料正常。
- VMID、MAC、IP、hostname、HA 與排程不和原系統衝突。
- 全程錄影，APM／PVE 工作紀錄、RPO、RTO、吞吐量及 checksum 完整。

<h2 id="environment">2. 實際環境基線</h2>

| 元件 | 實際設定 |
|---|---|
| PVE Cluster | 3 個節點：Node10、Node11、Node12；Proxmox VE 9.2.11 |
| 每節點網路 | 2 張 2.5GbE NIC |
| 系統碟 | 每節點 512 GB M.2 SSD × 1，安裝 PVE |
| Ceph 資料碟 | 每節點 2 TB M.2 SSD × 1，加入 Ceph 儲存池 |
| PVE Storage | Ceph 儲存池內的 VM_Pool，供 3 節點共同使用 |
| 備份設備 | Synology DP340 備份一體機 |
| DP340 作業／管理平台 | ActiveProtect Manager（APM）2.0-88101 |
| 保護對象 | PVE Cluster 內的 LXC 容器及虛擬機 Guest OS |
| Management / Service | 192.168.10.0/24；TL-SG108-M2（2.5G）；Node10–12 各為 2.5G，DP340 LAN 1 為 1G |
| Data / Corosync | 172.16.10.0/24；TL-SX-1008；DP340 LAN 2 為 10G，Node10–12 各為 2.5G |
| 流量控制 | 未設定 QoS、ACL 或備份速率限制 |

### 演練前補記

| 項目 | 實際值 |
|---|---|
| Node 名稱 | A：Node10　B：Node11　C：Node12 |
| Management IP | Node10：192.168.10.10　Node11：192.168.10.11　Node12：192.168.10.12 |
| Data / Corosync IP | Node10：172.16.10.10　Node11：172.16.10.11　Node12：172.16.10.12 |
| DP340 LAN 1 / LAN 2 IP | Management：192.168.10.18　Data：172.16.10.18 |
| APM build / DP340 韌體 | APM：2.0-88101　DP340 韌體：________ |
| Ceph 參考基線 | 提供截圖顯示：3 OSD Up／In、0 Down／Out；97 PG active+clean；Node10–12 的 Monitor／Manager／Metadata Server 均呈綠色 |

<div class="kb-info"><strong>Ceph 基準證據：</strong>上述狀態來自本文件更新時提供的管理畫面，只代表截圖當下。正式演練開始前仍須重新保存 <code>ceph -s</code>、<code>pvesm status</code> 與 PVE Ceph 畫面，並確認沒有 recovery、rebalance 或重大 scrub。</div>

<h2 id="network">3. 網路拓撲與資料路徑</h2>

~~~text
Management / Service：192.168.10.0/24
管理者 ── TL-SG108-M2（2.5G）
              ├── Node10：192.168.10.10（2.5G）
              ├── Node11：192.168.10.11（2.5G）
              ├── Node12：192.168.10.12（2.5G）
              └── DP340 LAN 1：192.168.10.18（1G，APM 管理）

Data / Cluster / Corosync：172.16.10.0/24
DP340 LAN 2：172.16.10.18（10G）── TL-SX-1008
                          ├── Node10：172.16.10.10（2.5G）
                          ├── Node11：172.16.10.11（2.5G）
                          └── Node12：172.16.10.12（2.5G）
                               ├── Backup / Restore Data
                               └── Cluster / Corosync

每節點：512 GB M.2（PVE OS）＋ 2 TB M.2（Ceph OSD）
三節點 Ceph ── VM_Pool ── VM / LXC
~~~

<div class="kb-grid">
<div class="kb-card"><h3>管理路徑</h3>透過 192.168.10.0/24 登入 PVE 與 APM；DP340 LAN 1 為 1G，不承載大量備份。</div>
<div class="kb-card"><h3>資料路徑</h3>DP340 LAN 2 為 10G；PVE 節點為 2.5G，單一節點上限仍由 2.5G 端限制。</div>
<div class="kb-card"><h3>共網風險</h3>Backup Data 與 Corosync 共用 172.16.10.0/24，目前無 QoS／限速，須由單一 Node、單一工作開始。</div>
</div>

<div class="kb-info"><strong>停止條件：</strong>若發生 quorum 改變、節點離線、Corosync 延遲／丟包告警、非預期 fencing／reboot、Ceph 健康惡化、VM_Pool I/O 異常或管理介面失聯，立即停止新增工作並保存證據。</div>

<h2 id="recording">4. 錄影與證據保存</h2>

| 角色 | 工作 |
|---|---|
| 演練主持人 | 宣讀案例、停止條件與時間，核准進入下一階段 |
| PVE 操作人員 | 驗證 Cluster、Ceph、VM／LXC、網路與服務 |
| DP340 操作人員 | 執行備份、選擇還原點及原機／異機還原 |
| 紀錄人員 | 全程錄影、截圖、填寫數據、保存 job ID 與 log |
| 見證／核准人 | 確認破壞性操作及結果，完成 Sign-off |

1. 錄影開頭顯示日期、演練編號、參與人員、APM build、PVE 9.2.11 及 DP340 韌體。
2. 每個案例口述案例 ID、來源工作負載、來源／目標節點、還原點、VMID 及預期結果。
3. 錄製 APM、PVE 工作進度、錯誤、Cluster／Ceph 狀態及還原後服務；不得剪去失敗或重試。
4. Token Secret、密碼、Private Key、Cookie 及完整憑證不得入鏡；必要時暫停錄影再輸入。
5. 影片、報告、log 與截圖存入受控位置並計算 SHA-256。

~~~text
YYYYMMDD_DP340-PVE_<CASE-ID>_<SOURCE>_<TARGET>_part01.mp4
YYYYMMDD_DP340-PVE_validation-report.pdf
YYYYMMDD_DP340-PVE_evidence-checksums.txt
~~~

### 已提供的演練影片

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

<div class="kb-alert"><strong>證據判讀：</strong>影片是演練佐證，仍須配合 APM／PVE job log、還原點、RPO／RTO、Corosync／Ceph 前後狀態及測試資料 checksum，才能完成 Pass／Fail 簽核。</div>

<h2 id="prepare">5. 演練前置準備</h2>

### 測試工作負載

至少選 1 台 VM 與 1 個 LXC。記錄 VMID、名稱、來源節點、CPU、RAM、磁碟、用量、MAC、IP、bridge、hostname、HA、服務 port 及 VM_Pool 位置。建立帶時間戳的測試檔案並記錄 SHA-256。

### PVE 與 Ceph 基線

~~~bash
pveversion -v
pvecm status
ha-manager status
ceph -s
pvesm status
~~~

三節點、quorum、MON／OSD、Ceph health 及 VM_Pool 容量均正常才能開始。演練不得與 Ceph recovery、rebalance、重大 scrub 或節點維護同時進行。

### DP340 串接

1. 從 Management／Service 網段連線至 DP340 LAN 1（192.168.10.18），登入 APM 2.0-88101。
2. 確認 DP340 LAN 2 為 172.16.10.18/24，且沒有非預期 default route。
3. 使用專用 PVE 帳號／API Token；Secret 只存密碼庫，不使用日常 root 帳號。
4. 新增 PVE 保護來源時使用節點的 Data／Corosync 位址：Node10（172.16.10.10）、Node11（172.16.10.11）或 Node12（172.16.10.12）。
5. 確認可探索 3 節點、測試 VM／LXC 與預期 storage。

<span class="verify-tag">需依 APM 2.0-88101 / DP340 韌體 / PVE 9.2.11 實際版本驗證</span> API 權限、Token、叢集探索、LXC／VM 支援、TLS 憑證及 storage mapping。

<h2 id="cases">6. 備份及原機／異機還原演練</h2>

<section class="test-card"><div class="test-head"><span class="test-num">01</span><strong>完整備份與共網壓力基線</strong></div><div class="test-body">

1. 錄製 PVE、Ceph、VM_Pool 與測試工作負載的前置狀態。
2. 在 APM 2.0-88101 先以單一測試對象、單一工作執行完整備份。
3. 記錄 job ID、來源節點、開始／結束時間、還原點、資料量及平均／峰值頻寬。
4. 監控 PVE 2.5G 共用介面、DP340 LAN 2、TL-SX-1008 埠、Corosync、quorum 與 Ceph。

<h4>Pass</h4>備份成功、還原點可選，Cluster／Corosync／Ceph 無新增異常，資料未誤走 Management 網段。
</div></section>

<section class="test-card"><div class="test-head"><span class="test-num">02</span><strong>增量備份與測試資料</strong></div><div class="test-body">

1. 在 VM／LXC 建立帶時間戳的測試檔案並記錄 SHA-256。
2. 執行第二次備份，記錄時間、邏輯異動量、實際傳輸量及 DP340 容量變化。
3. 確認新還原點晚於測試檔案建立時間。

<h4>Pass</h4>第二次備份成功，後續還原取得測試檔案且 checksum 相符。
<h4>注意</h4><span class="verify-tag">需依實際版本驗證</span> CBT、增量鏈、去重／壓縮及 APM 統計口徑。
</div></section>

<section class="test-card"><div class="test-head"><span class="test-num">03</span><strong>原機還原（Same-Node Restore）</strong></div><div class="test-body">

1. 錄下來源節點、VMID、MAC、IP、VM_Pool volume 及所選還原點。
2. 依核准方式關機並隔離、重新命名或刪除原測試工作負載。
3. 在 APM 選擇原機還原；若支援，優先採新 VMID 並關閉還原後自動開機。
4. 記錄提交、建立完成、可開機、OS ready 及服務可用時間。
5. 首次開機前核對 VMID、MAC、IP、bridge、hostname、HA 與開機順序。
6. 驗證 OS、網路、服務、測試檔案、SHA-256 及磁碟位於 VM_Pool。

<h4>Pass</h4>原節點還原成功，資料與服務正常，沒有重複 VMID／MAC／IP 或非預期 HA 動作。
</div></section>

<section class="test-card"><div class="test-head"><span class="test-num">04</span><strong>異機還原（Cross-Node Restore）</strong></div><div class="test-body">

1. 確認目標節點 online、quorum、Ceph 及 VM_Pool 容量正常。
2. 關機並隔離來源工作負載；未評估 HA、Ceph、fencing 前不得直接拔除節點電源。
3. 在 APM 選擇還原點、健康的異機節點、新 VMID 及 VM_Pool。
4. 完成後先核對 VMID、MAC、IP、bridge、hostname 與 HA，再啟動副本。
5. 驗證 OS、網路、服務、測試檔案及 checksum；再次檢查 Cluster 與 Ceph。

<h4>Pass</h4>工作負載在另一節點啟動並提供服務，資料完整，VM_Pool、Corosync、quorum 與 Ceph 正常。
<h4>注意</h4><span class="verify-tag">需依實際版本驗證</span> 跨節點還原、VMID／MAC、LXC／VM、storage mapping 及自動啟動行為。
</div></section>

<section class="test-card"><div class="test-head"><span class="test-num">05</span><strong>穩定性觀察與收尾</strong></div><div class="test-body">

1. 還原副本至少觀察 30 分鐘，記錄服務 health、CPU、RAM、磁碟 I/O 及應用 log。
2. 執行 read-only 測試；經核准後才做可回復的寫入／讀回驗證。
3. 確認原機與異機副本沒有重複 IP、排程、外部連線或 production automation。
4. 保存 APM／PVE job log、前後狀態、截圖、影片與 checksum。
5. 依核准結果保留、關機或清理副本；本計畫不自動刪除任何副本。

<h4>Pass</h4>服務穩定，Cluster／Ceph 回到基線，證據與副本處置完整。
</div></section>

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

### 證據索引

| 證據 | 檔名／位置 | SHA-256／Job ID |
|---|---|---|
| 全程錄影 |  |  |
| 備份演練影片 | https://youtu.be/N4TgeOz_Oz4 | YouTube ID：N4TgeOz_Oz4 |
| 還原演練影片 | https://youtu.be/6kksyT5lLUw | YouTube ID：6kksyT5lLUw |
| APM 備份紀錄 |  |  |
| APM 原機還原紀錄 |  |  |
| APM 異機還原紀錄 |  |  |
| PVE／Corosync／Ceph 前後狀態 |  |  |
| 測試資料 checksum |  |  |

| 問題／條件式通過項目 | 影響 | 改善措施 | 負責人 | 到期日 |
|---|---|---|---|---|
|  |  |  |  |  |
|  |  |  |  |  |

<div class="kb-signoff"><div>執行人／日期</div><div>系統負責人／日期</div><div>見證／核准人／日期</div></div>

<p class="print-only">演練編號：________　APM：2.0-88101　DP340 韌體：________　PVE：9.2.11</p>

<h2 id="operations">8. 演練後維運建議</h2>

<div class="kb-grid">
<div class="kb-card"><h3>錯峰</h3>Data 與 Corosync 共網且無 QoS；先維持一次一個 Node 的大型備份，再依實測調整。</div>
<div class="kb-card"><h3>定期還原</h3>至少每季輪流對 VM 與 LXC 執行原機／異機還原；重大升級後追加 smoke test。</div>
<div class="kb-card"><h3>Ceph</h3>監控 VM_Pool 容量與 OSD 健康；演練不與 recovery、rebalance 或重大 scrub 同時執行。</div>
<div class="kb-card"><h3>網路改善</h3>若 Corosync 指標惡化，評估備份限速、QoS，或新增介面／網段分離 Data 與 Corosync。</div>
<div class="kb-card"><h3>權限</h3>API Token 採專用帳號、密碼庫、來源限制及輪替；錄影不得保存 Secret。</div>
<div class="kb-card"><h3>版本</h3>每次記錄 APM build、DP340 韌體、PVE、Ceph 與交換器設定，版本改變時重查相容性。</div>
</div>

---

**目前版本基線：** ActiveProtect Manager 2.0-88101、Proxmox VE 9.2.11；DP340 韌體版本待補記。

**文件狀態：** 待完成完整備份、原機還原、異機還原及全程錄影後簽核。

**敏感資訊：** 文件、錄影與截圖不得包含 Token Secret、密碼、Private Key、Cookie、完整憑證或可重用 Session。

