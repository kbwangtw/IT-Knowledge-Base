---
layout: default
title: "Ceph 出現 BlueStore 慢操作告警：硬碟壞了嗎？備份排程怎麼排？"
permalink: /docs/pve/ceph-bluestore-slow-op-backup-schedule/
date: 2026-10-14
categories: [PVE, Ceph, PBS, Backup, Troubleshooting]
last_modified_at: 2026-10-15
---

# Ceph 出現 BlueStore 慢操作告警：硬碟壞了嗎？備份排程怎麼排？

10/13 早上 Ceph 出現 `HEALTH_WARN`：osd.0 有 BlueStore 慢操作。查下來，硬碟與核心設定都正常；osd.0 的 `aio_submit retries` 有七成五集中在每晚 21:00，也就是三台 PVE 同時開始備份的時間，而且三顆 OSD 都有同樣現象。

本次把三台的備份錯開 30 分鐘，順便整理 PBS 的 Prune、GC 與 Verify 排程。**結果：PBS 的 GC 從 77 分鐘降到 7 分鐘，告警也消失；但 Ceph 的 retries 次數幾乎沒有變化。**

> 紀錄日期：2026-10-13～14；PVE 9.2.21、kernel 7.0.14-23-pve、Ceph 20.2.4-pve5；PBS31 為 PBS 4.2.8，datastore Tokyo16 位於 CIFS 掛載。

## 1. 告警的意思

~~~text
HEALTH_WARN: 1 OSD(s) experiencing slow operations in BlueStore
[WRN] BLUESTORE_SLOW_OP_ALERT: osd.0 observed slow operation indications in BlueStore
~~~

osd.0 在 node10。這是警告不是錯誤，資料仍在、服務照常。這類告警在發生過慢操作後會保留一段時間才自動消失，所以看到告警不代表「現在」還在變慢。

告警出現時先不要重啟 OSD，也不要 `ceph osd out`：重啟不會讓它好，反而會觸發資料重新平衡、增加負載。

## 2. 先排除硬碟與核心

在任一台 node 與 node10 執行，以下都只讀取：

~~~bash
ceph health detail
ceph osd perf
journalctl -u ceph-osd@0 --since "2 days ago" --no-pager | grep -iE "slow|aio_submit|log_latency" | tail -15
dmesg -T | grep -iE "nvme|i/o error|reset|timeout" | tail -10
ceph osd metadata 0 | grep -E '"devices"|"bluestore_bdev_dev_node"|"rotational"'
smartctl -a /dev/<osd.0 的硬碟> | grep -iE "critical|media|error|percentage used|available spare|temperature|unsafe"
cat /proc/sys/fs/aio-nr /proc/sys/fs/aio-max-nr
~~~

| 檢查 | 結果 | 判讀 |
| --- | --- | --- |
| `ceph osd perf` | osd.0 6 ms，osd.1／osd.2 1 ms | 略高但不算慢 |
| osd.0 日誌 | 10/12 21:03～21:14 有十幾筆 `aio_submit retries 2～7` | Ceph 交給核心的讀寫佇列滿了，只好重試 |
| dmesg | 只有開機訊息，沒有 I/O error、reset、timeout | 核心沒看到硬碟錯誤 |
| SMART（osd.0 的 NVMe） | Critical Warning 0x00、Media Errors 0、Error Log 0、Spare 100%、已用 4%、40～48°C | 硬碟健康 |
| 核心 AIO | 使用 2,048／上限 1,048,576 | 不是核心上限不夠 |

SMART 另外顯示 Unsafe Shutdowns 15 次，是過去不正常斷電的累計，不是這次的原因，之後可觀察是否增加。

`aio_submit retries` 代表某段時間同時送出的讀寫太多、排隊排滿，是負載問題，不是硬碟壞掉。

## 3. 找出規律：每晚 21:00，三顆 OSD 都有

