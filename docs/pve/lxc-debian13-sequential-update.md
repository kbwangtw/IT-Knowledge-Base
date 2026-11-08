---
layout: default
title: "依序更新節點上所有 Debian 13 的 LXC：拍快照、apt 更新、整個容器重開、異常就停止"
date: 2026-11-08
categories: [PVE, LXC]
permalink: /docs/pve/lxc-debian13-sequential-update/
last_modified_at: 2026-11-08
---

# 依序更新節點上所有 Debian 13 的 LXC：拍快照、apt 更新、整個容器重開、異常就停止

> **一句話**：在 PVE 節點上執行一支小腳本，自動找出本節點所有「執行中、Debian 13」的 LXC，**一次一台**做「拍快照 → `apt full-upgrade` → `pct reboot` → 確認服務正常」，任何一台出現異常就立刻停止，不會繼續動下一台。

| 項目 | 內容 |
| --- | --- |
| 適合誰看 | 管理多台 Debian 13 LXC、想用一支指令安全地依序更新的人 |
| 環境 | PVE 9.x 叢集（`pct` 只管**本節點**的容器，所以每個節點各執行一次）；LXC 為 Debian 13（trixie） |
| 日期 | 2026-11-08 撰寫 |
| 結論 | ✅ 腳本語法檢查（`bash -n`）通過 ✅ 用模擬的 `pct` 驗證過篩選邏輯：略過非 Debian 13 與 stopped 的 CT，`EXCLUDE`、`ONLY`、`DRYRUN` 都如預期 ✅ 流程沿用 [LXC 自動更新後的待重啟檢查](https://kbwangtw.github.io/IT-Knowledge-Base/docs/pve/lxc-needrestart-service-restart/)的結論：底層服務待重啟就整個容器重開 ✅ 新增一鍵更新整個叢集的總控腳本（第 6 節）⏳ **尚未在實際 PVE 節點上實測**，第一次請先用 `ONLY` 指定一台影響最小的容器試跑 |

## 1. 先認識幾個名詞

| 名詞 | 白話解釋 |
| --- | --- |
| **LXC／CT** | PVE 的輕量容器；`CTID` 是容器編號 |
| **`pct`** | PVE 管理 LXC 的指令，**只看得到本節點**的容器 |
| **`pct exec`** | 從節點直接在容器內執行指令，不用 SSH 進去 |
| **快照（snapshot）** | 更新前拍的還原點；出問題用 `pct rollback` 回去 |
| **`full-upgrade`** | 比 `upgrade` 更完整的更新，必要時會新增／移除套件來解決相依 |
| **`--force-confold`** | 設定檔有衝突時一律**保留現有**設定，避免互動式詢問卡住 |
| **`is-system-running`** | systemd 的整體狀態：`running` 正常、`degraded` 有服務失敗 |
| **HA** | PVE 的高可用管理；由 HA 管理的容器用 `pct reboot` 重開後會維持 `started` |

## 2. 流程全貌

```text
節點上執行腳本
   │
   ▼
① 找出本節點「running 且 Debian 13」的 CT（排除 EXCLUDE 清單）
   │
   ▼
② 對每一台，依 CTID 由小到大，一次一台：
   ├─ 拍快照 pre-apt-<日期>        ← 失敗就停止
   ├─ apt update + full-upgrade + autoremove   ← 失敗就停止
   ├─ pct reboot（整個容器重開）
   ├─ 等 systemd 回到 running（最多 150 秒）
   └─ 檢查 failed units = 0         ← 不是 running 或有 failed 就停止
   │
   ▼
③ 全部成功 → 觀察一天 → 刪除快照
```

## 3. 事前準備與風險

**做什麼**：動手前先確認這幾件事，避免把正常服務更新壞。

| 項目 | 怎麼確認 | 為什麼 |
| --- | --- | --- |
| 兩台 DNS（例如 AdGuard、Pihole）不要同時重開 | 它們放在不同節點，**節點之間不要同時跑腳本** | 同時重開會短暫沒有 DNS |
| 有 `apt-mark hold` 的容器 | `pct exec <CTID> -- apt-mark showhold` | 被鎖住的套件不會更新，要另外有控制地升級（例如 Graylog 的 `opensearch`、`graylog-server`） |
| 重開會中斷服務的容器 | 自己判斷，用 `EXCLUDE` 排除 | 例如執行 Claude Code 的容器（重開會中斷對話）、Graylog 這類有啟動順序的容器，建議手動處理 |
| Ceph 空間 | `ceph df` | 每台多一個快照，更新完要記得刪除 |
| 第三方來源的套件 | 查看容器是否有額外的 apt 來源 | `apt full-upgrade` 只更新 apt 來源裡有的套件，第三方安裝的程式不會更新 |

**注意**：`rx`（Claude Code 的內網閘道）會擋含 `reboot` 的指令；這支腳本含 `pct reboot`，**要由你在節點上手動執行**，不要透過 `rx`。快照名稱也不要含 `reboot`。

## 4. 步驟 1：先唯讀確認哪些 CT 會被更新

**做什麼**：只列出會被動到的容器，不做任何修改。

**怎麼做**（在 PVE 節點上執行）：

```bash
for id in $(pct list | awk 'NR>1 && $2=="running"{print $1}' | sort -n); do
  os=$(pct exec "$id" -- sh -c '. /etc/os-release; echo "$ID $VERSION_ID"' 2>/dev/null)
  echo "CT$id  $(pct config "$id" | awk '/^hostname/{print $2}')  [$os]"
done
```

| 片段 | 意思 |
| --- | --- |
| `pct list \| awk 'NR>1 && $2=="running"{print $1}'` | 取出狀態是 `running` 的 CTID（`NR>1` 跳過標題列） |
| `sort -n` | 依數字由小到大排序，確保每次順序一致 |
| `. /etc/os-release; echo "$ID $VERSION_ID"` | 讀容器的系統版本，Debian 13 會是 `debian 13` |
| `pct config "$id" \| awk '/^hostname/{print $2}'` | 顯示容器名稱，方便辨認 |

**應該看到什麼**：每台一行，例如 `CT100  <名稱>  [debian 13]`。`[debian 13]` 的才會被更新；Ubuntu 或其他版本會被略過。

## 5. 步驟 2：依序更新的腳本

**做什麼**：把下面存成 `/root/lxc-debian13-update.sh`，一次處理一台，任何一步失敗就停止。

**怎麼做**：

```bash
#!/usr/bin/env bash
# 在 PVE 節點執行：依序更新本節點上所有 running 的 Debian 13 LXC
# 環境變數：
#   EXCLUDE="105 113"  不更新的 CTID（空白分隔）
#   ONLY="100"         只更新指定 CTID（試跑用；空白分隔）
#   DRYRUN=1           只列出會處理的 CT，不修改
set -u

DATE=$(date +%Y%m%d)
SNAP="pre-apt-$DATE"
EXCLUDE=" ${EXCLUDE:-} "
ONLY=" ${ONLY:-} "

targets=()
for id in $(pct list | awk 'NR>1 && $2=="running"{print $1}' | sort -n); do
  case "$EXCLUDE" in *" $id "*) echo "略過 CT$id（EXCLUDE）"; continue;; esac
  if [ "$ONLY" != "  " ]; then
    case "$ONLY" in *" $id "*) ;; *) continue;; esac
  fi
  if pct exec "$id" -- sh -c '. /etc/os-release; [ "$ID" = debian ] && [ "$VERSION_ID" = 13 ]' 2>/dev/null; then
    targets+=("$id")
  fi
done

echo "將依序更新的 Debian 13 CT：${targets[*]:-（無）}"
[ "${DRYRUN:-0}" = 1 ] && exit 0

for id in "${targets[@]}"; do
  echo "===== CT$id ====="

  pct snapshot "$id" "$SNAP" --description "Before apt upgrade" \
    || { echo "STOP：CT$id 拍快照失敗"; exit 1; }

  pct exec "$id" -- env DEBIAN_FRONTEND=noninteractive bash -c '
    apt-get update -qq &&
    apt-get -y -o Dpkg::Options::=--force-confold full-upgrade &&
    apt-get -y autoremove' \
    || { echo "STOP：CT$id apt 失敗，快照 $SNAP 保留"; exit 1; }

  pct reboot "$id" || { echo "STOP：CT$id 重開失敗"; exit 1; }

  state=""
  for i in $(seq 1 30); do
    sleep 5
    state=$(pct exec "$id" -- systemctl is-system-running 2>/dev/null)
    [ "$state" = running ] && break
  done
  failed=$(pct exec "$id" -- systemctl --failed --no-legend 2>/dev/null | wc -l)

  if [ "$state" != running ] || [ "$failed" != 0 ]; then
    echo "STOP：CT$id state=${state:-無回應} failed=$failed"
    pct exec "$id" -- systemctl --failed --no-pager 2>/dev/null
    exit 1
  fi
  echo "OK：CT$id 更新並重開完成（state=running，failed=0）"
done

echo "全部完成。觀察服務一天後，請刪除快照 $SNAP（見步驟 4）"
```

| 片段 | 意思 |
| --- | --- |
| `set -u` | 用到沒定義的變數就報錯，避免打錯字誤動 |
| `EXCLUDE=" ${EXCLUDE:-} "` | 前後補空白，之後用 `*" 105 "*` 精準比對，避免 `10` 誤中 `105` |
| `[ "$ONLY" != "  " ]` | `ONLY` 有指定時，只處理清單裡的 CT |
| `'. /etc/os-release; [ "$ID" = debian ] && [ "$VERSION_ID" = 13 ]'` | 容器內判斷是不是 Debian 13；不是就回傳非 0，被略過 |
| `${targets[*]:-（無）}` | 陣列內容；空的就顯示「（無）」 |
| `pct snapshot … \|\| { …; exit 1; }` | 拍快照失敗就停止，**沒有還原點就不更新** |
| `DEBIAN_FRONTEND=noninteractive` | 不跳互動式問答，避免卡住 |
| `-o Dpkg::Options::=--force-confold` | 設定檔衝突時保留現有版本 |
| `full-upgrade` | 完整更新（含相依變動）；`autoremove` 清掉不再需要的套件 |
| `pct reboot` | 整個容器重開，同時清掉 `dbus`、`systemd-logind` 等待重啟的底層服務 |
| `seq 1 30` + `sleep 5` | 最多等 150 秒，等 `systemctl is-system-running` 變成 `running` |
| `systemctl --failed --no-legend \| wc -l` | failed unit 數量，必須是 0 |
| `state != running` | `degraded`（有服務失敗）也算異常，腳本會停止，**不會繼續下一台** |

**執行方式**（每個節點各一次，**一個節點做完、確認正常，再換下一個節點**）：

```bash
chmod +x /root/lxc-debian13-update.sh

# 1) 只列出會處理的 CT，不修改
DRYRUN=1 /root/lxc-debian13-update.sh

# 2) 試跑：只更新影響最小的一台
ONLY="<CTID>" /root/lxc-debian13-update.sh

# 3) 正式執行，排除不想自動重開的容器
EXCLUDE="<CTID> <CTID>" /root/lxc-debian13-update.sh
```

**應該看到什麼**：

```text
將依序更新的 Debian 13 CT：100 103 110
===== CT100 =====
…（apt 輸出）…
OK：CT100 更新並重開完成（state=running，failed=0）
===== CT103 =====
…
全部完成。觀察服務一天後，請刪除快照 pre-apt-<日期>（見步驟 4）
```

以上是預期輸出的格式示意，**不是實測結果**。

## 6. 一鍵更新整個叢集

**做什麼**：步驟 2 的腳本一次只管一個節點。這支「總控腳本」在**任一節點**執行，用 SSH 依序對每個節點跑同樣的更新流程，不用自己逐台登入。

**運作方式**：

```text
./lxc-debian13-update-all.sh
   │
   ├─ 第 1 階段：對每個節點只「列出」會處理的 CT（不修改）
   │      ▼
   │   你看過清單，輸入 yes 才繼續（YES=1 可略過）
   │
   └─ 第 2 階段：node10 → node11 → node12，一次一個節點、一次一台 CT
          任一台異常 → 整個停止，後面的節點不處理
```

**事前條件**：執行的那個節點要能用 SSH 金鑰免密碼登入 `root@<各節點>`（PVE 叢集預設已互通；沒有的話，`ssh-copy-id` 或確認 `/etc/pve/priv/authorized_keys`）。節點名稱預設 `node10 node11 node12`，用 `NODES` 改。

**怎麼做**：存成 `/root/lxc-debian13-update-all.sh`。

```bash
#!/usr/bin/env bash
# 一鍵更新：在任一 PVE 節點執行，依序更新每個節點上 running 的 Debian 13 LXC
# 環境變數：
#   NODES="node10 node11 node12"  要處理的節點（依序）
#   EXCLUDE="105 113"             不更新的 CTID（空白分隔）
#   ONLY="100"                    只更新指定 CTID（試跑用）
#   YES=1                         略過確認提示
set -u
NODES="${NODES:-node10 node11 node12}"

update_local() {
  SNAP="pre-apt-$(date +%Y%m%d)"
  EXCLUDE=" ${EXCLUDE:-} "
  ONLY=" ${ONLY:-} "
  targets=()
  for id in $(pct list | awk 'NR>1 && $2=="running"{print $1}' | sort -n); do
    case "$EXCLUDE" in *" $id "*) echo "略過 CT$id（EXCLUDE）"; continue;; esac
    if [ "$ONLY" != "  " ]; then
      case "$ONLY" in *" $id "*) ;; *) continue;; esac
    fi
    if pct exec "$id" -- sh -c '. /etc/os-release; [ "$ID" = debian ] && [ "$VERSION_ID" = 13 ]' </dev/null 2>/dev/null; then
      targets+=("$id")
    fi
  done
  echo "將依序更新的 Debian 13 CT：${targets[*]:-（無）}"
  [ "${DRYRUN:-0}" = 1 ] && exit 0
  for id in "${targets[@]}"; do
    echo "===== CT$id ====="
    pct snapshot "$id" "$SNAP" --description "Before apt upgrade" \
      || { echo "STOP：CT$id 拍快照失敗"; exit 1; }
    pct exec "$id" -- env DEBIAN_FRONTEND=noninteractive bash -c '
      apt-get update -qq &&
      apt-get -y -o Dpkg::Options::=--force-confold full-upgrade &&
      apt-get -y autoremove' </dev/null \
      || { echo "STOP：CT$id apt 失敗，快照 $SNAP 保留"; exit 1; }
    pct reboot "$id" || { echo "STOP：CT$id 重開失敗"; exit 1; }
    state=""
    for i in $(seq 1 30); do
      sleep 5
      state=$(pct exec "$id" -- systemctl is-system-running </dev/null 2>/dev/null)
      [ "$state" = running ] && break
    done
    failed=$(pct exec "$id" -- systemctl --failed --no-legend </dev/null 2>/dev/null | wc -l)
    if [ "$state" != running ] || [ "$failed" != 0 ]; then
      echo "STOP：CT$id state=${state:-無回應} failed=$failed"
      pct exec "$id" -- systemctl --failed --no-pager </dev/null 2>/dev/null
      exit 1
    fi
    echo "OK：CT$id 更新並重開完成"
  done
}

run_nodes() {   # $1 = DRYRUN(1/0)
  local b64 n
  b64=$(declare -f update_local | base64 -w0)
  for n in $NODES; do
    echo "######## 節點 $n ########"
    ssh -n -o BatchMode=yes "root@$n" \
      "EXCLUDE='${EXCLUDE:-}' ONLY='${ONLY:-}' DRYRUN=$1 bash -c \"\$(echo $b64 | base64 -d); update_local\"" \
      || { echo "STOP：節點 $n 異常，後面的節點不處理"; exit 1; }
  done
}

echo ">>> 第 1 階段：只列出各節點會處理的 CT（不修改）"
run_nodes 1
if [ "${YES:-0}" != 1 ]; then
  read -r -p "確定依上面清單開始更新並重開？輸入 yes 繼續：" ans
  [ "$ans" = yes ] || { echo "已取消"; exit 0; }
fi
echo ">>> 第 2 階段：依序更新"
run_nodes 0
echo "全部節點完成。觀察服務一天後，請刪除 pre-apt-$(date +%Y%m%d) 快照"
```

| 片段 | 意思 |
| --- | --- |
| `update_local()` | 就是步驟 2 的邏輯（拍快照→apt→重開→驗證），包成函式 |
| `declare -f update_local \| base64 -w0` | 把函式內容編成一行文字，帶到遠端節點執行，**不用先把腳本複製過去** |
| `ssh -n -o BatchMode=yes` | `-n` 不讓 ssh 吃掉標準輸入；`BatchMode=yes` 不能免密碼登入就直接失敗，不會卡在問密碼 |
| `bash -c "$(echo … \| base64 -d); update_local"` | 在遠端還原函式並執行；腳本以參數傳入，所以容器內的 `pct exec` 不會誤讀到它 |
| `</dev/null` | 每個 `pct exec` 都不讀標準輸入，避免卡住 |
| `\|\| { …; exit 1; }`（`run_nodes` 裡） | 任一節點回傳非 0 就停止，**不會繼續下一個節點** |
| 第 1 階段 `run_nodes 1` | 傳 `DRYRUN=1`，只列清單 |
| `read -r -p … yes` | 要輸入 `yes` 才會進第 2 階段；`YES=1` 可略過（排程或確定要自動跑時才用） |

**執行方式**：

```bash
chmod +x /root/lxc-debian13-update-all.sh

# 一鍵：先看清單、輸入 yes 後依序更新全叢集
EXCLUDE="<CTID> <CTID>" /root/lxc-debian13-update-all.sh

# 第一次建議：只試跑一台
ONLY="<CTID>" /root/lxc-debian13-update-all.sh
```

**應該看到什麼**：第 1 階段每個節點印一行「將依序更新的 Debian 13 CT：…」；輸入 `yes` 後，每台依序出現 `===== CT<編號> =====` 與 `OK：CT<編號> 更新並重開完成`，最後印「全部節點完成」。出現 `STOP：…` 就是停在該台，先處理再重跑（見常見問題）。

**測試狀況**：用模擬的 `ssh`／`pct` 驗證過「全流程完成」「輸入非 yes 會取消」「某節點失敗時整個停止且 exit 1」；**尚未在實際叢集執行**。

**一鍵的風險**：

- 一鍵會**連續重開多台容器**；DNS 兩台（AdGuard、Pihole）分在不同節點，節點是依序跑，不會同時，但中間的間隔只有「單台驗證完成」那麼短，若在意 DNS 空窗，請把其中一台放進 `EXCLUDE` 另外手動做。
- 沒有檢查 HA 或 Ceph 狀態；Ceph 不是 `HEALTH_OK` 時請不要執行（先 `ceph -s`）。
- 有啟動順序或不可中斷的容器（Graylog、執行 Claude Code 的容器）用 `EXCLUDE` 排除。
- 同一天重跑會撞到同名快照（見常見問題）。

## 7. 步驟 3：更新後的驗收

**做什麼**：腳本只確認「systemd 正常、failed 為 0」，**服務本身是否健康**要另外確認。

**怎麼做**：

```bash
pct exec <CTID> -- needrestart -b -r l      # -r l 只列出、不重啟
pct exec <CTID> -- systemctl --failed --no-pager
pct exec <CTID> -- cat /etc/debian_version
ha-manager status | grep ct:<CTID>
```

| 片段 | 意思 |
| --- | --- |
| `needrestart -b -r l` | 列出還在跑舊函式庫的服務；`-r l` 是只列出、不重啟 |
| `systemctl --failed` | 應該是 0 個 |
| `cat /etc/debian_version` | 確認仍是 13.x |
| `ha-manager status \| grep ct:<CTID>` | HA 管理的容器應該是 `started` |

**應該看到什麼**：`needrestart` 沒有 `NEEDRESTART-SVC` 行（重開後待重啟的服務會被清掉）、failed 是 0、HA 是 `started`。再依容器用途確認服務本身（例如 DNS 能解析、Grafana `/api/health` 回 200、WireGuard 的 `wg0` 還在）。

## 8. 步驟 4：觀察一天後刪除快照

**做什麼**：快照會持續佔用 Ceph 空間，確認正常後刪除。

**怎麼做**（在該節點上執行，`<日期>` 換成腳本印出的快照日期）：

```bash
for id in $(pct list | awk 'NR>1{print $1}'); do
  pct listsnapshot "$id" 2>/dev/null | grep -q "pre-apt-<日期>" \
    && pct delsnapshot "$id" "pre-apt-<日期>" && echo "deleted CT$id"
done
```

**應該看到什麼**：每台有該快照的 CT 印出 `deleted CT<編號>`。

**還原方式**（更新後發現問題，才用）：

```bash
pct rollback <CTID> pre-apt-<日期>
```

## 9. 常見問題

| 現象 | 怎麼辦 |
| --- | --- |
| 腳本印出「將依序更新的 Debian 13 CT：（無）」 | 本節點沒有 running 的 Debian 13 容器，或 `ONLY`／`EXCLUDE` 把它們都排除了；先跑步驟 1 看系統版本 |
| `STOP：CT<編號> 拍快照失敗` | 容器可能有不支援快照的掛載點（bind mount），或儲存空間不足；先解決再重跑，**不要跳過快照直接更新** |
| `STOP：… apt 失敗` | 進容器手動 `apt-get update` 看錯誤（常見是 DNS 或來源不通）；快照保留，修好後重跑腳本即可（已更新的 CT 會變成「無待更新」，很快跑完） |
| `state=degraded`、`failed=1` | 腳本已停止在該台；用 `systemctl --failed` 找是哪個服務，修好或確認可忽略後，再用 `EXCLUDE` 排除已完成的 CT 重跑 |
| 一鍵腳本在某節點出現 `STOP`，前面的節點已經更新完 | 正常，前面的不用重做；修好後用 `NODES` 只列還沒做的節點重跑，例如 `NODES="node11 node12"` |
| `STOP：節點 <名稱> 異常` 但沒有其他訊息 | 多半是 SSH 連不上（`BatchMode=yes` 不問密碼）；先手動 `ssh root@<名稱> true` 確認 |
| 重跑時說快照已存在 | 同一天重跑會撞到同名快照；先 `pct delsnapshot <CTID> pre-apt-<日期>`，或改日期再跑 |
| 有套件被 `apt-mark hold` 鎖住沒更新 | 這是預期行為；用 `apt-mark showhold` 確認，需要升級時再有控制地處理 |
| 透過 `rx` 執行被擋 | `rx` 會擋含 `reboot` 的指令（連名稱含這個字也擋），這支腳本要由你直接在節點上執行 |
| 重開後一直等不到 `running`（150 秒逾時） | 可能是服務啟動慢（例如 Wazuh indexer 要一兩分鐘）；進容器 `systemctl is-system-running` 再看，必要時調大 `seq 1 30` 的 30 |

## 10. 待辦

- [ ] 在實際節點上先用 `DRYRUN=1` 確認清單，再用 `ONLY` 對一台影響最小的容器試跑，把實測結果補回本文
- [ ] 確認各節點每台 Debian 13 容器是否需要放進 `EXCLUDE`（有啟動順序或不可中斷的服務）
- [ ] 評估是否把 `EXCLUDE`／`ONLY` 設定改成設定檔，避免每次手打
- [ ] 在實際叢集用 `ONLY` 試跑一鍵腳本，並評估是否加入 `ceph -s` 為 `HEALTH_OK` 的前置檢查

## 11. 延伸閱讀

- [LXC 自動更新後，怎麼檢查「待重啟的服務」](https://kbwangtw.github.io/IT-Knowledge-Base/docs/pve/lxc-needrestart-service-restart/)：為什麼底層服務要整個容器重開，而不是逐一重啟
- [PVE 更新後的滾動重開機](https://kbwangtw.github.io/IT-Knowledge-Base/docs/pve/pve-rolling-reboot-after-update/)：節點本身的更新與重開順序
- [Debian 官方 Release Notes（trixie）](https://www.debian.org/releases/trixie/release-notes/)：Debian 13 的升級與相依變動說明
