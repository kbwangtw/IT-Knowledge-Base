---
layout: default
title: "Ceph 出現 BlueStore 慢操作告警：硬碟壞了嗎？備份排程怎麼排？"
permalink: /docs/pve/ceph-bluestore-slow-op-backup-schedule/
date: 2026-10-14
categories: [PVE, Ceph, PBS, Backup, Troubleshooting]
last_modified_at: 2026-10-17
---

# Ceph 出現 BlueStore 慢操作告警：硬碟壞了嗎？備份排程怎麼排？

> **一句話**：Ceph 跳出「慢操作」警告，查下來**硬碟沒壞**，而是每晚 21:00 三台同時備份、讀寫排隊排滿；把備份錯開 30 分鐘、整理 PBS 排程後，PBS 的 GC 從 77 分鐘降到 7 分鐘，告警消失，但 Ceph 的重試次數幾乎沒變。

| 項目 | 內容 |
| --- | --- |
| 適合誰看 | 看到 `BLUESTORE_SLOW_OP_ALERT`、想知道要不要換硬碟的人；要排 PVE／PBS 備份時間的人 |
| 環境 | PVE 9.2.21、kernel 7.0.14-23-pve、Ceph 20.2.4-pve5；PBS31 為 PBS 4.2.8，datastore Tokyo16 在 CIFS 掛載上 |
| 日期 | 2026-10-13～14；10/16 補 slow ops 歷史 |
| 結論 | ✅ 硬碟與核心正常；✅ 三台備份錯開；✅ PBS GC 77 → 7 分鐘；✅ 告警消失；⏳ Ceph retries 沒有變少，持續觀察 |

## 1. 先認識幾個名詞

| 名詞 | 白話解釋 |
| --- | --- |
| **OSD** | Ceph 裡負責一顆硬碟讀寫的服務；本案 osd.0／1／2 分別在 node10／11／12 |
| **BlueStore** | OSD 存資料的方式，直接管理整顆硬碟 |
| **慢操作（slow operation）** | 某些讀寫花太久；告警會保留一段時間才消失 |
| **aio_submit retries** | Ceph 把讀寫交給核心時，佇列滿了只好重試；代表「太忙」，不是「壞掉」 |
| **slow ops** | 單一操作超過 30 秒還沒完成，比 retries 嚴重得多 |
| **SMART** | 硬碟自己記錄的健康資料（錯誤次數、溫度、壽命） |
| **vzdump** | PVE 的備份工具，排程在 Datacenter → Backup |
| **Prune／GC／Verify** | PBS 的三種維護工作：決定刪哪些舊備份／真正釋放空間／檢查備份是否完好 |

## 2. 告警的意思

```text
HEALTH_WARN: 1 OSD(s) experiencing slow operations in BlueStore
[WRN] BLUESTORE_SLOW_OP_ALERT: osd.0 observed slow operation indications in BlueStore
```

- osd.0 在 node10。這是**警告**不是錯誤，資料都在、服務照常。
- 這類告警會在慢操作發生後**保留一段時間**才自動消失，所以看到告警，不代表「現在」還在變慢。

> ⚠️ 告警出現時**先不要**重啟 OSD，也**不要** `ceph osd out`。重啟不會讓它好，反而會觸發資料重新平衡、增加負載。

## 3. 步驟一：先排除硬碟與核心

**做什麼**：確認不是硬碟壞了。在任一台 node 與 node10 執行，**全部只讀取**：

```bash
ceph health detail
ceph osd perf
journalctl -u ceph-osd@0 --since "2 days ago" --no-pager | grep -iE "slow|aio_submit|log_latency" | tail -15
dmesg -T | grep -iE "nvme|i/o error|reset|timeout" | tail -10
ceph osd metadata 0 | grep -E '"devices"|"bluestore_bdev_dev_node"|"rotational"'
smartctl -a /dev/<osd.0 的硬碟> | grep -iE "critical|media|error|percentage used|available spare|temperature|unsafe"
cat /proc/sys/fs/aio-nr /proc/sys/fs/aio-max-nr
```

| 指令 | 在查什麼 |
| --- | --- |
| `ceph osd perf` | 每顆 OSD 的回應時間 |
| `journalctl -u ceph-osd@0 …` | osd.0 日誌裡跟「慢」有關的訊息 |
| `dmesg -T …` | 核心有沒有看到硬碟錯誤、重置、逾時 |
| `ceph osd metadata 0` | osd.0 用的是哪顆實體硬碟 |
| `smartctl -a` | 那顆硬碟的健康資料 |
| `/proc/sys/fs/aio-*` | 核心非同步 I/O 的使用量和上限 |

