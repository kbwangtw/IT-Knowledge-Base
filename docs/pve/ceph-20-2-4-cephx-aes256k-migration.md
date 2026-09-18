---
layout: default
title: "Ceph 換金鑰：為什麼 HEALTH_OK 還不夠？"
date: 2026-09-14
last_modified_at: 2026-09-18
categories: [PVE, Ceph, Security]
---

# Ceph 換金鑰：為什麼 HEALTH_OK 還不夠？

這篇記錄 Ceph 20.2.4 的 CephX 金鑰遷移，以及後來發現的漏項。最重要的經驗是：**MON 接受新金鑰，不代表每個 OSD、PVE storage 和 CephFS 掛載都已拿到同一份有效副本。**

這是一份有後續更正的歷史紀錄，不是一套可直接貼上執行的遷移腳本。尤其 OSD 的持久化金鑰來源與重開驗證還沒完成，不能以目前 HEALTH_OK 宣告全部結案。

## 先看三個日期，避免把結果混在一起

| 日期 | 發生什麼 | 當時能確認到哪裡 |
| --- | --- | --- |
| 2026-09-14 | 遷移至 AES256K-only | Ceph 健康、三台管理 CLI 可用；漏驗 storage 副本 |
| 2026-09-15 | PVE RBD 仍用舊 key，備份失敗 | 同步 VM_Pool.keyring 後，三台 active，VM／LXC 備份通過 |
| 2026-09-17～18 | 重開後三顆 OSD 未上線，CephFS 也有金鑰差異 | 修復本機 OSD keyring 與 CephFS secret 後服務恢復；label 持久性待查 |

