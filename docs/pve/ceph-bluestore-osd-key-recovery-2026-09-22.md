---
layout: default
title: "PVE 重開後 Ceph 又故障：修正 BlueStore 裡的 OSD 金鑰"
date: 2026-09-22
last_modified_at: 2026-11-01
categories: [PVE, Ceph, Troubleshooting]
permalink: /docs/pve/ceph-bluestore-osd-key-recovery-2026-09-22/
---

# PVE 重開後 Ceph 又故障：修正 BlueStore 裡的 OSD 金鑰

> **一句話**：9/18 修好的只是 OSD「執行時」用的金鑰副本，硬碟上 BlueStore 標籤裡存的還是錯的，所以一重開又壞；9/22 逐顆把標籤改回正確金鑰，三處（MON、本機、BlueStore）一致後，重開也不會再出事。

| 項目 | 內容 |
| --- | --- |
| 適合誰看 | Ceph OSD 每次重開就認證失敗的人；要輪換 OSD 金鑰的人 |
| 環境 | PVE 9.2.x 三節點（node10／11／12 對應 osd.0／1／2）；Ceph 20.2.4-pve4 |
| 日期 | 2026-09-21～22（UTC+8）；10/12、10/14、11/01 補記 |
| 結論 | ✅ 三顆 MON = LOCAL = BLUESTORE、HEALTH_OK；✅ 10/12 修復後第一次整機重開正常；✅ 10/14 已曝光的 osd.1 金鑰完成輪換；✅ 11/01 輪換後經兩次整叢集重開，osd.1 三處仍一致（9-5） |

> 不公開 CephX secret、完整 label 或原始截圖。操作範例依當時成功流程整理，並加入「失敗就停止」的檢查；不是文件發布時重新操作正式叢集的紀錄。

## 1. 先認識幾個名詞

| 名詞 | 白話解釋 |
| --- | --- |
| **CephX key** | OSD 登入 Ceph 的金鑰 |
| **三個存放處** | **MON**（叢集管理處的正本）、**LOCAL**（本機 `/var/lib/ceph/osd/ceph-N/keyring`）、**BLUESTORE**（硬碟上 label 裡的 `osd_key`） |
| **BlueStore label** | 寫在 OSD 硬碟開頭的標籤，記錄 OSD 編號、金鑰等 |
| **tmpfs** | 存在記憶體裡的資料夾，重開就清空；`/var/lib/ceph/osd/ceph-N` 就是 tmpfs |
| **ceph-volume activate** | 開機時依 BlueStore label **重建**本機 keyring 的流程 |
| **noout** | 告訴 Ceph「OSD 暫時 down 不要搬資料」，維護時用 |
| **SHA-256 hash** | 把金鑰算成一串摘要；比對摘要就知道是否相同，又不會露出金鑰 |

### 為什麼重開才會壞？

```text
開機
  → /var/lib/ceph/osd/ceph-N 是空的（tmpfs）
  → ceph-volume 讀 BlueStore label 裡的 osd_key，重建本機 keyring
  → 如果 label 裡存的是錯的，本機 keyring 也是錯的
  → OSD 登入 MON 失敗
```

所以 9/18 只修本機 keyring，服務可以恢復；但只要一重開，又會從錯的 label 重建出錯的 keyring。

## 2. 一開始的症狀

| 項目 | 本案環境 |
| --- | --- |
| 服務 | 3 MON、MGR 1 active／2 standby、MDS 1 active／2 standby |
| 儲存 | 3 OSD、4 pools、97 PG、1 個 CephFS |

9/21 重開／OSD 啟用後：

- osd.1、osd.2 無法正常啟動或加入叢集。
- CephFS／PVE storage 查詢 timeout，PVE Web 介面的儲存狀態受影響。
- osd.2 把**路徑**當成 CephX key 解析，出現 `Malformed input`；osd.1 認證失敗。

> MON quorum 正常、管理指令能查，不代表 OSD、CephFS 和 PVE storage 都正常。`systemctl is-active` 顯示 active 也只代表程式在跑，還要確認 OSD 已向叢集報到。

## 3. 時間線：9/13 到 9/22