**看到的結果**：

| 檢查 | 結果 | 判讀 |
| --- | --- | --- |
| `ceph osd perf` | osd.0 6 ms，osd.1／osd.2 1 ms | 略高但不算慢 |
| osd.0 日誌 | 10/12 21:03～21:14 有十幾筆 `aio_submit retries 2～7` | 讀寫佇列滿了，只好重試 |
| dmesg | 只有開機訊息，沒有 I/O error、reset、timeout | 核心沒看到硬碟錯誤 |
| SMART（osd.0 的 NVMe） | Critical Warning 0x00、Media Errors 0、Error Log 0、Spare 100%、已用 4%、40～48°C | 硬碟健康 |
| 核心 AIO | 使用 2,048／上限 1,048,576 | 不是核心上限不夠 |

SMART 另外顯示 **Unsafe Shutdowns 15 次**，這是過去不正常斷電的累計，不是這次的原因，之後觀察有沒有增加。

> **結論**：`aio_submit retries` 代表某段時間同時送出太多讀寫、排隊排滿，是**負載問題**，不是硬碟壞掉。

## 4. 步驟二：找出規律

**做什麼**：看 retries 發生在哪幾天、哪個時段、哪幾顆 OSD。

```bash
# 每天的次數
journalctl -u ceph-osd@0 --since "30 days ago" --no-pager | grep "aio_submit retries" | awk '{print $1, $2}' | sort | uniq -c
# 每小時的分布
journalctl -u ceph-osd@0 --since "30 days ago" --no-pager | grep "aio_submit retries" | awk '{print substr($3,1,2)":00"}' | sort | uniq -c
# 另外兩顆
ssh root@node11 'journalctl -u ceph-osd@1 --since "30 days ago" --no-pager | grep -c "aio_submit retries"'
ssh root@node12 'journalctl -u ceph-osd@2 --since "30 days ago" --no-pager | grep -c "aio_submit retries"'
cat /etc/pve/jobs.cfg
```

| 片段 | 意思 |
| --- | --- |
| `awk '{print $1, $2}'` | 只取日誌的月、日兩欄 |
| `substr($3,1,2)":00"` | 從時間欄取「小時」 |
| `sort \| uniq -c` | 排序後計算每個值出現幾次 |
| `grep -c` | 只算有幾行符合 |
| `/etc/pve/jobs.cfg` | 叢集的備份排程設定檔 |

**看到的結果**：

- 9/13～10/12 **每天都有**，每天 10～91 次；9/22（OSD 金鑰修復當天）最多。日誌只保留到 9/13，無法判斷是不是 Ceph 20.2.4 升級後才開始。
- osd.0 的 30 天加總中，**21:00 這一小時佔 624 次，約七成五**。
- 30 天合計：osd.0 約 836、osd.1 1,323、osd.2 2,010。**另外兩顆比 osd.0 更多**，所以不是 osd.0 或 node10 的問題，只是這次剛好由 osd.0 超過告警門檻。
- 備份排程當時只有一個：`all 1`、`schedule 21:00`、`mode snapshot`、`storage PBS31`、`prune-backups keep-daily=7,keep-last=3`。也就是**三台每晚 21:00 同時開始備份所有 VM／CT**。

10/12 的備份比平常久（node10 15 分、node11 16 分，平常 8～12 分）。推測是當天三台重開、多台 VM 重啟或搬移，QEMU 的 dirty bitmap（記錄「哪些區塊改過」的清單）被清掉，下一次備份只好整顆磁碟重讀。這點沒有逐筆查 vzdump log 確認。

## 5. 步驟三：三台備份錯開 30 分鐘

**怎麼做**：PVE Web UI **Datacenter → Backup**，原本的排程改成只跑 node10，再新增兩個，其他設定完全一樣：

| 排程 | Node | 時間 | Selection |
| --- | --- | --- | --- |
| 原排程 | node10 | 21:00 | All |
| 新增 | node11 | 21:30 | All |
| 新增 | node12 | 22:00 | All |

> **Selection mode 一定要選 All 再搭配 Node**：每個排程備份「當下在那台 node 上的所有 VM／CT」。HA 把 VM 搬走後，由新 node 的排程負責，三個加起來仍涵蓋全部。如果剛好在兩個排程之間搬移，那天可能多備一次或漏一次，隔天就恢復。

