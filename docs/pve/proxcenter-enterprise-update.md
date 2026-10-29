---
layout: default
title: "ProxCenter 企業版更新與擴容：1.4.11 → 1.4.12 怎麼做、哪裡會踩雷"
date: 2026-10-29
categories: [PVE, ProxCenter]
permalink: /docs/pve/proxcenter-enterprise-update/
last_modified_at: 2026-10-29
---

# ProxCenter 企業版更新與擴容：1.4.11 → 1.4.12 怎麼做、哪裡會踩雷

> **一句話**：ProxCenter 企業版不能只靠 `docker compose pull`，要**重跑官方安裝腳本帶 token** 才會一起更新 compose 設定與全部映像檔；這次從 1.4.11 升到 1.4.12 成功，順便把 CT110 從 2 核 1 GB 擴到 4 核 4 GB，但**前端 Node.js 仍是 v26.12.0，低於修補版 26.12.1**，漏洞待辦還沒結案。

| 項目 | 內容 |
| --- | --- |
| 適合誰看 | 用企業版 ProxCenter（Docker Compose 安裝）、想知道怎麼更新的人 |
| 環境 | CT110（Debian 13 LXC，HA 資源，當時在 node12），`/opt/proxcenter` 下四個容器：frontend、orchestrator、postgres、weasyprint；PVE 9.2.24 三節點 |
| 日期 | 2026-10-29 |
| 結論 | ✅ 1.4.11 → 1.4.12，四個容器 healthy，DRS 設定保留 ✅ CT110 擴容：2→4 核、1→4 GB、rootfs 20→40 GB ❌ 前端 Node.js v26.12.0 未達 26.12.1 ⏳ 清舊 docker 映像檔、追蹤下一版 |

> 本文不記錄 token、密碼、IP；token 一律由人在主機上輸入，不貼到任何對話或文件。

## 1. 先認識幾個名詞

| 名詞 | 白話解釋 |
| --- | --- |
| **企業版／社群版** | 兩種安裝方式。社群版升級是 `docker compose pull` 再 `up -d`；企業版要重跑安裝腳本並帶 token |
| **安裝腳本** | ProxCenter 官方的一行安裝／升級指令，企業版升級時會保留資料庫、設定、金鑰與 proxy，只重建環境有變的容器 |
| **docker compose** | 用一個設定檔同時管理多個容器；這次的設定檔在 `/opt/proxcenter` |
| **migration** | 升級後自動執行的資料庫結構更新；1.4.12 有 15 個，官方說明都是新增欄位或表 |
| **DRS** | ProxCenter 的負載平衡建議功能，這次確認更新後設定沒被重設 |
| **Task Center** | ProxCenter 畫面下方的工作清單，會列出 Rolling Update 等執行紀錄 |
| **pre-flight** | 安裝腳本一開始的環境檢查，會警告 CPU、記憶體、磁碟不足 |

## 2. 流程全貌

```text
① 更新前確認：目前版本、授權、metrics 保留、退路
        │
        ▼
② 在 CT110 執行安裝腳本（輸入 token，不顯示）
        │   pre-flight → 驗證 token → 登入 registry → 設定 → 下載映像檔 → 重啟服務
        ▼
③ 驗收：四個容器 healthy、DRS 設定、Inventory、PBS、授權、Node 版本
        │
        ▼
④ 依 pre-flight 的警告擴充 CT110（記憶體、CPU、磁碟）
```

## 3. 步驟一：更新前確認

**做什麼**：先弄清楚現況，再決定怎麼更新。

| 檢查 | 結果 |
| --- | --- |
| 右上角通知鈴 | `A new version v1.4.12 is available` |
| 目前版本 | 安裝腳本 pre-flight 顯示 `Installed 1.4.11` |
| 安裝方式 | 企業版 |
| 容器 | frontend、orchestrator、postgres、weasyprint 四個都 healthy |
| 前端映像檔 | 執行中的是 10/06 建立的 `e231971ce488`；本機另有一個先前只 pull 下來、**沒有套用**的新 frontend 映像檔，orchestrator 與 weasyprint 還是約 3 週前的舊版 |
| 前端 Node.js | `docker exec proxcenter-frontend node -v` → **v26.10.0** |

依專案 Releases 頁的摘要（我沒有逐版讀原文），升級前後值得注意的：

| 版本 | 重點 |
| --- | --- |
| v1.4.12（10/19） | 兩個映像檔修補 zlib、`golang.org/x/net`、Next.js、sharp 等；**15 個 migration**，啟動時自動執行；**metrics 歷史預設只保留 14 天**，要更久得到 Settings → Alert thresholds 調整 |
| v1.4.8 | 企業版要**重跑一次安裝腳本**，因為 `docker compose pull` 不會更新 compose 設定，`.env` 要多一個 `GHCR_TOKEN` |
| v1.4.6 | **過期的企業版授權會被拒絕**，功能退回社群版 |

