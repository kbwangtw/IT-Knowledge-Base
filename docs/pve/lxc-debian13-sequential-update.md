---
layout: default
title: "一鍵依序更新所有 Debian 13 的 LXC：拍快照、apt 更新、必要時才重開、異常就停止"
date: 2026-11-08
categories: [PVE, LXC]
permalink: /docs/pve/lxc-debian13-sequential-update/
last_modified_at: 2026-11-09
---

# 一鍵依序更新所有 Debian 13 的 LXC：拍快照、apt 更新、必要時才重開、異常就停止

> **一句話**：在任一 PVE 節點執行一支總控腳本，先檢查 Ceph 與 HA 都正常，列出全叢集所有「執行中、Debian 13」的 LXC 給你確認，再**一次一台**做「拍快照 → `apt full-upgrade` → **必要時才**重開 → 確認服務正常」，任何一台異常就立刻停止。

| 項目 | 內容 |
| --- | --- |
| 適合誰看 | 管理多台 Debian 13 LXC、想用一支指令安全地依序更新的人 |
| 環境 | PVE 9.x 三節點叢集（node10～12）、Ceph、HA；LXC 有 Debian 13、Debian 12、Ubuntu 22.04／24.04 混用 |
| 日期 | 2026-11-08 撰寫；同日由 Lab Ops 做唯讀盤點，並在 node11 實測 |
| 結論 | ✅ 唯讀盤點：Ceph `HEALTH_OK`、13 個 HA 服務全是 `started`；Debian 13 的 CT 有 6 台 ✅ **2026-11-08 實測：6 台全部更新完成**，更新後驗收 `needrestart` 乾淨、failed 為 0、`running`、HA `started` ✅ 實測發現：`REBOOT=auto` 在本環境實質上等於每台都重開，因為各台都有舊的待重啟服務（`systemd-logind`、`unattended-upgrades`），不是這次的 `tzdata` 造成 ⏳ CT101、CT110 的更新輸出沒有保存，驗收結果見第 7 節的實測紀錄 ✅ 各服務的網頁功能（IPAM、LibreNMS、WireGuard、ProxCenter）由人工確認，**2026-11-09 已確認正常**（快照刪除前確認） |

## 最短用法：只要一個指令

**日常更新，在任一節點輸入這一個指令就好：**

```bash
lxc-update
```

它會自動做完整流程（前置檢查 → 列清單 → 逐台備份、更新、必要時重開、檢查），看到清單後輸入 `y` 或 `yes` 確認。任何一步異常都會自動停止，不會繼續動下一台。

| 你要做的 | 說明 |
| --- | --- |
| 輸入 `lxc-update` | 預設不處理 CT105（Graylog，Debian 12）與 CT113（Lab Ops 所在的容器） |
| 看清單 | 確認要更新的 CT 沒有錯；有已更新過的 CT 就不要確認（同一天重跑會因同名快照停止，見第 10 節） |
| 輸入 `y` | 開始更新；其他輸入（含 Enter）都取消 |
| 隔天刪快照 | 觀察服務一天正常後再刪（見下方） |

**第一次使用前要先裝好（只做一次）**：把第 7 節的腳本存成 `/root/lxc-debian13-update-all.sh`，再建立 `lxc-update`：

```bash
chmod +x /root/lxc-debian13-update-all.sh
cat > /usr/local/bin/lxc-update <<'EOF'
#!/bin/bash
EXCLUDE="${EXCLUDE:-105 113}" /root/lxc-debian13-update-all.sh "$@"
EOF
chmod +x /usr/local/bin/lxc-update
```

`lxc-update` 只是轉接，真正的邏輯在 `/root/lxc-debian13-update-all.sh`，兩個檔案都不要移動或改名。

**常用變化**（需要時才用，平常不用管）：

```bash
LIST_ONLY=1 lxc-update            # 只看清單與各 CT 目前狀態，不更新
ONLY="103" lxc-update             # 只更新指定的 CT（試跑用）
EXCLUDE="105 110 113" lxc-update  # 改排除清單（例如這次不想動 ProxCenter）
REBOOT=never lxc-update           # 不重開（舊的待重啟服務會一直留著）
```

**隔天刪快照**（`<日期>` 換成當天日期，例如 `20261108`；在任一節點執行，會逐台處理三個節點）：

```bash
for n in node10 node11 node12; do ssh root@$n 'for id in $(pct list | awk "NR>1{print \$1}"); do pct listsnapshot $id 2>/dev/null | grep -q pre-apt-<日期> && pct delsnapshot $id pre-apt-<日期> && echo "deleted CT$id"; done'; done
```

