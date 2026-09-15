---
layout: default
title: "Proxmox VE 9 + Ceph 20.2.4 Tentacle：CephX AES → AES256K 安全金鑰遷移實戰"
date: 2026-09-14
last_modified_at: 2026-09-15
categories: [PVE, Ceph, Security]
---

<div class="kb-hero">
<h1>Proxmox VE 9 + Ceph 20.2.4 Tentacle：CephX AES → AES256K 安全金鑰遷移實戰</h1>
<p>三節點 Proxmox VE 9／Ceph Tentacle 20.2.4 升級後，依 Ceph 官方程序處理 CVE-2025-30156 所揭露的舊 CephX AES credential，完成 MON、MGR、MDS、OSD、bootstrap clients、client.crash、client.admin 與最終 AES256K-only 切換。</p>
<div class="kb-badges"><span class="kb-badge">PVE 9</span><span class="kb-badge">Ceph 20.2.4 Tentacle</span><span class="kb-badge">CephX</span><span class="kb-badge">AES256K</span><span class="kb-badge">HEALTH_OK</span></div>
</div>

> 本文為 2026-09-14 實機維運紀錄。所有 Ceph secret key、FSID、IP 等敏感資訊均不收錄。文中的節點名稱保留作為操作流程說明。

> **2026-09-15 修訂：Ceph HEALTH_OK 不代表 PVE RBD storage credential 正常。** 本次發現 `client.admin` rotate 後，`/etc/pve/priv/ceph/VM_Pool.keyring` 仍是舊 key，導致 RBD storage inactive 與 PBS 備份失敗。以下保留原遷移實戰，並補正 Storage 同步與備份驗證。

## 1. 案例摘要

Ceph 升級到 20.2.4 Tentacle 後，Cluster 並沒有故障，但開始出現多項 CephX `HEALTH_WARN`。原因是 Ceph 20.2.4 修補 CVE-2025-30156，會偵測既有 `aes` key type 並要求遷移到新的 `aes256k`。

本次採「一次一個 daemon／credential、每一步立即驗證」方式完成遷移。2026-09-14 的 Ceph 層驗證結果（完整結案另須通過第 16 節的 Storage／PBS 驗證）：

```text
HEALTH_OK
MON     3/3 quorum
MGR     1 active + 2 standby
MDS     1 active + 2 standby
OSD     3 up / 3 in
CephFS  1/1 healthy
PG      97 active+clean

auth_service_cipher   aes256k
auth_allowed_ciphers  aes256k
auth_preferred_cipher aes256k
```

## 2. 為什麼升級後突然出現 HEALTH_WARN？

Ceph 20.2.4 Tentacle 修補 CVE-2025-30156。舊 CephX `aes` key type 使用 AES-128-CBC，缺少完整性驗證；新版加入 `aes256k`（AES256-CTS-HMAC-SHA384-192）。既有 Cluster 升級後仍維持相容性，但 Monitor 會偵測 legacy credential 並產生 migration health warnings。

因此這不是「升級把 Ceph 弄壞」，而是新版開始揭露既有 CephX credential 的安全風險。

本次曾出現：

```text
AUTH_INSECURE_CLIENT_KEY_TYPE
AUTH_INSECURE_SERVICE_KEY_TYPE
AUTH_INSECURE_SERVICE_TICKETS
AUTH_INSECURE_KEYS_ALLOWED
AUTH_INSECURE_KEYS_CREATABLE
AUTH_INSECURE_ROTATING_SERVICE_KEY_TYPE
```

## 3. 實機環境

| 項目 | 環境 |
|---|---|
| Hypervisor | Proxmox VE 9.2.x |
| Ceph | 20.2.4 Tentacle |
| Nodes | `node10`、`node11`、`node12` |
| MON | 3 / 3 quorum |
| MGR | 1 active + 2 standby |
| MDS | 1 active + 2 standby |
| OSD | 3（每節點 1 OSD） |
| CephFS | 1 filesystem |
| Pools | 4 |
| PG | 97 |

操作期間持續以以下狀態作為安全基線：