**更新前還要做的**：

| 項目 | 說明 |
| --- | --- |
| 確認授權有效 | 企業版功能有啟用即可（本案確認有啟用） |
| 想清楚 metrics 保留 | 需要超過 14 天才要調；本案決定**維持預設，不調整** |
| 快照 | 建議先 `pct snapshot 110 pre-update-<日期>`。**本次沒有拍**；退路是 PBS 每晚的 CT110 備份（更新前最近一份是 10/28 21:05） |
| 沒有進行中的工作 | 滾動更新、搬移進行中不要更新 ProxCenter |

> ⚠️ **不要在只 pull 了 frontend 之後直接 `docker compose up -d`**：這樣只會換前端，變成「新前端 ＋ 舊 orchestrator」，而前端與 orchestrator 各自在啟動時跑 migration，版本混搭有風險。企業版請用安裝腳本。

## 4. 步驟二：執行更新

**做什麼**：在 CT110 的 console（PVE 網頁 → CT110 → Console）重跑企業版安裝腳本。

**怎麼做**：

```bash
read -rsp 'ProxCenter enterprise token: ' T; echo
curl -fsSL https://proxcenter.io/install/enterprise | bash -s -- --token "$T"
unset T
```

| 片段 | 意思 |
| --- | --- |
| `read -rsp` | 輸入 token 時**畫面不顯示**，也不會留在 shell history |
| `curl … \| bash -s -- --token "$T"` | 官方的標準做法，把 token 以參數帶給腳本 |
| `unset T` | 用完立刻清掉變數 |

> 直接把 token 打在指令列上也能跑，但會被記進 `~/.bash_history`，畫面截圖也會露出；不要這樣做。想更謹慎，可先 `curl -fsSL https://proxcenter.io/install/enterprise -o /root/pc-install.sh`，看過內容再執行。若 `.env` 有釘版本，腳本會重設成 latest，需要再帶 `--version`；檢查時只看版本那幾行，不要把整個 `.env` 印出來（裡面有金鑰）。

**應該看到什麼**（pre-flight）：

| 項目 | 畫面 |
| --- | --- |
| System | Debian 13（trixie）、amd64 ✅ |
| CPU／RAM | ⚠️ `2 vCPU · 1 GB`，建議 2 GB |
| Disk | ⚠️ `/var/lib/docker` 剩 **3.6 GB**，建議 10 GB |
| Port 3000 | 已由 ProxCenter 使用 ✅ |
| Internet | `ghcr.io`、`proxcenter.io` 可連 ✅ |
| Docker | 29.8.2 ✅ |
| Upgrade | `existing installation in /opt/proxcenter`、`Installed 1.4.11`、`Kept database, settings, secrets, proxy` |

接著依序是 Validating token、Docker、Signing in to registry、Configuring ProxCenter、**Pulling images**、**Restarting services**。更新期間 ProxCenter 網頁打不開；**不要關掉 console 分頁**，磁碟只剩 3.6 GB，若出現 `no space left on device` 就停下來看狀況，不要自己 `docker system prune`。

**看到的結果**：更新成功，版本 **v1.4.12**。

## 5. 步驟三：驗收

在 CT110 的 console：

```bash
cd /opt/proxcenter && docker compose ps
```

| 檢查 | 結果 |
| --- | --- |
| 四個容器 | frontend、orchestrator、postgres、weasyprint 都是 `Up … (healthy)` ✅ |
| 版本 | v1.4.12 ✅ |
| 右上角通知 | 「new version」提示消失 ✅ |
| DRS → Configuration | DRS enabled、Manual（Recommendations only）、VMs＋LXC 都勾，**設定沒有被重設** ✅ |
| Inventory | 三台 PVE、15 個客體、PBS31 150 個備份 ✅ |
| Task Center | 當天兩輪 Rolling Update 都是 `2/2 Done` ✅ |
| 授權 | 企業版功能有啟用 ✅ |
| metrics 保留 | 維持預設 14 天（決定不調整） |
| **前端 Node.js** | `docker exec proxcenter-frontend node -v` → **v26.12.0**，**低於修補版 26.12.1** ❌ |

