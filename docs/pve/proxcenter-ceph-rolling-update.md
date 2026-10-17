---
layout: default
title: "ProxCenter 逐台更新 PVE：三個卡關點怎麼排除？"
date: 2026-08-26
categories: [PVE, ProxCenter, Ceph]
last_modified_at: 2026-10-17
---

# ProxCenter 逐台更新 PVE：三個卡關點怎麼排除？

> **一句話**：用 ProxCenter 自動「一台一台」更新 PVE 叢集時，被三件事擋住：套件來源檢查讀到備份檔、SSH 連錯網段、sudo 權限不足；分開處理後就能往下走。也記錄了 10/12 實際更新的結果，以及「ProxCenter 不能更新自己所在那台」的問題。

| 項目 | 內容 |
| --- | --- |
| 適合誰看 | 第一次用 ProxCenter 做 PVE 滾動更新的人 |
| 環境 | 三台 PVE（node10～12）＋ Ceph；ProxCenter 是 ct:110 |
| 實測 | 2026-08-26（排除三個卡關點，node12 進入更新階段）；2026-10-12（ProxCenter 完成 node11、node12，node10 手動） |
| 結論 | ✅ 三個卡關點已排除；⏳ 還沒有「三台都由 ProxCenter 完成」的紀錄 |

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

## 12. 下次可以直接照做的檢查順序

1. 確認 quorum、Ceph、HA 與工作負載容量
2. 看套件來源的實際設定，區分出備份檔
3. 核對更新流程**真正使用**的 SSH IP
4. 用同一個帳號測試非互動 sudo
5. 先安排好本機儲存的 VM，再批准維護
6. 每台完成後驗證健康狀態；失敗就停下來查，不要直接處理下一台
7. 某一台改手動更新時，`reboot` 前一定先 `node-maintenance enable`，重開驗收後再 `disable`
8. 先按 `Check for updates` 或用 `apt list --upgradable` 確認真的有更新，並檢查有沒有 `ceph-*` 套件；沒有更新時 ProxCenter 不會執行
9. ProxCenter 所在的那台不交給 ProxCenter 更新，改用方案 A 手動處理

## 13. 常見問題

| 現象 | 原因與處理 |
| --- | --- |
| Repository Issues，但 apt 正常 | 來源目錄裡有備份檔；移到目錄外保留 |
| SSH 測試成功、更新時逾時 | 流程用了 Corosync 網段；明確指定管理網 IP |
| `sudo -n true` 要求密碼 | 流程需要完整免密碼 sudo（本案給了 ALL，屬權限取捨） |
| 本機儲存的 VM 被略過 | 符合設定；另外安排停機 |
| 手動重開後 HA error | 沒先進維護模式（見 HA error 那篇） |
| Rolling Update 沒有執行按鈕 | 沒有可用更新 |

## 14. 待辦

- [ ] 有實際更新時，用方案 A 完成一次「ProxCenter 更新 node10、node12」的完整紀錄
- [ ] 評估把 ProxCenter 移到叢集外
- [ ] 評估縮小 proxcenter 帳號的 sudo 權限

## 15. 延伸閱讀

- [PVE 更新重開後 HA 服務卡在 error：原因與救回步驟](https://kbwangtw.github.io/IT-Knowledge-Base/docs/pve/pve-ha-service-error-after-reboot/)
- [PVE HA 放置策略：PVE HA rules 和 ProxCenter 怎麼分工？](https://kbwangtw.github.io/IT-Knowledge-Base/docs/pve/pve-ha-placement-policy/)