```text
MON     3/3 quorum
OSD     3 up / 3 in
PG      97 active+clean
CephFS  healthy
```

## 4. 遷移策略與正確順序

本次依 Ceph Tentacle 官方 CephX migration 原則：

1. 過渡期保留 `aes,aes256k`
2. `auth_preferred_cipher` 改成 `aes256k`
3. 輪替 MON、MGR、MDS、OSD service credentials
4. 確認 `AUTH_INSECURE_SERVICE_KEY_TYPE` 消失
5. 設定 `auth_service_cipher aes256k`
6. 讓舊 rotating service keys 自然過期
7. 輪替 bootstrap 與一般 client credentials
8. `client.admin` 最後處理，先建立 emergency admin
9. 同步所有使用該 credential 的 PVE Storage keyring；完成指定 keyring 的 RBD、各節點 `pvesm status` 與 VM／LXC 備份驗證，並確認所有 insecure client/service warnings 清除
10. 最後才把 `auth_allowed_ciphers` 改成 `aes256k`

> **不要一開始就停用 `aes`。** 舊 daemon 或 client key 尚未遷移時，可能直接失去認證能力。

## 5. Preferred cipher

先確認 Monitor 設定：

```bash
ceph mon dump 2>/dev/null | grep -E 'auth_(service|allowed|preferred)_cipher'
```

遷移初期保留：

```text
auth_allowed_ciphers aes, aes256k
```

再設定：

```bash
ceph mon set auth_preferred_cipher aes256k
```

## 6. MON 金鑰遷移

建立 root-only 工作目錄：

```bash
mkdir -p /root/ceph-key-migration
chmod 700 /root/ceph-key-migration
```

輪替 MON credential：

```bash
ceph auth rotate --key-type=aes256k mon. \
  | tee /root/ceph-key-migration/mon.keyring
```

三台 MON 一次只 restart 一台，每次確認 quorum 回到 3/3 才處理下一台：

```bash
ceph quorum_status
ceph -s
```

## 7. MGR 金鑰遷移

PVE package-based Ceph 的 MGR keyring 位於：

```text
/var/lib/ceph/mgr/ceph-nodeXX/keyring
```

每台依序執行 stop → backup → rotate → 更新 keyring → 權限 → start → health check：

```bash
systemctl stop ceph-mgr@NODE
ceph auth rotate --key-type=aes256k mgr.NODE > /root/ceph-key-migration/mgr.NODE.keyring
cp /root/ceph-key-migration/mgr.NODE.keyring /var/lib/ceph/mgr/ceph-NODE/keyring
chown ceph:ceph /var/lib/ceph/mgr/ceph-NODE/keyring
chmod 600 /var/lib/ceph/mgr/ceph-NODE/keyring
systemctl start ceph-mgr@NODE
ceph -s
```

## 8. MDS 金鑰遷移

MDS keyring：

```text
/var/lib/ceph/mds/ceph-nodeXX/keyring
```

先處理 standby MDS。處理 active MDS 時先停止 active，確認另一台 standby 自動接手 rank 0，再 rotate 舊 active MDS，避免 CephFS metadata service 同時中斷。

```bash
ceph fs status
ceph -s
```

## 9. OSD：除了 keyring，還要更新 BlueStore label

OSD 一次只處理一顆，維護期間先：

```bash
ceph osd set noout
```

每顆 OSD：

```bash
systemctl stop ceph-osd@ID
ceph osd down ID
ceph auth rotate --key-type=aes256k osd.ID > /root/ceph-key-migration/osd.ID.keyring
cp /root/ceph-key-migration/osd.ID.keyring /var/lib/ceph/osd/ceph-ID/keyring
chown ceph:ceph /var/lib/ceph/osd/ceph-ID/keyring
chmod 600 /var/lib/ceph/osd/ceph-ID/keyring
```

對 ceph-volume 建立的 BlueStore OSD，還要找出 block device：

```bash
ceph-volume lvm list
```

並更新 BlueStore label 內的 `osd_key`：

```bash
ceph-bluestore-tool --dev /dev/DEVICE \
  set-label-key --key osd_key \
  -v /root/ceph-key-migration/osd.ID.keyring
```

