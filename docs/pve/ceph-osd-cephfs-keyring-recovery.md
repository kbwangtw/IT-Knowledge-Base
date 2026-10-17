---
layout: default
title: "PVE 出現問號、儲存變成 0：這次怎麼救回來？"
date: 2026-09-18
last_modified_at: 2026-10-17
categories: [PVE, Ceph, Troubleshooting]
permalink: /docs/pve/ceph-osd-cephfs-keyring-recovery/
---

# PVE 出現問號、儲存變成 0：這次怎麼救回來？

> **一句話**：三台主機都還在線，但三顆 OSD 拿著**錯誤的金鑰**，進不了 Ceph，儲存就變成 0；先把 OSD 金鑰改回 MON 上正確的版本，再修好 CephFS 掛載用的**另一份**金鑰，問號就消失了。

| 項目 | 內容 |
| --- | --- |
| 適合誰看 | PVE 節點出現問號、Ceph 儲存顯示 0 容量、CephFS inactive 的人 |
| 環境 | Ceph 20.2.4-pve4、kernel 7.0.14-16-pve；node10～node12 各一顆 OSD |
| 事件日期 | 2026-09-17～18（UTC+8） |
| 結果 | ✅ 3 up／3 in、HEALTH_OK、97 PG active+clean；三台 RBD、CephFS、PBS storage 都 active；問號消失 |
| 後續 | ✅ 9/22 已查明根因並修正 BlueStore 裡的金鑰（見[9/22 紀錄](https://kbwangtw.github.io/IT-Knowledge-Base/docs/pve/ceph-bluestore-osd-key-recovery-2026-09-22/)）；⏳ 手動備份與還原測試另外驗證 |

> 本文依實際終端輸出整理；未公開 IP、FSID、金鑰、完整 UPID 或原始截圖。node10～node12 與 OSD 編號保留作為對照。本文記錄的是本次服務恢復，不代表已完成重開機持久性或所有應用程式的還原測試。

## 1. 先認識幾個名詞

| 名詞 | 白話解釋 | 本案狀況 |
| --- | --- | --- |
| **PVE／Corosync quorum** | 主機之間確認「誰還在線」、能不能一起管理叢集 | 三台仍有 quorum |
| **Ceph MON** | Ceph 的「管理處」，保存叢集狀態和**正確的金鑰** | 三個 MON 有 quorum，管理指令可用 |
| **OSD** | 實際存放、讀寫資料的服務，一顆硬碟一個 | 一度 0 up，儲存不能用 |
| **MDS** | 管理 CephFS 的目錄與檔案資訊 | 復原後 active；但用戶端仍可能掛載失敗 |
| **keyring／secret** | 服務或用戶端登入 Ceph 的金鑰檔；keyring 是完整格式，secret 是只有金鑰的純文字 | 多個副本格式錯誤或內容不一致 |
| **PG** | Ceph 分配與維護資料副本的單位 | 從 inactive／unknown 恢復成 active+clean |
| **D state** | 程式卡在「不可中斷」的核心 I/O 等待，連 kill 都殺不掉 | 曾在 LXC 備份的 RBD 掛載程序看到 |

### 主機還在線，為什麼資料卻讀不到？

可以把叢集想成三間還能互相通話的倉庫。管理系統知道倉庫都在，但負責搬貨的服務拿著**錯誤的通行證**，所以進不去。這就是「quorum 正常，儲存卻不能用」。

- 本次 MON 裡的金鑰是好的，出問題的是**服務端和掛載端手上的副本**。修法是「核對後改回正確內容」，**不是**再產生一套新金鑰。
- 沒有證據顯示三顆硬碟同時壞掉；畫面容量 0 也**不代表**資料被刪除。

## 2. 故障全貌：兩段問題

```text
第一段：三顆 OSD 的金鑰不對
  → OSD 0 up，97 PG inactive，RBD 顯示 0 容量
  → 修法：從 MON 匯出正確金鑰，逐顆替換、啟動（第 4～5 節）

第二段：CephFS 掛載用的 secretfile 不對
  → OSD 都好了，CephFS 還是 inactive
  → 修法：把 MON 的 client.admin 金鑰寫進 secretfile（第 6 節）
```

## 3. 一開始看到什麼

- PVE 節點出現問號，但 Ping 和管理網頁都還連得上。
- Ceph 顯示 3 顆 OSD、**0 顆 up**，97 個 PG inactive／unknown。
- RBD 儲存顯示 0 容量，CephFS inactive。
- 較早的 CephFS 查詢曾出現「可以 `ls`，但 `df`／statfs timeout」。
- 備份工作長時間沒結束；曾看到 LXC 備份的 RBD 掛載程序處於 D state。
- kernel 日誌出現 `CephX authentication failed -13`（-13 就是「權限被拒」）。

當時雖然有較新的 kernel，本次恢復**沒有**用「更新 kernel、再重開三台或重新輪替金鑰」來處理。

> **叢集投票正常，只能證明管理層還在運作，不能證明資料儲存正常。**

## 4. 步驟一：先讀日誌，找出每顆 OSD 為什麼起不來

**做什麼**：不要急著重建 OSD，先看每顆 OSD 的 journal。

| 節點／OSD | 9/17 停止時間 | 重開後第一次失敗 | 已確認原因 |
| --- | --- | --- | --- |
| node12／osd.2 | 17:09:28 | 17:11:18 | key 欄位填成另一個檔案的**路徑** |
| node11／osd.1 | 17:11:40 | 17:13:32 | 本機金鑰和 MON 上的金鑰**不同** |
| node10／osd.0 | 17:15:14 | 17:20:16 | key 欄位填成另一個檔案的**路徑** |

三份日誌都有 systemd 發出停止訊號，接著出現新的 Boot 記錄。所以是**三台依序停止、重開後沒能上線**，不是三顆 OSD 同一瞬間一起壞。日誌本身沒有證明是誰、哪個操作發起重開。

### node10、node12：拿檔案路徑當金鑰

關鍵錯誤（已省略時間與程序識別資訊）：

```text
error parsing file .../keyring
type=key val=/root/ceph-key-migration/osd.ID.new.keyring
Malformed input
```

**白話**：key 欄位要放的是**編碼後的金鑰內容**。填入檔案路徑，就像把「鑰匙放在抽屜裡」這張紙條拿去開門，門鎖不會替你去抽屜拿鑰匙。（[ceph-authtool 說明](https://docs.ceph.com/en/latest/man/8/ceph-authtool/)）

後面接著的 `Key loading failed`、`failed to fetch mon config` 是連帶錯誤。這裡的 `Input/output error` 出現在金鑰載入失敗的脈絡中，**不能單憑這句就判斷硬碟壞了**。

### node11：檔案讀得到，但金鑰對不上

node11 沒有格式錯誤，而是：

```text
handle_auth_bad_method failed to auth with my available methods:
(13) Permission denied
```

光看這句還不能斷定是金鑰不同。本案另外讀取本機 osd.1 keyring 和 MON 上的 osd.1 金鑰，**在記憶體內比對**，只輸出結果：

```text
KEY_MISMATCH
```

再確認 MON 能提供三顆 OSD 的現有金鑰，才開始修復。這和「再產生一組新金鑰」是不同的操作。

## 5. 步驟二：備份 → 比對 → 替換 → 逐顆啟動

**做什麼**：每台經過核准後，依序處理 node11、node12、node10，**一顆好了才做下一顆**。

**怎麼做**（每顆 OSD 都一樣）：

1. 確認所在主機與 OSD 編號，檢查服務還沒在跑。
2. 在 root 專用目錄**備份**原本的 keyring。
3. 從 MON 匯出該 OSD 的完整 keyring。
4. 用 `ceph-authtool` 解析金鑰，再和 MON 重新讀到的值**比對**。
5. 驗證通過才替換本機檔案，權限設成 `ceph:ceph`、`0600`。
6. 清除 systemd 的失敗狀態，啟動這顆 OSD。
7. 看服務日誌、`ceph -s`、`ceph osd tree`，確認正常再處理下一台。

> `ceph:ceph`／`0600` 是**本機 OSD 檔案**的處理方式，不能直接套到 `/etc/pve`（pmxcfs）裡的共享檔案。

**看到的結果**（9/18）：

| 時間 | 已驗證進展 |
| --- | --- |
| 08:43:43 | osd.1 啟動，確認 1 up |
| 08:45:30 | osd.2 啟動，確認 2 up |
| 08:47:04 | osd.0 啟動，確認 3 up／3 in |
| 約 08:48 | HEALTH_OK；97 個 PG 都是 active+clean，部分正在 scrub |
| 後續檢查 | 97 active+clean，CephFS 叢集端 healthy |

osd.0 原本是 down、REWEIGHT 0；啟動後自己回報 up、REWEIGHT 1、3 in。本次**沒有**手動執行 `osd in`，也沒有改權重。

**本次沒做的事**：沒有 destroy／recreate OSD、沒有格式化磁碟、沒有修改 MON 上的金鑰、沒有強制殺 D-state 程序，也沒有為了恢復再重開主機。

## 6. 步驟三：Ceph 好了，還要查 CephFS 掛載端

**做什麼**：OSD 恢復後 RBD 正常了，但 CephFS 還是 inactive。這是**另一份金鑰副本**的問題。

**現象互相矛盾**：掛載日誌說

```text
no mds (Metadata Server) is up.
The cluster might be laggy, or you may not be authorized
```

但 `ceph fs status` 顯示 rank 0 active、還有兩個 standby；kernel 則一直回報：

```text
auth protocol 'cephx' mauth authentication failed: -13
```

MDS 明明是好的，所以**沒有**去重啟 MDS，而是讀 systemd mount unit 的掛載參數，確認本案使用：

```text
name=admin
secretfile=/etc/pve/priv/ceph/cephfs.secret
conf=/etc/pve/ceph.conf
fs=cephfs
```

> **`ceph -s` 能成功，不代表掛載用的 secretfile 也正確。** 掛載可以指定自己的金鑰來源。（[mount.ceph 說明](https://docs.ceph.com/en/reef/man/8/mount.ceph/)）

**怎麼修**：

1. 把 `cephfs.secret` 和 MON 的 `client.admin` 金鑰比對 → 結果 `CEPHFS_KEY_MISMATCH`。
2. 經核准後，備份原檔。
3. 匯出並驗證 MON 現有金鑰，把**純金鑰文字**寫進 secretfile。
4. 重試 node10 掛載。

> ⚠️ 完整 keyring 和純 secret 檔格式不同，**不能互相替代**。

這份檔案在 `/etc/pve` 的共享設定裡，所以**只更新一次**，再到每台分別驗證；沒有放寬共享目錄權限。其他環境如果用專用的 CephFS client，要同步它自己的金鑰，不能一律改成 admin。（[pmxcfs 說明](https://github.com/proxmox/pve-docs/blob/master/pmxcfs.adoc)）

**看到的結果**：08:57:26，node10 回報 `active (mounted)`，`findmnt` 確認 FSTYPE 是 `ceph`，`df` 正常回報容量。之後三台都確認 CephFS active。

### 為什麼只看 df 還不夠？

沒掛載時，`df /mnt/pve/cephfs` 仍可能顯示**本機根目錄**的容量。這只代表那個目錄所在的本機磁碟可用，不代表 CephFS 可用。所以要用 `findmnt` 一起核對掛載點、來源和 FSTYPE。

## 7. 備份有沒有成功：看對工作、看完最後一行

本案某筆批次備份長時間沒結束，但 Ceph 恢復後，有 VM 備份接著完成。

- 其中一台 VM 的日誌最後顯示 60 GiB 傳輸完成，接著出現 `Finished Backup`，查備份鎖也沒有 lock 欄位。
- 整批任務仍是 `job errors`。所以**不能**說這台 VM 備份失敗；反過來，也**不能**因為一台完成就說整批成功。
- 本案曾拿到一份明確「跳過目標 VM」的日誌。排查前一定要核對**節點、UPID、VM 編號**，避免分析錯工作。
- `prelaunch` 或 `lock: backup` 本身不等於卡死：備份可能會啟動 QEMU 來讀取原本關機 VM 的磁碟。

本次**沒有**手動 unlock 該 VM，也沒有強制啟動它。使用者決定系統恢復後再做一次手動備份；那次新備份和還原測試**不列入**本案已驗證結果。較早的 LXC D-state 備份沒有取得完整結案日誌，**不記為備份成功**。

## 8. 下次遇到同樣畫面，照這個順序查

以下用本案名稱示範，先換成自己的節點、OSD ID、儲存 ID 和 mount unit。日誌可能含敏感內容，分享前要去敏感化。

```bash
# 叢集與 OSD：只讀取狀態
timeout 15 ceph -s
timeout 15 ceph health detail
timeout 15 ceph osd tree
systemctl status ceph-osd@0 --no-pager -l
journalctl -u ceph-osd@0 --since "30 minutes ago" --no-pager -n 100

# CephFS：確認 MDS 與實際掛載
timeout 15 ceph fs status
systemctl status mnt-pve-cephfs.mount --no-pager -l
findmnt --mountpoint /mnt/pve/cephfs -o TARGET,SOURCE,FSTYPE
timeout 10 df -h /mnt/pve/cephfs
```

| 指令 | 用途 |
| --- | --- |
| `timeout 15 …` | 最多等 15 秒，避免指令卡住不回來 |
| `ceph health detail` | 列出每個警告的細節 |
| `journalctl -u ceph-osd@0` | 看這顆 OSD 的服務日誌，金鑰錯誤會出現在這裡 |
| `findmnt` | 確認是不是真的掛上 Ceph（FSTYPE 要是 `ceph`） |

`pvesm status` 可以看 PVE 的整合狀態，但本案實際觀察到它**可能觸發**未掛載 storage 的掛載嘗試，所以不能當成完全沒副作用的純讀取：

```bash
timeout 15 pvesm status
```

> `timeout` 能限制一般查詢的等待時間，但**殺不掉**卡在 D state 的程序。不要反覆執行，製造更多卡住的查詢。

### 不顯示金鑰的比對範例

以下針對本案 CephFS 的「純 secret 檔」，**不適用**完整 keyring。先確認 mount options 的帳號與檔案路徑正確。

```bash
(
set +x
set -eu
local_key=$(cat /etc/pve/priv/ceph/cephfs.secret)
mon_key=$(timeout 15 ceph auth get-key client.admin 2>/dev/null)
[ -n "$local_key" ] && [ -n "$mon_key" ] || {
    printf 'KEY_READ_FAILED\n'
    exit 1
}
if [ "$local_key" = "$mon_key" ]; then
    printf 'KEY_MATCH\n'
else
    printf 'KEY_MISMATCH\n'
fi
)
```

**這段在做什麼**：

- 外層 `( … )` 在子 shell 執行，變數不會留在你的終端機。
- `set +x` 確保不會把指令（含金鑰）印出來；`set -eu` 遇到錯誤就停。
- 兩邊金鑰都讀進變數，只印 `KEY_MATCH`／`KEY_MISMATCH`，**金鑰本身不會出現在畫面上**。

文字不一致時，仍要排除檔案格式或多餘字元；本案另外有「認證失敗」和「替換後掛載成功」的證據。**不要把金鑰貼到聊天、issue 或公開紀錄。**

## 9. 最後驗收：叢集、實際掛載、管理畫面都要查

| 層級 | 本案最終證據 |
| --- | --- |
| Ceph 叢集 | HEALTH_OK、3 up／3 in、97 active+clean |
| PVE 儲存 | 三台 RBD、CephFS、PBS storage 全部 active |
| CephFS 實際掛載 | 三台 `findmnt` 都是 ceph，node10 容量查詢正常 |
| 管理畫面 | 使用者確認節點問號消失 |
| 備份 | 目標 VM 的個別完成日誌已確認；整批有錯誤，後續手動備份另外執行 |

> HEALTH_OK 是叢集健康的證據，**不等於**所有 VM 的應用程式資料都做過還原驗證。

## 10. 根因：9/18 沒查到的，9/22 補上了

**9/18 當時的證據邊界**：

整理文章時，在既有的 [CephX 遷移紀錄](https://github.com/kbwangtw/IT-Knowledge-Base/blob/main/docs/pve/ceph-20-2-4-cephx-aes256k-migration.md) 發現，舊範例把 keyring **檔案路徑**當成 BlueStore `set-label-key` 的 `-v` 值。官方文件說明 `-v` 是「要存的值」，不是「去讀這個檔案」。這個舊範例已撤下並標示更正。（[ceph-bluestore-tool 參數說明](https://docs.ceph.com/en/latest/man/8/ceph-bluestore-tool/)）

它和本案「key 欄位變成路徑」的錯誤形態相符，但 9/18 沒有取得實際 BlueStore label、ceph-volume 啟用過程或完整操作歷史，當時**不能**認定舊指令已執行，或宣布它就是肇因。9/18 也沒有寫入 label，沒有做重開機驗證。

9/18 的結論分成兩句：

- **已證實且修復**：本機 OSD 金鑰的格式／內容問題，以及 CephFS 掛載金鑰不一致。
- **尚未證實**：最早造成金鑰變更的操作，以及磁碟上保存的金鑰是否也要修。

**9/22 的後續**：已確認 9/14 的 `set-label-key -v` 路徑誤用，讓 osd.0／osd.2 的 label 存成路徑，osd.1 則存了和 MON／本機不同的金鑰。逐顆停止後用正確的本機金鑰修正，三顆都達到 MON = LOCAL = BLUESTORE；最後 unset noout、HEALTH_OK、3 up／3 in、97 PG active+clean。完整流程見 [9/22 紀錄](https://kbwangtw.github.io/IT-Knowledge-Base/docs/pve/ceph-bluestore-osd-key-recovery-2026-09-22/)。

## 11. 常見問題

| 現象 | 怎麼辦 |
| --- | --- |
| quorum 正常，但儲存 0 容量 | 管理層正常 ≠ 儲存正常；先看 `ceph osd tree` 有幾顆 up |
| OSD 起不來 | 先讀 journal，**不要**因為容量 0 就重建 OSD |
| 日誌有 `Input/output error` | 先看前後文；本案是金鑰載入失敗，不是硬碟壞 |
| `ceph -s` 正常，CephFS 掛不上 | 查 mount unit 用的 secretfile，它是**另一份**金鑰 |
| `df` 有顯示容量 | 可能是本機根目錄的容量；用 `findmnt` 確認 FSTYPE 是 `ceph` |
| 備份顯示 `job errors` | 看每台 VM 的個別日誌最後一行；核對節點、UPID、VM 編號 |
| 指令卡住不回來 | D state 殺不掉，不要重複執行；加 `timeout` 限制一般查詢 |

## 12. 把這次經驗變成下次的檢查表

1. 每次換金鑰，都盤點**真正在用的副本**：daemon、RBD storage、CephFS secretfile，不能只測管理 CLI。
2. 一台停機後沒恢復，先**停下來**，不要處理下一台。
3. OSD 起不來先讀 journal，不因容量 0 就重建 OSD。
4. 先備份、再驗證、再替換；MON 上的金鑰有效時，不要為了排障再 rotate 一次。
5. 服務恢復後，完成各節點儲存驗證，再做備份與還原測試。
6. 備份下來的舊金鑰檔只做追查用途，限制存取；它不一定還有效，也不是通用的修復方案。

> 這次的診斷順序：**先看叢集與日誌 → 比對實際使用的金鑰 → 逐顆恢復 → 逐層驗收**。看到容量 0、掛載失敗或備份卡住時，先查清楚故障在哪一層，才能選對修法。

## 13. 延伸閱讀

- [PVE 重開後 Ceph 又故障：修正 BlueStore 裡的 OSD 金鑰（9/22）](https://kbwangtw.github.io/IT-Knowledge-Base/docs/pve/ceph-bluestore-osd-key-recovery-2026-09-22/)
- [Ceph 20.2.4 CephX AES256k 遷移紀錄](https://kbwangtw.github.io/IT-Knowledge-Base/docs/pve/ceph-20-2-4-cephx-aes256k-migration/)
- [Ceph 官方：ceph-authtool](https://docs.ceph.com/en/latest/man/8/ceph-authtool/)
- [Ceph 官方：mount.ceph](https://docs.ceph.com/en/reef/man/8/mount.ceph/)