右下角有個紅色 `1 error`。**推測**是 Task Center 裡 10/24 故意取消的那一筆 `1/2 Cancelled`（見[兩輪更新第 12-5 節](https://kbwangtw.github.io/IT-Knowledge-Base/docs/pve/proxcenter-ceph-rolling-update/)）；清單只列了 50 筆中的 7 筆，**沒有逐筆確認**。

**為什麼 Node 沒變**：1.4.12 的更新紀錄沒有提到 Node.js 升級，而且 10/19 發布，早於 10/21 的 Node 漏洞公告。漏洞背景與其他主機的處理見 [Node2Shell 與 LiteLLM 檢查](https://kbwangtw.github.io/IT-Knowledge-Base/docs/pve/node2shell-litellm-check/)。1.4.12 仍然值得更新（其他套件的安全修補），但**不能因此把 Node 待辦打勾**。

## 6. 步驟四：擴充 CT110 的資源

**做什麼**：pre-flight 警告記憶體與磁碟不足，更新穩定後擴容。

**更新前的設定**（node12 的 Shell）：

```bash
pct config 110 | grep -E '^(cores|memory|swap|rootfs)'
pvesm status | grep VM_Pool
```

| 項目 | 看到 |
| --- | --- |
| CPU／記憶體／swap | 2 核、1024 MB、512 MB |
| rootfs | `VM_Pool:vm-110-disk-0`，20 GB |
| Ceph `VM_Pool` | 使用率約 21%，可用約 1.35 TiB |

**怎麼做**：

```bash
pct set 110 --memory 4096 --cores 4
pct resize 110 rootfs +20G
```

| 片段 | 意思 |
| --- | --- |
| `pct set 110 --memory 4096 --cores 4` | 記憶體上限 4 GB、CPU 上限 4 核；**執行中的 LXC 立即生效，不用重開機** |
| `pct resize 110 rootfs +20G` | rootfs 加大 20 GB；只能加大不能縮小；Ceph RBD 可線上擴 |

**看到的結果**（node12）：`cores: 4`、`memory: 4096`、`swap: 512`、`rootfs: …size=40G`。

**容器內驗收**：

| 指令 | 結果 |
| --- | --- |
| `free -m` | Mem 4096 MB、available 3791；Swap 512 MB、已用 221 |
| `nproc` | 4 |
| `df -h /` | `/dev/rbd3` 40G、已用 16G、可用 22G（43%）；`/var/lib/docker` 同一個裝置 |
| `docker compose ps` | 四個容器仍是 healthy |

Swap 已用的 221 MB 是原本 1 GB 記憶體吃緊時被換出去的，擴容後不會自動換回；可用記憶體還很多，不影響使用。

> 沒有快照時擴容反而單純；若有快照，要先驗收、刪除快照再擴磁碟，否則之後回滾到快照會牽涉磁碟大小不一致（本案沒有實測）。

## 7. 常見問題

| 現象 | 怎麼辦 |
| --- | --- |
| 只 pull 了 frontend 就想 `docker compose up -d` | 不要。會變成新前端搭舊後端；企業版用安裝腳本更新 |
| pre-flight 警告 CPU／RAM、磁碟不足 | 更新能跑，但建議擴容（第 6 節）；磁碟不足時 pull 可能失敗 |
| 更新時 `no space left on device` | 先停下來，不要 `docker system prune`；更新成功後再 `docker image prune` |
| token 要怎麼輸入 | 用 `read -rsp`，不要直接打在指令列、不要貼給別人 |
| 右下角 `1 error` | 先看 Task Center 有沒有紅色項目；可能只是 10/24 故意取消的那一筆 |
| 更新後 metrics 少了 | 1.4.12 預設只留 14 天，到 Settings → Alert thresholds 調高 |
| `pct resize` 後 `df` 沒變大 | 檔案系統沒跟著長，先看輸出，不要重打 `pct resize`（本案正常，沒有發生） |

## 8. 待辦

- [ ] 追蹤 ProxCenter 下一版，**前端 Node.js 要 ≥ v26.12.1**；有新版時先看 Releases 有沒有提到 Node 升級，更新後用 `docker exec proxcenter-frontend node -v` 確認（已排 11/05 提醒）
- [ ] 穩定 3～5 天後清舊 docker 映像檔：先 `docker system df` 看可回收量，再 `docker image prune`（只清沒標籤的）；不要用 `docker system prune`
- [ ] 確認右下角 `1 error` 是不是 10/24 取消的那一筆
- [ ] 決定要不要把 metrics 保留天數調到 14 天以上（目前維持預設）

## 9. 延伸閱讀

- [ProxCenter 逐台更新 PVE：三個卡關點怎麼排除？](https://kbwangtw.github.io/IT-Knowledge-Base/docs/pve/proxcenter-ceph-rolling-update/)（同日用 ProxCenter 更新 PVE 三台的紀錄，第 13 節）
- [Node2Shell 與 LiteLLM 供應鏈攻擊：檢查環境有沒有中](https://kbwangtw.github.io/IT-Knowledge-Base/docs/pve/node2shell-litellm-check/)
- [PVE HA 放置策略](https://kbwangtw.github.io/IT-Knowledge-Base/docs/pve/pve-ha-placement-policy/)（DRS 開啟與 Wazuh 搬移）
- [ProxCenter UI（GitHub）](https://github.com/adminsyspro/proxcenter-ui)、[Releases](https://github.com/adminsyspro/proxcenter-ui/releases)