再啟動並等待恢復：

```bash
systemctl start ceph-osd@ID
ceph -s
```

每顆都等到 OSD `up/in`、PG `active+clean` 才處理下一顆。全部完成：

```bash
ceph osd unset noout
```

## 10. Service cipher 改成 AES256K

所有 daemon service credentials 完成後：

```bash
ceph mon set auth_service_cipher aes256k
```

過渡狀態為：

```text
auth_service_cipher aes256k
auth_allowed_ciphers aes, aes256k
auth_preferred_cipher aes256k
```

此後 `AUTH_INSECURE_SERVICE_TICKETS` 消失。

## 11. Rotating service keys：實測等待自然過期

仍可能看到：

```text
AUTH_INSECURE_ROTATING_SERVICE_KEY_TYPE
  mon using aes
  mds using aes
  osd using aes
  mgr using aes
```

本次：

```bash
ceph config get mon auth_service_ticket_ttl
```

得到 `3600` 秒，但這不代表 warning 一小時整就一定消失。Ceph 官方對一般部署建議讓 rotating service keys 自然過期，不建議只為消除 warning 就執行 wipe。

本案例在 14:48 檢查時四類 rotating AES keys 仍存在；16:25 再檢查時 `AUTH_INSECURE_ROTATING_SERVICE_KEY_TYPE` 已自然消失。實測證明不需要強制 wipe，也不需要為此重啟整個 Cluster。

## 12. Bootstrap client credentials

本次 insecure clients 包含：

```text
client.bootstrap-osd
client.bootstrap-mds
client.bootstrap-mgr
client.bootstrap-rbd
client.bootstrap-rbd-mirror
client.bootstrap-rgw
client.crash
client.admin
```

`client.bootstrap-osd` 實際使用：

```text
/var/lib/ceph/bootstrap-osd/ceph.keyring
```

輪替後分發到所有實際使用節點：

```bash
ceph auth rotate --key-type=aes256k client.bootstrap-osd \
  > /root/ceph-key-migration/bootstrap-osd.new.keyring
chmod 600 /root/ceph-key-migration/bootstrap-osd.new.keyring
```

使用 SHA256 比對，不輸出 secret：

```bash
sha256sum /root/ceph-key-migration/bootstrap-osd.new.keyring \
  /var/lib/ceph/bootstrap-osd/ceph.keyring
```

實機檢查 bootstrap-mds、bootstrap-mgr、bootstrap-rbd、bootstrap-rbd-mirror、bootstrap-rgw 目錄沒有實際 keyring，因此只安全保存新 credential，沒有憑空建立 consumer path。

> 原則：rotate client key 後必須更新每一個真正使用該 credential 的位置；沒有實際 consumer 時不要自行創造部署路徑。

## 13. PVE 的 client.crash 特殊處理

三台節點使用：

```text
/etc/pve/ceph/ceph.client.crash.keyring
```

`/etc/pve` 為 PVE cluster filesystem（pmxcfs）。先備份，再 rotate：

```bash
cp -a /etc/pve/ceph/ceph.client.crash.keyring \
  /root/ceph-key-migration/client.crash.keyring.old
chmod 600 /root/ceph-key-migration/client.crash.keyring.old

ceph auth rotate --key-type=aes256k client.crash \
  > /root/ceph-key-migration/client.crash.new.keyring
chmod 600 /root/ceph-key-migration/client.crash.new.keyring
```

更新 PVE keyring：

```bash
cp /root/ceph-key-migration/client.crash.new.keyring \
  /etc/pve/ceph/ceph.client.crash.keyring
chown root:www-data /etc/pve/ceph/ceph.client.crash.keyring
chmod 640 /etc/pve/ceph/ceph.client.crash.keyring
```

### ceph-crash startup ping 的 misleading error

restart `ceph-crash.service` 曾看到：

```text
No supported authentication method found! Is the keyring missing?
unable to find a keyring via 'keyring' config /etc/pve/priv/ceph.client.admin.keyring: Permission denied
```

