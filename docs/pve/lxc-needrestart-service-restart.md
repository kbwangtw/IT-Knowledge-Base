---
layout: default
title: "LXC 自動更新後，怎麼檢查「待重啟的服務」：逐一重啟 dbus 的坑與整個容器重開"
date: 2026-10-25
categories: [PVE, LXC]
permalink: /docs/pve/lxc-needrestart-service-restart/
last_modified_at: 2026-10-29
---

# LXC 自動更新後，怎麼檢查「待重啟的服務」：逐一重啟 dbus 的坑與整個容器重開

> **一句話**：10 台 LXC 每天凌晨自動裝安全更新，裝完後 `needrestart` 會列出還在跑舊函式庫的服務；我們逐一重啟 `dbus`、`systemd-logind` 之後，兩台 Ubuntu 容器出現 `networkd-dispatcher` failed 且 `networkctl status` 卡住，**整個容器重開後就恢復**，所以很可能的結論是：應用程式服務可以單獨重啟，`dbus`／`logind`／`systemd` 這類系統底層服務就整個容器重開。

| 項目 | 內容 |
| --- | --- |
| 適合誰看 | 開了自動更新、想知道「更新有沒有生效」和「`needrestart` 列出的服務該不該逐一重啟」的人 |
| 環境 | PVE 9.2 三節點（node10～12）；10 台 LXC（Debian 13／Ubuntu 22.04／24.04），都有開 `unattended-upgrades`；Ceph、HA |
| 日期 | 2026-10-25 檢查與重啟；10-28、10-29 驗證與重開 |
| 結論 | ✅ 10 台 LXC 最後一次更新都成功、ERROR 為 0 ✅ 逐一重啟 `dbus`／`logind` 後，**觀察到** CT112、CT114 的 `networkd-dispatcher` failed、`networkctl status` 卡住 ✅ CT112、CT114 整個容器重開後，兩個現象都消失；沒動過的 CT113 一直正常 ⏳ 「很可能」是逐一重啟 `dbus` 造成，**沒有隔離變因，不寫成已證明** ⏳ 需排除 needrestart 重啟的設定語法**待驗證** ⏳ CT113 尚未處理 |

## 1. 先認識幾個名詞