**要知道的限制**：

- 預設會處理 ProxCenter（CT110），它的 `docker-ce` 升級會讓 docker 容器短暫停止（`restart: unless-stopped` 會自動起來）；更新前先確認沒有人在用、沒有跑到一半的任務。不想動它就用 `EXCLUDE="105 110 113" lxc-update`。
- 兩台 DNS（AdGuard、Pihole）分在不同節點，節點依序更新，但間隔很短；在意的話把其中一台排除、另外做。
- 同一天不能跑兩次（同名快照）。
- 這個一鍵腳本含重開動作，**要由你直接在節點上執行**，不要透過 `rx`。

以下是完整說明與每個環節的細節，一般日常使用不需要看。

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
| **`needrestart`** | 更新後檢查「哪些服務還在跑舊函式庫」；`-b -r l` 是只列出、不重啟 |
| **`/run/reboot-required`** | 套件更新後留下的標記檔，代表需要重開 |
| **基準線（baseline）** | 更新**前**的狀態；容器本來就 `degraded` 的話，更新後的異常不能算在更新頭上 |
| **HA** | PVE 的高可用管理；由 HA 管理的容器用 `pct reboot` 重開後會維持 `started` |

## 2. 流程全貌

```text
./lxc-debian13-update-all.sh
   │
   ├─ 前置檢查：Ceph = HEALTH_OK、HA 沒有 error／fence／freeze
   │
   ├─ 第 1 階段：對每個節點只「列出」Debian 13 的 CT 與目前狀態（不修改）
   │      ▼
   │   你看過清單，輸入 y 或 yes 才繼續（LIST_ONLY=1 只看清單；YES=1 略過確認）
   │
   └─ 第 2 階段：node10 → node11 → node12，一次一個節點、一次一台 CT
        ├─ 每個節點開始前，再做一次前置檢查
        └─ 每台 CT：
             ├─ 確認更新前是 running、failed = 0     ← 不是就停止（還沒動它）
             ├─ 拍快照 pre-apt-<日期>                 ← 失敗就停止
             ├─ apt update + full-upgrade + autoremove ← 失敗就停止
             ├─ 需要才重開（見第 6 節）
             └─ 確認 running、failed = 0              ← 不是就停止，不動下一台
```

## 3. 事前準備與風險

**做什麼**：動手前先確認這幾件事，避免把正常服務更新壞。

| 項目 | 怎麼確認 | 為什麼 |
| --- | --- | --- |
| 兩台 DNS（AdGuard、Pihole）要錯開 | 分在不同節點；節點是依序跑，但中間只隔「單台驗證完成」那麼短 | 若在意空窗，把其中一台放進 `EXCLUDE`，等另一台驗證 DNS 正常後再單獨更新 |
| 有 `apt-mark hold` 的容器 | `pct exec <CTID> -- apt-mark showhold` | 被鎖住的套件不會更新（例如 Graylog 的 `opensearch`、`graylog-server`），要另外有控制地升級 |
| 重開會中斷服務的容器 | 自己判斷，用 `EXCLUDE` 排除 | 例如執行 Claude Code 的容器（重開會中斷對話） |
| 更新會重啟服務的套件 | 看待更新清單 | 例如 `docker-ce` 升級會重啟 `dockerd`；沒開 `live-restore` 時，容器會跟著重啟，建議單獨處理，並先確認各服務有 restart policy |
| Ceph 空間 | `ceph df` | 每台多一個快照，更新完要記得刪除；腳本不檢查剩餘空間 |
| 第三方來源的套件 | 查看容器是否有額外的 apt 來源 | `apt full-upgrade` 只更新 apt 來源裡有的套件，第三方安裝的程式不會更新 |

**注意**：`rx`（Claude Code 的內網閘道）會擋含 `reboot` 的指令；腳本含 `pct reboot`，所以**更新本身要由你在節點上手動執行**。`LIST_ONLY=1` 只列清單、不會重開，但腳本檔案內容含 `reboot` 字樣，能不能透過 `rx` 執行**未確認**（`rx` 是否只比對指令列字串未實測）。

## 4. 步驟 1：先唯讀確認哪些 CT 會被更新

**做什麼**：只列出會被動到的容器，不做任何修改。可以用第 7 節腳本的 `LIST_ONLY=1`，或在單一節點上手動執行下面這段。

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