實機檢查 `/usr/bin/ceph-crash` 後發現，它降權限為 `ceph` UID + `www-data` GID 後，啟動 ping 階段直接執行 `ceph -s`，沒有指定 `-n client.crash`，因此會落到一般 `[client]` 的 admin keyring 路徑而遭遇權限問題。真正 `post_crash()` 才會依序嘗試 `client.crash`、`client.crash.<hostname>`、`client.admin`。

另外確認：

```bash
ceph-conf -n client.crash --lookup keyring
```

正確解析：

```text
/etc/pve/ceph/ceph.client.crash.keyring
```

原有 caps 也保持：

```text
caps mgr = "profile crash"
caps mon = "profile crash"
```

因此不要因 startup ping 訊息就擅自放寬 `/etc/pve/priv` 權限或修改 `client.crash` caps。

## 14. client.admin：最後處理，先建立 emergency admin

先建立緊急管理 credential：

```bash
ceph auth get-or-create client.admin-backup mon "allow *" \
  > /root/ceph-key-migration/client.admin-backup.keyring
chmod 600 /root/ceph-key-migration/client.admin-backup.keyring
```

驗證：

```bash
ceph -n client.admin-backup \
  -k /root/ceph-key-migration/client.admin-backup.keyring \
  auth ls >/dev/null
echo $?
```

必須為 `0`。

本次 node10 同時有：

```text
/etc/pve/priv/ceph.client.admin.keyring
/etc/ceph/ceph.client.admin.keyring
```

先備份，再 rotate：

```bash
ceph auth rotate --key-type=aes256k client.admin \
  > /root/ceph-key-migration/client.admin.new.keyring
chmod 600 /root/ceph-key-migration/client.admin.new.keyring
```

立即更新正式 keyring：

```bash
cp /root/ceph-key-migration/client.admin.new.keyring \
  /etc/pve/priv/ceph.client.admin.keyring
cp /root/ceph-key-migration/client.admin.new.keyring \
  /etc/ceph/ceph.client.admin.keyring
chmod 600 /etc/pve/priv/ceph.client.admin.keyring
chmod 600 /etc/ceph/ceph.client.admin.keyring
```

三節點均驗證新的 admin credential 可正常執行 `ceph -s`。

### 14.1 必做：同步 PVE RBD Storage keyring

`client.admin` rotate 後，除了上述 admin 路徑，也必須盤點 `/etc/pve/storage.cfg` 中使用同一個身分的 RBD Storage。PVE 的 Storage credential 路徑為：

```text
/etc/pve/priv/ceph/<STORAGE_ID>.keyring
```

本案例 Storage ID 與 pool 都叫 `VM_Pool`，但其他環境兩者未必相同。本次設定沒有指定其他 `username`，keyring entity 為 `[client.admin]`，因此同步目前有效的 admin keyring；若 Storage 使用專用 client，應同步該 client 的有效 key，不能一律覆蓋成 admin。

**立即依第 16.3 節先備份再同步，並完成第 16.4 節驗證，才繼續停用舊 AES。** 只更新 Ceph DB 與 `/etc/ceph/ceph.client.admin.keyring`，不保證 Storage 的獨立副本也會更新。

## 15. 最後 AES256K-only 切換

16:25 再次執行：

```bash
date
ceph health detail
```

此時 `AUTH_INSECURE_ROTATING_SERVICE_KEY_TYPE` 已消失，只剩：

```text
AUTH_INSECURE_KEYS_ALLOWED
AUTH_INSECURE_KEYS_CREATABLE
```

且先前的下列警告均已消失：

```text
AUTH_INSECURE_CLIENT_KEY_TYPE
AUTH_INSECURE_SERVICE_KEY_TYPE
AUTH_INSECURE_SERVICE_TICKETS
AUTH_INSECURE_ROTATING_SERVICE_KEY_TYPE
```

原紀錄於此執行最後切換；修訂後 SOP 必須先確認第 14.1 節 Storage credential 同步與第 16 節功能驗證通過，不能只以 warnings 消失判定：

```bash
ceph mon set auth_allowed_ciphers aes256k
```

