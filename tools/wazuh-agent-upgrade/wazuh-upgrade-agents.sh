#!/usr/bin/env bash
# 在 Wazuh Manager 主機上，依序用內建的 agent_upgrade 升級指定的 Agent。
#
# 用法：
#   wazuh-upgrade-agents.sh ID [ID ...]          只預演（dry-run），不做任何升級
#   wazuh-upgrade-agents.sh --run ID [ID ...]    實際執行，一次一台
#
# 保護：
#   - 一次一台；升完確認「版本 = 目標版本 且 Active」才做下一台
#   - 任何一台失敗或逾時就停下來（不繼續）
#   - 升級前要求該 Agent 為 Active 且版本等於 FROM_VERSION
#   - Windows 主機、HARD_SKIP 清單的 ID 一律不處理
#   - CONFIRM_IDS 清單的 ID（DNS、PVE 節點、備份伺服器）每台要人工輸入 y 確認
#   - Manager 版本必須已是目標版本（Agent 版本不能高於 Manager）
#
# 可用環境變數覆蓋：
#   TARGET_VERSION(v4.14.9) FROM_VERSION(v4.14.8) PACKAGE_TYPE(deb)
#   TIMEOUT(300 秒) INTERVAL(10 秒) PAUSE(60 秒，兩台之間的間隔)
#   HARD_SKIP("014 015 016") CONFIRM_IDS("001 002 003 008 009 017")
#   AGENT_CONTROL AGENT_UPGRADE SKIP_MANAGER_CHECK(1 = 略過 Manager 版本檢查，僅測試用)

set -u

AC="${AGENT_CONTROL:-/var/ossec/bin/agent_control}"
AU="${AGENT_UPGRADE:-/var/ossec/bin/agent_upgrade}"
TARGET="${TARGET_VERSION:-v4.14.9}"
FROM="${FROM_VERSION:-v4.14.8}"
PKG="${PACKAGE_TYPE:-deb}"
TIMEOUT="${TIMEOUT:-300}"
INTERVAL="${INTERVAL:-10}"
PAUSE="${PAUSE:-60}"
HARD_SKIP="${HARD_SKIP:-014 015 016}"
CONFIRM_IDS="${CONFIRM_IDS:-001 002 003 008 009 017}"
LOG="${LOG_FILE:-$HOME/wazuh-agent-upgrade-$(date +%Y%m%d).log}"

RUN=0
IDS=()
for a in "$@"; do
  case "$a" in
    --run) RUN=1 ;;
    -h|--help) sed -n '2,23p' "$0"; exit 0 ;;
    *) IDS+=("$a") ;;
  esac
done

log() { printf '%s %s\n' "$(date '+%F %T')" "$*" | tee -a "$LOG"; }
in_list() { local x="$1"; shift; for i in $*; do [ "$i" = "$x" ] && return 0; done; return 1; }

if [ "${#IDS[@]}" -eq 0 ]; then
  echo "請指定 Agent ID，例如：$0 013（預演）或 $0 --run 013"
  exit 2
fi

# 讀取 Agent 資訊：設定 A_NAME A_STATUS A_VER A_OS
get_info() {
  local out
  out="$("$AC" -i "$1" 2>&1)"
  A_NAME="$(printf '%s\n' "$out" | awk -F': *' '/Agent Name:/{print $2; exit}')"
  A_STATUS="$(printf '%s\n' "$out" | awk -F': *' '/Status:/{print $2; exit}' | tr -d ' ')"
  A_VER="$(printf '%s\n' "$out" | awk '/Client version:/{print $NF; exit}')"
  A_OS="$(printf '%s\n' "$out" | awk -F': *' '/Operating system:/{print $2; exit}')"
}

