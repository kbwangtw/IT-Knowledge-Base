---
layout: default
title: "整個 PVE 叢集安全關機與開機：一鍵腳本（含 HA、Ceph）"
date: 2026-10-23
categories: [PVE, Ceph, HA]
permalink: /docs/pve/pve-cluster-full-shutdown/
last_modified_at: 2026-11-01
---

# 整個 PVE 叢集安全關機與開機：一鍵腳本（含 HA、Ceph）

> **一句話**：為了調整機器擺放位置（順便替 tokyo16 加裝 10G 網卡），要把三台 PVE、PBS31 和兩台 NAS 全部關機。三台不能直接一起關：HA 會把服務搬來搬去，Ceph 會以為硬碟壞了開始搬資料。這篇把正確順序寫成兩支腳本（關機、開機），實際用了一次；最後一台被 HA 的 watchdog 強制重開，已修正腳本（修正版待下次關機驗證）。2026-11-01 為了接 UPS 又關了一次，這次手動操作、最後一台正常關機（第 9 節）。

| 項目 | 內容 |
| --- | --- |
| 適合誰看 | 要搬機房、停電維護，需要把整個叢集關掉再開回來的人 |
| 環境 | PVE 9.2.21 三節點 node10～12（Ceph、CephFS、13 個 HA 資源）；PBS31 是 NAS 上的 VM；NAS tokyo16、melayu17 |
| 日期 | 2026-10-23 |
| 結論 | ✅ 關機腳本跑完 HA 停止、其他 VM 關機、Ceph 旗標、兩台關機 ✅ 開機腳本 1 分半恢復 13 個服務、Ceph `HEALTH_OK` ⚠️ 最後一台（node10）被 watchdog 重開、卡在開機，長按電源關機 ⏳ 已加「停 HA 監看＋延遲卸載 CephFS」，待下次關機驗證 ✅ tokyo16 加裝 10G 網卡：備份、GC、Verify 時間都沒有明顯變化（第 8 節） ✅ 2026-11-01 為了裝 UPS 又關了一次（手動流程，node10 正常關機，第 9 節） |

## 1. 先認識幾個名詞

| 名詞 | 白話解釋 |
| --- | --- |
| **quorum** | 叢集「過半數同意」才能運作；三台要至少兩台在線。剩一台時就失去 quorum |
| **HA 資源** | 交給 HA 管的 VM／CT；某台節點失聯時，HA 會在別台重新啟動它 |
| **shutdown_policy＝migrate** | 本叢集的 HA 設定：節點關機時，服務先搬到別台。整個叢集要關時，這會讓服務被搬來搬去 |
| **pve-ha-lrm／pve-ha-crm** | HA 在每台節點上的兩個程式；LRM 負責本機服務，CRM 負責全叢集調度 |
| **watchdog** | HA 的保護機制：節點失去 quorum 時，若 LRM 還在監看，約 60 秒後**強制重開**這台，避免它繼續跑服務 |
| **Ceph 旗標** | 告訴 Ceph「現在是維護」：`noout`（OSD 下線不要踢出）、`norecover`／`nobackfill`／`norebalance`（不要搬資料）、`nodown`、`pause`（暫停讀寫） |
| **CephFS** | Ceph 上的共用檔案系統，掛在 `/mnt/pve/cephfs` |
| **ha-rebalance-on-start** | `datacenter.cfg` 的 CRS 設定；服務啟動時挑當下負載最低的節點 |

## 2. 全貌

```text
關機（node10 執行 cluster-shutdown.sh）
  0 檢查 quorum／SSH／Ceph，列出所有執行中的 VM／CT   ← --dry-run 只做到這裡
  1 記錄 HA 狀態、不在 HA 的執行中 VM／CT（存 /etc/pve/priv/）
  2 HA 服務 set stopped，等全部停止
  3 關閉不在 HA 的 VM／CT（逾時不強制，改為停止腳本）
  4 Ceph 旗標
  5 三台停 pve-ha-lrm → pve-ha-crm（10/23 修正後新增）
  6 延遲卸載 CephFS，關另外兩台，最後關自己
        ↓
  關 PBS31 → 關 NAS → 搬機器 → 開 NAS → 開 PBS31 → 開三台
        ↓
開機（任一台執行 cluster-startup.sh）
  1 等 quorum  2 解除 Ceph 旗標  3 等 HEALTH_OK
  4 只啟動關機前是 started 的 HA 服務  5 啟動關機前在跑的非 HA VM／CT
```

