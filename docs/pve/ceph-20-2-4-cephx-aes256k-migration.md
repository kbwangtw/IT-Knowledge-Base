---
layout: default
title: "Ceph 換金鑰：為什麼 HEALTH_OK 還不夠？"
date: 2026-09-14
last_modified_at: 2026-10-17
categories: [PVE, Ceph, Security]
---

# Ceph 換金鑰：為什麼 HEALTH_OK 還不夠？

> **一句話**：Ceph 升級後把舊金鑰換成新類型，叢集顯示 HEALTH_OK，但**其他地方還留著舊金鑰的副本**，結果備份失敗、重開機後硬碟起不來；這篇記錄漏掉了哪些位置，以及教訓。

| 項目 | 內容 |
| --- | --- |
| 適合誰看 | 要做 Ceph 金鑰遷移或輪換的人；想理解「健康不等於全部正常」的人 |
| 環境 | 三台 PVE 9.2.x（node10～12），Ceph 20.2.4 Tentacle |
| 性質 | 有後續更正的**歷史紀錄**，不是可以直接貼上執行的遷移腳本 |
| 目前狀態 | 9/22 已修好 BlueStore 裡的金鑰，三顆 OSD 三層一致、HEALTH_OK；10/12 修復後整機重開驗證正常 |

> 9/22 的根因與修復見 [BlueStore 金鑰修復紀錄](https://kbwangtw.github.io/IT-Knowledge-Base/docs/pve/ceph-bluestore-osd-key-recovery-2026-09-22/)。下文保留 9/14～18 當時的紀錄。

## 1. 先認識幾個名詞

| 名詞 | 白話解釋 |
| --- | --- |
| **Ceph** | 三台 PVE 共用的分散式儲存 |
| **CephX** | Ceph 各服務之間「互相驗證身分」的機制，靠金鑰（key） |
| **keyring** | 存放金鑰的檔案 |
| **MON／MGR／MDS／OSD** | Ceph 的四種服務：監視器（管叢集狀態）、管理員、CephFS 中繼資料、實際存資料的硬碟服務 |
| **cipher（aes／aes256k）** | 金鑰的加密類型；aes256k 是新的、比較安全的類型 |
| **BlueStore label** | OSD 硬碟上記錄的身分資訊，開機時用來啟動 OSD |
| **consumer** | 實際「使用」金鑰的地方（PVE storage、CephFS 掛載、OSD…） |
| **HEALTH_OK** | Ceph 自認健康；但它只代表 Ceph 內部，不保證外部使用者都正常 |

## 2. 事件時間軸

| 日期 | 發生什麼 | 當時確認到哪裡 |
| --- | --- | --- |
| 2026-09-14 | 遷移到「只接受 aes256k」 | Ceph 健康、三台管理指令可用；**漏驗 storage 副本** |
| 2026-09-15 | PVE 的 RBD storage 仍用舊金鑰，備份失敗 | 同步 VM_Pool.keyring 後三台 active，VM／LXC 備份通過 |
| 2026-09-17～18 | 重開後三顆 OSD 起不來，CephFS 也有金鑰差異 | 修好本機 OSD keyring 與 CephFS secret 後恢復；label 是否持久待查 |
| 2026-09-21～22 | 重開再次觸發故障，查明並修復 BlueStore osd_key | osd.0／2 存成「檔案路徑」，osd.1 與 MON／local 不同；三顆修正後三層一致，HEALTH_OK |

第三段的完整證據在 [OSD／CephFS 復原紀錄](https://kbwangtw.github.io/IT-Knowledge-Base/docs/pve/ceph-osd-cephfs-keyring-recovery/)。

> 9/15 的備份成功，**不代表** 9/18 事故後所有備份都重新測過。

## 3. 為什麼升級後要換金鑰？

Ceph 20.2.4 升級後出現多個 `AUTH_INSECURE` 類警告，涉及舊的 CephX 憑證與 ticket。依當時官方安全公告，這和 **CVE-2025-30156** 以及新的 aes256k 類型有關。

> 這類 HEALTH_WARN 的意思是「還有舊類型的憑證或相容設定待處理」，**不是**磁碟壞了。

三個相關設定：

| 設定 | 控制什麼 |
| --- | --- |
| `auth_preferred_cipher` | 優先使用的類型 |
| `auth_service_cipher` | 服務票證使用的類型 |
| `auth_allowed_ciphers` | 目前接受哪些類型 |

> ⚠️ 舊的服務或 client 還沒準備好就停用 aes，可能**失去認證能力**。實際遷移要先查你版本的官方流程與 migration helper，不能只從本文擷取幾條歷史指令。

## 4. 環境與健康基線

三台 PVE 9.2.x，Ceph 20.2.4：MON 3 個、MGR 1 active／2 standby、MDS 1 active／2 standby、OSD 3 顆、4 個 pool、97 個 PG、一個 CephFS。

**健康基線**：MON quorum 完整、OSD 3 up／3 in、PG active+clean、CephFS healthy。**一個服務處理完沒恢復，就停止，不要往下一個推進。**

## 5. 當時的遷移步驟

1. 過渡期同時保留 aes 與 aes256k，先調整偏好
2. 依序處理 MON、MGR、MDS、OSD 的憑證
3. 服務憑證都準備好後，切換 service cipher
4. 等舊的 rotating service keys 自然過期
5. 處理 bootstrap clients、client.crash，最後才處理 client.admin
6. 切換成只接受 aes256k，檢查叢集與管理指令

> **回頭看的漏洞**：第 5、6 步之間少了「完整盤點所有 consumer」。修正後的做法：把實際使用金鑰的 **storage、CephFS 掛載、OSD 啟動來源**都列出來，逐一驗證後才停用舊類型。

**為什麼一次只處理一個服務**：MON 需要 quorum、MDS 有 active／standby、OSD 掌管資料。不能同時停掉多個服務，再期待最後一起恢復。

**兩類金鑰位置不能用同一套方法處理**：MGR／MDS／OSD 的本機 keyring 在各自的 `/var/lib/ceph` 目錄；`/etc/pve` 裡的檔案由 pmxcfs（叢集共用檔案系統）管理。兩者的同步與權限方式不同，不能套用同一組複製和 chmod 流程。

**舊 rotating keys 不一定立刻消失**：`auth_service_ticket_ttl` 是 3600 秒，但這**不保證**一小時整一定清掉所有警告。9/14 14:48 還看得到 MON、MDS、OSD、MGR 的舊 rotating keys，16:25 再查時警告自然消失。本案沒有強制清除，也沒有為了消警告而重啟整個叢集。

## 6. 最容易漏掉的金鑰位置

| 使用者／服務 | 要注意的位置或行為 |
| --- | --- |
| 管理指令（CLI） | `/etc/pve/priv/ceph.client.admin.keyring`、`/etc/ceph/ceph.client.admin.keyring` |
| PVE RBD storage | `/etc/pve/priv/ceph/<STORAGE_ID>.keyring` |
| CephFS 掛載 | mount 選項**真正指定的** secretfile |
| OSD | 本機 keyring，以及 BlueStore 裡持久化的啟動來源 |
| bootstrap-osd | `/var/lib/ceph/bootstrap-osd/ceph.keyring` |
| client.crash | `/etc/pve/ceph/ceph.client.crash.keyring` |

- 其他 bootstrap 目錄沒有找到實際的 keyring，所以只保護新憑證，沒有憑空建立。
- 表中的 admin 是本案的身分；其他環境若用專用 client，要保留對應的身分與權限。
- STORAGE_ID 不一定等於 pool 名稱；本案兩者剛好都叫 VM_Pool。

## 7. 9/15 的教訓：管理指令正常，備份卻失敗

**現象**：`ceph -s` 是 HEALTH_OK，`rbd ls` 列得出磁碟，VM 也在跑；但 PVE 的 VM_Pool 是 **inactive**，VM104 與 CT100 的 PBS 備份失敗。

**怎麼定位**：固定同一個 client 和 pool，**只換 keyring 路徑**比較：

```bash
rbd --id admin --keyring /etc/pve/priv/ceph/VM_Pool.keyring -p VM_Pool ls    # 失敗
rbd --id admin --keyring /etc/ceph/ceph.client.admin.keyring -p VM_Pool ls   # 成功
```

第一條認證失敗、第二條成功；再比較實際的 key 值，確認 **storage 那份副本還是舊的**。不能只看到 `handle_auth_bad_method` 就斷定是 cipher 不相容。

### 比較 key 值，而不把 key 印出來

（只適用已確認這些路徑與 client.admin 正確的情況；任何讀取失敗都會停止。）

```bash
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
```

這段只輸出「一不一致」，key 只存在變數裡。整份 keyring 的雜湊不同，也可能只是空白或 caps 排序不同，所以要比較**解析出來的 key 值**。不要公開 secret 或完整的認證匯出。

### 怎麼修

先確認有效來源和 MON 一致、而且能用它存取 RBD，再**備份舊的 storage keyring**，把有效內容同步到共用檔案。正常 quorum 下共用位置只要更新一次，但三台都分別驗證。

- 沒有再次輪換，也沒有放寬 `/etc/pve/priv` 的權限。
- 舊金鑰備份是追查用的；MON 已經不接受舊 key，單純放回舊檔**不會**恢復認證。

**9/15 驗證結果**：

| 路徑 | 結果 |
| --- | --- |
| 三台 VM_Pool | active |
| 指定 storage keyring 的 RBD 列表 | 成功 |
| VM104 → PBS31 | TASK OK |
| CT100 → RBD snapshot → PBS31 | snapshot 建立、上傳、清除，TASK OK |

CT100 處理 3.124 GiB，重用 2.905 GiB（93.0%）。這個比例不是成功判準，要看最後是否完成、暫存 snapshot 是否清掉。

## 8. client.crash 的 Permission denied：不要靠放寬權限解決

ceph-crash 啟動時的 ping 會嘗試一般的 `ceph -s`，用到 admin keyring 而被拒。檢查部署中的腳本後發現，真正的 crash 上傳另有自己的認證流程。也確認了 client.crash 的 keyring 路徑與原有的 `profile crash` 權限：

```bash
ceph-conf -n client.crash --lookup keyring
```

> 這是本案版本的排查結果，**不代表**所有 Permission denied 都可以忽略。先分清楚是哪個階段、哪個身分失敗，不要把 admin 私密目錄開放給其他帳號。

## 9. 9/18 更正：BlueStore 的 `-v` 不是「讀取檔案」

舊文章曾把 keyring **檔案路徑**當成 `set-label-key` 的 `-v` 值。**這段範例已撤下，不要沿用。** 官方工具說明中的 `-v` 是「要儲存的值」，它不會替你讀取那個檔案、抽出金鑰。

- 9/17～18 事故中，node10、node12 的 key 欄位確實是「路徑」而不是金鑰；node11 則是本機 key 與 MON 不同。
- 9/22 查明：osd.0／osd.2 的 BlueStore osd_key 確實存成 keyring 路徑，和 9/14 的錯誤用法吻合；osd.1 的 BlueStore key 與 MON／local 不一致。
- 9/18 只修了本機 OSD keyring，沒有查或寫 BlueStore label。9/22 逐顆停止 OSD，用經 MON 比對一致的 local key 修正 label，再啟動驗證；三顆最終三層一致。

完整 label 可能含 secret，只能在本機受控環境比較。逐顆修復方式與 normalized hash 範例見 [9/22 修復紀錄](https://kbwangtw.github.io/IT-Knowledge-Base/docs/pve/ceph-bluestore-osd-key-recovery-2026-09-22/)。三層已一致時不需要再寫 label。

## 10. 緊急管理憑證要留到什麼時候？

處理 client.admin 時曾建立並測試**緊急管理憑證**，避免失去管理入口。但當時只驗證了三台 CLI 就移除，結案條件不足。

**今後的做法**：先完成各節點管理、實際 storage、CephFS、新連線、VM／LXC 備份與必要的還原驗證，再依維護計畫移除臨時權限。緊急憑證本身也要受控保存與清理。

## 11. 目前狀態

9/14 取得的設定與叢集結果：

```text
auth_service_cipher   aes256k
auth_allowed_ciphers  aes256k
auth_preferred_cipher aes256k
HEALTH_OK
OSD 3 up / 3 in
PG 97 active+clean
```

9/18 恢復服務，三台 storage 正常、PVE 問號消失；9/22 完成持久化金鑰修復與三層一致驗證；10/12 修復後整機重開正常，10/14 完成已曝光的 OSD.1 金鑰輪換（見 9/22 修復紀錄）。

## 12. 下次維護的檢查重點

| 原則 | 說明 |
| --- | --- |
| 先盤點所有副本 | 第 6 節的每個位置都要列出來 |
| 只動確認過的對象 | 不憑空建立、不放寬權限 |
| 逐個驗證 | 管理指令、storage、CephFS、OSD 啟動、備份 |
| 出錯就停 | 一個服務沒恢復，不往下推進 |
| 留下可追溯的結果 | 每一步的輸出都保存 |

不要只為了讓 HEALTH_WARN 消失而加快切換。

## 13. 延伸閱讀

- [Proxmox CephX migration](https://pve.proxmox.com/pve-docs/chapter-pveceph.html#pveceph_cephx_migration)
- [Ceph CVE-2025-30156](https://docs.ceph.com/en/latest/security/CVE-2025-30156/)
- [Ceph Tentacle 發行紀錄](https://docs.ceph.com/en/latest/releases/tentacle/)
- [CephX 設定與輪替說明](https://docs.ceph.com/en/tentacle/rados/configuration/auth-config-ref/)
- [BlueStore 工具參數](https://docs.ceph.com/en/latest/man/8/ceph-bluestore-tool/)
- [PVE RBD 認證](https://pve.proxmox.com/pve-docs/pve-storage-rbd-plain.html)
- [pmxcfs 同步與權限](https://github.com/proxmox/pve-docs/blob/master/pmxcfs.adoc)
- [OSD／CephFS 金鑰故障復原](https://kbwangtw.github.io/IT-Knowledge-Base/docs/pve/ceph-osd-cephfs-keyring-recovery/)
