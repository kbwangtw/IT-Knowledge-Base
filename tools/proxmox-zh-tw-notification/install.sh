#!/usr/bin/env bash
set -euo pipefail

REPOSITORY="kbwangtw/IT-Knowledge-Base"
SUBDIR="tools/proxmox-zh-tw-notification"
BRANCH="${PROXMOX_ZH_TW_BRANCH:-main}"
RAW_BASE="https://raw.githubusercontent.com/${REPOSITORY}/${BRANCH}/${SUBDIR}"
BACKUP_ROOT="${PROXMOX_ZH_TW_BACKUP_ROOT:-/var/backups/proxmox-zh-tw-notification}"
STATE_ROOT="${PROXMOX_ZH_TW_STATE_ROOT:-/var/lib/proxmox-zh-tw-notification}"
ROOT_PREFIX="${PROXMOX_ZH_TW_ROOT:-}"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P)"
MODE="auto"
tmp_dir=""

PVE_FILES=(
  vzdump-subject.txt.hbs
  vzdump-body.txt.hbs
  vzdump-body.html.hbs
)

PBS_FILES=(
  gc-ok-subject.txt.hbs gc-ok-body.txt.hbs
  gc-err-subject.txt.hbs gc-err-body.txt.hbs
  prune-ok-subject.txt.hbs prune-ok-body.txt.hbs
  prune-err-subject.txt.hbs prune-err-body.txt.hbs
  verify-ok-subject.txt.hbs verify-ok-body.txt.hbs
  verify-err-subject.txt.hbs verify-err-body.txt.hbs
  sync-ok-subject.txt.hbs sync-ok-body.txt.hbs
  sync-err-subject.txt.hbs sync-err-body.txt.hbs
  package-updates-subject.txt.hbs package-updates-body.txt.hbs
)

usage() {
  cat <<'EOF'
用法：sudo ./install.sh [--pve | --pbs | --all | --auto]

  --auto  自動偵測已安裝的 Proxmox 產品（預設）
  --pve   僅安裝 Proxmox VE 9.x 模板
  --pbs   僅安裝 Proxmox Backup Server 4.x 模板
  --all   同時安裝 PVE 與 PBS 模板
EOF
}

log() { printf '[proxmox-zh-TW] %s\n' "$*"; }
die() { printf '[proxmox-zh-TW] 錯誤：%s\n' "$*" >&2; exit 1; }
cleanup() {
  if [[ -n "${tmp_dir:-}" && -d "${tmp_dir:-}" ]]; then
    rm -rf -- "$tmp_dir"
  fi
}
trap cleanup EXIT

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

[[ -n "$ROOT_PREFIX" || "${EUID}" -eq 0 ]] || die "請使用 root 權限執行（例如 sudo ./install.sh）。"

root_path() { printf '%s%s' "$ROOT_PREFIX" "$1"; }
pve_config_dir="$(root_path /etc/pve)"
pbs_config_dir="$(root_path /etc/proxmox-backup)"

has_pve=false
has_pbs=false
if [[ -d "$pve_config_dir" ]] || { [[ -z "$ROOT_PREFIX" ]] && command -v pveversion >/dev/null 2>&1; }; then has_pve=true; fi
if [[ -d "$pbs_config_dir" ]] || { [[ -z "$ROOT_PREFIX" ]] && command -v proxmox-backup-manager >/dev/null 2>&1; }; then has_pbs=true; fi

case "$MODE" in
  auto)
    $has_pve || $has_pbs || die "找不到 PVE 或 PBS；可用 --pve 或 --pbs 明確指定。"
    ;;
  pve) has_pve=true; has_pbs=false ;;
  pbs) has_pve=false; has_pbs=true ;;
  all) has_pve=true; has_pbs=true ;;
esac

timestamp="$(date -u +%Y%m%dT%H%M%SZ)-$$"
mkdir -p "$BACKUP_ROOT" "$STATE_ROOT"
if [[ -z "$ROOT_PREFIX" ]]; then
  chmod 0700 "$BACKUP_ROOT" "$STATE_ROOT"
