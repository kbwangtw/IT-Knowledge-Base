---
layout: default
title: "PVE 節點出現問號、Ceph 全部 OSD down：金鑰不一致的排查與復原紀錄"
date: 2026-09-18
last_modified_at: 2026-09-18
categories: [PVE, Ceph, Troubleshooting]
permalink: /docs/pve/ceph-osd-cephfs-keyring-recovery/
---

<div class="kb-hero">
<h1>PVE 節點出現問號、Ceph 全部 OSD down</h1>
<p>用白話記錄一次從「儲存容量變成 0、備份卡住」到三台恢復正常的排查過程：先找到錯誤，再修正金鑰，最後逐層驗證。</p>
<div class="kb-badges"><span class="kb-badge">三節點 PVE</span><span class="kb-badge">CephX</span><span class="kb-badge">CephFS</span><span class="kb-badge">服務已恢復</span></div>
</div>

> 事件日期：2026-09-17～18（UTC+8）。依實際終端輸出整理；未公開 IP、FSID、金鑰、完整 UPID 或原始截圖。node10～node12 與 OSD 編號保留作為案例對照。本文記錄的是本次服務恢復，不代表已完成重開機持久性或所有應用程式的還原測試。

## 先用一句話說明

三台主機還能互相聯絡，但負責儲存資料的 Ceph OSD，在重開後拿不到正確的「通行證」，所以無法上線。OSD 恢復後，又發現 CephFS 掛載使用的另一份通行證仍不正確。把這些本機副本與 MON 現有金鑰同步後，儲存服務恢復，PVE 的問號也消失。

沒有證據顯示這次是三顆硬碟同時損壞；畫面容量為 0，也不能直接當成資料被刪除。

## 這幾個名詞在做什麼？

| 元件 | 白話用途 | 本案狀況 |
| --- | --- | --- |
| PVE／Corosync quorum | 主機之間確認誰還在線、能否共同管理叢集 | 三台仍有 quorum |
| Ceph MON | 維護叢集狀態與認證資料 | 三個 MON 有 quorum，管理指令可用 |
| OSD | 實際存放、讀寫資料的服務 | 一度 0 up，無法提供正常儲存 |
| MDS | 管理 CephFS 的目錄與檔案資訊 | 復原後 active；用戶端仍可能掛載失敗 |
| keyring／secret | 服務或用戶端登入 Ceph 使用的金鑰檔 | 多個副本格式錯誤或內容不一致 |
| PG | Ceph 分配與維護資料副本的單位 | 從 inactive／unknown 恢復為 active+clean |

## 一開始看到什麼？

- PVE 節點出現問號，但 Ping 與管理網頁仍可連線。
- Ceph 顯示 3 顆 OSD、0 顆 up，97 個 PG inactive／unknown。
- RBD 儲存顯示 0 容量，CephFS inactive。
- 較早的 CephFS 查詢曾出現「可以 ls，但 df／statfs timeout」。
- 備份工作長時間未完成；曾觀察到 LXC 備份的 RBD 掛載程序處於 D state。
- kernel 日誌出現 CephX authentication failed -13。

環境回報為 Ceph 20.2.4-pve4、kernel 7.0.14-16-pve。當時雖有較新 kernel 可用，本次恢復沒有以更新 kernel、再重開三台或重新輪替金鑰作為處置。

**叢集投票正常，只能證明管理層還在運作，不能證明資料儲存正常。**

## 日誌把三顆 OSD 的問題分開了

| 節點／OSD | 9/17 停止時間 | 新一次開機後首次失敗 | 已確認原因 |
| --- | --- | --- | --- |
| node12／osd.2 | 17:09:28 | 17:11:18 | key 欄位填成另一個檔案的路徑 |
| node11／osd.1 | 17:11:40 | 17:13:32 | 本機金鑰與 MON 現有金鑰不同 |
| node10／osd.0 | 17:15:14 | 17:20:16 | key 欄位填成另一個檔案的路徑 |

三份日誌都有 systemd 發出停止訊號，接著出現新的 Boot 記錄。因此，是三台依序停止、重開後未能正常上線；不能描述成三顆 OSD 在同一瞬間一起故障。日誌本身也沒有證明是誰、哪個操作發起重開。

### 問題一：把「檔案地址」當成「金鑰」

node10、node12 的關鍵錯誤如下，已省略時間與程序識別資訊：

~~~text
error parsing file .../keyring
type=key val=/root/ceph-key-migration/osd.ID.new.keyring
Malformed input
~~~

