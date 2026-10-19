---
layout: default
title: "把 PVE、PBS 與 NAS 的日誌集中到 Graylog"
date: 2026-09-17
categories: [PVE, Graylog, Syslog]
permalink: /docs/pve/proxmox-graylog-syslog-pipeline-sop/
last_modified_at: 2026-10-19
---

# 把 PVE、PBS 與 NAS 的日誌集中到 Graylog

> **一句話**：把散在各台主機上的日誌（log）全部送到同一台 Graylog，讓你在一個畫面搜尋、看統計，出問題時自動寄 Email 通知。

| 項目 | 內容 |
| --- | --- |
| 適合誰看 | 第一次接觸「集中式日誌」與 Graylog 的人；或要維護這套環境的人 |
| 收集對象 | PVE 三台節點（node10～12）、PBS31、兩台 Synology NAS（tokyo16、melayu17） |
| 環境 | Graylog 7.1.9，裝在 PVE 叢集上的 LXC 容器（CT 105，Debian 12） |
| 目前狀態 | 收集、分類、主機名稱查表、14 個 Email 告警都已運作並驗證；Graylog 本身也有監控（11-6）；看板與信件格式仍待改善（見第 14 節） |
| 紀錄期間 | 2026-09-17 起陸續建置，最後更新 2026-10-19 |

**這篇怎麼讀**：

- 第一次接觸：先讀第 1～3 節，弄懂名詞、全貌和目前狀態。
- 要動手做某件事：直接跳到對應章節，每一節都有「做什麼 → 怎麼做 → 應該看到什麼」。
- 出了問題：先看第 13 節「常見問題與踩雷」。

