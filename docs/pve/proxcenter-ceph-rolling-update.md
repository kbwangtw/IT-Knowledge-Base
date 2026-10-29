---
layout: default
title: "ProxCenter 逐台更新 PVE：三個卡關點怎麼排除？"
date: 2026-08-26
categories: [PVE, ProxCenter, Ceph]
last_modified_at: 2026-10-29
---

# ProxCenter 逐台更新 PVE：三個卡關點怎麼排除？

> **一句話**：用 ProxCenter 自動「一台一台」更新 PVE 叢集時，被三件事擋住：套件來源檢查讀到備份檔、SSH 連錯網段、sudo 權限不足；分開處理後就能往下走。也記錄了 10/12 實際更新的結果、「ProxCenter 不能更新自己所在那台」的問題，10/24 分兩輪讓 ProxCenter 更新完三台的做法，以及 10/29 ProxCenter 在 node10 時的第二次三台更新。

| 項目 | 內容 |
| --- | --- |
| 適合誰看 | 第一次用 ProxCenter 做 PVE 滾動更新的人 |
| 環境 | 三台 PVE（node10～12）＋ Ceph；ProxCenter 是 ct:110 |
| 實測 | 2026-08-26（排除三個卡關點，node12 進入更新階段）；2026-10-12（ProxCenter 完成 node11、node12，node10 手動）；2026-10-24（**三台都由 ProxCenter 完成**，分兩輪）；2026-10-29（再次三台，ProxCenter 在 node10，kernel -25 → -26） |
| 結論 | ✅ 三個卡關點已排除；✅ 10/24 三台都由 ProxCenter 更新並重開（kernel 7.0.14-23 → -25），HA 服務沒有中斷、Ceph 回到 HEALTH_OK（第 12 節）；✅ 10/29 再做一次三台更新，已是最新的節點會被自動略過，不需要「陪跑」（第 13 節）；⏳ 把 ProxCenter 移到叢集外、縮小 sudo 權限 |

> 文中 IP 都是文件示範位址（管理網 192.0.2.0/24、內部網段 198.51.100.0/24）；IP、帳號、VMID 是案例值。

## 1. 先認識幾個名詞

| 名詞 | 白話解釋 |
| --- | --- |
| **逐台更新（Rolling update）** | 一次只維護一台，其他台繼續服務 |
| **ProxCenter** | 管理 PVE 叢集的網頁工具，可以自動做滾動更新 |
| **維護模式** | 告訴 HA「這台要維修」，先把服務搬走 |
| **noout** | Ceph 的維護旗標：暫時不要因為某顆 OSD 離線就開始搬資料 |
| **Corosync 網段** | 叢集節點之間互相通訊的網路，和管理網分開 |
| **sudo -n** | 不互動地執行 sudo；需要密碼就直接失敗 |
| **APT 套件來源** | 系統從哪些網址下載更新，設定在 `/etc/apt/` |

## 2. 更新前先確認叢集健康

逐台更新的前提是：**少一台時，剩下的主機、儲存與網路撐得住全部工作**。本次三台有 quorum，Ceph 是 HEALTH_OK、OSD 3 up／3 in，HA／LRM 正常。

```bash
pvecm status       # 叢集 quorum
ceph -s            # Ceph 健康
ha-manager status  # HA 服務
pveversion -v      # 版本
```

## 3. 當時使用的更新設定（8/26）

| 設定 | 本次選擇 |
| --- | --- |
| 順序 | node12 → node11 → node10 |
| 搬移非 HA VM | 開啟 |
| 關閉使用本機儲存的 VM | 關閉 |
| 必要時自動重開 | 開啟 |
| 維護期間設定 Ceph noout | 開啟 |
| 發生錯誤即中止 | 開啟 |
| 每台之間人工批准 | 開啟 |
| 最少健康節點 | 2 |
| 等待 Ceph HEALTH_OK | 開啟 |

> 這是本案設定，不是所有環境的標準答案。「略過本機儲存 VM」**不代表**它在主機重開時還會運作，必須另外安排停機。

## 4. 卡關一：APT 正常，檢查器卻說來源有問題

**現象**：`apt update` 本身正常，但 ProxCenter 回報 Repository Issues。

**原因**：套件來源目錄裡有 `.BAK` 備份檔，檢查器也把它們算進去了。

**怎麼確認**：先只移出 node10 的兩個備份檔，錯誤從 6 個變成 4 個；處理其他節點後降為 0。這個**前後對照**才是定位問題的依據。

```bash
apt-cache policy                                           # 實際生效的來源
grep -Rni 'enterprise.proxmox.com' /etc/apt/ 2>/dev/null   # 哪些檔案提到企業版來源
ls -la /etc/apt/sources.list.d/                            # 找出備份檔
```