| 名詞 | 白話解釋 |
| --- | --- |
| **unattended-upgrades** | Debian／Ubuntu 的自動更新工具，預設只裝官方的安全性更新，日誌在 `/var/log/unattended-upgrades/unattended-upgrades.log` |
| **needrestart** | 更新後檢查「哪些正在跑的服務還在用舊的函式庫」；`-b` 是給程式讀的簡短輸出 |
| **待重啟的服務** | 套件檔案已換新，但服務是更新前啟動的，記憶體裡還是舊版 |
| **failed units** | `systemctl --failed` 列出的啟動失敗或異常結束的服務，正常是 0 |
| **dbus** | 系統內部讓服務互相傳訊息的元件，很多小服務靠它連線 |
| **systemd-logind** | 管理登入 session 的服務 |
| **networkd-dispatcher** | Ubuntu 上，網路狀態改變時執行 hook 腳本的小程式（Debian 容器沒有）；本環境它的 hook 目錄是空的 |
| **networkctl** | 查詢 `systemd-networkd` 網路狀態的指令 |
| **rx** | 讓 Claude Code 在內網執行指令的去識別化閘道（[說明文章](https://kbwangtw.github.io/IT-Knowledge-Base/docs/pve/claude-code-redact-gateway/)），會擋含 `reboot` 的指令 |
| **快照（snapshot）** | `pct snapshot` 替容器拍的還原點，用 `pct rollback` 回去 |
| **replica／yellow** | OpenSearch／Wazuh indexer 的副本分片；單節點放不下副本，叢集狀態就是 yellow |

## 2. 流程全貌

```text
① 唯讀盤點（log、systemctl --failed、needrestart -b）
        │
        ▼
② 分類待重啟的服務
   ├─ 應用程式（mongod、wazuh-indexer…）→ 單獨重啟，一次一台、一個服務
   └─ 底層（dbus、systemd-logind、networkd-dispatcher）→ 不逐一重啟，排時間整個容器重開
        │
        ▼
③ 每一步：先說明做什麼／風險／怎麼還原 → 拍快照 → 動手 → 唯讀驗證
```

## 3. 步驟 1：唯讀盤點

**做什麼**：確認昨晚的自動更新有沒有成功，以及更新後還有哪些服務要重啟。

**怎麼做**：先列出 running 的容器，再對每一台執行檢查。

```bash
pct list | awk 'NR==1 || $2=="running"'

pct exec <CTID> -- sh -c "
L=/var/log/unattended-upgrades/unattended-upgrades.log
grep -E 'Packages that will be upgraded|All upgrades installed|ERROR' \$L | tail -4
echo ERRCOUNT_TOTAL=\$(grep -c ERROR \$L)
echo FAILED=\$(systemctl --failed --no-legend | wc -l)
needrestart -b 2>&1 | grep -E 'NEEDRESTART-(SVC|KSTA|UCSTA)'
"
```

| 片段 | 意思 |
| --- | --- |
| `grep -E '…\|ERROR'` | 只留三種關鍵行：要升級的套件清單、完成訊息、錯誤 |
| `tail -4` | 只看最近一兩次執行 |
| `grep -c ERROR` | 整份日誌累計 ERROR 幾筆，0 代表從來沒錯過 |
| `systemctl --failed --no-legend \| wc -l` | failed unit 的數量 |
| `needrestart -b` | 待重啟清單；`NEEDRESTART-SVC: xxx.service` 就是要重啟的服務 |

**應該看到什麼**：最後一行是 `All upgrades installed`、`ERRCOUNT_TOTAL=0`、`FAILED=0`。套件數：數 `Packages that will be upgraded:` 那一行冒號後面有幾個套件名稱。

**2026-10-25 的實測結果**（更新時間都在 04:03～04:21）：

| 節點 | CT | 名稱 | 套件數 | ERROR | failed | 待重啟的服務 |
| --- | --- | --- | --- | --- | --- | --- |
| node10 | 100 | AdGuard | 12 | 0 | 0 | dbus、unattended-upgrades |
| node10 | 103 | IPAM | 13 | 0 | 0 | dbus、unattended-upgrades |
| node10 | 110 | ProxCenter | 11 | 0 | 0 | dbus、unattended-upgrades |
| node10 | 113 | ai | 43 | 0 | 0 | dbus、networkd-dispatcher、systemd-logind、unattended-upgrades |
| node11 | 102 | librenms | 6（前一天 16） | 0 | 0 | 無 |
| node11 | 109 | wireguard | 8 | 0 | 0 | dbus、unattended-upgrades |
| node11 | 112 | wazuh | 27 | 0 | 0 | dbus、networkd-dispatcher、systemd-logind、unattended-upgrades、wazuh-indexer、wazuh-manager |
| node12 | 101 | Pihole | 11 | 0 | 0 | dbus、unattended-upgrades |
| node12 | 105 | Graylog | 4 | 0 | 0 | dbus、mongod、unattended-upgrades |
| node12 | 114 | grafana | 26 | 0 | 0 | dbus、networkd-dispatcher、systemd-logind、unattended-upgrades |

## 4. 步驟 2：把待重啟的服務分類，應用程式服務單獨重啟

**做什麼**：步驟 1 的 `NEEDRESTART-SVC` 清單分成兩類，處理方式不同。

| 類別 | 例子 | 怎麼處理 |
| --- | --- | --- |
| 應用程式服務 | `mongod`、`wazuh-indexer`、`wazuh-manager` | 單獨重啟；一次一個，確認健康才做下一個 |
| 底層服務 | `dbus`、`systemd-logind`、`systemd`、`networkd-dispatcher` | **不單獨重啟**，留給步驟 3 整個容器重開 |
| `unattended-upgrades` | 常和 `dbus` 一起出現 | 一併留給步驟 3 |

**怎麼做**（以應用程式服務為例，每個服務重複一次）：

```bash
pct snapshot <CTID> pre-restart-<日期>
pct exec <CTID> -- systemctl restart <服務名稱>
pct exec <CTID> -- systemctl is-active <服務名稱>
pct exec <CTID> -- systemctl --failed --no-pager
```

| 片段 | 意思 |
| --- | --- |
| `pct snapshot <CTID> pre-restart-<日期>` | 先拍還原點；名稱不要含 `reboot`，會被 `rx` 擋 |
| `systemctl restart <服務名稱>` | 只重啟這一個服務 |
| `systemctl is-active` | 確認服務回到 `active` |
| `systemctl --failed` | 確認沒有新的 failed unit |

**應該看到什麼**：服務是 `active`、failed 是 0，再確認服務本身是健康的（例如 Graylog `lbstatus` 回 `ALIVE`、Grafana `/api/health` 回 200）。Wazuh 的順序是先 `wazuh-indexer`，確認 Filebeat 到 indexer 通了，才重啟 `wazuh-manager`。

## 5. 步驟 3：底層服務待重啟，整個容器重開

**做什麼**：`dbus`、`systemd-logind` 這類底層服務不要逐一重啟，改成挑沒人用的時段，整個容器重開；同時也會清掉待重啟的 `unattended-upgrades`。

**怎麼做**：

1. 唯讀記錄重開前的狀態：

```bash
pct exec <CTID> -- systemctl --failed --no-pager
pct exec <CTID> -- timeout 10 networkctl status eth0
echo "exit=$?"
ha-manager status | grep ct:<CTID>
```

| 片段 | 意思 |
| --- | --- |
| `timeout 10` | 最多等 10 秒，超過就終止；不加的話，`networkctl` 卡住時會一直等 |
| `exit=124` | `timeout` 的逾時代碼，代表卡住；`exit=0` 代表正常 |
| `ha-manager status \| grep ct:<CTID>` | 容器是否由 HA 管理、目前在哪個節點 |

2. 拍快照：`pct snapshot <CTID> pre-restart-<日期>`
3. 在容器所在的節點上手動執行 `pct reboot <CTID>`（HA 管理的容器會維持 `started`）。
4. 約 1 分鐘後，重跑第 1 點的指令，並確認服務本身健康。

**應該看到什麼**：

| 項目 | 重開後應該是 |
| --- | --- |
| `systemctl --failed` | 0 個 |
| `timeout 10 networkctl status eth0` | 立刻回應，`exit=0`，`routable` |
| 服務本身 | `active`，健康檢查正常 |
| HA | `started` |

**注意**：

- 多台容器一次只重開一台；DNS 兩台（AdGuard、Pihole）要錯開。
- Wazuh 重開後 indexer 要一兩分鐘才起來，叢集狀態仍會是 yellow（單節點的 replica 放不下，見第 8 節）。
- 執行 Claude Code 的容器（CT113）重開，會中斷那邊的對話，先存好手上的工作。

## 6. 踩過的雷：逐一重啟 dbus／logind 之後

### 當時的做法

**當時的做法**（現在回頭看，不建議照做）：每台先拍快照，再依序重啟 `needrestart` 列出的服務，順序是 `dbus` → `systemd-logind` → `unattended-upgrades`，應用程式服務另外處理。

| 項目 | 內容 |
| --- | --- |
| 已處理的容器 | CT103、110、109、114、105、112、100、101（CT102 本來就沒有待重啟服務；CT113 刻意不處理，因為它是執行 Claude Code 的容器） |
| 實際重啟的底層服務 | 每台的 `dbus`、`unattended-upgrades`；CT114、CT112 另有 `systemd-logind`（CT114 還重啟了 `networkd-dispatcher`） |
| 實際重啟的應用服務 | Graylog：`mongod`；Wazuh：先 `wazuh-indexer`，確認 Filebeat 通了才 `wazuh-manager` |
| 當天驗證 | 各台 failed 數、`needrestart` 是否清空、服務本身（`wg0` 還在、Grafana health 回 200、Graylog `lbstatus` 回 `ALIVE`、`dig` 能解析、Wazuh agent 數） |

### 觀察到的症狀

重啟 `dbus` 之後，**靠 dbus 連線運作的小服務會以 exit 1 結束**：

| 現象 | 觀察 |
| --- | --- |
| `unattended-upgrades.service` failed | 它是「關機前等更新完成」的小程式，`dbus` 重啟後斷線退出（**推測**）；再啟動一次就好。所以順序要先 `dbus`、後它 |
| Ubuntu 的 `networkd-dispatcher` failed（CT114、CT112） | 日誌在重啟 `dbus` 的那一刻出現 `exited, status=1/FAILURE` |
| CT114 手動啟動 `networkd-dispatcher` 逾時，重試仍逾時 | 日誌有 `Failed to query link bit rates: Connection timed out` |
| `networkctl status eth0` 卡住 | 用 `timeout 10` 保護，兩台都是 exit 124（沒輸出）；`networkctl list` 正常；`eth0` 仍是 routable，Grafana 等服務本身不受影響 |

`networkctl status` 一定要用 `timeout 10` 保護，不然會一直卡住（用法見步驟 3）。

### 對照：重開前 vs 整個容器重開後

兩台都是同樣的操作：先唯讀記錄重開前狀態、拍快照 `pre-restart-20261029`、由使用者在節點上手動執行 `pct reboot`（`rx` 會擋 `reboot` 類指令，見常見問題與[說明文章](https://kbwangtw.github.io/IT-Knowledge-Base/docs/pve/claude-code-redact-gateway/)）、再唯讀驗證。

| 項目 | CT114 重開前 | CT114 重開後 | CT112 重開前 | CT112 重開後 |
| --- | --- | --- | --- | --- |
| failed units | 1（`networkd-dispatcher`） | 0 | 1（`networkd-dispatcher`） | 0 |
| `timeout 10 networkctl status eth0` | 卡住（exit 124） | 正常（exit 0，`routable`） | 卡住（exit 124） | 正常（exit 0，`routable`） |
| 服務本身 | `grafana-server` active | active，`/api/health` 回 200、`database: ok` | 4 個 Wazuh 服務 active | 4 個都 active，Filebeat 到 indexer `talk to server... OK` |
| 其他 | — | HA：`started` | indexer yellow、27 個未分配；agent 19、Active 18 | 一樣；HA：`started`，`quorum OK` |

### 對照組：CT113 沒動過

CT113（ai）沒有被我們逐一重啟過 `dbus`／`logind`，10-28 的檢查：failed units 是 0，`networkctl status eth0` 立刻回應、`routable`。

它的 `systemd-networkd` 在 10-25 04:21、04:22 因為更新重啟過，也沒有卡住。所以「`systemd-networkd` 因更新重啟」本身**看起來不是**原因。

### 判讀（措辭）

- **觀察到**：被逐一重啟過 `dbus`／`logind` 的兩台 Ubuntu 容器出現症狀，沒動過的 CT113 沒有；整個容器重開後症狀消失。
- **很可能**：逐一重啟 `dbus`／`logind` 造成了這個狀況。
- **未確認**：沒有隔離變因（沒有在乾淨容器上只重啟 `dbus` 重現），重開前也沒有 `networkctl` 的正常基準；也不知道是 `dbus` 還是 `logind` 還是兩者造成；Debian 容器是否會遇到同樣問題也沒驗證（本次 Debian 容器沒有 `networkd-dispatcher`）。

## 7. 預防

- **LXC 裡不要用 `needrestart` 自動重啟 `dbus`／`systemd-logind`／`systemd`**（例如 `needrestart -r a`），也不要逐一手動重啟它們。
- 待重啟清單裡出現這些底層服務時：**整個容器重開**，挑沒人用的時段，並先拍快照。
- 應用程式服務（`mongod`、`wazuh-indexer`、`wazuh-manager` 這類）可以單獨重啟，但要分開、一次一個，確認健康才做下一個。
- 多台容器**一次只動一台**；DNS 兩台（AdGuard、Pihole）錯開。

### 排除服務的設定（待驗證）

想讓 `needrestart` 不要把某些服務列為「要重啟」，需要排除設定。**這個語法我們沒有驗證過**，請先在一台測試容器確認，再套用到正式容器。 所以這裡不放範例，已列入待辦；驗證前不要依賴它。

## 8. 其他教訓

| 教訓 | 說明 |
| --- | --- |
| **Graylog 真實日誌在 `infra_syslog_*`，不是 `graylog_*`** | 依 Graylog 網頁的 Index Set 設定，真實日誌在 `infra_syslog_*`；本次沒有用指令重新驗證。當天對 `graylog_*` 查「最近 5 分鐘」得到 0 筆、60 秒增量為 0，這個結論**不可靠**，不能據此說「日誌很稀疏」；要看收 log 請查對 index，並在 Graylog 網頁確認 Input 是 Running |
| **Wazuh 單節點的 yellow 是 replica 無法配置，不是故障** | 24 個未分配 shard 全是 replica，原因 `CLUSTER_RECOVERED`；10-29 重開前是 27 個（多出的 3 個沒查是哪些）。primary 全部 active、資料沒遺失。重開不會改變它；要變 green 得把 `number_of_replicas` 設成 0，屬於修改，要另外評估 |
| **一次只動一個容器** | 這次中途出現狀況時，因為是一台一台做，影響範圍才小，也才找得到與沒動過的對照組 |
| **WinClient 的 Wazuh agent Disconnected** | VM 108 是**故意關機**（已確認；`onboot: 0`，且有 VGA 直通），所以 agent 顯示 Disconnected 是預期現象，不需處理；`qm agent ping` 關機時必然失敗，所以沒有測 |

## 9. 驗收

| CT | 名稱 | 目前狀況 |
| --- | --- | --- |
| 100、101、103、105、109、110 | AdGuard、Pihole、IPAM、Graylog、wireguard、ProxCenter | ✅ failed 為 0 |
| 112 | wazuh | ✅ 整個容器重開後 failed 為 0，`networkctl` 正常 |
| 114 | grafana | ✅ 同上 |
| 102 | librenms | 本來就沒有待重啟服務 |
| 113 | ai | ⏸ 未處理，failed 為 0，`networkctl` 正常 |

## 10. 常見問題

| 現象 | 怎麼辦 |
| --- | --- |
| `needrestart -b` 重啟後仍列出 `dbus.service` | `systemctl daemon-reexec` 只重載 systemd 本身，不會重啟 `dbus-daemon`（依 systemd 行為推論，非本次實測）；要清掉就整個容器重開（步驟 3） |
| 重啟 `dbus` 後 `unattended-upgrades` failed | 重新啟動它即可；但根本做法是別逐一重啟 `dbus` |
| `networkd-dispatcher` failed 且 `networkctl status` 卡住 | 容器內 hook 目錄是空的，**推測**不影響功能；整個容器重開可恢復（本次 CT112、CT114 都恢復，步驟 3） |
| `needrestart -b` 沒有輸出且 exit code 是 1 | 是 `grep` 沒找到東西，代表沒有待重啟的服務 |
| 用 `127.0.0.1` 測 Graylog 得到 `000` | Graylog 綁在容器自己的 IP，從 `server.conf` 的 `http_bind_address` 取位址再測 |
| 用 API 檢查 `wazuh-indexer` 健康需要帳密 | 用 `/etc/wazuh-indexer/certs/` 的 admin 憑證呼叫 `_cluster/health`；沒有權限時改看服務狀態與 port |
| 拍快照或執行指令被 `rx` 擋下，規則是 `reboot` | [`rx`](https://kbwangtw.github.io/IT-Knowledge-Base/docs/pve/claude-code-redact-gateway/) 會擋含 `reboot` 的指令，連**快照名稱**含這個字也會被擋；快照改用 `pre-restart-日期`，`pct reboot` 要由有權限的人在節點上手動執行 |
| `pct snapshot` 的描述含中文，出現 `Wide character in printf` | 只是警告，不影響快照；建議描述用英文 |

## 11. 待辦

- [ ] 確認幾天都正常後，刪除 `pre-restart-20261025`（CT100、101、103、105、109、110、112、114）和 `pre-restart-20261029`（CT112、CT114）快照（`pct delsnapshot <CTID> <名稱>`），避免佔用 Ceph 空間
- [ ] CT113 找時間整個容器重開，一併清掉待重啟的服務
- [ ] 驗證 `needrestart` 排除服務的設定語法（在測試容器上）
- [ ] 查 Wazuh 未分配 shard 多出的 3 個是哪些，並評估是否把 replica 設成 0
- [ ] 重新用 `infra_syslog_*` 確認 Graylog 在 `mongod` 重啟後有沒有漏 log

## 12. 延伸閱讀

- [一次檢查並統一所有 LXC 的時區](https://kbwangtw.github.io/IT-Knowledge-Base/docs/pve/pve-lxc-timezone/)：同一批 10 台 LXC 的另一個全面檢查
- [Wazuh LXC（Ubuntu 22.04）維運](https://kbwangtw.github.io/IT-Knowledge-Base/docs/pve/wazuh-lxc-ubuntu2204-operations/)：Wazuh 服務的日常維運
- [Node2Shell 與 LiteLLM 檢查](https://kbwangtw.github.io/IT-Knowledge-Base/docs/pve/node2shell-litellm-check/)：說明為什麼自動更新不會更新第三方來源的套件