第三段的完整證據在[OSD／CephFS 復原紀錄](https://kbwangtw.github.io/IT-Knowledge-Base/docs/pve/ceph-osd-cephfs-keyring-recovery/)。不能把 9/15 的備份成功當成 9/18 事故後已重新測過所有備份。

## 為什麼升級後開始提醒換金鑰？

本次 Ceph 20.2.4 升級後出現多個 AUTH_INSECURE 類警告，涉及舊 CephX credential 與 ticket。依當時官方安全公告與遷移文件，這與 CVE-2025-30156 及新的 aes256k 類型有關。

可以把 CephX 想成服務之間驗證身分的機制。警告的意思是仍有舊類型憑證或相容設定待處理，不能只因看到 HEALTH_WARN 就認定磁碟壞了。

| 名稱 | 在控制什麼 |
| --- | --- |
| auth_preferred_cipher | 優先使用的類型 |
| auth_service_cipher | 服務票證使用的類型 |
| auth_allowed_ciphers | 目前接受的類型 |

舊服務或 client 還没準備好就停用 aes，可能失去認證能力。實際遷移應先查自己版本的官方流程與 migration helper，不能只從本文擷取幾條歷史命令。

## 本案環境

三台 PVE 9.2.x：node10、node11、node12，Ceph 20.2.4 Tentacle。MON 3 個、MGR 1 active／2 standby、MDS 1 active／2 standby、OSD 3 顆、4 個 pools、97 個 PG、一個 CephFS。

操作時的健康基線是 MON quorum 完整、OSD 3 up／3 in、PG active+clean、CephFS healthy。一個服務處理後未回復，就應停止往下一個推進。

## 當時遷移做了哪些事？

本案採逐項處理的方式：

1. 過渡期保留 aes 與 aes256k，先調整偏好。
2. 依序處理 MON、MGR、MDS、OSD 的憑證。
3. 服務憑證準備好後，切換 service cipher。
4. 等待舊 rotating service keys 自然過期。
5. 處理 bootstrap clients、client.crash，最後才處理 client.admin。
6. 切換成僅接受 aes256k，檢查叢集與管理 CLI。

回頭看，第 5、6 步之間少了完整的 consumer 盤點。修訂後必須把實際使用金鑰的 storage、CephFS 掛載與 OSD 啟用來源列入，逐一驗證後才能停用舊類型。

### 為什麼要一次一個？

MON 需要 quorum，MDS 有 active／standby，OSD 掌管資料。本案採一次處理一個服務、每次查狀態的方式；不能同時停掉多個服務，再期待最後一起恢復。

MGR／MDS／OSD 的本機 keyring 位於各自的 /var/lib/ceph 目錄；/etc/pve 裡的檔案則由 pmxcfs 管理。兩類位置的同步與權限方式不同，不能套用同一組複製和 chmod 流程。

### 舊 rotating keys 不一定立刻消失

本次查到 auth_service_ticket_ttl 為 3600 秒，但這不是「一小時整必定清除所有 warning」的保證。

9/14 14:48 還看得到 MON、MDS、OSD、MGR 的舊 rotating keys，16:25 再查時警告自然消失。本案沒有為此強制 wipe，也沒有為了清警告重啟整個叢集。

## 最容易漏掉的金鑰位置

| 使用者／服務 | 本案需要注意的位置或行為 |
| --- | --- |
| 管理 CLI | /etc/pve/priv/ceph.client.admin.keyring、/etc/ceph/ceph.client.admin.keyring |
| PVE RBD storage | /etc/pve/priv/ceph/&lt;STORAGE_ID&gt;.keyring |
| CephFS 掛載 | mount options 真正指定的 secretfile |
| OSD | 本機 keyring，以及實際部署的持久化／啟用來源 |
| bootstrap-osd | /var/lib/ceph/bootstrap-osd/ceph.keyring |
| client.crash | /etc/pve/ceph/ceph.client.crash.keyring |

本次其他 bootstrap 目錄未找到實際 keyring，因此只保護新憑證，沒有憑空建立使用位置。表中的 admin 只是本案身分，其他環境若用專用 client，必須保留對應身分與權限。

Shared storage 設定中的 STORAGE_ID 也不一定等於 pool 名稱；本案兩者剛好都叫 VM_Pool。

## 9/15 的教訓：管理指令正常，RBD 備份卻失敗

當時 ceph -s 為 HEALTH_OK，一般 rbd ls 能列出磁碟，VM 也仍在運作；但 PVE 的 VM_Pool inactive，VM104 與 CT100 的 PBS 備份失敗。

固定同一個 client 和 pool，只換 keyring 路徑：

~~~bash
rbd --id admin --keyring /etc/pve/priv/ceph/VM_Pool.keyring -p VM_Pool ls
rbd --id admin --keyring /etc/ceph/ceph.client.admin.keyring -p VM_Pool ls
~~~

第一條認證失敗，第二條成功；再比較實際 key 值，確認 storage 副本仍是舊的。這才定位到問題，不能只靠 handle_auth_bad_method 就說一定是 cipher 不相容。

### 比較 key 值，不把 key 貼出來

以下只適用已確認這些路徑與 client.admin 正確的案例；任何讀取失敗都停止：

~~~bash
(
  set +x
  set -eu
  local_key=$(timeout 10 ceph-authtool /etc/ceph/ceph.client.admin.keyring -n client.admin --print-key)
  db_key=$(timeout 15 ceph -n client.admin -k /etc/ceph/ceph.client.admin.keyring auth get-key client.admin)
  storage_key=$(timeout 10 ceph-authtool /etc/pve/priv/ceph/VM_Pool.keyring -n client.admin --print-key)
  test -n "$local_key" && test -n "$db_key" && test -n "$storage_key"
  if [ "$local_key" = "$db_key" ]; then
    printf 'LOCAL_DB_MATCH\n'
  else
    printf 'LOCAL_DB_MISMATCH\n'
  fi
  if [ "$storage_key" = "$db_key" ]; then
    printf 'STORAGE_DB_MATCH\n'
  else
    printf 'STORAGE_DB_MISMATCH\n'
  fi
)
~~~

整份 keyring 的雜湊不同，也可能只是空白或 caps 排序不同；判斷金鑰要比較解析後的 key 值。不要公開 secret 或完整認證匯出。

### 當時怎麼修？

先確認有效來源與 MON 相符，且指定該來源可使用 RBD，再備份舊 storage keyring，將有效內容同步到共享檔案。正常 quorum 下共享位置只更新一次，但三個節點都分別驗證。

本次沒有再次 rotate，也沒有放寬 /etc/pve/priv。舊金鑰備份是追查資料；MON 已不接受舊 key 時，單純把舊檔放回去不會恢復認證。

9/15 驗證結果：

| 路徑 | 結果 |
| --- | --- |
| 三台 VM_Pool | active |
| 指定 storage keyring 的 RBD 列表 | 成功 |
| VM104 → PBS31 | TASK OK |
| CT100 → RBD snapshot → PBS31 | snapshot 建立、上傳、清除與 TASK OK |

CT100 處理 3.124 GiB，重用 2.905 GiB（93.0%）。這個比例不是成功判準，仍要看最後完成與暫存 snapshot 清理。

## client.crash 的 Permission denied，不要直接靠放寬權限解決

本案 ceph-crash 啟動 ping 曾嘗試一般 ceph -s，落到 admin keyring 而遭拒。當時檢查部署中的腳本後，發現真正的 crash 上傳另有認證嘗試流程。

也確認 client.crash 的 keyring 路徑與原有 profile crash 權限：

~~~bash
ceph-conf -n client.crash --lookup keyring
~~~

這是本案版本的排查結果，不代表所有 Permission denied 都可以忽略。先辨別哪個階段、哪個身分失敗，不要把 admin 私密目錄開放給其他帳號。

## 9/18 更正：BlueStore 的 -v 不是讀取檔案

舊文章曾把 keyring 檔案路徑當成 set-label-key 的 -v 值。**這段範例已撤下，不應沿用。** 官方工具說明中的 -v 是要儲存的值，不會替你讀取那個檔案並抽出金鑰。

9/17～18 事故中，node10、node12 的 key 欄位確實出現路徑而非金鑰；node11 則是本機 key 與 MON 不同。這與舊範例的錯誤形態相符，但沒有取得完整操作歷史和實際 label，不能直接宣布原始肇因已證實。

這次只修復本機 OSD keyring，**未查驗或寫入 BlueStore label，未做重開持久性測試**。後續必須核對實際裝置、版本、label 的 osd_key 與 ceph-volume 啟用流程，避免下次啟用又帶回錯誤內容。

完整 label 可能含 secret，應只在本機受控環境比較。若需修改，另安排單顆 OSD 維護與備份；這裡不提供未經本環境驗證的通用寫入命令。

## emergency admin 應該保留到什麼時候？

本次曾建立並測試緊急管理憑證，避免處理 client.admin 時失去管理入口。但原紀錄只驗證三台 CLI 就移除，結案條件不足。

今後應先完成各節點管理、實際 storage、CephFS、新連線、VM／LXC 備份及必要還原驗證，再按維護計畫移除臨時權限。緊急憑證本身也需要受控保存與清理。

## 現在的狀態，分兩層看

9/14 曾取得下列設定與叢集結果：

~~~text
auth_service_cipher   aes256k
auth_allowed_ciphers  aes256k
auth_preferred_cipher aes256k
HEALTH_OK
OSD 3 up / 3 in
PG 97 active+clean
~~~

9/18 再次恢復服務，三台 storage 正常，PVE 問號消失。這些支持目前服務恢復，卻不取代持久化金鑰、重開、新備份與應用還原驗證。

下次維護的檢查重點是：盤點所有副本、只更動確認的對象、逐個驗證、出錯即停，以及保留可追溯結果。不要只為了讓 HEALTH_WARN 消失而加快切換。

## 官方文件與後續紀錄

- [Proxmox CephX migration](https://pve.proxmox.com/pve-docs/chapter-pveceph.html#pveceph_cephx_migration)
- [Ceph CVE-2025-30156](https://docs.ceph.com/en/latest/security/CVE-2025-30156/)
- [Ceph 20.2.4 所屬 Tentacle 發行紀錄](https://docs.ceph.com/en/latest/releases/tentacle/)
- [CephX 設定與輪替說明](https://docs.ceph.com/en/tentacle/rados/configuration/auth-config-ref/)
- [BlueStore 工具參數](https://docs.ceph.com/en/latest/man/8/ceph-bluestore-tool/)
- [PVE RBD 認證](https://pve.proxmox.com/pve-docs/pve-storage-rbd-plain.html)
- [pmxcfs 同步與權限](https://github.com/proxmox/pve-docs/blob/master/pmxcfs.adoc)
- [OSD／CephFS 金鑰故障復原](https://kbwangtw.github.io/IT-Knowledge-Base/docs/pve/ceph-osd-cephfs-keyring-recovery/)