## 3. 步驟一：安裝兩支腳本

腳本在 repo 的 [`tools/pve-cluster-power/`](https://github.com/kbwangtw/IT-Knowledge-Base/tree/main/tools/pve-cluster-power)。在 node10 用 `cat > /usr/local/sbin/cluster-shutdown.sh <<'EOS' … EOS` 貼上內容（`'EOS'` 加單引號，`$h`、`$(…)` 才會原樣寫入），開機腳本同理，再：

```bash
chmod 700 /usr/local/sbin/cluster-shutdown.sh /usr/local/sbin/cluster-startup.sh
bash -n /usr/local/sbin/cluster-shutdown.sh && bash -n /usr/local/sbin/cluster-startup.sh && echo "SYNTAX-OK"
for h in node11 node12; do scp -p /usr/local/sbin/cluster-{shutdown,startup}.sh root@$h:/usr/local/sbin/; done
```

| 片段 | 意思 |
| --- | --- |
| `chmod 700` | 只有 root 能讀、能執行 |
| `bash -n` | 只檢查語法，不執行 |
| `scp` 到另外兩台 | 開機時 node10 萬一起不來，別台也能執行開機腳本 |

腳本的安全設計：

| 設計 | 原因 |
| --- | --- |
| `--dry-run` | 只檢查、列出狀態，不做任何變更 |
| 要輸入 `SHUTDOWN` | 避免誤觸 |
| VM／CT 關機逾時不強制關 | 避免強制關掉 DC 這類 Windows VM；腳本停在第 3 步，不會設 Ceph 旗標、不會關機 |
| 狀態檔放 `/etc/pve/priv/` | 叢集共用目錄，開機後任一台都讀得到 |
| 開機只啟動關機前 `started` 的服務 | 原本就停著的不會被誤開 |
| 每次都留記錄檔 | `/root/cluster-shutdown-日期時間.log`、`/root/cluster-startup-日期時間.log` |

## 4. 步驟二：先試跑

```bash
cluster-shutdown.sh --dry-run
```

**看到的結果**：quorum、SSH 通過，`HEALTH_OK`，13 個 HA 服務都是 `started`，執行中 15 個。其中 VM 104（UBClient）、VM 108（WinClient）**不在 HA**：原版腳本關機時會關、開機時不會開，所以加上「記錄並重新啟動非 HA 的 VM／CT」。

## 5. 步驟三：正式關機

**開始前確認**：人在現場、用區網連（WireGuard 跑在叢集的 ct:109，關機會斷）；當天備份成功；避開 21:00～03:00；記下三台 IP（DNS 也在叢集裡，開機時要用 IP 連）；WinClient、UBClient 沒人在用。

```bash
cluster-shutdown.sh      # 輸入 SHUTDOWN
```

**看到的結果**（10/23）：

| 時間 | 步驟 | 結果 |
| --- | --- | --- |
| 09:46:52～09:47:45 | 2. HA 服務 | 13 個約 50 秒全部停止 |
| 09:47:45～09:48:04 | 3. 非 HA VM | VM 104、108 約 19 秒關機 |
| 09:48:04 | 4. Ceph 旗標 | `HEALTH_WARN pauserd,pausewr,nodown,noout,nobackfill,norebalance,norecover flag(s) set`（預期） |
| 09:48:10～09:49:27 | 5. 關機 | node12、node11 無回應；09:49:27 送出 node10 關機 |

### 5-1 node10 沒關掉：被 watchdog 重開、卡在開機

node10 連線還在，`systemctl list-jobs` 顯示的全是 **start**：

```text
mnt-pve-cephfs.mount        start running
pve-guests.service          start running
multi-user.target           start waiting
```

**判讀**：node10 不是沒關機，而是**被強制重開後卡在開機途中**——另外兩台關機後它失去 quorum，HA 的 LRM 還在監看，watchdog 約 60 秒後強制重開；開機時 Ceph 只剩一台、又是 `pause`，CephFS 掛不上，開機一直完成不了。服務都是 `stopped`，所以重開後沒有啟動任何東西。

處理：`systemctl poweroff --force` 沒反應，**長按電源鍵 5 秒**。當時所有 VM／CT 已停、Ceph 暫停讀寫，開機後 Ceph 1 分鐘內 `HEALTH_OK`，沒有資料問題。

### 5-2 修正：關機前停 HA 監看、延遲卸載 CephFS

腳本最後一段換成（`sed -i '/^say "== 5. 關機/,$d'` 刪掉舊段落，再 `cat >>` 加上新段落）：

```bash
say "== 5. 停止 HA 監看程式（避免最後一台失去 quorum 時被 watchdog 強制重開）"
for h in $NODES; do ssh root@$h 'systemctl stop pve-ha-lrm'; done
for h in $NODES; do ssh root@$h 'systemctl stop pve-ha-crm'; done

say "== 6. 關機：$OTHERS，最後 $ME（先延遲卸載 CephFS，避免關機卡住）"
for h in $OTHERS; do ssh root@$h 'umount -l /mnt/pve/cephfs 2>/dev/null; nohup shutdown -h now >/dev/null 2>&1 &'; done
…
sync; umount -l /mnt/pve/cephfs 2>/dev/null; shutdown -h now
```

| 片段 | 意思 |
| --- | --- |
| 先停三台 `pve-ha-lrm`，再停 `pve-ha-crm` | Proxmox 建議的順序；LRM 停了 watchdog 就不會重開節點 |
| `umount -l` | 延遲卸載：先從目錄拿掉，不等 Ceph 回應 |

開機腳本不用改：兩個 HA 程式開機會自動啟動。⏳ 修正版要下次整個叢集關機才能驗證。

## 6. 步驟四：關 PBS31 與 NAS、搬機器、開機

PBS31 是 NAS 上的 VM，PBS 的 datastore 在 tokyo16 上，所以順序是：

| 關機 | 開機 |
| --- | --- |
| 1. PVE 叢集 | 1. NAS（等完全開機） |
| 2. PBS31（網頁 Administration → Shutdown，或 SSH `shutdown -h now`；先看 Dashboard 沒有 Running Tasks） | 2. PBS31 |
| 3. NAS（DSM 右上角 → 關機；先確認 Virtual Machine Manager 裡 PBS31 已關機） | 3. 三台 PVE，再執行開機腳本 |

Synology 的連線通知記下 NAS 停機時間（雲端通知，可能有延遲）：tokyo16 10:15～15:00、melayu17 10:20～14:57。

## 7. 步驟五：開機腳本

三台都按電源鍵，用 **IP** SSH 到任一台：

```bash
cluster-startup.sh
```

**看到的結果**（14:55:48～14:57:25，約 1 分半）：

| 階段 | 結果 |
| --- | --- |
| quorum | 一開始就是 `Nodes: 3`、`Quorate: Yes` |
| Ceph 旗標解除 → HEALTH_OK | 約 50 秒；`3 osds: 3 up, 3 in`，`97 active+clean` |
| HA 服務 | 13 個 `start`，30 秒後全部 `started` |
| 非 HA VM | VM 104、108 啟動 |

再確認：`ha-manager status | grep -c started` 為 13；DNS、WireGuard、Graylog、PBS31 datastore 都正常。

**HA 重新分配了節點**：13 個同時啟動，`ha-rebalance-on-start=1` 讓 HA 依當下負載挑節點，8 個換了位置，數量仍是 4／5／4，DNS（AdGuard、Pi-hole）與 DC01／DC02 的互斥規則都有遵守。

| 服務 | 關機前 | 開機後 |
| --- | --- | --- |
| ct:102 LibreNMS | node10 | node11 |
| ct:105 Graylog | node11 | node12 |
| ct:112 Wazuh | node12 | node11 |
| ct:113 ai | node11 | node10 |
| ct:114 Grafana | node11 | node12 |
| vm:106 DC01 | node12 | node10 |
| vm:107 DC02 | node10 | node12 |
| vm:111 CA | node12 | node11 |

之後 `pct exec` 要到新的節點執行；LibreNMS 的「位置」欄更不準了（[Wazuh 營運文件](https://kbwangtw.github.io/IT-Knowledge-Base/docs/pve/wazuh-lxc-ubuntu2204-operations/)待辦）。

## 8. 順便：tokyo16 加裝 10G 網卡

**做什麼**：趁 NAS 關機時，tokyo16（DS723+）加裝 **Synology E10G22-T1-Mini**（單埠 10GBASE-T，RJ45），接到 10G 交換器；原本在「區域網路 2」的儲存網段 IP 搬到新網卡「區域網路 3」，**位址不變**，所以用這個 IP 的設備（PBS31 的 SMB datastore）不用改設定。

**備份流量經過兩段**：

```text
PVE 節點 ──①──▶ PBS31（tokyo16 上的 VM） ──②──▶ tokyo16 本機 SMB
```

| 段落 | 走哪裡 | 速度上限 |
| --- | --- | --- |
| ① 節點 → PBS31 | 節點網卡 → 10G 交換器 → tokyo16 區域網路 3 → 虛擬交換器 → PBS31 | 節點的網卡（Realtek，推測 2.5G） |
| ② PBS31 → tokyo16 | 同一台 NAS、同一個虛擬交換器內部 | 不經過實體網路 |

關鍵是 **PBS31 的虛擬交換器綁在哪張網卡**：如果還綁區域網路 2，① 不會用到 10G，② 甚至可能從區域網路 2 出去、繞交換器再從區域網路 3 回來。

**怎麼檢查**（tokyo16 DSM）：

| 檢查 | 位置 | 結果 |
| --- | --- | --- |
| 連線速度 | 控制台 → 網路 → 網路介面 → 區域網路 3 | ✅ 10000 Mbps、全雙工 |
| 區域網路 2 | 同一頁 | ✅ 沒有儲存網段的 IP（同網段兩張網卡會不穩） |
| MTU | 區域網路 3 → 編輯 → 進階 | ✅ 1500，和原本相同（要和 PBS31、交換器一致） |
| PBS31 的網路 | Virtual Machine Manager → 網路（虛擬交換器綁定的網卡）；虛擬機器 → PBS31 → 編輯 → 網路 | ✅ 綁區域網路 3，不會繞路 |
| 防火牆 | 控制台 → 安全性 → 防火牆 → 編輯規則，看上方的介面選單 | ✅ 規則設在「所有介面」（兩個內網網段全部允許、特定服務只允許台灣），新網卡同樣受保護。DSM 防火牆可以依網卡分別設定，規則若綁在舊網卡，新網卡會沒有規則 |
| PBS31 datastore | PBS 網頁 → Datastore | ✅ 正常 |

- 10GBASE-T 建議 Cat6a（100 m）；Cat6 約 55 m，Cat5e 通常跑不到 10G。
- LibreNMS 會多出新的網路介面，下次輪詢後在 tokyo16 的 Ports 頁看流量。
- ✅ 效果驗證（10/24 晚上起的結果見 8-1）：備份、GC、Verify 都沒有明顯變化。

### 8-1 效果驗證（2026-10-24 晚上～10/25 凌晨）

**備份**：10/23 是叢集重開後第一晚，VM 的 dirty bitmap（記錄哪些區塊有變動）被清空，備份要讀整顆磁碟，加上 HA 重新分配節點，所以改用「單一 VM／CT」比較。

| VMID | 名稱 | 10/23 | 10/24 | 差 |
| --- | --- | --- | --- | --- |
| 108 | WinClient（VM） | 7m34s | 2m53s | −4m41s |
| 106 | DC01（VM） | 2m55s | 1m15s | −1m40s |
| 104 | UBClient（VM） | 1m41s | 9s | −1m32s |
| 107 | DC02（VM） | 2m53s | 2m38s | −15s |
| 111 | CA（VM） | 1m59s | 1m44s | −15s |
| 113 | ai | 2m41s | 1m31s | −1m10s |
| 103 | IPAM | 1m08s | 56s | −12s |
| 110 | ProxCenter | 3m45s | 4m30s | +45s |
| 100、101、102、105、109、112、114 | AdGuard、Pihole、LibreNMS、Graylog、WireGuard、Wazuh、Grafana | — | — | 都在 ±5 秒內 |

| 分類 | 10/23 | 10/24 | 差 |
| --- | --- | --- | --- |
| 5 台 VM | 17m02s | 8m39s | −8m23s |
| 10 個 CT | 12m52s | 12m10s | −42s |
| 三台總計 | 29m54s | 20m49s | −9m05s |

與換網卡**前**的基準相比：

| 日期 | 三台總計 |
| --- | --- |
| 10/13（node10 7m37s＋node11 9m07s＋node12 4m29s） | 21m13s |
| 10/24 | 20m49s（−24 秒，約 −2%） |

> 10/13 的備份清單可能比現在少幾個 CT（例如 Grafana 較晚才建立，未確認），這個比較只能當參考。

**判讀**：

- VM 變快符合預期：dirty bitmap 恢復後又是增量備份，**不是網路變快**。
- CT 幾乎沒變，才是看網卡效果的地方：網路若是瓶頸，CT 也該明顯變快。
- ai 變快：推測是當天移除了 Hermes（約 1.5 GB）。ProxCenter 變慢：推測是當天在 CT110 下載了新的 Docker 映像檔，多了一批新檔案（未確認）。

**GC 與 Verify**（PBS 通知信）：

| 工作 | 10/23 | 10/24～10/25 |
| --- | --- | --- |
| GC（00:00 起） | 00:00～00:08，成功（回收 23.63 GiB、損壞 0、dedup 10.21） | 00:00 起，信件 00:07，成功（回收 53.587 GiB、刪除 23905 個區塊、損壞 0、dedup 10.34） |
| Verify（02:00 起） | 02:00～03:04（1 小時 4 分），成功 | 信件 03:01（約 1 小時 1 分，開始時間為排程時間推測），成功，沒有驗證失敗的備份 |

Verify 要讀整個資料集，若 10G 有幫助，這裡最看得出來，結果只快約 5%。

10/25 GC 通知信的完整數字：

| 項目 | 數值 |
| --- | --- |
| 索引檔案數 | 270 |
| 已回收空間／已刪除區塊 | 53.587 GiB／23905（10/23 是 23.63 GiB，多一倍；推測是保留期限到期的舊備份被清掉，未確認） |
| 已刪除損壞區塊／剩餘損壞區塊 | 0／0 |
| 等待移除空間 | 25.727 GiB（10883 個區塊）：這輪沒被引用、但還在保護期內，下一輪 GC 才會刪 |
| 原始資料使用量 → 實際磁碟使用量 | 3.631 TiB → 359.444 GiB（9.67%，也就是 1／dedup 倍率） |
| 磁碟區塊數／重複資料刪除倍率 | 162013／10.34（10/23 是 10.21） |

> 同一時間 PVE 看到的 SMB 共享已用約 869 GiB，比資料集的 359 GiB 大很多；可能共享上還有其他資料，或檔案系統有額外開銷，未確認，之後要估容量時再查。

**結論**：加裝 10G 網卡對**目前這個備份架構**沒有可見的效果。對照上面的流量圖，② PBS31 → tokyo16 在同一台 NAS 的虛擬交換器內，不經過實體網路；① 節點 → PBS31 的上限是節點網卡（推測 2.5G）。時間主要花在讀 Ceph、比對重複區塊（dedup）、經 SMB 寫入。10G 網卡的效益推測會在多個來源同時存取 NAS、還原大型 VM 時才看得出來（未驗證）。

**還沒驗證的瓶頸**（都是推測）：

| 候選 | 怎麼確認 |
| --- | --- |
| SMB 協定對大量小檔案（PBS 的資料區塊檔）效率差 | PBS31 執行 `proxmox-backup-client benchmark`，看 TLS 傳輸、SHA256、壓縮、Verify 速度，一次看出 CPU 和網路誰是瓶頸 |
| NAS 的 CPU 或磁碟 | Verify 進行時，看 DSM → 資源監控的網路、CPU、磁碟使用 |
| 節點網卡 | 從節點對 PBS31 測速 |

## 9. 第二次關機：安裝 UPS（2026-11-01，手動操作）

> **一句話**：為了接上 UPS，把整個叢集關機再開機；這次**沒有用 10/23 的腳本**，而是照同樣的順序手動做。結果一切正常，但開機後 Lab Ops 卡在「連線失敗」、HA 服務又換了節點，這兩件事要記得。

| 項目 | 內容 |
| --- | --- |
| 日期 | 2026-11-01（下午；備份排程 21:00 之前做完） |
| 做法 | 手動：HA 資源逐一設 `stopped` → Ceph 旗標 → 關節點；沒用腳本是因為當天忘了腳本放在哪裡（位置見 9-1 的提示） |
| 結果 | ✅ quorum 正常、Ceph `HEALTH_OK`、97 個 PG 全部 `active+clean`、13 個 HA 服務 `started`、21 項服務唯讀檢查全過 ✅ WireGuard 從手機 4G 連入正常 |
| 沒驗證到的 | 10/23 的待辦「修正版腳本讓 node10 正常關機」**這次沒有驗證**，因為沒跑腳本 |

### 9-1 和 10/23 的差別

| 項目 | 10/23（腳本） | 11/01（手動） |
| --- | --- | --- |
| Ceph 旗標 | `pause`、`nodown`、`noout`、`nobackfill`、`norebalance`、`norecover` | 只設 `noout`、`norebalance`、`nobackfill`、`norecover` 四個 |
| 非 HA 的 VM（104、108） | 腳本關機、開機時再啟動 | 關機前它們**本來就是停止的**，不用處理 |
| 停 `pve-ha-lrm`／`pve-ha-crm` | 腳本自動做 | 最後一台 node10 **正常關機**，沒有被 watchdog 重開；這次有沒有手動停過 `pve-ha-lrm`／`pve-ha-crm`：未確認 |
| 開機後起服務 | 腳本只起「關機前是 started」的 | 手動逐一 `ha-manager set … --state started` |

> **腳本在哪裡**：repo 的 `tools/pve-cluster-power/`；依第 3 節，三台的 `/usr/local/sbin/cluster-shutdown.sh`、`cluster-startup.sh` 都已安裝（用 `ls -la /usr/local/sbin/cluster-*.sh` 確認；11/01 在 node10 確認過兩個檔都在，權限 700，關機腳本修改於 10/23 15:10、開機腳本 10/23 09:44，node11、node12 沒有確認）。
>
> 下次建議直接用 10/23 的腳本：它會記錄關機前的狀態、自動處理非 HA 的 VM、只還原原本就在跑的服務，不會忘記「改回 started」。手動做的風險就是這一步被漏掉。

### 9-2 關機前先看一遍（唯讀）

| 檢查 | 指令 | 看到的結果（2026-11-01 14:24） |
| --- | --- | --- |
| quorum | `pvecm status` | `Quorate: Yes`、3 個節點、票數 3 |
| Ceph | `ceph -s` | `HEALTH_WARN`：1 個 OSD 的 BlueStore 慢操作（osd.1）；3 up／3 in；97 個 PG 全部 `active+clean` |
| HA | `ha-manager status` | quorum OK、13 個資源全是 `started`、沒有 error |
| 備份 | `ps aux \| grep -c '[v]zdump'`（三台各跑） | 三台都是 `0`（備份排程 21:00 起，現在沒有在跑） |
| Guest | `qm list`、`pct list`（三台各跑） | VM 104、108 在 node11，本來就是 `stopped`、不在 HA |

### 9-3 步驟

**① HA 資源分批設成 `stopped`**（先葉端、再 DNS／AD、最後留 Graylog、WireGuard 和 Lab Ops 主機）：

```bash
ha-manager set ct:114 --state stopped
```

| 批次 | 資源 | 原因 |
| --- | --- | --- |
| 1 | ct:114、110、102、103、112 | 監控與葉端服務，沒有人依賴它們 |
| 2 | ct:100、101、vm:111 | DNS 與 CA |
| 3 | vm:107、vm:106 | DC02、DC01 |
| 4 | ct:105、109、113 | 最後才停 Graylog（留下關機過程的 log）、WireGuard（保留遠端進入）和 Lab Ops 主機 |

每批做完用 `ha-manager status` 確認都變 `stopped` 再做下一批。**應該看到**：13 個資源全是 `stopped`，三台的 `qm list`／`pct list` 全是 `stopped`。

**② 設 Ceph 旗標並驗證**：

```bash
ceph osd set noout
ceph osd set norebalance
ceph osd set nobackfill
ceph osd set norecover
ceph osd dump | grep '^flags'
```

**應該看到**：`flags` 那行出現這四個旗標（另有 Ceph 預設的 `sortbitwise,recovery_deletes,purged_snapdirs,pglog_hardlimit`）。

**③ 關機**：PBS31 → node12 → node11 → node10（你操作的最後關）→ NAS → 網路設備。當天沒有留下關機與開機的時間紀錄（這也是用腳本的好處：腳本會自動留記錄檔）。

### 9-4 開機後的恢復

| 順序 | 做什麼 | 應該看到 |
| --- | --- | --- |
| 1 | NAS → PBS31 → 三台節點 | 三台都起來 |
| 2 | `pvecm status`、`ceph -s`、`ceph osd tree` | `Quorate: Yes`；`3 osds: 3 up, 3 in`；97 個 PG `active+clean`；**`HEALTH_OK`** |
| 3 | 解除四個旗標：`ceph osd unset …`，再 `ceph osd dump \| grep '^flags'` | 只剩 Ceph 預設的四個旗標 |
| 4 | HA 資源改回 `started`，**DC01、DC02 先**，等它們起來再設其他（第 1 批 vm:106、107；第 2 批 ct:100、101、vm:111、ct:109、113；第 3 批其餘） | `ha-manager status` 13 個全是 `started`、沒有 error |

**實測**：

- osd.1 的 BlueStore 慢操作警告，在 OSD 重新啟動之後**消失**，`ceph -s` 回到 `HEALTH_OK`（推測：警告的計時在 OSD 重啟時被重置）。
- **13 個服務又換了節點**：`ha-rebalance-on-start=1` 讓 HA 在啟動時依當下負載重新挑節點。8 個換了位置，數量變成 node10 五個、node11 四個、node12 四個：

| 服務 | 關機前 | 開機後 |
| --- | --- | --- |
| ct:100 AdGuard | node10 | node11 |
| ct:102 LibreNMS | node11 | node10 |
| ct:103 JT-IPAM | node10 | node12 |
| ct:105 Graylog | node12 | node10 |
| ct:109 WireGuard | node11 | node10 |
| ct:110 ProxCenter | node12 | node11 |
| ct:112 Wazuh | node10 | node11 |
| vm:107 DC02 | node11 | node12 |

其餘 5 個（ct:101、113、114、vm:106、vm:111）位置不變。**之後 `pct exec` 要到 CT 目前所在的節點執行**，用 `pvesh get /cluster/resources --type vm` 可以一次看到所有 Guest 在哪台、是否在跑。

### 9-5 開機後驗證（唯讀）

| 檢查 | 結果 |
| --- | --- |
| 各 CT 的 `systemctl is-system-running` | 全部 `running` |
| AdGuardHome、pihole-FTL、graylog-server、wazuh-manager、grafana-server | 全部 `active` |
| ProxCenter（CT110） | 4 個容器全是 `Up … (healthy)` |
| WireGuard | `wg show interfaces` 看到 `wg0`；手機 4G 開 WireGuard 後內網連得上 |
| PBS31 儲存 | `pvesm status` 顯示 `active`（今晚備份的前提） |
| DNS（AdGuard、Pi-hole） | 從 CT113 `ping` 兩台都通 |
| DC01、DC02 的 AD | 在 Windows 端確認，正常（PVE 只看得到 VM 在跑，看不到 AD 本身） |

## 10. 常見問題

| 現象 | 怎麼辦 |
| --- | --- |
| 最後一台沒關掉，`systemctl list-jobs` 都是 `start` | 被 watchdog 重開、卡在開機（5-1）；服務都是 stopped，長按電源關機即可；新版腳本先停 HA 監看 |
| 腳本停在第 3 步「還有 VM／CT 在執行」 | 某台 VM 5 分鐘內關不掉（有人在用、Windows 更新）。手動處理後再執行；不想關了就執行 `cluster-startup.sh` 恢復 |
| 腳本中途停下（HA 已停但沒關機） | 執行 `cluster-startup.sh`，會解除旗標（沒設的旗標 unset 也無害）並啟動原本的服務 |
| 開機後用名稱連不到節點 | DNS 在叢集裡，HA 服務啟動前用 IP 連 |
| 開機腳本說找不到 `/etc/pve/priv/ha-before-shutdown.txt` | 關機腳本沒跑到第 1 步，或已經用過一次（用過會改名為 `/root/ha-before-shutdown-used-…`） |
| WinClient 開機出現 `no efidisk configured`、`failed to reset PCI device` | 這台 VM 原本的設定（沒有 EFI 磁碟、有 PCI 直通），`Task finished with 2 warning(s)` 仍正常啟動 |
| 關機前 PBS31 網頁登不進去，重開後正常 | 原因未確認（和 SSH 金鑰設定無關，網頁用 PAM）；再發生時用 SSH 執行 `journalctl -u proxmox-backup-proxy --since "1 hour ago" \| grep -iE "auth\|login\|fail"` 抓原因 |
| 開機後 HA 資源都沒起來 | 手動關機時資源被設成 `stopped`，HA 不會自己起來；逐一 `ha-manager set <資源> --state started`，DC 先。腳本版會自動處理 |
| 整個叢集重啟後，Lab Ops（`claude --remote-control`）顯示 `Session creation failed`，程序卻還活著 | CT113 開機時 DNS（AdGuard、Pi-hole）還沒起來，啟動當下連線失敗，之後不會自己重連。確認 DNS 通了之後，**只對 `claude` 那個程序** `kill <PID>`，外層的 `while true` 迴圈 10 秒後會自動重啟它。**不要用 `pkill -f`**：外層迴圈與 tmux 的命令列也含同樣的字串，會連迴圈一起殺掉 |
| `pct exec` 說容器不存在 | 開機後 HA 換了節點；先用 `pvesh get /cluster/resources --type vm` 找出它現在在哪台 |
| 重啟後 Ceph 的慢操作警告不見了 | 正常：計時在 OSD 重啟時重置。若又出現，代表問題還在，看 BlueStore 慢操作那篇 |

## 11. 待辦

- [ ] 下次整個叢集關機時，驗證修正版（node10 正常關機、不被重開）
- [x] 比較備份時間確認 10G 網卡的效果（2026-10-25，8-1）：沒有明顯變化
- [ ] （可選）找出備份真正的瓶頸：Verify 時看 DSM 資源監控，或在 PBS31 執行 `proxmox-backup-client benchmark`
- [x] 三台的 `/usr/local/sbin/cluster-shutdown.sh` 已換成 5-2 的修正版（10/23，`bash -n` 通過，scp 到 node11、node12）
- [ ] 修正版驗證後，刪除 node10 的 `/usr/local/sbin/cluster-shutdown.sh.bak-20261023`
- [x] 這次 node10（最後一台）正常關機，沒有被 watchdog 重開（手動流程；與 10/23 腳本版不同的原因未確認）
- [ ] 下次整個叢集關機改用 10/23 的腳本，並驗證修正版
- [ ] Lab Ops 啟動迴圈先等 DNS 可用再啟動 `claude`（選項：A 改啟動指令加等待；B 調整 HA 啟動順序；C 不處理、整叢集重啟後手動 `kill`；目前採 C）
- [ ] UPS 是 APC SmartUPS 1500：確認這一台有 USB 或網路管理卡（依型號後綴與是否裝了網卡而定，未確認），再評估 NUT（斷電時自動依序關機）；接了哪些設備、預估續航時間尚未記錄

## 12. 延伸閱讀

- [PVE HA 放置策略](https://kbwangtw.github.io/IT-Knowledge-Base/docs/pve/pve-ha-placement-policy/)：CRS、`ha-rebalance-on-start`、互斥規則
- [PVE 更新重開後 HA 服務卡在 error](https://kbwangtw.github.io/IT-Knowledge-Base/docs/pve/pve-ha-service-error-after-reboot/)：shutdown_policy 改為 migrate 的原因
- [Proxmox VE：High Availability](https://pve.proxmox.com/pve-docs/chapter-ha-manager.html)（watchdog、fencing、shutdown policy）
- [Ceph：維護時的 OSD 旗標](https://docs.ceph.com/en/latest/rados/operations/health-checks/)
