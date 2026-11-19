---
layout: default
title: "ProxCenter 逐台更新 PVE：三個卡關點怎麼排除？"
date: 2026-08-26
categories: [PVE, ProxCenter, Ceph]
last_modified_at: 2026-11-19
---

# ProxCenter 逐台更新 PVE：三個卡關點怎麼排除？

> **一句話**：用 ProxCenter 自動「一台一台」更新 PVE 叢集時，被三件事擋住：套件來源檢查讀到備份檔、SSH 連錯網段、sudo 權限不足；分開處理後就能往下走。也記錄了 10/12 實際更新的結果、「ProxCenter 不能更新自己所在那台」的問題，10/24 分兩輪讓 ProxCenter 更新完三台的做法，以及 10/29 ProxCenter 在 node10 時的第二次三台更新。11/19 白天再更新一次三台（kernel -29 → -30），兩輪做完後 Ceph 的三個維護旗標沒有被清掉，要手動解除。

| 項目 | 內容 |
| --- | --- |
| 適合誰看 | 第一次用 ProxCenter 做 PVE 滾動更新的人 |
| 環境 | 三台 PVE（node10～12）＋ Ceph；ProxCenter 是 ct:110 |
| 實測 | 2026-08-26（排除三個卡關點，node12 進入更新階段）；2026-10-12（ProxCenter 完成 node11、node12，node10 手動）；2026-10-24（**三台都由 ProxCenter 完成**，分兩輪）；2026-10-29（再次三台，ProxCenter 在 node10，kernel -25 → -26）；2026-11-17（**人不在現場、沒有 BMC**，node10 → node12 → node11，kernel -28 → -29，第 14 節）；2026-11-19（白天、分兩輪，kernel -29 → -30，**更新後旗標沒清**，第 15 節） |
| 結論 | ✅ 三個卡關點已排除；✅ 10/24 三台都由 ProxCenter 更新並重開（kernel 7.0.14-23 → -25），HA 服務沒有中斷、Ceph 回到 HEALTH_OK（第 12 節）；✅ 10/29 再做一次三台更新，已是最新的節點會被自動略過，不需要「陪跑」（第 13 節）；✅ 11/17 人不在現場，一次一台更新三台到 kernel `7.0.14-29`、pve-manager 9.2.28：13 個 HA 服務 `started`、Ceph `HEALTH_OK`、`noout` 已清除；**不在 HA 的執行中 VM（nextcloud）要先線上搬走**（第 14 節）；✅ 11/19 三台更新到 kernel `7.0.14-30`、pve-manager 9.2.31，但**更新結束後 `noout`、`norebalance`、`norecover` 都還在、25 個 PG degraded**，手動解除後回到 `HEALTH_OK`、97 個 PG `active+clean`（第 15 節）；⏳ 把 ProxCenter 移到叢集外、縮小 sudo 權限、查清楚旗標沒被清除的原因 |

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

## 14. 2026-11-17：人不在現場、沒有 BMC，一次一台更新三台（node10 → node12 → node11）

**做什麼**：三台各有 24 個可更新套件（ProxCenter 畫面顯示 25，**推測**多的 1 個是 signed kernel image，和 10/29 相同），要在**人不在現場、三台都沒有 IPMI／BMC**（使用者確認）的情況下更新並重開。重開後若有一台沒起來，**只能到現場處理**，所以做法是「一次一台、每台驗收通過才批准下一台、嚴格停損」。

### 14-1 更新內容與風險

ProxCenter 的 Rolling Update 畫面：三台都是 9.2.26、每台 25 個更新、預估每台約 29 分鐘、共約 1 小時 27 分、需重開 3 次。以下只列出符合篩選（`ceph`、`proxmox-kernel`、`grub`、`ifupdown2`、`pve-firewall`、`pve-manager`、`qemu`）的套件名稱，**24 個的完整清單沒有記錄**：