| 日期 | 事件 | 判讀 |
| --- | --- | --- |
| 9/13 | Ceph 20.2.2-pve1 → 20.2.4-pve4 | Ceph 套件在這天升級，和 9/21 的更新分開看 |
| 9/14 | CephX 金鑰遷移／輪換 | osd.0／osd.2 的 label 被寫成 keyring 路徑；osd.1 的 label 和有效金鑰不一致 |
| 9/15 | PVE RBD storage 金鑰副本問題 | 遷移文章記錄同步 storage keyring 與當日備份驗證 |
| 9/17～18 | 重開後 OSD／CephFS 故障 | 修了本機 keyring 和 CephFS secret；**當時沒有查 BlueStore label** |
| 9/20 | 日誌出現 `aio_submit retries` | 列為 I/O 觀察項目，沒有證據認定是主因 |
| 9/21 | PVE 更新後重開，osd.1／2 異常 | 當天**沒有**更新 Ceph 套件；是重開觸發了先前留下的問題 |
| 9/22 | 逐顆修正 BlueStore osd_key | 三顆 MON = LOCAL = BLUESTORE；unset noout，HEALTH_OK |

> 不能簡化成「PVE 更新弄壞 Ceph」。事件鏈是：**升級 → 金鑰遷移留下錯誤的 BlueStore 資料 → 重開時讀到它 → 認證失敗 → OSD 和上層儲存異常**。

