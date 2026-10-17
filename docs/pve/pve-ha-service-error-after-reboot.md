---
layout: default
title: "PVE 更新重開後 HA 服務卡在 error：原因與救回步驟"
permalink: /docs/pve/pve-ha-service-error-after-reboot/
date: 2026-10-12
categories: [PVE, HA, Ceph, Troubleshooting]
last_modified_at: 2026-10-17
---

# PVE 更新重開後 HA 服務卡在 error：原因與救回步驟

> **一句話**：手動重開 PVE 節點前**忘了先進維護模式**，HA 在關機過程中一直想把服務開回來、失敗太多次就卡在 error；資料沒事，照步驟清除再啟動就救回來了。

| 項目 | 內容 |
| --- | --- |
| 適合誰看 | 遇到 HA 服務顯示 `error` 的人；要手動重開 PVE 節點的人 |
| 環境 | pve-manager 9.2.21；kernel 7.0.14-22 → 7.0.14-23；Ceph 20.2.4-pve5 |
| 發生日期 | 2026-10-12 |
| 結果 | ✅ ct:100（DNS）與 vm:107 都已救回；預防措施：HA Shutdown Policy 改成 `migrate` |

## 1. 先認識幾個名詞

| 名詞 | 白話解釋 |
| --- | --- |
| **HA（High Availability）** | 高可用：某台主機掛了，PVE 自動把服務搬到別台重新啟動 |
| **CRM／LRM** | HA 的「總指揮」（叢集層）和「各台執行者」（節點層） |
| **維護模式（node-maintenance）** | 告訴 HA「這台要維修」，HA 會先把服務搬走 |
| **error 狀態** | HA 重試太多次都失敗後的狀態；**不會自動恢復**，一定要人工處理 |
| **Ceph／RBD** | 三台共用的分散式儲存；RBD 是存放 VM 磁碟的區塊裝置 |
| **Watcher** | 正在使用某顆 RBD 磁碟的程式；有 watcher 代表磁碟還在被用 |
| **Keep Separate（互斥規則）** | 指定兩個服務不能放在同一台，例如兩台 DNS |

## 2. 發生了什麼事

三台 PVE 更新 kernel 並逐台重開後，cluster、Ceph（HEALTH_OK）、`noout` 都正常，但 HA 有兩個服務停在 `error`：

```bash
ha-manager status
```

```text
service ct:100 (node10, error)
service ct:101 (node12, started)
...
service vm:107 (node10, error)
```

兩個都在 **node10**，也就是唯一**手動**更新的那一台（node11、node12 由 ProxCenter 更新）。

> ct:100 和 ct:101 是兩台互斥的 DNS。ct:101 還在跑，所以 DNS 沒中斷，但**只剩一台**；node12 這時再出事，DNS 就全停了。所以先處理 ct:100。

## 3. 步驟一：先查原因，不要直接重設

在 node10 執行（**全部只讀取**）：

```bash
pct status 100
qm status 107
pct config 100 | grep -E "^(rootfs|mp[0-9])"                                   # 磁碟在哪裡
qm config 107 | grep -E "^(scsi|virtio|sata|ide|efidisk|tpmstate)[0-9]"
journalctl -u pve-ha-lrm -u pve-ha-crm --since "1 hour ago" --no-pager | grep -E "ct:100|vm:107" | tail -40
pvenode task list --errors 1 --limit 10                                       # 最近失敗的工作
```

| 項目 | ct:100 | vm:107 |
| --- | --- | --- |
| 目前狀態 | stopped | stopped |
| 磁碟位置 | `VM_Pool:vm-100-disk-0`（Ceph） | `VM_Pool:vm-107-disk-0`（Ceph） |
| 啟動錯誤 | `systemctl start pve-container@100' failed: exit code 4` | `org.freedesktop.DBus.Error.NoReply: Did not receive a reply` |

兩顆磁碟都在 Ceph，而 Ceph 是 HEALTH_OK，所以**資料沒問題**，服務也能在任何一台啟動。

時間順序：

| 時間 | 事件 |
| --- | --- |
| 15:42:06 | `hamigrate 107`（proxcenter@pve token）ERROR |
| 15:42:54～15:43:16 | HA 在 node10 上每隔約 5 秒嘗試啟動 ct:100、vm:107，每次都失敗 |
| 之後 | node10 重開機 |
| 15:51:22 | 重開後，LRM 回報 `service ... is in an error state and needs manual intervention` |

兩種錯誤都代表 **systemd 不接受啟動要求**，最常見的原因就是「機器正在關機」。時間也吻合：失敗都發生在 node10 重開之前。

## 4. 為什麼沒進維護模式就會出錯

| 重開前有沒有先 `node-maintenance enable` | HA 的行為 |
| --- | --- |
| 有 | HA 先把服務搬到別台，node10 上沒有 HA 服務後才重開 |
| **沒有（本案）** | 服務被停掉，但 HA 仍認為它們應該在 node10 執行，於是在關機過程中反覆嘗試啟動；systemd 已不接受新工作，重試用完就進入 error |

ProxCenter 更新 node11、node12 時會**自動**進入維護模式，所以那兩台沒事。

## 5. 步驟二：確認磁碟沒有被其他地方使用

重新啟動前，確認沒有任何程式在用這兩顆磁碟，避免**同一顆磁碟被兩邊同時寫入**（會毀損資料）：

```bash
rbd status VM_Pool/vm-100-disk-0
rbd status VM_Pool/vm-107-disk-0
```

**應該看到**：`Watchers: none`。本次兩個都是。

> ⚠️ 如果出現 watcher，**先停下來**查清楚是誰在用，不要繼續。