~~~bash
# 每天的次數
journalctl -u ceph-osd@0 --since "30 days ago" --no-pager | grep "aio_submit retries" | awk '{print $1, $2}' | sort | uniq -c
# 每小時的分布
journalctl -u ceph-osd@0 --since "30 days ago" --no-pager | grep "aio_submit retries" | awk '{print substr($3,1,2)":00"}' | sort | uniq -c
# 另外兩顆
ssh root@node11 'journalctl -u ceph-osd@1 --since "30 days ago" --no-pager | grep -c "aio_submit retries"'
ssh root@node12 'journalctl -u ceph-osd@2 --since "30 days ago" --no-pager | grep -c "aio_submit retries"'
cat /etc/pve/jobs.cfg
~~~

- 9/13～10/12 每天都有，每天 10～91 次；9/22（OSD 金鑰修復當天）最多。日誌只保留到 9/13，無法判斷是否在 Ceph 20.2.4 升級後才開始。
- osd.0 的 30 天加總中，**21:00 這一小時佔 624 次，約七成五**。
- 30 天合計：osd.0 約 836、osd.1 1,323、osd.2 2,010，**另外兩顆比 osd.0 更多**。這不是 osd.0 或 node10 的問題，只是這次剛好由 osd.0 超過告警門檻。
- 備份排程當時只有一個：`all 1`、`schedule 21:00`、`mode snapshot`、`storage PBS31`、`prune-backups keep-daily=7,keep-last=3`。三台 node 每晚 21:00 同時開始備份所有 VM／CT。

10/12 的備份比平常久（node10 15 分、node11 16 分，平常 8～12 分），推測是當天三台重開、多台 VM 重啟或搬移，QEMU 的 dirty bitmap 被清掉，下一次備份必須完整讀取整顆磁碟。這點沒有逐筆查 vzdump log 確認。

## 4. 調整：三台備份錯開 30 分鐘

PVE Web UI **Datacenter → Backup**：原本的排程改為只跑 node10，另外新增兩個，其他設定完全一樣：

| 排程 | Node | 時間 | Selection |
| --- | --- | --- | --- |
| 原排程 | node10 | 21:00 | All |
| 新增 | node11 | 21:30 | All |
| 新增 | node12 | 22:00 | All |

**Selection mode 一定要選 All 再搭配 Node**：每個排程備份「當下在那台 node 上的所有 VM／CT」，HA 搬移後由新 node 的排程負責，三個加起來仍涵蓋全部。若剛好在兩個排程之間搬移，那天可能多備一次或漏一次，隔天會恢復。

每台實際只需 5～16 分鐘，所以 30 分鐘間隔足夠。

## 5. 順便整理 PBS 排程

### Prune Job 沒有設定任何保留規則

PBS 的 Prune Job 每天都是 `WARNINGS: 1`，Keep 各欄全空，只跑 0.1 秒。log：

~~~text
No prune selection - keeping all files.
Pruning group :"ct/101"
remove ct/101/2026-10-03T13:00:02Z
remove ct/101/2026-10-04T13:00:04Z
...
TASK WARNINGS: 1
~~~

**每一筆都標示 `remove`，但實際上什麼都沒刪**：沒有保留規則時，PBS 判定全部保留，log 只是印出計算時的標記。證據：

- datastore 目錄 `ct/101/` 仍有 10/03～10/12 共 10 個快照目錄（加上 `owner` 檔）。
- 14 個群組各 10 筆，ProxCenter 與 `pvesm list PBS31` 都是 140 筆。
- 每組 10 筆剛好等於 PVE 端 `keep-last=3` 加 `keep-daily=7`，實際清理舊備份的是 PVE 端。

這個 Prune Job 沒有作用、每天產生警告，日後若有人只填一部分規則還可能真的開始刪、而且比 PVE 端更嚴格，所以**直接刪除**。GC Job 必須保留，它負責釋放空間。

### Verify 與 GC 錯開

原本 GC 與 Verify 都在 00:00 開始，兩者都大量讀取同一個 datastore。把 Verify 改為 `02:00`（PBS 排程欄位可直接輸入時間，選單只是範例）。

## 6. 結果（10/13 晚上到 10/14 清晨）

