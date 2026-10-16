#!/usr/bin/env bash
set -euo pipefail

STATE_ROOT="${PROXMOX_ZH_TW_STATE_ROOT:-/var/lib/proxmox-zh-tw-notification}"
ROOT_PREFIX="${PROXMOX_ZH_TW_ROOT:-}"
MODE="auto"

usage() {
  cat <<'EOF'
用法：sudo ./uninstall.sh [--pve | --pbs | --all | --auto]

移除本專案安裝的模板，並還原首次安裝前的自訂模板。
EOF
}

log() { printf '[proxmox-zh-TW] %s\n' "$*"; }
die() { printf '[proxmox-zh-TW] 錯誤：%s\n' "$*" >&2; exit 1; }

while (($#)); do
  case "$1" in
    --auto) MODE="auto" ;;
    --pve) MODE="pve" ;;
    --pbs) MODE="pbs" ;;
    --all) MODE="all" ;;
    -h|--help) usage; exit 0 ;;
    *) die "未知參數：$1" ;;
  esac
  shift
done

[[ -n "$ROOT_PREFIX" || "${EUID}" -eq 0 ]] || die "請使用 root 權限執行（例如 sudo ./uninstall.sh）。"

uninstall_product() {
  local product="$1"
  local state_dir="${STATE_ROOT}/${product}"
  local target_file="${state_dir}/target"
  local list_file="${state_dir}/installed-files"
  local original_dir="${state_dir}/original"
  local target filename

  [[ -f "$target_file" && -f "$list_file" ]] || {
    log "找不到 ${product^^} 的安裝記錄，略過。"
    return
  }
  target="$(<"$target_file")"

  if [[ "$product" == "pve" ]]; then
    while IFS= read -r filename; do
      [[ -n "$filename" ]] || continue
      if [[ -f "${original_dir}/${filename}" ]]; then
        cp -- "${original_dir}/${filename}" "${target}/${filename}"
      else
        rm -f -- "${target}/${filename}"
      fi
    done < "$list_file"
  else
    while IFS= read -r filename; do
      [[ -n "$filename" ]] && rm -f -- "${target}/${filename}"
    done < "$list_file"

    if [[ -d "$original_dir" ]]; then
      cp -a -- "$original_dir"/. "$target"/
    fi
  fi

  if [[ -d "$original_dir" ]]; then
    log "已還原首次安裝前的 ${product^^} 自訂模板。"
  fi

  rm -rf -- "$state_dir"
  rmdir --ignore-fail-on-non-empty "$target" 2>/dev/null || true
  log "已移除 ${product^^} 繁體中文通知模板。"
}

case "$MODE" in
  pve) uninstall_product pve ;;
  pbs) uninstall_product pbs ;;
  all) uninstall_product pve; uninstall_product pbs ;;
  auto)
    found=false
    if [[ -d "${STATE_ROOT}/pve" ]]; then uninstall_product pve; found=true; fi
    if [[ -d "${STATE_ROOT}/pbs" ]]; then uninstall_product pbs; found=true; fi
    $found || die "找不到本專案的安裝記錄。"
    ;;
esac

rmdir --ignore-fail-on-non-empty "$STATE_ROOT" 2>/dev/null || true
log "移除完成；不需重新啟動服務。"
