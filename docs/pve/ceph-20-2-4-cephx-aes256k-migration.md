---
layout: default
title: "Proxmox VE + Ceph 20.2.4：CephX AES → AES256K 安全金鑰遷移實戰"
date: 2026-09-14
categories: [PVE, Ceph, Security]
---

<div class="kb-hero">
<h1>Proxmox VE + Ceph 20.2.4：CephX AES → AES256K 安全金鑰遷移實戰</h1>
<p>三節點 Proxmox VE／Ceph Tentacle 20.2.4 升級後，依官方程序逐步處理 CephX 舊 AES 金鑰警告，完成 MON、MGR、MDS、OSD、bootstrap clients、client.crash 與 client.admin 的 AES256K 遷移。</p>
<div class="kb-badges"><span class="kb-badge">PVE 9</span><span class="kb-badge">Ceph 20.2.4</span><span class="kb-badge">CephX</span><span class="kb-badge">AES256K</span></div>
</div>

> 本文為實機維運紀錄。所有 Ceph secret key 均未收錄；IP、FSID、金鑰內容等敏感資訊應在公開文件中去識別化。

## 1. 為什麼升級後突然出現 HEALTH_WARN？

Ceph 20.2.4 Tentacle 修補 CVE-2025-30156。舊 CephX `aes` key type 使用 AES-128-CBC，缺少完整性驗證；新版加入 `aes256k`（AES256-CTS-HMAC-SHA384-192）。既有叢集升級後仍維持相容性，但 Monitor 會偵測舊金鑰並產生 migration health warnings。

因此這不是「升級把 Ceph 弄壞」，而是新版開始揭露既有 CephX credential 的安全風險，要求管理者分階段遷移。

官方參考：

- https://docs.ceph.com/en/latest/security/CVE-2025-30156/
- https://docs.ceph.com/en/latest/releases/tentacle/
- https://docs.ceph.com/en/tentacle/rados/configuration/auth-config-ref/

## 2. 實機環境

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
| PG | 97 |

操作期間的重要健康基線：

```text
MON     3/3 quorum
OSD     3 up / 3 in
PG      97 active+clean
CephFS  healthy
```

所有高風險操作都以「一次只處理一個 daemon／credential，完成後立即驗證」為原則。

## 3. 升級後常見警告

本次曾出現：

```text
AUTH_INSECURE_CLIENT_KEY_TYPE
AUTH_INSECURE_SERVICE_KEY_TYPE
AUTH_INSECURE_SERVICE_TICKETS
AUTH_INSECURE_KEYS_ALLOWED
AUTH_INSECURE_KEYS_CREATABLE
AUTH_INSECURE_ROTATING_SERVICE_KEY_TYPE
```

先確認 Monitor 允許新舊 cipher 共存：

```bash
ceph mon dump | grep -E 'auth_(service|allowed|preferred)_cipher'
```

遷移初期應保留：

```text
auth_allowed_ciphers aes, aes256k
```

然後把新 credential 的 preferred cipher 改成 AES256K：

```bash
ceph mon set auth_preferred_cipher aes256k
```

> **不要一開始就執行 `ceph mon set auth_allowed_ciphers aes256k`。** 舊 daemon/client key 尚未遷移時關閉 `aes`，可能直接造成認證中斷。

## 4. 官方建議遷移順序

本次依 Ceph Tentacle 官方 CephX migration 原則處理：

1. 允許 `aes,aes256k`
2. `auth_preferred_cipher` 設為 `aes256k`
3. 輪替 service daemon credentials：MON → MGR → MDS → OSD
4. 確認 `AUTH_INSECURE_SERVICE_KEY_TYPE` 消失
5. 設定 `auth_service_cipher aes256k`
6. 讓舊 rotating service keys 自然過期
7. 輪替 bootstrap／一般 client credentials
8. `client.admin` 最後處理，先建立 emergency admin
9. 所有舊 client/service key 清除後，最後才停用 `aes`

## 5. MON 金鑰遷移

先建立受限工作目錄：

```bash
mkdir -p /root/ceph-key-migration
chmod 700 /root/ceph-key-migration
```

產生新的 MON AES256K credential 並保存：

```bash
ceph auth rotate --key-type=aes256k mon. \
  | tee /root/ceph-key-migration/mon.keyring
```

三台 MON 採一次一台的方式 restart，每次都確認 quorum 回到 3/3 後才處理下一台。

```bash
ceph quorum_status
ceph -s
```

> 不要同時 restart 多個 MON。