**應該看到什麼**：每台一行，例如 `CT100  <名稱>  [debian 13]`。`[debian 13]` 的才會被更新；Ubuntu 或 Debian 12 會被略過。

## 5. 本環境的唯讀盤點（2026-11-08，Lab Ops 透過 `rx` 執行）

只做唯讀查詢；對各 CT 只執行 `apt-get update -qq`（更新套件清單，不升級）。沒有重開、快照或升級。

| 項目 | 結果 |
| --- | --- |
| Ceph | `HEALTH_OK`；3 mon quorum、3 OSD up/in、97 個 PG 全部 `active+clean`；用量約 1.3 TiB／5.5 TiB |
| HA | quorum OK；三個節點的 LRM 都是 active；fencing 已啟用；13 個服務全部 `started` |

| 節點 | CTID | 名稱 | 系統 | hold 的套件 | 待更新數 | 腳本會處理？ |
| --- | --- | --- | --- | --- | --- | --- |
| node10 | 103 | IPAM | Debian 13 | 無 | 1（`tzdata`） | ✅ |
| node10 | 105 | Graylog | **Debian 12** | `graylog-server`、`opensearch` | 4 | ❌（版本不符，另外手動處理） |
| node10 | 113 | ai（Lab Ops 所在） | Ubuntu 24.04 | 無 | 18 | ❌ |
| node10 | 114 | grafana | Ubuntu 24.04 | 無 | 9 | ❌ |
| node11 | 100 | AdGuard | Debian 13 | 無 | 1（`tzdata`） | ✅ |
| node11 | 110 | ProxCenter | Debian 13 | 無 | 8（`docker-ce` 系列 7 個＋`tzdata`） | ✅（建議單獨處理） |
| node11 | 112 | wazuh | Ubuntu 22.04 | 無 | 7 | ❌ |
| node12 | 101 | Pihole | Debian 13 | 無 | 1（`tzdata`） | ✅ |
| node12 | 102 | librenms | Debian 13 | 無 | 1（`tzdata`） | ✅ |
| node12 | 109 | wireguard | Debian 13 | 無 | 1（`tzdata`） | ✅ |

**判讀**：

- 腳本會處理 6 台：CT103、100、110、101、102、109。其中 5 台待更新的只有 `tzdata`；CT110 有 `docker-ce`，風險最高。
- 盤點當時我們**推測**只有 `tzdata` 就不用重開；實測證明這個推測**不成立**（見第 6 節）。
- CT105 Graylog 是 Debian 12，版本篩選本來就會略過；放進 `EXCLUDE` 只是多一層保險。
- 盤點時沒有查各 CT 更新前的 `systemctl --failed` 基準線，所以腳本加了「更新前先確認正常」的檢查（見第 7 節）。

## 6. 重開策略：必要時才重開

**做什麼**：原本的做法是更新完一律 `pct reboot`。盤點發現 6 台裡有 5 台只更新 `tzdata`，為了它重開 DNS 容器會造成無謂的中斷，所以改成預設 `REBOOT=auto`。

| `REBOOT` | 行為 |
| --- | --- |
| `auto`（預設） | 符合下列任一條件才重開：① 有 `/run/reboot-required` ② `needrestart -b -r l` 列出待重啟的服務 ③ 容器沒有 `needrestart`（無法判斷，保守重開）；都沒有就不重開 |
| `always` | 一律重開 |
| `never` | 一律不重開（更新後仍可能有待重啟的服務，之後用第 8 節檢查） |

