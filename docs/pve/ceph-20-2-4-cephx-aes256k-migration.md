---
layout: default
title: "Proxmox VE 9 + Ceph 20.2.4 Tentacle：CephX AES → AES256K 安全金鑰遷移實戰"
date: 2026-09-14
categories: [PVE, Ceph, Security]
---

<div class="kb-hero">
<h1>Proxmox VE 9 + Ceph 20.2.4 Tentacle：CephX AES → AES256K 安全金鑰遷移實戰</h1>
<p>三節點 Proxmox VE 9／Ceph Tentacle 20.2.4 升級後，依 Ceph 官方程序處理 CVE-2025-30156 所揭露的舊 CephX AES credential，完成 MON、MGR、MDS、OSD、bootstrap clients、client.crash、client.admin 與最終 AES256K-only 切換。</p>
<div class="kb-badges"><span class="kb-badge">PVE 9</span><span class="kb-badge">Ceph 20.2.4 Tentacle</span><span class="kb-badge">CephX</span><span class="kb-badge">AES256K</span><span class="kb-badge">HEALTH_OK</span></div>
</div>

> 本文為 2026-09-14 實機維運紀錄。所有 Ceph secret key、FSID、IP 等敏感資訊均不收錄。文中的節點名稱保留作為操作流程說明。

## 1. 案例摘要

Ceph 升級到 20.2.4 Tentacle 後，Cluster 並沒有故障，但開始出現多項 CephX `HEALTH_WARN`。原因是 Ceph 20.2.4 修補 CVE-2025-30156，會偵測既有 `aes` key type 並要求遷移到新的 `aes256k`。

本次採「一次一個 daemon／credential、每一步立即驗證」方式完成遷移。最終結果：

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
9. 確認所有 insecure client/service warnings 清除
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

## 15. 最後 AES-only 切換

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

因此執行最後切換：

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

這證明三台 PVE 節點的 `client.admin` 在 AES256K-only 環境下均可正常認證。

## 17. 移除 emergency admin，正式結案

確認三節點正常後，在 node10 移除 emergency auth entity：

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

至此 CephX AES → AES256K migration 正式完成。

## 18. 本次時間線

| 時間 | 狀態 |
|---|---|
| 遷移初期 | daemon/client 舊 AES credentials 逐項輪替 |
| 14:48 | 仍有 MON/MDS/OSD/MGR 共 4 類 rotating AES service keys |
| 16:25 | rotating warning 自然消失，只剩 AES allowed/creatable warnings |
| 16:26 後 | `auth_allowed_ciphers` 切為 `aes256k`，立即 `HEALTH_OK` |
| 最終驗證 | node10/node11/node12 admin 全部 RC=0 |
| 結案 | 移除 `client.admin-backup`，仍為 `HEALTH_OK` |

## 19. 這次踩到的重點

- 升級後的 CephX WARN 是安全 migration 訊號，不等於 Ceph 故障。
- `auth_allowed_ciphers aes256k` 一定要最後才做。
- MON、MGR、MDS、OSD 都應採 rolling、一個一個處理。
- OSD 不只要換 keyring，ceph-volume BlueStore OSD 也要注意 label 裡的 `osd_key`。
- rotating service keys 不需要為了追求立即 HEALTH_OK 就強制 wipe；本案例等待後自然消失。
- `client.admin` 要最後處理，而且先建立可驗證的 emergency admin。
- PVE 的 `/etc/pve` 是 pmxcfs，共享 keyring 要理解其同步特性。
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
✗ AES256K-only 尚未完成三節點驗證就刪 emergency admin
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
Rotating service keys 自然過期
        ↓
auth_allowed_ciphers → AES256K only
        ↓
三節點 admin authentication 驗證
        ↓
移除 emergency admin
        ↓
HEALTH_OK
```

> **先確保所有真正使用中的 credential 都已安全換成 AES256K，再關閉舊 AES。**

## 官方文件

- Ceph CVE-2025-30156：<https://docs.ceph.com/en/latest/security/CVE-2025-30156/>
- Ceph Tentacle 20.2.4 Release Notes：<https://docs.ceph.com/en/latest/releases/tentacle/>
- CephX Config Reference / Upgrading and Rotating CephX Keys：<https://docs.ceph.com/en/tentacle/rados/configuration/auth-config-ref/>
- Ceph Health Checks：<https://docs.ceph.com/en/latest/rados/operations/health-checks/>
- Ceph Manual Deployment / bootstrap credentials：<https://docs.ceph.com/en/tentacle/install/manual-deployment/>