[9/14 遷移紀錄](https://kbwangtw.github.io/IT-Knowledge-Base/docs/pve/ceph-20-2-4-cephx-aes256k-migration/)和 [9/17～18 服務復原](https://kbwangtw.github.io/IT-Knowledge-Base/docs/pve/ceph-osd-cephfs-keyring-recovery/)保留各自當日的驗證範圍。

## 4. 根因：`-v` 收的是「值」，不會去讀檔案

以下是**錯誤的歷史用法，禁止執行**（故意用 text 區塊，只供辨識）：

```text
ceph-bluestore-tool ... set-label-key --key osd_key \
  -v /root/ceph-key-migration/osd.2.new.keyring
```

`-v`／`--value` 接收的是**要存進 label 的文字**，不是「去讀這個檔案」。所以它把 `/root/ceph-key-migration/osd.2.new.keyring` 這串字**原樣**存進 `osd_key`，不會打開檔案、更不會解析裡面的 key。（[ceph-bluestore-tool 官方文件](https://docs.ceph.com/en/latest/man/8/ceph-bluestore-tool/)也要求修改 label 前先停止對應 OSD。）

| 節點／OSD | 9/22 確認的問題 | 修復結果 |
| --- | --- | --- |
| node10／osd.0 | label 的 osd_key 是 `osd.0.new.keyring` 的路徑 | 寫回驗證過的本機 key，三處一致 |
| node11／osd.1 | label 是金鑰文字，但和 MON／本機**不一致** | 寫回驗證過的本機 key，三處一致 |
| node12／osd.2 | label 的 osd_key 是 `osd.2.new.keyring` 的路徑 | 寫回驗證過的本機 key，三處一致 |

- osd.1 的問題是「內容不一致」，不是「也寫成路徑」。
- osd.0 當時還能運作，但它的 label 一樣有問題，不能略過。

## 5. 修復流程：一次一顆，不重新產生金鑰

**實際順序**：label 修復前，叢集已先恢復到 3 up／3 in、97 active+clean。先處理 osd.0 → osd.2，最終稽核發現 osd.1 仍不一致，再單獨處理 osd.1。中途曾解除 noout，處理 osd.1 前重新設定；**每次停止／修改 OSD 期間都有 noout**。

以下把成功流程整理成一致的步驟。

> ⚠️ **已經健康且三處一致的 OSD 不需要再寫 label。** 也不可把這套流程直接套到仍有多顆 OSD down 的叢集。

### 5-1 步驟一：確認基線、對應裝置

在對應節點用 root 執行。核對 OSD ID、`block` 指向的實際裝置、其他 OSD 是否健康。備份 keyring／metadata 時放在 root 專用、權限受限的位置，**不進 Git**。

```bash
ceph -s
ceph health detail
ceph osd tree
ceph fs status
# 以 node10 / osd.0 為例；每次只選一顆
readlink -f /var/lib/ceph/osd/ceph-0/block
ceph osd set noout
```

- `noout` 只避免 Ceph 自動把 OSD 踢出去，**不保證服務可用**；停止 OSD 前仍要確認副本數、pool min_size 和維護影響。
- 如果 quorum、其他 OSD 或 PG 原本就異常，**先停下來**排除既有故障。

### 5-2 步驟二：比對三處金鑰（唯讀）

在 **Bash** 執行。node10 用 `id=0`、node11 用 `id=1`、node12 用 `id=2`。

```bash
(
  set +x
  set -euo pipefail
  id=0
  dir="/var/lib/ceph/osd/ceph-${id}"
  normalize() { tr -d '[:space:]'; }
  mon=$(ceph auth get-key "osd.${id}" 2>/dev/null | normalize)
  local_key=$(ceph-authtool "$dir/keyring" -n "osd.${id}" \
    --print-key 2>/dev/null | normalize)
  label_key=$(ceph-bluestore-tool show-label --dev "$dir/block" 2>/dev/null |
    python3 -c 'import json,sys
d=json.load(sys.stdin)
if len(d)!=1: sys.exit("LABEL_COUNT_ERROR")
x=next(iter(d.values()))
if str(x.get("whoami"))!=sys.argv[1]: sys.exit("OSD_ID_MISMATCH")
k=x.get("osd_key")
if not isinstance(k,str): sys.exit("LABEL_KEY_MISSING")
sys.stdout.write("".join(k.split()))' "$id")
  test -n "$mon"
  test -n "$local_key"
  test -n "$label_key"
  printf 'MON       : '; printf '%s' "$mon" | sha256sum
  printf 'LOCAL     : '; printf '%s' "$local_key" | sha256sum
  printf 'BLUESTORE : '; printf '%s' "$label_key" | sha256sum
  test "$mon" = "$local_key" || { echo MON_LOCAL_MISMATCH; exit 1; }
  test "$mon" = "$label_key" || { echo BLUESTORE_MISMATCH; exit 1; }
  echo THREE_WAY_MATCH
)
```

**這段在做什麼**：

| 部分 | 意思 |
| --- | --- |
| `( … )` | 在子 shell 執行，變數不會留在你的終端機 |
| `set +x` | 不印出指令內容（避免金鑰出現在畫面） |
| `set -euo pipefail` | 任何一步出錯就停止 |
| `normalize` | 去掉空白、換行，避免格式差異造成誤判 |
| `mon=`／`local_key=`／`label_key=` | 分別從 MON、本機 keyring、BlueStore label 讀出金鑰 |
| `python3 -c …` | 解析 label，並檢查 OSD 編號對得上、`osd_key` 存在 |
| `test -n` | 拒絕空值，避免「兩個空值算出一樣的 hash」被誤判一致 |
| `sha256sum` | 只印摘要，不印金鑰 |

**應該看到**：三行 hash 相同，最後印出 `THREE_WAY_MATCH`。

> 如果 MON 和 LOCAL 不一致，**不能**直接用本機 key 覆蓋 label。要先找出有效的認證來源、修好本機 keyring 並驗證服務。本案 label 修復前已先證明 MON = LOCAL。也不要把 `show-label` 或 `--print-key` 的原始輸出貼到聊天或日誌平台。

### 5-3 步驟三：停止 OSD，把有效 key 寫進 label

只有在**確認 MON = LOCAL、而 label 不一致**時才做。以下以 node10／osd.0 示範；每顆都要重新做前置核對，**不要用迴圈同時跑三台**。

```bash
systemctl stop ceph-osd@0
systemctl is-active ceph-osd@0
```

確認回報 `inactive` 才寫入。下面這段會**再檢查一次**停止狀態和 MON／LOCAL 一致性；出錯就保持停止，不會自動啟動或解除 noout：

```bash
(
  set +x
  set -euo pipefail
  id=0
  dir="/var/lib/ceph/osd/ceph-${id}"
  state=$(systemctl show "ceph-osd@${id}" -p ActiveState --value)
  test "$state" = inactive || { echo OSD_NOT_STOPPED; exit 1; }
  OSDKEY=$(ceph-authtool "$dir/keyring" -n "osd.${id}" \
    --print-key 2>/dev/null | tr -d '[:space:]')
  MONKEY=$(ceph auth get-key "osd.${id}" 2>/dev/null | tr -d '[:space:]')
  test -n "$OSDKEY"
  test -n "$MONKEY"
  test "$OSDKEY" = "$MONKEY" || { echo MON_LOCAL_MISMATCH; exit 1; }
  ceph-bluestore-tool set-label-key \
    --dev "$dir/block" --key osd_key -v "$OSDKEY"
  unset OSDKEY MONKEY
)
```

- 這裡 `-v "$OSDKEY"` 傳的是**解析出的金鑰值**；**禁止傳入 keyring 檔案路徑**。
- 不 rotate、不改 MON、不重建 OSD。
- 這個指令會短暫讓金鑰出現在程序參數中，要在受控的管理環境執行、關閉 shell tracing，不要錄製或公開程序清單。

### 5-4 步驟四：三處一致才啟動，叢集恢復才換下一顆

先重跑 5-2 的唯讀比對，確認 `THREE_WAY_MATCH`，再啟動：

```bash
systemctl start ceph-osd@0
systemctl is-active ceph-osd@0
ceph osd tree
ceph -s
ceph health detail
journalctl -u ceph-osd@0 --since "10 minutes ago" --no-pager -n 100
```

**本次的情況**：osd.0 先顯示 process active，但 OSD tree 還是 down、PG undersized／degraded。看日誌並等待後，才回到 3 up／3 in、97 active+clean。

- **不要**用固定等 5 秒或 10 秒當驗收，也不要看到暫時 down 就重複改 key 或重啟。
- 持續異常時，保留 noout、**停止處理下一顆**，先查這顆的日誌。
- 只有 health detail **唯一剩下 noout 維護警告**時，才算預期狀態；其他 warning 都要處理。

### 5-5 步驟五：三顆都驗證後解除 noout

```bash
ceph osd unset noout
ceph -s
ceph health detail
ceph osd tree
ceph fs status
```

這是維護收尾，不需要再輪換或再寫 label。

## 6. 9/22 最終驗證結果

執行 `ceph osd unset noout` 後的狀態（去除識別資訊的摘要）：

```text
health: HEALTH_OK
mon: 3 daemons, quorum node10,node11,node12
mgr: node10 active; standbys node12,node11
mds: 1/1 up, 2 standby
osd: 3 osds, 3 up, 3 in
volumes: 1/1 healthy
pools: 4 pools, 97 PG
PG: 95 active+clean
     2 active+clean+scrubbing+deep
```

97 個 PG 都是 active+clean，其中 2 個正在 deep scrub（定期深度檢查），不是故障，不需要關閉 scrub。

| OSD | MON／LOCAL／BLUESTORE hash | 結果 |
| --- | --- | --- |
| osd.0 | 三者相同 | ✅ |
| osd.1 | 三者相同 | ✅ |
| osd.2 | 三者相同 | ✅ |

表格的意思是**每顆 OSD 自己的三處相同**，不是三顆共用同一把 key。

9/22 當時已確認的範圍：label 修復、OSD 重啟後入叢集、三處一致、叢集健康。整機重開驗證、所有應用讀寫、新備份與還原測試，不在當天的證據裡。

## 7. 10/12 補記：修復後第一次整機重開

10/12 更新 kernel（7.0.14-22-pve → 7.0.14-23-pve），三台逐台重開。Ceph 套件沒升級，仍是 20.2.4-pve5。

| 項目 | 結果 |
| --- | --- |
| MON | 3 daemons，quorum node10、node11、node12 |
| OSD | 3 up／3 in，osd.0、osd.1、osd.2 都 up |
| PG | 97 active+clean |
| CephFS | 1/1 healthy |
| 叢集健康 | HEALTH_OK，`noout` 已解除 |

9/21 重開後 osd.1／osd.2 加入不了叢集；這次三顆都正常加入，**支持 BlueStore 修復在重開後仍有效**。

- 這次沒有重跑三處 hash 比對，判斷依據是 OSD 加入叢集和 HEALTH_OK。
- HA 服務 ct:100 與 vm:107 用 Ceph 上的磁碟，重新啟動後都恢復 running；但沒做完整的應用讀寫和新備份還原測試。
- 同次重開中 node10 有兩個 HA 服務進入 error，原因是手動重開前沒進 HA 維護模式，和 Ceph 無關，見 [PVE 更新重開後 HA 服務卡在 error](https://kbwangtw.github.io/IT-Knowledge-Base/docs/pve/pve-ha-service-error-after-reboot/)。

## 8. 9/20 的 I/O 訊息

9/20 的 `aio_submit retries` 保留為觀察項目。10/14 的 30 天統計顯示三顆 OSD 每晚都有、七成五集中在 21:00 備份時段，SMART 正常，見 [Ceph 慢操作與備份排程](https://kbwangtw.github.io/IT-Knowledge-Base/docs/pve/ceph-bluestore-slow-op-backup-schedule/)。沒有證據把這次故障歸因於 SSD 損壞。

## 9. 10/14 補記：osd.1 金鑰輪換

### 9-1 為什麼要換

osd.1 的實際 CephX key 曾在排障對話中曝光。9/22 先完成一致性修復，沒有把輪換混進事故收尾。

CephX key **不會自己過期**。osd.1 的權限是 `mon`／`mgr` = `allow profile osd`、`osd` = `allow *`，拿到 key 又能連到 Ceph 網路的人，理論上可以冒充 osd.1 讀寫儲存層。Ceph 網路不對外，實際風險不高，但外流的 key 會一直有效，只有換掉才能讓它失效。

### 9-2 原則

和 9/22 相同：**osd.1 停機時，把 MON、本機 keyring、BlueStore label 三處一起換成同一把新 key，三處一致才啟動。**

> label 一定要換：`/var/lib/ceph/osd/ceph-1` 是 tmpfs，重開時由 `ceph-volume` 依 label 重建 keyring。漏掉 label，下次重開 osd.1 就會用舊 key 而登入失敗。

全程在 node11 的 tmux 裡執行（斷線也不會中斷），白天 12:00 左右進行，避開 21:00～03:00 的備份、GC 與 Verify。輸出只看 hash 前幾碼與 OK／錯誤字樣，不顯示 key。

### 9-3 步驟與結果

| 步驟 | 內容 | 本次結果 |
| --- | --- | --- |
| 0. 事前檢查 | HEALTH_OK、3 up／3 in、97 active+clean；四個 pool 都是 size 3／min_size 2；`ceph auth import` 可用；沒有備份在跑 | 通過 |
| 確認 key 類型 | osd.0／1／2 的 key 和 `ceph-authtool --gen-print-key` 產生的 key 都是 60 字元，屬於 9/14 遷移後的新類型 | 通過 |
| 1. 備份與稽核 | `ceph auth get osd.1` 與本機 keyring 複製到 `/root/osd1-rotate/`（700／600）；三處 hash 比對 | `THREE_WAY_MATCH`、`KEY=OLD` |
| 2. 停止 | `ceph osd set noout`，`systemctl stop ceph-osd@1` | inactive、osd.1 down |
| 3. 換 key | 產生新 key，依序寫入本機 → label → MON，**最後才動 MON** | `LOCAL_OK`、`LABEL_OK`、`MON_OK`；三處一致、和舊值不同（`KEY=NEW`）；keyring 仍是 `ceph:ceph` 600 |
| 4. 啟動 | `systemctl start ceph-osd@1` | 約 20 秒後 up；短暫 11 個 PG peering，約 1 分鐘內回到 97 active+clean；日誌沒有 auth／cephx 錯誤 |
| 5. 收尾 | `ceph osd unset noout`，再稽核一次，`shred` 刪除備份 | HEALTH_OK；`THREE_WAY_MATCH`、`KEY=NEW`；備份已清除 |

**換 key 的核心步驟**。MON 用的 keyring 由原本的匯出檔只替換 `key =` 那一行，權限（caps）保持不變；任何檢查失敗就停止，osd.1 保持停機：

```bash
(
  set +x; set -euo pipefail; umask 077
  dir=/var/lib/ceph/osd/ceph-1; w=/root/osd1-rotate
  [ "$(systemctl show ceph-osd@1 -p ActiveState --value)" = inactive ] || { echo OSD_NOT_STOPPED; exit 1; }
  NEWKEY=$(ceph-authtool --gen-print-key | tr -d '[:space:]')
  [ "${#NEWKEY}" -eq 60 ] || { echo "KEY_LENGTH_WRONG ${#NEWKEY}"; exit 1; }
  sed "s|^\([[:space:]]*key = \).*|\1${NEWKEY}|" "$w/mon-old.keyring" > "$w/mon-new.keyring"
  grep -qF "$NEWKEY" "$w/mon-new.keyring" || { echo SED_FAILED; exit 1; }
  diff <(grep caps "$w/mon-old.keyring") <(grep caps "$w/mon-new.keyring") >/dev/null || { echo CAPS_CHANGED; exit 1; }
  sed "s|^\([[:space:]]*key = \).*|\1${NEWKEY}|" "$w/local-old.keyring" > "$dir/keyring"
  grep -qF "$NEWKEY" "$dir/keyring" || { echo LOCAL_FAILED; exit 1; }
  echo LOCAL_OK
  ceph-bluestore-tool set-label-key --dev "$dir/block" --key osd_key -v "$NEWKEY"
  echo LABEL_OK
  ceph auth import -i "$w/mon-new.keyring"
  echo MON_OK
  unset NEWKEY
  echo ROTATE_DONE
)
```

**逐段說明**：

| 部分 | 意思 |
| --- | --- |
| `umask 077` | 新建的檔案只有 root 能讀 |
| 第一個 `[ … ]` | 確認 osd.1 已停止，否則中止 |
| `--gen-print-key` | 產生新金鑰；檢查長度是 60 字元 |
| `sed "s|…key = …|…|"` | 只換 `key =` 那一行 |
| `diff <(grep caps …)` | 確認權限沒被改到 |
| 最後三段 | 依序寫入本機 → label → MON，各印一個 OK |

稽核用的比對和 5-2 相同（`id=1`），另外比對備份的舊 key，用來分辨 `KEY=OLD`／`KEY=NEW`。

**退回方案**（本次沒用到）：停止 osd.1，用備份的舊 keyring 寫回本機和 label，`ceph auth import -i mon-old.keyring` 還原 MON，稽核一致後再啟動。只在啟動後出現認證錯誤時使用；退回後用的是外流的舊 key，只能暫時使用。

### 9-4 注意事項

- Tentacle 另有 `ceph auth rotate <entity> [--key_type]`，但它會在 OSD 運作中直接換掉 MON 端的 key，順序不受控制，本次不使用。
- **不要把指令輸出貼回 shell**：輸出中可能剛好有可執行的內容。
- 排障時，含 key 的輸出（`ceph auth get`、keyring、`show-label`）只回報 hash 或 OK／錯誤字樣，避免又要事後輪換。
- **不要**把 secret、含 key 的截圖或完整認證匯出放進 GitHub、Pages、issue 或 Graylog。

### 9-5 2026-11-01 補記：輪換後的重開驗證

**做什麼**：10/14 輪換後，叢集在 10/23、11/01 兩次整叢集關機再開機（見[叢集關機與開機](https://kbwangtw.github.io/IT-Knowledge-Base/docs/pve/pve-cluster-full-shutdown/)第 7、9 節），osd.1 都是從 BlueStore label 重建 keyring 後啟動的。11/01 下午在 node11 確認 osd.1 正常，並重跑三處比對。

**怎麼做①：確認 osd.1 狀態**（node11，唯讀）：

```bash
hostname
ceph -s | grep -E 'health|osd:|pgs:'
ceph pg stat
ceph osd tree | grep -E 'host node11|osd\.1 '
systemctl is-active ceph-osd@1
journalctl -u ceph-osd@1 -b --no-pager | grep -ciE 'auth|cephx|bad key|Malformed'
```

| 片段 | 意思 |
| --- | --- |
| `hostname` | 確認在 node11；`ceph-osd@1` 和 osd.1 的硬碟只在這台，在別台跑會看到 `inactive`、`0`，不代表有問題 |
| `ceph pg stat` | 一行列出全部 PG 的狀態；`ceph -s` 配 `grep` 只會抓到第一行 |
| `journalctl -u ceph-osd@1 -b` | 這次開機以來 osd.1 的日誌 |
| `grep -ciE …` | 只計算提到認證錯誤的行數，不印出內容 |

**看到的結果**：

| 檢查 | 結果 |
| --- | --- |
| 叢集 | `HEALTH_OK`，3 up／3 in |
| PG | 97 個：96 `active+clean`、1 `active+clean+scrubbing+deep`（定期檢查，不是故障） |
| osd.1 | `up`，`ceph-osd@1` 是 `active` |
| 認證錯誤 | 這次開機以來 0 筆 |

**怎麼做②：三處比對**：用 5-2 的腳本，`id=1`，三行 `sha256sum` 後面加 `| cut -c1-12`，只印摘要前 12 碼，方便記錄又不露出金鑰。

**看到的結果**：MON、LOCAL、BLUESTORE 三行的前 12 碼相同，最後印出 `THREE_WAY_MATCH`。

- 10/14 的舊 key 備份已經 `shred` 刪除，這次無法再比對 `KEY=NEW`；但三處一致、osd.1 能登入叢集而且沒有認證錯誤，代表重開後用的就是輪換後的 key。
- 結論：**輪換時三處一起換（含 label）是有效的**，重開不會退回舊 key。

## 10. 常見問題

| 現象 | 怎麼辦 |
| --- | --- |
| 修好後一重開又壞 | 檢查 BlueStore label 的 osd_key，本機 keyring 是開機時從它重建的 |
| 日誌出現 `Malformed input` | label 裡可能存成了路徑；用 5-2 比對 |
| `systemctl is-active` 是 active，但 OSD tree 是 down | 程式在跑不代表已入叢集；看日誌、等待，不要重複改 key |
| MON 和 LOCAL 不一致 | 不要直接覆蓋 label；先找出有效來源、修好本機 keyring |
| 要換 OSD 金鑰 | 三處一起換、最後才動 MON；不用 `ceph auth rotate` |
| 金鑰曾貼到聊天或截圖 | 視為外流，安排輪換 |

## 11. 防復發：更新／重開機檢查清單

### 更新與重開前

- [ ] 留存日期、`pveversion -v`、`ceph versions` 與實際套件變更，分清「套件升級」和「重開觸發」。
- [ ] 確認 MON quorum、3 up／3 in、PG active+clean、CephFS healthy，了解 pool 副本與 min_size。
- [ ] 每顆 OSD 用同一規則驗證 MON = LOCAL = BLUESTORE；讀取錯誤或空值不算通過。
- [ ] 核對 PVE RBD keyring、CephFS 實際 secretfile、daemon／bootstrap 等金鑰使用端，不只測管理 CLI。
- [ ] 準備備份與回復計畫，記錄旗標原始狀態；維護用 noout，完成後解除。
- [ ] 確認指令參數語意；**禁止** `set-label-key -v /path/to/keyring`。修改 label 前必須停止對應 OSD。

### 每次只處理一台／一顆

- [ ] 前一顆 OSD／前一台節點沒恢復，就停止往下推進。
- [ ] 啟動後同時查 systemd、OSD tree、health detail 與 PG；不能只看 active。
- [ ] 複查三處 hash，確認啟用流程沒有帶回錯誤內容。
- [ ] 一台的叢集與儲存驗證完成後，再處理下一台；**禁止三台一起重開**。

### 全部完成後

- [ ] 確認三顆一致、3 MON quorum、3 up／3 in、97 PG active+clean、CephFS healthy，再 unset noout。
- [ ] 確認 HEALTH_OK，正常 deep scrub 不當成故障；其他警告記錄實際原因。
- [ ] 各節點核對 CephFS 真正掛載來源／FSTYPE、PVE storage 狀態與必要應用讀寫。`pvesm status` 可能嘗試啟用 storage，要留意。
- [ ] 新備份看最終 TASK OK，再依計畫做還原驗證；不得沿用舊日期的結果。
- [x] 修復後整機重開驗證：10/12 完成，三顆正常加入、HEALTH_OK（未重跑三處 hash）。
- [x] 已曝光 key 的輪換：10/14 完成，三處一致、HEALTH_OK。
- [x] 輪換後的重開驗證：2026-11-01 完成（10/23、11/01 兩次整叢集重開後），osd.1 up、無認證錯誤、`THREE_WAY_MATCH`（9-5）。

## 12. 延伸閱讀

- [CephX 遷移與 storage 副本漏項](https://kbwangtw.github.io/IT-Knowledge-Base/docs/pve/ceph-20-2-4-cephx-aes256k-migration/)
- [9/17～18 OSD／CephFS 服務復原](https://kbwangtw.github.io/IT-Knowledge-Base/docs/pve/ceph-osd-cephfs-keyring-recovery/)
- [ProxCenter 逐台更新](https://kbwangtw.github.io/IT-Knowledge-Base/docs/pve/proxcenter-ceph-rolling-update/)
- [PVE 日誌集中到 Graylog](https://kbwangtw.github.io/IT-Knowledge-Base/docs/pve/proxmox-graylog-syslog-pipeline-sop/)
- [Ceph BlueStore 工具官方參數](https://docs.ceph.com/en/latest/man/8/ceph-bluestore-tool/)