## 6. MGR 金鑰遷移

PVE package-based Ceph 的 MGR keyring 位置：

```text
/var/lib/ceph/mgr/ceph-node10/keyring
/var/lib/ceph/mgr/ceph-node11/keyring
/var/lib/ceph/mgr/ceph-node12/keyring
```

每台一次一個：stop → backup → rotate → 更新 keyring → 權限 → start → health check。

概念流程：

```bash
systemctl stop ceph-mgr@NODE
ceph auth rotate --key-type=aes256k mgr.NODE > /root/ceph-key-migration/mgr.NODE.keyring
cp /root/ceph-key-migration/mgr.NODE.keyring /var/lib/ceph/mgr/ceph-NODE/keyring
chown ceph:ceph /var/lib/ceph/mgr/ceph-NODE/keyring
chmod 600 /var/lib/ceph/mgr/ceph-NODE/keyring
systemctl start ceph-mgr@NODE
ceph -s
```

## 7. MDS 金鑰遷移

MDS keyring：

```text
/var/lib/ceph/mds/ceph-nodeXX/keyring
```

先處理 standby MDS。最後處理 active MDS 時，先停止 active，確認另一台 standby 自動接手 rank 0，再進行 rotate。

```bash
ceph fs status
ceph -s
```

這樣可以避免一次中斷 CephFS metadata service。

## 8. OSD 金鑰遷移：除了 keyring，還要注意 BlueStore label

OSD 是本次最需要謹慎的 daemon。一次只處理一顆 OSD，並在維護期間設定 `noout`：

```bash
ceph osd set noout
```

每顆 OSD 的流程：

```bash
systemctl stop ceph-osd@ID
ceph osd down ID
ceph auth rotate --key-type=aes256k osd.ID > /root/ceph-key-migration/osd.ID.keyring
cp /root/ceph-key-migration/osd.ID.keyring /var/lib/ceph/osd/ceph-ID/keyring
chown ceph:ceph /var/lib/ceph/osd/ceph-ID/keyring
chmod 600 /var/lib/ceph/osd/ceph-ID/keyring
```

package/systemd + ceph-volume 建立的 BlueStore OSD，還要檢查並更新 BlueStore label 內的 `osd_key`。先用：

```bash
ceph-volume lvm list
```

找到該 OSD 的 block device，再依官方程序：

```bash
ceph-bluestore-tool --dev /dev/DEVICE \
  set-label-key --key osd_key \
  -v /root/ceph-key-migration/osd.ID.keyring
```

再啟動：

```bash
systemctl start ceph-osd@ID
ceph -s
```

必須等 OSD 回到 `up/in`、PG 回到 `active+clean`，才處理下一顆。

全部完成後：

```bash
ceph osd unset noout
```

## 9. Service cipher 改成 AES256K

所有 daemon service key 都完成後：

```bash
ceph mon set auth_service_cipher aes256k
```

確認：

```bash
ceph mon dump | grep -E 'auth_(service|allowed|preferred)_cipher'
```

本次過渡狀態：

```text
auth_service_cipher aes256k
auth_allowed_ciphers aes, aes256k
auth_preferred_cipher aes256k
```

`AUTH_INSECURE_SERVICE_TICKETS` 隨後消失。

## 10. Rotating service keys：不要急著 wipe

Ceph 仍可能顯示：

```text
AUTH_INSECURE_ROTATING_SERVICE_KEY_TYPE
  mon using aes
  mds using aes
  osd using aes
  mgr using aes
```

本次 `auth_service_ticket_ttl` 為 3600 秒：

```bash
ceph config get mon auth_service_ticket_ttl
```

Ceph 官方對一般部署的建議是讓 rotating service keys 自然過期，不建議為了立即消除 warning 強制 wipe。因 rotating keys 為階梯式輪替，實際清除可能需要數小時。

## 11. Bootstrap client credentials

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

### bootstrap-osd

實際使用：

```text
/var/lib/ceph/bootstrap-osd/ceph.keyring
```

先 rotate：

```bash
ceph auth rotate --key-type=aes256k client.bootstrap-osd \
  > /root/ceph-key-migration/bootstrap-osd.new.keyring
chmod 600 /root/ceph-key-migration/bootstrap-osd.new.keyring
```

再把新 keyring 分發到所有實際使用此 credential 的節點：

```bash
cp /root/ceph-key-migration/bootstrap-osd.new.keyring \
  /var/lib/ceph/bootstrap-osd/ceph.keyring
chmod 600 /var/lib/ceph/bootstrap-osd/ceph.keyring
```

