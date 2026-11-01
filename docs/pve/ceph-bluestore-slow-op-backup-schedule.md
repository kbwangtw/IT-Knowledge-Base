---
layout: default
title: "Ceph 出現 BlueStore 慢操作告警：硬碟壞了嗎？備份排程怎麼排？"
permalink: /docs/pve/ceph-bluestore-slow-op-backup-schedule/
date: 2026-10-14
categories: [PVE, Ceph, PBS, Backup, Troubleshooting]
last_modified_at: 2026-10-31
---

# Ceph 出現 BlueStore 慢操作告警：硬碟壞了嗎？備份排程怎麼排？

> **一句話**：Ceph 跳出「慢操作」警告，查下來**硬碟沒壞**，而是每晚 21:00 三台同時備份、讀寫排隊排滿；把備份錯開 30 分鐘、整理 PBS 排程後，PBS 的 GC 從 77 分鐘降到 7 分鐘，告警消失，但 Ceph 的重試次數幾乎沒變。

| 項目 | 內容 |
| --- | --- |
| 適合誰看 | 看到 `BLUESTORE_SLOW_OP_ALERT`、想知道要不要換硬碟的人；要排 PVE／PBS 備份時間的人 |
| 環境 | 三台 Win element M600（Ryzen 9 8945HS、64 GB，硬體見 8-1）；PVE 9.2.21、kernel 7.0.14-23-pve、Ceph 20.2.4-pve5；PBS31 為 PBS 4.2.8，datastore Tokyo16 在 CIFS 掛載上 |
| 日期 | 2026-10-13～14；10/16 補 slow ops 歷史；10/31 復發（第 11 節） |
| 結論 | ✅ 硬碟與核心正常；✅ 三台備份錯開；✅ PBS GC 77 → 7 分鐘；✅ 告警消失；✅ 10/21 一週追蹤：retries 沒有上升（142 → 117），期間沒有再出現告警；⚠️ 10/31 復發，這次是 osd.1：retries 41（一週平均約 39）、無 `slow ops`、SMART 無故障徵兆，判斷同為備份時段排隊（第 11 節）；✅ 11/01 第二輪：三顆 OSD 碟 Media Errors 皆 0、核心沒有 NVMe 重置或逾時，osd.0 碟 Unsafe Shutdowns 仍是 15（10/31 曾誤把 node10 的另一顆碟當成 osd.0，已更正）；⏳ 觀察：osd.1 碟 54°C、壽命已用 19%；⏳ 告警 11/01 上午仍在（`lifetime` 86400、`threshold` 1，推算最快 11/01 21:38 後消失，第 11-6 節） |

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
| 10/15 | 22 | 43 | 77 | 142 | 無 |
| 10/16 | 22 | 45 | 70 | 137 | 無 |
| 10/17 | 28 | 35 | 73 | 136 | 無 |
| 10/18 | 22 | 38 | 69 | 129 | 無 |
| 10/19 | 22 | 32 | 68 | 122 | 無 |
| 10/20 | 22 | 35 | 60 | 117 | 無 |

在 node10 用上面同一段迴圈，只把日期換成 `15 16 17 18 19 20`；「告警」欄看當晚之後 `ceph health detail` 有沒有出現 `BLUESTORE_SLOW_OP_ALERT`。判讀方式：合計若穩定在 135～155 之間，代表是備份時段的正常負載；若持續上升或告警反覆出現，再評估第 8 節的限速做法。

**10/18 初步判讀**：四晚合計 129～142，和錯開前（135～155）同一水準、沒有上升趨勢；分布仍是 osd.2 最多、osd.0 最少，和 30 天統計一致。查詢時 `ceph health detail` 為 `HEALTH_OK`。10/19、10/20 兩晚在查詢當下還沒到（輸出為 0，不是實際數字），補齊後再結案。「告警」欄的「無」是依查詢時 HEALTH_OK 推定，沒有逐晚查歷史告警。

**10/21 結案判讀**：

