#!/bin/bash
# cluster-shutdown.sh — PVE 叢集一鍵關機（HA 服務、其他 VM／CT、Ceph 維護旗標、停 HA 監看、三台關機）
# 用法：cluster-shutdown.sh --dry-run   只檢查、列出會做什麼，不做任何變更
#       cluster-shutdown.sh             實際執行（要輸入 SHUTDOWN 確認）
set -u
NODES="node10 node11 node12"
ME=$(hostname); OTHERS=$(for n in node12 node11 node10; do [ "$n" != "$ME" ] && echo -n "$n "; done)
STATE=/etc/pve/priv/ha-before-shutdown.txt      # 放在叢集共用目錄，開機後任一台都讀得到
GUESTS=/etc/pve/priv/guests-before-shutdown.txt # 不在 HA、關機前在跑的 VM／CT
LOG=/root/cluster-shutdown-$(date +%Y%m%d-%H%M).log
DRY=0; [ "${1:-}" = "--dry-run" ] && DRY=1

exec > >(tee -a "$LOG") 2>&1
say(){ echo "[$(date +%T)] $*"; }
die(){ say "!!! $*，腳本已停止，後面的步驟沒有執行"; exit 1; }

say "== 0. 事前檢查"
pvecm status | grep -q "Quorate:.*Yes" || die "叢集沒有 quorum"
for h in $OTHERS; do ssh -o BatchMode=yes -o ConnectTimeout=5 root@$h true || die "SSH 連不到 $h"; done
H=$(date +%H); if [ "$H" -ge 21 ] || [ "$H" -lt 3 ]; then say "⚠️ 現在是 21:00～03:00 備份時段"; fi
say "Ceph：$(ceph health)"
say "HA 服務（目前狀態）："; ha-manager status | grep '^service'
say "目前執行中的 VM／CT（含 HA 管理的）："
for h in $NODES; do
  ssh root@$h 'pct list | awk "NR>1 && \$2==\"running\"{print \"  '"$h"' CT\", \$1, \$NF}"; qm list | awk "NR>1 && \$3==\"running\"{print \"  '"$h"' VM\", \$1, \$2}"'
done
if [ $DRY = 1 ]; then say "--dry-run：只檢查，沒有做任何變更"; exit 0; fi

read -rp "確定要關閉整個叢集（含所有 VM／CT）？輸入 SHUTDOWN 繼續：" a
[ "$a" = SHUTDOWN ] || die "沒有輸入 SHUTDOWN"

say "== 1. 記錄 HA 狀態 → $STATE"
ha-manager status > "$STATE"
cp -a "$STATE" "/root/ha-before-shutdown-$(date +%Y%m%d-%H%M).txt"

HA_IDS=$(awk '/^service/{print $2}' "$STATE")
for h in $NODES; do
  ssh -n root@$h 'pct list | awk "NR>1 && \$2==\"running\"{print \"ct\", \$1}"; qm list | awk "NR>1 && \$3==\"running\"{print \"vm\", \$1}"' | while read t id; do
    echo "$HA_IDS" | grep -qx "$t:$id" || echo "$h $t $id"
  done
done > "$GUESTS"
say "  不在 HA、開機後要重新啟動的：$(tr '\n' ' ' < "$GUESTS")"

say "== 2. 停止 HA 服務"
for sid in $(awk '/^service/ && /started/{print $2}' "$STATE"); do
  say "  stop $sid"; ha-manager set "$sid" --state stopped
done
for i in $(seq 1 60); do
  n=$(ha-manager status | grep '^service' | grep -cE 'started|stopping|request_stop|migrate|relocate')
  [ "$n" = 0 ] && break
  say "  還有 $n 個服務在停止中…（$i/60）"; sleep 10
done
[ "$n" = 0 ] || die "10 分鐘內 HA 服務沒有全部停止，請手動檢查 ha-manager status"

say "== 3. 關閉不在 HA 的 VM／CT（逾時不強制關，改為停止腳本）"
for h in $NODES; do
  ssh root@$h '
    for id in $(pct list | awk "NR>1 && \$2==\"running\"{print \$1}"); do echo "  '"$h"' CT $id"; pct shutdown $id --timeout 120; done
    for id in $(qm list | awk "NR>1 && \$3==\"running\"{print \$1}"); do echo "  '"$h"' VM $id"; qm shutdown $id --timeout 300; done
  '
done
LEFT=$(for h in $NODES; do ssh root@$h 'pct list | awk "NR>1 && \$2==\"running\"" ; qm list | awk "NR>1 && \$3==\"running\""' | sed "s/^/$h /"; done)
[ -z "$LEFT" ] || { echo "$LEFT"; die "還有 VM／CT 在執行"; }
say "  所有 VM／CT 都已停止"

say "== 4. Ceph 維護旗標"
for f in noout norecover norebalance nobackfill nodown pause; do ceph osd set $f; done
ceph -s | grep -E "health|flag"

say "== 5. 停止 HA 監看程式（避免最後一台失去 quorum 時被 watchdog 強制重開）"
for h in $NODES; do ssh root@$h 'systemctl stop pve-ha-lrm'; done
for h in $NODES; do ssh root@$h 'systemctl stop pve-ha-crm'; done
for h in $NODES; do echo "  $h: lrm=$(ssh root@$h systemctl is-active pve-ha-lrm) crm=$(ssh root@$h systemctl is-active pve-ha-crm)"; done

say "== 6. 關機：$OTHERS，最後 $ME（先延遲卸載 CephFS，避免關機卡住）"
for h in $OTHERS; do ssh root@$h 'umount -l /mnt/pve/cephfs 2>/dev/null; nohup shutdown -h now >/dev/null 2>&1 &'; done
for h in $OTHERS; do
  for i in $(seq 1 36); do ping -c1 -W1 $h >/dev/null 2>&1 || break; sleep 5; done
  say "  $h 已無回應"
done
say "$ME 關機。三台開機後，在任一台執行 /usr/local/sbin/cluster-startup.sh"
sync; umount -l /mnt/pve/cephfs 2>/dev/null; shutdown -h now