使用 SHA256 比對檔案是否一致，不要 `cat` secret：

```bash
sha256sum /root/ceph-key-migration/bootstrap-osd.new.keyring \
  /var/lib/ceph/bootstrap-osd/ceph.keyring
```

### 其他 bootstrap entities

實機檢查發現 bootstrap-mds、bootstrap-mgr、bootstrap-rbd、bootstrap-rbd-mirror、bootstrap-rgw 目錄皆沒有實際 keyring，因此只將新 credential 安全保存於 `/root/ceph-key-migration/`，沒有憑空部署到原本不存在的使用位置。

例如：

```bash
ceph auth rotate --key-type=aes256k client.bootstrap-rgw \
  > /root/ceph-key-migration/bootstrap-rgw.new.keyring
chmod 600 /root/ceph-key-migration/bootstrap-rgw.new.keyring
```

原則是：**rotate client key 後，必須更新每一個真正使用該 credential 的位置；沒有實際 consumer 時不要自行創造部署路徑。**

## 12. PVE 的 client.crash 特殊處理

三台節點都看到：

```text
/etc/pve/ceph/ceph.client.crash.keyring
```

`/etc/pve` 為 PVE cluster filesystem（pmxcfs），因此先比對三台 SHA256，確認為同一份 credential，再進行 rotate。

備份：

```bash
cp -a /etc/pve/ceph/ceph.client.crash.keyring \
  /root/ceph-key-migration/client.crash.keyring.old
chmod 600 /root/ceph-key-migration/client.crash.keyring.old
```

rotate：

```bash
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

三台再以 SHA256 確認 pmxcfs 已同步。

### ceph-crash 啟動時的 misleading error

`ceph-crash.service` restart 後曾看到：

```text
No supported authentication method found! Is the keyring missing?
unable to find a keyring via 'keyring' config /etc/pve/priv/ceph.client.admin.keyring: Permission denied
```

檢查 `/usr/bin/ceph-crash` 後發現程式會先降權限成 `ceph` UID + `www-data` GID，然後在啟動 ping 階段直接執行：

```text
ceph -s
```

沒有指定 `-n client.crash`。因此會落到一般 `[client]` 的 keyring 設定：

```text
/etc/pve/priv/$cluster.$name.keyring
```

以降權後身份嘗試讀 `client.admin` 時產生 Permission denied。真正 `post_crash()` 則會依序嘗試：

```text
client.crash
client.crash.<hostname>
client.admin
```

另外確認：

```bash
ceph-conf -n client.crash --lookup keyring
```

正確解析為：

```text
/etc/pve/ceph/ceph.client.crash.keyring
```

以及 auth DB caps 保持：

```text
caps mgr = "profile crash"
caps mon = "profile crash"
```

因此不要因 startup ping 的訊息就擅自放寬 `/etc/pve/priv` 權限或修改 `client.crash` caps。

## 13. client.admin：最後處理，先建立 emergency admin

這是整個 migration 風險最高的 client credential。Ceph 官方特別要求先建立緊急管理 credential。

建立：

```bash
ceph auth get-or-create client.admin-backup mon "allow *" \
  > /root/ceph-key-migration/client.admin-backup.keyring
chmod 600 /root/ceph-key-migration/client.admin-backup.keyring
```

驗證 emergency credential，輸出丟棄，避免把所有 key 顯示到終端紀錄：

```bash
ceph -n client.admin-backup \
  -k /root/ceph-key-migration/client.admin-backup.keyring \
  auth ls >/dev/null

echo $?
```

必須為 `0`。

### 備份 PVE 與 local admin keyring

本次 node10 同時存在：

```text
/etc/pve/priv/ceph.client.admin.keyring
/etc/ceph/ceph.client.admin.keyring
```

先備份並用 SHA256 驗證一致。

### Rotate admin

```bash
ceph auth rotate --key-type=aes256k client.admin \
  > /root/ceph-key-migration/client.admin.new.keyring
chmod 600 /root/ceph-key-migration/client.admin.new.keyring
```

此刻舊 admin key 已不能重新認證，因此立即更新正式 keyring：

```bash
cp /root/ceph-key-migration/client.admin.new.keyring \
  /etc/pve/priv/ceph.client.admin.keyring

cp /root/ceph-key-migration/client.admin.new.keyring \
  /etc/ceph/ceph.client.admin.keyring