| 項目 | 調整前 | 10/13 晚上 |
| --- | --- | --- |
| node10 備份 | 21:00 同時開始 | 21:00:06～21:07:43（7 分 37 秒） |
| node11 備份 | 21:00 同時開始 | 21:30:03～21:39:10（9 分 07 秒） |
| node12 備份 | 21:00 同時開始 | 22:00:03～22:04:32（4 分 29 秒） |
| PBS GC | 00:00 開始，1 小時 17 分 | 00:00 開始，**7 分 06 秒** |
| PBS Verify | 00:00 開始，1 小時 15 分 | 02:00 開始，59 分 22 秒 |
| Ceph | HEALTH_WARN | HEALTH_OK |

三台備份沒有重疊，全部 OK。GC 從 77 分鐘降到 7 分鐘，代表過去與 Verify 同時讀取時被拖慢了十倍以上；這是本次最明確的改善。GC 這次清掉的 66.11 GB 正是上一次留下的待清除量，新的待清除 41.68 GB 會在下一次 GC 處理，屬正常機制。

**Ceph 的 retries 沒有變少。** 用同一時段（20:50～23:00）比較：

~~~bash
for d in 10 11 12 13; do
  echo -n "10/$d 晚上："
  for n in node10:0 node11:1 node12:2; do
    h=${n%:*}; o=${n#*:}
    echo -n " osd.$o=$(ssh root@$h "journalctl -u ceph-osd@$o --since '2026-10-$d 20:50' --until '2026-10-$d 23:00' --no-pager | grep -c 'aio_submit retries'")"
  done
  echo
done
~~~

| 晚上 | osd.0 | osd.1 | osd.2 | 合計 |
| --- | --- | --- | --- | --- |
| 10/10 | 26 | 43 | 74 | 143 |
| 10/11 | 29 | 37 | 70 | 136 |
| 10/12 | 25 | 43 | 76 | 144 |
| **10/13（錯開後）** | 23 | 47 | 65 | 135 |
| 10/14 | 30 | 42 | 83 | 155 |

10/14 晚上合計 155，比前幾晚多約一成，主要是 osd.2（83）。當天中午 osd.1 曾因[金鑰輪換](https://kbwangtw.github.io/IT-Knowledge-Base/docs/pve/ceph-bluestore-osd-key-recovery-2026-09-22/)停機約一分鐘，是否相關無法判斷；告警沒有出現，繼續觀察到 10/21 再看趨勢。

推測原因：RBD 磁碟的資料分散在三顆 OSD 上，就算同一時間只有一台 node 在備份，讀取仍會同時打到三顆 OSD，單一台的備份就足以讓佇列短暫滿載。錯開排程降低的是「三台同時」的疊加，而不是單一備份的瞬間讀取量。

另外 10/12 晚上的 retries 數量和其他晚上差不多，告警卻只在那晚之後出現；`BLUESTORE_SLOW_OP_ALERT` 看的是慢操作，`aio_submit retries` 只是其中一種跡象，兩者不是一對一。告警消失可能是因為昨晚的慢操作沒有超過門檻，也可能只是過了保留時間，本次沒有逐筆分辨。

## 7. 本次結論與待觀察

- 硬碟、核心 AIO 上限都正常；`aio_submit retries` 每晚發生在備份時段，三顆 OSD 都有，重試後完成，目前沒有資料錯誤。
- 錯開三台備份：沒有減少 Ceph retries，但避免三台同時讀取、備份時間沒有變長，維持此設定。
- PBS：刪除沒有規則的 Prune Job；Verify 改到 02:00 後，GC 從 77 分鐘降到 7 分鐘。
- 觀察：`ceph health` 是否再出現 `BLUESTORE_SLOW_OP_ALERT`；osd.0 SMART 的 Unsafe Shutdowns 是否增加。
- 若告警反覆出現，再評估降低單一備份的並行讀取（例如 vzdump 的頻寬限制或 `performance` 的 max-workers），本次沒有調整。

PBS 每天的忙碌時段因此變成三段：21:00～22:30（接收備份）、00:00 起的 GC、02:00～03:00 的 Verify。重啟 `proxmox-backup-proxy`、升級 PBS 套件或重開 PBS 都要避開。

## 8. 每日快速健康檢查腳本

把觀察項目整理成一支唯讀腳本，放在 node10，想看時手動執行一次（10/15 起使用）。它會 SSH 到另外兩台查詢；SMART 只查 node10 本機的 osd.0。

| 段落 | 正常的樣子 | 基準 |
| --- | --- | --- |
| 1. Ceph | `HEALTH_OK`、3 up／3 in、97 active+clean | — |
| 2. retries | 三顆合計約 135～155 | 10/10～10/14 |
| 3. osd.0 SMART | Unsafe Shutdowns 15、Media Errors 0、Critical Warning 0x00 | 10/13 |
| 4. 備份 | 三台 OK，約 21:00／21:30／22:00 開始 | 錯開後的排程 |
| 5. HA、服務 | `HA 全部正常`，三台沒有 failed 服務 | — |

安裝（在 node10）：

~~~bash
cat > /usr/local/bin/pve-daily-check.sh <<'EOF'
#!/bin/bash
# 每日快速健康檢查（唯讀）。在 node10 執行。
# 用法：pve-daily-check.sh [日期]，預設檢查昨晚，例如 pve-daily-check.sh 2026-10-13
set -u
D=${1:-$(date -d yesterday +%F)}
D=$(date -d "$D" +%F) || exit 1
echo "##### $(hostname) $(date '+%F %T')，retries 檢查 $D 晚上 #####"

echo; echo "===== 1. Ceph ====="
ceph health detail
ceph -s | grep -E "osd:|pgs:|volumes:"

echo; echo "===== 2. aio_submit retries（$D 20:50～23:00）====="
total=0
for n in node10:0 node11:1 node12:2; do
  h=${n%:*}; o=${n#*:}
  c=$(ssh root@$h "journalctl -u ceph-osd@$o --since '$D 20:50' --until '$D 23:00' --no-pager | grep -c 'aio_submit retries'")
  echo -n "osd.$o=$c  "; total=$((total + c))
done
echo "合計=$total"

echo; echo "===== 3. osd.0 SMART ====="
if [ "$(hostname)" = node10 ]; then
  dev=$(ceph osd metadata 0 | python3 -c 'import json,sys;print(json.load(sys.stdin)["devices"].split(",")[0])')
  echo "裝置：/dev/$dev"
  smartctl -a "/dev/$dev" | grep -iE "unsafe shutdowns|media and data integrity|critical warning|percentage used|temperature:"
else
  echo "osd.0 在 node10，請在 node10 執行這段"
fi

echo; echo "===== 4. 最近一次備份 ====="
for h in node10 node11 node12; do
  echo -n "$h: "; ssh root@$h "pvenode task list --typefilter vzdump --limit 1 2>/dev/null | grep vzdump | awk -F'│' '{print \$6, \$8}'"
done

echo; echo "===== 5. HA 與失敗的服務 ====="
ha-manager status | grep -E "error|starting|disabled|stopped|fence" || echo "HA 全部正常"
for h in node10 node11 node12; do
  echo -n "$h: "; ssh root@$h "systemctl --failed --no-legend --plain | awk '{print \$1}' | tr '\n' ' '"; echo
done
EOF
chmod 755 /usr/local/bin/pve-daily-check.sh
pve-daily-check.sh
~~~

注意：

- 第 4 段抓的是 `pvenode task list` 表格的第 6、8 欄（開始時間、狀態）；PVE 改版若表格欄位變動，這段可能顯示錯位，改看原始輸出即可。
- 腳本只讀取，不改任何設定；也沒有排程與通知。觀察一段時間、retries 的正常範圍確定後，再考慮改成「只有異常才通知」。
- 這支腳本放在 node10 本機，重灌或換機時要重新建立。

## 相關紀錄

- [PVE 重開後 Ceph 又故障：修正 BlueStore 裡的 OSD 金鑰](https://kbwangtw.github.io/IT-Knowledge-Base/docs/pve/ceph-bluestore-osd-key-recovery-2026-09-22/)（9/20 `aio_submit retries` 原列為觀察項目）
- [PBS 更新後，怎麼確認備份還能用？](https://kbwangtw.github.io/IT-Knowledge-Base/docs/pve/ProxCenter-PBS-Update-and-DR-Validation-SOP/)
- [Proxmox VE Backup and Restore](https://pve.proxmox.com/pve-docs/chapter-vzdump.html)
- [Proxmox Backup Server：Maintenance Tasks](https://pbs.proxmox.com/docs/maintenance.html)
