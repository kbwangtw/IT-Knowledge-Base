---
layout: default
title: "PVE 更新重開後 HA 服務卡在 error：原因與救回步驟"
permalink: /docs/pve/pve-ha-service-error-after-reboot/
date: 2026-10-12
categories: [PVE, HA, Ceph, Troubleshooting]
last_modified_at: 2026-10-12
---

# PVE 更新重開後 HA 服務卡在 error：原因與救回步驟

三台 PVE 更新 kernel 並逐台重開後，Ceph 是 HEALTH_OK，但 `ha-manager status` 有兩個服務停在 `error`：ct:100（DNS）和 vm:107。兩個都在 node10，也就是唯一以手動更新的那一台。

**原因是 node10 在 `reboot` 前沒有先執行 `node-maintenance enable`。HA 在關機過程中不斷嘗試在 node10 啟動服務，重試用完後就進入 error。磁碟、設定和新 kernel 都沒有問題。**

> 紀錄日期：2026-10-12；pve-manager 9.2.21，kernel 從 7.0.14-22-pve 升到 7.0.14-23-pve，Ceph 20.2.4-pve5。node10 手動更新，node11、node12 由 ProxCenter 更新。ct:100 與 vm:107 都已恢復成 running，全部 HA 服務正常；HA Shutdown Policy 已改成 `migrate`。

## 怎麼發現的？

更新後的驗收中，cluster quorum、Ceph、`noout` 都正常，HA 卻有兩個服務是 error：

~~~bash
ha-manager status
~~~

~~~
service ct:100 (node10, error)
service ct:101 (node12, started)
...
service vm:107 (node10, error)
~~~

ct:100 和 ct:101 是互斥規則（Keep Separate）下的兩台 DNS。ct:101 在 node12 上仍是 started，所以 DNS 沒有中斷，但只剩一台在服務；node12 這時再出事，DNS 就會整個停掉。因此先處理 ct:100。

## 1. 先查原因，不要直接重設狀態

在 node10 上執行，以下都只讀取：

~~~bash
pct status 100
qm status 107
pct config 100 | grep -E "^(rootfs|mp[0-9])"
qm config 107 | grep -E "^(scsi|virtio|sata|ide|efidisk|tpmstate)[0-9]"
journalctl -u pve-ha-lrm -u pve-ha-crm --since "1 hour ago" --no-pager | grep -E "ct:100|vm:107" | tail -40
pvenode task list --errors 1 --limit 10
~~~

本次結果：

| 項目 | ct:100 | vm:107 |
| --- | --- | --- |
| 目前狀態 | stopped | stopped |
| 磁碟位置 | `VM_Pool:vm-100-disk-0`（Ceph） | `VM_Pool:vm-107-disk-0`（Ceph） |
| 啟動錯誤 | `systemctl start pve-container@100' failed: exit code 4` | `org.freedesktop.DBus.Error.NoReply: Did not receive a reply` |

兩個磁碟都在 Ceph，而 Ceph 是 HEALTH_OK，所以資料沒有問題，服務也可以在任何一台 node 上啟動。

HA 與工作紀錄的時間順序：

| 時間 | 事件 |
| --- | --- |
| 15:42:06 | `hamigrate 107`（proxcenter@pve token）ERROR |
| 15:42:54～15:43:16 | HA 在 node10 上每隔約 5 秒嘗試啟動 ct:100、vm:107，每次都失敗 |
| 之後 | node10 重開機 |
| 15:51:22 | node10 重開後，LRM 回報 `service ... is in an error state and needs manual intervention` |

兩種錯誤都代表 systemd 沒有接受啟動要求，最常見的情況就是機器正在關機。時間也吻合：失敗發生在 node10 重開之前。

## 2. 為什麼沒先進入維護模式會出錯？

| `reboot` 前有沒有先 `node-maintenance enable` | HA 的行為 |
| --- | --- |
| 有 | HA 先把服務搬到其他 node，node10 上沒有 HA 服務後才重開 |
| 沒有（本案） | 服務被停止，但 HA 仍認為它們應該在 node10 執行，於是在關機過程中反覆嘗試啟動；systemd 已不接受新工作，重試用完就進入 error |

ProxCenter 更新 node11、node12 時會自動進入維護模式，所以那兩台沒有發生這個問題。

PVE HA 的服務進入 error 後**不會自動重試**，一定要手動處理。

## 3. 確認磁碟沒有被其他地方使用

重新啟動之前，先確認沒有任何地方正在使用這兩顆磁碟，避免同一顆磁碟被兩邊同時寫入：

~~~bash
rbd status VM_Pool/vm-100-disk-0
rbd status VM_Pool/vm-107-disk-0
~~~

本次兩個都顯示 `Watchers: none`。如果出現 watcher，先停下來查清楚是誰在用，不要繼續。

## 4. 清除 error，再重新啟動

