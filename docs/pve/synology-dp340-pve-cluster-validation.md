---
layout: default
title: "Synology DP340 備份還原 PVE Cluster：SOP 驗證計畫"
date: 2026-09-02
categories: [PVE, Synology, Backup, DR]
---

<style>
.kb-hero{padding:2rem;border-radius:18px;background:linear-gradient(135deg,#15324a,#245f73);color:#fff;margin:1rem 0 1.5rem}.kb-hero h1{margin:0 0 .75rem;color:#fff;line-height:1.25}.kb-hero p{margin:.4rem 0;max-width:55rem}.kb-badges{display:flex;flex-wrap:wrap;gap:.5rem;margin-top:1rem}.kb-badge{display:inline-block;padding:.3rem .65rem;border:1px solid rgba(255,255,255,.35);border-radius:999px;background:rgba(255,255,255,.1);font-size:.85rem}.kb-alert{border-left:5px solid #d97706;background:#fff7ed;padding:1rem 1.1rem;border-radius:8px;margin:1.25rem 0}.kb-alert strong{color:#9a3412}.kb-toc{background:#f5f7f8;border:1px solid #d8e0e5;border-radius:14px;padding:1rem 1.25rem;margin:1.5rem 0}.kb-toc ol{columns:2;column-gap:2rem;margin-bottom:0}.kb-grid{display:grid;grid-template-columns:repeat(3,minmax(0,1fr));gap:1rem;margin:1rem 0}.kb-card{border:1px solid #d8e0e5;border-radius:14px;padding:1rem;background:#fff;box-shadow:0 2px 8px rgba(21,50,74,.06)}.kb-card h3{margin-top:0;color:#15324a}.kb-flow{display:grid;grid-template-columns:repeat(3,minmax(0,1fr));gap:.8rem;margin:1rem 0}.kb-flow>div{padding:1rem;border-radius:12px;background:#eef5f7;border-top:4px solid #245f73}.test-card{border:1px solid #d8e0e5;border-radius:16px;margin:1.25rem 0;overflow:hidden}.test-head{display:flex;align-items:center;gap:.8rem;background:#15324a;color:#fff;padding:1rem 1.2rem}.test-num{display:grid;place-items:center;min-width:2.2rem;height:2.2rem;border-radius:50%;background:#fff;color:#15324a;font-weight:700}.test-body{padding:1.1rem 1.25rem}.test-body h4{margin-bottom:.35rem}.verify-tag{display:inline-block;background:#fff3cd;color:#664d03;border:1px solid #ffecb5;border-radius:6px;padding:.25rem .5rem;font-size:.85rem;font-weight:600}.result-table{display:block;overflow-x:auto;white-space:nowrap}.checkline{letter-spacing:.08em}.kb-signoff{display:grid;grid-template-columns:repeat(3,1fr);gap:1rem;margin-top:1.5rem}.kb-signoff>div{border-bottom:1px solid #666;padding:1.2rem .25rem .25rem}.print-only{display:none}@media(max-width:760px){.kb-grid,.kb-flow,.kb-signoff{grid-template-columns:1fr}.kb-toc ol{columns:1}.kb-hero{padding:1.35rem}.test-head{align-items:flex-start}.result-table{font-size:.88rem}}@media print{.site-header,.site-footer,.kb-toc{display:none!important}.wrapper{max-width:none!important}.kb-hero{background:none!important;color:#000;border:2px solid #333;padding:1rem}.kb-hero h1{color:#000}.kb-card,.test-card{box-shadow:none;break-inside:avoid}.test-head{background:#eee!important;color:#000}.print-only{display:block}a{color:#000;text-decoration:none}.result-table{white-space:normal;font-size:9pt}h2{break-after:avoid}}
</style>

<div class="kb-hero">
  <h1>Synology DP340 備份還原 PVE Cluster<br>SOP 驗證計畫</h1>
  <p>適用於 3-Node Proxmox VE Cluster；每個 Node 配置 2 張 2.5GbE，其中 Service／Management 獨立，Backup Data 與 Corosync 共用另一張介面。</p>
  <div class="kb-badges"><span class="kb-badge">Backup & Recovery</span><span class="kb-badge">Network Isolation</span><span class="kb-badge">HA / DR Drill</span><span class="kb-badge">Ransomware Readiness</span></div>
</div>

<div class="kb-alert"><strong>文件定位：</strong>本頁是上線前驗證計畫，不是產品功能保證。畫面名稱、支援的 Proxmox VE 版本、API 權限、CBT／去重、Instant Restore 傳輸協定、背景回遷、不可變備份與管理員刪除限制，均需依 <strong>Synology ActiveProtect / Proxmox VE 實際版本驗證</strong>，並以當版官方文件與實機 PoC 為準。</div>

<nav class="kb-toc" aria-label="章節導覽">
<strong>章節導覽</strong>
<ol>
  <li><a href="#scope">驗證範圍與準入條件</a></li>
  <li><a href="#network">雙介面拓撲與邏輯分流</a></li>
  <li><a href="#prepare">前置準備與串接 SOP</a></li>
  <li><a href="#tests">五個驗證測試案例</a></li>
  <li><a href="#signoff">Sign-off 驗證結果</a></li>
  <li><a href="#operations">長期維運與容量管理</a></li>
</ol>
</nav>

<h2 id="scope">1. 驗證範圍與準入條件</h2>

本計畫驗證「Service／Management 使用獨立 2.5GbE，Backup Data 與 Corosync 共用另一張 2.5GbE」的設計，並量測共享介面壅塞時的叢集穩定性、備份、增量、還原與防勒索控制。執行破壞性測試前，須取得變更核准並確認測試 VM 可刪除／可中斷。

| 準入檢查 | 通過條件 |
|---|---|
| PVE Cluster | 3 節點 online、`pvecm status` 顯示 quorate、無既存 Corosync 告警 |
| 儲存與網路 | 目標 storage 健康；兩張 2.5GbE 的 VLAN／路由／ACL、共享介面的 QoS 與速率限制已記錄 |
| DP340 / APM | 韌體、APM 版本、授權與 Proxmox VE 相容性已確認 |
| 回復點 | 3 台測試 VM 均已標記；含 Windows／Linux，且無正式服務依賴 |
| 安全與稽核 | Token Secret 不進入文件；已啟用時間同步、工作與系統日誌 |
| 回復方案 | 刪除／關機演練具有回復步驟、停止條件、聯絡人與維護窗口 |

<h2 id="network">2. 雙 2.5GbE 拓撲與 Data／Corosync 邏輯分流</h2>

<div class="kb-alert"><strong>架構重點：</strong>PVE Node 的第二張網卡雖接到 10G 交換器，但網卡本身只有 2.5GbE，因此單一 Node 的實際線速上限仍約為 2.5Gbps，且 Backup Data 與 Corosync 會競爭同一條實體連線。此架構沒有 Data／Corosync 的實體隔離，必須用 VLAN、QoS、備份速率限制與錯峰排程保護叢集心跳。</div>

<div class="kb-flow">
  <div><strong>NIC 1 — Service / Management</strong><br>PVE 2.5GbE 接 2.5G 交換器；承載 VM Service、PVE 管理與一般維運流量。</div>
  <div><strong>NIC 2 — Backup Data</strong><br>PVE 2.5GbE 接 10G 交換器；以 Data VLAN／IP 連接 DP340。Node 端上限仍為 2.5Gbps。</div>
  <div><strong>NIC 2 — Corosync</strong><br>與 Backup Data 共用實體介面及上行，但使用獨立 VLAN／子網；需以 QoS 優先保障心跳。</div>
</div>

```text
每個 PVE Node
  ├─ NIC 1：2.5GbE ── 2.5G Switch ── Service / Management VLAN
  └─ NIC 2：2.5GbE ── 10G Switch
                         ├─ Backup Data VLAN ── DP340 10G 介面
                         └─ Corosync VLAN ───── PVE Cluster 心跳

注意：交換器側是 10G，不會把 PVE 的 2.5GbE NIC 變成 10Gbps。
Data 與 Corosync 雖使用不同 VLAN，仍共用同一張 NIC 與 2.5Gbps 頻寬。
```

<div class="kb-grid">
  <div class="kb-card"><h3>VLAN 與路由</h3>Data 與 Corosync 使用不同 VLAN／子網；NIC 2 不設定非預期 default route。以路由表、VLAN tag 與實際連線來源驗證。</div>
  <div class="kb-card"><h3>QoS 與限速</h3>在交換器與可用的主機／備份端設定 Corosync 高優先級；備份先以低於 2.5Gbps 的保守上限測試，再逐步提高。</div>
  <div class="kb-card"><h3>Corosync 基線</h3>備份前後比對 latency、retransmit、packet loss 與 quorum；發生節點不穩或仲裁異常立即停止並降低備份並行度／頻寬。</div>
</div>

> 「備份走 Data VLAN」須以介面流量、VLAN、連線來源／目的位址與路由紀錄共同證明；僅在 APM 輸入 Data IP 不足以作為證據。VLAN 可分隔廣播域與政策，但無法消除共用 NIC 的頻寬競爭。

<h2 id="prepare">3. 前置準備與串接 SOP</h2>

### 3.1 建立 PVE API Token 最小權限

1. 在 PVE Web UI 進入 **Datacenter → Permissions → Roles**。
2. 建立專用角色，例如 `DP340-Backup-Role`；以當版整合文件所列權限為基準。初始候選權限可包含 `VM.Backup`、`VM.Audit`、`Datastore.Audit`／`Datacenter.Audit`、`Sys.Audit`，但名稱與必要範圍須以實際 PVE 版本確認。
3. 在 **Users** 建立專用服務帳號，例如 `dp340-backup@pve`，不使用 `root@pam`。
4. 在 **API Tokens** 產生 Token。只在密碼庫保存 Token ID 與 Secret；Secret 通常只顯示一次。
5. 將角色套用在最小必要路徑，並確認「Privilege Separation」設定是否影響 Token 權限繼承。
6. 先以唯讀／探索操作測試，再執行備份。若缺權限，只補足錯誤訊息所證實的必要權限，不直接授予 Administrator。

<span class="verify-tag">需依 Synology ActiveProtect / Proxmox VE 實際版本驗證</span> DP340 所需的精確權限集合、是否支援 API Token、Token 格式與叢集探索行為。

### 3.2 設定 DP340 與 APM 串接

1. 從 Service／Management 網路登入 ActiveProtect Manager。
2. 在 DP340 的 10G 介面配置 Data 網段靜態 IP；檢查 MTU、DNS、NTP、路由與防火牆。PVE Node 端仍以 2.5GbE 連線。
3. 在保護來源新增 Proxmox VE；輸入 PVE 節點的 **Data 網段 IP** 與專用 Token。
4. 驗證 TLS 憑證／指紋，不以永久關閉驗證作為正式方案。
5. 確認可探索預期的 3 個節點與測試 VM，且沒有非預期資產。
6. 在 PVE 與交換器側確認實際 API 與資料連線使用正確介面；將截圖、時間與介面計數器納入證據。

<span class="verify-tag">需依 Synology ActiveProtect / Proxmox VE 實際版本驗證</span> APM 選單名稱、Proxmox VE 保護來源支援版本、叢集自動探索方式及憑證驗證流程。

<h2 id="tests">4. 五個驗證測試案例</h2>

<section class="test-card"><div class="test-head"><span class="test-num">01</span><strong>2.5G 首次全備份與共享 Corosync 壓力測試</strong></div><div class="test-body">
<h4>目的</h4>證明備份資料使用 NIC 2 的 Data VLAN，並確認與其共用實體介面的 Corosync 在備份負載下仍穩定。
<h4>步驟</h4>
1. 從每個節點選 1 台測試 VM；Windows 若採應用程式一致性，先確認 VSS 狀態與產品支援方式。
2. 記錄備份前 `pvecm status`、Corosync 延遲／丟包、介面計數器及 storage I/O。
3. 先限制單一備份工作與保守頻寬，手動執行首次備份；同時監看 PVE 共用 NIC、Data／Corosync VLAN、DP340 10G NIC 與交換器埠。穩定後才逐步增加負載。
4. 完成後再取一次叢集、介面、備份工作與容量證據。
<h4>判定</h4>備份成功；主要流量出現在 Data VLAN；Corosync 無新增告警、quorum 變化或可歸因於測試的延遲／丟包。吞吐量以 2.5GbE Node 端、協定開銷與 storage 實測解釋，不以 10G 交換器線速作為目標。
<h4>記錄</h4>邏輯資料量、實際傳輸量、開始／結束時間、平均／峰值 Gbps、DP340 寫入量、Corosync latency／loss、工作 ID。
</div></section>

<section class="test-card"><div class="test-head"><span class="test-num">02</span><strong>增量備份、異動區塊與去重</strong></div><div class="test-body">
<h4>目的</h4>量測第二次備份的傳輸量與容量節省，不預設 CBT 或全域去重一定適用。
<h4>步驟</h4>
1. 在 3 台測試 VM 寫入可校驗的新資料，記錄大小與 checksum。
2. 觸發第二次備份，記錄執行時間、來源 Data NIC 傳輸量與 DP340 容量變化。
3. 比較首次與第二次備份，並從 APM 擷取其所提供的去重／壓縮／儲存效率指標。
<h4>判定</h4>第二次備份成功且新資料可由還原點取回；增量與容量節省比率採實測數據。<span class="verify-tag">需依 Synology ActiveProtect / Proxmox VE 實際版本驗證</span> CBT、全域去重的支援範圍、統計口徑與重設條件。
<h4>記錄</h4>異動量、傳輸量、增量時間、儲存成長量、去重／壓縮比、checksum。
</div></section>

<section class="test-card"><div class="test-head"><span class="test-num">03</span><strong>即時／快速還原與 RTO 量測</strong></div><div class="test-body">
<h4>目的</h4>驗證當版產品可用的最快還原流程，量測「提交還原」到「服務可登入」的實際 RTO。
<h4>步驟</h4>
1. 先記錄原 VMID、MAC、IP、storage 與服務驗證方式。優先隔離或改用新 VMID，避免與正式網路衝突。
2. 刪除或隔離測試 VM，於 APM 選擇當版實際提供的還原模式與 PVE 目標。
3. 分別記錄提交、VM 可啟動、OS ready、應用服務可登入的時間。
4. 觀察資料路徑、暫存 storage、效能與後續資料落地／回遷狀態；完成後驗證資料一致性。
<h4>判定</h4>還原 VM 在核准的 RTO 目標內提供服務，且資料校驗成功。原始草案中的「1–2 分鐘」、「以 NFS 掛載」與「自動 Live Migration 回本地」均不是預設保證。
<h4>必要確認</h4><span class="verify-tag">需依 Synology ActiveProtect / Proxmox VE 實際版本驗證</span> 是否支援 Instant Restore、實際協定、PVE storage 呈現方式、背景回遷是否自動，以及適用的 VM／storage／版本限制。
</div></section>

<section class="test-card"><div class="test-head"><span class="test-num">04</span><strong>跨節點完整還原</strong></div><div class="test-body">
<h4>目的</h4>模擬 Node A 不可用，將測試 VM 完整還原至健康的 Node B 或 C。
<h4>步驟</h4>
1. 先確認 cluster、quorum、HA、Ceph／LVM-thin 與目標容量健康。
2. 以核准方式關閉或隔離 Node A；不得在未評估 fencing／HA 影響時直接斷電。
3. 從 DP340 選擇完整還原，指定健康節點、新 VMID（建議）與目標 storage。
4. 啟動前核對 MAC、IP、bridge 與 guest 內靜態網路；啟動後驗證 OS、服務及 checksum。
<h4>判定</h4>完整還原成功、服務網路經人工確認後正常，資料一致性通過；記錄實際 RTO／RPO。跨節點支援矩陣與網路設定保留行為 <span class="verify-tag">需依 Synology ActiveProtect / Proxmox VE 實際版本驗證</span>。
</div></section>

<section class="test-card"><div class="test-head"><span class="test-num">05</span><strong>不可變備份與權限邊界</strong></div><div class="test-body">
<h4>目的</h4>確認鎖定期間內，不同權限角色可執行／不可執行的刪除、縮短保留期與系統管理行為。
<h4>步驟</h4>
1. 若當版 APM 提供不可變設定，在測試策略設 7 天；取得一個明確標示鎖定到期日的還原點。
2. 分別以備份操作員、一般管理員與最高權限角色測試刪除，並嘗試縮短保留期；不要測試重設、抹除或破壞設備。
3. 保存 UI 訊息、audit log、事件代碼、帳號角色與時間戳。
4. 驗證遭拒後還原點仍可列出並可執行測試還原。
<h4>判定</h4>結果必須逐角色記錄。不得僅因一般 UI 刪除被拒，就推論遭入侵的最高權限管理員、設備重設或其他控制面也無法破壞資料。
<h4>必要確認</h4><span class="verify-tag">需依 Synology ActiveProtect / Proxmox VE 實際版本驗證</span> 不可變功能是否存在、授權／儲存限制、鎖定是否可延長或縮短、哪些角色可繞過，以及設備重設／保固維修情境的行為。
</div></section>

<h2 id="signoff">5. Sign-off 驗證結果表格</h2>

<div class="result-table">

| ID | 測試項目 | 驗收基準 | 實際結果／證據 | 數據記錄 | 判定 |
|---|---|---|---|---|---|
| 01 | 首次全備份／網路隔離 | 備份成功；流量走 Data；Corosync 穩定 | __________________ | 容量 ___ GB；時間 ___ min；平均／峰值 ___ / ___ Gbps；loss ___ | ☐ Pass ☐ Fail |
| 02 | 增量／去重 | 新資料可還原；效率以實測呈現 | __________________ | 異動 ___ GB；傳輸 ___ GB；節省比 ___；時間 ___ min | ☐ Pass ☐ Fail |
| 03 | 即時／快速還原 | 服務與資料驗證成功；RTO 符合核准目標 | __________________ | VM boot ___ sec；service RTO ___ sec；RPO ___ | ☐ Pass ☐ Fail |
| 04 | 跨節點完整還原 | B／C 節點啟動；網路與 checksum 正常 | __________________ | 還原 ___ min；資料 ___ GB；checksum ______ | ☐ Pass ☐ Fail |
| 05 | 不可變／權限邊界 | 各角色結果與 audit log 完整；還原點可用 | __________________ | 角色 ______；事件碼 ______；到期日 ______ | ☐ Pass ☐ Fail |

</div>

### 例外與風險接受

| 未通過／條件式通過項目 | 影響 | 暫行措施 | 負責人 | 到期日 |
|---|---|---|---|---|
|  |  |  |  |  |
|  |  |  |  |  |

<div class="kb-signoff"><div>執行人／日期</div><div>系統負責人／日期</div><div>變更核准人／日期</div></div>

<p class="print-only">文件列印時間：________________　APM 版本：________________　PVE 版本：________________</p>

<h2 id="operations">6. 長期維運與容量管理建議</h2>

<div class="kb-grid">
  <div class="kb-card"><h3>錯開備份窗口</h3>Data 與 Corosync 共用 2.5GbE，預設一次只跑一個 Node 的大型備份。可先以 Node A 01:00、B 02:30、C 04:00 為假設，再依 Corosync 與吞吐實測調整。</div>
  <div class="kb-card"><h3>容量水位</h3>建立 70% 預警、80% 處置、90% 升級機制。容量門檻與可用容量不可硬套固定 14.5 TB，應依實際型號、RAID、保留政策與當版官方規格計算。</div>
  <div class="kb-card"><h3>定期還原</h3>備份成功不等於可還原。至少每季抽測 VM boot、應用服務與 checksum；重大升級後追加測試。</div>
  <div class="kb-card"><h3>權限與憑證</h3>Token 放密碼庫、限制來源、定期輪替；每季檢視角色與稽核紀錄。離職／職務異動立即撤銷。</div>
  <div class="kb-card"><h3>版本管理</h3>升級 DP340／APM／PVE 前查相容矩陣、備份設定並保留回復方案；升級後重跑探索、備份與還原 smoke test。</div>
  <div class="kb-card"><h3>3-2-1-1-0</h3>至少 3 份資料、2 種媒體、1 份異地、1 份離線或不可變、0 個未驗證錯誤；不可變機制需與管理控制面風險一併評估。</div>
</div>

### 每月／每季檢查節奏

| 頻率 | 工作 |
|---|---|
| 每日 | 失敗工作、容量趨勢、硬體／磁碟、告警通道、時間同步 |
| 每週 | 隨機還原檔案、工作時窗，以及共享 2.5GbE 上的 Data／Corosync 延遲、丟包與介面錯誤 |
| 每月 | Token／角色檢視、容量預測、韌體與相容性公告、audit log 抽查 |
| 每季 | 完整 VM 還原、跨節點 DR 演練、RTO／RPO 重測、Runbook 更新與簽核 |

## 停止條件

測試期間若出現 quorum 改變、Corosync 延遲／丟包異常、節點非預期 reboot／fencing、Ceph／主要 storage 進入非預期錯誤、DP340 容量達處置門檻，或還原 VM 可能與正式 IP／MAC 衝突，應立即停止新工作並依變更計畫復原；先保留證據，不直接重跑。

---

**文件狀態：** 待依現場 DP340、ActiveProtect Manager 與 Proxmox VE 版本完成 PoC 後簽核。  
**敏感資訊：** 文件與截圖不得包含 Token Secret、密碼、Private Key、完整憑證或可重用的 Session。