立即驗證：

```bash
ceph mon dump 2>/dev/null | grep -E 'auth_(service|allowed|preferred)_cipher'
ceph health detail
ceph -s
```

實測結果：

```text
auth_service_cipher aes256k
auth_allowed_ciphers aes256k
auth_preferred_cipher aes256k
HEALTH_OK
```

Cluster 同時維持：

```text
MON     3 daemons，3/3 quorum
MGR     1 active + 2 standby
MDS     1 active + 2 standby
OSD     3 up / 3 in
CephFS  1/1 healthy
Pools   4
PG      97 active+clean
```

切換當下 Cluster 仍有數百 MiB/s 的 client read I/O，服務仍維持正常。

## 16. AES256K-only 後的三節點驗證

停用舊 AES 後，不立刻刪除 emergency admin，而是逐節點驗證。

node10：

```bash
ceph -s >/dev/null
echo "NODE10_ADMIN_RC=$?"

ceph -n client.admin-backup \
  -k /root/ceph-key-migration/client.admin-backup.keyring \
  auth ls >/dev/null
echo "BACKUP_ADMIN_RC=$?"
```

結果：

```text
NODE10_ADMIN_RC=0
BACKUP_ADMIN_RC=0
```

node11：

```text
NODE11_ADMIN_RC=0
HEALTH_OK
```

node12：

```text
NODE12_ADMIN_RC=0
HEALTH_OK
```

這證明三台 PVE 節點的 Ceph CLI admin 認證正常；尚不足以證明 PVE RBD Storage 使用的 keyring 正常。以下為 2026-09-15 事故與補正流程。


### 16.1 實際事故：Ceph 正常，PVE RBD inactive、PBS 備份失敗

2026-09-14 輪替 `client.admin` 後，Ceph DB 與 `/etc/ceph/ceph.client.admin.keyring` 已更新，但 `/etc/pve/priv/ceph/VM_Pool.keyring` 仍保留舊 key。事故時：

| 檢查 | 修復前結果 |
|---|---|
| `ceph -s` | `HEALTH_OK` |
| 一般 `rbd -p VM_Pool ls` | 可列出 images |
| VM／CT | 仍在運作 |
| `pvesm status` | `VM_Pool rbd inactive`；PBS31 本身 active |
| 指定 PVE Storage keyring 的 `rbd ls` | `Permission denied` |
| QEMU VM 104／LXC CT 100 備份 | RBD 存取／snapshot 認證失敗 |

實際錯誤訊息（移除時間戳與執行緒 ID）：

```text
monclient(hunting): handle_auth_bad_method failed to auth with my available methods: (13) Permission denied
rbd: couldn't connect to the cluster!
rbd: listing images failed: (13) Permission denied
cannot determine size of volume 'VM_Pool:vm-104-disk-0'
```

LXC 失敗發生在 RBD snapshot 階段；錯誤關鍵片段如下，省略號代表省略的命令參數，並非完整原始 log：

```text
rbd snapshot ... Permission denied
```

> **Ceph HEALTH_OK 不代表 PVE RBD storage credential 正常。** 一般 CLI 與 PVE Storage 可能使用不同 keyring；VM 持續運作也不能取代新連線、snapshot 與備份驗證。`handle_auth_bad_method` 本身不能單獨證明 cipher 不相容，本次是以不同 keyring 的對照測試確認舊 credential 副本問題。

### 16.2 診斷：固定身分與 keyring，逐層對照

在發生問題的節點以 root 執行，先確認 Cluster、Storage 與實際 Storage 設定：

```bash
ceph -s
pvesm status
cat /etc/pve/storage.cfg
rbd -p VM_Pool ls
```

接著以相同 client 與 pool，只改變 keyring 路徑：

```bash
rbd --id admin --keyring /etc/pve/priv/ceph/VM_Pool.keyring -p VM_Pool ls
rbd --id admin --keyring /etc/ceph/ceph.client.admin.keyring -p VM_Pool ls
```

本次第一個測試認證失敗，第二個成功列出 `vm-100-disk-0`、`vm-104-disk-0` 等 images，定位到 Storage keyring 的差異。