先救 DNS（ct:100），確認恢復後再處理 vm:107。每一步都等狀態確認後再往下做。

清除 error：

~~~bash
ha-manager set ct:100 --state disabled
sleep 15; ha-manager status | grep ct:100
~~~

本次第一次查看時顯示 `clearing error flag`。這是正常的過渡狀態，HA 會先確認服務確實已停止，再改成 `disabled`。CRM 大約每 10 秒檢查一次，所以要多等一下，看到 `disabled` 再繼續。

重新啟動：

~~~bash
ha-manager set ct:100 --state started
sleep 15; ha-manager status | grep -E "ct:100|ct:101"
pct status 100
~~~

本次結果：

~~~
service ct:100 (node10, starting)
service ct:101 (node12, started)
status: running
~~~

`pct status` 已經是 running，HA 的 `starting` 會在下一輪檢查時變成 `started`。兩台 DNS 分別在 node10 和 node12，互斥規則正常。

vm:107 用同樣的流程。VM 開機比容器慢，所以等久一點：

~~~bash
ha-manager set vm:107 --state disabled
sleep 15; ha-manager status | grep vm:107

ha-manager set vm:107 --state started
sleep 30; ha-manager status | grep vm:107
qm status 107
~~~

本次 vm:107 也恢復成 running。

最後確認沒有遺漏的服務：

~~~bash
ha-manager status | grep -E "error|starting|disabled|stopped" || echo "全部 HA 服務正常"
~~~

本次輸出 `全部 HA 服務正常`。

## 5. 以後怎麼避免？

**手動重開 HA node 的正確順序：**

~~~bash
ha-manager crm-command node-maintenance enable node10
ha-manager status          # 確認 node10 上的 HA 服務都已搬走
apt full-upgrade
reboot
# 重開後確認 cluster、Ceph、HA 正常
ha-manager crm-command node-maintenance disable node10
~~~

**再加一層保護（可選）：** **Datacenter → Options → HA Settings → Shutdown Policy** 改成 `migrate`。node 關機或重開時，HA 會一律先把服務搬到其他 node，就算忘了先進入維護模式也不會出錯。代價是重開要等服務搬完，速度比較慢。改設定前請先讀 [PVE HA 文件的 Shutdown Policy 章節](https://pve.proxmox.com/pve-docs/chapter-ha-manager.html#ha_manager_shutdown_policy)。

本次修復後，已把 Shutdown Policy 改成 `migrate`。這個設定存在 cluster 共用的 `/etc/pve/datacenter.cfg`，三台會一起生效。可用下面的指令確認：

~~~bash
grep -i '^ha' /etc/pve/datacenter.cfg
~~~

預期看到 `ha: shutdown_policy=migrate`。改成 `migrate` 後，下次重開時服務會先搬走，這個行為還沒有實際重開驗證過；維護模式仍是建議的標準流程，Shutdown Policy 只是忘記時的保險。

## 本次更新的其他驗收結果

| 項目 | 結果 |
| --- | --- |
| 三台 running kernel | 7.0.14-23-pve；舊的 7.0.14-22 仍保留在 `/boot`，可做回退 |
| 驗收時 uptime | node11 14 分鐘、node12 10 分鐘、node10 8 分鐘 |
| Cluster | Quorate Yes，3 nodes |
| Ceph | HEALTH_OK；3 MON quorum；OSD 3 up／3 in；97 PG active+clean；CephFS 1/1 healthy |
| `noout` | 已解除，不在 OSD flags 中 |
| HA | quorum OK、fencing armed、3 台 LRM active |
| 訂閱提示 patch、pveproxy、fail2ban | 三台都正常；widget-toolkit 本次未升級，仍為 5.2.10 |

## 本次結論

ct:100 與 vm:107 已救回，全部 HA 服務正常。根本原因是手動重開前沒有先進入 HA 維護模式，不是 kernel 或儲存的問題。預防措施已完成：Shutdown Policy 改成 `migrate`。待辦：用 `nslookup` 確認 ct:100 的 DNS 解析、確認 vm:107 上應用程式的實際運作，以及下次重開時確認 `migrate` 有先把服務搬走。

## 相關紀錄

- [PVE HA 放置策略：PVE HA rules 和 ProxCenter 怎麼分工？](https://kbwangtw.github.io/IT-Knowledge-Base/docs/pve/pve-ha-placement-policy/)
- [ProxCenter 逐台更新 PVE](https://kbwangtw.github.io/IT-Knowledge-Base/docs/pve/proxcenter-ceph-rolling-update/)
- [PVE 重開後 Ceph 又故障：修正 BlueStore 裡的 OSD 金鑰](https://kbwangtw.github.io/IT-Knowledge-Base/docs/pve/ceph-bluestore-osd-key-recovery-2026-09-22/)
- [PVE HA Manager 官方文件](https://pve.proxmox.com/pve-docs/chapter-ha-manager.html)