- 先確認哪些是備份檔，再**移到來源目錄以外並保留**，不要刪掉正常使用中的來源。
- 套件來源要依自己的訂閱與版本設定，不能為了讓檢查變綠就任意切換。

## 5. 卡關二：SSH 測試成功，更新工作卻連不到

**現象**：單獨按「測試 SSH」成功；真正更新時卻連到 198.51.100.12:22 而逾時。

**原因**：更新流程自動選了 **Corosync 網段**，和測試時用的管理網不同。

**解法**：把 SSH 目的地明確指定成管理網：

```text
node10 → 192.0.2.10
node11 → 192.0.2.11
node12 → 192.0.2.12
```

> **要比的是同一個目的 IP、帳號與驗證方式。** 一個按鈕測試成功，不能證明另一段流程用的連線也一樣。

從節點日誌核對實際的登入：

```bash
journalctl --since "10 minutes ago" | grep -Ei 'sshd|proxcenter'
```

## 6. 卡關三：部分指令可以用，仍被判定沒有免密碼 sudo

**現象**：原本只允許部分指令，apt、ceph、ha-manager 個別測試都可以，但流程的 `sudo -n true` 測試仍要求密碼。

```bash
visudo -c -f /etc/sudoers.d/proxcenter     # 檢查語法
sudo -u proxcenter sudo -n -l              # 列出這個帳號能做什麼
sudo -u proxcenter sudo -n true            # 流程實際做的測試
```

**本案最後採用**：

```text
proxcenter ALL=(ALL) NOPASSWD: ALL
```

之後測試回傳 0，`id` 顯示 root，流程得以往下走。

> ⚠️ 這讓帳號取得**等同 root** 的能力，是本次採用的**權限取捨**，不是已驗證的最小權限解法。要縮小權限，得依該版本實際執行的完整指令另外測試。

查看 reboot 的 sudo 權限用清單模式，**不要為了測試權限直接執行重開**：

```bash
sudo -u proxcenter sudo -n -l /usr/sbin/reboot
```

## 7. VM 被略過，是錯誤嗎？

VM100、VM105 使用本機儲存，所以被略過；VM107 成功搬到 node11。這符合「不關閉本機儲存 VM」的設定，但也代表這些 VM **需要另外安排維護**。

第一次工作曾設定 noout、嘗試維護模式、搬移 VM，然後才在套件更新的 SSH 階段失敗。**失敗不代表前面完全沒改變**，重試前要重新檢查：

```bash
pvecm status
ceph -s
ha-manager status
ceph osd dump | grep flags        # 看 noout 是否還在
```

> noout 是維護旗標，不是永久設定。收尾時依實際維護狀態確認是否該解除；不能看到就盲目清掉，也不能忘記檢查。

## 8. 8/26 最後看到的結果

修正後，node12 的日誌進入以下階段：

```text
Enabling maintenance mode
Waiting for HA migrations
Migrating non-HA VMs
Running apt update && apt full-upgrade
Verifying node health
```

這證明「三個阻礙已排除，node12 的更新流程能往下走」。要宣告整個叢集更新完成，仍需每台的版本、重開後狀態、VM／HA、Ceph 和維護旗標紀錄。

## 9. 2026-10-12：ProxCenter 完成兩台更新與重開

這次更新 kernel（7.0.14-22-pve → 7.0.14-23-pve，pve-manager 維持 9.2.21）。**node11、node12 由 ProxCenter 更新並重開，node10 手動更新。**

驗收時三台 running kernel 都是 7.0.14-23-pve，uptime 分別是 node11 14 分鐘、node12 10 分鐘、node10 8 分鐘。從 uptime 看，ProxCenter 這次先處理 node11 再處理 node12，和 8/26 設定的順序不同；以實際順序為準。

| 項目 | 結果 |
| --- | --- |
| Cluster | Quorate Yes，3 nodes |
| Ceph | HEALTH_OK；3 MON quorum；OSD 3 up／3 in；97 PG active+clean；CephFS healthy |
| `noout` | 已解除 |
| node11、node12 | 沒有 HA 服務異常 |
| node10（手動） | ct:100、vm:107 進入 HA error，已修復 |

