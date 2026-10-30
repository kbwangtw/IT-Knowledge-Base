---
layout: default
title: "jt-ipam 導入紀錄：從 IP 掃描到 PVE、LibreNMS 與機櫃管理"
last_modified_at: 2026-10-29
---

# jt-ipam 導入紀錄：從 IP 掃描到 PVE、LibreNMS 與機櫃管理

> **一句話**：用開源的 jt-ipam 把「網路上有哪些 IP、哪台機器、放在哪個機櫃」集中管理，並和 PVE、LibreNMS、Wazuh、Graylog 串起來。

| 項目 | 內容 |
| --- | --- |
| 適合誰看 | 想了解 IP 位址管理（IPAM）怎麼導入的人；要維護這套 jt-ipam 的人 |
| 部署 | PVE 叢集上的 Debian 13 LXC，HTTPS 網頁 |
| 版本 | 2026-10-15 由 v0.6.19 升級到 v1.0.11；2026-10-29 升級到 v1.0.16 |
| 進度 | 依官方 Adoption Roadmap：掃描、PVE、LibreNMS、Graylog 已完成；機櫃 U 位待實機確認 |

公開文件不記錄密碼、Token Secret、私鑰或完整憑證。

## 1. 先認識幾個名詞

| 名詞 | 白話解釋 |
| --- | --- |
| **IPAM** | IP Address Management，IP 位址管理：記錄每個 IP 給了誰、哪些還空著 |
| **Subnet（子網路）** | 一段連續的 IP 範圍，例如一個辦公室 LAN |
| **Scan Agent** | 定期掃描網路、找出有哪些主機在線上的程式 |
| **ICMP／ARP／PTR** | 三種找主機的方法：ping、查 MAC 位址、用 IP 反查主機名稱 |
| **API Token** | 讓兩套系統互相讀資料的「通行證」，比直接給帳號密碼安全 |
| **Stale data** | 過期的資料，例如已經刪掉的機器還留在清單上 |

## 2. 導入進度總覽

| 階段 | 內容 | 狀態 |
| --- | --- | --- |
| Phase 0 | 安裝、安全與基本環境 | 部分完成 |
| Phase 1 | IP／Subnet 規劃 | 基本架構完成 |
| Phase 2 | 掃描探索（Discovery／Scan） | ✅ 已完成並持續運作 |
| Phase 3 | 外部系統整合 | ✅ PVE、LibreNMS、Graylog 已完成 |
| Phase 4 | 機房、機櫃與設備 | 建檔中，U 位待實機確認 |
| Phase 5 | 維運、自動化 | 待進行 |

## 3. 已完成的部分

### 3-1 網路與掃描

- 建立 ITBH-Network，納管主要 LAN 與 PVE Cluster Network。現場沒有 VLAN，所以**不建立虛構的 VLAN 資料**。
- 本機 Scan Agent 啟用 ICMP、ARP L2 與 Reverse PTR 探索，可以找到 LAN 上的主機、取得部分主機名稱與 MAC，用來和人工維護的資料比對。

### 3-2 Proxmox VE 整合

- 使用**獨立的唯讀 API 帳號與 Token** 整合三節點叢集。
- 初次同步遇到 HTTP 401（認證失敗）：直接驗證 PVE API、重新保存認證資訊後恢復。實測 PVE API 版本 9.2.20 / release 9.2。
- PVE 的 VM／容器主要顯示在 **Virtualization 視角**；一般 Device 清單沒出現相同資料，**不代表整合失敗**。

### 3-3 LibreNMS 整合

- 透過 API 讀取 Device、ARP、鄰居與上線狀態，供 jt-ipam 比對。
- 同一台 VM／容器可能**同時**出現在 Virtualization 和 Device：前者是「虛擬化資產」，後者是「監控視角」，不要只因名稱相同就刪掉其中一筆。

### 3-4 Graylog 整合（2026-10-15）