| 套件 | 影響 |
| --- | --- |
| `proxmox-kernel-7.0` | 要重開才生效（node11 更新前是 `7.0.14-28`，另兩台沒有看到輸出，推測相同） |
| `ifupdown2` | 網路設定工具；11/05 也更新過，三台重開正常（見[更新後逐台重開](https://kbwangtw.github.io/IT-Knowledge-Base/docs/pve/pve-rolling-reboot-after-update/)） |
| `pve-manager` | 套件升級時服務自動重啟；更新前 9.2.26（ProxCenter 畫面），更新後 9.2.28 |
| `pve-qemu-kvm` | 已在跑的 VM 要遷移或重啟才會用新版 QEMU；維護模式的線上遷移剛好達成 |
| 沒有 `ceph-*`、`grub`、`pve-firewall` | 依上面的篩選結果；比 11/05 單純 |

| 選項 | 內容 | 評估 |
| --- | --- | --- |
| **A. 全部一次一台、嚴格停損（本次採用）** | node10 驗收通過才批准 node12，再做 node11；任何一台 10 分鐘沒回來就全部停下 | 有 11/05 同一組套件的先例；一台出事時另外兩台仍有 quorum 與 Ceph（2/3） |
| B. 只做 node10 | 觀察一天，其餘等人在現場 | 風險最小，要多花一輪 |
| C. 等到人在現場 | 最保險 | 沒有時間壓力時最好 |

**重開沒回來時**：不要碰別台、確認 `pvecm status`／`ceph -s`／`ha-manager status`（服務應都在剩下兩台且 `started`）、不要 `ceph osd out`（`noout` 還在）；到現場接螢幕，若是新核心的問題就在開機選單選舊核心。Wake-on-LAN 只對「已關機」有用，對「卡住」沒用，不能當退路。

### 14-2 更新前檢查（唯讀，08:16）

```bash
tmux new -s update
date
pvecm status | grep -E 'Quorate|Nodes:'
ceph -s | grep -E 'health|osd:|pgs:'
ceph health detail
ha-manager status | grep -E '^(quorum|master)|ct:|vm:'
for n in node10 node11 node12; do echo "== $n"; ssh root@$n 'apt list --upgradable 2>/dev/null | grep -c upgradable; apt list --upgradable 2>/dev/null | grep -iE "ceph|proxmox-kernel|grub|ifupdown2|pve-firewall|pve-manager|qemu" | cut -d/ -f1 | tr "\n" " "; echo'; done
for n in node10 node11 node12; do echo -n "$n 備份程序數："; ssh root@$n 'ps aux | grep -c "[v]zdump"' < /dev/null; done
for n in node10 node11 node12; do echo "== $n 最近備份"; ssh root@$n 'pvenode task list --typefilter vzdump --limit 1' < /dev/null; done
pvesh get /cluster/resources --type vm --output-format json | python3 -c "import json,sys;[print(r['vmid'],r.get('name'),r['node'],r['status']) for r in sorted(json.load(sys.stdin),key=lambda r:r['vmid'])]"
```

| 片段 | 意思 |
| --- | --- |
| `tmux new -s update` | 斷線（例如 VPN 中斷）後用 `tmux attach -t update` 接回 |
| `apt list --upgradable \| grep -c upgradable` | 每台可更新的套件數；三台應相同 |
| `grep -iE "ceph\|proxmox-kernel\|grub…"` | 挑出「出錯會讓節點連不上或影響 Ceph」的套件名稱 |
| `ps aux \| grep -c "[v]zdump"` | 有沒有備份正在跑，應為 0 |
| `pvenode task list --typefilter vzdump --limit 1` | 昨晚備份的結果 |
| `pvesh get /cluster/resources --type vm …` | 列出所有 VM／CT 與所在節點，用來對照 HA（見 14-3） |

**看到的結果**：

| 檢查 | 結果 |
| --- | --- |
| 叢集 | `Quorate: Yes`、3 節點 |
| Ceph | `HEALTH_OK`、3 up（since 11d）、3 in、`volumes 1/1 healthy`、97 個 PG `active+clean` |
| HA | `quorum OK`、master 在 node10；13 個服務都 `started` |
| 可更新套件 | 三台都是 24 個；符合篩選的：`ifupdown2`、`proxmox-kernel-7.0`、`pve-manager`、`pve-qemu-kvm` |
| 備份程序數 | 三台都是 0 |
| 昨晚（11/16）備份 | node10 21:00～21:12 `OK`；node11 21:30～21:38 `WARNINGS: 2`；node12 22:00～22:12 `OK`。node11 的警告**依 KB 是 VM 108 關機的已知現象，但這次沒有看日誌確認** |

更新前的位置：

| 節點 | HA 資源 | 非 HA |
| --- | --- | --- |
| node10 | ct:103、105、113、114、vm:106 | VM 104（stopped） |
| node11 | ct:100、**110（ProxCenter）**、112 | VM 108（stopped，VGA 直通）、**VM 115 nextcloud（running）** |
| node12 | ct:101、102、109、vm:107、111 | — |

### 14-3 不在 HA 的執行中 VM：VM 115（nextcloud）

`pvesh` 列出 16 個 VM／CT，HA 只有 13 個，多的是 VM 104、108（都是 stopped）和 **VM 115（running）**。

| 事實 | 影響 |
| --- | --- |
| VM 115 不在 HA | 節點進維護模式時，HA **不會**搬它；node11 重開時它會被關機再開機，Nextcloud 停機數分鐘 |
| 依[Nextcloud SOP](https://kbwangtw.github.io/IT-Knowledge-Base/docs/pve/nextcloud-vm-docker-compose-sop/)，磁碟在 Ceph `VM_Pool`、`onboot=1`、建立時沒有設 `hostpci` | **可以線上搬**；實際的 `qm config 115` 輸出這次**沒有記錄** |

做法：在 node11 那一輪**之前**，用 `qm migrate 115 <已更新的節點> --online` 線上搬走。**結果**：使用者回報第 2 輪前 VM 115 已在 node10；用什麼方式搬、搬了多久沒有記錄。

### 14-4 流程與第 1 輪（node10 → node12）結果

```text
第 1 輪：精靈勾選 node10（排第一）、node12（排第二），Manual approval 開
        node10 驗收通過 → Approve node12
中場：  ProxCenter（ct:110）搬離 node11、VM 115 線上搬走
第 2 輪：精靈只勾 node11（另兩台已是最新，會自動略過），Approve
```

| 設定 | 建議值 |
| --- | --- |
| SSH Addresses | 管理網（`vmbr0 (gw)`），不是 `Cluster` |
| Manual approval between each node | 開 |
| Reboot timeout | 600 |
| Minimum healthy nodes | 1（只算勾選的節點） |

以上是計畫與建議值，**精靈實際設定沒有截圖記錄**。node11 放最後，是因為 ProxCenter 在 node11；node12 放第 1 輪最後，是因為 WireGuard（ct:109）在 node12，VPN 只會在那一段中斷。

第 1 輪完成後驗收（唯讀）：

```bash
for n in node10 node12; do echo "== $n"; ssh root@$n 'uname -r; pveversion | head -1; pve-firewall status; systemctl is-active pve-cluster corosync pveproxy pve-ha-lrm'; done
pvecm status | grep -E 'Quorate|Nodes:'
corosync-cfgtool -s | grep -E 'LINK ID|nodeid'
ceph -s | grep -E 'health|osd:|pgs:'
ceph osd dump | grep '^flags'
ha-manager status | grep -E 'ct:|vm:'
for n in node10 node11 node12; do echo -n "$n 核心："; ssh root@$n 'uname -r'; done
```

| 檢查 | 結果 |
| --- | --- |
| node10、node12 | 核心 `7.0.14-29-pve`、`pve-manager 9.2.28`；`enabled/running`、四個服務都 `active` |
| node11 | 核心還是 `7.0.14-28-pve`（預期，還沒更新） |
| 叢集 | `Quorate: Yes`、3 節點；LINK 0、LINK 1 對另兩台都 `connected` |
| Ceph | `HEALTH_OK`、3 up（since 7m）、97 個 PG `active+clean`；`flags` 沒有 `noout`（ProxCenter 結束時自動清除） |
| HA | 13 個服務都 `started` |
| **ProxCenter（ct:110）** | **已經在 node12**，不在 node11；中場有沒有執行 `ha-manager migrate ct:110`、或是別的原因，**沒有記錄（未確認）** |

### 14-5 第 2 輪（node11）與最後驗收（08:52）

最後驗收用的指令和上面相同（三台都查）；另外 `qm status 115`、`ceph -s`：

| 檢查 | 結果 |
| --- | --- |
| 三台版本 | 核心都是 `7.0.14-29-pve`、`pve-manager 9.2.28`；`enabled/running`、四個服務都 `active` |
| 叢集 | `Nodes: 3`、`Quorate: Yes`；LINK 0、LINK 1 都 `connected` |
| Ceph | `HEALTH_OK`、3 up（since 91s）、3 in、`volumes 1/1 healthy`；`flags` 沒有 `noout` |
| PG | `ceph -s \| grep pgs` 只看到 **96** 個 `active+clean`；**第 97 個沒有看到（見下）** |
| HA | `quorum OK`、master 在 node12；三台 `lrm` 都是 `active`（沒有 `maintenance`）；13 個服務都 `started` |
| `qm status 115` | 在 node12 執行，回報 `Configuration file 'nodes/node12/qemu-server/115.conf' does not exist` |

- **96 個 PG**：`grep pgs` 只印含 `pgs` 的那一行，第二行（例如 `1 active+clean+scrubbing+deep`）被切掉，OSD 剛回來時常見（見第 17 節）；**這次沒有用 `ceph pg stat` 確認第 97 個的狀態**，所以是「未確認」。
- **`qm status 115` 的錯誤**：`qm` 只查**本機**的 VM，VM 115 在 node10，在 node12 查不到，**不代表 nextcloud 有問題**；要看位置用 `pvesh get /cluster/resources --type vm`。這次**沒有用正確的方式確認 VM 115 是 `running`**。

最後的位置：

| 節點 | HA 資源 | 非 HA |
| --- | --- | --- |
| node10 | ct:101、103、105、113、114、vm:106（6 個） | VM 104（stopped）、VM 115（使用者回報在此） |
| node11 | ct:100、112（2 個） | VM 108（stopped） |
| node12 | ct:102、109、110（ProxCenter）、vm:107、111（5 個） | — |

| 規則 | 結果 |
| --- | --- |
| DC01（node10）與 DC02（node12）不同節點 | ✅ **這條只存在 ProxCenter，PVE HA 沒有**，是剛好沒落在同一台 |
| AdGuard（node11）與 Pihole（node10）不同節點 | ✅ PVE 規則 |
| 三套監控分開：Graylog node10、Wazuh node11、LibreNMS node12 | ✅ |

分布是 6／2／5，node11 只有 2 個；CRS 是 static，HA 不會自動搬回平均，**這不是錯誤**，要再分散見[HA 放置策略](https://kbwangtw.github.io/IT-Knowledge-Base/docs/pve/pve-ha-placement-policy/)第 13 節。

### 14-6 沒有記錄到的

| 項目 | 狀態 |
| --- | --- |
| 各輪實際開始與完成時間 | 沒有記錄（08:16 開始檢查、08:52 看到最後驗收；ProxCenter 預估 1 小時 27 分，實際明顯較短，但沒有逐台時間） |
| 精靈實際設定、Verify 結果 | 沒有記錄 |
| 中場做了什麼（ct:110 為何在 node12、VM 115 怎麼搬） | 沒有記錄 |
| 過程異常：VPN 中斷多久、告警信（Graylog／Wazuh／LibreNMS）、ProxCenter 網頁、Lab Ops `Session creation failed` | 沒有記錄 |
| 第 97 個 PG、VM 115 的實際狀態 | 未確認（見 14-5） |
| 當晚（11/17）三台備份 | 尚未看到 |

### 14-7 這次學到的

- ProxCenter 的維護模式只搬 HA 資源；**不在 HA 的執行中 VM 要自己先線上搬走**。更新前用 `pvesh get /cluster/resources --type vm` 對照 `ha-manager status` 找出它們。
- `qm` 指令只查本機；驗收時 VM 在哪台要用 `pvesh` 查，不要在任一台直接 `qm status`。
- 人不在現場時，停損規則要事先寫好：一台 10 分鐘沒回來就停，不碰別台。

## 15. 2026-11-19：白天更新，兩輪做完後 Ceph 旗標沒清（node10、node12 → node11）

**做什麼**：三台各有 14 個可更新套件（ProxCenter 畫面顯示 15，**推測**多的 1 個是 signed kernel image，和 10/29、11/17 相同），要更新到 kernel `7.0.14-30`、pve-manager 9.2.31。這次是白天、人在線上操作，分兩輪：第 1 輪 node10、node12，第 2 輪 node11（ProxCenter 在 node11）。重點是**兩輪結束後，Ceph 的三個維護旗標沒有被清掉**，要手動解除。

### 15-1 更新前檢查（唯讀，08:20）

| 檢查 | 結果 |
| --- | --- |
| 版本 | 三台都是 kernel `7.0.14-29-pve`、pve-manager 9.2.28，uptime 約 1 天 23 小時（和 11/17 更新時間吻合） |
| 可更新套件 | 三台都是 14 個；符合篩選的只有 `proxmox-kernel-7.0`、`pve-manager`、`qemu-server`；**沒有** `ceph-*`、`grub`、`ifupdown2`、`pve-firewall`、`corosync`、`libknet`。這是 apt 快取，更新前沒有另外跑 `apt update`，清單以 ProxCenter 的 `Check for updates` 為準 |
| 套件狀態、來源 | `dpkg --audit` 三台都沒輸出；`/etc/apt/sources.list.d/` 三台一致（`ceph.sources`、`debian.sources`、`proxmox.sources`），沒有 `.BAK` 備份檔 |
| 叢集 | `Quorate: Yes`、3 節點；Corosync LINK 0、LINK 1 都 `connected` |
| Ceph | `HEALTH_OK`、3 MON quorum（leader node10）、OSD 3 up／3 in、97 個 PG `active+clean`、沒有任何旗標；用量 1.3 TiB／5.5 TiB（約 24%） |
| HA | `quorum OK`、master 在 node12、fencing armed、三台 `lrm` 都是 `active`；14 個服務（10 個 CT、4 個 VM）都 `started`；`shutdown_policy=migrate` |
| 儲存與副本 | `VM_Pool` 是 Ceph RBD；4 個 pool 都是 size 3、min_size 2；10 個 CT 都沒有 `mp*`、`dev*`（沒有 bind mount 和直通） |

HA 服務是 14 個，比 11/17 的 13 個多 1 個。**推測**是 VM 115（nextcloud）已加入 HA（查詢結果顯示它在 HA 內、`onboot=1`）；這次沒有用 `ha-manager config` 單獨確認。

不在 HA 的 VM 只剩兩台，**都是 `stopped`**：

| VM | 節點 | 磁碟 | 特殊項目 | `onboot` | 影響 |
| --- | --- | --- | --- | --- | --- |
| 104 UBClient | node10 | `scsi0` 60G（`VM_Pool`） | 無 | 未設定 | 關機中，不需處理 |
| 108 WinClient | node11 | `scsi0` 60G（`VM_Pool`） | `hostpci0`（PCI 直通） | 0 | 有直通不能線上遷移；關機中不需處理，**更新期間不要開機** |

> 更新前原本以為 VM 108 是開機的（10/29 是關機），查詢結果是 `stopped`。所以不需要先正常關機。若它是開機的，ProxCenter 的「Migrate non-HA VMs」會嘗試遷移它並失敗，`Abort on failure` 會讓流程在節點已進維護模式後中止（**推測**，這次沒有發生）。

更新前的位置（running）：

| 節點 | 資源 |
| --- | --- |
| node10 | ct:101、103、105、113（Lab Ops 所在）、114、vm:106 |
| node11 | ct:100、110（ProxCenter）、112、VM 115 |
| node12 | ct:102、109（WireGuard）、vm:107、111 |

### 15-2 更新前發現：昨晚（11/18）備份的異常

| 節點 | 排程 | 結果 | 內容 |
| --- | --- | --- | --- |
| node10 | 21:00:01～21:07:59 | `ERROR` | **只有 VM 104 失敗**：`qmp command 'query-pbs-bitmap-info' failed - got timeout`；CT 101、103、105、113、114 與 vm:106 都成功 |
| node11 | 21:30:01～21:38:21 | `WARNINGS: 2` | 全部來自 VM 108，備份最後 `Finished`（2 分 55 秒） |
| node12 | 22:00:01～22:05:37 | `OK` | |

- **VM 104**：它是 stopped 的 VM，備份時 PVE 會暫時起一個 QEMU 讀磁碟，失敗的是這個程序查詢 PBS dirty-bitmap 時逾時。原因**不確定**（推測是 PBS 或網路當下較慢）；104 過去幾天是不是一直失敗，**沒有查**。
- **VM 108**：log 裡的三類訊息是 `no efidisk configured! Using temporary efivars disk.`、`iothread is only valid with virtio disk or virtio-scsi-single controller, ignoring`（`scsi0` 設了 `iothread=1`，控制器是 `virtio-scsi-pci`，這個設定不會生效）、`failed to reset PCI device`（備份 stopped 的 VM 時會碰到直通裝置）。都是 108 的設定造成，和更新無關。
- **備份有沒有在跑**：`ps aux | grep -c "[v]zdump"` 的計數不可靠（node11、node12 回 1，node10 回 5；**推測**是遠端指令列本身含 `vzdump` 字樣）。要確認用 `pgrep -x vzdump`（精確比對程序名稱，沒輸出代表沒有）。

**判斷**：兩台的問題都不擋更新，各台 running 的資源昨晚都有備份。更新是節點層，風險在重開，不在 guest 資料，所以沒有再額外做一次備份。

### 15-3 第 1 輪（node10、node12）的精靈與 Verify

精靈每次都會回到預設值，要逐項重新確認（SSH Addresses 管理網、Manual approval 開、Reboot timeout 600、Minimum healthy nodes 1、不勾 node11）。使用者回報「設定都確認了」，**實際值沒有逐項記錄**。

Verify 畫面：

| 項目 | 看到 |
| --- | --- |
| 總結 | `All checks passed`，預估約 47 分鐘 |
| 叢集 | Quorum OK、3/3 票（quorum 2）、3/3 節點在線 |
| 可更新 | node10、node12 各 15 個套件 |
| 重開 | `2/2 nodes will likely require a reboot (kernel updates detected)` |
| 遷移 | `10 VMs will be migrated`，對得上 node10 的 6 個加 node12 的 4 個 running 資源 |

起跑前先確認：

```bash
for n in node10 node12; do echo "== $n"; ssh root@$n 'apt list --upgradable 2>/dev/null | grep -vc "^Listing"; apt list --upgradable 2>/dev/null | grep -iE "ceph|proxmox-kernel|grub|ifupdown2|pve-firewall|pve-manager|qemu|corosync|libknet" | cut -d/ -f1 | tr "\n" " "; echo'; done
```

| 片段 | 意思 |
| --- | --- |
| `grep -vc "^Listing"` | 可更新套件數；ProxCenter 的 15 比快取的 14 多 1 |
| `grep -iE "ceph\|…\|corosync\|libknet"` | 挑出「出事會讓節點連不上、影響 Ceph 或叢集通訊」的套件；有的話先停下來看 |

監看視窗開在這一輪不會重開的 node11（用 tmux），內容和第 11 節相同。

### 15-4 兩輪做完之後

使用者回報：三台分兩次更新完之後「有些指令沒執行」，**沒有說是哪些**。ct:110（ProxCenter）的行為是：**node11 進維護模式時被 HA 搬走，解除後自己回來**。中場有沒有手動 `ha-manager migrate ct:110`，**沒有記錄**（依上述回報，**推測**沒做）。

ProxCenter 的 Rolling Update 頁面最後顯示：

| 節點 | Version | Available Updates | VMs | Status |
| --- | --- | --- | --- | --- |
| node10 | 9.2.31 | 0 | 7 | Online |
| node12 | 9.2.31 | 0 | 4 | Online |
| node11 | 9.2.31 | 0 | 5 | Online |

下方是 `0 update(s) available on 0 node(s)`。

### 15-5 發現旗標沒清：Ceph 是 `HEALTH_WARN`

ProxCenter 叢集頁的 OSD Flags 顯示 **`noout`、`norebalance`、`norecover`** 都還在，Ceph 是 Warning。唯讀檢查：

| 檢查 | 結果 |
| --- | --- |
| 版本 | 三台都是 kernel `7.0.14-30-pve`（也是執行中的核心）、pve-manager 9.2.31；可更新 0 |
| 旗標 | `noout,norebalance,norecover` |
| Ceph health | `HEALTH_WARN`：157／366300 個物件 degraded（0.043%）、25 個 PG degraded、9 個 PG undersized |
| PG | 97 個裡 64 個 `active+clean`，其餘是 `recovery_wait` 或 `recovering` |
| undersized 的 PG | 超過 44 分鐘只有 2 份副本（`[0,2]` 或 `[2,0]`，少 osd.1 那份）；osd.1 已經回來，因為其他 PG 的 acting set 有它 |
| HA | quorum OK，三台 `lrm` 都是 `active`，14 個服務都 `started` |
| 用量與 IO | 約 5.2 MiB/s 讀、812 KiB/s 寫 |

**原因不確定。** 推測：ProxCenter 在第 2 輪（node11）被 HA 搬走時，流程被中斷，來不及清旗標（第 10 節的風險）。`norebalance`、`norecover` 是誰設的**也未確認**：這份文章過去只記錄 ProxCenter 設與清 `noout`，這兩個旗標可能是 ProxCenter 新版的行為，也可能是手動設的，沒有查執行紀錄。

**`norecover` 開著時 PG 停在 `recovery_wait` 是旗標造成的，不是壞掉。** 但 9 個 PG 只有 2 份副本，而 `min_size` 是 2，等於**沒有容錯餘裕**；這段期間不要再動任何節點、OSD 或網路。

### 15-6 解除旗標的步驟

先確認三台都更新完、HA 沒有節點在維護模式、PG 沒有 `inactive`，再依序解除（改狀態的指令，自己在 shell 貼）：

```bash
ceph osd unset norecover
watch -n 5 'ceph -s | grep -E "health|pgs|degraded|recovering|io:"'
```

| 片段 | 意思 |
| --- | --- |
| `ceph osd unset norecover` | 先讓 recovery 開始，把缺的第三份副本補回來 |
| `watch … grep -E …` | 每 5 秒看 degraded 與 PG 狀態；`io:` 底下的縮排行會被 `grep` 切掉，畫面上 `io:` 空白不是異常 |

**應該看到**：degraded 的數字下降，最後 `97 active+clean`。這次量很小（0.043%），很快就完成。

PG 全部 `active+clean` 後，先確認警告只剩旗標：

```bash
ceph health detail
```

```text
HEALTH_WARN noout,norebalance flag(s) set
[WRN] OSDMAP_FLAGS: noout,norebalance flag(s) set
```

再解除另外兩個：

```bash
ceph osd unset norebalance
ceph osd unset noout
ceph osd dump | grep '^flags'
ceph -s
```

**看到的結果**：

| 項目 | 結果 |
| --- | --- |
| `flags` | `sortbitwise,recovery_deletes,purged_snapdirs,pglog_hardlimit`，沒有任何維護旗標 |
| health | `HEALTH_OK` |
| MON／MGR／MDS | 3 個 MON 都在 quorum（leader node10）；MGR active 在 node12；MDS 1／1 up、2 standby |
| OSD | 3 up（since 49m）、3 in |
| 資料 | `volumes: 1/1 healthy`、4 pools、97 pgs、122.10k objects、465 GiB；1.3 TiB 已用、4.2 TiB 可用 |
| PG | 97 `active+clean` |
| IO | 約 3.4 KiB/s 讀、528 KiB/s 寫 |

### 15-7 最後驗收

| 檢查 | 結果 |
| --- | --- |
| HA | quorum OK、master 在 node12；三台 `lrm` 都是 `active`、watchdog active；14 個服務都 `started`；沒有 `error`、`maintenance`、`migrate`、`relocate` |
| VM／CT | 共 16 個，14 個 running；VM 104（node10）、108（node11）`stopped`，和更新前一致 |
| 分布 | node10 有 7 個（含 stopped 的 104）、node11 有 5 個（含 stopped 的 108）、node12 有 4 個；ct:110 在 node11 |
| 版本 | 三台 `7.0.14-30-pve`、9.2.31（kernel 版本來自 Lab Ops 回報的 `uname -r`，ProxCenter 頁面只顯示 9.2.31） |

分布是 7／5／4，CRS 是 static，HA 不會自動搬回平均，**這不是錯誤**（見[HA 放置策略](https://kbwangtw.github.io/IT-Knowledge-Base/docs/pve/pve-ha-placement-policy/)）。

### 15-8 沒有記錄到的

| 項目 | 狀態 |
| --- | --- |
| 精靈實際設定（兩輪） | 沒有逐項記錄 |
| 兩輪各自的開始與完成時間、node10 驗收後才批准 node12 的紀錄 | 沒有記錄 |
| 「有些指令沒執行」是哪些；中場有沒有手動搬 ct:110 | 沒有記錄 |
| `norebalance`、`norecover` 是誰設的、旗標為什麼沒被清除 | 未確認 |
| 過程異常：VPN 中斷多久、Lab Ops 斷線、告警信（Graylog／Wazuh／LibreNMS） | 沒有記錄 |
| 更新前三台 `pve-firewall status`、VM 115 是否已加入 HA（`ha-manager config`） | 未確認 |
| VM 104 過去幾天的備份是否一直失敗 | 沒有查 |
| 當晚（11/19）三台備份 | 尚未看到 |

### 15-9 這次學到的

- **兩輪更新結束後，一定要查 `ceph osd dump | grep '^flags'`**，不要假設 ProxCenter 一定會清掉。旗標沒清，日後 OSD 真的故障時 Ceph 不會自動處理。
- 清旗標前先確認 PG 沒有 `inactive`、HA 沒有節點在維護模式；順序是 `norecover` → 等 recovery 完成 → `norebalance`、`noout`。
- `norecover` 開著時，PG 停在 `recovery_wait` 不是故障，但副本數會一直少一份。
- 判斷備份是否在跑用 `pgrep -x vzdump`，不要用 `ps aux | grep -c`（會算到指令列自己）。
- `grep` 只印含關鍵字的那一行，多行輸出（例如 `io:` 底下）會被切掉；判讀前先看完整的 `ceph -s`。

## 16. 下次可以直接照做的檢查順序

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
14. 更新前用 `pvesh get /cluster/resources --type vm` 對照 `ha-manager status`，找出**不在 HA 的執行中 VM／CT**；維護模式不會搬它，要先 `qm migrate <VMID> <已更新的節點> --online` 或排停機（第 14 節）
15. 人不在現場、沒有 BMC 時：一次一台，每台驗收通過才批准下一台；任何一台 10 分鐘沒回來就停，不碰別台（第 14 節）
16. 兩輪都做完後，用 `ceph osd dump | grep '^flags'` 確認 `noout`、`norebalance`、`norecover` 都已清除；ProxCenter 不一定會清（第 15 節）
17. 旗標沒清時：先確認三台版本、PG 沒有 `inactive`、HA 沒有節點在 `maintenance`，再依序 `ceph osd unset norecover` → 等全部 `active+clean` → `ceph osd unset norebalance`、`ceph osd unset noout`（第 15-6 節）
18. 第 2 輪前記得先把 ProxCenter（ct:110）搬離要更新的節點；沒搬時它會被 HA 搬走又回來，旗標可能沒清（第 15-4 節，**推測**）

## 17. 常見問題

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
| `qm status <VMID>` 回報 `Configuration file 'nodes/<節點>/qemu-server/<VMID>.conf' does not exist` | `qm` 只查本機的 VM；VM 在別台時用 `pvesh get /cluster/resources --type vm` 看位置，或到那台執行（第 14-5 節） |
| 更新前 `pvesh` 列出的 VM／CT 比 HA 資源多 | 多出來的是不在 HA 的（關機的 104、108，執行中的 115）；執行中的要先線上搬走，維護模式不會搬它（第 14-3 節） |
| 人不在現場，有一台重開後沒回來 | 不要碰別台；另外兩台有 quorum 與 Ceph，服務都在它們上面；到現場處理（第 14-1 節） |
| 更新後 Ceph 是 `HEALTH_WARN`，`noout`、`norebalance`、`norecover` 還在 | ProxCenter 沒清掉；先確認 PG、HA，再依序手動 `ceph osd unset`（第 15-5、15-6 節） |
| PG 一直停在 `recovery_wait`、有 PG undersized | `norecover` 開著造成的，不是壞掉；先 `ceph osd unset norecover`，這段期間不要再動節點（第 15-5 節） |
| `ps aux \| grep -c "[v]zdump"` 回非 0，但沒有備份在跑 | 計數會算到遠端指令列自己；改用 `pgrep -x vzdump`（第 15-2 節） |
| 備份 stopped 的 VM 108 出現 `failed to reset PCI device`、`no efidisk configured` | 108 有 PCI 直通、沒有 EFI 磁碟造成，備份仍會完成，和更新無關（第 15-2 節） |
| 備份 VM 104 出現 `query-pbs-bitmap-info failed - got timeout` | 11/18 單次失敗，原因未確認；先看過去幾天是否一直失敗（第 15-2 節） |

## 18. 待辦

- [x] 三台都由 ProxCenter 完成一次更新的完整紀錄（2026-10-24，第 12 節；2026-10-29 再做一次，第 13 節）
- [x] 2026-11-17 人不在現場、一次一台再更新三台（第 14 節）
- [ ] 確認 11/17 最後驗收只看到 96 個 `active+clean` 行，第 97 個 PG 的狀態（`ceph pg stat`）
- [x] 用 `pvesh get /cluster/resources --type vm` 確認 VM 115 的位置與 `running` 狀態（2026-11-19 查詢：VM 115 在 node11、running，第 15 節）
- [ ] 確認 11/17 當晚（21:00、21:30、22:00）三台備份都 `OK`（沒有看到；11/18 當晚的結果見第 15-2 節）
- [x] 2026-11-19 白天再更新三台（kernel -29 → -30），並手動解除更新後遺留的 Ceph 旗標（第 15 節）
- [ ] 確認 11/19 當晚（21:00、21:30、22:00）三台備份，這是更新後的第一次排程備份
- [ ] 查 VM 104 近幾天的備份是否一直 `query-pbs-bitmap-info` 逾時（`pvesh get /nodes/node10/storage/PBS31/content --vmid 104` 看最近幾筆的時間）
- [ ] 查清楚 `norebalance`、`norecover` 是 ProxCenter 設的還是手動設的，以及兩輪做完旗標為什麼沒被清除；若是 ProxCenter 新版行為，要更新第 12～14 節「只設 `noout`」的說法
- [ ] 補記 11/19 兩輪實際時間、精靈實際設定、中場有沒有搬 ct:110、有哪些指令沒執行，與異常（VPN／Lab Ops／告警），使用者尚未提供
- [ ] 用 `ha-manager config` 確認 VM 115 是否已加入 HA（11/17 時不在 HA）
- [ ] 補記 11/17 各輪實際時間、精靈實際設定、中場做法（ct:110 為何在 node12）與異常（VPN／Lab Ops／告警），使用者尚未提供
- [ ] 評估把 ProxCenter 移到叢集外
- [ ] 評估縮小 proxcenter 帳號的 sudo 權限（目前清單最後有 `NOPASSWD: ALL`，前面的細項清單等於沒有作用）
- [ ] 回報或追蹤 ProxCenter 把 Ceph 上的 LXC 判斷成 `has local storage` 的問題

## 19. 延伸閱讀

- [ProxCenter 企業版更新與擴容：1.4.11 → 1.4.12](https://kbwangtw.github.io/IT-Knowledge-Base/docs/pve/proxcenter-enterprise-update/)：同日更新 ProxCenter 本身與 CT110 擴容
- [PVE 更新重開後 HA 服務卡在 error：原因與救回步驟](https://kbwangtw.github.io/IT-Knowledge-Base/docs/pve/pve-ha-service-error-after-reboot/)
- [PVE HA 放置策略：PVE HA rules 和 ProxCenter 怎麼分工？](https://kbwangtw.github.io/IT-Knowledge-Base/docs/pve/pve-ha-placement-policy/)
- [PVE 更新後逐台重開（人不在現場）：維護模式加 noout，一次一台](https://kbwangtw.github.io/IT-Knowledge-Base/docs/pve/pve-rolling-reboot-after-update/)：11/05 不用 ProxCenter、手動做的版本