每台實際只要 5～16 分鐘，30 分鐘間隔足夠。

## 6. 步驟四：順便整理 PBS 排程

### 6-1 Prune Job 根本沒設定保留規則

PBS 的 Prune Job 每天都是 `WARNINGS: 1`，Keep 各欄全空，只跑 0.1 秒。log：

```text
No prune selection - keeping all files.
Pruning group :"ct/101"
remove ct/101/2026-10-03T13:00:02Z
remove ct/101/2026-10-04T13:00:04Z
...
TASK WARNINGS: 1
```

**看起來每一筆都標 `remove`，但其實什麼都沒刪**：沒有保留規則時，PBS 判定全部保留，log 只是印出計算時的標記。證據：

- datastore 目錄 `ct/101/` 還有 10/03～10/12 共 10 個快照目錄（加上 `owner` 檔）。
- 14 個群組各 10 筆，ProxCenter 和 `pvesm list PBS31` 都是 140 筆。
- 每組 10 筆剛好等於 PVE 端 `keep-last=3` 加 `keep-daily=7`。**真正在清舊備份的是 PVE 端**。

這個 Prune Job 沒有作用、每天產生警告；日後如果有人只填一部分規則，還可能真的開始刪、而且比 PVE 端更嚴格，所以**直接刪除**。

> GC Job **必須保留**，它負責真正釋放空間。

### 6-2 Verify 和 GC 錯開

原本 GC 和 Verify 都在 00:00 開始，兩者都大量讀同一個 datastore。把 Verify 改成 `02:00`（PBS 排程欄位可以直接輸入時間，下拉選單只是範例）。

## 7. 結果（10/13 晚上到 10/14 清晨）

| 項目 | 調整前 | 10/13 晚上 |
| --- | --- | --- |
| node10 備份 | 21:00 同時開始 | 21:00:06～21:07:43（7 分 37 秒） |
| node11 備份 | 21:00 同時開始 | 21:30:03～21:39:10（9 分 07 秒） |
| node12 備份 | 21:00 同時開始 | 22:00:03～22:04:32（4 分 29 秒） |
| PBS GC | 00:00 開始，1 小時 17 分 | 00:00 開始，**7 分 06 秒** |
| PBS Verify | 00:00 開始，1 小時 15 分 | 02:00 開始，59 分 22 秒 |
| Ceph | HEALTH_WARN | HEALTH_OK |

- 三台備份沒有重疊，全部 OK。
- **GC 從 77 分鐘降到 7 分鐘**，代表過去和 Verify 同時讀取時被拖慢了十倍以上，這是本次最明確的改善。
- GC 這次清掉的 66.11 GB 是上一次留下的待清除量；新的待清除 41.68 GB 會在下一次 GC 處理，屬正常機制。

### Ceph 的 retries 沒有變少

用同一時段（20:50～23:00）比較每晚的次數：

```bash
for d in 10 11 12 13; do
  echo -n "10/$d 晚上："
  for n in node10:0 node11:1 node12:2; do
    h=${n%:*}; o=${n#*:}
    echo -n " osd.$o=$(ssh root@$h "journalctl -u ceph-osd@$o --since '2026-10-$d 20:50' --until '2026-10-$d 23:00' --no-pager | grep -c 'aio_submit retries'")"
  done
  echo
done
```

**這段在做什麼**：外層跑 10～13 日，內層跑三台；`node10:0` 這種寫法用 `${n%:*}` 取出主機名、`${n#*:}` 取出 OSD 編號，再 SSH 過去數那晚的次數。

| 晚上 | osd.0 | osd.1 | osd.2 | 合計 |
| --- | --- | --- | --- | --- |
| 10/10 | 26 | 43 | 74 | 143 |
| 10/11 | 29 | 37 | 70 | 136 |
| 10/12 | 25 | 43 | 76 | 144 |
| **10/13（錯開後）** | 23 | 47 | 65 | 135 |
| 10/14 | 30 | 42 | 83 | 155 |

**10/15～10/20 趨勢追蹤**（錯開後連續觀察一週，10/21 判讀）：

| 晚上 | osd.0 | osd.1 | osd.2 | 合計 | 告警 |
| --- | --- | --- | --- | --- | --- |
| 10/15 | ⏳ | ⏳ | ⏳ | ⏳ | ⏳ |
| 10/16 | ⏳ | ⏳ | ⏳ | ⏳ | ⏳ |
| 10/17 | ⏳ | ⏳ | ⏳ | ⏳ | ⏳ |
| 10/18 | ⏳ | ⏳ | ⏳ | ⏳ | ⏳ |
| 10/19 | ⏳ | ⏳ | ⏳ | ⏳ | ⏳ |
| 10/20 | ⏳ | ⏳ | ⏳ | ⏳ | ⏳ |

