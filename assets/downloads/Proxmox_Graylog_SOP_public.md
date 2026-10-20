# 把 PVE、PBS 與 NAS 的日誌集中到 Graylog（一）：收集、分類與寄信設定

> **一句話**：把散在各台主機上的日誌（log）全部送到同一台 Graylog，讓你在一個畫面搜尋、看統計，出問題時自動寄 Email 通知。

| 項目 | 內容 |
| --- | --- |
| 適合誰看 | 第一次接觸「集中式日誌」與 Graylog 的人；或要維護這套環境的人 |
| 收集對象 | PVE 三台節點（node10～12）、PBS31、兩台 Synology NAS（tokyo16、melayu17） |
| 環境 | Graylog 7.1.11（10/20 由 7.1.9 升級，11-2），裝在 PVE 叢集上的 LXC 容器（CT 105，Debian 12） |
| 目前狀態 | 收集、分類、主機名稱查表、Gmail 寄信都已運作並驗證；14 個告警與各項監控見下篇；看板 10/20 盤點修正並新增「趨勢與明細」分頁（第 8 節） |
| 下篇 | [Graylog 告警與監控（二）：告警清單與監控腳本](https://kbwangtw.github.io/IT-Knowledge-Base/docs/pve/graylog-alerts-monitoring/)：全部告警、PVE 監控腳本、監控 Graylog 本身、NAS 複寫與備份監控、中文告警信、postfix |
| 第三篇 | [Graylog 告警與監控（三）：中文告警信與摘要](https://kbwangtw.github.io/IT-Knowledge-Base/docs/pve/graylog-alert-templates/)：13 個通知的中文範本、主旨、每個告警的摘要寫法 |
| 紀錄期間 | 2026-09-17 起陸續建置，最後更新 2026-10-19 |

**這篇怎麼讀**：

- 第一次接觸：先讀第 1～3 節，弄懂名詞、全貌和目前狀態。
- 要動手做某件事：直接跳到對應章節，每一節都有「做什麼 → 怎麼做 → 應該看到什麼」。
- 出了問題：先看第 12 節「常見問題與踩雷」；收到某種告警信時，看下篇第 10 節。
- 本文提到「下篇」都是指上表的〈Graylog 告警與監控（二）〉。

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
                    ├─ 搜尋、看「PVE 任務監控」「PVE 基礎架構監控」看板
                    └─ 由 14 個 Event Definition 檢查 → 符合條件 → Gmail 告警
```

另外，PVE 節點上有兩支**監控腳本**，每 1 分鐘、每 5 分鐘檢查一次節點和儲存空間，有異常就寫一筆日誌，再由 Graylog 告警（下篇第 4-1 節）。

| 來源 | 送到哪裡 | 設定方式 | 章節 |
| --- | --- | --- | --- |
| PVE node10～12 | UDP 1514 | rsyslog | 4-1 |
| PBS31 | UDP 1514 | rsyslog（需先安裝） | 4-2 |
| tokyo16、melayu17 | UDP 1515 | DSM 記錄中心的「記錄傳送」 | 4-3 |

Infrastructure Syslog 的實際索引名稱是 `infra_syslog_` 加上編號（Index Set `infra_syslog` 底下的索引）。Graylog 會定期輪替成新索引，編號會一直增加：一開始是 `infra_syslog_0`，2026-10-19 已是 `infra_syslog_8`，這是正常的。

## 3. 目前做到哪裡

| 範圍 | 狀態 |
| --- | --- |
| 收集 | ✅ 三台 PVE、PBS31（10/08 加入）、兩台 NAS 都已確認收到 |
| 分類（Pipeline） | ✅ 主機、服務、任務、認證、系統錯誤分類；PBS 識別；NAS 登入解析 |
| 主機名稱查表 | ✅ 10/15 接上 jt-ipam，訊息中的 IP 自動補上 `src_host` |
| 雜訊過濾 | ✅ 10/16 丟棄 PBS 讀取 NAS 產生的大量紀錄，tokyo16 每天少了約 7 萬筆 |
| 告警 | ✅ 14 個告警運作中，全部寄 Gmail；10/16 盤點並修正 3 項設定；10/19 加入「每日健康回報」（下篇第 3 節） |
| 監控 Graylog 本身 | ✅ 10/19 三台 PVE 每 5 分鐘從外部檢查，異常直接用 postfix 寄信；每日 08:00 健康回報驗證整條告警鏈（下篇第 5 節） |
| NAS 快照複寫 | ✅ 10/19 複寫失敗、停止由 tokyo16 DSM 寄信；兩台 NAS 是否回應由三台 PVE 每 5 分鐘檢查（下篇第 6 節） |
| 備份 | ✅ PVE 備份、PBS GC／Verify 失敗本來就會寄信；10/19 加上每天 08:30 檢查每台 VM／CT 的最新備份與驗證結果（下篇第 7 節） |
| 看板 | ✅「PVE 任務監控」8 個 Widget；10/20「PVE 基礎架構監控」修正 5 個查詢、補 3 個數字，新增「趨勢與明細」分頁（第 8 節） |
| 告警信格式 | ✅ 10/19 十三個通知改用同一份中文範本，信裡直接列出時間、主機、原始訊息（[第三篇](https://kbwangtw.github.io/IT-Knowledge-Base/docs/pve/graylog-alert-templates/)） |

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
| `@` | **一個** @ 代表用 UDP 送；兩個 11- 才是 TCP |
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
| **melayu17** | tokyo16 的快照複寫目的地（最後一道防線；複寫與連線監控見下篇第 6 節） |

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
| PVE-Authentication Events | 標記認證相關訊息（`event_category=authentication`）；PBS 的登入失敗另由 Stage 1 的規則補標（5-3） |
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

**PBS 登入失敗（10/20 新增）**

做什麼：PBS 的登入失敗有三種寫法，原本的認證規則只標到第一種，另外兩種沒有 `event_category=authentication`，告警也就抓不到：

```text
proxmox-backup-proxy[664]: authentication failure; rhost=[::ffff:127.0.0.1]:47768 msg=user account or token disabled or expired.
proxmox-backup-api[569]: authentication failure; rhost=[::ffff:127.0.0.1]:52058 user=<PBS 帳號> msg=authentication error - AUTH_ERR (7)
proxmox-backup-api: pam_unix(proxmox-backup-auth:auth): authentication failure; logname= uid=0 euid=0 tty= ruser= rhost=::ffff:127.0.0.1 user=<PBS 帳號>
```

怎麼做：在 Stage 1 加一條規則，只挑 PBS 訊息裡有「authentication failure」的。放 Stage 1 是因為 `device_type=pbs` 在 Stage 0 才加上，到下一關一定讀得到：

```text
rule "PBS - Authentication Failures"
when
    to_string($message.device_type) == "pbs"
    &&
    contains(to_string($message.message), "authentication failure", true)
then
    set_field("event_category", "authentication");
end
```

| 片段 | 意思 |
| --- | --- |
| `device_type == "pbs"` | 只看 PBS31 的訊息 |
| `contains(..., "authentication failure", true)` | 訊息有這段字（`true`＝不分大小寫）；CRON、SSH 的 `session opened` 不會被標到 |
| `set_field("event_category", "authentication")` | 標成認證事件，下篇的「多次驗證失敗」告警才抓得到 |

看到的結果：

- Rule Simulation（JSON：`{"source":"pbs31","device_type":"pbs","message":"proxmox-backup-api: pam_unix(proxmox-backup-auth:auth): authentication failure; user=root"}`）多出 `event_category: authentication`。
- 加入 Stage 1 後，在 PBS31 用 `logger` 送 3 筆假失敗（指令在下篇 3-2），`source:pbs31 AND event_category:authentication` 找到 3 筆，並收到【PVE／PBS 多次驗證失敗】信。

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
| 有補上主機名稱的訊息 | `_exists_:src_host`（`src_host:*` 會出錯，見第 12 節） |
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

> 查詢時間範圍要注意時區（第 11-1 節）：改時區後，原本以 UTC 填的 Absolute 範圍會被平移 8 小時。

## 8. 看板

| 看板 | 用途 | Widget |
| --- | --- | --- |
| PVE 任務監控 | PVE 工作（備份、遷移、開機…）的成功／失敗 | 8 個（8-1） |
| PVE 基礎架構監控 | 「現在有沒有事」＋「這週發生過什麼」 | 兩個分頁共 17 個（8-2～8-4） |
| Sources | Graylog 內建的日誌量看板 | 不用管 |

### 8-1 「PVE 任務監控」

9/17 建立了八個 Widget；10/20 用 API 盤點，查詢與 Stream 都正確，維持原樣。

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

### 8-2 用 API 盤點每個 Widget 的查詢（2026-10-20）

**做什麼**：看板是 9 月建的，之後告警的查詢改過好幾次。一個一個點 Edit 太慢，改用 API 一次列出所有 Widget 的查詢、Stream 數與時間範圍（唯讀）。

**怎麼做**（在 node10；密碼用 `read -rsp` 單獨貼上）：

```bash
read -rsp "Graylog admin 密碼：" GLPW; echo
```

```bash
cat > /root/gl-dash-inventory.py <<'EOF2'
import json, os, base64, urllib.request
url = os.environ["GL_URL"].rstrip("/")
auth = base64.b64encode(("admin:" + os.environ["GLPW"]).encode()).decode()
def get(path):
    req = urllib.request.Request(url + path, headers={"Authorization": "Basic " + auth, "Accept": "application/json"})
    return json.load(urllib.request.urlopen(req, timeout=15))
r = get("/api/dashboards?per_page=100")
for s in r.get("views") or r.get("elements") or []:
    v = get("/api/views/" + s["id"])
    print("######", v["title"])
    for qid, st in (v.get("state") or {}).items():
        titles = (st.get("titles") or {})
        print("  分頁:", titles.get("tab", {}).get("title", qid))
        for w in st.get("widgets") or []:
            q = (w.get("query") or {}).get("query_string", "")
            tr = w.get("timerange") or {}
            print("  ==", titles.get("widget", {}).get(w["id"], "(無標題)"), "|", w.get("type"))
            print("     查詢:", q or "（空白）")
            print("     Stream 數:", len(w.get("streams") or []), "| 範圍:", tr.get("type"), tr.get("range", ""))
EOF2
. /root/.graylog-monitor.conf
GL_URL="$GL_URL" GLPW="$GLPW" python3 /root/gl-dash-inventory.py
unset GLPW
```

| 片段 | 意思 |
| --- | --- |
| `/api/dashboards` | 看板清單，**只有標題和 ID**，沒有 Widget 設定 |
| `/api/views/<ID>` | 用 ID 讀完整設定，`state` 裡才有每個分頁的 Widget |
| `query_string` | Widget 自己的查詢，拿來和告警的 Search Query 比對 |
| `Stream 數` | 0 代表搜尋全部 Stream |

**看到的結果**：「PVE 基礎架構監控」10 個數字 Widget 裡有 5 個和告警（下篇 3-2）對不上，其中 4 個**永遠是 0**，會讓人誤以為一切正常：

| Widget | 原本的查詢 | 改成（和告警相同） |
| --- | --- | --- |
| PVE 儲存設備離線數 | `message:"STORAGE_OFFLINE"`（腳本根本不會送這個字） | `message:"STORAGE_UNAVAILABLE"` |
| PVE 多次驗證失敗數 → **PVE/PBS 驗證失敗數** | `message:"AUTH_FAILURE"` | `device_type:("pve" OR "pbs") AND event_category:"authentication" AND (message:failure OR message:failed)` |
| PVE 服務異常數 | `message:"PVE_SERVICE_FAILED"` | `device_type:"pve" AND event_category:"system_error" AND message:"Failed with result"` |
| DSM 登入失敗數 | 比對 `failed to sign in to`… 文字 | `synology_auth_result:failed AND synology_service:DSM`（Stream：Synology Syslog） |
| PVE Node 離線數 | `"PVE_NODE_OFFLINE"` | `"PVE_NODE_OFFLINE" OR "PVE_NODE_MONITOR_ERROR"` |

改法：Widget 右上角 **⋮ → Edit** → 改查詢 → **Update widget**；全部改完按看板右上角 **Save**（沒按 Save 不會保存，API 也讀不到）。改完再跑一次腳本確認。

> 之後改告警的 Search Query 時，要一起改看板上對應的 Widget；改完跑這支腳本對照。

### 8-3 第一頁「IT 基礎架構監控」：現在有沒有事（全部 1 天）

10/20 補上告警清單有、看板沒有的 3 個，共 13 個數字（Visualization：Single Number）：

| Widget | 查詢 | Stream | 正常值 |
| --- | --- | --- | --- |
| WireGuard VPN 異常數 | `source:wazuh AND "WireGuard ct:109"` | 全部 | 0 |
| DSM 管理員登入數 | `message:"User [<NAS 管理員帳號>]" AND message:"signed in to [DSM] successfully"` | Synology Syslog | 自己登入的次數 |
| Graylog 每日心跳數 | `"GRAYLOG_DAILY_HEARTBEAT"` | 全部 | **3**（少於 3：有節點沒送；多於 3：有人手動測試） |

其餘 10 個（Ceph、Corosync、Node 離線、任務失敗、儲存 ×3、服務異常、驗證失敗、DSM 登入失敗）的查詢和下篇 3-2 的告警相同。

- 第一頁回答「現在有沒有事」：**心跳 3、其他 0** 就是正常。
- 數字算的是**訊息筆數**，不是告警次數。例如驗證失敗數算每一筆失敗，告警則要「同一台 5 分鐘 ≥ 3 次」才觸發。
- 要臨時換時間範圍，用看板最上方的 **No Override** 時間選擇器，整頁一起換；看完切回 No Override，不要存檔。

### 8-4 第二頁「趨勢與明細」：這週發生過什麼（全部 7 天）

**做什麼**：第一頁看到非 0，到這一頁看是哪台、什麼時候、哪一筆。同一頁統一用 7 天，標題都加上「（7 天）」。

**怎麼做**：點分頁列「IT 基礎架構監控 ▾」右邊的 **＋** 新增分頁，▾ → **Edit Title** 改名；確認停在新分頁，再從左側 **＋ → Message Count**（或 Message Table）新增 Widget。

| Widget | 查詢 | 分組（Group By） | 圖表 |
| --- | --- | --- | --- |
| 各主機日誌量趨勢 | （空白，全部 Stream） | timestamp（Row，Interval Auto）＋ source（Column，Limit 20） | Line Chart |
| 驗證失敗趨勢 | 同第一頁的驗證失敗 | timestamp（Row）＋ source（Column） | Bar Chart |
| DSM 登入失敗來源 | `synology_auth_result:failed AND synology_service:DSM`（Synology Syslog） | 同一個 Group By 放 synology_src_ip、source（Row）；Sort：Message Count Descending | Data Table |
| 最近異常明細 | 所有告警條件用 OR 串起來（下方） | —（Message Table，欄位 timestamp、source，訊息另起一行） | — |

```text
"PVE_NODE_OFFLINE" OR "PVE_NODE_MONITOR_ERROR" OR "STORAGE_CRITICAL" OR "STORAGE_WARNING" OR "STORAGE_UNAVAILABLE" OR pve_event_type:task_failed OR (message:corosync AND message:"Members left:") OR (message:"Health check failed:" AND NOT message:"cmd=" AND NOT message:"dispatch" AND NOT message:"finished") OR (device_type:"pve" AND event_category:"system_error" AND message:"Failed with result") OR (device_type:("pve" OR "pbs") AND event_category:"authentication" AND (message:failure OR message:failed)) OR (synology_auth_result:failed AND synology_service:DSM) OR (source:wazuh AND "WireGuard ct:109")
```

| 介面位置（Graylog 7.1.9） | 說明 |
| --- | --- |
| Group By 的 **＋** | 在 Group By 那一行最右邊；Visualization 是 Single Number 時不會出現，先改成 Line／Bar Chart 或 Data Table |
| Metrics 的 Field | 維持空白（Count 算筆數）；時間要放在 Group By，不是 Metrics |
| Sort 的 **＋** | 新增後才會出現 Field（選 Message Count）和 Direction（Descending） |

**看到的結果（10/20）**：第一頁的非 0 數字全部在「最近異常明細」找到原因，**沒有真的異常**：

| 第一頁 | 原因 |
| --- | --- |
| Ceph 2、Corosync 1、儲存空間嚴重 1 | 10/19 15:36、17:09 改「每筆」與摘要時的 `TEST_ONLY` 測試訊息 |
| WireGuard 1 | 10/19 17:00:35 ct:109 遷移到 node11，WGDashboard 還在啟動（`wg0=up dashboard=activating`） |
| 驗證失敗 6 | 10/20 PBS 認證規則的 logger 測試（5-3） |
| 心跳 4 | 10/19 14:29 範本測試手動送的 1 筆＋當天 3 筆排程 |
| DSM 登入失敗來源：melayu17 9 次 | 10/19 從 node10 測試 DSM API 登入（下篇第 6 節）與一次手動登入 |

「各主機日誌量趨勢」另外抓到 **pbs31 在 10/19 13:26～13:31 送了約 648 萬筆**（每秒約 2 萬筆，是同時段一台 PVE 節點的 350 倍）。縮小時間範圍到 10 秒後，全是同一行：

```text
proxmox-backup-proxy[664]: list groups error on datastore zhtest - EACCES: Permission denied
```

原因是測試中文通知時，把測試用 datastore 的資料夾權限拿掉（見 [中文通知文件](https://kbwangtw.github.io/IT-Knowledge-Base/docs/pve/proxmox-zh-tw-notification/)常見問題）；權限改回、zhtest 刪除後就停了，不會再發生。這批資料會隨索引輪替（14～18 天）消失；在那之前，點圖例的 pbs31 可以暫時隱藏它。

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

當時填的 Event Summary Template 是 `PVE 任務失敗：${source.message}`，當時還沒驗證這個變數能不能帶出原始訊息（10/19 已驗證可以，並改成結構化摘要，見[第三篇](https://kbwangtw.github.io/IT-Knowledge-Base/docs/pve/graylog-alert-templates/)第 8 節）。建好時 Last Matched 是 Never（當時沒有新的失敗），這不代表規則壞了，也不能當作告警已通過的證據；9/22 已用 5-5 節的合成訊息確認 Last Matched 更新並收到正式告警信。

### 10-2 建立通知並綁定

| 項目 | 設定 |
| --- | --- |
| Notification Title | PVE 任務失敗通知 |
| Type | Email Notification |
| Description | 當 Proxmox VE 任務執行失敗時發送警報通知 |
| Subject | 當時是 `【Graylog 警報】${event_definition_title}`；10/19 改為 `【PVE 任務告警】${event_definition_title}`（[第三篇](https://kbwangtw.github.io/IT-Knowledge-Base/docs/pve/graylog-alert-templates/)） |
| 寄件人／收件人 | 已核對正確的 Gmail 地址（公開文件不列） |
| Time zone | Taipei，測試信顯示 +08:00 |
| Body／HTML Body Template | 當時保留 Graylog 預設範本；10/19 改為中文範本（[第三篇](https://kbwangtw.github.io/IT-Knowledge-Base/docs/pve/graylog-alert-templates/)） |
| 測試 | 2026-09-18 實際收到，信內時間 14:28:26.023+08:00 |

收到測試信後，回到「PVE 任務失敗警報」→ Edit → **Notifications**，加入「PVE 任務失敗通知」，Grace Period 5 分鐘，最後按 **Update event definition**，看到 `Event Definition "PVE 任務失敗警報" was updated successfully.` 才算存好（只在下拉選單選到通知不算）。

Message Backlog 當時是 0，Summary 會顯示 `Notifications will not include any messages.`，意思是信裡不附原始訊息，不是通知沒綁上。**10/16 已改為 5**（下篇第 4-2 節）。

> 其餘 13 個告警的清單、背後的監控腳本，以及 2026-10-16 的盤點修正，都在下篇第 3、4 節。

## 11. 日常維運

### 11-1 把顯示時區改成台灣時間（2026-10-16）

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

### 11-2 套件更新（2026-10-03）

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

**2026-10-20：Graylog 7.1.9 → 7.1.11，同時更新 MongoDB 與 Debian 安全性套件**

做什麼：同一條 7.1 線的修補版（10/19 發佈）；同一次停機一起更新 MongoDB 8.0.32 → 8.0.34 與 pcre2、perl、python3.11 的安全性更新，只建一次快照。

升級前檢查（在 CT 105 所在節點；10/20 是 node11）：

```bash
pct exec 105 -- systemctl is-active graylog-server mongod opensearch
pct exec 105 -- curl -s 'http://127.0.0.1:9200/_cluster/health?pretty' | grep -E '"status"|number_of_nodes'
pct exec 105 -- apt-mark showhold
pct exec 105 -- apt-get update -qq
pct exec 105 -- apt-cache policy graylog-server | head -4
pct exec 105 -- apt-get -s install graylog-server | grep -E '^(Inst|Conf|Remv)'
pct exec 105 -- apt list --upgradable 2>/dev/null
```

看到的結果：三個 active、`green`、hold 是 graylog-server 與 opensearch；Installed `7.1.9-1`、Candidate `7.1.11-1`；模擬只有 `Inst`／`Conf graylog-server` 兩行（`-s` 只模擬，不安裝）。

升級（先 `pct snapshot 105 pre-graylog-7111 --description "Before graylog 7.1.11, mongodb 8.0.34, debian security"`，再 `pct enter 105`）：

```bash
systemctl stop graylog-server
DEBIAN_FRONTEND=noninteractive apt-get -y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold upgrade
systemctl restart mongod
systemctl is-active mongod
mongod --version | head -1
apt-mark unhold graylog-server
DEBIAN_FRONTEND=noninteractive apt-get -y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold install graylog-server
apt-mark hold graylog-server
apt-mark showhold
systemctl start graylog-server
GL=$(hostname -I | awk '{print $1}')
for i in $(seq 1 30); do s=$(curl -s http://$GL:9000/api/system/lbstatus); echo "$i $s"; [ "$s" = ALIVE ] && break; sleep 10; done
journalctl -u graylog-server --since "10 min ago" --no-pager | grep -c ERROR
```

| 片段 | 意思 |
| --- | --- |
| `apt-get … upgrade` | 只更新沒被 hold 的套件（17 個：MongoDB 與安全性更新）；graylog-server 顯示 kept back |
| `restart mongod` | 套用新版 MongoDB（graylog-server 已先停） |
| `unhold` → `install graylog-server` → `hold` | 暫時解鎖、只升這一個、立刻鎖回 |
| `for … lbstatus` | 每 10 秒問一次，最多 5 分鐘，等到 `ALIVE` |

看到的結果：mongod `v8.0.34`；`server.conf` 出現「Keeping old config file as default」（`--force-confold` 保留現有設定，新版預設檔另存為 `server.conf.dpkg-dist`）；啟動後第 2 次檢查（約 10 秒）就 `ALIVE`，ERROR 0 行；之後 `apt-get upgrade` 沒有待更新套件。

升級後確認：

```bash
dpkg-query -W graylog-server mongodb-org-server opensearch
curl -s http://$GL:9000/api/ ; echo
```

| 項目 | 結果 |
| --- | --- |
| 版本 | graylog-server `7.1.11-1`、mongodb-org-server `8.0.34`、opensearch `2.19.6`（未變） |
| API 回報 | `"version":"7.1.11+080dbb0"` |
| 服務 | 三個 active；hold 仍是 graylog-server、opensearch |
| 停機 | 停 graylog-server 到 `ALIVE` 約 1～2 分鐘 |

- apt 執行時出現 `perl: warning: Setting locale failed`：容器沒有產生 `en_US.UTF-8` 語系，不影響升級與 Graylog。
- `dpkg -l graylog-server | grep ^ii` 這次沒有輸出，改用 `dpkg-query -W` 確認版本。
- 快照 `pre-graylog-7111` 觀察一天正常後刪除（⏳）。

### 11-3 要不要升級到 Debian 13？（10/04 查證、10/06 測試）

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

## 12. 常見問題與踩雷

| 現象 | 原因 | 怎麼辦 |
| --- | --- | --- |
| 搜尋 0 筆 | 時間範圍或條件太窄 | 放寬條件、拉長時間，先找到原始訊息（4-4） |
| 新規則沒有替舊訊息加欄位 | 規則只處理「之後進來」的訊息 | 用新訊息測試；舊資料不會回填 |
| `Rule ... has been renamed or removed. This rule will be skipped.` | 規則改名後，Stage 還引用舊名稱 | 到 Stage 移除舊引用、加入新規則；規則清單有新名稱 ≠ Stage 已更新 |
| 規則加了，後面的處理卻消失 | 放進「全部符合才繼續」的 Stage | 新規則放在 None or more rules match 的 Stage（5-1） |
| `src_host:*` 出現 `'*' or '?' not allowed as first character in WildcardQuery` | 萬用字元不能放開頭 | 改用 `_exists_:src_host` |
| Rule Simulation 每一筆都顯示 Not stored | 模擬本來就不寫入索引 | 用 `set_field("would_drop", "yes")` 測試（7-3） |
| 看板數字一直是 0，但告警有寄信 | Widget 的查詢和告警不同（例如告警改過、看板沒跟著改） | 用 8-2 的腳本列出 Widget 查詢，和下篇 3-2 對照 |
| 「各主機日誌量趨勢」某台突然暴增到幾百萬筆 | 程式反覆寫同一條錯誤（10/19 pbs31 的 `list groups error … EACCES`） | 把 Search 時間縮到 10 秒看是哪一行；先修好原因，這批資料隨索引輪替消失 |
| 時間差 8 小時 | admin 帳號時區是 UTC | 照 11-1 改時區 |
| 改時區後，查詢結果怪怪的 | 舊的 Absolute 範圍被自動平移 8 小時 | 重新填台灣時間 |
| `curl` 打 API 回 `http=000` | Graylog 監聽容器 IP，不是 127.0.0.1 | 用 `GL=$(hostname -I \| awk '{print $1}')` |
| `curl` 打 API 回 `http=401` | admin 帳號或密碼錯誤 | 確認帳號（`root_username`，預設 admin）；或用暫時 token（下篇 3-1） |
| jt-ipam 查不到主機名稱 | Data Adapter 欄位從 0 起算 | Key column 0、Value column 1（6-3） |
| OpenSearch 重啟後是 red | 資料還在載入 | `wait_for_status=green` 等它（11-2） |
| 重啟 Graylog 後少了一段日誌 | UDP 不重送 | 屬預期，重啟要避開重要時段 |
| PBS31 出現 `authentication failure`，來源是 127.0.0.1 | 本機程式或 CLI 用了過期 token／錯誤帳密（10/19 13:32–13:33 的 4 筆來自測試時過期的 token 與 CLI 登入，不是攻擊） | 看 `user=` 與 `msg=` 找出是哪個帳號或 token；來源是外部 IP 才當成可疑登入處理 |

告警、監控腳本、NAS 複寫與備份檢查相關的問題（收到某種告警信時怎麼查）在下篇第 10 節。

## 13. 待辦

| 項目 | 說明 |
| --- | --- |
| DSM 日誌過濾器 | 確認兩台 NAS 送出哪些種類的日誌 |
| 觀察磁碟用量 | 一週後決定是否也丟棄 PBS 的寫入紀錄 |

告警相關的待辦（Summary Template、新告警測試、單節點故障演練、每月看 Snapshot Replication）在下篇第 11 節。

## 14. 延伸閱讀與下載

- [Graylog 告警與監控（二）：告警清單與監控腳本](https://kbwangtw.github.io/IT-Knowledge-Base/docs/pve/graylog-alerts-monitoring/)：下篇
- [Graylog 告警與監控（三）：中文告警信與摘要](https://kbwangtw.github.io/IT-Knowledge-Base/docs/pve/graylog-alert-templates/)：第三篇
- [PVE 告警實測紀錄（更新至 2026-09-22）](https://kbwangtw.github.io/IT-Knowledge-Base/docs/pve/graylog-pve-alert-validation-2026-09-18/)：告警的真實日誌證據與 logger 安全測試
- [jt-ipam 導入紀錄](https://kbwangtw.github.io/IT-Knowledge-Base/docs/network/jt-ipam-adoption-itbh/)：IP 管理系統與 Graylog 整合
- [不再把 PVE 8006 開到網際網路：改用 WireGuard 連回家](https://kbwangtw.github.io/IT-Knowledge-Base/docs/pve/wireguard-remote-access-replace-8006/)：WireGuard VPN 異常告警的建置
- [把 PVE／PBS 通知改成繁體中文](https://kbwangtw.github.io/IT-Knowledge-Base/docs/pve/proxmox-zh-tw-notification/)：PVE／PBS 本身寄的通知信（和 Graylog 告警是兩套機制）
- [Graylog 官方文件](https://go2docs.graylog.org/current/home.htm)、[Graylog Compatibility Matrix](https://go2docs.graylog.org/current/downloading_and_installing_graylog/compatibility_matrix.htm)、[Graylog2/graylog2-server#23512](https://github.com/Graylog2/graylog2-server/issues/23512)
