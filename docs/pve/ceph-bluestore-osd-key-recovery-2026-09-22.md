---
layout: default
title: "PVE 重開後 Ceph 又故障：修正 BlueStore 裡的 OSD 金鑰"
date: 2026-09-22
last_modified_at: 2026-09-22
categories: [PVE, Ceph, Troubleshooting]
permalink: /docs/pve/ceph-bluestore-osd-key-recovery-2026-09-22/
---

# PVE 重開後 Ceph 又故障：修正 BlueStore 裡的 OSD 金鑰

**9/22 已完成三顆 OSD 的 BlueStore 金鑰修復與稽核，解除 noout 後回到 HEALTH_OK。** 這次查明：9/14 金鑰遷移時把 keyring「檔案路徑」傳給 `set-label-key -v`，使 osd.0／osd.2 的 BlueStore `osd_key` 存成路徑字串；osd.1 則保存了與 MON／local 不一致的金鑰。

重開機讓潛藏的認證資料問題再次浮現。9/21 更新本身沒有更新 Ceph 套件，不能把本案簡化成「PVE 更新弄壞 Ceph」。

> 依 2026-09-21～22「PVE 更新後排查 Web介面」對話的已確認結果整理，日期採 UTC+8。保留節點及 OSD 編號，不公開 CephX secret、完整 label 或原始截圖。本文的操作範例依當時成功流程整理並加入失敗即停止的檢查；不是本次文件發布時重新操作正式叢集的紀錄。

## 環境與一開始的症狀

| 項目 | 本案環境 |
| --- | --- |
| PVE 節點 | node10、node11、node12；既有環境紀錄為 PVE 9.2.x |
| OSD 對照 | node10 → osd.0；node11 → osd.1；node12 → osd.2 |
| Ceph | 9/13 從 20.2.2-pve1 升至 20.2.4-pve4 |
| 服務 | 3 MON、MGR 1 active／2 standby、MDS 1 active／2 standby |
| 儲存 | 3 OSD、4 pools、97 PG、1 個 CephFS |

9/21 reboot／OSD activation 後，OSD.1／OSD.2 無法正常啟動或加入叢集，CephFS／PVE storage 查詢 timeout，影響 PVE Web 介面的儲存狀態。OSD.2 曾把路徑當 CephX key 解析，出現 `Malformed input`；OSD.1 有認證失敗問題。

MON quorum 正常、管理 CLI 可查詢，不能代表 OSD、CephFS 掛載及 PVE storage 都正常。`systemctl is-active` 顯示 active，也只代表服務程序正在執行，還必須確認 OSD 已向叢集報到。

## 9/13 到 9/22：升級、遷移、重開與修復

| 日期 | 事件 | 證據與判讀 |
| --- | --- | --- |
| 9/13 | Ceph 20.2.2-pve1 → 20.2.4-pve4 | Ceph 套件升級發生在此日，與 9/21 更新分開看 |
| 9/14 | CephX migration／rotation | osd.0／osd.2 的 label 更新把 keyring 路徑當成值；osd.1 後續查到 label 與有效金鑰不一致 |
| 9/15 | PVE RBD storage 金鑰副本問題 | 既有遷移文章記錄同步 storage keyring 與當日備份驗證；不是 9/22 新測試 |
| 9/17～18 | 先前重開後 OSD／CephFS 故障 | 已修本機 keyring 與 CephFS secret；當時尚未查證、修正 BlueStore label，詳見舊復原紀錄 |
| 9/20 | 日誌出現 aio_submit retries | 列為 I/O 觀察項目，沒有足夠證據認定是本次主因 |
| 9/21 | PVE 更新後 reboot／activation，OSD.1／2 異常 | 當日未更新 Ceph package；啟用流程觸發先前留下的認證資料問題，伴隨 CephFS／PVE storage timeout |
| 9/22 | 逐顆修正 BlueStore osd_key，完成三層稽核 | 三顆均 MON = LOCAL = BLUESTORE；最後 unset noout，HEALTH_OK |