- 六晚合計 142、137、136、129、122、117，**沒有上升，反而略降**，都在錯開前（135～155）的範圍或以下；分布仍是 osd.2 最多、osd.0 最少。下降的原因未確認（可能和每晚備份的資料量有關），只記錄趨勢。
- 「告警」欄改用 Graylog 回查確認：搜尋 `message:"BLUESTORE_SLOW_OP_ALERT"`（10/13 00:00～10/21 08:53）只有 3 筆，都是 **10/14 06:15:20** 的 `Health check cleared: BLUESTORE_SLOW_OP_ALERT`（同一則叢集訊息由三台 mon 各記一次），也就是 10/12 那次告警的解除；之後**沒有任何新的告警**。
- 查詢時 `ceph health detail` 為 `HEALTH_OK`。
- 結論：錯開排程後備份時段負載穩定，**不需要**第 8 節的限速；維持現狀，日常用第 9 節的腳本觀察。

- 10/14 晚上合計 155，比前幾晚多約一成，主要是 osd.2（83）。當天中午 osd.1 曾因[金鑰輪換](https://kbwangtw.github.io/IT-Knowledge-Base/docs/pve/ceph-bluestore-osd-key-recovery-2026-09-22/)停機約一分鐘，是否相關無法判斷；告警沒有出現，觀察到 10/21 再看趨勢。
- **推測原因**：RBD 磁碟的資料分散在三顆 OSD，就算同一時間只有一台在備份，讀取仍會同時打到三顆 OSD，單一台的備份就足以讓佇列短暫滿載。錯開排程降低的是「三台同時」的疊加，不是單一備份的瞬間讀取量。
- 10/12 晚上的 retries 和其他晚上差不多，告警卻只在那晚之後出現。`BLUESTORE_SLOW_OP_ALERT` 看的是慢操作，`aio_submit retries` 只是其中一種跡象，兩者不是一對一。告警消失可能是慢操作沒超過門檻，也可能只是過了保留時間，本次沒有逐筆分辨。

## 8. 結論與後續觀察

- 硬碟、核心 AIO 上限都正常；`aio_submit retries` 每晚發生在備份時段，三顆 OSD 都有，重試後完成，目前沒有資料錯誤。
- 錯開三台備份：沒有減少 retries，但避免三台同時讀取、備份時間沒有變長，**維持此設定**。
- PBS：刪除沒規則的 Prune Job；Verify 改到 02:00 後，GC 從 77 分鐘降到 7 分鐘。
- 觀察：`ceph health` 是否再出現 `BLUESTORE_SLOW_OP_ALERT`；osd.0 SMART 的 Unsafe Shutdowns 是否增加。**10/31 告警復發（osd.1）**；osd.0 碟的 Unsafe Shutdowns 11/01 重查仍是 15，沒有增加，見第 11 節。
- 如果告警反覆出現，再評估降低單一備份的並行讀取（例如 vzdump 的頻寬限制，或 `performance` 的 max-workers），本次沒有調整。

### 8-1 三台硬體與 OSD 碟款（2026-10-21）

用 `dmidecode` 讀硬體資訊（在 node10 執行，唯讀；刻意不查序號）：

```bash
for h in node10 node11 node12; do
  echo "===== $h ====="
  ssh -o BatchMode=yes root@$h '
    echo "系統廠牌：$(dmidecode -s system-manufacturer)"
    echo "系統型號：$(dmidecode -s system-product-name)"
    echo "主機板：  $(dmidecode -s baseboard-manufacturer) $(dmidecode -s baseboard-product-name)"
    echo "BIOS：    $(dmidecode -s bios-version)（$(dmidecode -s bios-release-date)）"
    echo "CPU：     $(dmidecode -s processor-version | head -1)"
    echo "記憶體：  $(free -g | awk "/Mem:/{print \$2}") GB"
    for d in /sys/class/nvme/nvme*; do echo "NVMe：    $(cat $d/model | xargs)（$(cat $d/address)）"; done
  '
done
```

| 項目 | node10 | node11 | node12 |
| --- | --- | --- | --- |
| 機型 | Win element M600 | Win element M600 | Win element M600 |
| CPU | AMD Ryzen 9 8945HS（Radeon 780M） | 同左 | 同左 |
| 記憶體 | 64 GB（`free` 顯示 62 GB，部分保留給內顯與系統） | 同左 | 同左 |
| BIOS | SR500_P5C2V08（2024/07/29） | SR500_P5C2V08（2024/07/29） | SR500_P5C2V**09**（2024/11/21） |
| 系統碟 512 GB（`06:00`） | SAMSUNG MZVL4512HBLU | KINGSTON OM8SEP4512Q | KINGSTON SA2000M8500G |
| 資料碟 2 TB（`01:00`，Ceph OSD） | BIWIN NV7200（osd.0） | Lexar THOR PRO（osd.1） | KINGSTON SNV3S（osd.2） |

**和 retries 分布對照（推測）**：一週平均每晚 osd.0 約 23（最少）、osd.1 約 39、osd.2 約 70（最多）。osd.2 的 KINGSTON NV3 系列是入門款，推測大量讀寫時較慢，所以排隊重試最多；沒有實測三顆碟的效能，資料分布與 PG 主副本位置也會影響，未確認。三個廠牌的好處是不容易同時故障，代價是 Ceph 會被最慢的那顆拖住。目前 retries 穩定、沒有告警，不需要處理；日後要換碟可優先考慮 osd.2。

- node12 的 BIOS 比另兩台新一版；沒有造成問題，不為了一致而更新（有變磚風險、要停機），等真的需要時三台一起評估。

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

## 11. 10/31 復發：這次警告的是 osd.1

### 11-1 發生什麼事

| 項目 | 內容 |
| --- | --- |
| 時間 | 2026-10-31 21:38:44（Graylog 21:42 寄出「Ceph 健康警告」） |
| 告警 | `BLUESTORE_SLOW_OP_ALERT`，警告的是 **osd.1（node11）**；10/14 是 osd.0 |
| 狀態 | 22:35 查仍在；97 個 PG 全部 `active+clean`、OSD 3 up / 3 in，沒有資料風險 |
| 備份排程 | `/etc/pve/jobs.cfg` 三個工作都備份到 PBS31（全部 guest、snapshot）：node10 21:00、node11 21:30、node12 22:00，`keep-daily=7,keep-last=3`；和第 5 節相同 |

告警發生在 node11 備份開始後 8 分鐘。但 Ceph 讀取的是各 PG 的**主 OSD**，不一定是 node11 本機的 osd.1，所以這**只是時間吻合，不是因果**。

官方文件（[Ceph Health Checks](https://docs.ceph.com/en/latest/rados/operations/health-checks/)）：在 `bluestore_slow_ops_warn_lifetime` 秒內，單一 BlueStore OSD 的慢操作次數達到 `bluestore_slow_ops_warn_threshold` 才會告警；文件說單次慢操作可能是誤報；條件消失後告警自動清除。這兩個選項的預設值文件沒有寫，本篇不憑記憶引用。

### 11-2 做什麼、怎麼做

**做什麼**：確認告警的是哪一顆 OSD、它所在的硬碟有沒有故障徵兆、是不是備份時段排隊。**全部是唯讀指令**，由 Lab Ops 透過 `rx` 逐條執行。

```bash
ceph health detail
ceph -s
ceph osd perf
cat /etc/pve/jobs.cfg
ceph osd metadata 1 | grep -E '"(hostname|devices|bluestore_bdev_devices|bluestore_bdev_dev_node)"'
journalctl -u ceph-osd@1 --since "today" --no-pager | grep -E "slow operation|log_latency" | tail -20
journalctl -u ceph-osd@1 --since "20:30" --until "23:00" --no-pager | grep -c "aio_submit retries"
journalctl -u ceph-osd@1 --since "today" --no-pager | grep -c "slow ops"
smartctl -a /dev/nvme0n1 | grep -E "Model Number|Critical Warning|Percentage Used|Media and Data Integrity|Unsafe Shutdowns|Temperature:"
```

| 片段 | 意思 |
| --- | --- |
| `ceph health detail` | 告警明細，會寫出是哪一顆 OSD |
| `ceph osd perf` | 各 OSD 此刻的延遲（只是快照） |
| `ceph osd metadata 1 \| grep …` | osd.1 在哪台主機、用哪顆 NVMe；**裝置編號每台不同，不能沿用 osd.0 的 `nvme1n1`** |
| `grep -E "slow operation\|log_latency"` | 官方文件說要找的 BlueStore 慢操作日誌 |
| `grep -c "aio_submit retries"` | 備份時段的 aio 重試次數 |
| `grep -c "slow ops"` | 單一操作超過 30 秒的次數 |
| `smartctl -a /dev/nvme0n1 \| grep …` | 硬碟健康；裝置名稱取自上面 `metadata` 的結果 |

> `grep -c` 沒有符合的行時，回傳碼是 1 但輸出是 `0`，那是**結果**不是失敗；請 Lab Ops 照實回報，不要因此停下來。

### 11-3 看到的結果

| 檢查 | osd.1（node11，Lexar THOR PRO 2TB，`nvme0n1`） | osd.0（node10，對照） |
| --- | --- | --- |
| `aio_submit retries`（20:30～23:00） | **41** | 18 |
| 一週平均每晚（8-1） | 約 39 | 約 23 |
| `slow ops`（> 30 秒） | **0** | 0 |
| `slow operation`／`log_latency` 日誌 | 無輸出 | 無輸出 |
| `ceph osd perf`（此刻） | 0／0 ms | 7／7 ms（osd.2：1／1 ms） |
| Critical Warning | `0x00` | 11/01 第二輪表格未列，未重查 |
| Media and Data Integrity Errors | 0 | 0 |
| 溫度 | 54°C（10/31 22:35 與 11/01 09:58 相同） | 40°C（11/01 09:58） |
| Percentage Used | 19% | 5% |
| Unsafe Shutdowns | 24 | 15 |

> osd.0 欄的 SMART 數字已在 11/01 更正，原因見 11-5 最後的「更正」。

**判讀**：osd.1 的 retries 41 接近一週平均 39、沒有 `slow ops`、SMART 沒有故障徵兆，**和 10/14 同類：備份時段排隊，這次剛好由 osd.1 超過門檻**。因此不調整備份排程、不調整告警門檻（調高門檻會降低靈敏度，可能蓋掉真正的硬碟前兆）。

`slow operation`／`log_latency` 查不到字串，與 10/14 查 osd.0 的結果一致（第 3 節）；這類訊息是否寫在 `/var/log/ceph/` 底下的日誌檔，**未驗證**。

### 11-4 11/01 第二輪：三顆 OSD 碟、開機次數、核心訊息（閒置時段，唯讀）

**做什麼**：補三顆碟的寫入量、耗損、溫度，核對開機次數，並確認核心有沒有看到 NVMe 重置或逾時。全部是唯讀指令，由 Lab Ops 透過 `rx` 執行（2026-11-01 09:58）。

```bash
ceph osd metadata 0 | grep -E '"(hostname|bluestore_bdev_devices)"'      # osd.1、osd.2 各查一次
smartctl -a /dev/<上一步查到的裝置> | grep -E "Model Number|Power On Hours|Data Units Written|Percentage Used|Unsafe Shutdowns|Media and Data Integrity|Critical Warning|Comp. Temperature Time|Thermal Temp|Temperature:"
journalctl --list-boots --no-pager | tail -15                                                    # node11、node12
dmesg -T | grep -iE "nvme.*(reset|timeout|error)|i/o error" | tail -10                           # 三台
```

| 片段 | 意思 |
| --- | --- |
| `ceph osd metadata <編號> \| grep …` | 先查這顆 OSD 實際用哪個 NVMe；**不能沿用別台的裝置名稱** |
| `smartctl -a /dev/<裝置>` | 該硬碟的 SMART；`Data Units Written` 是累計寫入量，`Power On Hours` 是通電時數 |
| `journalctl --list-boots` | 列出每次開機的起訖時間，用來數重開次數 |
| `dmesg -T \| grep …` | 核心訊息裡有沒有 NVMe 重置、逾時、I/O 錯誤（只涵蓋本次開機，即 10/29 之後） |

**看到的結果**（11/01 09:58）：

| 節點 | OSD | 裝置 | 型號 | Power On Hours | Data Units Written | Percentage Used | Unsafe Shutdowns | Media Errors | 溫度 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| node10 | osd.0 | `nvme0n1` | BIWIN NV7200 2TB | 8,623 | 21.9 TB | 5% | 15 | 0 | 40°C |
| node11 | osd.1 | `nvme0n1` | Lexar THOR PRO 2TB | 10,580 | 21.5 TB | 19% | 24 | 0 | 54°C |
| node12 | osd.2 | **`nvme1n1`** | KINGSTON SNV3S2000G | 1,177 | 18.6 TB | 4% | 12 | 0 | 49°C |

- node12 的 OSD 碟是 `nvme1n1`，node10、node11 是 `nvme0n1`；裝置編號每台不同。
- 三台 `dmesg` 都**沒有**符合的輸出：本次開機（10/29 起）核心沒有看到 NVMe 重置、逾時或 I/O 錯誤。
- Critical Warning、`Comp. Temperature Time`、`Thermal Temp` 這次整理的表格沒有列出，**未重查**（也未確認這幾顆 smartctl 有沒有這幾行）。

### 11-5 判讀

**① Unsafe Shutdowns：osd.0 的碟沒有增加**

| 項目 | 內容 |
| --- | --- |
| osd.0 碟（`nvme0n1`）10/13 | 15（第 3 節） |
| osd.0 碟 11/01 | **15，沒有增加** |
| 這段期間 node10 的開機紀錄 | 4 次開機結束：10/23 09:49、10/23 11:04（14:30 才開機，全機關機）、10/24 12:20、10/29 13:30 |
| node11、node12 的開機紀錄（`list-boots`，依指令順序與 10/29 滾動更新順序推測前者是 node11） | 各 3 次：10/23 09:49、10/24 12:xx、10/29 09:xx |

10/13 之後重開與全機關機共 4 次，這顆碟的計數仍是 15，所以**這段期間的重開沒有被計入**；包含 10/23 那次，為什麼沒有計入我不確定（未確認）。node11、node12 的碟沒有 10/13 的基準，只能先記下 24 與 12，之後再比較。

**② osd.1 的碟：耗損比例高、溫度偏高，但沒有故障徵兆**

- 三顆碟的累計寫入量相近（21.9／21.5／18.6 TB），但 Percentage Used 是 5%／**19%**／4%；osd.1 的耗損比例約為另外兩顆的 4 倍。**推測**是 Lexar 這顆的廠商耐久估計值較低，或計算方式不同；規格**沒有查**，未確認。
- osd.1 的 54°C 在 10/31 22:35 與 11/01 09:58 兩個時間點都一樣，**不是備份尖峰造成的**；osd.0 是 40°C、osd.2 是 49°C，差異可能和機身內位置有關（推測，未確認）。這顆碟的溫度規格也沒有查，不判斷是否降速。
- osd.2 的碟 Power On Hours 只有 1,177（約 49 天），累計寫入卻已 18.6 TB，和用了一年以上的另兩顆差不多。原因不確定（KB 沒有換碟紀錄可對照）。
- 三顆碟 Media Errors 都是 0、核心沒有 NVMe 錯誤，**沒有看到硬碟故障的證據**。

> ⚠️ **更正（11/01）**：10/31 這節原本的 osd.0 SMART 數字（35°C、已用 7%、Unsafe Shutdowns 35）讀的是 `/dev/nvme1n1`，但 node10 的 osd.0 在 **`nvme0n1`**（BIWIN）。`nvme1n1` 依第 8-1 節的硬體表**推測**是 node10 的 512 GB 系統碟（Samsung，未用 `smartctl -i` 當場確認型號）。裝置路徑沒有先用 `ceph osd metadata` 確認就沿用，是 10/31 的錯誤；因此當時寫的「osd.0 碟 Unsafe Shutdowns 15 → 35」**不成立**，上方 11-3 與本節已改成 11/01 用 metadata 查到的裝置重查的結果。

### 11-6 告警為什麼還在：`lifetime` 86400、`threshold` 1（2026-11-01 上午）

**做什麼**：10/31 21:38 的告警隔天上午還在，要確認是不是仍是 osd.1，以及告警會保留多久。**全部是唯讀指令**。

```bash
ceph health detail
ceph config get osd.1 bluestore_slow_ops_warn_lifetime
ceph config get osd.1 bluestore_slow_ops_warn_threshold
```

| 片段 | 意思 |
| --- | --- |
| `ceph health detail` | 告警明細，會寫出是哪一顆 OSD；單用 `ceph health` 看不出來 |
| `ceph config get osd.1 bluestore_slow_ops_warn_lifetime` | 慢操作的計算時間窗（秒） |
| `ceph config get osd.1 bluestore_slow_ops_warn_threshold` | 時間窗內累計幾次才告警 |

**看到的結果**（11/01 上午）：

| 項目 | 結果 |
| --- | --- |
| 告警 | `HEALTH_WARN`，`BLUESTORE_SLOW_OP_ALERT`，仍是 **osd.1** |
| `bluestore_slow_ops_warn_lifetime` | **86400** 秒（24 小時） |
| `bluestore_slow_ops_warn_threshold` | **1** |

**判讀**：

- 門檻是 1、時間窗是 24 小時，也就是**過去 24 小時內只要出現過一次慢操作，就會一直顯示 `HEALTH_WARN`**。所以告警還在，不代表現在還在變慢。
- 官方文件寫告警在條件消失後自動清除。最後一次慢操作不晚於 10/31 21:38（Graylog 收到告警的時間，OSD 實際發生的時間可能更早，不知道）；若 24 小時內沒有新的，**最快約 11/01 21:38 消失**。今晚 node11 的備份從 21:30 開始，若又產生一次慢操作，時間窗重新計 24 小時。
- 這與第 7 節 10/14 的經過相容（10/12 晚上有重試紀錄，10/14 清晨已是 `HEALTH_OK`），但**是推測，不是驗證**。
- **未確認**：86400 與 1 是否為預設值（印象中是，但沒有查證）；官方文件範例用 300 秒與 5 次，那只是範例，不是預設。可用 `ceph config dump | grep slow_ops`（沒有輸出代表沒有透過 Ceph 設定資料庫改過）與 `grep slow_ops /etc/pve/ceph.conf` 確認，**尚未執行**。
- 門檻 1 很敏感，備份每晚都會讓 OSD 排隊，所以告警容易重複出現；它實際上是「過去 24 小時內有過慢操作」，不是「硬碟有問題」。

| 選項 | 內容 | 評估 |
| --- | --- | --- |
| A. 維持現狀、繼續觀察 | 11/02 上午再看 | **目前採用**；Media Errors 為 0、核心沒有 NVMe 錯誤 |
| B. 降低備份造成的讀取壓力 | vzdump 頻寬限制或 `max-workers` | 等「反覆出現」再做 |
| C. 調高 `bluestore_slow_ops_warn_threshold` | 官方文件說單次慢操作可能是誤報，用時間窗內累計次數過濾 | 會降低靈敏度，可能蓋掉真正的硬碟前兆；確認反覆復發且硬碟沒問題後再考慮 |

### 11-7 待辦

- [ ] 確認告警何時自動消失：11/01 上午仍在（osd.1）；預期最快 11/01 21:38 之後，今晚 node11 備份（21:30 起）可能重新計時；11/02 上午再看 `ceph health detail`
- [ ] 確認 `lifetime`、`threshold` 是否為預設（`ceph config dump | grep slow_ops`、`grep slow_ops /etc/pve/ceph.conf`）
- [x] 閒置時段第二輪唯讀檢查（2026-11-01 完成，見 11-4）
- [ ] 補查三顆碟的 Critical Warning、`Comp. Temperature Time`（Warning／Critical）、`Thermal Temp`
- [ ] 11/30 前後重查三顆碟的 Percentage Used、Unsafe Shutdowns、溫度（以 11/01 的數字為基準）
- [ ] 查 Lexar THOR PRO 2TB 的耐久（TBW）與溫度規格（目前沒有查）
- [ ] 確認 `slow operation`／`log_latency` 字串是否寫在 `/var/log/ceph/ceph-osd.N.log`（未驗證）
- [ ] 若三顆 OSD 反覆輪流告警，才依第 8 節評估降低單一備份的並行讀取（vzdump 頻寬限制或 `max-workers`）

## 12. 常見問題

| 現象 | 怎麼辦 |
| --- | --- |
| 看到 `BLUESTORE_SLOW_OP_ALERT` | 先別重啟 OSD 或 `osd out`；照第 3 節查硬碟和核心 |
| 日誌有 `aio_submit retries` | 負載太高、排隊排滿；看它集中在哪個時段 |
| 只有一顆 OSD 告警 | 三顆都查一次 retries，可能只是剛好那顆超過門檻 |
| PBS Prune 每天 `WARNINGS: 1`、log 寫 `remove` | 沒設保留規則時什麼都不會刪；確認清理由 PVE 端負責 |
| GC 跑很久 | 檢查是否和 Verify 同時跑，錯開時間 |
| 多個備份排程怎麼選 VM | Selection 選 All 再指定 Node，HA 搬移後仍涵蓋全部 |
| 這次告警的 OSD 和上次不同 | 正常，三顆都有 retries，哪一顆先超過門檻就告警哪一顆；先用 `ceph health detail` 確認，不要假設還是 osd.0 |
| 查 osd.1 的 SMART 找不到 `nvme1n1` | 裝置編號每台不同；先用 `ceph osd metadata <OSD 編號>` 查 `bluestore_bdev_devices` |
| 告警還在，但現在不慢 | 門檻 1、時間窗 24 小時：過去 24 小時內有過任何一次慢操作就會顯示；用 `ceph health detail` 確認是哪一顆，等最後一次慢操作之後滿 24 小時，期間不要重啟 OSD（第 11-6 節） |
| Lab Ops 在 `grep -c` 輸出 0 時停下來 | 沒有符合行時回傳碼是 1，輸出的 0 就是結果，告訴它繼續 |

## 13. 延伸閱讀

- [PVE 重開後 Ceph 又故障：修正 BlueStore 裡的 OSD 金鑰](https://kbwangtw.github.io/IT-Knowledge-Base/docs/pve/ceph-bluestore-osd-key-recovery-2026-09-22/)（9/20 `aio_submit retries` 原列為觀察項目）
- [PBS 更新後，怎麼確認備份還能用？](https://kbwangtw.github.io/IT-Knowledge-Base/docs/pve/ProxCenter-PBS-Update-and-DR-Validation-SOP/)
- [Proxmox VE Backup and Restore](https://pve.proxmox.com/pve-docs/chapter-vzdump.html)
- [Proxmox Backup Server：Maintenance Tasks](https://pbs.proxmox.com/docs/maintenance.html)
- [Ceph Health Checks（BLUESTORE_SLOW_OP_ALERT）](https://docs.ceph.com/en/latest/rados/operations/health-checks/)