jt-ipam 提供「IP → 主機名稱（全域）」對照表，Graylog 每 5 分鐘下載一次，自動替日誌裡的 IP 補上主機名稱。設定、憑證信任與規則見 [把 PVE、PBS 與 NAS 的日誌集中到 Graylog](https://kbwangtw.github.io/IT-Knowledge-Base/docs/pve/proxmox-graylog-syslog-pipeline-sop/) 第 6 節。

> 權杖 365 天到期（**2027-10-15**），到期前要重新產生並更新 Graylog Data Adapter 的網址（已排入 Google Calendar 2027-10-01）。

## 4. 升級到 v1.0.11（2026-10-15）

**為什麼升級**：Graylog 整合 v1.0 才有。

**官方做法**：在容器內執行升級腳本，它會依序做 git pull → 備份 → 安裝相依套件 → 資料庫結構更新（alembic）→ 建置前端 → 重啟；完成後用 `doctor` 檢查。0.5.170 以前的版本要執行兩次，本案不需要。

```bash
bash /opt/jt-ipam/scripts/jt-ipam.sh upgrade
bash /opt/jt-ipam/scripts/jt-ipam.sh doctor
```

| 步驟 | 內容 |
| --- | --- |
| 1. 檢查 | 容器 4 核／8 GB（官方最低 2 核／4 GB，建置前端峰值約 1.6 GB）；`git status` 沒有本機修改 |
| 2. 快照 | `pct snapshot <CTID> pre-v1-upgrade` |
| 3. 升級 | 第一次停在 `Building frontend…`，錯誤 `FATAL: pnpm is required to build the frontend` |
| 4. 原因 | 腳本已把 pnpm 裝到 `/usr/local/bin`，但用 `pct enter` 進入的 shell，PATH 只有 `/sbin:/bin:/usr/sbin:/usr/bin`，找不到 |
| 5. 修正 | `export PATH=/usr/local/sbin:/usr/local/bin:$PATH` 後重跑 upgrade（加 `2>&1 \| tee /root/upgrade-<時間>.log` 留紀錄），從建置前端繼續完成 |
| 6. 驗收 | doctor 顯示 No problems；前後端都是 1.0.11、資料庫結構最新、nginx WebSocket 與 geoip／oui／recog 更新排程已安裝；同步無錯誤、Wazuh Agent 18 筆、網頁正常 |
| 7. 收尾 | doctor 全部通過後，同日刪除升級前快照 |

> ⚠️ **用 `pct enter` 進容器執行安裝或升級腳本前，先補 PATH**（上面第 5 步），或進去後先 `su -` 載入完整的登入環境。

- 升級中途失敗時，doctor 會顯示「frontend build is 0.6.x but backend is 1.0.x」和缺少的排程，照 `→` 的提示重跑 upgrade 即可。
- `perl: warning: Setting locale failed` 是容器沒有產生 en_US.UTF-8 語系，和升級無關。

### 4-1 2026-10-29：升級到 v1.0.16

**為什麼**：版本落後 v1.0.12～v1.0.16 共五版，順便確認 Node.js 22.23.4 的建置環境。

**升級前確認**：

| 項目 | 結果 |
| --- | --- |
| 快照 | `pct snapshot 103 pre-update-20261029`（15:11） |
| 本機有沒有改過檔案 | `git -c safe.directory=/opt/jt-ipam status --short` **沒有輸出** |
| 記憶體、swap、磁碟 | 8 GB（已用約 1 GB）、swap 2 GB、根目錄 40 GB（已用 4.4 GB） |
| PATH | 用 `pct enter` 進容器的 shell 只有 `/sbin:/bin:/usr/sbin:/usr/bin`，**先補** `export PATH=/usr/local/sbin:/usr/local/bin:$PATH`；`command -v pnpm` 要看得到 `/usr/local/bin/pnpm` |

`git status` 直接執行會出現 `fatal: detected dubious ownership in repository at '/opt/jt-ipam'`：`/opt/jt-ipam` 的擁有者不是 root，git 為了安全拒絕操作，不代表有人改過檔案。**不要照提示執行 `git config --global --add safe.directory`**（會寫進 root 的全域設定），用 `git -c safe.directory=… status` 做一次性放行即可。

**升級**（同一個 console 視窗，不要中途換視窗）：

```bash
bash /opt/jt-ipam/scripts/jt-ipam.sh upgrade 2>&1 | tee /root/upgrade-$(date +%Y%m%d-%H%M).log
bash /opt/jt-ipam/scripts/jt-ipam.sh doctor
```

**看到的結果**：

| 輸出 | 意思 |
| --- | --- |
| `✔ built in 14.80s`、黃字 `Some chunks are larger than 500 kB` | 前端建置只花 15 秒；黃字是 vite 的提示，不是錯誤 |
| `Backend is answering …/api/v1/system/version`、`Ping tool: ready` | 後端重啟後有回應，有權限送 ping |
| `Local scan agent already registered; leaving it as is.` | 本機掃描 agent 沒被動到，仍在跑 |
| `Upgrade complete: 1.0.16 (2de826f2) -> 1.0.16 (2de826f2)  alembic 0231_warroom_intel (head)` | 升級完成；資料庫 migration 到 0231 |
| 結尾的 `SECURITY HEADERS` 長段說明 | 腳本的通用提醒：若在它前面另外放反向代理，那一層也要設相同的安全標頭；**本環境前面有沒有另外的代理未確認** |

升級前是 v1.0.11，輸出卻是 `1.0.16 -> 1.0.16`，**推測**是腳本先 `git pull`，之後顯示的「舊版」已是更新後的檔案，只是顯示問題；實際以 `doctor` 為準。

**`doctor`：All checks passed**。重點項目：

| 區塊 | 結果 |
| --- | --- |
| Services | backend、nginx running；`/healthz` 有回應；HTTPS 端到端 HTTP 401（沒登入打 API 的正常回應）；WebSocket 轉發正常；guacd 1.6.1-pre.d9ec474（build 4）在 127.0.0.1:4822 回應 |
| Database | PostgreSQL 17、pgvector、稽核表權限正確、schema 在 head（`0231_warroom_intel`） |
| Frontend | 前後端版本一致（1.0.16）；建前端用 Node.js **v22.23.4** |
| Scheduled work | sync、ai-audit、backup、geoip、oui、recog 六個 timer 都 enabled；最新備份 `jt-ipam-2026-10-29.jtbak`（加密備份）；last sync run completed |
| Scanning／Remote console | 本機 scan agent running；RDP 引擎 guacd |

升級紀錄用 `grep -inE 'error|fatal|fail' /root/upgrade-*.log` 檢查：今天的紀錄只比對到**檔名含 error**（`test_ldap_tls_and_errors.py`、`wsError-….js`），沒有 `FATAL`；10/15 的紀錄裡有當時的 pnpm 失敗與 locale 警告（已知）。

**這五版和我們有關的變更**（依專案 CHANGELOG 的摘要，我只讀到前面一小部分，升級前請自己再對照最新版說明）：

| 版本 | 重點 |
| --- | --- |
| v1.0.12～v1.0.16 | 共 17 個資料庫 migration（0215～0231），腳本自動執行 |
| v1.0.12 | 每日備份資料夾改為只有 root 可讀；備份腳本記錄目錄總大小 |
| v1.0.13 | 自動分配 IP 會跳過保留與 DHCP 範圍；LibreNMS 離線或停用的設備不再餵給 ARP／MAC 表；不再附 `jt-ipam-worker.service`；本機帳號不再需要 email |
| v1.0.16 | **通知矩陣改成每個聊天頻道各自勾選**，原本的通知路由可能改變 |
| Graylog | 這幾版的紀錄沒有提到 Graylog 變更 |

**回滾**（只有升級失敗到無法補救才用）：`pct rollback 103 pre-update-20261029`，整個回到快照當時的狀態，包含資料庫。

**升級後一天的確認**（2026-10-30）：

| 項目 | 結果 |
| --- | --- |
| 網頁與儀表板 | ✅ 左上角 v1.0.16、能登入；裝置 28、虛擬化 15（與 PVE 的 15 個客體一致）、已配發 IP 44；IP 指示計上線 28、離線 16、未知 0（來源：掃描代理＋LibreNMS 綜合判定） |
| 離線 16 台 | ✅ **都是家裡的手機**（使用者確認），不是設備異常 |
| 03:30 加密備份 | ✅ `last-run`：`status=ok`、`exit_code=0`、`encrypted=1`、`finished_at=2026-10-30T03:32:07+08:00`；`jt-ipam-2026-10-30.jtbak` 1.3 MB、權限 `-rw------- root` |
| 10/29 的備份檔 | `jt-ipam-2026-10-29.jtbak` 時間是 15:19：升級腳本升級前先做備份，**同一天檔名相同而覆蓋**了凌晨 03:30 的那份，所以它是升級前（v1.0.11）的狀態 |
| 通知鈴的 2 則 | 都是 **6 天前（約 10/24）**的「代理失聯：IPAM（scan）」與「代理已恢復回報」，**不是這次升級造成的**；失聯那則寫最後一次回報是 314 分鐘前，原因未確認（只確認已恢復） |
| 快照 | 備份確認正常後，`pre-update-20261029` 已刪除（CT103 只剩 `pre-restart-20261025`） |
| **仍待確認** | 通知矩陣設定有沒有被改變（v1.0.16 起每個聊天頻道各自勾選）、Graylog 的 Lookup Table 是否仍每 5 分鐘更新 |

通知鈴那則訊息值得記住：掃描代理失聯時，**它負責的網段完全沒有在掃描，畫面上不會有任何異狀，資料只是停在原地**；所以代理失聯的通知要確實送到你看得到的地方（通知矩陣）。

## 5. 每日備份加密（2026-10-15）

**為什麼要做**：jt-ipam 每天 03:30 備份到 `/var/backups/jt-ipam/`（保留 14 天）。沒加密時，每份備份同時含資料庫和 `backend.env`，而 `backend.env` 正是解開資料庫裡 PVE、LibreNMS、Wazuh 憑證的鑰匙。備份檔一旦外流，等於所有憑證外流。

**怎麼做**：網頁「**管理 → 系統設定 → 每日備份加密**」設定密碼（至少 12 字元，存在密碼管理器、不放本機）。之後每日備份變成單一檔案 `jt-ipam-<日期>.jtbak`（AES-256-GCM 加密），明文目錄自動移除。

**驗證**（一定要測能不能解開，否則等於沒有備份）：

```bash
systemctl start jt-ipam-backup.service
cat /var/backups/jt-ipam/last-run          # 應為 status=ok、encrypted=1
/opt/jt-ipam/backend/.venv/bin/python /opt/jt-ipam/backend/app/services/backup_crypt.py decrypt \
  /var/backups/jt-ipam/jt-ipam-<日期>.jtbak --out /root/restore-test   # 會詢問密碼
ls -lh /root/restore-test/*/               # 應有 .dump、backend.env、tls.tar.gz、uploads.tar.gz
rm -rf /root/restore-test                  # 解出來的是明文，測完立刻刪除
```

**結果**：手動備份 `encrypted=1`、1.3 MB；解密測試成功後，刪除加密前留下的 14 個明文備份目錄：

```bash
find /var/backups/jt-ipam -maxdepth 1 -type d -name '2026-*' -exec rm -rf {} +   # 只刪日期目錄，不動 .jtbak
```

**保護範圍**：加密保護的是「備份檔被複製到別處」的情況；拿到容器 root 的人仍然可以直接讀 `/etc/jt-ipam/backend.env`。PBS 對整個容器的備份仍含 `backend.env`，依 PBS 保留規則輪替；PBS 備份本身是否加密另行評估。

## 6. 機房與機櫃

已建立 Location `ITBH Server Room` 與 12U `Rack-01`，預計納管三台 PVE 主機、兩台 Synology NAS、兩台交換器與兩片層板。

**刻意先不填最終 U 位**：非標準機架的設備會放在層板上，要等機櫃到貨，依實際尺寸、層板位置、散熱與線材空間再決定。

> 層板的 U 位代表「設備底部的支撐位置」，不是設備頂部。

## 7. 待辦與下一步

| 項目 | 說明 |
| --- | --- |
| 備份還原驗證 | 完成 jt-ipam 設定與資料的備份／還原驗證 |
| 清理過期資料 | IP、Device、Virtualization 三個視角的 stale data |
| IP 管理規則 | 固定 IP、保留 IP 與動態 Client 的規則 |
| 機櫃 U 位 | 機櫃到貨後補上設備與層板位置 |
| LibreNMS Token | jt-ipam 使用的 LibreNMS Token 屬於 admin 且不過期，評估改用權限較小的帳號（見戰情中心（二）） |
| 自動化 | 之後再評估告警、異常偵測、IP 申請等 |
| 升級後確認（2026-10-29） | 備份已確認、快照已刪；仍待確認通知矩陣與 Graylog Lookup Table；清理 `/root/upgrade-*.log`（見 4-1） |

**導入原則**：目前已把 Scan Agent 的實際網路狀態、PVE 的虛擬化資產和 LibreNMS 的監控資料串起來。下一階段優先確保**資料可信、來源可追蹤**，再擴大自動建立與自動化。

## 8. 延伸閱讀

- [jt-ipam Adoption Roadmap](https://jasoncheng7115.github.io/jt-ipam/adoption.html)（官方導入路線圖）
- [jt-ipam GitHub](https://github.com/jasoncheng7115/jt-ipam)、[jt-ipam 官方文件](https://jasoncheng7115.github.io/jt-ipam/)
- [把 PVE、PBS 與 NAS 的日誌集中到 Graylog](https://kbwangtw.github.io/IT-Knowledge-Base/docs/pve/proxmox-graylog-syslog-pipeline-sop/)：Graylog 整合
- [用 Grafana 建立戰情中心（二）：接上 LibreNMS](https://kbwangtw.github.io/IT-Knowledge-Base/docs/pve/grafana-war-room-librenms/)