[9/14 遷移及後續更正](https://kbwangtw.github.io/IT-Knowledge-Base/docs/pve/ceph-20-2-4-cephx-aes256k-migration/)與 [9/17～18 服務復原](https://kbwangtw.github.io/IT-Knowledge-Base/docs/pve/ceph-osd-cephfs-keyring-recovery/)保留各自當日的驗證範圍，不把早期結果改寫成這次已重新測過。

## 根因：-v 接收值，不會讀取 keyring 檔案

以下是**錯誤歷史用法，禁止執行**；故意使用 text 區塊，只供辨識：

~~~text
ceph-bluestore-tool ... set-label-key --key osd_key \
  -v /root/ceph-key-migration/osd.2.new.keyring
~~~

`-v`／`--value` 接收要存入 label 的文字，不是檔案輸入參數。因此它會把 `/root/ceph-key-migration/osd.2.new.keyring` 原樣存入 `osd_key`，不會開啟檔案、更不會解析其中的 key。[Ceph 官方工具文件](https://docs.ceph.com/en/latest/man/8/ceph-bluestore-tool/)也要求修改 label 前停止對應 OSD；該連結是持續更新的文件，現場仍須核對安裝版本。

| 節點／OSD | 9/22 確認的持久化問題 | 修復結果 |
| --- | --- | --- |
| node10／osd.0 | BlueStore osd_key 是 osd.0.new.keyring 的路徑 | 寫回已驗證的 local key，三層一致 |
| node11／osd.1 | BlueStore 是金鑰文字，但與 MON／local 不一致 | 寫回已驗證的 local key，三層一致 |
| node12／osd.2 | BlueStore osd_key 是 osd.2.new.keyring 的路徑 | 寫回已驗證的 local key，三層一致 |

osd.1 不能描述為「也把路徑寫進 label」；它的已確認問題是內容不一致。也不能因 osd.0 當時還能運作，就略過它的持久化來源。

事件鏈為：**升級 → 金鑰遷移留下錯誤／不同步的 BlueStore metadata → reboot／activation 讀取該來源 → 認證或解析失敗 → OSD 與上層儲存異常。** 9/18 只恢復執行時使用的副本，尚未消除這個持久化問題；9/22 的 label 稽核與修復補上了缺口。

## 修復流程：一次一顆，不重新產生金鑰

本次 label 修復前已先恢復到 3 up／3 in、97 active+clean 的可維護基線。實際處理順序為 osd.0 → osd.2，之後最終稽核發現 osd.1 仍不一致，再單獨處理 osd.1。中途曾解除 noout，處理 osd.1 前重新設定；每次停止／修改 OSD 期間都有保留 noout。

以下將成功流程整理成一致的維護步驟。**已健康且三層一致的 OSD 不需要再寫 label。** 不可把流程直接套到仍有多顆 OSD down 的叢集。

### 1. 確認基線、對應裝置與維護條件

在對應節點以 root 執行；先核對 OSD ID、`block` 指向的實際裝置、OSD UUID／whoami，以及其他 OSD 是否健康。備份 keyring／必要 metadata 時放在 root 專用、權限受限的位置，不進 Git。`noout` 只避免自動 out，不保證服務可用；停止 OSD 前仍須確認副本、pool min_size 與維護影響。

~~~bash
ceph -s
ceph health detail
ceph osd tree
ceph fs status
# 以 node10 / osd.0 為例；每次只選一顆
readlink -f /var/lib/ceph/osd/ceph-0/block
ceph osd set noout
~~~

若 quorum、不相關 OSD 或 PG 原本就異常，停止這套預防性 label 維護，先排除既有故障。

### 2. 比較解析後的 key，不比較整份 keyring

下面是唯讀稽核範例，在 **Bash** 執行。node10 用 `id=0`；node11 用 `id=1`；node12 用 `id=2`。三個來源統一去除空白後計算 SHA-256。拒絕空值及讀取失敗，避免兩個空值產生同一 hash 而被誤判一致。

~~~bash
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
~~~

若 MON 與 local 不一致，**不能直接以 local 覆蓋 label**。先定位有效認證來源、修復本機 keyring 並驗證服務；本案 label 修復階段已先證明 MON = LOCAL。不要直接把 `show-label` 或 `--print-key` 的原始輸出貼到聊天或日誌平台。

### 3. 停止目標 OSD，再把有效 local key 寫入 label

只有在已確認 MON = LOCAL、且 label 確實不一致時才做。以下以 **node10／osd.0** 示範；每顆都需重新完成前置核對，不要用迴圈同時跑三台。

~~~bash
systemctl stop ceph-osd@0
systemctl is-active ceph-osd@0
~~~

確認回報 `inactive` 才進行寫入。以下額外再檢查一次停止狀態與 MON／local 一致性；錯誤時保持停止，不自動啟動或解除 noout。

~~~bash
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
~~~

這裡 `-v "$OSDKEY"` 傳入的是解析出的有效 key 值；**禁止傳入 keyring 檔案路徑**。不 rotate、不更改 MON auth、不建立新 OSD。此介面會短暫讓值存在程序參數中，應在受控管理環境執行，關閉 shell tracing，不錄製或公開包含參數的程序清單。

### 4. 三層一致才啟動，叢集恢復才換下一顆

先重跑上方唯讀稽核，確認 `THREE_WAY_MATCH`，再執行對應服務的啟動與檢查：

~~~bash
systemctl start ceph-osd@0
systemctl is-active ceph-osd@0
ceph osd tree
ceph -s
ceph health detail
journalctl -u ceph-osd@0 --since "10 minutes ago" --no-pager -n 100
~~~

本次 osd.0 曾先顯示 process active，但 OSD tree 仍 down、PG undersized／degraded。後續檢查日誌並等待，才回到 3 up／3 in、97 active+clean。不能以固定等待 5 或 10 秒當成驗收，也不能看到暫時 down 就重複改 key 或重啟。

若持續異常，保留 noout、停止處理下一顆，檢查該 OSD 日誌。只有 health detail **唯一剩下 noout 維護警告**時，才可把該警告視為預期；其他 warning 仍要處理。

### 5. 三顆全數驗證後解除 noout

~~~bash
ceph osd unset noout
ceph -s
ceph health detail
ceph osd tree
ceph fs status
~~~

這是維護收尾，不用再次輪替或再寫 label。後續正常監看即可。

## 9/22 最終驗證結果

最後截圖確認已執行 `ceph osd unset noout`，狀態如下；這是去除識別資訊後的摘要：

~~~text
health: HEALTH_OK
mon: 3 daemons, quorum node10,node11,node12
mgr: node10 active; standbys node12,node11
mds: 1/1 up, 2 standby
osd: 3 osds, 3 up, 3 in
volumes: 1/1 healthy
pools: 4 pools, 97 PG
PG: 95 active+clean
     2 active+clean+scrubbing+deep
~~~

97 個 PG 都具有 active+clean 狀態，其中 2 個正在 deep scrub，與當時 HEALTH_OK 一致，不是故障，也無須為此關閉 scrub。

| OSD | MON／LOCAL／BLUESTORE normalized SHA-256 | 結果 |
| --- | --- | --- |
| osd.0 | 三者相同 | 通過 |
| osd.1 | 三者相同 | 通過 |
| osd.2 | 三者相同 | 通過 |

表格表示**每顆 OSD 自己的三個來源相等**，不是三顆 OSD 共用同一把 key。公開文件只保留比對結果，不需要公開 key 或完整雜湊。

已確認範圍是 label 修復、OSD 重新啟動後入叢集、三層一致及最終叢集健康。這不等於已另外完成修復後的三台整機重開驗證、所有 PVE storage／應用讀寫、新備份與還原測試；這些不在本次最終證據中。

## Sep20 I/O 訊息與安全收尾

Sep20 的 `aio_submit retries` 保留為觀察項目。當次 SMART 檢查沒有看到 media／data integrity error；這不足以保證所有硬體狀態都正常，也沒有證據把本次主要故障歸因於 SSD 損壞。後續可對照 retries 發生時間、負載、OSD 延遲、核心 I/O／reset 訊息及 SMART 計數變化，再判斷是否需獨立追查。

**OSD.1 的實際 CephX key 曾在排障對話曝光。** 本次先完成既有金鑰的一致性修復，未將新一輪 rotation 混入事故收尾。後續另排受控維護窗口輪替 OSD.1，完整同步與驗證 MON、local、BlueStore 及啟用流程；此項仍待執行。不要將 secret、含 key 的截圖或完整認證匯出放入 GitHub、Pages、issue 或 Graylog。

## 防復發：更新／重開機前後檢查清單

### 更新與重開前

- [ ] 留存日期、`pveversion -v`、`ceph versions` 與實際套件變更，分清「套件升級」和「重開觸發」。
- [ ] 確認 MON quorum、3 up／3 in、PG active+clean、CephFS healthy，了解 pool 副本與 min_size。
- [ ] 每顆 OSD 以同一規則驗證 MON = LOCAL = BLUESTORE；讀取錯誤／空值不可視為通過。
- [ ] 核對 PVE RBD keyring、CephFS 實際 secretfile、daemon／bootstrap 等金鑰消費端，不只測管理 CLI。
- [ ] 準備受控備份與維護回復計畫，記錄旗標原始狀態；本案維護用 noout，完成後解除。
- [ ] 確認命令參數語意；禁止 `set-label-key -v /path/to/keyring`。修改 label 前必須停止對應 OSD。

### 每次只處理一台／一顆

- [ ] 前一顆 OSD／前一台節點未恢復，就停止往下一個推進。
- [ ] 啟動後同時查 systemd、OSD tree、health detail 與 PG；不能只看 active。
- [ ] 複查三層 hash，確認 activation 沒有帶回錯誤內容；秘密只在本機受控環境處理。
- [ ] 完成一台的叢集與儲存驗證，再處理下一台，禁止三台一起重開。

### 全部完成後

- [ ] 確認三顆一致、3 MON quorum、3 up／3 in、97 PG active+clean、CephFS healthy，再 unset noout。
- [ ] 確認 HEALTH_OK，正常 deep scrub 不當成故障；記錄其他警告的實際原因。
- [ ] 各節點核對 CephFS 真正掛載來源／FSTYPE、PVE storage 狀態與必要應用讀寫。`pvesm status` 可能嘗試啟用 storage，須留意操作脈絡。
- [ ] 新備份查看最終 TASK OK，再依維護計畫做還原驗證；不得沿用舊日期結果宣稱本次通過。
- [ ] 另排修復後整機滾動重開驗證及已曝光 key 的安全輪替，各自記錄日期與結果。

## 相關紀錄

- [CephX 遷移與 storage 副本漏項](https://kbwangtw.github.io/IT-Knowledge-Base/docs/pve/ceph-20-2-4-cephx-aes256k-migration/)
- [9/17～18 OSD／CephFS 服務復原](https://kbwangtw.github.io/IT-Knowledge-Base/docs/pve/ceph-osd-cephfs-keyring-recovery/)
- [ProxCenter 逐台更新](https://kbwangtw.github.io/IT-Knowledge-Base/docs/pve/proxcenter-ceph-rolling-update/)
- [PVE 日誌集中到 Graylog](https://kbwangtw.github.io/IT-Knowledge-Base/docs/pve/proxmox-graylog-syslog-pipeline-sop/)
- [Ceph BlueStore 工具官方參數](https://docs.ceph.com/en/latest/man/8/ceph-bluestore-tool/)