fi

fetch_template() {
  local product="$1" filename="$2" destination="$3"
  local local_file="${SCRIPT_DIR}/${product}/default/${filename}"

  if [[ -f "$local_file" ]]; then
    install -m 0644 "$local_file" "$destination"
  else
    command -v curl >/dev/null 2>&1 || die "找不到 curl，無法下載模板。"
    curl -fsSL "${RAW_BASE}/${product}/default/${filename}" -o "$destination"
    chmod 0644 "$destination"
  fi
}

copy_to_target() {
  local product="$1" source="$2" destination="$3"

  if [[ "$product" == "pve" ]]; then
    # /etc/pve is pmxcfs: it manages permissions and rejects chmod.
    cp -- "$source" "$destination"
  else
    install -m 0644 "$source" "$destination"
  fi
}

install_product() {
  local product="$1" target="$2"
  shift 2
  local -a files=("$@")
  local state_dir="${STATE_ROOT}/${product}"
  local backup_dir="${BACKUP_ROOT}/${product}-${timestamp}"
  local original_dir="${state_dir}/original"
  local rollback_dir filename
  tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/proxmox-zh-tw.XXXXXX")"
  rollback_dir="${tmp_dir}/rollback"
  mkdir -p "$target" "$state_dir" "$rollback_dir"

  # Fetch every template before changing the target or recording installation state.
  for filename in "${files[@]}"; do
    fetch_template "$product" "$filename" "${tmp_dir}/${filename}"
  done

  if find "$target" -mindepth 1 -maxdepth 1 -print -quit | grep -q .; then
    mkdir -p "$backup_dir"
    cp -a -- "$target"/. "$backup_dir"/
    log "已備份現有 ${product^^} 自訂模板至 ${backup_dir}"
  fi

  if [[ ! -e "${state_dir}/original-recorded" ]]; then
    mkdir -p "$original_dir"
    if find "$target" -mindepth 1 -maxdepth 1 -print -quit | grep -q .; then
      cp -a -- "$target"/. "$original_dir"/
    fi
    : > "${state_dir}/original-recorded"
  fi

  # Snapshot only managed paths so a partial copy can be rolled back safely.
  for filename in "${files[@]}"; do
    if [[ -e "${target}/${filename}" ]]; then
      cp -a -- "${target}/${filename}" "${rollback_dir}/${filename}"
    else
      : > "${rollback_dir}/${filename}.absent"
    fi
  done

  for filename in "${files[@]}"; do
    if ! copy_to_target "$product" "${tmp_dir}/${filename}" "${target}/${filename}"; then
      log "安裝 ${product^^} 模板失敗，正在還原本次變更。"
      for filename in "${files[@]}"; do
        if [[ -e "${rollback_dir}/${filename}" ]]; then
          copy_to_target "$product" "${rollback_dir}/${filename}" "${target}/${filename}" || \
            log "警告：無法還原 ${target}/${filename}"
        else
          rm -f -- "${target}/${filename}" || \
            log "警告：無法移除 ${target}/${filename}"
        fi
      done
      return 1
    fi
  done

  # installed-files is the completion marker consumed by uninstall.sh.
  printf '%s\n' "$target" > "${tmp_dir}/target"
  printf '%s\n' "${files[@]}" > "${tmp_dir}/installed-files"
  mv -f -- "${tmp_dir}/target" "${state_dir}/target"
  mv -f -- "${tmp_dir}/installed-files" "${state_dir}/installed-files"
  cleanup
  tmp_dir=""
  log "已安裝 ${product^^} 繁體中文通知模板至 ${target}"
}

if $has_pve; then
  install_product pve "${pve_config_dir}/notification-templates/default" "${PVE_FILES[@]}"
fi
if $has_pbs; then
  install_product pbs "${pbs_config_dir}/notification-templates/default" "${PBS_FILES[@]}"
fi

log "安裝完成；通知模板會在產生下一封通知時載入，不需重新啟動服務。"