再比對本機 admin、Ceph DB 與 Storage 的 **key 值**，避免整份 keyring 因空白或 caps 排序不同而誤判。以下 Bash 程式只輸出一致／不一致，不輸出 secret；任何讀取失敗都停止比較：

```bash
(
  set -e
  set +x
  local_key=$(ceph-authtool /etc/ceph/ceph.client.admin.keyring -n client.admin --print-key)
  db_key=$(ceph -n client.admin -k /etc/ceph/ceph.client.admin.keyring auth get-key client.admin)
  storage_key=$(ceph-authtool /etc/pve/priv/ceph/VM_Pool.keyring -n client.admin --print-key)
  test -n "$local_key" && test -n "$db_key" && test -n "$storage_key"
  if [ "$local_key" = "$db_key" ]; then
    echo "本機 admin 與 Ceph DB：一致"
  else
    echo "本機 admin 與 Ceph DB：不一致"
  fi
  if [ "$storage_key" = "$db_key" ]; then
    echo "Storage 與 Ceph DB：一致"
  else
    echo "Storage 與 Ceph DB：不一致"
  fi
)
```

本次結果為「本機 admin 與 DB 一致，Storage 與 DB 不一致」。若兩個指定 keyring 的 RBD 測試都失敗，不能直接套用此根因，應再檢查身分、caps、Ceph 設定、連線及 client 版本。

### 16.3 已驗證修復：先備份，再同步有效 credential

前提：已確認 `VM_Pool` 使用 `client.admin`，來源 key 與 DB 一致，且以來源 keyring 執行 `rbd ls` 成功。以下只在 **node10** 執行一次：

```bash
(
  set -e
  umask 077
  backup_dir=$(mktemp -d /root/ceph-rbd-keyring-backup.XXXXXX)
  cp /etc/pve/priv/ceph/VM_Pool.keyring "$backup_dir/VM_Pool.keyring"
  chmod 600 "$backup_dir/VM_Pool.keyring"
  printf '舊 keyring 備份：%s\n' "$backup_dir/VM_Pool.keyring"

  cp /etc/ceph/ceph.client.admin.keyring /etc/pve/priv/ceph/VM_Pool.keyring
  stat -c '%U:%G %a %n' /etc/pve/priv/ceph/VM_Pool.keyring
)
```

預期檔案權限：

```text
root:www-data 600 /etc/pve/priv/ceph/VM_Pool.keyring
```

本次修復流程中的權限設定命令為：

```bash
chown root:www-data /etc/pve/priv/ceph/VM_Pool.keyring
chmod 600 /etc/pve/priv/ceph/VM_Pool.keyring
```

