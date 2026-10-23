---
layout: default
title: "整個 PVE 叢集安全關機與開機：一鍵腳本（含 HA、Ceph）"
date: 2026-10-23
categories: [PVE, Ceph, HA]
permalink: /docs/pve/pve-cluster-full-shutdown/
last_modified_at: 2026-10-23
---

# 整個 PVE 叢集安全關機與開機：一鍵腳本（含 HA、Ceph）

> **一句話**：為了調整機器擺放位置（順便替 tokyo16 加裝 10G 網卡），要把三台 PVE、PBS31 和兩台 NAS 全部關機。三台不能直接一起關：HA 會把服務搬來搬去，Ceph 會以為硬碟壞了開始搬資料。這篇把正確順序寫成兩支腳本（關機、開機），實際用了一次；最後一台被 HA 的 watchdog 強制重開，已修正腳本（修正版待下次關機驗證）。

| 項目 | 內容 |
| --- | --- |
| 適合誰看 | 要搬機房、停電維護，需要把整個叢集關掉再開回來的人 |
| 環境 | PVE 9.2.21 三節點 node10～12（Ceph、CephFS、13 個 HA 資源）；PBS31 是 NAS 上的 VM；NAS tokyo16、melayu17 |
| 日期 | 2026-10-23 |
| 結論 | ✅ 關機腳本跑完 HA 停止、其他 VM 關機、Ceph 旗標、兩台關機 ✅ 開機腳本 1 分半恢復 13 個服務、Ceph `HEALTH_OK` ⚠️ 最後一台（node10）被 watchdog 重開、卡在開機，長按電源關機 ⏳ 已加「停 HA 監看＋延遲卸載 CephFS」，待下次關機驗證 |

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
- ⏳ 效果驗證：比較換網卡後的備份時間與 10/13 基準（node10 7 分 37 秒、node11 9 分 07 秒、node12 4 分 29 秒，見 [Ceph slow op 文件](https://kbwangtw.github.io/IT-Knowledge-Base/docs/pve/ceph-bluestore-slow-op-backup-schedule/)第 7 節）；PBS 是增量備份，每晚資料量不同，看趨勢即可。

## 9. 常見問題

| 現象 | 怎麼辦 |
| --- | --- |
| 最後一台沒關掉，`systemctl list-jobs` 都是 `start` | 被 watchdog 重開、卡在開機（5-1）；服務都是 stopped，長按電源關機即可；新版腳本先停 HA 監看 |
| 腳本停在第 3 步「還有 VM／CT 在執行」 | 某台 VM 5 分鐘內關不掉（有人在用、Windows 更新）。手動處理後再執行；不想關了就執行 `cluster-startup.sh` 恢復 |
| 腳本中途停下（HA 已停但沒關機） | 執行 `cluster-startup.sh`，會解除旗標（沒設的旗標 unset 也無害）並啟動原本的服務 |
| 開機後用名稱連不到節點 | DNS 在叢集裡，HA 服務啟動前用 IP 連 |
| 開機腳本說找不到 `/etc/pve/priv/ha-before-shutdown.txt` | 關機腳本沒跑到第 1 步，或已經用過一次（用過會改名為 `/root/ha-before-shutdown-used-…`） |
| WinClient 開機出現 `no efidisk configured`、`failed to reset PCI device` | 這台 VM 原本的設定（沒有 EFI 磁碟、有 PCI 直通），`Task finished with 2 warning(s)` 仍正常啟動 |
| 關機前 PBS31 網頁登不進去，重開後正常 | 原因未確認（和 SSH 金鑰設定無關，網頁用 PAM）；再發生時用 SSH 執行 `journalctl -u proxmox-backup-proxy --since "1 hour ago" \| grep -iE "auth\|login\|fail"` 抓原因 |

## 10. 待辦

- [ ] 下次整個叢集關機時，驗證修正版（node10 正常關機、不被重開）
- [ ] 比較 10/23 晚上起的備份時間與 10/13 基準，確認 10G 網卡的效果（第 8 節）
- [x] 三台的 `/usr/local/sbin/cluster-shutdown.sh` 已換成 5-2 的修正版（10/23，`bash -n` 通過，scp 到 node11、node12）
- [ ] 修正版驗證後，刪除 node10 的 `/usr/local/sbin/cluster-shutdown.sh.bak-20261023`

## 11. 延伸閱讀

- [PVE HA 放置策略](https://kbwangtw.github.io/IT-Knowledge-Base/docs/pve/pve-ha-placement-policy/)：CRS、`ha-rebalance-on-start`、互斥規則
- [PVE 更新重開後 HA 服務卡在 error](https://kbwangtw.github.io/IT-Knowledge-Base/docs/pve/pve-ha-service-error-after-reboot/)：shutdown_policy 改為 migrate 的原因
- [Proxmox VE：High Availability](https://pve.proxmox.com/pve-docs/chapter-ha-manager.html)（watchdog、fencing、shutdown policy）
- [Ceph：維護時的 OSD 旗標](https://docs.ceph.com/en/latest/rados/operations/health-checks/)