if [ "${SKIP_MANAGER_CHECK:-0}" != "1" ]; then
  mver="$(dpkg-query -W -f='${Version}' wazuh-manager 2>/dev/null || true)"
  case "$mver" in
    "${TARGET#v}"*) ;;
    *) log "停止：Manager 版本是『${mver:-未知}』，不是 ${TARGET#v}；Agent 不能高於 Manager。"; exit 1 ;;
  esac
fi

[ "$RUN" -eq 1 ] && log "=== 開始（實際執行）：${IDS[*]}" || log "=== 預演（dry-run，不會升級）：${IDS[*]}"

total=${#IDS[@]}
n=0
for id in "${IDS[@]}"; do
  n=$((n + 1))
  if in_list "$id" $HARD_SKIP; then
    log "[$id] 在 HARD_SKIP 清單（Windows 或未確認系統），略過；請依 SOP 手動處理。"
    continue
  fi

  get_info "$id"
  if [ -z "$A_NAME" ]; then
    log "[$id] 停止：查不到這個 Agent。"; exit 1
  fi
  case "$A_OS" in
    *[Ww]indows*) log "[$id] $A_NAME 是 Windows（$A_OS），略過；Windows 要先清除待重開機項目，請手動處理。"; continue ;;
  esac
  if [ "$A_VER" = "Wazuh" ] || [ -z "$A_VER" ]; then
    log "[$id] 停止：讀不到 $A_NAME 的版本。"; exit 1
  fi
  if [ "$A_VER" = "$TARGET" ]; then
    log "[$id] $A_NAME 已是 $TARGET，略過。"; continue
  fi
  if [ "$A_STATUS" != "Active" ]; then
    log "[$id] 停止：$A_NAME 狀態是『$A_STATUS』，不是 Active。"; exit 1
  fi
  if [ "$A_VER" != "$FROM" ]; then
    log "[$id] 停止：$A_NAME 版本是 $A_VER，不是預期的 $FROM，請先人工確認。"; exit 1
  fi

  if [ "$RUN" -ne 1 ]; then
    log "[$id] (dry-run) 會升級 $A_NAME：$A_VER → $TARGET，指令：$AU -a $id -v $TARGET --package_type $PKG"
    continue
  fi

  if in_list "$id" $CONFIRM_IDS; then
    printf '[%s] %s 是重要主機（DNS／PVE 節點／備份伺服器）。現在可以升級嗎？(y/N) ' "$id" "$A_NAME"
    read -r ans
    if [ "$ans" != "y" ]; then log "[$id] 使用者未確認，停止。"; exit 1; fi
  fi

  log "[$id] 升級 $A_NAME：$A_VER → $TARGET"
  au_out="$("$AU" -a "$id" -v "$TARGET" --package_type "$PKG" 2>&1)"
  au_rc=$?
  printf '%s\n' "$au_out" | tee -a "$LOG"
  log "[$id] agent_upgrade 結束，退出碼 $au_rc；等待 Agent 回報新版本（最多 ${TIMEOUT} 秒）"

  waited=0
  ok=0
  while [ "$waited" -lt "$TIMEOUT" ]; do
    sleep "$INTERVAL"
    waited=$((waited + INTERVAL))
    get_info "$id"
    if [ "$A_VER" = "$TARGET" ] && [ "$A_STATUS" = "Active" ]; then ok=1; break; fi
  done

  if [ "$ok" -ne 1 ]; then
    log "[$id] 失敗：$A_NAME 目前版本 $A_VER、狀態 $A_STATUS（等了 ${waited} 秒）。已停止，請人工檢查（Agent 端的 /var/ossec/logs/ossec.log 與 upgrade.log）。"
    exit 1
  fi
  log "[$id] 成功：$A_NAME 已是 $A_VER、$A_STATUS（${waited} 秒）"

  if [ "$n" -lt "$total" ] && [ "$PAUSE" -gt 0 ]; then
    log "等待 ${PAUSE} 秒再處理下一台..."
    sleep "$PAUSE"
  fi
done

log "=== 完成"