重開的理由沿用 [LXC 自動更新後的待重啟檢查](https://kbwangtw.github.io/IT-Knowledge-Base/docs/pve/lxc-needrestart-service-restart/)的結論：`dbus`、`systemd-logind` 這類底層服務待重啟時，**整個容器重開**，不要逐一重啟。

**實測發現（2026-11-08）**：CT103、100、102、109 都只更新 `tzdata`，但 `needrestart` 都列出同樣兩個待重啟的服務 `systemd-logind.service`、`unattended-upgrades.service`，所以 `auto` 都判定要重開。這兩個服務**不是這次更新造成的**，而是先前自動更新留下的舊待辦（apt 輸出的 `Service restarts being deferred`）。重開後 `needrestart` 只剩 `NEEDRESTART-VER`，舊待辦就清掉了。

**所以**：舊待辦清掉以後，下一次才可能真的出現「不需要重開」；若不想重開，用 `REBOOT=never`，但舊待辦會一直留著。

**注意**：`docker-ce` 這類套件的安裝腳本本來就會自己重啟 `dockerd`，CT110 沒開 `live-restore`，容器會跟著停止；它的 4 個容器都是 `restart: unless-stopped`，所以會自動起來。這是它建議單獨處理的原因。

## 7. 一鍵更新整個叢集

**做什麼**：在**任一節點**執行這支總控腳本，它用 SSH 依序對每個節點跑同樣的更新流程，不用自己逐台登入。

**事前條件**：

- 執行的那個節點要能用 SSH 金鑰免密碼登入 `root@<各節點>`（PVE 叢集預設已互通；沒有的話，`ssh-copy-id` 或確認 `/etc/pve/priv/authorized_keys`）。節點名稱預設 `node10 node11 node12`，用 `NODES` 改。
- 執行的節點要有 `ceph`、`ha-manager` 指令（PVE 叢集節點一般都有）。

**怎麼做**：存成 `/root/lxc-debian13-update-all.sh`。

```bash
#!/usr/bin/env bash
# 一鍵更新：在任一 PVE 節點執行，依序更新每個節點上 running 的 Debian 13 LXC
# 環境變數：
#   NODES="node10 node11 node12"  要處理的節點（依序）
#   EXCLUDE="105 113"             不更新的 CTID（空白分隔）
#   ONLY="100"                    只更新指定 CTID（試跑用）
#   REBOOT=auto|always|never      重開策略，預設 auto（必要時才重開）
#   LIST_ONLY=1                   只列出清單與目前狀態，不更新（也不需要確認）
#   YES=1                         略過確認提示
#   SKIP_CEPH_CHECK=1             略過 Ceph 健康檢查（不建議）
#   SKIP_HA_CHECK=1               略過 HA 狀態檢查（不建議）
set -u
NODES="${NODES:-node10 node11 node12}"

update_local() {
  SNAP="pre-apt-$(date +%Y%m%d)"
  EXCLUDE=" ${EXCLUDE:-} "
  ONLY=" ${ONLY:-} "
  REBOOT="${REBOOT:-auto}"

  sysstate() { pct exec "$1" -- systemctl is-system-running </dev/null 2>/dev/null; }
  nfailed()  { pct exec "$1" -- systemctl --failed --no-legend </dev/null 2>/dev/null | wc -l; }

  need_reboot() {   # 回傳 0 = 需要重開
    case "$REBOOT" in always) echo "  重開原因：REBOOT=always"; return 0;; never) return 1;; esac
    if pct exec "$1" -- test -f /run/reboot-required </dev/null 2>/dev/null; then
      echo "  重開原因：/run/reboot-required"; return 0
    fi
    if ! pct exec "$1" -- sh -c 'command -v needrestart' </dev/null >/dev/null 2>&1; then
      echo "  重開原因：容器沒有 needrestart，無法判斷，保守重開"; return 0
    fi
    local svc
    svc=$(pct exec "$1" -- needrestart -b -r l </dev/null 2>/dev/null | grep '^NEEDRESTART-SVC:' | sed 's/^NEEDRESTART-SVC: //' | tr '\n' ' ')
    if [ -n "$svc" ]; then echo "  重開原因：待重啟的服務 $svc"; return 0; fi
    return 1
  }

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
  for id in "${targets[@]}"; do
    echo "  CT$id 目前狀態：$(sysstate "$id") failed=$(nfailed "$id")"
  done
  [ "${DRYRUN:-0}" = 1 ] && exit 0

  for id in "${targets[@]}"; do
    echo "===== CT$id ====="
    b_state=$(sysstate "$id"); b_failed=$(nfailed "$id")
    if [ "$b_state" != running ] || [ "$b_failed" != 0 ]; then
      echo "STOP：CT$id 更新前就不正常（state=${b_state:-無回應} failed=$b_failed），先處理再更新"
      exit 1
    fi

    pct snapshot "$id" "$SNAP" --description "Before apt upgrade" \
      || { echo "STOP：CT$id 拍快照失敗"; exit 1; }

    pct exec "$id" -- env DEBIAN_FRONTEND=noninteractive bash -c '
      apt-get update -qq &&
      apt-get -y -o Dpkg::Options::=--force-confold full-upgrade &&
      apt-get -y autoremove' </dev/null \
      || { echo "STOP：CT$id apt 失敗，快照 $SNAP 保留"; exit 1; }

    rebooted=0
    if need_reboot "$id"; then
      pct reboot "$id" || { echo "STOP：CT$id 重開失敗"; exit 1; }
      rebooted=1
    else
      echo "  不需要重開"
    fi

    state=""
    [ "$rebooted" = 1 ] && sleep 5
    for i in $(seq 1 30); do
      state=$(sysstate "$id")
      [ "$state" = running ] && break
      sleep 5
    done
    failed=$(nfailed "$id")
    if [ "$state" != running ] || [ "$failed" != 0 ]; then
      echo "STOP：CT$id state=${state:-無回應} failed=$failed"
      pct exec "$id" -- systemctl --failed --no-pager </dev/null 2>/dev/null
      exit 1
    fi
    echo "OK：CT$id 更新完成（重開=$rebooted，state=running，failed=0）"
  done
}

ceph_ok() {   # Ceph 必須是 HEALTH_OK 才繼續
  [ "${SKIP_CEPH_CHECK:-0}" = 1 ] && return 0
  local h
  h=$(ceph health 2>/dev/null | awk '{print $1}')
  [ "$h" = HEALTH_OK ] && return 0
  echo "STOP：Ceph 狀態是 ${h:-無法取得}，不是 HEALTH_OK，先處理再重跑（ceph -s、ceph health detail）"
  return 1
}

ha_ok() {     # HA 資源不能有 error／fence／freeze
  [ "${SKIP_HA_CHECK:-0}" = 1 ] && return 0
  local bad
  bad=$(ha-manager status 2>/dev/null | grep -E '^service ' | grep -Ei 'error|fence|freeze')
  [ -z "$bad" ] && return 0
  echo "STOP：HA 有異常的資源，先處理再重跑："; echo "$bad"
  return 1
}

preflight() { ceph_ok && ha_ok; }

run_nodes() {   # $1 = DRYRUN(1/0)
  local b64 n
  b64=$(declare -f update_local | base64 -w0)
  for n in $NODES; do
    [ "$1" = 0 ] && { preflight || exit 1; }   # 動每個節點之前都再檢查一次
    echo "######## 節點 $n ########"
    ssh -n -o BatchMode=yes "root@$n" \
      "EXCLUDE='${EXCLUDE:-}' ONLY='${ONLY:-}' REBOOT='${REBOOT:-auto}' DRYRUN=$1 bash -c \"\$(echo $b64 | base64 -d); update_local\"" \
      || { echo "STOP：節點 $n 異常，後面的節點不處理"; exit 1; }
  done
}

preflight || exit 1
echo ">>> 第 1 階段：只列出各節點會處理的 CT 與目前狀態（不修改）"
run_nodes 1
[ "${LIST_ONLY:-0}" = 1 ] && exit 0
if [ "${YES:-0}" != 1 ]; then
  read -r -p "確定依上面清單開始更新？輸入 y 或 yes 繼續：" ans
  case "$ans" in y|Y|yes|YES) ;; *) echo "已取消"; exit 0;; esac
fi
echo ">>> 第 2 階段：依序更新"
run_nodes 0
echo "全部節點完成。觀察服務一天後，請刪除 pre-apt-$(date +%Y%m%d) 快照"
```

| 片段 | 意思 |
| --- | --- |
| `update_local()` | 在**單一節點**上執行的主邏輯（篩選 CT → 基準線 → 快照 → apt → 必要時重開 → 驗證），包成函式 |
| `declare -f update_local \| base64 -w0` | 把函式內容編成一行文字，帶到遠端節點執行，**不用先把腳本複製過去** |
| `ssh -n -o BatchMode=yes` | `-n` 不讓 ssh 吃掉標準輸入；`BatchMode=yes` 不能免密碼登入就直接失敗，不會卡在問密碼 |
| `bash -c "$(echo … \| base64 -d); update_local"` | 在遠端還原函式並執行；腳本以參數傳入，所以容器內的 `pct exec` 不會誤讀到它 |
| `</dev/null` | 每個 `pct exec` 都不讀標準輸入，避免卡住 |
| `EXCLUDE=" ${EXCLUDE:-} "` | 前後補空白，之後用 `*" 105 "*` 精準比對，避免 `10` 誤中 `105` |
| `'. /etc/os-release; [ "$ID" = debian ] && [ "$VERSION_ID" = 13 ]'` | 容器內判斷是不是 Debian 13；不是就略過 |
| 第一個 `for id in "${targets[@]}"` 印目前狀態 | 列出每台更新**前**的 `is-system-running` 與 failed 數，也就是基準線 |
| `b_state`、`b_failed` | 動手前再確認一次，不是 `running` 或 failed 不為 0 就停止，**這時還沒拍快照、沒動容器** |
| `pct snapshot … \|\| { …; exit 1; }` | 拍快照失敗就停止，**沒有還原點就不更新** |
| `DEBIAN_FRONTEND=noninteractive`、`--force-confold` | 不跳互動問答；設定檔衝突時保留現有版本 |
| `need_reboot()` | 依第 6 節的規則判斷要不要重開，並印出原因 |
| `seq 1 30` + `sleep 5` | 最多等 150 秒，等 `systemctl is-system-running` 變成 `running` |
| `ceph_ok` | `ceph health` 第一個字必須是 `HEALTH_OK`；`HEALTH_WARN`、`HEALTH_ERR` 或指令失敗都停止 |
| `ha_ok` | `ha-manager status` 的 `service` 行出現 `error`、`fence`、`freeze` 就停止 |
| `preflight`（開頭與每個節點前） | 開始前檢查一次，之後每動一個節點前再檢查一次，避免前一個節點更新後叢集變差還繼續 |
| `\|\| { …; exit 1; }`（`run_nodes` 裡） | 任一節點回傳非 0 就停止，**不會繼續下一個節點** |
| `LIST_ONLY=1` | 第 1 階段列完清單就結束，不問、不更新 |
| `read -r -p …` ＋ `case … y\|Y\|yes\|YES` | 輸入 `y` 或 `yes`（不分大小寫）才會進第 2 階段，其他輸入或直接按 Enter 都取消；`YES=1` 可略過 |
| `SKIP_CEPH_CHECK=1`、`SKIP_HA_CHECK=1` | 略過檢查；有已知、可接受的警告時才用，要自己承擔風險 |

**執行方式**：

```bash
chmod +x /root/lxc-debian13-update-all.sh

# 1) 只看清單與各 CT 目前狀態，不更新
LIST_ONLY=1 /root/lxc-debian13-update-all.sh

# 2) 試跑：只更新影響最小的一台（先看清單、輸入 yes）
ONLY="<CTID>" /root/lxc-debian13-update-all.sh

# 3) 一鍵：排除不想自動處理的容器，依序更新全叢集
EXCLUDE="<CTID> <CTID>" /root/lxc-debian13-update-all.sh
```

**本環境建議的執行順序**（依第 5 節盤點；**尚未實測**）：

```bash
# a. 看清單
LIST_ONLY=1 EXCLUDE="101 105 113" /root/lxc-debian13-update-all.sh
# b. 試跑影響最小的 CT103（IPAM）
ONLY="103" /root/lxc-debian13-update-all.sh
# c. 其餘台，先排除 DNS 的 Pihole、Graylog、Lab Ops 所在的 CT 與 ProxCenter
EXCLUDE="101 105 110 113" /root/lxc-debian13-update-all.sh
# d. CT100 AdGuard 完成並確認 DNS 正常後，再單獨做 Pihole
ONLY="101" NODES="node12" /root/lxc-debian13-update-all.sh
# e. 確認 ProxCenter 的服務有 restart policy 後，單獨做 CT110
ONLY="110" NODES="node11" /root/lxc-debian13-update-all.sh
```

**應該看到什麼**：第 1 階段每個節點印「將依序更新的 Debian 13 CT：…」與各 CT 的 `目前狀態：running failed=0`；輸入 `y` 或 `yes` 後，每台依序出現 `===== CT<編號> =====`、（如有）`重開原因：…` 或 `不需要重開`，以及 `OK：CT<編號> 更新完成（重開=0 或 1，state=running，failed=0）`，最後印「全部節點完成」。出現 `STOP：…` 就是停在該台，先處理再重跑（見常見問題）。

**測試狀況**：用模擬的 `ssh`／`pct`／`ceph`／`ha-manager` 驗證過：

- 篩選：略過非 Debian 13、stopped、`EXCLUDE` 的 CT；`ONLY` 只處理指定的
- 重開策略：`reboot-required` 時重開、只有 `tzdata` 時不重開、`REBOOT=never`／`always` 如預期
- 保護：更新前就 `degraded` 的 CT 在拍快照前就停止；Ceph 非 `HEALTH_OK`、HA 有 `error` 時停止；某節點失敗時整個停止（exit 1）；`LIST_ONLY=1` 不需確認；輸入 y／yes 以外的內容會取消

2026-11-08 已在實際叢集執行（見下方實測紀錄）。`ha-manager status` 的 `service` 行格式（`service ct:103 (node10, started)`）與 `needrestart -b` 的輸出，實測與腳本的解析一致。

### 實測紀錄（2026-11-08，node11 執行）

| CT | 名稱 | 更新內容 | 重開 | 驗收結果 |
| --- | --- | --- | --- | --- |
| 103 | IPAM | `tzdata`（`2026c` → `2026f`） | 是（待重啟：`systemd-logind`、`unattended-upgrades`） | ✅ `needrestart` 乾淨、failed 0、HA `started`、有快照 |
| 100 | AdGuard | 同上 | 是（同上） | ✅ 同上 |
| 102 | librenms | 同上 | 是（同上） | ✅ 同上；快照未在驗收時列出 |
| 109 | wireguard | 同上 | 是（同上） | ✅ 同上；快照未在驗收時列出 |
| 101 | Pihole | `tzdata` 已是 `2026f` | 更新輸出未保存；快照時間 10:33:58，驗收時 `uptime` 約 1 小時 58 分，**推算**更新後有重開（未直接觀察） | ✅ `needrestart` 乾淨、failed 0、`running`、HA `started` |
| 110 | ProxCenter | `docker-ce` 系列＋`tzdata` | 更新輸出未保存 | ✅ 4 個容器 `Up`＋`healthy`、`needrestart` 乾淨、failed 0、`running`、HA `started`、有快照 |

實測過程遇到的事：

- **確認提示**：輸入 `y` 原本不被接受（只認 `yes`），連續被取消兩次，之後改成 `y`／`yes` 都可。打錯字（例如 `yws`）會取消，不會誤動作。
- **同日快照衝突**：CT101 重跑時出現 `snapshot name 'pre-apt-20261108' already used`，腳本在拍快照這步就停止，沒動容器。查證後確認該 CT 其實已更新完成（`tzdata` 為 `2026f`、沒有待更新套件），不需要再更新，也沒有刪快照。
- **第一次清單誤含已完成的 CT**：忘了把 103 加進 `EXCLUDE`，被確認提示攔下（取消）而沒有誤動。
- **CT110（ProxCenter）**：更新前檢查 `Live Restore Enabled: false`，4 個容器 restart policy 都是 `unless-stopped`；更新後 4 個都 `Up`、`healthy`。
- **刪快照（2026-11-09）**：隔天用第一節的刪快照指令，從 node10 一次處理三個節點，六台都印出 `Removing snap: 100% complete...done.` 與 `deleted CT…`（103、100、110、101、102、109）。
- **DNS 驗證**：用 `dig +short <網域> @<DNS 位址>` 測；從聊天視窗複製指令會把網址變成 `[…](https://…)` 的連結格式，要手動打字或貼上後檢查。

## 8. 步驟 3：更新後的驗收

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

**應該看到什麼**：`needrestart` 沒有 `NEEDRESTART-SVC` 行、failed 是 0、HA 是 `started`。再依容器用途確認服務本身（例如 DNS 能解析、`wg0` 還在、ProxCenter 的 docker 服務都起來了）。

## 9. 步驟 4：觀察一天後刪除快照

**做什麼**：快照會持續佔用 Ceph 空間，確認正常後刪除。

**怎麼做**（在每個節點上執行，`<日期>` 換成腳本印出的快照日期）：

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

## 10. 常見問題

| 現象 | 怎麼辦 |
| --- | --- |
| 「將依序更新的 Debian 13 CT：（無）」 | 該節點沒有 running 的 Debian 13 容器，或 `ONLY`／`EXCLUDE` 把它們都排除了；先跑步驟 1 看系統版本 |
| `STOP：CT<編號> 更新前就不正常` | 這台本來就 `degraded` 或有 failed unit，**腳本還沒動它**；`systemctl --failed` 找出原因，處理後再跑，或用 `EXCLUDE` 排除 |
| `STOP：CT<編號> 拍快照失敗` | 容器可能有不支援快照的掛載點（bind mount），或儲存空間不足；先解決再重跑，**不要跳過快照直接更新**。HA 在途中把 CT 遷到別的節點時也會失敗，這是安全的停止 |
| `STOP：… apt 失敗` | 進容器手動 `apt-get update` 看錯誤（常見是 DNS 或來源不通）；快照保留，修好後重跑即可（已更新的 CT 會變成「無待更新」，很快跑完） |
| 更新後 `state=degraded`、`failed=1` | 腳本已停止在該台（更新前是正常的，所以問題出在更新）；用 `systemctl --failed` 找是哪個服務，必要時 `pct rollback` |
| `STOP：Ceph 狀態是 HEALTH_WARN…` | 先 `ceph -s`、`ceph health detail` 看原因（例如 OSD down、scrub 中、時間不同步）；恢復 `HEALTH_OK` 再重跑。已知可接受的警告才用 `SKIP_CEPH_CHECK=1` |
| `STOP：HA 有異常的資源` | `ha-manager status` 看是哪個資源，處理後再跑。已知可接受才用 `SKIP_HA_CHECK=1` |
| 某節點出現 `STOP`，前面的節點已更新完 | 正常，前面的不用重做；修好後用 `NODES` 只列還沒做的節點重跑，例如 `NODES="node11 node12"` |
| `STOP：節點 <名稱> 異常` 沒有其他訊息 | 多半是 SSH 連不上（`BatchMode=yes` 不問密碼）；先手動 `ssh root@<名稱> true` 確認 |
| 重跑時說快照已存在（`snapshot name … already used`） | 同一天重跑會撞到同名快照，腳本會在拍快照這步停止，**沒有動容器**。**先不要刪快照**：用 `pct listsnapshot <CTID>`、`dpkg -l <套件>`、`apt list --upgradable` 確認這台是不是其實已經更新完（2026-11-08 的 CT101 就是）；確定還沒更新過，才 `pct delsnapshot <CTID> pre-apt-<日期>` 再跑，或改天再跑 |
| 確認提示輸入後直接「已取消」 | 只有 `y`、`Y`、`yes`、`YES` 會繼續，其他（包含打錯字、直接按 Enter）都取消；看清單時也要確認有沒有已更新過的 CT，避免同日快照衝突 |
| 有套件被 `apt-mark hold` 鎖住沒更新 | 這是預期行為；用 `apt-mark showhold` 確認，需要升級時再有控制地處理 |
| 透過 `rx` 執行被擋 | `rx` 會擋含 `reboot` 的指令（連名稱含這個字也擋），更新要由你直接在節點上執行 |
| 重開後一直等不到 `running`（150 秒逾時） | 可能是服務啟動慢；進容器 `systemctl is-system-running` 再看，必要時調大 `seq 1 30` 的 30 |

## 11. 待辦

- [x] 在實際叢集用 `LIST_ONLY=1` 確認清單，再用 `ONLY="103"` 試跑，把實測結果補回本文（2026-11-08 已完成，見第 7 節實測紀錄）
- [ ] 確認 CT110 更新時 `dockerd`／容器重啟花了多久、ProxCenter 網頁中斷多久（目前只有更新前後的檢查，沒有保存更新輸出）
- [x] 人工確認 IPAM、LibreNMS、WireGuard、ProxCenter 的網頁或連線功能正常（2026-11-09 已確認，四個服務都正常）
- [x] 觀察一天後，刪除六台 CT 的 `pre-apt-20261108` 快照（2026-11-09 已刪除：CT103、100、110、101、102、109 各印出 `deleted CT…`，三個節點的刪快照指令實測可用）
- [ ] 下一次更新時，確認舊待重啟服務清掉後，`REBOOT=auto` 是否真的會在「只有小更新」時跳過重開
- [ ] 確認 `LIST_ONLY=1` 能否透過 `rx` 執行（`rx` 是否只比對指令列字串，**未確認**）
- [ ] 評估更新前檢查 Ceph 剩餘空間
- [ ] 評估是否把 `EXCLUDE`／`ONLY` 設定改成設定檔，避免每次手打
- [ ] Graylog（CT105）是 Debian 12，另外依 [Graylog 更新步驟](https://kbwangtw.github.io/IT-Knowledge-Base/docs/pve/proxmox-graylog-syslog-pipeline-sop/)手動處理

## 12. 延伸閱讀

- [LXC 自動更新後，怎麼檢查「待重啟的服務」](https://kbwangtw.github.io/IT-Knowledge-Base/docs/pve/lxc-needrestart-service-restart/)：為什麼底層服務要整個容器重開，而不是逐一重啟
- [PVE 更新後的滾動重開機](https://kbwangtw.github.io/IT-Knowledge-Base/docs/pve/pve-rolling-reboot-after-update/)：節點本身的更新與重開順序
- [Claude Code 去識別化閘道 `rx`](https://kbwangtw.github.io/IT-Knowledge-Base/docs/pve/claude-code-redact-gateway/)：為什麼 `reboot` 要手動執行
- [Debian 官方 Release Notes（trixie）](https://www.debian.org/releases/trixie/release-notes/)：Debian 13 的升級與相依變動說明