在 node10 用上面同一段迴圈，只把日期換成 `15 16 17 18 19 20`；「告警」欄看當晚之後 `ceph health detail` 有沒有出現 `BLUESTORE_SLOW_OP_ALERT`。判讀方式：合計若穩定在 135～155 之間，代表是備份時段的正常負載；若持續上升或告警反覆出現，再評估第 8 節的限速做法。

- 10/14 晚上合計 155，比前幾晚多約一成，主要是 osd.2（83）。當天中午 osd.1 曾因[金鑰輪換](https://kbwangtw.github.io/IT-Knowledge-Base/docs/pve/ceph-bluestore-osd-key-recovery-2026-09-22/)停機約一分鐘，是否相關無法判斷；告警沒有出現，觀察到 10/21 再看趨勢。
- **推測原因**：RBD 磁碟的資料分散在三顆 OSD，就算同一時間只有一台在備份，讀取仍會同時打到三顆 OSD，單一台的備份就足以讓佇列短暫滿載。錯開排程降低的是「三台同時」的疊加，不是單一備份的瞬間讀取量。
- 10/12 晚上的 retries 和其他晚上差不多，告警卻只在那晚之後出現。`BLUESTORE_SLOW_OP_ALERT` 看的是慢操作，`aio_submit retries` 只是其中一種跡象，兩者不是一對一。告警消失可能是慢操作沒超過門檻，也可能只是過了保留時間，本次沒有逐筆分辨。

## 8. 結論與後續觀察

- 硬碟、核心 AIO 上限都正常；`aio_submit retries` 每晚發生在備份時段，三顆 OSD 都有，重試後完成，目前沒有資料錯誤。
- 錯開三台備份：沒有減少 retries，但避免三台同時讀取、備份時間沒有變長，**維持此設定**。
- PBS：刪除沒規則的 Prune Job；Verify 改到 02:00 後，GC 從 77 分鐘降到 7 分鐘。
- 觀察：`ceph health` 是否再出現 `BLUESTORE_SLOW_OP_ALERT`；osd.0 SMART 的 Unsafe Shutdowns 是否增加。
- 如果告警反覆出現，再評估降低單一備份的並行讀取（例如 vzdump 的頻寬限制，或 `performance` 的 max-workers），本次沒有調整。

**PBS 每天的忙碌時段**變成三段，重啟 `proxmox-backup-proxy`、升級 PBS 套件或重開 PBS 都要避開：

| 時段 | 工作 |
| --- | --- |
| 21:00～22:30 | 接收三台備份 |
| 00:00 起 | GC |
| 02:00～03:00 | Verify |

## 9. 每日快速健康檢查腳本

把觀察項目整理成一支**唯讀**腳本，放在 node10，想看時手動執行（10/15 起使用）。它會 SSH 到另外兩台查詢；SMART 只查 node10 本機的 osd.0。

| 段落 | 正常的樣子 | 基準 |
| --- | --- | --- |
| 1. Ceph | `HEALTH_OK`、3 up／3 in、97 active+clean | — |
| 2. retries | 三顆合計約 135～155 | 10/10～10/14 |
| 3. osd.0 SMART | Unsafe Shutdowns 15、Media Errors 0、Critical Warning 0x00 | 10/13 |
| 4. 備份 | 三台 OK，約 21:00／21:30／22:00 開始 | 錯開後的排程 |
| 5. HA、服務 | `HA 全部正常`，三台沒有 failed 服務 | — |

**安裝**（在 node10，整段貼上）：

```bash
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
```

| 片段 | 意思 |
| --- | --- |
| `cat > 檔案 <<'EOF' … EOF` | 把中間的內容寫進檔案；`'EOF'` 加引號代表內容原樣寫入，不先展開變數 |
| `D=${1:-…}` | 有給日期參數就用它，沒給就用「昨天」 |
| `chmod 755` | 讓腳本可以執行 |

**注意**：

- 第 4 段抓的是 `pvenode task list` 表格的第 6、8 欄（開始時間、狀態）。PVE 改版若表格欄位變動，這段可能錯位，改看原始輸出即可。
- 腳本只讀取，不改任何設定，也沒有排程和通知。retries 的正常範圍確定後，再考慮改成「只有異常才通知」。
- 腳本放在 node10 本機，重灌或換機時要重新建立。

## 10. slow ops 歷史（2026-10-16 回查）

**做什麼**：判斷慢操作是長期現象還是偶發，回查三台 journal 裡 OSD 回報 `slow ops`（單一操作超過 30 秒）的日子。

```bash
# node10 本機
journalctl -u ceph-osd@0 --no-pager | grep 'slow ops' | awk '{print $1, $2}' | uniq -c | tail -20
# 另外兩台
for n in node11:1 node12:2; do
  h=${n%:*}; o=${n#*:}
  echo "== osd.$o ($h) =="
  ssh root@$h "journalctl -u ceph-osd@$o --no-pager | grep 'slow ops' | awk '{print \$1, \$2}' | uniq -c | tail -20"
done
```

| 日期 | osd.0（node10） | osd.1（node11） | osd.2（node12） | 判讀 |
| --- | --- | --- | --- | --- |
| 2～3 月、5/29、6/17、8 月 | 無紀錄* | 零星（22～35） | 零星（1～81） | 偶發 |
| **5/4～5/5** | 無紀錄* | 31,971＋336 | 30,802＋373 | 整個 cluster 的事件 |
| **7/21** | **65,215** | 0 | 0 | 只有 osd.0，規模最大 |
| **9/24** | 207 | 31 | 41 | 三顆都有，osd.0 最多 |
| 10 月至 10/16 | 0 | 0 | 0 | 無 |

\* node10 的 journal（4 GB，systemd 預設上限）最早只到 7/21，更早的紀錄已被輪替；node11、node12 保留到 2～3 月。

- 10 月的 `BLUESTORE_SLOW_OP_ALERT` 和每晚的 retries 都**沒有**伴隨 `slow ops`，代表重試後在 30 秒內完成，比 5/4、7/21 輕微得多。
- 7/21 只有 osd.0 回報，其他 OSD 沒有因等它而回報，可能是 node10 當時與其他節點斷線，或 osd.0 很快被標為 down（推測，未確認）。該日第一筆紀錄的 ceph-osd 程序編號很小，像剛開機不久；是否和 Unsafe Shutdowns（15 次）有關無法確認。
- 9/24 接近 [9/20～9/22 重開與 OSD 金鑰修復](https://kbwangtw.github.io/IT-Knowledge-Base/docs/pve/ceph-bluestore-osd-key-recovery-2026-09-22/)，是否相關未確認。
- 5/4、7/21、9/24 當天的事件（停電、網路、維護）目前沒有紀錄可對照。**日後若有停電或重開，記下日期**，方便和 log 比對。
- 要追 7/21，可在 node10 查 `journalctl --list-boots --no-pager | head` 和 `last -x reboot shutdown | head -20`，看當時有沒有重開或異常關機。

## 11. 常見問題

| 現象 | 怎麼辦 |
| --- | --- |
| 看到 `BLUESTORE_SLOW_OP_ALERT` | 先別重啟 OSD 或 `osd out`；照第 3 節查硬碟和核心 |
| 日誌有 `aio_submit retries` | 負載太高、排隊排滿；看它集中在哪個時段 |
| 只有一顆 OSD 告警 | 三顆都查一次 retries，可能只是剛好那顆超過門檻 |
| PBS Prune 每天 `WARNINGS: 1`、log 寫 `remove` | 沒設保留規則時什麼都不會刪；確認清理由 PVE 端負責 |
| GC 跑很久 | 檢查是否和 Verify 同時跑，錯開時間 |
| 多個備份排程怎麼選 VM | Selection 選 All 再指定 Node，HA 搬移後仍涵蓋全部 |

## 12. 延伸閱讀

- [PVE 重開後 Ceph 又故障：修正 BlueStore 裡的 OSD 金鑰](https://kbwangtw.github.io/IT-Knowledge-Base/docs/pve/ceph-bluestore-osd-key-recovery-2026-09-22/)（9/20 `aio_submit retries` 原列為觀察項目）
- [PBS 更新後，怎麼確認備份還能用？](https://kbwangtw.github.io/IT-Knowledge-Base/docs/pve/ProxCenter-PBS-Update-and-DR-Validation-SOP/)
- [Proxmox VE Backup and Restore](https://pve.proxmox.com/pve-docs/chapter-vzdump.html)
- [Proxmox Backup Server：Maintenance Tasks](https://pbs.proxmox.com/docs/maintenance.html)