chmod 600 /etc/pve/priv/ceph.client.admin.keyring
chmod 600 /etc/ceph/ceph.client.admin.keyring
```

先用 SHA256 確認，再測：

```bash
ceph -s
echo $?
```

三台節點都必須能以新的 PVE admin keyring 正常執行 `ceph -s`。

本次驗證結果：

```text
node10  admin authentication OK
node11  admin authentication OK
node12  admin authentication OK
MON     3/3 quorum
OSD     3 up / 3 in
PG      97 active+clean
CephFS  healthy
```

## 14. 目前最後等待階段

完成所有 daemon/client migration 後，本次剩餘：

```text
AUTH_INSECURE_KEYS_ALLOWED
AUTH_INSECURE_KEYS_CREATABLE
AUTH_INSECURE_ROTATING_SERVICE_KEY_TYPE
```

Monitor 設定：

```text
auth_service_cipher aes256k
auth_allowed_ciphers aes, aes256k
auth_preferred_cipher aes256k
```

前兩個 warning 是因為遷移期間仍刻意允許 `aes`；第三個則等待 rotating service keys 自然淘汰。

定期只需檢查：

```bash
date
ceph health detail
```

不要為了追求立即 `HEALTH_OK` 而強制 wipe rotating keys。

## 15. 最後收尾：停用舊 AES

**只有在以下條件都成立後才做：**

```text
AUTH_INSECURE_CLIENT_KEY_TYPE          已消失
AUTH_INSECURE_SERVICE_KEY_TYPE         已消失
AUTH_INSECURE_SERVICE_TICKETS          已消失
AUTH_INSECURE_ROTATING_SERVICE_KEY_TYPE 已消失
三台 admin authentication              正常
MON/OSD/PG/CephFS                       正常
```

最後執行：

```bash
ceph mon set auth_allowed_ciphers aes256k
```

驗證：

```bash
ceph mon dump | grep -E 'auth_(service|allowed|preferred)_cipher'
ceph health detail
ceph -s
```

預期：

```text
auth_service_cipher aes256k
auth_allowed_ciphers aes256k
auth_preferred_cipher aes256k
```

`AUTH_INSECURE_KEYS_ALLOWED` 應清除；當 allowed ciphers 不再包含 insecure type 時，`AUTH_INSECURE_KEYS_CREATABLE` 的預設行為也會隨之關閉。

確認整個 cluster 正常後，才移除 emergency admin：

```bash
ceph auth rm client.admin-backup
```

再次：

```bash
ceph -s
ceph health detail
```

## 16. 不要做的事情

```text
✗ daemon/client 尚未完成遷移就關閉 aes
✗ 同時 restart 多個 MON/OSD
✗ OSD rotate 後忘記 BlueStore osd_key label
✗ 把 keyring 用 cat 貼到 ticket、聊天室或 GitHub
✗ 為了清 warning 強制 wipe rotating service keys
✗ client.admin 未建立 emergency credential 就直接 rotate
✗ 看到 ceph-crash startup ping error 就放寬 /etc/pve/priv 權限
```

## 17. 每一步的安全驗證原則

建議反覆使用：

```bash
ceph -s
ceph health detail
ceph quorum_status
ceph osd tree
ceph fs status
```

關鍵檔案只比較 hash：

```bash
sha256sum FILE1 FILE2
```

不要輸出 credential 本體。

## 18. 結論

Ceph 20.2.4 升級後的 CephX warnings 是安全 migration 訊號，不代表叢集已故障。本次三節點 PVE/Ceph 叢集採逐 daemon、逐 client 的方式完成 AES → AES256K credential rotation，並在每一階段維持 MON quorum、OSD up/in、PG active+clean 與 CephFS healthy。

最重要的原則不是「最快把 HEALTH_WARN 清掉」，而是：

> **先確保所有真正使用中的 credential 都已安全換成 AES256K，再關閉舊 AES。**

## 官方文件

- Ceph CVE-2025-30156：<https://docs.ceph.com/en/latest/security/CVE-2025-30156/>
- Ceph Tentacle 20.2.4 Release Notes：<https://docs.ceph.com/en/latest/releases/tentacle/>
- CephX Config Reference / Upgrading and Rotating CephX Keys：<https://docs.ceph.com/en/tentacle/rados/configuration/auth-config-ref/>
- Ceph Health Checks：<https://docs.ceph.com/en/latest/rados/operations/health-checks/>
- Ceph Manual Deployment / bootstrap credentials：<https://docs.ceph.com/en/tentacle/install/manual-deployment/>