key 欄位要放的是編碼後的金鑰內容。填入檔案路徑，就像把「鑰匙放在抽屜裡」這張紙拿去開門，門鎖不會替你到抽屜取鑰匙。[Ceph keyring 工具說明](https://docs.ceph.com/en/latest/man/8/ceph-authtool/)

隨後的「Key loading failed」「failed to fetch mon config」是相關後續錯誤。此處的 Input/output error 出現在金鑰載入失敗的脈絡，不能單憑這句診斷硬碟故障。

### 問題二：格式可讀，但不是 MON 現在接受的金鑰

node11 沒有上述格式錯誤，而是：

~~~text
handle_auth_bad_method failed to auth with my available methods:
(13) Permission denied
~~~

只看這句仍不能斷定金鑰不一致。本案另外讀取本機 osd.1 keyring 與 MON 的 osd.1 金鑰，在記憶體內比對，只輸出：

~~~text
KEY_MISMATCH
~~~

再確認 MON 能提供三顆 OSD 的現有金鑰，才開始修復。這與「再產生一組新金鑰」是不同操作。

## 第一階段：逐顆恢復 OSD

使用者核准每台的修復後，依序處理 node11、node12、node10：

1. 確認所在主機與 OSD 編號，檢查服務尚未執行。
2. 在 root 專用目錄備份原 keyring。
3. 從 MON 匯出該 OSD 的完整 keyring。
4. 使用 ceph-authtool 解析金鑰，再與 MON 重新讀取的值比對。
5. 驗證通過才替換本機檔案，設定本機 OSD keyring 為 ceph:ceph、0600。
6. 清除 systemd 失敗狀態並啟動該 OSD。
7. 檢查服務日誌、ceph -s 與 OSD tree，再處理下一台。

這裡的 ceph:ceph／0600 是本機 OSD 檔案的處理方式，不能直接套到 pmxcfs 的共享檔案。

| 9/18 時間 | 已驗證進展 |
| --- | --- |
| 08:43:43 | osd.1 服務啟動，隨後確認 1 up |
| 08:45:30 | osd.2 服務啟動，隨後確認 2 up |
| 08:47:04 | osd.0 服務啟動，隨後確認 3 up／3 in |
| 約 08:48 | HEALTH_OK；97 個 PG 都具有 active+clean 狀態，部分正在 scrub |
| 後續檢查 | 97 active+clean，CephFS 叢集端 healthy |

osd.0 曾是 down、REWEIGHT 0；啟動後實際回報 up、REWEIGHT 1、3 in。本次沒有手動執行 osd in，也沒有改寫權重。

本次未 destroy／recreate OSD、未格式化磁碟、未修改 MON 現有金鑰、未強制殺死 D-state 程序，也沒有為恢復再重開主機。

## 第二階段：Ceph 健康，為什麼 CephFS 還不能用？

OSD 恢復後，RBD 儲存正常，CephFS 卻仍 inactive。這是另一個認證副本問題。

掛載日誌寫：

~~~text
no mds (Metadata Server) is up.
The cluster might be laggy, or you may not be authorized
~~~

但 ceph fs status 顯示 rank 0 active、有兩個 standby；kernel 則持續回報：

~~~text
auth protocol 'cephx' mauth authentication failed: -13
~~~

因此沒有直接重啟 MDS，而是讀取 systemd mount unit 的掛載參數。確認本案例使用：

~~~text
name=admin
secretfile=/etc/pve/priv/ceph/cephfs.secret
conf=/etc/pve/ceph.conf
fs=cephfs
~~~

**ceph -s 能成功，不代表掛載用的 secretfile 也正確。** 掛載可使用自己指定的金鑰來源。[mount.ceph 官方說明](https://docs.ceph.com/en/reef/man/8/mount.ceph/)

本案將 cephfs.secret 與 MON 的 client.admin 金鑰比較，結果是 CEPHFS_KEY_MISMATCH。經核准後，備份原檔、匯出並驗證 MON 現有金鑰，將「純金鑰文字」寫入 secretfile，再重試 node10 掛載。完整 keyring 與純 secret 檔案的格式不同，不可互相直接替代。

這份檔案位於 /etc/pve 的共享設定中，只更新一次，再於每台分別驗證；並未放寬共享目錄權限。其他環境若使用專用 CephFS client，必須同步它自己的金鑰，不能一律改成 admin。[Proxmox pmxcfs 說明](https://github.com/proxmox/pve-docs/blob/master/pmxcfs.adoc)

08:57:26，node10 回報 active (mounted)，findmnt 確認 FSTYPE 為 ceph，df 正常回報容量。之後三台都確認 CephFS active。

### 為什麼只看 df 還不夠？

未掛載時，df /mnt/pve/cephfs 仍可能顯示本機根檔案系統的容量。這只能說明目錄所在的本機磁碟可用，不代表 CephFS 可用。因此要把 findmnt 的掛載點、來源、FSTYPE 一起核對。

## 備份卡住如何判讀？

本案某筆批次備份長時間未結束，但 Ceph 恢復後，有 VM 備份繼續完成。

其中一台 VM 的最終日誌顯示 60 GiB 傳輸完成，接著出現 Finished Backup，備份鎖查詢也沒有 lock 欄位。整批任務仍是 job errors，不能據此宣稱這一台 VM 備份失敗；反過來，也不能因其中一台完成就宣稱整批成功。

另外，本案曾拿到一份明確「跳過目標 VM」的日誌。排查前必須核對節點、UPID 與 VM 編號，避免分析錯工作。prelaunch 或 lock: backup 本身也不等於卡死：備份可能啟動 QEMU 來讀取原本關機 VM 的磁碟。

本次沒有手動 unlock 該 VM，也沒有強制啟動它。使用者決定系統恢復後再做一次手動備份；該次新備份及還原測試尚未列入本案已驗證結果。較早的 LXC D-state 備份未取得完整結案日誌，不將它記為備份成功。

## 可重用的診斷順序

以下以本案例名稱示範。先確認自己的節點、OSD ID、儲存 ID 與 mount unit。日誌可能含敏感內容，分享前須去敏感化。

~~~bash
# 叢集與 OSD：讀取狀態
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
~~~

pvesm status 可確認 PVE 的整合狀態，但本案實際觀察到它可能觸發未掛載 storage 的啟用／掛載嘗試，不能視為絕對沒有副作用的純讀取操作：

~~~bash
timeout 15 pvesm status
~~~

timeout 有助於限制一般查詢等待，但不能保證終止卡在不可中斷核心 I/O 的 D-state 程序。不要反覆製造新的卡住查詢。

### 不顯示金鑰的比對範例

以下針對本案 CephFS「純 secret 檔」比較，不適用完整 keyring。先確認 mount options 的帳號與檔案路徑正確。

~~~bash
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
~~~

文字不一致仍需排除檔案格式／多餘字元；本案另有認證失敗與替換後掛載成功的證據。不要把金鑰輸出到聊天、issue 或公開紀錄。

## 復原驗收：三層都過才算服務恢復

| 層級 | 本案最終證據 |
| --- | --- |
| Ceph 叢集 | HEALTH_OK、3 up／3 in、97 active+clean |
| PVE 儲存 | 三台 RBD、CephFS、PBS storage 全部 active |
| CephFS 實際掛載 | 三台 findmnt 為 ceph，node10 容量查詢正常 |
| 管理畫面 | 使用者確認節點問號消失 |
| 備份 | 目標 VM 的個別完成日誌已確認；整批有錯誤，後續手動備份仍待執行 |

HEALTH_OK 是叢集健康證據，不等於所有 VM 的應用程式資料都做過還原驗證。

## 尚未釐清：重開後會不會再次發生？

**目前服務已恢復，但持久性仍有一個待查項目。**

整理文章時，在既有 [CephX 遷移紀錄](https://github.com/kbwangtw/IT-Knowledge-Base/blob/main/docs/pve/ceph-20-2-4-cephx-aes256k-migration.md) 發現，舊範例將 keyring 檔案路徑當成 BlueStore set-label-key 的 -v 值。官方工具文件說明 -v 是要儲存的值，並不是讀檔參數。這個舊範例已撤下並標示更正。[官方參數說明](https://docs.ceph.com/en/latest/man/8/ceph-bluestore-tool/)

它與本案「key 欄位變成路徑」的錯誤形態相符，值得追查；但本次沒有取得實際 BlueStore label、ceph-volume 啟用過程或完整操作歷史，不能因此認定舊指令已執行，或宣布它就是原始肇因。

後續應核對實際裝置、部署版本、BlueStore label 的 osd_key 與 OSD 啟用流程，判斷是否可能在下一次啟用時重新帶入錯誤金鑰。相關讀取結果可能含 secret，應只在本機比對，不公開完整 label。若需修改 label，應另訂維護計畫，停止對應 OSD 並完成裝置與備份確認；本次沒有做 label 寫入，也沒有做重開機驗證。

因此結論應分成兩句：

- **已證實且修復：**本機 OSD 金鑰格式／內容問題，以及 CephFS 掛載金鑰不一致。
- **尚未證實：**最早造成金鑰變更的操作，以及磁碟持久化來源是否也需要修正。

## 下次如何避免？

1. 每次金鑰變更都盤點真正使用的副本：daemon、RBD storage、CephFS secretfile，不能只測管理 CLI。
2. 一台停機後若沒恢復，先停止處理下一台。
3. OSD 啟動失敗先讀 journal，不因容量顯示 0 就重建 OSD。
4. 先備份，再驗證，再替換；既有 MON 金鑰有效時，不為排障再做一次 rotate。
5. 服務恢復後完成各節點儲存驗證，再做備份與還原測試。
6. 備份的舊金鑰檔只作追查用途，限制存取；它不一定仍有效，也不是可直接還原的通用修復方案。

這次最有用的經驗是：同一個「Ceph 認證」可能散落在多份檔案。把每一個真正使用中的金鑰來源查清楚，才知道要修哪一份。
