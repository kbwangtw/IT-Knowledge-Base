---
layout: default
title: "ProxCenter 逐台更新 PVE：三個卡關點怎麼排除？"
date: 2026-08-26
categories: [PVE, ProxCenter, Ceph]
last_modified_at: 2026-10-12
---

# ProxCenter 逐台更新 PVE：三個卡關點怎麼排除？

這次更新被三件不同的事擋住：套件來源檢查讀到備份檔、SSH 連到錯的網段，以及自動流程要求的 sudo 權限與測試項目不同。分開處理後，node12 成功進入套件更新與健康檢查階段。

> 文中 IP 皆為文件示範位址（管理網 192.0.2.0/24、內部網段 198.51.100.0/24），並非實際環境位址；照做前請換成自己的位址。

**8/26 的成功證據到 node12 為止。10/12 的 kernel 更新由 ProxCenter 完成 node11、node12 的更新與重開，node10 改為手動；三台的驗收紀錄見文末。**

> 實測日期：2026-08-26。這是當時版本的排查紀錄；設定中的 IP、帳號與 VMID 是案例值。

## 「逐台更新」是什麼意思？

一次只維護一台，讓其他主機繼續工作。這要求剩下的主機、儲存與網路能承受工作負載，不能只把三台排成順序就直接開始。

本次三台有 quorum，Ceph 為 HEALTH_OK、OSD 3 up／3 in，HA／LRM 正常。更新前先確認：

~~~bash
pvecm status
ceph -s
ha-manager status
pveversion -v
~~~

## 當時使用的更新設定

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

這些是本案設定，不是所有三節點環境的標準答案。尤其「略過本機儲存 VM」不代表它在主機重開時仍會運作，必須另外安排停機。

## 卡關一：APT 正常，檢查器卻說來源有問題

APT 更新本身正常，但 ProxCenter 的檢查仍回報 Repository Issues。本案發現來源目錄裡有 .BAK 備份檔，檢查器也把它們算進去。

先只移出 node10 的兩個備份檔，錯誤從 6 個變成 4 個；處理其他節點後降為 0。這個前後對照，才是定位問題的依據。

~~~bash
apt-cache policy
grep -Rni 'enterprise.proxmox.com' /etc/apt/ 2>/dev/null
ls -la /etc/apt/sources.list.d/
~~~

處理時先確認哪些是備份檔，再移到來源目錄以外並保留原檔，不要把正常使用中的來源刪掉。套件來源應依自己的訂閱與版本設定，不能為了讓檢查變綠就任意切換。

## 卡關二：SSH 測試成功，更新工作卻連不到

單獨測試 SSH 成功；真正更新時卻連到 198.51.100.12:22 而 timeout。原來更新流程自動選了 Corosync 所在網段，和測試時的管理網不同。

本次把 SSH 目的地明確指定為：

~~~text
node10 → 192.0.2.10
node11 → 192.0.2.11
node12 → 192.0.2.12
~~~

**要比的是同一個目的 IP、帳號與驗證方式。** 一個按鈕測試成功，不能證明另一段流程使用的連線也相同。

可從節點日誌核對實際登入：

~~~bash
journalctl --since "10 minutes ago" | grep -Ei 'sshd|proxcenter'
~~~

## 卡關三：可以執行部分管理命令，仍被判定沒有免密碼 sudo

原本允許部分命令，apt、ceph、ha-manager 的個別測試可用，但流程的 sudo -n true 測試仍要求密碼。

~~~bash
visudo -c -f /etc/sudoers.d/proxcenter
sudo -u proxcenter sudo -n -l
sudo -u proxcenter sudo -n true
~~~

本案最後採用：

~~~text
proxcenter ALL=(ALL) NOPASSWD: ALL
~~~

之後測試回傳 0，id 顯示 root，流程得以往下走。這個設定讓帳號取得等同 root 的能力，**是本次採用的權限取捨，不是已驗證的最小權限解法**。若要縮小權限，需依該版本實際執行的完整命令另測。

查看 reboot 的 sudo 權限可以用清單模式；不要為了測試權限直接執行重開：

~~~bash
sudo -u proxcenter sudo -n -l /usr/sbin/reboot
~~~

## VM 被略過，是錯誤嗎？

當時 VM100、VM105 使用本機儲存，因此被略過；VM107 成功搬到 node11。這符合「不關閉本機儲存 VM」的設定，卻也表示它們需要另外安排維護。

第一次工作還曾設定 noout、嘗試維護模式、搬移 VM，然後才在套件更新的 SSH 階段失敗。失敗不代表前面完全沒改變，重試前要重新查：

~~~bash
pvecm status
ceph -s
ha-manager status
ceph osd dump | grep flags
~~~

noout 是維護旗標，不是永久設定。收尾時依實際維護狀態確認是否應解除；不能看到它就盲目清掉，也不能忘記檢查。

## 最後看到了什麼？

修正後，node12 日誌進入以下階段：

~~~text
Enabling maintenance mode
Waiting for HA migrations
Migrating non-HA VMs
Running apt update && apt full-upgrade
Verifying node health
~~~

這支持「原來的三個阻礙已排除，node12 更新流程能往下走」。要宣告整個叢集更新完成，仍需每台的版本、重開後狀態、VM／HA、Ceph 和維護旗標紀錄。

## 2026-10-12：ProxCenter 完成兩台更新與重開

這次更新 kernel（7.0.14-22-pve → 7.0.14-23-pve，pve-manager 維持 9.2.21）。node11、node12 由 ProxCenter 更新並重開，node10 以手動更新。

