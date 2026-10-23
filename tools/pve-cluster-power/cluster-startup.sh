#!/bin/bash
# cluster-startup.sh — 三台開機後執行：等 quorum → 解除 Ceph 旗標 → 等 HEALTH_OK → 啟動關機前在跑的 HA 服務
set -u
STATE=/etc/pve/priv/ha-before-shutdown.txt      # 放在叢集共用目錄，開機後任一台都讀得到
GUESTS=/etc/pve/priv/guests-before-shutdown.txt # 不在 HA、關機前在跑的 VM／CT
LOG=/root/cluster-startup-$(date +%Y%m%d-%H%M).log
exec > >(tee -a "$LOG") 2>&1
say(){ echo "[$(date +%T)] $*"; }
die(){ say "!!! $*，已停止"; exit 1; }

say "== 1. 等叢集 quorum（最多 10 分鐘）"
for i in $(seq 1 60); do pvecm status 2>/dev/null | grep -q "Quorate:.*Yes" && break; sleep 10; done
pvecm status | grep -E "Quorate|Nodes" || true
pvecm status | grep -q "Quorate:.*Yes" || die "沒有 quorum，請確認三台都已開機"
[ -f "$STATE" ] || die "找不到 $STATE（關機前的 HA 紀錄）"

say "== 2. 解除 Ceph 旗標"
for f in pause nodown nobackfill norebalance norecover noout; do ceph osd unset $f; done

say "== 3. 等 Ceph HEALTH_OK（最多 15 分鐘）"
for i in $(seq 1 90); do
  s=$(ceph health 2>/dev/null); [ "${s%% *}" = HEALTH_OK ] && break
  [ $((i % 6)) = 0 ] && say "  $s"; sleep 10
done
ceph -s | grep -E "health|osd:|pgs:"
if [ "$(ceph health | awk '{print $1}')" != HEALTH_OK ]; then
  read -rp "Ceph 還不是 HEALTH_OK，仍要啟動服務？輸入 YES 繼續：" a; [ "$a" = YES ] || die "沒有啟動服務"
fi

say "== 4. 啟動關機前在跑的 HA 服務"
for sid in $(awk '/^service/ && /started/{print $2}' "$STATE"); do
  say "  start $sid"; ha-manager set "$sid" --state started
done
sleep 30; ha-manager status | grep '^service'

say "== 5. 啟動不在 HA、關機前在跑的 VM／CT"
if [ -s "$GUESTS" ]; then
  while read h t id; do
    say "  $h $t $id"
    if [ "$t" = vm ]; then ssh -n root@$h "qm start $id"; else ssh -n root@$h "pct start $id"; fi
  done < "$GUESTS"
fi
mv "$STATE" "/root/ha-before-shutdown-used-$(date +%Y%m%d-%H%M).txt"
[ -f "$GUESTS" ] && mv "$GUESTS" "/root/guests-before-shutdown-used-$(date +%Y%m%d-%H%M).txt"
say "完成。請確認 DNS、WireGuard、Graylog"