node10 的 HA error **不是** ProxCenter 造成的：手動 `reboot` 前沒有先 `ha-manager crm-command node-maintenance enable node10`，HA 在關機過程中反覆嘗試啟動服務而失敗。ProxCenter 會自動進入維護模式，所以它處理的兩台沒事。詳見 [PVE 更新重開後 HA 服務卡在 error](https://kbwangtw.github.io/IT-Knowledge-Base/docs/pve/pve-ha-service-error-after-reboot/)。

同時段 node10 的工作紀錄裡，有一筆 proxcenter@pve token 發出的 `hamigrate 107` 是 ERROR（15:42:06）。當時 node10 正在手動更新重開，本次沒有另外追查這筆搬移請求的來源。

## 10. 問題：ProxCenter 在自己管理的叢集裡

ProxCenter 是 ct:110，平常在 node11，受 PVE HA 管理。輪到 node11 時，ProxCenter 會讓這台進入維護模式，HA 就把 ct:110 搬走；**容器搬移會先停止再啟動**，等於 ProxCenter 在流程途中把自己停掉了。ProxCenter 有沒有特別處理這種情況，本次沒有查證。

**這個環境的做法（方案 A）**：

1. ProxCenter 所在的 node11 **手動**更新：`node-maintenance enable` → `apt full-upgrade` → `reboot` → 驗收 → `node-maintenance disable`。解除維護模式時，HA 會把原本在 node11 的服務（包含 ct:110）搬回來。
2. 確認 ct:110 回到 node11，再用 ProxCenter 只更新 node10、node12。
3. 每台之間的人工批准前，確認服務都回到 `started`。

要讓 ProxCenter 自己跑完全部三台，比較可靠的做法是把 ProxCenter 移到叢集外面（例如另一台主機）。本案尚未這樣部署。

## 11. 2026-10-12：沒有可用更新時，ProxCenter 不會啟動

kernel 更新完成後，想用方案 A 實驗一次滾動更新。事前檢查：

| 檢查 | 結果 |
| --- | --- |
| `apt list --upgradable`（三台） | 都沒有可更新的套件 |
| node11 上非 HA 的 VM | VM104、VM108，都已關機 |
| HA 規則 | 只有兩條互斥規則（ct:100／ct:101、vm:106／vm:107），沒有把 ct:110 固定在某台 |
| Cluster／Ceph | Quorate Yes、HEALTH_OK、OSD 3 up／3 in、97 PG active+clean，沒有 `noout` |

ProxCenter 的 Rolling Update 頁面顯示三台都是 9.2.21、Available Updates 都是 0，訊息是 `0 update(s) available on 0 node(s)` 與 `Up to date`。畫面只有 `Check for updates` 按鈕，**沒有可以啟動滾動更新的選項**。

**結論**：ProxCenter 會先檢查可用更新，全部為 0 時不提供執行，也就不會進維護模式、搬服務或重開。它不能拿來「單純測試維護與重開流程」，要等有實際更新時再實驗。ProxCenter 的 Available Updates 和 `apt list --upgradable` 結果一致。（本次沒有查 Settings 裡有沒有強制執行的選項。）

**執行時的監看視窗**：在 ProxCenter 不會維護的那台開著，即時看維護模式、服務搬移、`noout` 與 OSD 狀態：

```bash
watch -n 5 'ha-manager status | grep -E "lrm|service"; echo; ceph osd dump | grep "^flags"; ceph -s | grep -E "health|osd:"'
```

> 用 `grep "^flags"` 只抓叢集層級的旗標那一行；寫成 `grep flags` 會連每個 pool 的資料都抓到，畫面會被洗掉。

## 12. 2026-10-24：分兩輪，三台都由 ProxCenter 更新

**做什麼**：Rolling Update 頁面顯示三台各 16 個更新（`48 update(s) available on 3 node(s)`、`3 reboot(s) required`），終於可以實際跑一次。目標是**三台都交給 ProxCenter**，不再手動更新任何一台。

**難題**：ProxCenter（ct:110）在 node11。讓它一輪做完三台，輪到 node11 時 HA 會把 ct:110 搬走，等於 ProxCenter 在流程中途把自己停掉；ProxCenter 會怎麼處理這種情況，release notes 裡沒有寫。

**做法：分兩輪**，ProxCenter 永遠不更新自己所在的那台：

```text
第 1 輪：ProxCenter 更新 node12 → node10（ct:110 在 node11，不受影響）
中場：  ha-manager migrate ct:110 node10（搬到已更新的節點）
第 2 輪：ProxCenter 更新 node11（node12 陪跑，等批准時按 Cancel）
```

### 12-1 更新前檢查（唯讀）

```bash
sudo -l -U proxcenter | sed -n '/may run/,$p'
for h in node10 node11 node12; do echo "== $h"; ssh root@$h "apt list --upgradable 2>/dev/null | grep -v '^Listing' | cut -d/ -f1 | tr '\n' ' '; echo"; done
pvecm status | grep -E 'Quorate|Nodes'; ceph -s | grep -E 'health|osd:|pgs:'; ceph osd dump | grep '^flags'
ha-manager status | grep -E 'ct:110|error'
```

| 檢查 | 結果 |
| --- | --- |
| 可更新套件 | 三台相同：`bind9-*`、`ca-certificates`、`cifs-utils`、`curl`、`libcurl*`、`libexpat1`、`libpve-storage-perl`、`libunbound8`、`linux-libc-dev`、`proxmox-kernel-7.0`、`qemu-server`、`tzdata`；**沒有 `ceph-*`** |
| 叢集 | Quorate Yes、HEALTH_OK、OSD 3 up／3 in、97 PG active+clean、沒有 `noout` |
| ct:110 | node11 |
| `proxcenter` 的 sudo | 除了一長串指令清單，**最後還有 `NOPASSWD: ALL`**（就是第 6 節 8/26 加的） |

另外確認兩台要更新的節點上，**沒有正在執行、又不在 HA 裡的 VM／CT**（這種的維護模式不會搬）：

```bash
for h in node10 node12; do echo "== $h"; ssh root@$h "for id in \$(qm list | awk '/running/{print \$1}'; pct list | awk '/running/{print \$1}'); do ha-manager status | grep -qE \"(vm|ct):\$id \" || echo \"  \$id\"; done"; done
```

看到的結果：兩台都沒有輸出。

### 12-2 精靈設定

| 設定 | 預設 | 本次 | 原因 |
| --- | --- | --- | --- |
| 節點 | 三台都勾 | 第 1 輪只勾 node12、node10 | 排除 ProxCenter 所在的 node11 |
| SSH Addresses | **`198.51.100.x Cluster`** | `192.0.2.x vmbr0 (gw)` | 預設又是 Corosync 網段，就是第 5 節的卡關二；改成管理網 |
| Migrate non-HA VMs | 開 | 開 | |
| Automatically reboot | 開 | 開 | 有新 kernel |
| Set Ceph noout flag | 開 | 開 | 第一台開始前設定，整輪結束時清除 |
| Abort on failure | 開 | 開 | |
| Manual approval between each node | **關** | **開** | 每台之間先確認服務、Ceph，再批准下一台 |
| Reboot timeout | 300 秒 | 600 秒 | 保守值；實測重開只要 80～125 秒 |
| Minimum healthy nodes | 1 | 1 | 見 12-3 |
| Shutdown VMs with local storage | 關 | 關 | 搬不走的 VM 跳過，不關機 |
| Wait for Ceph HEALTH_OK between each node | 開 | 開 | |

### 12-3 坑：Minimum healthy nodes 只算勾選的節點

第 1 輪原本想設 2，Verify 擋下來：

```text
Only 2 nodes are healthy, and 11 are needed to keep 10 online while one is updated.
```

（欄位被誤輸入成 10。）第 2 輪只勾 node11、設 1，又被擋：

```text
Only 1 nodes are healthy, and 2 are needed to keep 1 online while one is updated.
```

兩次都說明：**ProxCenter 只計算有勾選的節點**，不算叢集裡其他在線的節點。而且這個欄位**最小只能填 1**，填 0 會自動跳回 1。

| 勾選幾台 | Minimum healthy nodes | 結果 |
| --- | --- | --- |
| 2 台 | 1 | ✅ 通過 |
| 2 台 | 2 | ❌ 永遠不夠 |
| 1 台 | 1（最小值） | ❌ 永遠不夠 |

只更新一台時，改用「**陪跑**」：多勾一台已經沒有更新的節點，**排在要更新的那台後面**，開啟 Manual approval；要更新的那台完成、停在等待批准陪跑節點時按 **Cancel**。陪跑節點完全不會被動到。

> 設 1 不會降低實際安全性：沒勾選的節點一直在線，quorum 和 Ceph 都夠。真正的保護是 Wait for Ceph HEALTH_OK、Abort on failure 和 Manual approval。

### 12-4 第 1 輪：node12 → node10（10 分鐘）

監看視窗開在**這一輪不會重開的 node11**：

```bash
watch -n 5 'ha-manager status | grep -E "lrm|service"; echo; ceph osd dump | grep "^flags"; ceph -s | grep -E "health|osd:|volumes"'
```

ProxCenter 的紀錄（節錄）：

```text
[12:11:56] [node12] Skipping VM 101 (Pihole) - has local storage
[12:11:56] [node12] Skipping VM 105 (Graylog) - has local storage
[12:11:56] [node12] Skipping VM 114 (grafana) - has local storage
[12:11:56] [node12] Migrating VM 107 (DC02) to node10
[12:12:01] [node12] Running apt update && apt full-upgrade
[12:12:46] [node12] Package upgrade finished: 17 package(s) configured
[12:12:46] [node12] Rebooting node
[12:14:11] [node12] Verifying node health
[12:14:12] Ceph also reports, not holding the update: MON_CLOCK_SKEW: clock skew detected on mon.node12
[12:14:12] [node12] Waiting for manual approval before updating this node   ← node10
...
[12:19:00] [node10] Rebooting node
[12:21:05] [node10] Verifying node health
[12:21:06] Waiting for Ceph to recover: FS_DEGRADED: 1 filesystem is degraded
```

| 節點 | 套件 | 重開 | 備註 |
| --- | --- | --- | --- |
| node12 | 17 個（12:12:01～12:12:46） | 12:12:46 → 12:14:11（約 85 秒） | 回來時 `MON_CLOCK_SKEW`，對時後自己消失 |
| node10 | 17 個（12:18:15～12:19:00） | 12:19:00 → 12:21:05（約 125 秒） | API node；回來後等 CephFS 恢復（`FS_DEGRADED`） |

結果：`Rolling update completed successfully (2/2 nodes)`、`Duration: 10 minutes`。

**`has local storage` 是誤判**：這幾台都是 LXC，磁碟全在 Ceph：

```bash
grep -HE '^(rootfs|mp[0-9]+):' /etc/pve/nodes/*/lxc/{101,105,114}.conf
```

```text
/etc/pve/nodes/node12/lxc/101.conf:rootfs: VM_Pool:vm-101-disk-0,size=8G
/etc/pve/nodes/node12/lxc/105.conf:rootfs: VM_Pool:vm-105-disk-0,size=64G
/etc/pve/nodes/node12/lxc/114.conf:rootfs: VM_Pool:vm-114-disk-0,size=30G
```

實際上 HA 在維護模式時已經把它們搬走，重開期間它們在其他節點正常執行；從 HA 的紀錄可以看到「搬回來」的那一段（`node = node10` 就是它原本暫住的節點）：

```text
12:14:24 pve-ha-crm: node 'node12': state changed from 'maintenance' => 'online'
12:14:24 pve-ha-crm: moving service 'ct:105' back to 'node12', node came back from maintenance.
12:14:24 pve-ha-crm: service 'ct:105': state changed from 'started' to 'relocate'  (node = node10, target = node12)
12:14:34 pve-ha-crm: service 'ct:105': state changed from 'relocate' to 'started'  (node = node12)
```

LXC 搬移是「先停再啟動」，所以每台 CT 會停兩次（搬走、搬回），每次約 10 秒；VM 是線上遷移，不中斷。

驗收：兩台可更新套件 0、`HEALTH_OK`、`volumes: 1/1 healthy`、97 PG active+clean、**`noout` 已自動清除**、三台 lrm 都是 `active`。

### 12-5 第 2 輪：node11（node12 陪跑）

1. 確認 ct:110 在 node10（`ha-manager status | grep ct:110`）。
2. 監看視窗改開在 **node12**（node11 會重開，node10 有 ProxCenter）。
3. 精靈勾選 **node11 第一、node12 第二**，Minimum healthy nodes 1，Manual approval 開。

```text
[12:36:57] Set Ceph noout flag
[12:36:58] [node11] Skipping VM 102 (librenms) / 109 (wireguard) / 112 (wazuh) - has local storage
[12:36:58] [node11] Migrating 3 VM(s), up to 2 in parallel        ← VM 108、104（關機中）、VM 111
[12:37:23] [node11] Shutting down local storage VMs
[12:37:23] [node11] Running apt update && apt full-upgrade
[12:38:26] [node11] Rebooting node
[12:39:46] [node11] Verifying node health
[12:39:48] [node11] Node update completed
[12:39:48] [node12] Waiting for manual approval before updating this node   ← 按 Cancel
```

| 疑點 | 查證結果 |
| --- | --- |
| `Shutting down local storage VMs`（選項明明是關的） | 只是流程訊息。HA 紀錄顯示 102、109、112 在 12:40:05 從 node10／node12 搬回 node11，代表重開期間它們在別台執行，**沒有被關機** |
| 「搬走」的紀錄找不到 | 當時 HA master 就是 node11，那段紀錄在 node11 自己的 journal；重開後 master 換到 node10 |
| 取消後 `noout` | ProxCenter 取消時**也會自動清除**，`ceph osd dump` 沒有 `noout`、`HEALTH_OK` |
| vm:111（CA） | ProxCenter 用一般遷移搬到 node12，不是 HA 搬的，所以不會自動搬回；不影響運作 |
| 搬 WireGuard（ct:109） | 透過 VPN 連線時，畫面會斷約 10～20 秒兩次；更新在內網進行，不受影響 |

### 12-6 最後驗收

```bash
for h in node10 node11 node12; do echo "$h: $(ssh root@$h 'uname -r; uptime -p' | tr '\n' ' ')"; done
for h in node10 node11 node12; do echo -n "$h: "; ssh root@$h "apt list --upgradable 2>/dev/null | grep -vc '^Listing'"; done
ha-manager status | grep -cE 'service .*started'; ha-manager status | grep -E 'error|fence' || echo "no error/fence"
ssh root@node11 "pct exec 112 -- systemctl is-active wazuh-manager wazuh-indexer wazuh-dashboard"
for h in node10 node11 node12; do echo -n "$h: "; ssh root@$h "journalctl -u ssh --since '12:00' --no-pager | grep 'for proxcenter from' | grep -oP 'from \K[0-9.]+' | sort | uniq -c | tr '\n' ' '"; echo; done
```

| 檢查 | 結果 |
| --- | --- |
| kernel | 三台 **7.0.14-25-pve**（pve-manager 維持 9.2.21） |
| 可更新套件 | 三台 0 |
| HA | 13 個 started，沒有 error／fence |
| Wazuh | manager、indexer、dashboard 都是 active |
| `proxcenter` 登入來源 | node10 8 次、node12 6 次，都是 `192.0.2.30`；node11 是 `192.0.2.30` 5 次、**`198.51.100.30` 1 次** |

最後一列很重要：當天早上替 `proxcenter` 的金鑰加了 `from=` 來源限制，**兩個 IP 都允許**，所以那一次從 Corosync 網段來的登入沒有被擋（見 [Fail2Ban 強化文件第 13-5 節](https://kbwangtw.github.io/IT-Knowledge-Base/docs/pve/pve-cluster-fail2ban-hardening/)）。如果只允許管理網的 IP，這次更新可能會在 node11 失敗。

同日 PBS31 也更新到 7.0.14-25，四台一致，見 [PBS 更新後，怎麼確認備份還能用？](https://kbwangtw.github.io/IT-Knowledge-Base/docs/pve/ProxCenter-PBS-Update-and-DR-Validation-SOP/)。

## 13. 2026-10-29：ProxCenter 在 node10 時，再做一次三台更新

**做什麼**：三台各有 22 個更新（kernel 7.0.14-25 → -26、`pve-manager` 9.2.21 → 9.2.24、`qemu-server`、`pve-cluster`、`pve-firmware`、`swtpm`／`libtpms` 等），沒有 `ceph-*`。這次 ProxCenter（ct:110）在 **node10**，做法和 10/24 對調：

```text
第 1 輪：ProxCenter 更新 node11 → node12（ct:110 在 node10，不受影響）
中場：  ha-manager migrate ct:110 <已更新的節點>
第 2 輪：ProxCenter 更新 node10
```

### 13-1 更新前檢查（唯讀）

| 檢查 | 結果 |
| --- | --- |
| `pvecm status` | Quorate Yes、3 節點、Quorum 2 |
| `ceph -s` | HEALTH_OK、OSD 3 up／3 in、97 個 PG 全部 active+clean、沒有 `noout` |
| `ha-manager status` | 13 個資源都 started、沒有 error／freeze；ct:110 在 node10 |
| 三台可更新的套件名稱 | 21 個，三台相同（ProxCenter 顯示 22，多出的是 signed kernel image） |

另外查**執行中、又不在 HA 裡**的 VM／CT（`ha-manager config` 對照 `pvesh get /cluster/resources --type vm`）：15 個 VM／CT 裡 13 個在 HA，剩下 VM 104（node12、running）和 VM 108（node11、stopped）。

| 項目 | 結果 | 影響 |
| --- | --- | --- |
| VM 104 | 磁碟在 Ceph 的 `VM_Pool`、沒有 hostpci／usb 直通 | 可以被 ProxCenter live migrate |
| VM 108 | 關機、有 VGA 直通（hostpci） | 關機的 VM 維護模式不會搬，留在原地；有直通所以無法 live migrate，更新期間不要開機 |

### 13-2 精靈設定

和 12-2 相同；這次的重點是**預設值每次都會被重設**，要逐項重新檢查：

| 設定 | 預設 | 本次 |
| --- | --- | --- |
| SSH Addresses | 這次預設就是管理網 `vmbr0 (gw)` | 仍要逐台確認，10/24 預設是 Corosync 網段 |
| Manual approval between each node | 關 | **開** |
| Reboot timeout | 300 | 600 |
| Minimum healthy nodes | 1 | 1 |

按 Verify 的結果：`All checks passed`、預估約 45 分鐘、`3 VMs will be migrated`（**推測**是 node12 上執行中的 VM 104、107、111；畫面沒有列名字）。

### 13-3 第 1 輪：node11 → node12

node11 的日誌（時間是 24 小時制）：

```text
09:21:43 Rolling update started
09:21:44 Set Ceph noout flag
09:21:44 [node11] Enabling maintenance mode / Waiting for HA migrations to complete
09:21:44 [node11] Skipping VM 102 (librenms) - has local storage   ← 橘字，LXC 誤判，見 14
09:22:38 [node11] Package upgrade finished: 22 package(s) configured
09:22:38 [node11] Rebooting node
09:23:52 [node11] Verifying node health / Disabling maintenance mode
09:23:53 Ceph also reports, not holding the update: MON_CLOCK_SKEW … on mon.node11
09:23:53 [node12] Waiting for manual approval before updating this node
```

套件約 1 分鐘裝完，重開約 74 秒節點回來。`MON_CLOCK_SKEW` 是剛開機還在對時，幾分鐘內自己消失，ProxCenter 不會因此停住。

**批准 node12 前的檢查**（唯讀）：

| 項目 | 看到 |
| --- | --- |
| node11 版本 | kernel `7.0.14-26-pve`、pve-manager `9.2.24` |
| Ceph | `HEALTH_WARN` 只剩 `noout` 一項（更新中預期有）、OSD 3 up、97 個 PG 全部 active+clean、`MON_CLOCK_SKEW` 已消失 |
| HA | 13 個 started；ct:102、109、112 在 node11 |

批准後 node12 照同樣流程完成，整輪結束時 ProxCenter **自動清除 `noout`**。驗收：兩台都是 `7.0.14-26-pve`／`9.2.24`，Ceph HEALTH_OK，13 個 started；**VM 104、107、111 都搬到 node11 並 running**，node12 只剩 CT101、105、114；VM 108 仍是 stopped。

> `pvesh` 顯示這三台 VM 的 uptime 約 4 小時。uptime 是**目前這個 QEMU 程序**的時間，live migrate 後目的節點的新程序也從搬移那刻起算，所以**不能用它判斷是重啟還是熱遷移**；要看 ProxCenter 日誌的 `Migrating VM`。

### 13-4 中場與第 2 輪：node10

中場在 PVE 網頁 node10 → Shell 執行：

```bash
ha-manager migrate ct:110 node11
```

**看到的結果**：ProxCenter 網頁約 1 分鐘打不開，之後恢復；`ct:110` 最後在 **node12**（node11、node12 都已更新，在哪一台都行；指令寫 node11 但實際在 node12，原因不確定）。

第 2 輪勾選 node11（排第一）和 node10（排第二），Manual approval 開。日誌：

```text
13:29:29 Rolling update started
13:29:30 Set Ceph noout flag
13:29:30 [node11] Node is already up-to-date, skipping      ← 已是最新，自動略過
13:29:30 [node10] Waiting for manual approval before updating this node
13:29:37 [node10] Node update approved                       ← 使用者按 Approve
13:29:37 [node10] Enabling maintenance mode
13:29:38 [node10] Skipping VM 100 (AdGuard) / 103 (IPAM) / 113 (ai) - has local storage
```

| 觀察 | 說明 |
| --- | --- |
| **已是最新的節點會被自動略過** | 所以這次**不需要「陪跑」**，node10 是最後一個節點，完成後整輪直接結束，**不用按 Cancel**，`noout` 也自動清除 |
| Manual approval 仍然會在第一個被更新的節點前要你批准 | 即使前一個節點是被略過的 |
| 執行 Claude Code 的容器（CT113）在 node10 | 它是 HA 資源，node10 進維護模式時被 HA 重啟到別台，更新完又回來；對話中斷約一兩分鐘 |

### 13-5 最後驗收

| 檢查 | 結果 |
| --- | --- |
| 三台版本 | 都是 kernel `7.0.14-26-pve`、pve-manager `9.2.24` |
| Ceph | HEALTH_OK、沒有任何警告（`noout` 已清除）、OSD 3 up／3 in、97 個 PG active+clean |
| HA | 13 個 started、沒有 error／freeze；master 在 node11 |
| Quorum | Yes、3 節點 |

最後的位置：

| 節點 | 資源 |
| --- | --- |
| node10 | ct:100、103、113、vm:106 |
| node11 | ct:102、109、112、vm:107、111；非 HA：vm:104（running）、vm:108（stopped） |
| node12 | ct:101、105、110、114 |

DC01（vm:106，node10）與 DC02（vm:107，node11）在不同節點；AdGuard（node10）與 Pihole（node12）在不同節點。**DC 的分開規則只存在 ProxCenter，PVE HA 沒有**（見 [HA 放置策略](https://kbwangtw.github.io/IT-Knowledge-Base/docs/pve/pve-ha-placement-policy/)），這次是剛好沒落在同一台，不是規則保證。

**未確認**：CT110（ProxCenter）驗收時 uptime 只有約 8 分鐘，比同節點其他 CT 短很多，原因不確定。

## 14. 下次可以直接照做的檢查順序

1. 確認 quorum、Ceph、HA 與工作負載容量
2. 看套件來源的實際設定，區分出備份檔
3. 核對更新流程**真正使用**的 SSH IP
4. 用同一個帳號測試非互動 sudo
5. 先安排好本機儲存的 VM，再批准維護
6. 每台完成後驗證健康狀態；失敗就停下來查，不要直接處理下一台
7. 某一台改手動更新時，`reboot` 前一定先 `node-maintenance enable`，重開驗收後再 `disable`
8. 先按 `Check for updates` 或用 `apt list --upgradable` 確認真的有更新，並檢查有沒有 `ceph-*` 套件；沒有更新時 ProxCenter 不會執行
9. ProxCenter 所在的那台不要和其他台同一輪：分兩輪，中間用 `ha-manager migrate ct:110 <已更新的節點>` 把 ProxCenter 搬走（第 12 節）
10. 精靈的 SSH Addresses 每次都確認是管理網（預設可能是 Cluster 網段）
11. Minimum healthy nodes 只算勾選的節點；只更新一台時用「陪跑」節點加 Manual approval，等待批准時按 Cancel
12. 精靈每次開啟都會回到預設值（Manual approval 關、Reboot timeout 300），要逐項重新檢查，不要沿用上次的印象
13. 沒有更新的節點會被自動略過，不需要陪跑；ProxCenter 所在的節點仍然要放最後一輪，中場先搬走 ProxCenter（第 13 節）

## 15. 常見問題

| 現象 | 原因與處理 |
| --- | --- |
| Repository Issues，但 apt 正常 | 來源目錄裡有備份檔；移到目錄外保留 |
| SSH 測試成功、更新時逾時 | 流程用了 Corosync 網段；明確指定管理網 IP |
| `sudo -n true` 要求密碼 | 流程需要完整免密碼 sudo（本案給了 ALL，屬權限取捨） |
| 本機儲存的 VM 被略過 | 符合設定；另外安排停機 |
| 手動重開後 HA error | 沒先進維護模式（見 HA error 那篇） |
| Rolling Update 沒有執行按鈕 | 沒有可用更新 |
| Verify：`Only N nodes are healthy, and M are needed…` | Minimum healthy nodes 只算勾選的節點；勾 2 台設 1；只勾 1 台時加一台陪跑（第 12-3 節） |
| Minimum healthy nodes 填 0 會跳回 1 | 最小值就是 1，用陪跑做法 |
| 紀錄寫 LXC `has local storage`，但磁碟在 Ceph | ProxCenter 誤判；HA 維護模式仍會搬走，看 `pve-ha-crm` 紀錄確認 |
| 重開後 `MON_CLOCK_SKEW` | 剛開機還在對時，幾分鐘內自己消失；ProxCenter 不會因此停住 |
| 重開後停在 `FS_DEGRADED` | CephFS 的 MDS 在切換，等它恢復；ProxCenter 會等 |
| `Node is already up-to-date, skipping` | 這個節點沒有可更新的套件，ProxCenter 自動略過，不是錯誤（第 13-4 節） |
| 節點被略過了，仍出現 `Waiting for manual approval` | 批准是加在「第一個要更新的節點」前面；Manual approval 開著就要按 Approve（第 13-4 節） |
| 取消後擔心 `noout` 留著 | `ceph osd dump \| grep '^flags'` 確認；10/24 實測取消時會自動清除 |

## 16. 待辦

- [x] 三台都由 ProxCenter 完成一次更新的完整紀錄（2026-10-24，第 12 節；2026-10-29 再做一次，第 13 節）
- [ ] 評估把 ProxCenter 移到叢集外
- [ ] 評估縮小 proxcenter 帳號的 sudo 權限（目前清單最後有 `NOPASSWD: ALL`，前面的細項清單等於沒有作用）
- [ ] 回報或追蹤 ProxCenter 把 Ceph 上的 LXC 判斷成 `has local storage` 的問題

## 17. 延伸閱讀

- [PVE 更新重開後 HA 服務卡在 error：原因與救回步驟](https://kbwangtw.github.io/IT-Knowledge-Base/docs/pve/pve-ha-service-error-after-reboot/)
- [PVE HA 放置策略：PVE HA rules 和 ProxCenter 怎麼分工？](https://kbwangtw.github.io/IT-Knowledge-Base/docs/pve/pve-ha-placement-policy/)