驗收時三台的 running kernel 都是 7.0.14-23-pve，uptime 分別是 node11 14 分鐘、node12 10 分鐘、node10 8 分鐘。從 uptime 看，ProxCenter 這次先處理 node11，再處理 node12，和 8/26 設定的 node12 → node11 順序不同；記錄時以實際順序為準。

| 項目 | 結果 |
| --- | --- |
| Cluster | Quorate Yes，3 nodes |
| Ceph | HEALTH_OK；3 MON quorum；OSD 3 up／3 in；97 PG active+clean；CephFS healthy |
| `noout` | 已解除 |
| node11、node12 | 沒有 HA 服務異常 |
| node10（手動） | ct:100、vm:107 進入 HA error，已修復 |

node10 的 HA error 不是 ProxCenter 造成的：手動 `reboot` 前沒有先執行 `ha-manager crm-command node-maintenance enable node10`，HA 在關機過程中反覆嘗試啟動服務而失敗。ProxCenter 流程會自動進入維護模式，所以由它處理的兩台沒有這個問題。原因與救回步驟見 [PVE 更新重開後 HA 服務卡在 error](https://kbwangtw.github.io/IT-Knowledge-Base/docs/pve/pve-ha-service-error-after-reboot/)。

同一段時間的 node10 工作紀錄裡，有一筆 proxcenter@pve token 發出的 `hamigrate 107` 為 ERROR（15:42:06）。當時 node10 正在手動更新與重開，本次沒有另外追查這筆搬移請求的來源與失敗原因。

ProxCenter 仍沒有「三台都由它完成」的紀錄。要補齊這個驗證，得先處理下一節「ProxCenter 在自己管理的 cluster 裡」的問題。

## ProxCenter 在自己管理的 cluster 裡

本案的 ProxCenter 是 ct:110，平常在 node11 上，受 PVE HA 管理。輪到 ct:110 所在的 node 時，ProxCenter 會讓這台進入維護模式，HA 再把 ct:110 搬走；容器搬移會先停止再啟動，等於 ProxCenter 在流程途中被自己停掉。ProxCenter 是否特別處理這種情況，本次沒有查證。

因此這個環境採用以下做法（下文稱「方案 A」）：

1. ProxCenter 所在的 node11 先手動更新：`node-maintenance enable` → `apt full-upgrade` → `reboot` → 驗收 → `node-maintenance disable`。維護模式解除時，HA 會把原本在 node11 的服務（包含 ct:110）搬回來。
2. 確認 ct:110 回到 node11，再用 ProxCenter 只更新 node10、node12。
3. 每台之間的人工批准前，確認服務都回到 `started`。

如果要讓 ProxCenter 自己跑完全部三台，比較可靠的做法是把 ProxCenter 移到 cluster 外面，例如另一台主機。本案尚未這樣部署。

## 2026-10-12：沒有可用更新時，ProxCenter 不會啟動

10/12 的 kernel 更新完成後，想用方案 A 實驗一次 rolling update。事前檢查結果：

| 檢查 | 結果 |
| --- | --- |
| `apt list --upgradable`（三台） | 都沒有可更新的套件 |
| node11 上非 HA 的 VM | VM104、VM108，都已關機 |
| HA 規則 | 只有兩條互斥規則（ct:100／ct:101、vm:106／vm:107），沒有把 ct:110 固定在某台 node |
| Cluster／Ceph | Quorate Yes、HEALTH_OK、OSD 3 up／3 in、97 PG active+clean，沒有 `noout` |

ProxCenter 的 Rolling Update 頁面顯示三台版本都是 9.2.21，Available Updates 都是 0，下方訊息為 `0 update(s) available on 0 node(s)` 與 `Up to date`。畫面上只有 `Check for updates` 按鈕，**沒有可以啟動 rolling update 的選項**。

結論：ProxCenter 會先檢查每台的可用更新，全部為 0 時不提供執行，也就不會進入維護模式、搬移服務或重開。它不能拿來單純測試維護模式與重開流程，要等有實際更新時再實驗。ProxCenter 的 Available Updates 與 `apt list --upgradable` 的結果一致。

本次沒有查看 ProxCenter Settings 裡是否有強制執行之類的選項。

執行時可以在 ProxCenter 不會維護的 node 上開一個監看視窗，即時看到維護模式、服務搬移、`noout` 與 OSD 狀態：

~~~bash
watch -n 5 'ha-manager status | grep -E "lrm|service"; echo; ceph osd dump | grep "^flags"; ceph -s | grep -E "health|osd:"'
~~~

這裡用 `grep "^flags"`，只抓 cluster 層級的旗標那一行；只寫 `grep flags` 也會抓到每個 pool 的資料，畫面會被洗掉。

## 下次可直接沿用的檢查順序

1. 先確認 quorum、Ceph、HA 與工作負載容量。
2. 看套件來源的實際有效設定，區分備份檔。
3. 核對更新流程真正使用的 SSH IP。
4. 以同一帳號測試非互動 sudo。
5. 先安排本機儲存 VM，再批准維護。
6. 每台完成後驗證健康狀態；失敗就停下來查，別直接處理下一台。
7. 某一台改用手動更新時，`reboot` 前一定要先 `node-maintenance enable`，重開並驗收後再 `disable`。
8. 先在 ProxCenter 按 `Check for updates` 或用 `apt list --upgradable` 確認真的有更新，並檢查有沒有 `ceph-*` 套件；沒有更新時 ProxCenter 不會執行。
9. ProxCenter 所在的 node 不交給 ProxCenter 更新，改用方案 A 手動處理。