告警的詳細實測過程另有一篇：[PVE 告警實測紀錄（更新至 2026-09-22）](https://kbwangtw.github.io/IT-Knowledge-Base/docs/pve/graylog-pve-alert-validation-2026-09-18/)。

## 1. 先認識幾個名詞

| 名詞 | 白話解釋 |
| --- | --- |
| **日誌（log）** | 系統自動寫下的流水帳，例如「幾點幾分，誰登入失敗」「備份工作結束」 |
| **Syslog** | 傳送日誌的標準格式與方法，幾乎所有 Linux 和網路設備都支援 |
| **rsyslog** | Linux 上負責「把日誌轉送出去」的程式 |
| **UDP** | 一種網路傳送方式：只管送出、不確認對方有沒有收到。速度快，但**接收端停機時，那段期間的日誌就會遺失** |
| **Graylog** | 收集、儲存、搜尋日誌的平台，也能依條件寄送告警 |
| **Input** | Graylog 的「收件口」，例如「用 UDP 1514 收 Syslog」 |
| **Stream** | 把相關訊息歸在同一個「資料夾」，例如「基礎設施的 Syslog」 |
| **Pipeline** | 一串處理規則，替每筆訊息分類、拆出欄位（例如「這是哪一台」「是不是任務失敗」） |
| **Stage** | Pipeline 裡的「關卡」，依編號 0、1、2… 依序處理 |
| **Rule** | 放在 Stage 裡的單一規則：「當（when）符合條件，就（then）做某件事」 |
| **欄位（field）** | 從訊息拆出來的資料，例如 `source`（來源主機）、`pve_task_status`（任務結果）。有了欄位才能精準搜尋與統計 |
| **Index Set** | 決定訊息存在哪一組資料庫索引，以及保存多久 |
| **Event Definition** | 告警的「觸發條件」，例如「每 5 分鐘查一次，有任務失敗就產生事件」 |
| **Notification** | 事件發生時「怎麼通知」，本環境都是寄 Gmail |
| **Grace Period** | 冷卻時間：同一個告警在這段時間內只寄一封，避免信箱被灌爆 |
| **Backlog** | 通知信裡附上幾筆觸發告警的原始訊息 |
| **Lookup Table** | 對照表，例如「IP → 主機名稱」，讓 Graylog 自動替訊息補上資料 |

## 2. 全貌：日誌從哪裡來、到哪裡去

```text
【來源】                           【Graylog】
PVE node10／11／12 ─┐
                    ├─ UDP 1514 → Input「Syslog UDP」→ Stream「Infrastructure Syslog」
PBS31 ──────────────┘                  → Pipeline「Infrastructure Syslog」（分類、補主機名稱）
                                       → 存入 infra_syslog 索引

tokyo16、melayu17 ── UDP 1515 → Input「Synology Syslog UDP」→ Stream「Synology Syslog」
                                       → Pipeline「Synology Syslog」（解析登入、丟棄雜訊）
                                       → 存入預設索引 graylog_*

                    ↓ 存好的訊息可以：
                    ├─ 搜尋、看「PVE 任務監控」看板
                    └─ 由 14 個 Event Definition 檢查 → 符合條件 → Gmail 告警
```

另外，PVE 節點上有兩支**監控腳本**，每 1 分鐘、每 5 分鐘檢查一次節點和儲存空間，有異常就寫一筆日誌，再由 Graylog 告警（第 11-3 節）。

| 來源 | 送到哪裡 | 設定方式 | 章節 |
| --- | --- | --- | --- |
| PVE node10～12 | UDP 1514 | rsyslog | 4-1 |
| PBS31 | UDP 1514 | rsyslog（需先安裝） | 4-2 |
| tokyo16、melayu17 | UDP 1515 | DSM 記錄中心的「記錄傳送」 | 4-3 |

Infrastructure Syslog 的實際索引名稱是 `infra_syslog_0`（Index Set `infra_syslog` 底下的第一個索引）。

## 3. 目前做到哪裡

| 範圍 | 狀態 |
| --- | --- |
| 收集 | ✅ 三台 PVE、PBS31（10/08 加入）、兩台 NAS 都已確認收到 |
| 分類（Pipeline） | ✅ 主機、服務、任務、認證、系統錯誤分類；PBS 識別；NAS 登入解析 |
| 主機名稱查表 | ✅ 10/15 接上 jt-ipam，訊息中的 IP 自動補上 `src_host` |
| 雜訊過濾 | ✅ 10/16 丟棄 PBS 讀取 NAS 產生的大量紀錄，tokyo16 每天少了約 7 萬筆 |
| 告警 | ✅ 14 個告警運作中，全部寄 Gmail；10/16 盤點並修正 3 項設定；10/19 加入「每日健康回報」 |
| 監控 Graylog 本身 | ✅ 10/19 三台 PVE 每 5 分鐘從外部檢查，異常直接用 postfix 寄信；每日 08:00 健康回報驗證整條告警鏈（11-6） |
| NAS 快照複寫 | ✅ 10/19 複寫失敗、停止由 tokyo16 DSM 寄信；兩台 NAS 是否回應由三台 PVE 每 5 分鐘檢查（11-7） |
| 備份 | ✅ PVE 備份、PBS GC／Verify 失敗本來就會寄信；10/19 加上每天 08:30 檢查每台 VM／CT 的最新備份與驗證結果（11-8） |
| 看板 | 🔶「PVE 任務監控」八個 Widget 保留；整體基礎設施看板待完善 |
| 告警信格式 | 🔶 預設格式難判讀，改為中文範本列入待辦 |

> 驗證的界線：告警都以 `logger` 產生的「合成測試訊息」驗證過完整鏈路（訊息 → 分類 → 事件 → 收到信），**沒有為了測試去弄壞真正的 VM、容器或 Ceph**。

## 4. 第一步：把日誌送進 Graylog

### 4-1 PVE 三台節點

**做什麼**：讓每台 PVE 把自己的日誌轉送給 Graylog。

**怎麼做**：在每台節點建立轉送設定（`192.0.2.24` 是文件示範位址，請換成自己的 Graylog）：

```bash
cat > /etc/rsyslog.d/60-graylog.conf <<'EOF'
# Forward PVE syslog messages to Graylog
*.* @192.0.2.24:1514
EOF
```

| 寫法 | 意思 |
| --- | --- |
| `*.*` | 所有類別、所有等級的日誌 |
| `@` | **一個** @ 代表用 UDP 送；兩個 @@ 才是 TCP |
| `:1514` | Graylog Input 的連接埠 |

先檢查語法，**沒錯才重啟**（語法錯誤會讓 rsyslog 起不來）：

```bash
rsyslogd -N1
systemctl restart rsyslog
systemctl status rsyslog --no-pager
```

Graylog 那邊也要有對應的 UDP 1514 Input。

**應該看到**：在 Graylog 分別搜尋 `source:node10`、`source:node11`、`source:node12`，三台都有新訊息。只看服務顯示 running 不夠，要真的搜尋得到。

### 4-2 PBS31（2026-10-08 加入）

PBS31 是 PBS 4（Debian 13，跑在 Synology NAS 上的虛擬機），先前只有 Wazuh Agent 與 SNMP，日誌沒有送到 Graylog。它沿用 PVE 的 UDP 1514 Input 與 Infrastructure Syslog Stream，Graylog 不需要新增 Input。

**要注意**：Debian 13 預設只有 journald，**沒有裝 rsyslog**（`/etc/rsyslog.d/` 只有 postfix 套件放的 `postfix.conf`），要先安裝。操作時避開 21:00 的排程備份。

```bash
apt update                 # 企業版套件來源回報 401 可以忽略
apt install rsyslog        # 確認只有安裝、沒有移除任何套件
cat > /etc/rsyslog.d/60-graylog.conf <<'EOF'
# Forward PBS syslog messages to Graylog
*.* @192.0.2.24:1514
EOF
rsyslogd -N1               # 應顯示 End of config validation run. Bye.
systemctl restart rsyslog
systemctl is-active rsyslog; systemctl is-enabled rsyslog   # active / enabled
systemctl is-active proxmox-backup-proxy                    # active：備份服務沒受影響
logger -t GRAYLOG_TEST "PBS31 graylog forwarding test"
```

**應該看到**：Graylog 搜尋 `source:pbs31 AND GRAYLOG_TEST` 找到測試訊息；點開訊息，Received by 是 Syslog UDP 1514、Routed into streams 是 Infrastructure Syslog、存在 infra_syslog 索引。

### 4-3 Synology NAS（約 9 月底建立，10/15 補記）

兩台 NAS 的設定相同：

| 位置 | 設定 |
| --- | --- |
| DSM「記錄中心 → 記錄傳送」 | 傳送到 syslog 伺服器：Graylog 主機名稱、**UDP 1515**、格式 BSD（RFC 3164）、不用 TLS；頁面有「傳送測試日誌」按鈕 |
| Graylog Input | **Synology Syslog UDP**（監聽 0.0.0.0:1515），和 PVE／PBS 的 1514 分開 |
| Stream | **Synology Syslog**，訊息存在預設索引（graylog_*），**不在** infra_syslog |
| Pipeline | **Synology Syslog**，由 Graylog 的 Input Setup Wizard 建立（第 7 節） |

| NAS | 角色 |
| --- | --- |
| **tokyo16** | 主要檔案伺服器兼備份伺服器；PBS31 的 Tokyo16 datastore 以 SMB 掛在這台 |
| **melayu17** | tokyo16 的快照複寫目的地（最後一道防線；複寫與連線監控見 11-7） |

**應該看到**：按 DSM 的「傳送測試日誌」後，訊息出現在 Synology Syslog Stream。兩台都已確認。

### 4-4 怎麼確認真的有收到

```bash
pct exec <Graylog CTID> -- ss -ulnp | grep -E ':151[45] '   # 1514 和 1515 都由 Graylog（java）監聽
```

- Graylog 網頁的 **Inputs → 點該 Input → Input Diagnosis**：可以看到最近 15 分鐘收到幾筆、錯誤數，以及「Received Message count by Stream」（訊息進了哪個 Stream）。
- **搜尋沒結果不等於沒送到**。曾用 `source:node10 AND "UPID:"` 查最近 5 分鐘是 0 筆；放寬成 `source:node10 AND pvedaemon`、時間拉長到 15 分鐘就找到了。先放寬條件找到原始訊息，再檢查分類欄位。
- 畫面顯示 0 errors/s 只代表「當下沒有處理錯誤」，不能取代欄位抽查或告警測試。

## 5. 第二步：替訊息分類（Infrastructure Syslog Pipeline）

### 5-1 Pipeline 怎麼運作

訊息進來後，依序經過 Stage 0、1、2…。每個 Stage 有一個「**繼續條件**」，決定訊息要不要往下一關走：

| 繼續條件 | 意思 |
| --- | --- |
| None or more rules match | 不管有沒有規則符合，都繼續往下（本環境 Stage 1、2 用這個） |
| At least one rule matches | 至少一條規則符合才繼續 |
| All rules match | 全部規則都符合才繼續 |

> ⚠️ 新增規則時，要注意放進哪個 Stage。如果把「只對少數訊息成立」的規則放進「全部符合才繼續」的 Stage，大部分訊息會在那裡被擋下，後面的 Stage 都不會執行。

規則編輯頁預設是 **Rule Builder**（點選式）；要貼上下面的原始碼，按 **Use Source Code Editor**。

### 5-2 Stage 0：認出主機，標記一般事件

| 規則 | 在做什麼 |
| --- | --- |
| PVE - Identify Cluster Nodes | source 是 node10～12 時，加上 `device_type=pve`、`pve_cluster=PVE-Cluster` |
| PBS - Identify Backup Server | source 是 pbs31 時，加上 `device_type=pbs`、`pbs_server=pbs31`（10/08 新增） |
| PVE-Authentication Events | 標記認證相關訊息（`event_category=authentication`） |
| Infrastructure - System Errors | 找 DENIED、failed、error 等字樣，標記 `system_error` |

PBS 的規則：

```text
rule "PBS - Identify Backup Server"
when
    to_string($message.source) == "pbs31"
then
    set_field("device_type", "pbs");
    set_field("pbs_server", "pbs31");
end
```

存檔前先用規則頁的 **Rule Simulation**（JSON：`{"source": "pbs31", "message": "test"}`）確認會加上兩個欄位；加入 Stage 0 後再用 `logger -t GRAYLOG_TEST "PBS31 pipeline test"` 實測，`source:pbs31 AND device_type:pbs` 找得到、兩個欄位都在。

> 「System Errors」只是用文字比對做**初步分類**，看到 error 字樣不代表整個服務壞了，仍要看原始訊息。

用來測試認證與錯誤分類的訊息：

```bash
logger -p auth.info -t pam_unix "Graylog authentication pipeline test"
logger -p kern.warning -t INFRA_ERROR_TEST "DENIED Graylog infrastructure system error test"
```

訊息收到了、欄位卻沒出現，問題可能在規則本身，或 Pipeline 和 Stream 沒有連接。

### 5-3 Stage 1：服務事件（systemd）

把 systemd 的 Started、Stopped、Starting、Stopping、Reached target 訊息標記為 `event_category=service`：

```text
rule "PVE - Service Events"
when
    contains(to_string($message.message), "systemd", true)
    &&
    (
        contains(to_string($message.message), "Started", true)
        ||
        contains(to_string($message.message), "Stopped", true)
        ||
        contains(to_string($message.message), "Starting", true)
        ||
        contains(to_string($message.message), "Stopping", true)
        ||
        contains(to_string($message.message), "Reached target", true)
    )
then
    set_field("event_category", "service");
end
```

條件的意思是「**有 systemd，而且**五種事件**任一種**」。用 Source Code Editor 寫，是為了避免點選介面誤設成「五種都要同時出現」。

五種都測過：

```bash
logger -p daemon.info -t systemd "Started graylog-pipeline-test.service - Graylog Pipeline Test Service"
logger -p daemon.info -t systemd "Stopped graylog-pipeline-test.service - Graylog Pipeline Test Service"
logger -p daemon.info -t systemd "Starting graylog-pipeline-test.service - Graylog Pipeline Test Service"
logger -p daemon.info -t systemd "Stopping graylog-pipeline-test.service - Graylog Pipeline Test Service"
logger -p daemon.info -t systemd "Reached target graylog-pipeline-test.target - Graylog Pipeline Test Target"
```

### 5-4 PVE 任務：從 UPID 拆出欄位

PVE 每個工作（備份、遷移、開機…）都有一個識別碼 **UPID**，出現在 pvedaemon 的日誌裡，例如：

```text
node10 pvedaemon[4129114]: <root@pam> end task UPID:node10:00022D58:0191F4A8:6AAA40A2:vncproxy:100:root@pam: command '/usr/bin/termproxy' failed: exit code 1
```

UPID 裡依序藏著：節點、程序編號、時間、**任務名稱**（vncproxy）、**VM／CT 編號**（100）、**使用者**（root@pam）。Pipeline 把這些拆成欄位：

| 規則 | 用途 |
| --- | --- |
| PVE - Task Events | 有 pvedaemon 和 `UPID:` 的訊息，標記為 `event_category=pve_task`（只分類，不拆欄位） |
| PVE - Parse Task UPID | 拆出節點、任務、VM／CT、使用者 |
| PVE - Task Started | 任務開始 |
| PVE - Task Success | 任務成功（`end task UPID:` 而且以 `: OK` 結尾） |
| PVE - Task Warning | 任務警告 |
| PVE - Task Failed | 任務失敗（5-5 節） |

```text
rule "PVE - Task Events"
when
    contains(to_string($message.message), "pvedaemon", true)
    &&
    contains(to_string($message.message), "UPID:", true)
then
    set_field("event_category", "pve_task");
end
```

拆出來的欄位：

| 欄位 | 代表什麼 |
| --- | --- |
| `pve_event_type` | 事件類型，例如 `task_failed` |
| `pve_task_name` | 任務名稱 |
| `pve_task_node` | 執行的節點 |
| `pve_vmid` | VM／CT 編號；有些任務本來就沒有 |
| `pve_task_user` | 執行的使用者 |
| `pve_task_status` | started、success、warning 或 failed |

- 早期規則用的欄位名是 `task_status`，後來改為 `pve_task_status`，新看板要用後者。
- 本紀錄沒有保存最新版全部解析規則的原始碼，所以**不提供拼湊的「一鍵匯入」**。
- 三台都已驗證有任務訊息，node11、node12 的 pveupdate／aptupdate 也有真實成功事件。

### 5-5 「任務失敗」規則的修正過程

**9/18 第一版**：要求訊息有 `end task UPID:` 而且包含 `failed:`。當時最近 24 小時有 34 筆任務結束訊息（三台都有），但沒有失敗；延長到 7 天才找到 1 筆歷史失敗：

| 項目 | 歷史紀錄 |
| --- | --- |
| 時間 | 2026-09-16 07:09:32（原搜尋畫面時間，時區未另核對） |
| 來源 | node10 |
| 任務 | vncproxy |
| VMID | 100 |
| 結果 | `command '/usr/bin/termproxy' failed: exit code 1` |

搜尋條件是 `message:"end task" AND message:failed`。Rule Simulation 用這筆格式可以產生 `pve_event_type=task_failed`，但這只證明「這一種格式」認得出來。

> 這筆舊訊息沒有 `pve_event_type`，因為它比規則還早寫入。**新增規則不會替已經存進索引的舊訊息補欄位**。

**9/22 修正**：PVE 9.2.20 的真實日誌顯示，第一版會漏掉 `migration aborted`、`CT is locked (backup)`、`unable to get PID for CT ... (not running?)` 這些失敗。改成「成功都以 `: OK` 結尾，其他結尾就算失敗」：

```text
rule "PVE - Task Failed"
when
    has_field("message") &&
    contains(to_string($message.message), "end task UPID:") &&
    !ends_with(to_string($message.message), ": OK")
then
    set_field("pve_event_type", "task_failed");
    set_field("pve_task_status", "failed");
end
```

這樣不必維護一長串錯誤字串，也解決了漏報。「Task Success」本來就用 `: OK` 判斷，不需要改。

**驗證**：在 node10 送一筆合成訊息（沒有真的操作 VM 999）：

```bash
logger -p daemon.warning "end task UPID:node10:TEST:TEST:TEST:vzstart:999:root@pam: GRAYLOG-PVE-TASK-FAILED-TEST"
```

**看到的結果**：訊息帶有 `device_type=pve`、`event_category=pve_task`、`pve_cluster=PVE-Cluster`、`pve_event_type=task_failed`、`pve_task_name=vzstart`、`pve_task_node=node10`、`pve_task_status=failed`、`pve_task_user=root@pam`、`pve_vmid=999`，進入 Infrastructure Syslog Stream；告警的 Last Matched 更新，也收到了正式告警信。

## 6. 第三步：用 jt-ipam 補上主機名稱（2026-10-15）

**為什麼要做**：日誌裡常常只有 IP，例如 `Failed password ... from <IP>`、`rhost=<IP>`，看不出是哪台機器。jt-ipam（IP 位址管理系統）有「IP → 主機名稱」的對照表，讓 Graylog 自動補上 `src_ip`、`src_host` 兩個欄位。jt-ipam 要 1.0 以上才有這個功能（升級見 [jt-ipam 導入紀錄](https://kbwangtw.github.io/IT-Knowledge-Base/docs/network/jt-ipam-adoption-itbh/)）。

```text
jt-ipam（IP → 主機名稱對照表，HTTPS + 權杖 + 只允許 Graylog 存取）
  → Graylog 信任 jt-ipam 的憑證（6-2）
  → Data Adapter 每 5 分鐘下載一次對照表 → Lookup Table「ipam_hostname」（6-3）
  → Pipeline 最後一個 Stage：從訊息取出 IP，查表 → src_ip、src_host（6-4）
```

### 6-1 jt-ipam 端

在 jt-ipam 的「整合 → Graylog」：

| 項目 | 設定 |
| --- | --- |
| 格式 | CSV |
| 允許的來源位址 | Graylog 主機 `/32`（**先設定這個，再產生權杖**） |
| 允許明文 HTTP（8088） | 關閉 |
| 權杖 | 365 天（所有 DSV 端點共用一把；到期前 14、7、1 天會通知） |
| 對照表 | 啟用「IP → 主機名稱（全域）」，路徑 `ip-fqdn`，取得含權杖的 HTTPS 網址（存進密碼管理器） |

另有預設啟用的「VM 名稱」（vmid → VM 名稱）對照表，日後可替 PVE 任務日誌補上 VM 名稱。

從 Graylog 容器測試。網址含權杖，用 `read -s` 輸入，畫面不會顯示；`pct enter` 和 `read -s` 都要**單獨貼上**，否則後面的指令會被吞掉或被當成輸入：

```bash
read -s -p "jt-ipam lookup URL: " U; echo
curl -sk "$U" | head -5                                                   # 應顯示 "IP","主機名稱"
curl -s -o /dev/null -w 'http=%{http_code}\n' "$U" || echo "憑證驗證失敗"
echo | openssl s_client -connect <jt-ipam IP>:443 2>/dev/null | openssl x509 -noout -subject -ext subjectAltName
unset U
```

**看到的結果**：對照表有 21 筆。jt-ipam 用的是**自簽憑證**（自己簽發、不是公開憑證機構簽的），名稱相符但不受信任，所以 Graylog 會拒絕連線，要先做 6-2。

### 6-2 讓 Graylog 信任 jt-ipam 的憑證

**先比對指紋**，確認 Graylog 看到的憑證和 jt-ipam 本機上的一樣（防止中間被調包），**一樣才匯入**：

```bash
# Graylog 容器內
echo | openssl s_client -connect <jt-ipam IP>:443 2>/dev/null | openssl x509 -noout -enddate -fingerprint -sha256
# PVE 節點上，從 jt-ipam 容器內部看
pct exec <jt-ipam CTID> -- bash -c "echo | openssl s_client -connect 127.0.0.1:443 2>/dev/null | openssl x509 -noout -fingerprint -sha256"
```

Graylog 內建 Java，信任清單叫 `cacerts`。**不要直接改內建的那份**（套件更新會覆蓋），複製一份到 `/etc/graylog/server/` 再加入：

```bash
cp -a /etc/default/graylog-server /etc/default/graylog-server.bak-$(date +%Y%m%d)
echo | openssl s_client -connect <jt-ipam IP>:443 2>/dev/null | openssl x509 > /etc/graylog/server/jt-ipam.crt
cp /usr/share/graylog-server/jvm/lib/security/cacerts /etc/graylog/server/cacerts
/usr/share/graylog-server/jvm/bin/keytool -importcert -noprompt -alias jt-ipam \
  -file /etc/graylog/server/jt-ipam.crt -keystore /etc/graylog/server/cacerts -storepass changeit
chmod 644 /etc/graylog/server/cacerts
echo 'GRAYLOG_SERVER_JAVA_OPTS="$GRAYLOG_SERVER_JAVA_OPTS -Djavax.net.ssl.trustStore=/etc/graylog/server/cacerts -Djavax.net.ssl.trustStorePassword=changeit"' >> /etc/default/graylog-server
systemctl restart graylog-server          # 約 1～2 分鐘，期間 UDP syslog 會漏收
curl -s http://<Graylog IP>:9000/api/system/lbstatus   # ALIVE
ps -ef | grep -o 'trustStore=[^ ]*' | head -1          # /etc/graylog/server/cacerts
```

- 複製的 cacerts 保留了所有公開憑證機構，Gmail 寄信不受影響。`changeit` 是 Java 信任清單的**預設密碼**，檔案裡只有公開憑證，不是機密。
- jt-ipam 憑證 2031-09-14 到期；jt-ipam 換憑證後要重新匯入（先 `keytool -delete -alias jt-ipam` 再匯入）。
- 升級 graylog-server 時，如果 apt 詢問 `/etc/default/graylog-server` 要不要覆蓋，**選保留現有版本**，否則信任設定會消失。
- 還原：把 `.bak-日期` 複製回 `/etc/default/graylog-server` 並重啟。

### 6-3 Graylog 端：建立對照表

| 項目 | 設定 |
| --- | --- |
| URL Allowlist（允許 Graylog 連線的網址） | Regex `^https://<jt-ipam IP，點要跳脫>/api/v1/lookup/.*`；不含權杖，所以換權杖不用改 |
| Data Adapter | DSV File from HTTP；File URL 填含權杖的網址；Refresh 300 秒；Separator `,`；Line `\n`；Quote `"`；**Key column 0、Value column 1** |
| Cache | Do not cache values（Data Adapter 已經把整份對照表載入記憶體） |
| Lookup Table | 名稱 `ipam_hostname` |

> ⚠️ jt-ipam 畫面上寫「key 欄＝1、value 欄＝2」，但 Graylog **從 0 開始算**，實測要填 0 和 1 才查得到。

**應該看到**：Lookup Table 的 Test lookup 輸入 Graylog 的 IP，回傳 `graylog.<網域>`、`has_error: false`；Data Adapter 顯示共 21 筆。

含權杖的網址存在 Graylog 設定裡，Graylog 管理員看得到；這把權杖只能讀對照表、只允許 Graylog 的 IP 使用。

### 6-4 Pipeline 規則：從訊息取出 IP 並查表

```text
rule "Enrich - Source IP hostname (jt-ipam)"
when
    regex("(?:from|rhost=)\\s*(\\d{1,3}(?:\\.\\d{1,3}){3})", to_string($message.message)).matches == true
then
    let m = regex("(?:from|rhost=)\\s*(\\d{1,3}(?:\\.\\d{1,3}){3})", to_string($message.message));
    let ip = to_string(m["0"]);
    set_field("src_ip", ip);
    set_field("src_host", to_string(lookup_value("ipam_hostname", ip), "(not in ipam)"));
end
```

白話：找到「from」或「rhost=」後面接的 IP，存成 `src_ip`；拿去對照表查，查到就是主機名稱，查不到填 `(not in ipam)`。

- 加在 Infrastructure Syslog **新增的最後一個 Stage**，繼續條件選 None or more rules match（原因見 5-1）。
- Rule Simulation（Simple Message）分別用內網 IP 和外部 IP（`rhost=` 寫法）測試，外部 IP 應得到 `(not in ipam)`。

**實測**：在節點上執行 `logger -t sshd "Failed password for invalid user ipamtest from <jt-ipam IP> port 22 ssh2"`，搜尋 `ipamtest AND _exists_:src_host` 找到訊息，`src_host` 是 jt-ipam 的主機名稱。

搜尋小技巧：

| 想找 | 搜尋 |
| --- | --- |
| 有補上主機名稱的訊息 | `_exists_:src_host`（`src_host:*` 會出錯，見第 13 節） |
| 來自「沒登記在 jt-ipam」的 IP | `src_host:"(not in ipam)"`，日後可做成告警或戰情面板 |
| 某台主機在 PVE 和 NAS 上的紀錄 | `src_host:"<名稱>"`（兩邊欄位名稱相同） |

## 7. Synology NAS 的處理（Synology Syslog Pipeline）

### 7-1 解析登入紀錄

Pipeline 由 Input Setup Wizard 建立。Stage 0 有兩條解析規則：「Synology DSM Authentication Failed Parser」和「Synology DSM Authentication Success Parser」，繼續條件是 **at least one rule**。

它們從登入紀錄，例如：

```text
Connection: User [帳號] from [IP] signed in to [DSM] successfully via [password].
```

拆出 `synology_nas`、`synology_service`、`synology_user`、`synology_src_ip`、`synology_auth_result`（success／failed）、`synology_auth_method` 六個欄位。

**兩步驟驗證（2FA）會產生兩筆紀錄**：先是 `passed the first authentication of 2FA via [password]`，再是 `signed in to [DSM] successfully via [OTP]`；後者解析為 `synology_auth_method: OTP`、`synology_auth_result: success`。

### 7-2 補上主機名稱

NAS 的訊息已經有 `synology_src_ip`，不需要再從文字裡找 IP。新增規則放在 **Stage 9**（None or more rules match）：

```text
rule "Enrich - Synology src_ip hostname (jt-ipam)"
when
    has_field("synology_src_ip")
then
    let ip = to_string($message.synology_src_ip);
    set_field("src_ip", ip);
    set_field("src_host", to_string(lookup_value("ipam_hostname", ip), "(not in ipam)"));
end
```

- Rule Simulation（JSON）：`{"message": "test", "synology_src_ip": "<WireGuard 容器 IP>"}` → `src_host` 是 WireGuard 容器的主機名稱。實際登入 DSM 後，訊息也出現 `src_ip`、`src_host`。兩台 NAS 都已確認。
- Stage 0 是 at least one rule，所以**只有登入紀錄**會走到 Stage 9，剛好就是有 `synology_src_ip` 的訊息；其他系統事件不受影響。
- 從外面經 WireGuard 登入時，NAS 看到的來源是 WireGuard 容器（NAT 轉換），`src_host` 會顯示 WireGuard 主機名稱，可以用來辨識「這是 VPN 登入」。
- 經 QuickConnect 連線時，日誌記錄的是使用者 IP 還是 Synology 中繼站，**尚未觀察到**，有紀錄再確認。

### 7-3 丟棄 PBS 讀取 NAS 產生的雜訊（2026-10-15～16）

**問題**：tokyo16 每天約 11～12 萬筆日誌，大部分是 PBS 透過 SMB 讀取備份資料產生的 DSM 傳輸記錄：

```text
tokyo16 WinFileService Event: read, Path: /PBS_BK_Folder/..., User: <PBS 帳號>, IP: <PBS31>
```

**為什麼不直接在 DSM 關掉「讀取」記錄**：tokyo16 是檔案伺服器，**使用者**的讀取紀錄有稽核價值（例如有人大量複製檔案）。所以改在 Graylog 只丟掉「PBS 帳號的 read」。

規則加在 Synology Syslog Pipeline 的 **Stage 0**（和兩條解析規則並列）：

```text
rule "Drop - Synology PBS SMB read"
when
    contains(to_string($message.message), "WinFileService Event: read") &&
    contains(to_string($message.message), "User: <PBS 帳號>")
then
    drop_message();
end
```

- **為什麼放 Stage 0**：這些訊息不會被解析規則認出，本來就停在 Stage 0，但**仍會存進索引**，所以要在 Stage 0 丟掉。
- 其他帳號的 SMB 存取、PBS 的寫入和刪除（write／create／rename／delete）都保留；DSM 本機的記錄不受影響。
- `contains()` **有分大小寫**，而且依賴 DSM 的訊息格式。格式改變時只是雜訊回來，不會漏掉其他紀錄；PBS 改用別的帳號時要一起修改。

**怎麼測試**（踩過的雷）：Rule Simulation 會對**每一筆**模擬訊息都顯示「Not stored」，因為模擬本來就不寫入索引，所以**看不出有沒有被丟掉**。正確做法：

1. 先把 `then` 改成 `set_field("would_drop", "yes");`
2. 模擬 PBS 的 read 訊息 → 應出現 `would_drop: yes`；模擬其他帳號的訊息 → 不應出現
3. 確認後改回 `drop_message();`

**上線後驗證（2026-10-16 已驗證）**：搜尋 `source:tokyo16 AND "WinFileService" AND "<PBS 帳號>" AND "read"`，時間從規則上線後開始，結果 **0 筆**。

| 時段（台灣） | 上線前 | 上線後 |
| --- | --- | --- |
| PBS Verify（02:00～03:00）、GC（00:00） | 大量 read，是主要來源 | read 為 0；同時段仍有 Verify 更新 `index.json.blob` 的 create／write／rename，證明 Verify 有執行 |
| 約 14:00 | 一小批 read（約 300 筆） | 0 |
| 備份（21:00～22:30） | 寫入紀錄 | 保留（PBS 寫入 chunk 的 create／write／rename） |

規則上線後一天內，tokyo16 仍有約 4.5 萬筆 `WinFileService`，都是寫入類事件，照設計保留。已存的舊紀錄依預設索引的保留期（Data Tiering，30～40 天）自然輪替。

> 查詢時間範圍要注意時區（第 12-1 節）：改時區後，原本以 UTC 填的 Absolute 範圍會被平移 8 小時。

## 8. 看板：「PVE 任務監控」

9/17 建立了八個 Widget；之後的工作聚焦在告警，沒有再逐項驗收看板。

| 區塊 | 內容 |
| --- | --- |
| 四個數字 | failed、warning、success、started 各有幾筆 |
| 狀態趨勢 | 各狀態隨時間的變化 |
| 節點統計 | 每個節點完成多少工作 |
| 任務種類統計 | 哪一類工作最多 |
| 最近異常 | 逐筆列出 warning／failed |

- 每個 Widget 都要**各自**限定 Infrastructure Syslog Stream，時間範圍「最近一天到現在」。Dashboard 名稱對了，不代表每個 Widget 都選對 Stream。
- 節點與種類統計要排除 started，免得同一個工作的「開始」和「結束」被算兩次：

  ```text
  pve_task_status:success OR pve_task_status:warning OR pve_task_status:failed
  ```

- 分組用 `pve_task_node` 或 `pve_task_name`，略過空值。
- 最近異常用 `pve_task_status:warning OR pve_task_status:failed`，依時間新到舊，顯示時間、節點、任務、VMID、使用者與狀態。VMID 空白不一定是解析失敗，有些任務本來就沒有 VMID。

## 9. 告警（一）：讓 Graylog 能寄 Gmail

寄信要兩塊設定都完成：

| 設定 | 在哪裡 | 管什麼 |
| --- | --- | --- |
| Email Transport | 主機上的 `/etc/graylog/server/server.conf` | 用哪個 SMTP 伺服器、帳號 |
| Notification | Graylog 網頁 | 通知名稱、收件人、信件內容 |

以下只列非機密設定，帳號用佔位文字，**刻意省略密碼那一行**，不能直接覆蓋主機設定檔：

```ini
transport_email_enabled = true
transport_email_hostname = smtp.gmail.com
transport_email_port = 587
transport_email_use_auth = true
transport_email_auth_username = <GMAIL_ACCOUNT>
transport_email_from_email = <GMAIL_ACCOUNT>
transport_email_socket_connection_timeout = 10s
transport_email_socket_timeout = 10s
transport_email_use_tls = true
transport_email_use_ssl = false
```

- 587 埠搭配 STARTTLS（`use_tls=true`）：連線後再升級成加密，所以 `use_ssl=false` **不代表沒加密**。
- `transport_email_auth_password` 在主機上私下設定為 Gmail 的**應用程式密碼（App Password）**；本文、附件與 Git 紀錄都不包含它，也不保存可還原的 Base64。

### 9-1 排錯過程（2026-09-18）

寄不出信時，**一層一層往下查**：

| 步驟 | 觀察到什麼 | 判讀與處理 |
| --- | --- | --- |
| Email Transport | 出現「未啟用 Email Transport」的系統通知 | 設好 SMTP 並重啟後，要看通知的**時間**，不能把舊警告當成新結果 |
| 收件人格式 | server.log 出現 `AddressException`、`Domain contains illegal character`：地址多了一個 @ | 修正收件地址；這個問題和後面的 535 錯誤無關 |
| Notification 儲存 | 停在沒按儲存的表單，清單裡沒有該通知 | 先建立並**儲存**「PVE 任務失敗通知」，再在既有項目上測試 |
| 日誌時序 | journalctl 沒有新紀錄；server.log 尾端仍是舊的地址錯誤 | 沒有新 log 不代表寄成功；不能拿舊錯誤推斷本次原因 |
| 網路（TCP 587） | `nc -vz smtp.gmail.com 587` 顯示 `587 (submission) open` | 主機連得到 Gmail；DNS fwd/rev mismatch 的提示不影響 |
| 加密（STARTTLS） | OpenSSL 顯示 `Verification: OK`、`Verify return code: 0 (ok)`，TLS 1.3 握手成功 | 加密與憑證正常，問題在帳號驗證 |
| 密碼格式 | App Password 原本 19 字元，拿掉 3 個空格變 16 字元 | 長度對了仍失敗：格式正確 ≠ Google 接受 |
| 舊密碼 | SMTP 測試回 `SMTPAuthenticationError(535, ...)`、`5.7.8 Username and Password not accepted` | 舊密碼不被接受，改 TLS 或 Notification 都沒用 |
| 新密碼 | 重新產生 App Password，用不顯示的方式輸入測試，得到 `SMTP AUTH SUCCESS` | 新密碼通過；沒有在任何地方記錄密碼 |
| Graylog 實測 | 私下更新設定、重啟後服務 active，再測既有 Notification | Gmail 實際收到測試信 |

**結論**：網路與加密都正常，是舊 App Password 驗證失敗；換新密碼後就成功了。紀錄不足以判斷舊密碼是被撤銷、抄錯還是其他原因，不再推測。

分層檢查用的兩條指令（日後排錯參考）：

```bash
nc -vz smtp.gmail.com 587                                          # 第 1 層：連得上嗎？
openssl s_client -starttls smtp -connect smtp.gmail.com:587 -crlf   # 第 2 層：加密與憑證正常嗎？
```

- 只看連線與憑證驗證結果就好，不需要公開整份憑證或驗證對話。
- 測試帳號密碼時用互動、不回顯的輸入方式，避免密碼留在命令列、截圖或紀錄裡。
- Graylog 顯示 Notification executed successfully，**不能取代實際收到信**。

## 10. 告警（二）：第一個告警「PVE 任務失敗」

### 10-1 建立 Event Definition

在 **Alerts → Event Definitions** 建立，Rule Simulation 成功後，正式設定為每 5 分鐘查最近 5 分鐘：

| 欄位 | 設定 |
| --- | --- |
| Title | PVE 任務失敗警報 |
| Description | 偵測 Proxmox VE 任務執行失敗事件 |
| Priority | High（清單顯示 3） |
| Condition Type | Filter & Aggregation |
| Search Query | `pve_event_type:task_failed` |
| Stream | Infrastructure Syslog |
| Search within the last／Execute search every | 5 分鐘／5 分鐘 |
| Enable scheduling／Status | Yes／enabled |
| Create Events | Filter has results |
| Event Limit | 100 |
| Custom Fields | 第一版沒有新增 |

當時填的 Event Summary Template 是 `PVE 任務失敗：${source.message}`，**還沒驗證這個變數能不能帶出原始訊息**。建好時 Last Matched 是 Never（當時沒有新的失敗），這不代表規則壞了，也不能當作告警已通過的證據；9/22 已用 5-5 節的合成訊息確認 Last Matched 更新並收到正式告警信。

### 10-2 建立通知並綁定

| 項目 | 設定 |
| --- | --- |
| Notification Title | PVE 任務失敗通知 |
| Type | Email Notification |
| Description | 當 Proxmox VE 任務執行失敗時發送警報通知 |
| Subject | `【Graylog 警報】${event_definition_title}` |
| 寄件人／收件人 | 已核對正確的 Gmail 地址（公開文件不列） |
| Time zone | Taipei，測試信顯示 +08:00 |
| Body／HTML Body Template | 保留 Graylog 預設範本 |
| 測試 | 2026-09-18 實際收到，信內時間 14:28:26.023+08:00 |

收到測試信後，回到「PVE 任務失敗警報」→ Edit → **Notifications**，加入「PVE 任務失敗通知」，Grace Period 5 分鐘，最後按 **Update event definition**，看到 `Event Definition "PVE 任務失敗警報" was updated successfully.` 才算存好（只在下拉選單選到通知不算）。

Message Backlog 當時是 0，Summary 會顯示 `Notifications will not include any messages.`，意思是信裡不附原始訊息，不是通知沒綁上。**10/16 已改為 5**（第 11-4 節）。

## 11. 告警（三）：全部告警清單（2026-10-16 盤點）

### 11-1 怎麼匯出所有告警設定

大部分告警在本文件之前就由其他人建立，沒有紀錄。10/16 用 Graylog 的 REST API 一次匯出。

在 Graylog 容器內執行。注意 Graylog 監聽的是**容器的 IP**，不是 127.0.0.1；`-u admin` 會詢問 admin 密碼：

```bash
GL=$(hostname -I | awk '{print $1}')
curl -s -o /root/event-defs.json -w 'http=%{http_code}\n' -u admin "http://$GL:9000/api/events/definitions?per_page=100"
python3 -c '
import json
d=json.load(open("/root/event-defs.json"))
for e in d["event_definitions"]:
    c=e["config"]; n=e.get("notification_settings") or {}
    print("==", e["title"], "| priority", e["priority"])
    print("  query:", c.get("query"))
    print("  every/within(min):", c.get("execute_every_ms",0)//60000, "/", c.get("search_within_ms",0)//60000)
    print("  group_by:", c.get("group_by"), "| conditions:", json.dumps(c.get("conditions"), ensure_ascii=False))
    print("  grace(min):", (n.get("grace_period_ms") or 0)//60000, "| backlog:", n.get("backlog_size"), "| notifications:", len(e.get("notifications") or []))
'
rm /root/event-defs.json
```

| 顯示 | 意思 |
| --- | --- |
| `http=200` | 成功 |
| `http=401` | 帳號或密碼錯誤。忘記密碼時，可在網頁 System → Users and Teams → Administrator → **Edit Tokens** 建立暫時 token，改用 `-u "<token>:token"`，用完刪除 |
| `http=000` | 連不上，多半是用了 127.0.0.1 |

### 11-2 清單

「每／範圍」是「每幾分鐘檢查一次／檢查最近幾分鐘」。

| 告警 | 條件（Search Query） | 每／範圍（分） | 分組、門檻 | Grace／Backlog |
| --- | --- | --- | --- | --- |
| Ceph 健康警告 | `message:"Health check failed:" AND NOT message:"cmd=" AND NOT message:"dispatch" AND NOT message:"finished"` | 5／5 | 有就觸發 | 5 分／10 |
| PVE Corosync 成員離線 | `message:corosync AND message:"Members left:"` | 5／5 | 有就觸發 | 5 分／10 |
| PVE Node 狀態離線 | `"PVE_NODE_OFFLINE" OR "PVE_NODE_MONITOR_ERROR"`（11-3 的腳本產生；10/16 加入後者） | 1／1 | 每筆 | 5 分／10 |
| PVE 任務失敗警報 | `pve_event_type:task_failed` | 5／5 | 每筆 | 5 分／5（10/16 由 0 改為 5） |
| PVE 儲存空間嚴重 | `message:"STORAGE_CRITICAL"`（11-3） | 5／5 | 有就觸發 | 5 分／10 |
| PVE 儲存空間警告 | `message:"STORAGE_WARNING"`（11-3） | 5／5 | 有就觸發 | **24 小時**／10（10/16 由 5 分改為 24 小時） |
| PVE 儲存設備離線 | `message:"STORAGE_UNAVAILABLE"`（11-3） | 5／5 | 有就觸發 | 5 分／10 |
| PVE 多次驗證失敗 | `device_type:"pve" AND event_category:"authentication" AND (message:failure OR message:failed)` | 5／5 | 同一台 `source` ≥ 3 次 | 5 分／50 |
| PVE 服務異常 | `device_type:"pve" AND event_category:"system_error" AND message:"Failed with result"` | 5／5 | 每筆 | 5 分／50 |
| Synology DSM 登入失敗 | `synology_auth_result:failed AND synology_service:DSM` | 5／5 | 同一台 NAS、同一來源 IP ≥ 3 次 | 5 分／10 |
| Synology DSM 管理員登入 | `message:"User [<NAS 管理員帳號>]" AND message:"signed in to [DSM] successfully"` | 5／5 | 每筆 | 5 分／10 |
| WireGuard VPN 異常 | `source:wazuh AND "WireGuard ct:109"`（由 Wazuh 轉來） | 1／5 | 每筆 | 30 分／5 |
| Graylog 每日健康回報 | `"GRAYLOG_DAILY_HEARTBEAT"`（三台每天 08:00 送出；10/19 加入，見 11-6） | 5／5 | 有就觸發 | 60 分／3 |
| System notification events | Graylog 內建 | — | — | — |

- 每個告警都綁了一個 Email 通知（第 9 節）。
- **Grace 5 分鐘**：同一告警 5 分鐘內最多寄一封。狀態持續時（節點一直離線、儲存一直超標）會每 5 分鐘再寄一封，直到恢復。
- **NAS 登入失敗**：要「同一台 NAS、同一個 IP、5 分鐘內 ≥ 3 次」才通知；比較慢的嘗試由 DSM 的自動封鎖處理。
- **NAS 管理員登入**：只涵蓋那一個管理員帳號。兩步驟驗證時只有最後的 `signed in ... successfully via [OTP]` 符合，一次登入只寄一封。
- **WireGuard**：檢查範圍 5 分鐘比間隔 1 分鐘長，同一筆訊息會被抓到好幾次，靠 30 分鐘的 Grace 避免重複寄信（建置過程見 [WireGuard 文件](https://kbwangtw.github.io/IT-Knowledge-Base/docs/pve/wireguard-remote-access-replace-8006/)第 12 節）。

### 11-3 告警背後的監控腳本（PVE 三台）

「Node 離線」和三個「儲存」告警的訊息**不是 PVE 原生的日誌**，而是節點上的腳本定期檢查後，用 `logger` 寫進 syslog，再轉送到 Graylog。

| 腳本 | 在哪裡 | 多久跑一次 | 檢查什麼 |
| --- | --- | --- | --- |
| `/usr/local/sbin/pve-node-monitor.sh` | 三台（10/16 加入 node11、node12） | 每 1 分鐘 | 用 `pvesh get /cluster/resources --type node` 查叢集，狀態不是 online 的節點寫出 `PVE_NODE_OFFLINE node=<節點> status=<狀態>`；查詢失敗寫 `PVE_NODE_MONITOR_ERROR` |
| `/usr/local/sbin/pve-storage-monitor.sh` | 三台，內容相同 | 每 5 分鐘 | 本機 `/` 與 `pve/data`（LVM Thin 的 data、metadata）用量 ≥ 80% 寫 `STORAGE_WARNING`、≥ 90% 寫 `STORAGE_CRITICAL`；共用儲存 PBS31、VM_Pool、cephfs（`pvesm status`）狀態不是 active 寫 `STORAGE_UNAVAILABLE` |

**怎麼判讀「哪一台出問題」**：

| 訊息 | 出問題的是 |
| --- | --- |
| `PVE_NODE_OFFLINE node=node12 status=offline` | `node=` 後面那一台；訊息的 source 是負責偵測的節點 |
| `PVE_NODE_MONITOR_ERROR ...` | 送出訊息的那一台本身（查不到叢集狀態） |
| `STORAGE_WARNING host=node11 storage=...` | `host=` 那一台的 `storage=` 那個儲存 |

`pve-node-monitor.sh`（需要先安裝 `jq`）：

```bash
#!/bin/bash
TAG="PVE-NODE-MONITOR"
NODES_JSON=$(pvesh get /cluster/resources --type node --output-format json 2>/dev/null)
if [ $? -ne 0 ] || [ -z "$NODES_JSON" ]; then
    logger -t "$TAG" "PVE_NODE_MONITOR_ERROR unable_to_query_cluster_resources"
    exit 1
fi
echo "$NODES_JSON" | jq -r '.[] | select(.status != "online") | "\(.node)|\(.status)"' |
while IFS='|' read -r NODE STATUS; do
    [ -z "$NODE" ] && continue
    logger -t "$TAG" "PVE_NODE_OFFLINE node=$NODE status=$STATUS"
done
```

`pve-storage-monitor.sh`（三台相同）：

```bash
#!/bin/bash
WARN=80
CRIT=90
HOST=$(hostname -s)

# local：PVE root filesystem
ROOT_USAGE=$(df --output=pcent / | tail -1 | tr -dc '0-9')
if [ "$ROOT_USAGE" -ge "$CRIT" ]; then
    logger -t pve-storage-monitor "STORAGE_CRITICAL host=$HOST storage=local type=filesystem usage=${ROOT_USAGE}% threshold=${CRIT}%"
elif [ "$ROOT_USAGE" -ge "$WARN" ]; then
    logger -t pve-storage-monitor "STORAGE_WARNING host=$HOST storage=local type=filesystem usage=${ROOT_USAGE}% threshold=${WARN}%"
fi

# local-lvm：LVM Thin Pool Data% 與 Metadata%
for M in data metadata; do
    V=$(lvs --noheadings --nosuffix -o ${M}_percent pve/data 2>/dev/null | xargs)
    [ -z "$V" ] && continue
    I=${V%.*}
    if [ "$I" -ge "$CRIT" ]; then
        logger -t pve-storage-monitor "STORAGE_CRITICAL host=$HOST storage=local-lvm metric=$M usage=${V}% threshold=${CRIT}%"
    elif [ "$I" -ge "$WARN" ]; then
        logger -t pve-storage-monitor "STORAGE_WARNING host=$HOST storage=local-lvm metric=$M usage=${V}% threshold=${WARN}%"
    fi
done

# Shared Storage：由三台節點監控，重複訊息由 Graylog 合併
for STORAGE in PBS31 VM_Pool cephfs; do
    LINE=$(pvesm status 2>/dev/null | awk -v s="$STORAGE" '$1 == s {print}')
    [ -z "$LINE" ] && continue
    STATUS=$(echo "$LINE" | awk '{print $3}')
    USAGE=$(echo "$LINE" | awk '{print $7}' | tr -d '%')
    if [ "$STATUS" != "active" ]; then
        logger -t pve-storage-monitor "STORAGE_UNAVAILABLE host=$HOST storage=$STORAGE type=shared status=$STATUS"
        continue
    fi
    [ -z "$USAGE" ] && continue
    U=${USAGE%.*}
    if [ "$U" -ge "$CRIT" ]; then
        logger -t pve-storage-monitor "STORAGE_CRITICAL host=$HOST storage=$STORAGE type=shared usage=${USAGE}% threshold=${CRIT}%"
    elif [ "$U" -ge "$WARN" ]; then
        logger -t pve-storage-monitor "STORAGE_WARNING host=$HOST storage=$STORAGE type=shared usage=${USAGE}% threshold=${WARN}%"
    fi
done
```

（原腳本的 data、metadata 是分開兩段寫的，邏輯相同，這裡合併以便閱讀。）

讓腳本定時執行的 systemd 設定：

```ini
# /etc/systemd/system/pve-node-monitor.service
[Unit]
Description=PVE Cluster Node Status Monitor
After=pve-cluster.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/pve-node-monitor.sh

# /etc/systemd/system/pve-node-monitor.timer
[Unit]
Description=Run PVE Cluster Node Status Monitor every minute

[Timer]
OnBootSec=1min
OnUnitActiveSec=1min
Unit=pve-node-monitor.service
Persistent=true

[Install]
WantedBy=timers.target

# /etc/systemd/system/pve-storage-monitor.timer（三台都有；service 為同名的 oneshot）
[Unit]
Description=Run PVE Storage Capacity Monitor every 5 minutes

[Timer]
OnBootSec=2min
OnUnitActiveSec=5min
Persistent=true

[Install]
WantedBy=timers.target
```

| systemd 名詞 | 意思 |
| --- | --- |
| `.service`（oneshot） | 「執行一次就結束」的工作；跑完狀態是 `inactive`，代表成功 |
| `.timer` | 鬧鐘：`OnBootSec` 開機後多久第一次執行，`OnUnitActiveSec` 之後每隔多久執行 |

node10 的 `/root/graylog-alert-test-all.sh`、`graylog-alert-test-remaining.sh` 是建立告警時用的測試腳本，日後要驗證告警是否仍有效時可以參考。

### 11-4 盤點發現與處理（2026-10-16）

| 發現 | 影響 | 處理 |
| --- | --- | --- |
| Node 離線檢查與共用儲存檢查**只在 node10** | node10 自己離線時沒人送 `PVE_NODE_OFFLINE`，共用儲存也沒人查（但 node11、node12 的 corosync 仍會觸發「Corosync 成員離線」） | ✅ node11、node12 部署相同腳本與 timer，三台互相監控（11-5） |
| `PVE_NODE_MONITOR_ERROR` 沒有告警 | node10 查不到叢集狀態（例如失去 quorum）時只寫 log | ✅ Node 離線告警條件加入 `OR "PVE_NODE_MONITOR_ERROR"`，用 `logger -t PVE-NODE-MONITOR "PVE_NODE_MONITOR_ERROR manual-test-20261016"` 測試，收到通知。node10 重開機時若 timer 比叢集服務早執行，可能多寄一封，屬預期 |
| 共用儲存在 `pvesm status` 找不到時直接略過 | 儲存被移除或改名時不會告警 | 留意；改名時同步修改腳本 |
| 儲存空間警告的 Grace 只有 5 分鐘 | 超過 80% 後每 5 分鐘寄一封，可能連續好幾天 | ✅ 警告改為 24 小時；嚴重維持 5 分鐘 |
| 任務失敗告警 Backlog 0 | 通知信看不出是哪個任務失敗 | ✅ 改為 5 |
| 腳本與 timer 只存在節點上 | 重灌或換節點時容易遺漏 | ✅ 本節保存了完整內容 |

### 11-5 三台都部署監控腳本（2026-10-16）

先加 node11（讓 node10 離線時也有人回報），再加 node12（讓三台設定一致；node12 額外的效益只在 node10、node11 同時離線時，那時 node12 失去 quorum，多半會送出 `PVE_NODE_MONITOR_ERROR`）。

- 任一台離線時，另外兩台都會送 `PVE_NODE_OFFLINE`，由 5 分鐘 Grace 合併成一封信。
- 三個儲存告警是「5 分鐘內有就觸發一次」，多台各送一筆仍只算一次事件。

部署步驟（在 node10 執行，以 node11 為例）：

```bash
# 1. 比對：兩台 storage 腳本只差共用儲存那一段
diff <(ssh root@node11 cat /usr/local/sbin/pve-storage-monitor.sh) /usr/local/sbin/pve-storage-monitor.sh
# 2. 安裝 jq（原本沒有，腳本會失敗）並備份
ssh root@node11 "apt-get install -y jq"
ssh root@node11 "cp -a /usr/local/sbin/pve-storage-monitor.sh /usr/local/sbin/pve-storage-monitor.sh.bak-$(date +%Y%m%d)"
# 3. 複製腳本與 systemd 設定，啟用 timer
scp -p /usr/local/sbin/pve-storage-monitor.sh /usr/local/sbin/pve-node-monitor.sh root@node11:/usr/local/sbin/
scp -p /etc/systemd/system/pve-node-monitor.service /etc/systemd/system/pve-node-monitor.timer root@node11:/etc/systemd/system/
ssh root@node11 "chmod 755 /usr/local/sbin/pve-node-monitor.sh && systemctl daemon-reload && systemctl enable --now pve-node-monitor.timer"
```

驗證：

```bash
ssh root@node11 "pvesh get /cluster/resources --type node --output-format json | jq -r '.[] | \"\(.node) \(.status)\"'"
ssh root@node11 "systemctl start pve-node-monitor.service pve-storage-monitor.service; systemctl is-failed pve-node-monitor.service pve-storage-monitor.service"
ssh root@node11 "systemctl list-timers --no-pager | grep -E 'pve-(node|storage)'"
ssh root@node11 'logger -t PVE-NODE-MONITOR "PVE_NODE_MONITOR_ERROR manual-test-node11"'
for h in node10 node11 node12; do echo "== $h"; ssh root@$h "md5sum /usr/local/sbin/pve-*-monitor.sh"; done
```

| 檢查 | 結果（node11、node12 都相同） |
| --- | --- |
| 查叢集 | 三台都是 `online` |
| 兩個服務 | `inactive`（執行完畢、沒有 failed） |
| timer | 兩個都已排程 |
| 測試訊息 | 收到「PVE Node 狀態離線」通知，信裡 source 是送出的那一台 |
| md5 | 三台兩支腳本完全相同 |

node12 部署前，它的 storage 腳本和 node11 改版前的備份 `diff` 沒有差異。

還原（node11 或 node12）：`systemctl disable --now pve-node-monitor.timer`，刪除 node-monitor 腳本與兩個 systemd 檔案後 `daemon-reload`；storage 腳本用 `.bak-日期` 還原。

### 11-6 監控 Graylog 本身（2026-10-19）

**為什麼要做**：所有告警都由 Graylog 寄出，連 Wazuh 的 VPN 告警也要經過它。Graylog 自己掛掉時，**所有告警都會靜默**，而且沒有任何通知。所以監控 Graylog 一定要走**另一條寄信路線**。

「Graylog 掛了」有四種情況，用兩層分工處理：

| # | 情況 | 例子 | 由哪一層抓 |
| --- | --- | --- | --- |
| 1 | 服務停了 | 容器沒開、graylog-server 當掉 | 第一層 |
| 2 | 服務在，但收不到日誌 | Input 停了、來源端的 rsyslog 壞了 | 第一層 |
| 3 | 收得到，但處理不了 | OpenSearch 卡住、磁碟滿，訊息堆在佇列（journal） | 第一層 |
| 4 | 都正常，但**信寄不出去** | Gmail 應用程式密碼失效 | 第二層 |

```text
第一層：外部檢查（抓 1、2、3）
  node10／11／12 每 5 分鐘呼叫 Graylog API 檢查
    → 異常 → 用節點本機的 postfix 直接寄 Gmail（不經過 Graylog）

第二層：每日健康回報（抓 4）
  每天 08:00 三台各送一筆 GRAYLOG_DAILY_HEARTBEAT 日誌
    → Graylog 照正常告警流程寄出【每日健康回報】
    → 哪天早上沒收到這封信 = 告警鏈有地方斷了
```

> 三台都部署，是因為 node10、node11 同時故障時，node12 雖然失去 quorum，但檢查腳本只用 `curl` 和 `mail`、不依賴叢集功能，仍然能檢查和寄信。代價是同一個故障會收到 3 封信（主旨寫明是哪一台偵測到的）。

#### 第一步：確認節點能直接寄信

PVE 沒有 `/etc/pve/notifications.cfg`，代表用預設方式：交給本機 postfix，而 postfix 已設定經 Gmail 轉寄（備份通知信就是走這條路）。

```bash
postconf -h relayhost          # 應為 smtp.gmail.com:587
command -v sendmail mail       # 有這兩個指令
read -p "收件 Gmail：" TO
```

```bash
echo "寄信測試，來自 $(hostname)" | mail -s "【測試】$(hostname) 直接寄信（不經過 Graylog）" "$TO"
journalctl --since "10 min ago" --no-pager | grep -E 'postfix/.*status=' | tail -3
```

**看到的結果**：三台 relayhost 都是 `smtp.gmail.com:587`，紀錄出現 `status=sent (250 2.0.0 OK …)`，三封測試信都收到。postfix 的服務名稱各版本不同，所以用 `journalctl` 讀全部日誌再 grep，不指定 `-u`。

`postconf` 會出現 `support for parameter "smtp_use_tls" will be removed` 警告，是舊參數名稱，目前不影響寄信（列入待辦）。

#### 第二步：建立唯讀帳號與 token

腳本要讀 Graylog API，所以建一個只有 **Reader** 角色的帳號 `pve-monitor`。以下在 node10 用管理員身分透過 API 建立，token 直接寫進設定檔，**不顯示在畫面上、不經過剪貼簿**。

先建立設定檔（`read -p` 單獨貼上）：

```bash
read -p "收件 Gmail：" TO
```

```bash
umask 077
printf 'GL_URL=http://<Graylog IP>:9000\nGL_TOKEN=\nMAIL_TO=%s\n' "$TO" > /root/.graylog-monitor.conf
ls -l /root/.graylog-monitor.conf      # 應為 -rw-------
```

輸入管理員密碼（`read -s` 單獨貼上，輸入時畫面不顯示）：

```bash
read -s -p "Graylog admin 密碼：" GLPASS; echo
```

建立帳號與 token：

```bash
. /root/.graylog-monitor.conf
H=(-s -u "admin:$GLPASS" -H 'X-Requested-By: cli' -H 'Content-Type: application/json' -H 'Accept: application/json')
UPW=$(openssl rand -base64 32)
curl "${H[@]}" -w '  http=%{http_code}\n' -X POST "$GL_URL/api/users" -d "{\"username\":\"pve-monitor\",\"first_name\":\"PVE\",\"last_name\":\"Monitor\",\"email\":\"$MAIL_TO\",\"password\":\"$UPW\",\"roles\":[\"Reader\"],\"permissions\":[]}"
unset UPW
UID_=$(curl "${H[@]}" "$GL_URL/api/users/pve-monitor" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("id",""))')
RESP=$(curl "${H[@]}" -X POST "$GL_URL/api/users/$UID_/tokens/pve-graylog-monitor" -d '{"token_ttl":"P3650D"}')
unset GLPASS H
NEWTOKEN=$(printf '%s' "$RESP" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("token",""))' 2>/dev/null)
[ -n "$NEWTOKEN" ] && sed -i "s|^GL_TOKEN=.*|GL_TOKEN=$NEWTOKEN|" /root/.graylog-monitor.conf
unset NEWTOKEN RESP UID_
```

| 片段 | 意思 |
| --- | --- |
| `UPW=$(openssl rand …)` | 帳號的密碼隨機產生、不顯示；這個帳號只用 token，不用密碼登入 |
| `"roles":["Reader"]` | 只能讀，不能改任何設定 |
| `/api/users/<ID>/tokens/<名稱>` | 建立 token 要用帳號 ID，不是帳號名稱 |
| `"token_ttl":"P3650D"` | 有效期 3650 天，避免預設期限一到監控就失效 |
| `sed -i …` | token 直接寫進設定檔 |

測試 token（`-u "<token>:token"` 是 Graylog 的 token 登入方式：帳號欄放 token，密碼欄固定寫 `token`）：

```bash
. /root/.graylog-monitor.conf; echo "token 長度：${#GL_TOKEN}"
A=(-s -m 10 -u "$GL_TOKEN:token" -H 'Accept: application/json')
for p in system/lbstatus system/journal system/inputstates system/metrics/org.graylog2.throughput.input system/metrics/org.graylog2.throughput.output; do
  printf '%-48s ' "$p"; curl "${A[@]}" -o /dev/null -w 'http=%{http_code}\n' "$GL_URL/api/$p"
done
```

**看到的結果**：token 長度 52，五個端點都是 `http=200`。Reader 權限就讀得到佇列、Input 狀態和累計數字，不需要再補權限。

| 端點 | 用途 | 實測值（10/19） |
| --- | --- | --- |
| `system/lbstatus` | 健康狀態，不需登入 | `ALIVE` |
| `system/journal` | 佇列堆積幾筆 | 9 筆，每秒進出各 6 筆 |
| `system/inputstates` | 每個 Input 是否 RUNNING | 全部 RUNNING |
| `…throughput.input` | 啟動以來**收進**幾筆（累計） | 1,016,412 |
| `…throughput.output` | 啟動以來**處理完**幾筆（累計） | 825,263（比收進少，是 7-3 的丟棄規則把 NAS 雜訊丟掉） |

> `system/throughput`（每秒處理量）**不適合**拿來判斷：連續 10 秒測得 6、0、3、0、6、3、6、0、3、0，日誌是一陣一陣進來的，碰到空檔就是 0，會誤報。所以改用只增不減的累計數字。`count/total` 在 Graylog 7 已不存在（404）。

#### 第三步：安裝檢查腳本

| 檢查 | 判定異常的條件 | 對應情況 |
| --- | --- | --- |
| 健康端點 | 不是 `ALIVE`，或 10 秒內沒回應 | 1 |
| Input | 有任何 Input 不是 `RUNNING` | 2 |
| 輸入累計 | 和上次檢查（5 分鐘前）相比完全沒增加 | 2 |
| 處理累計 | 有收到新訊息，但處理數完全沒增加 | 3 |
| 佇列 | 堆積超過 50,000 筆（平常個位數） | 3 |
| API | 讀不到資料 | token 失效或權限被改 |

**寄信規則**：剛異常時立刻寄一封；持續異常每 60 分鐘再寄一次；恢復時寄「已恢復」。Graylog 重開時累計數字會歸零，腳本把「數字變小」視為重開，不當成異常。

`/usr/local/sbin/graylog-health-check.sh`：

```bash
#!/bin/bash
# Graylog 健康檢查：異常時用本機 postfix 直接寄信（不經過 Graylog）
CONF=${CONF:-/root/.graylog-monitor.conf}
STATE_DIR=/var/lib/graylog-health
JOURNAL_MAX=50000   # 佇列堆積超過這個數量就告警
REPEAT_MIN=60       # 持續異常時，每隔幾分鐘再寄一次
. "$CONF" || exit 1
mkdir -p "$STATE_DIR"
H=$(hostname -s); NOW=$(date +%s); problems=()
api() { curl -s -m 10 -u "$GL_TOKEN:token" -H 'Accept: application/json' "$GL_URL/api/$1"; }
num() { python3 -c "import json,sys; print(json.load(sys.stdin)$1)" 2>/dev/null; }

lb=$(curl -s -m 10 "$GL_URL/api/system/lbstatus")
if [ "$lb" != "ALIVE" ]; then
  problems+=("健康端點不是 ALIVE（實際回應：${lb:-沒有回應}）")
else
  in_now=$(api system/metrics/org.graylog2.throughput.input | num '["count"]')
  out_now=$(api system/metrics/org.graylog2.throughput.output | num '["count"]')
  unc=$(api system/journal | num '["uncommitted_journal_entries"]')
  down=$(api system/inputstates | python3 -c 'import json,sys; print(", ".join(s["message_input"]["title"]+"="+s["state"] for s in json.load(sys.stdin)["states"] if s["state"]!="RUNNING"))' 2>/dev/null)
  if [ -z "$in_now" ] || [ -z "$out_now" ] || [ -z "$unc" ]; then
    problems+=("API 讀不到累計數字或佇列（token 失效或權限被改？）")
  else
    [ -n "$down" ] && problems+=("Input 沒有在執行：$down")
    [ "$unc" -gt "$JOURNAL_MAX" ] && problems+=("佇列堆積 $unc 筆（上限 $JOURNAL_MAX）：收得到但處理不了")
    read -r in_prev out_prev 2>/dev/null < "$STATE_DIR/counts"
    if [ -n "$in_prev" ] && [ "$in_now" -ge "$in_prev" ]; then   # 數字變小 = Graylog 重開，略過這一輪
      [ "$in_now" -eq "$in_prev" ] && problems+=("上次檢查到現在沒有收到任何新訊息（輸入累計停在 $in_now）")
      [ "$in_now" -gt "$in_prev" ] && [ "$out_now" -eq "$out_prev" ] && problems+=("有收到新訊息，但處理數沒有增加（停在 $out_now）")
    fi
    echo "$in_now $out_now" > "$STATE_DIR/counts"
  fi
fi

prev=$(cat "$STATE_DIR/status" 2>/dev/null || echo OK)
last=$(cat "$STATE_DIR/last_mail" 2>/dev/null || echo 0)
if [ ${#problems[@]} -gt 0 ]; then
  logger -t graylog-health "GRAYLOG_UNHEALTHY host=$H $(printf '%s; ' "${problems[@]}")"
  if [ "$prev" = OK ] || [ $((NOW-last)) -ge $((REPEAT_MIN*60)) ]; then
    printf '偵測主機：%s\n時間：%s\n\n異常項目：\n%s\n\n這封信由 PVE 節點直接寄出，不經過 Graylog。\n處理方式見知識庫 Graylog 文件「監控 Graylog 本身」一節。\n' \
      "$H" "$(date '+%F %T')" "$(printf -- '- %s\n' "${problems[@]}")" \
      | mail -s "【Graylog 異常】$H 偵測到 Graylog 有問題" "$MAIL_TO"
    echo "$NOW" > "$STATE_DIR/last_mail"
  fi
  echo FAIL > "$STATE_DIR/status"
else
  if [ "$prev" = FAIL ]; then
    printf '偵測主機：%s\n時間：%s\n\nGraylog 已恢復正常（健康端點 ALIVE、佇列 %s 筆）。\n' \
      "$H" "$(date '+%F %T')" "$unc" | mail -s "【Graylog 已恢復】$H" "$MAIL_TO"
    logger -t graylog-health "GRAYLOG_RECOVERED host=$H"
  fi
  echo OK > "$STATE_DIR/status"
fi
```

| 片段 | 意思 |
| --- | --- |
| `CONF=${CONF:-…}` | 平常讀正式設定檔；測試時可以換成另一份 |
| `api()`、`num()` | 小函式：呼叫 API、從 JSON 取出數字 |
| `/var/lib/graylog-health/` | 記錄狀態（OK／FAIL）、上次寄信時間、上次的累計數字 |
| `logger -t graylog-health` | 異常時也寫一筆 syslog，Graylog 還活著時事後查得到 |

systemd 設定（每 5 分鐘）：

```ini
# /etc/systemd/system/graylog-health-check.service
[Unit]
Description=Graylog health check (alerts via local postfix, not Graylog)
After=network-online.target postfix.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/graylog-health-check.sh

# /etc/systemd/system/graylog-health-check.timer
[Unit]
Description=Run Graylog health check every 5 minutes

[Timer]
OnBootSec=5min
OnUnitActiveSec=5min
Persistent=true

[Install]
WantedBy=timers.target
```

先手動執行兩次（隔 60 秒）確認 `exit=0`、狀態 `OK`、累計數字有增加，再啟用 timer。

#### 第四步：模擬故障測試（不碰真正的 Graylog）

用一份故意寫錯埠號的設定，讓腳本以為連不到 Graylog：

```bash
sed 's|:9000|:9999|' /root/.graylog-monitor.conf > /root/.graylog-monitor-test.conf; chmod 600 /root/.graylog-monitor-test.conf
CONF=/root/.graylog-monitor-test.conf /usr/local/sbin/graylog-health-check.sh   # 模擬故障 → 寄「異常」
CONF=/root/.graylog-monitor-test.conf /usr/local/sbin/graylog-health-check.sh   # 60 分鐘內 → 不再寄
/usr/local/sbin/graylog-health-check.sh                                          # 正式設定 → 寄「已恢復」
rm -f /root/.graylog-monitor-test.conf
```

| 測試 | 結果（10/19） |
| --- | --- |
| 模擬故障 | ✅ 狀態 FAIL，收到【Graylog 異常】node10，內容「健康端點不是 ALIVE（實際回應：沒有回應）」 |
| 重複告警 | ✅ 沒有再寄 |
| 模擬恢復 | ✅ 狀態 OK，收到【Graylog 已恢復】node10 |

#### 第五步：部署到三台並啟用

```bash
systemctl enable --now graylog-health-check.timer
for h in node11 node12; do
  scp -p /usr/local/sbin/graylog-health-check.sh root@$h:/usr/local/sbin/
  scp -p /etc/systemd/system/graylog-health-check.service /etc/systemd/system/graylog-health-check.timer root@$h:/etc/systemd/system/
  scp -p /root/.graylog-monitor.conf root@$h:/root/
  ssh root@$h "chmod 600 /root/.graylog-monitor.conf && systemctl daemon-reload && /usr/local/sbin/graylog-health-check.sh; systemctl enable --now graylog-health-check.timer"
done
for h in node10 node11 node12; do
  echo "== $h"; ssh root@$h "ls -l /root/.graylog-monitor.conf | cut -c1-10; md5sum /usr/local/sbin/graylog-health-check.sh | cut -c1-12; cat /var/lib/graylog-health/status; systemctl list-timers --no-pager | grep graylog-health"
done
```

**看到的結果**：三台設定檔都是 `-rw-------`、腳本指紋相同、狀態 `OK`、timer 每 5 分鐘執行。

#### 第六步：每日健康回報（第二層）

三台節點每天 08:00 送一筆心跳日誌：

```ini
# /etc/systemd/system/graylog-heartbeat.service
[Unit]
Description=Send daily heartbeat message to Graylog

[Service]
Type=oneshot
ExecStart=/usr/bin/logger -t graylog-heartbeat "GRAYLOG_DAILY_HEARTBEAT host=%H"

# /etc/systemd/system/graylog-heartbeat.timer
[Unit]
Description=Daily Graylog heartbeat at 08:00

[Timer]
OnCalendar=*-*-* 08:00:00
Persistent=false

[Install]
WantedBy=timers.target
```

| 設定 | 意思 |
| --- | --- |
| `%H` | systemd 自動換成主機名稱 |
| `OnCalendar=*-*-* 08:00:00` | 每天 08:00（節點時區 CST） |
| `Persistent=false` | 08:00 剛好關機時，開機後不補送，避免半夜收到「每日回報」 |

三台都複製這兩個檔案後 `systemctl daemon-reload && systemctl enable --now graylog-heartbeat.timer`。

Graylog 端建立通知與 Event Definition：

| 項目 | 設定 |
| --- | --- |
| 通知 | Title `每日健康回報通知`；Email Notification；Subject `【每日健康回報】Graylog 告警鏈正常`；Time Zone `Asia/Taipei`；先 Execute Test Notification 收到測試信再 Create |
| Event Definition | Title `Graylog 每日健康回報`；Priority Low；Filter & Aggregation；Query `"GRAYLOG_DAILY_HEARTBEAT"`；Stream Infrastructure Syslog；每 5 分鐘、看 5 分鐘；Filter has results；通知 `每日健康回報通知`；**Grace 60 分鐘**（三台各一筆只寄一封）；Backlog 3 |

**測試**：建好 Event Definition **之後**才手動觸發（規則只看最近 5 分鐘，建好前送的訊息不會被抓到）：

```bash
for h in node10 node11 node12; do ssh root@$h "systemctl start graylog-heartbeat.service"; done
```

**看到的結果**（10/19）：三筆訊息進入 Infrastructure Syslog（`device_type=pve`），09:00:34 觸發事件，收到**一封**【每日健康回報】信。

**日常使用**：Gmail 可設篩選器（主旨含「每日健康回報」→ 略過收件匣、加標籤），**每天早上看一眼有沒有今天的信**；沒收到就代表告警鏈斷了，依第一層的信或手動檢查找原因。

#### 收到「Graylog 異常」信時怎麼查

| 信裡的異常項目 | 先查什麼 |
| --- | --- |
| 健康端點不是 ALIVE | Graylog 容器有沒有開（`pct status 105`）、`systemctl status graylog-server`、OpenSearch 是否正常 |
| Input 沒有在執行 | Graylog **System → Inputs**，看錯誤訊息後重新啟動該 Input |
| 沒有收到任何新訊息 | 來源端 rsyslog（`systemctl status rsyslog`）、網路、Input 是否 RUNNING |
| 處理數沒有增加／佇列堆積 | OpenSearch 狀態（12-2）、磁碟空間；佇列會在恢復後自動消化 |
| API 讀不到資料 | token 被刪除或過期、`pve-monitor` 帳號被停用；重建 token（第二步） |

#### 還原

三台各執行：`systemctl disable --now graylog-health-check.timer graylog-heartbeat.timer`，刪除 `/usr/local/sbin/graylog-health-check.sh`、四個 systemd 檔案、`/root/.graylog-monitor.conf`、`/var/lib/graylog-health/` 後 `daemon-reload`。Graylog 端刪除 Event Definition「Graylog 每日健康回報」、通知「每日健康回報通知」與 `pve-monitor` 帳號（連同它的 token）。

### 11-7 NAS 快照複寫與連線監控（2026-10-19）

**為什麼要做**：melayu17 是 tokyo16 的快照複寫目的地，也是**最後一道防線**。回查 Snapshot Replication 套件的日誌（2023-12 起），過去的複寫失敗都**連續好幾天沒被發現**：

| 期間 | 失敗的任務 | 原因 |
| --- | --- | --- |
| 2026-08-30～08-31 | PBS_BK_Folder、No16、homes（兩天全部失敗） | `connection failed`：連不到 melayu17 的 DSM 埠 |
| 2026-07-13～07-15 | No16、homes、PVE_Backup（連續三天） | 同上 |
| 2026-07-01～07-02 | No16、homes、PVE_Backup | 同上 |
| 2025 年 8～9 月 | 共 4 天 | 同上 |

#### 目前的複寫任務（tokyo16 → melayu17，每天一次）

| 來源 | 目的地 | 每天完成時間 |
| --- | --- | --- |
| PBS_BK_Folder | PBS_BK_Folder | 約 00:15～00:25 |
| No16 | No16 | 約 02:00 |
| homes | homes-replicated | 約 02:01 |
| ActiveBackupforBusiness | ActiveBackupforBusiness-1 | 約 03:10 |
| KB-GD | KB-GD | 約 03:10 |
| ITBH-GD | ITBH-GD | 約 03:11 |

`PVE_Backup` 的複寫在 2026-07-27 改用 `PBS_BK_Folder` 後已移除，PVE 也沒有使用這個共用資料夾（`grep -i pve_backup /etc/pve/storage.cfg` 無結果）。10/19 從兩台的「控制台 → 共用資料夾」確認，`PVE_Backup` 共用資料夾在 tokyo16 與 melayu17 都已不存在（File Station 只列出目前帳號有權限的資料夾，要用控制台確認）。

**日誌格式**（套件內的「日誌」頁，**不在 DSM 記錄中心，所以不會經「記錄傳送」進 Graylog**；在 Graylog 搜尋 7 天為 0 筆）：

```text
成功：Synced shared folder replication from [tokyo16:<來源>] to [melayu17:<目的地>] completed.
失敗：Failed to sync shared folder replication from [tokyo16:<來源>] to [melayu17:<目的地>] due to [<原因>].
```

#### 要抓的情況與分工

| 情況 | 例子 | 怎麼抓 |
| --- | --- | --- |
| 複寫失敗 | melayu17 連不上、空間滿 | DSM 內建通知（Warning 規則） |
| 複寫被停止 | 任務被暫停或停用 | DSM 內建通知（自訂規則「快照複寫停止」） |
| 任一台 NAS 當機或斷線 | tokyo16 整台掛掉時 DSM 自己寄不出信 | PVE 節點每 5 分鐘檢查兩台 DSM 是否回應 |

#### 第一步：DSM 內建通知（tokyo16）

tokyo16 的 **控制台 → 通知設定 → 電子郵件** 已設定 Gmail 寄信，標題前置文字 `[tokyo16]`。預設規則 **Warning**（不能修改）已包含：

| Snapshot Replication 事件 | 層級 | Warning |
| --- | --- | --- |
| 執行初始複寫失敗 | 重大 | ✅ |
| 執行排程複寫失敗 | 重大 | ✅ |
| 無法為複寫任務啟用不可變快照 | 警告 | ✅ |
| 複寫任務未於特定時間內完成 | 警告 | ✅ |
| 複寫已停止 | 資訊 | ❌ |
| 初始／排程複寫已完成 | 資訊 | ❌（不需要） |

在「檢視規則」視窗的搜尋框輸入「複寫」，就能直接列出這些事件（不用展開類別）。

補上「複寫已停止」：

1. **規則 → 新增**：名稱 `快照複寫停止`，只勾 Snapshot Replication 的「複寫已停止」。
2. **電子郵件 → 收件者設定檔 → 新增**：同一個 Gmail，規則選 `快照複寫停止`。**保留原本的 Warning 那一筆**（一個收件者設定檔只能套一條規則，兩筆並存才不會少收）。

**看到的結果**：收件者設定檔有兩筆，分別套 Warning 與 快照複寫停止。

#### 第二步：為什麼不用 DSM API 查「最新快照」

原本想讓節點每小時用 DSM API 查 melayu17 上每個資料夾的最新快照（超過 26 小時沒有新的就告警）。實測結果：

| 測試 | 結果 |
| --- | --- |
| `SYNO.API.Info` 查詢（不用登入） | ✅ 有 `SYNO.Core.Share.Snapshot`、`SYNO.DR.Plan` |
| 管理員帳號登入後 `SYNO.Core.Share.Snapshot list` | ✅ 列得出每日快照（`time: GMT+08-2026.10.18-00.10.02`） |
| 一般帳號（只開 DSM 權限）登入 | ✅（`session` 要用 `webui`；用自訂名稱回 402） |
| 一般帳號讀快照、讀複寫任務 | ❌ 都回 `105`（沒有權限） |

結論：**只有管理員帳號讀得到**。melayu17 是最後一道防線，不在 PVE 節點上存它的管理員帳密（節點被入侵時，最後一份備份也會被刪），所以改用「連線檢查」，測試用的一般帳號已刪除。這樣抓不到「排程被改掉、但沒觸發停止事件」這種少見情況，改以每月人工看一次 Snapshot Replication 狀態頁補上。

#### 第三步：PVE 節點檢查兩台 NAS 是否回應

檢查方式是呼叫 DSM 的 `query.cgi`（**不需要登入，節點上沒有任何 NAS 帳密**）。兩台的 DSM HTTPS 埠刻意設成不同號碼，文件中以 `<tokyo16 埠>`、`<melayu17 埠>` 代稱。

設定檔 `/root/.nas-monitor.conf`（權限 600，收件人沿用 11-6 的設定）：

```bash
umask 077
. /root/.graylog-monitor.conf
cat > /root/.nas-monitor.conf <<EOF
MAIL_TO=$MAIL_TO
NAS_LIST="tokyo16=https://<tokyo16 IP>:<tokyo16 埠> melayu17=https://<melayu17 IP>:<melayu17 埠>"
EOF
umask 022
```

`/usr/local/sbin/nas-reach-check.sh`：

```bash
#!/bin/bash
# NAS 連線檢查：DSM 是否有回應；異常用本機 postfix 直接寄信（不經過 Graylog）
CONF=${CONF:-/root/.nas-monitor.conf}
STATE_DIR=/var/lib/nas-reach
FAIL_MIN=2      # 連續幾次沒回應才告警（每 5 分鐘一次 = 10 分鐘）
REPEAT_MIN=60   # 持續異常時，每隔幾分鐘再寄一次
. "$CONF" || exit 1
mkdir -p "$STATE_DIR"
H=$(hostname -s); NOW=$(date +%s)
for item in $NAS_LIST; do
  name=${item%%=*}; url=${item#*=}
  ok=$(curl -sk -m 10 "$url/webapi/query.cgi?api=SYNO.API.Info&version=1&method=query&query=SYNO.API.Auth" \
       | python3 -c 'import json,sys; print("yes" if json.load(sys.stdin).get("success") else "no")' 2>/dev/null)
  f="$STATE_DIR/$name"
  read -r fails status last 2>/dev/null < "$f"
  fails=${fails:-0}; status=${status:-OK}; last=${last:-0}
  if [ "$ok" = yes ]; then
    if [ "$status" = FAIL ]; then
      printf '偵測主機：%s\n時間：%s\n\n%s 的 DSM 已恢復回應。\n請到 Snapshot Replication 確認今晚的複寫有正常完成。\n' \
        "$H" "$(date '+%F %T')" "$name" | mail -s "【NAS 已恢復】$name（$H 偵測）" "$MAIL_TO"
      logger -t nas-reach "NAS_RECOVERED nas=$name host=$H"
    fi
    echo "0 OK 0" > "$f"
  else
    fails=$((fails+1))
    logger -t nas-reach "NAS_UNREACHABLE nas=$name host=$H fails=$fails"
    if [ "$fails" -ge "$FAIL_MIN" ]; then
      if [ "$status" = OK ] || [ $((NOW-last)) -ge $((REPEAT_MIN*60)) ]; then
        printf '偵測主機：%s\n時間：%s\n\n%s 的 DSM 連續 %s 次（每 5 分鐘一次）沒有回應。\n\n影響：\n- tokyo16 連不上：PBS 備份與快照複寫都會失敗\n- melayu17 連不上：快照複寫會失敗（最後一道防線沒有更新）\n\n這封信由 PVE 節點直接寄出，不經過 Graylog。\n' \
          "$H" "$(date '+%F %T')" "$name" "$fails" | mail -s "【NAS 連不上】$name（$H 偵測）" "$MAIL_TO"
        last=$NOW
      fi
      status=FAIL
    fi
    echo "$fails $status $last" > "$f"
  fi
done
```

| 片段 | 意思 |
| --- | --- |
| `NAS_LIST="名稱=網址 …"` | 要檢查的 NAS；多一台就多加一組 |
| 狀態檔 `連續失敗次數 狀態 上次寄信時間` | 每台 NAS 一個檔，在 `/var/lib/nas-reach/` |
| `FAIL_MIN=2` | 連續 10 分鐘沒回應才寄信，避開 DSM 更新重開的短暫中斷 |
| `logger -t nas-reach` | 每次失敗也寫 syslog，Graylog 事後查得到 |

systemd 設定與 11-6 相同模式（`nas-reach-check.service` 為 oneshot，`nas-reach-check.timer` 為 `OnBootSec=5min`、`OnUnitActiveSec=5min`）。

#### 第四步：模擬 melayu17 連不上（不碰真正的 NAS）

```bash
sed 's|:<melayu17 埠>|:39999|' /root/.nas-monitor.conf > /root/.nas-monitor-test.conf; chmod 600 /root/.nas-monitor-test.conf
show() { for f in /var/lib/nas-reach/*; do echo "  $(basename $f)：$(cat $f)"; done; }
CONF=/root/.nas-monitor-test.conf /usr/local/sbin/nas-reach-check.sh; show   # 第 1 次
CONF=/root/.nas-monitor-test.conf /usr/local/sbin/nas-reach-check.sh; show   # 第 2 次
CONF=/root/.nas-monitor-test.conf /usr/local/sbin/nas-reach-check.sh; show   # 第 3 次
/usr/local/sbin/nas-reach-check.sh; show                                     # 第 4 次（正式設定）
rm -f /root/.nas-monitor-test.conf
```

| 第幾次 | melayu17 狀態檔（10/19 實測） | 信件 |
| --- | --- | --- |
| 1 | `1 OK 0` | 不寄 |
| 2 | `2 FAIL <時間戳>` | ✅ 收到【NAS 連不上】melayu17（node10 偵測） |
| 3 | `3 FAIL <同一個時間戳>` | 不寄（60 分鐘內） |
| 4 | `0 OK 0` | ✅ 收到【NAS 已恢復】melayu17（node10 偵測） |

tokyo16 全程 `0 OK 0`。

#### 第五步：部署到三台

```bash
systemctl enable --now nas-reach-check.timer
for h in node11 node12; do
  scp -p /usr/local/sbin/nas-reach-check.sh root@$h:/usr/local/sbin/
  scp -p /etc/systemd/system/nas-reach-check.service /etc/systemd/system/nas-reach-check.timer root@$h:/etc/systemd/system/
  scp -p /root/.nas-monitor.conf root@$h:/root/
  ssh root@$h "chmod 600 /root/.nas-monitor.conf && systemctl daemon-reload && /usr/local/sbin/nas-reach-check.sh && systemctl enable --now nas-reach-check.timer"
done
```

**看到的結果**：三台設定檔都是 `-rw-------`、腳本指紋相同、兩台 NAS 都是 `0 OK 0`、timer 已排程。同一個故障三台會各寄一封（主旨寫明偵測主機）。

#### 收到信時怎麼查

| 信件 | 先查什麼 |
| --- | --- |
| `[tokyo16]` 排程複寫失敗 | 失敗原因寫在信裡；`connection failed` → melayu17 是否開機、網路、DSM 埠；空間不足 → melayu17 儲存空間 |
| `[tokyo16]` 複寫已停止 | 是不是有人手動暫停；確認後在 Snapshot Replication 恢復任務 |
| 【NAS 連不上】tokyo16 | 主機是否當機；PBS 的 Tokyo16 datastore（CIFS）也會失效，見「PVE 儲存設備離線」告警 |
| 【NAS 連不上】melayu17 | 開機、網路；恢復後到 Snapshot Replication 確認當晚複寫完成，必要時手動「立即同步」 |

#### 還原

三台各執行 `systemctl disable --now nas-reach-check.timer`，刪除腳本、兩個 systemd 檔、`/root/.nas-monitor.conf`、`/var/lib/nas-reach/` 後 `daemon-reload`。tokyo16 可刪除「快照複寫停止」規則與對應的收件者設定檔。

### 11-8 備份監控（2026-10-19）

**為什麼要做**：備份分成三段，任何一段出錯都要知道；最難發現的是「備份根本沒執行」，因為那時信箱只是少了幾封信。

```text
每晚 21:00～22:30  PVE 三台各自備份（vzdump）→ PBS31
每晚 00:00          PBS31 GC（清掉不要的資料、釋放空間）
每晚 02:00          PBS31 Verify（檢查備份資料有沒有損壞）
每天 08:30          三台 PVE 檢查每台 VM／CT 的最新備份（本節新增）
```

#### 盤點：失敗時本來就會寄信的部分

| 階段 | 通知方式 | 證據 |
| --- | --- | --- |
| PVE 備份 | 三個 vzdump 排程都是 `notification-mode notification-system`；PVE 沒有 `/etc/pve/notifications.cfg`，用預設：每次都寄到 root@pam，經 postfix 轉寄 Gmail | `grep -A12 '^vzdump:' /etc/pve/jobs.cfg`；另有 Graylog「PVE 任務失敗警報」 |
| PBS GC、Verify | PBS 目標 `mail-to-root`（sendmail）、規則 `default-matcher`（除了成功的 Prune 以外全部都寄）；root@pam 有 email；postfix relayhost 為 Gmail | `proxmox-backup-manager notification target list`、`… matcher list` |
| 實際收信 | 每天收到中文的【PBS 垃圾資料回收成功】、【PBS 備份驗證成功】；2026-10-19 在測試 datastore 實際製造 GC 失敗、Verify 失敗，兩封中文失敗信都有寄到 | 成功每次都寄，失敗也確認會寄（做法見中文通知文件 9-1） |

PBS 的任務結果不會以 `TASK ERROR`／`end task` 的形式出現在 Graylog（搜尋 7 天 0 筆），所以 PBS 這段只靠 PBS 自己的通知。

**Gmail 篩選器**：每天有約 5 封成功信，失敗信容易被淹沒。主旨含「失敗」→ 標上星號、永遠標示為重要、永不移至垃圾郵件，並套用到既有的相符信件。

#### 新增：每日備份檢查（抓「沒執行」與「驗證失敗」）

**做法**：直接看結果。PVE 本來就連得到 PBS31，用 `pvesh` 讀 PBS31 上的備份清單，**不需要新增帳號或密碼**。

| 檢查 | 判定異常 | 抓的情況 |
| --- | --- | --- |
| 叢集裡每台 VM／CT（不含範本）在 PBS31 上有沒有備份 | 完全沒有 | 新建的 VM 沒被納入備份 |
| 最新備份的時間 | 超過 26 小時 | 備份沒執行（排程停用、PBS 掛載失效） |
| 最新備份的驗證結果 | `failed` 或沒有驗證紀錄 | 備份損壞，或 Verify 沒執行 |
| 讀不到 PBS31 的備份清單 | 指令失敗 | PBS31 掛了或連線問題 |

先用唯讀指令確認讀得到（10/19 實測：15 台、最新備份都是 10/18 21:00～22:07、驗證全部 `ok`）。指令裡含引號的 Python 要先用 `<<'EOF'` 寫成檔案再執行，直接放在 `python3 -c '…'` 裡用 `\"` 跳脫會出現 SyntaxError。

`/usr/local/sbin/pbs-backup-check.py`：

```python
#!/usr/bin/env python3
# 每日備份檢查：PBS31 上每台 VM／CT 是否有 26 小時內的新備份、最新一份是否驗證通過
# 有問題才用本機 postfix 寄信（不經過 Graylog）
import json, os, socket, subprocess, time

STORAGE = "PBS31"
MAX_AGE_H = float(os.environ.get("MAX_AGE_H", "26"))   # 測試時可用環境變數縮短
CONF = "/root/.graylog-monitor.conf"
host = socket.gethostname().split(".")[0]
mail_to = next(l.split("=", 1)[1].strip() for l in open(CONF) if l.startswith("MAIL_TO="))

def pvesh(*args):
    r = subprocess.run(["pvesh", "get", *args, "--output-format", "json"],
                       capture_output=True, text=True, timeout=180, check=True)
    return json.loads(r.stdout)

problems = []
try:
    guests = {str(g["vmid"]): g.get("name", "") for g in pvesh("/cluster/resources", "--type", "vm")
              if not g.get("template")}
    latest = {}
    for b in pvesh(f"/nodes/{host}/storage/{STORAGE}/content"):
        v = str(b.get("vmid", ""))
        if v and b.get("ctime", 0) > latest.get(v, {}).get("ctime", 0):
            latest[v] = b
    now = time.time()
    for v in sorted(guests, key=int):
        name = guests[v]
        b = latest.get(v)
        if not b:
            problems.append(f"{v} {name}：PBS31 上完全沒有備份")
            continue
        age = (now - b["ctime"]) / 3600
        when = time.strftime("%m/%d %H:%M", time.localtime(b["ctime"]))
        state = b.get("verification", {}).get("state")
        if age > MAX_AGE_H:
            problems.append(f"{v} {name}：最新備份是 {when}（{age:.1f} 小時前），超過 {MAX_AGE_H:g} 小時")
        if state == "failed":
            problems.append(f"{v} {name}：最新備份（{when}）驗證失敗")
        elif not state:
            problems.append(f"{v} {name}：最新備份（{when}）沒有驗證紀錄")
    summary = f"檢查 {len(guests)} 台，異常 {len(problems)} 項"
except Exception as e:
    problems.append(f"讀不到 {STORAGE} 的備份清單：{e}")
    summary = "檢查失敗"

print(summary)
for p in problems:
    print(" -", p)
if problems:
    body = (f"偵測主機：{host}\n時間：{time.strftime('%F %T')}\n{summary}\n\n異常項目：\n"
            + "\n".join(f"- {p}" for p in problems)
            + "\n\n這封信由 PVE 節點直接寄出，不經過 Graylog。\n")
    subprocess.run(["mail", "-s", f"【備份檢查異常】{len(problems)} 項（{host} 偵測）", mail_to],
                   input=body, text=True)
    subprocess.run(["logger", "-t", "pbs-backup-check", f"BACKUP_CHECK_PROBLEM host={host} {summary}"])
```

| 設計 | 原因 |
| --- | --- |
| 先列出叢集**所有** VM／CT 再對照 | 只看 PBS 上有的備份，會漏掉「從來沒備份過」的新 VM |
| 每台節點用自己的連線查 PBS31 | 某台節點連不到 PBS31 時，只有那台寄「讀不到」，看得出是哪一台 |
| `MAX_AGE_H` 可用環境變數覆蓋 | 測試時改成 1 小時觸發告警 |

systemd：`pbs-backup-check.service`（oneshot，`After=… pve-cluster.service`）與 `pbs-backup-check.timer`（`OnCalendar=*-*-* 08:30:00`、`Persistent=true`，節點 08:30 剛好關機時開機後補跑）。

#### 測試與部署（10/19）

```bash
/usr/local/sbin/pbs-backup-check.py               # 檢查 15 台，異常 0 項，不寄信
MAX_AGE_H=1 /usr/local/sbin/pbs-backup-check.py   # 15 台都超過 1 小時 → 收到【備份檢查異常】15 項（node10 偵測）
systemctl enable --now pbs-backup-check.timer
for h in node11 node12; do
  scp -p /usr/local/sbin/pbs-backup-check.py root@$h:/usr/local/sbin/
  scp -p /etc/systemd/system/pbs-backup-check.service /etc/systemd/system/pbs-backup-check.timer root@$h:/etc/systemd/system/
  ssh root@$h "systemctl daemon-reload && systemctl enable --now pbs-backup-check.timer"
done
```

**看到的結果**：三台腳本指紋相同、都有收件人設定檔、手動檢查都是「檢查 15 台，異常 0 項」、timer 下次執行 10/20 08:30。

#### 收到【備份檢查異常】時怎麼查

| 異常項目 | 先查什麼 |
| --- | --- |
| 完全沒有備份 | 是新建的 VM／CT 嗎？確認備份排程的 Selection 是 All 且有 Node，或手動備份一次 |
| 超過 26 小時 | 前一晚有沒有收到該節點的 PVE 備份信；`pvenode task list --typefilter vzdump --limit 3`；PBS31 的 Tokyo16 是否掛載（「PVE 儲存設備離線」告警） |
| 驗證失敗 | 看當天的【PBS 備份驗證】信；PBS 網頁 Datastore → Content 找到該份備份，必要時手動重新驗證或重新備份 |
| 沒有驗證紀錄 | 前一晚 02:00 的 Verify 有沒有執行（PBS 網頁 Tasks） |
| 讀不到備份清單 | `pvesm status --storage PBS31`；PBS31 是否開機、8007 是否連得到 |

#### 還原

三台各執行 `systemctl disable --now pbs-backup-check.timer`，刪除腳本與兩個 systemd 檔後 `daemon-reload`。

## 12. 日常維運

### 12-1 把顯示時區改成台灣時間（2026-10-16）

**問題**：內建 admin 帳號（root user）的時區預設是 UTC，搜尋和訊息時間都要自己加 8 小時，很容易看錯（曾因此誤判驗證結果）。admin 的設定寫在 `server.conf`，**網頁上改不了**。

**做法**：在 Graylog 容器內修改設定檔並重啟。進入容器：先在 PVE 節點查 CT 105 在哪一台（`ls /etc/pve/nodes/*/lxc/105.conf`），到那台執行 `pct enter 105`（單獨貼上）。

```bash
cp -a /etc/graylog/server/server.conf /etc/graylog/server/server.conf.bak-$(date +%Y%m%d)
if grep -qE '^#?\s*root_timezone' /etc/graylog/server/server.conf; then
  sed -i -E 's|^#?\s*root_timezone.*|root_timezone = Asia/Taipei|' /etc/graylog/server/server.conf
else
  echo 'root_timezone = Asia/Taipei' >> /etc/graylog/server/server.conf
fi
grep -n 'root_timezone' /etc/graylog/server/server.conf          # 只剩 root_timezone = Asia/Taipei
grep -n 'ROOT_TIMEZONE' /etc/default/graylog-server              # 應無輸出，否則環境變數會蓋過 server.conf
systemctl restart graylog-server                                 # 約 1～2 分鐘，期間 UDP syslog 漏收
GL=$(hostname -I | awk '{print $1}')
curl -s "http://$GL:9000/api/system/lbstatus"; echo              # ALIVE
```

**應該看到**：重新登入後，Preferences 的 Timezone 和搜尋時間範圍下方的「All timezones using」都顯示 Asia/Taipei，Absolute 時間範圍可以直接填台灣時間。

- 只改變**顯示**；資料和 Graylog 內部時間仍是 UTC。
- 以前用 UTC 填的時間範圍 preset 要改成台灣時間。
- 另一種做法：建立個人管理帳號（Admin 角色、時區 Asia/Taipei）日常使用，不必重啟，admin 留作緊急備用。
- 升級 graylog-server 時若 apt 詢問 `server.conf` 要不要覆蓋，選保留現有版本。
- 還原：把 `.bak-日期` 複製回 `server.conf` 並重啟。

### 12-2 套件更新（2026-10-03）

Graylog 容器有 9 個套件待更新：6 個 Debian 安全性更新（openssl、libssl3、libexpat1、liblzma5、xz-utils、tzdata）、2 個 MongoDB 用戶端工具（mongodb-database-tools、mongodb-mongosh），以及 opensearch 2.19.5 → 2.19.6。MongoDB 伺服器與 graylog-server 不在清單中。

Graylog 由三個服務組成，更新時要照順序停、照順序開：

| 服務 | 角色 |
| --- | --- |
| mongod（MongoDB） | 存 Graylog 的設定 |
| opensearch | 存日誌資料、負責搜尋 |
| graylog-server | 主程式與網頁 |

**更新前**：確認三個服務都在跑、OpenSearch 是 `green`，並建快照（說明用英文，避免 listsnapshot 亂碼）：

```bash
pct exec 105 -- systemctl is-active graylog-server mongod opensearch
pct exec 105 -- curl -s 'http://127.0.0.1:9200/_cluster/health?pretty' | grep -E '"status"|number_of_nodes'
pct snapshot 105 pre-apt-20261003 --description "Before apt upgrade (opensearch 2.19.6, openssl)"
```

**更新順序**：停止 graylog-server → `apt-get upgrade`（加 `--force-confold` 保留現有設定檔）→ 重啟 mongod（套用新版 OpenSSL）→ 重啟 opensearch，等到 `green` → 啟動 graylog-server，等 `/api/system/lbstatus` 回 `ALIVE`。

要注意：

- **opensearch 和 graylog-server 被 `apt-mark hold` 鎖住**（Graylog 安裝說明的建議，避免 `apt upgrade` 意外升到不相容的版本），所以第一次 `apt-get upgrade` 只更新了另外 8 個。用 `apt-mark showhold` 確認、`apt-get -s install opensearch` 模擬沒有其他相依變動後，再另外有控制地升級。
- OpenSearch 剛重啟時會短暫是 `red`（資料還在載入），要用 `_cluster/health?wait_for_status=green&timeout=120s` 等，不能只看第一次回應。
- 停止期間 UDP 送來的 syslog 會遺失。

**有控制地升級 opensearch**（先建快照，暫時解鎖、只升這一個、立刻重新鎖定）：

```bash
pct snapshot 105 pre-opensearch-2196 --description "Before opensearch 2.19.5 to 2.19.6"
# 以下在容器內執行
systemctl stop graylog-server
apt-mark unhold opensearch
DEBIAN_FRONTEND=noninteractive apt-get -y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold install opensearch
apt-mark hold opensearch
systemctl restart opensearch
curl -s 'http://127.0.0.1:9200/_cluster/health?wait_for_status=green&timeout=120s'
curl -s http://127.0.0.1:9200 | grep '"number"'        # 執行中的版本
systemctl start graylog-server
curl -s http://<Graylog 位址>:9000/api/system/lbstatus  # ALIVE
```

**結果**：OpenSearch 2.19.6、`green`、分片 100%；Graylog `ALIVE`，啟動後沒有新的 ERROR；`apt-mark showhold` 仍是 graylog-server、opensearch；沒有待更新套件。確認正常後，10/04 刪除兩個快照（`pct delsnapshot 105 <名稱>`）。

### 12-3 要不要升級到 Debian 13？（10/04 查證、10/06 測試）

**結論：正式機暫緩**，原因是 OpenSearch 在 Debian 13 上收不到更新（見下方測試結果）。

10/04 查證：

| 項目 | 結果 |
| --- | --- |
| Graylog 官方支援 | 官方相容性表只列 Debian 12（依搜尋結果摘要，官方文件網站在本環境打不開）；GitHub issue「Support for Debian/trixie v13」（Graylog2/graylog2-server #23512，2025-08-30 提出）仍為 Open |
| MongoDB | 套件庫依 Debian 版本分開；目前用 `bookworm/mongodb-org/8.0`。trixie 版的 Release 檔回 200（但 10/06 測試發現裡面沒有套件，見下表） |
| Graylog、OpenSearch | 內建 Java、不分 Debian 版本，影響較小 |
| 急迫性 | Debian 12 仍在長期支援期，持續收到安全性更新 |

10/06 用**複製出來的測試容器**實測，正式機不受影響：

```bash
pct snapshot 105 pre-clone-trixie --description "Source for Debian 13 upgrade test clone"
pct clone 105 905 --full --snapname pre-clone-trixie --hostname graylog-test --target node12
pct delsnapshot 105 pre-clone-trixie
# 在 node12：改用臨時 IP、不指定 MAC（自動產生新的）、先拔網路線
pct set 905 --net0 name=eth0,bridge=vmbr0,firewall=1,ip=<臨時 IP>/24,gw=<閘道>,link_down=1
pct set 905 --onboot 0
pct start 905
pct exec 905 -- systemctl disable --now wazuh-agent graylog-server   # 避免 Agent 身分衝突與重複告警
# 確認後才接上網路（保留自動產生的 MAC）
pct set 905 --net0 name=eth0,bridge=vmbr0,firewall=1,ip=<臨時 IP>/24,gw=<閘道>,hwaddr=<自動產生的 MAC>
```

> ⚠️ 複製出來的容器，IP、MAC、Wazuh Agent 身分都和正式機一樣，**一定要先斷網**，改好 IP、停用 Agent 和 graylog-server 再接網路。臨時 IP 要先 ping 確認沒人用（`Destination Host Unreachable` 代表沒人回應）；本案曾誤用沒確認過的範例 IP，立刻改回。Graylog 的 `http_bind_address` 寫死正式機 IP，只在測試容器內改成臨時 IP。

升級步驟（容器內）：停止 opensearch、mongod → 備份套件來源 → 把 Debian 與 MongoDB 套件來源的 `bookworm` 改成 `trixie`（OpenSearch、Graylog 不分版本，不用改）→ `apt-get update` → `upgrade --without-new-pkgs` → `full-upgrade`（都加 `--force-confold`）→ `autoremove`。

```bash
sed -i 's/\bbookworm\b/trixie/g' /etc/apt/sources.list
grep -rl bookworm /etc/apt/sources.list.d/ | xargs -r sed -i 's/\bbookworm\b/trixie/g'
```

升級 173 個套件，`full-upgrade` 再升級 84、新增 55、移除 20，變成 Debian 13.7，hold 仍在。重開機後系統、MongoDB（8.0.32）、OpenSearch（green）、Graylog（7.1.9、ALIVE、網頁正常）**都正常**。但套件來源出問題：

| 套件來源 | 問題 | 處理 |
| --- | --- | --- |
| MongoDB | trixie 的套件庫**沒有任何套件**，系統沿用原本的 8.0.32 | 維持 bookworm 來源（bookworm 版本在 Debian 13 上可以正常執行） |
| OpenSearch（金鑰格式） | Debian 13 的 apt 改用 `sqv` 驗證簽章，讀不了舊的 GnuPG keybox 格式（`Failed to parse keyring ... EOF`） | 匯出成標準格式：`gpg --no-default-keyring --keyring <檔案> --export > <新檔>` |
| OpenSearch（SHA1） | 2.x 套件庫仍用 2021 年的金鑰 `C5B7 4989 65EF D1C2 924B A9D5 39D3 1987 9310 D3FC` 簽署，該金鑰用 SHA1，sqv 自 2026-02-01 起拒絕。新金鑰 `A8B2 D9E0 4CD5 1FEF 6AA2 DB53 BA81 D999 8119 1457` 已發布，但 2.x 套件庫還沒改用 | **無法解決**，OpenSearch 在 Debian 13 上無法用 apt 更新 |

> 升級過程中的 `apt-get update` 還是 Debian 12 的 apt，所以不會報錯；要升級完成、用新的 apt 再執行一次才會發現金鑰問題。

**可以升級的條件**：OpenSearch 2.x 套件庫改用新金鑰簽署。每月檢查一次（已排入 Google Calendar 每月第一個週一）：

```bash
curl -s https://artifacts.opensearch.org/releases/bundle/opensearch/2.x/apt/dists/stable/InRelease | gpg --verify 2>&1 | grep -iE 'key|using'
```

顯示的金鑰變成 `A8B2…1457`（或其他 SHA256 金鑰）時就可以升級，屆時：MongoDB 來源維持 bookworm、OpenSearch 金鑰換成新金鑰的標準格式。

測試容器已刪除（`pct stop 905 && pct destroy 905 --purge`）；要再測時從 CT 105 重新複製（6.7 GB，約 1 分鐘）。

**正式機升級計畫**（條件成立後）：

| 項目 | 做法 |
| --- | --- |
| 時段 | 停機約 20～30 分鐘，UDP syslog 會漏收；選離峰，避開 21:00 備份 |
| 保護 | 確認前一晚 PBS 備份成功，升級前建快照 |
| 服務 | 先停 graylog-server；Wazuh Agent 維持啟用；`http_bind_address` 不用改 |
| 重開機 | CT 105 是 HA 資源，從容器內執行 `reboot` |
| 驗證 | 同測試項目，另外確認 Wazuh Agent、LibreNMS 輪詢、Graylog 有收到新日誌 |
| 收尾 | 快照觀察數天後刪除 |

## 13. 常見問題與踩雷

| 現象 | 原因 | 怎麼辦 |
| --- | --- | --- |
| 搜尋 0 筆 | 時間範圍或條件太窄 | 放寬條件、拉長時間，先找到原始訊息（4-4） |
| 新規則沒有替舊訊息加欄位 | 規則只處理「之後進來」的訊息 | 用新訊息測試；舊資料不會回填 |
| `Rule ... has been renamed or removed. This rule will be skipped.` | 規則改名後，Stage 還引用舊名稱 | 到 Stage 移除舊引用、加入新規則；規則清單有新名稱 ≠ Stage 已更新 |
| 規則加了，後面的處理卻消失 | 放進「全部符合才繼續」的 Stage | 新規則放在 None or more rules match 的 Stage（5-1） |
| `src_host:*` 出現 `'*' or '?' not allowed as first character in WildcardQuery` | 萬用字元不能放開頭 | 改用 `_exists_:src_host` |
| Rule Simulation 每一筆都顯示 Not stored | 模擬本來就不寫入索引 | 用 `set_field("would_drop", "yes")` 測試（7-3） |
| 時間差 8 小時 | admin 帳號時區是 UTC | 照 12-1 改時區 |
| 改時區後，查詢結果怪怪的 | 舊的 Absolute 範圍被自動平移 8 小時 | 重新填台灣時間 |
| `curl` 打 API 回 `http=000` | Graylog 監聽容器 IP，不是 127.0.0.1 | 用 `GL=$(hostname -I \| awk '{print $1}')` |
| `curl` 打 API 回 `http=401` | admin 帳號或密碼錯誤 | 確認帳號（`root_username`，預設 admin）；或用暫時 token（11-1） |
| jt-ipam 查不到主機名稱 | Data Adapter 欄位從 0 起算 | Key column 0、Value column 1（6-3） |
| OpenSearch 重啟後是 red | 資料還在載入 | `wait_for_status=green` 等它（12-2） |
| 告警信看不出是哪台出問題 | 預設範本只把整筆訊息倒出來 | 依 11-3 的表判讀；改中文範本列入待辦 |
| 重啟 Graylog 後少了一段日誌 | UDP 不重送 | 屬預期，重啟要避開重要時段 |
| 收到【NAS 連不上】或 `[tokyo16]` 複寫失敗信 | NAS 或複寫出問題 | 依 11-7「收到信時怎麼查」 |
| Graylog 搜不到快照複寫的紀錄 | 複寫日誌在套件自己的日誌頁，不在 DSM 記錄中心 | 到 Snapshot Replication → 日誌查看或匯出 CSV |
| DSM API 登入回 402 | 一般帳號用了自訂的 `session` 名稱，或沒有 DSM 應用程式權限 | `session=webui`，並允許 DSM 權限 |
| `read -s` 讀進來的密碼少一個字 | 沒加 `-r` 時反斜線會被吃掉 | 改用 `read -rs` |
| 收到【備份檢查異常】信 | 有 VM／CT 太久沒備份、驗證失敗或沒被備份 | 依 11-8「收到信時怎麼查」 |
| 失敗信混在每天的成功信裡沒看到 | PVE、PBS 成功也會寄信 | Gmail 篩選器：主旨含「失敗」→ 加星號、標示為重要 |
| 收到【Graylog 異常】信 | Graylog 本身出問題，信是節點直接寄的 | 依 11-6「收到異常信時怎麼查」 |
| 早上沒收到【每日健康回報】 | 告警鏈某處斷了（含 Gmail 寄信失敗） | 先看有沒有【Graylog 異常】信；再到 Search 搜 `"GRAYLOG_DAILY_HEARTBEAT"`、看 Event Definition 的 Last Matched |
| `read -s` 存進去的不是 token | `read -s` 那行和下一段指令一起貼上，下一行被當成輸入 | `read -s` 單獨貼上、輸入完再貼下一段；token 改用 API 建立直接寫檔（11-6） |
| 每秒處理量常常是 0 | 日誌是一陣一陣進來的 | 判斷「有沒有在收」改用累計數字（11-6） |

## 14. 待辦

| 項目 | 說明 |
| --- | --- |
| 中文通知信範本 | 預設信件把 Backlog 整筆欄位倒出，`Source` 顯示 Graylog 本身，看不出哪台出問題。改為中文自訂範本：Subject、Body Template、HTML Body Template，用 `${foreach backlog message}` 列出 `${message.source}` 與 `${message.message}`；先用 Execute Test Notification 測試，注意 `${message.timestamp}` 可能是 UTC。先確認 Alerts → Notifications 有幾個通知、各告警共用哪一個 |
| 驗證 Summary Template | `PVE 任務失敗：${source.message}` 能否帶出原始訊息；補齊 node、task、VM／CT ID、UPID 與錯誤內容 |
| 完善看板 | 沿用任務看板，再加入節點、服務、登入等統計與異常明細 |
| PBS 的認證事件 | 確認 PBS 的登入與 sudo 是否也要分類 |
| 每月看一次 Snapshot Replication | 補上 11-7 抓不到的「排程被改掉」情況：確認六個任務都是「成功」、最近一次執行是前一天 |
| DSM 日誌過濾器 | 確認兩台 NAS 送出哪些種類的日誌 |
| 觀察磁碟用量 | 一週後決定是否也丟棄 PBS 的寫入紀錄 |
| postfix 舊參數 | 三台 `main.cf` 的 `smtp_use_tls` 將被移除，改成 `smtp_tls_security_level = encrypt`；改前先寄測試信確認、改後再寄一次 |
| 其他新告警的測試 | 每個新告警都安排安全、可控的測試事件，記錄原始訊息、欄位、事件、收信時間與 Grace 下的重複通知情形 |
| TP-Link 整合 | 尚未列入 |

## 15. 延伸閱讀與下載

- [PVE 告警實測紀錄（更新至 2026-09-22）](https://kbwangtw.github.io/IT-Knowledge-Base/docs/pve/graylog-pve-alert-validation-2026-09-18/)：告警的真實日誌證據與 logger 安全測試
- [jt-ipam 導入紀錄](https://kbwangtw.github.io/IT-Knowledge-Base/docs/network/jt-ipam-adoption-itbh/)：IP 管理系統與 Graylog 整合
- [不再把 PVE 8006 開到網際網路：改用 WireGuard 連回家](https://kbwangtw.github.io/IT-Knowledge-Base/docs/pve/wireguard-remote-access-replace-8006/)：WireGuard VPN 異常告警的建置
- [把 PVE／PBS 通知改成繁體中文](https://kbwangtw.github.io/IT-Knowledge-Base/docs/pve/proxmox-zh-tw-notification/)：PVE／PBS 本身寄的通知信（和 Graylog 告警是兩套機制）
- [Graylog 官方文件](https://go2docs.graylog.org/current/home.htm)、[Graylog Compatibility Matrix](https://go2docs.graylog.org/current/downloading_and_installing_graylog/compatibility_matrix.htm)、[Graylog2/graylog2-server#23512](https://github.com/Graylog2/graylog2-server/issues/23512)

[下載同版 Markdown]({{ '/assets/downloads/Proxmox_Graylog_SOP_public.md' | relative_url }})：文字版與本文同步；倉庫裡較早的 Word 檔是歷史附件，沒有同步這次改寫。