## 6. 步驟三：清除 error，再重新啟動

先救 DNS（ct:100），確認恢復後再處理 vm:107。**每一步都等狀態確認後再往下做**。

**清除 error：**

```bash
ha-manager set ct:100 --state disabled
sleep 15; ha-manager status | grep ct:100
```

第一次查看可能顯示 `clearing error flag`，這是正常的過渡狀態：HA 會先確認服務真的停了，再改成 `disabled`。CRM 大約每 10 秒檢查一次，多等一下，**看到 `disabled` 再繼續**。

**重新啟動：**

```bash
ha-manager set ct:100 --state started
sleep 15; ha-manager status | grep -E "ct:100|ct:101"
pct status 100
```

**看到的結果**：

```text
service ct:100 (node10, starting)
service ct:101 (node12, started)
status: running
```

`pct status` 已經是 running，HA 的 `starting` 會在下一輪檢查變成 `started`。兩台 DNS 分別在 node10 和 node12，互斥規則正常。

**vm:107 用同樣流程**（VM 開機比容器慢，等久一點）：

```bash
ha-manager set vm:107 --state disabled
sleep 15; ha-manager status | grep vm:107

ha-manager set vm:107 --state started
sleep 30; ha-manager status | grep vm:107
qm status 107
```

vm:107 也恢復成 running，之後確認 VM 裡的應用程式運作正常。

**最後確認沒有遺漏：**

```bash
ha-manager status | grep -E "error|starting|disabled|stopped" || echo "全部 HA 服務正常"
```

本次輸出 `全部 HA 服務正常`。

## 7. 步驟四：確認服務真的能用

狀態是 running **不代表服務可用**。DNS 要實際查詢，兩台都要測：

```bash
nslookup <內部主機名稱> <DNS 1 的 IP>
nslookup <內部主機名稱> <DNS 2 的 IP>
```

本次用 ProxCenter 的內部名稱測試，兩台都回傳相同且正確的內部 IP。其中一台顯示 `Non-authoritative answer`，代表它不是這個網域的權威伺服器，而是轉送或快取來的答案；兩台角色不同，但都能正確解析。

## 8. 以後怎麼避免

**手動重開 HA 節點的正確順序：**

```bash
ha-manager crm-command node-maintenance enable node10
ha-manager status          # 確認 node10 上的 HA 服務都已搬走
apt full-upgrade
reboot
# 重開後確認 cluster、Ceph、HA 正常
ha-manager crm-command node-maintenance disable node10
```

**再加一層保險：Shutdown Policy 改成 `migrate`**

**Datacenter → Options → HA Settings → Shutdown Policy** 改成 `migrate`：節點關機或重開時，HA 一律先把服務搬走，就算忘了進維護模式也不會出錯。代價是重開要等服務搬完，比較慢。改之前請先讀 [PVE HA 文件的 Shutdown Policy 章節](https://pve.proxmox.com/pve-docs/chapter-ha-manager.html#ha_manager_shutdown_policy)。

本次修復後**已改成 `migrate`**。這個設定存在叢集共用的 `/etc/pve/datacenter.cfg`，三台一起生效：

```bash
grep -i '^ha' /etc/pve/datacenter.cfg      # 應看到 ha: shutdown_policy=migrate
```

> 改成 `migrate` 後的行為**還沒有實際重開驗證過**。維護模式仍是建議的標準流程，Shutdown Policy 只是忘記時的保險。

## 9. 本次更新的其他驗收結果

| 項目 | 結果 |
| --- | --- |
| 三台 running kernel | 7.0.14-23-pve；舊的 7.0.14-22 仍保留在 `/boot`，可以回退 |
| 驗收時 uptime | node11 14 分鐘、node12 10 分鐘、node10 8 分鐘 |
| Cluster | Quorate Yes，3 nodes |
| Ceph | HEALTH_OK；3 MON quorum；OSD 3 up／3 in；97 PG active+clean；CephFS 1/1 healthy |
| `noout` | 已解除 |
| HA | quorum OK、fencing armed、3 台 LRM active |
| 訂閱提示 patch、pveproxy、fail2ban | 三台都正常；widget-toolkit 本次未升級，仍是 5.2.10 |

## 10. 常見問題

| 現象 | 怎麼辦 |
| --- | --- |
| HA 服務顯示 error | 不會自動恢復；照第 3～6 節：查原因 → 確認磁碟沒人用 → disabled → started |
| 顯示 `clearing error flag` | 正常過渡狀態，等 10～15 秒 |
| `rbd status` 有 watcher | 停下來查是誰在用，避免兩邊同時寫入 |
| 狀態 running，但服務不通 | 實際測試服務（例如 DNS 用 `nslookup`） |

## 11. 待辦

- [ ] 下次重開時，確認 Shutdown Policy `migrate` 有先把服務搬走

## 12. 延伸閱讀

- [PVE HA 放置策略：PVE HA rules 和 ProxCenter 怎麼分工？](https://kbwangtw.github.io/IT-Knowledge-Base/docs/pve/pve-ha-placement-policy/)
- [ProxCenter 逐台更新 PVE](https://kbwangtw.github.io/IT-Knowledge-Base/docs/pve/proxcenter-ceph-rolling-update/)
- [PVE 重開後 Ceph 又故障：修正 BlueStore 裡的 OSD 金鑰](https://kbwangtw.github.io/IT-Knowledge-Base/docs/pve/ceph-bluestore-osd-key-recovery-2026-09-22/)
- [PVE HA Manager 官方文件](https://pve.proxmox.com/pve-docs/chapter-ha-manager.html)