**pmxcfs 注意事項：** `/etc/pve` 是 cluster filesystem，權限依路徑管理；`priv` 下的檔案僅 root 可存取。上述命令不是改變 pmxcfs 權限的通用方法，若拒絕設定，應以 `stat` 確認是否已為 `root:www-data 600`，不要放寬 `/etc/pve/priv`。同步內容是本次修復的關鍵。[Proxmox pmxcfs 官方說明](https://github.com/proxmox/pve-docs/blob/master/pmxcfs.adoc)

在正常有 quorum 的同一 PVE Cluster 中，這個共享路徑會同步至 node11、node12，**不需三台各自重複複製或修改**；但各台仍須分別驗證。此特性不代表一般 `/etc/ceph` 本機檔案也自動同步。

舊 keyring 備份用於追查；DB 已輪替時，單純還原舊檔不能恢復認證。本次只同步有效 keyring 即恢復，不需要再次 rotate。

### 16.4 修復後驗證與必做清單

在 **node10、node11、node12 各自執行**：

```bash
pvesm status
rbd --id admin --keyring /etc/pve/priv/ceph/VM_Pool.keyring -p VM_Pool ls
```

本次三台 `pvesm status` 均確認 `VM_Pool = active`，指定 Storage keyring 的 RBD 列表測試成功。

接著在 VM／CT 所在節點依序測試 PBS31 備份：

```bash
vzdump 104 --storage PBS31 --mode snapshot
vzdump 100 --storage PBS31 --mode snapshot
```

依本次事故驗證紀錄，兩條路徑均已成功：

| 路徑 | 已確認結果 |
|---|---|
| QEMU VM 104 → Ceph RBD → PBS31 | 備份 `TASK OK` |
| LXC CT 100（AdGuard）→ RBD snapshot → PBS31 | snapshot 建立、清除成功，備份 `TASK OK` |

LXC 成功判讀須涵蓋 snapshot 建立、資料上傳、暫存 snapshot 清除及整體任務完成。以下列出應核對的關鍵行，不是重新拼接的完整原始 log：

```text
Creating snap: 100% complete...done.
INFO: cleanup temporary 'vzdump' snapshot
Removing snap: 100% complete...done.
INFO: Finished Backup of VM 100
INFO: Backup job finished successfully
TASK OK
```

本次 CT 100 處理 3.124 GiB，重用 2.905 GiB（93.0%）；開始上傳或看到增量統計仍不能取代最後的 `TASK OK`。

遷移完成前逐項核對：

- [ ] Ceph health、MON quorum、OSD／PG 正常。
- [ ] 所有使用已輪替 client 的 Storage keyring 均已盤點並同步。
- [ ] 本機 admin key、Ceph DB 與使用 admin 的 Storage key 一致。
- [ ] node10／node11／node12 的 `VM_Pool` 均為 `active`。
- [ ] 各節點指定 PVE Storage keyring 的 `rbd ls` 成功。
- [ ] QEMU VM 104 → PBS31 備份 `TASK OK`。
- [ ] LXC CT 100 snapshot 建立／清除成功，PBS 備份 `TASK OK`。
- [ ] AES256K-only 切換後再次確認 Storage 與備份路徑，才移除 emergency admin。

## 17. 移除 emergency admin，正式結案

原紀錄僅確認三節點 admin CLI 正常便移除 emergency auth entity；修訂後必須完成第 16.4 節的 Storage／VM／LXC／PBS 驗證，才能在 node10 移除：

```bash
ceph auth rm client.admin-backup
```

再次驗證：

```bash
ceph -s >/dev/null
echo "FINAL_ADMIN_RC=$?"
ceph health detail
ceph mon dump 2>/dev/null | grep -E 'auth_(service|allowed|preferred)_cipher'
```

最終實測：

```text
FINAL_ADMIN_RC=0
HEALTH_OK
auth_service_cipher aes256k
auth_allowed_ciphers aes256k
auth_preferred_cipher aes256k
```

上述為 2026-09-14 的 Ceph 層結果；2026-09-15 補齊 Storage keyring 同步及 VM／LXC 備份驗證後，才完成本次事故結案。

## 18. 本次時間線

| 時間 | 狀態 |
|---|---|
| 遷移初期 | daemon/client 舊 AES credentials 逐項輪替 |
| 14:48 | 仍有 MON/MDS/OSD/MGR 共 4 類 rotating AES service keys |
| 16:25 | rotating warning 自然消失，只剩 AES allowed/creatable warnings |
| 16:26 後 | `auth_allowed_ciphers` 切為 `aes256k`，立即 `HEALTH_OK` |
| 最終驗證 | node10/node11/node12 admin 全部 RC=0 |
| 09-14 原結案 | 移除 `client.admin-backup`，仍為 `HEALTH_OK`；當時漏驗 Storage／PBS |
| 09-15 診斷 | 一般 RBD 正常，指定 `VM_Pool.keyring` 認證失敗，確認舊 key 副本 |
| 09-15 修復 | 備份舊檔並同步有效 admin keyring，三節點 `VM_Pool active` |
| 09-15 完整結案 | VM 104 與 CT 100 → PBS31 均 `TASK OK`，LXC snapshot 建立／清除成功 |

## 19. 這次踩到的重點

- 升級後的 CephX WARN 是安全 migration 訊號，不等於 Ceph 故障。
- `auth_allowed_ciphers aes256k` 一定要最後才做。
- MON、MGR、MDS、OSD 都應採 rolling、一個一個處理。
- OSD 不只要換 keyring，ceph-volume BlueStore OSD 也要注意 label 裡的 `osd_key`。
- rotating service keys 不需要為了追求立即 HEALTH_OK 就強制 wipe；本案例等待後自然消失。
- `client.admin` 要最後處理，而且先建立可驗證的 emergency admin。
- PVE 的 `/etc/pve` 是 pmxcfs，共享 keyring 更新一次，各節點分別驗證。
- `client.admin` rotate 後必須同步所有使用它的 `/etc/pve/priv/ceph/<STORAGE_ID>.keyring`。
- `HEALTH_OK` 不代表 PVE RBD Storage credential 正常，結案必須包含 `pvesm status`、指定 keyring 的 RBD 及 VM／LXC → PBS 驗證。
- `ceph-crash` startup ping 的 Permission denied 不代表新的 `client.crash` credential 失敗，不能因此亂改權限或 caps。
- 驗證 keyring 同步時用 SHA256，不要把 secret `cat` 到終端、ticket、聊天室或 GitHub。

## 20. 不要做的事情

```text
✗ daemon/client 尚未完成遷移就關閉 aes
✗ 同時 restart 多個 MON 或 OSD
✗ OSD rotate 後忘記 BlueStore osd_key label
✗ 把 keyring secret 貼到 GitHub、ticket 或聊天室
✗ 為了清 warning 就強制 wipe rotating service keys
✗ client.admin 未建立 emergency credential 就直接 rotate
✗ 看到 ceph-crash startup ping error 就放寬 /etc/pve/priv 權限
✗ 只看 HEALTH_OK 就判定 Storage 與 PBS 備份正常
✗ client.admin rotate 後漏更新 Storage 專用 keyring 副本
✗ AES256K-only 尚未完成三節點 Storage 與 VM／LXC 備份驗證就刪 emergency admin
```

## 21. 最終結論

這次真正重要的不是「把 HEALTH_WARN 清掉」，而是安全地完成所有正在使用的 credential migration，再停用 legacy AES。

完整流程可以濃縮成：

```text
Ceph 20.2.4 Tentacle Upgrade
        ↓
偵測 legacy CephX AES credentials
        ↓
Preferred cipher → AES256K
        ↓
MON / MGR / MDS / OSD rotation
        ↓
BlueStore osd_key 更新
        ↓
Service cipher → AES256K
        ↓
Bootstrap / client.crash / client.admin rotation
        ↓
同步 PVE Storage keyring，驗證 RBD／pvesm／VM 與 LXC 備份
        ↓
Rotating service keys 自然過期
        ↓
auth_allowed_ciphers → AES256K only
        ↓
三節點 admin／Storage authentication 與 PBS 備份驗證
        ↓
移除 emergency admin
        ↓
HEALTH_OK
```

> **先確保所有真正使用中的 credential 都已安全換成 AES256K，再關閉舊 AES。**

## 官方文件

- Proxmox CephX migration（新部署應先核對當前 PVE 官方流程與 migration helper）：<https://pve.proxmox.com/pve-docs/chapter-pveceph.html#pveceph_cephx_migration>
- Proxmox RBD Storage authentication：<https://pve.proxmox.com/pve-docs/pve-storage-rbd-plain.html>
- Proxmox Cluster File System／權限與同步：<https://github.com/proxmox/pve-docs/blob/master/pmxcfs.adoc>

- Ceph CVE-2025-30156：<https://docs.ceph.com/en/latest/security/CVE-2025-30156/>
- Ceph Tentacle 20.2.4 Release Notes：<https://docs.ceph.com/en/latest/releases/tentacle/>
- CephX Config Reference / Upgrading and Rotating CephX Keys：<https://docs.ceph.com/en/tentacle/rados/configuration/auth-config-ref/>
- Ceph Health Checks：<https://docs.ceph.com/en/latest/rados/operations/health-checks/>
- Ceph Manual Deployment / bootstrap credentials：<https://docs.ceph.com/en/tentacle/install/manual-deployment/>
