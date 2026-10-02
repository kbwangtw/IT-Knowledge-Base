---
layout: default
title: "PVE HA 放置策略：PVE HA rules 和 ProxCenter 怎麼分工？"
date: 2026-10-02
categories: [PVE, HA, ProxCenter]
permalink: /docs/pve/pve-ha-placement-policy/
last_modified_at: 2026-10-02
---

# PVE HA 放置策略：PVE HA rules 和 ProxCenter 怎麼分工？

為了避免更新節點時 DNS、網域控制站一起消失，我在 ProxCenter 設了互斥規則。後來才發現：**節點維護、故障轉移時真正在搬 HA 服務的是 PVE，不是 ProxCenter**。本文整理兩者的分工，以及實際補上的 PVE HA 規則與 CRS 設定。

> 紀錄日期：2026-10-02；Proxmox VE 9.2.20，三節點（node10、node11、node12），Ceph 共用儲存。本文的設定都已在叢集上完成並驗證；單節點故障與 ProxCenter 完整逐台更新尚未實際演練，見最後的「待驗證」。

## 先說結論

| 問題 | 答案 |
| --- | --- |
| 以 ProxCenter 為主要管理介面，可以關掉 PVE HA 嗎？ | **不行。** 故障轉移和 fencing 只有 PVE HA 做得到 |
| ProxCenter 的 Affinity rules 在維護或故障時會生效嗎？ | **HA 資源不一定會**，因為那時是 PVE 在搬 |
| 那規則要設在哪裡？ | **HA 資源的規則放 PVE；非 HA 的 VM 放 ProxCenter** |
| PVE 的自動平衡要開嗎？ | **目前不開。** HA 資源都是容器，搬一次就中斷一次 |

## 用 VMware 來理解

| VMware | Proxmox | 角色 |
| --- | --- | --- |
| vCenter | ProxCenter | 管理平面：統一介面、DRS、逐台更新 |
| vSphere HA（每台 ESXi 上的 agent） | PVE HA（每台節點上的 CRM／LRM） | 故障轉移：主機掛掉時把服務拉起來 |

vCenter 掛掉時 vSphere HA 照樣運作；PVE 也一樣，HA 跑在每台節點上，不依賴外部管理工具。

不能只靠 ProxCenter 的三個理由：

1. **ProxCenter 本身就跑在叢集裡**（本案為 CT 110，也是 HA 資源）。它所在的節點掛掉時，ProxCenter 也跟著停，是 PVE HA 把它在別的節點拉起來。
2. **只有 PVE HA 能做 fencing。** 失聯的節點由 watchdog 讓它自行重開，確認它停了才在別處啟動服務，避免同一台 VM 在兩個節點同時寫入同一顆 Ceph 磁碟。
3. **ProxCenter 也需要更新、可能需要還原。** 這段期間叢集的保護不能跟著消失。

## 誰在搬服務？

| 情境 | HA 資源由誰搬 | 非 HA 的 VM |
| --- | --- | --- |
| 節點故障 | **PVE HA** | 不會自動處理，要人工 |
| 在 PVE 上手動逐台更新（維護模式） | **PVE HA** | 依操作而定 |
| **用 ProxCenter 逐台更新** | **PVE HA** | ProxCenter |
| 平常的負載平衡 | ProxCenter DRS（若開啟） | ProxCenter DRS（若開啟） |

ProxCenter 逐台更新的日誌就能看出這點（見[ProxCenter 逐台更新 PVE](https://kbwangtw.github.io/IT-Knowledge-Base/docs/pve/proxcenter-ceph-rolling-update/)）：

~~~text
Enabling maintenance mode
Waiting for HA migrations
Migrating non-HA VMs
~~~

HA 服務是交給 PVE 的維護模式搬的。**換用 ProxCenter 更新，並不會讓 HA 服務改為遵守 ProxCenter 的規則。**

## 2026-10-02 的現況

HA 資源：

| HA 資源 | 服務 | 所在節點 |
| --- | --- | --- |
| ct:100 | AdGuard（DNS） | node10 |
| ct:101 | Pi-hole（DNS） | node12 |
| ct:110 | ProxCenter | node10 |
| ct:112 | Wazuh | node10（之後移至 node12，見第 4 節） |
| ct:113 | AI Agent | node10 |

ProxCenter 的 Affinity rules：

| 規則 | 類型 | 對象 | 涉及 HA 資源？ |
| --- | --- | --- | --- |
| DNS | Anti-affinity | AdGuard、Pi-hole | **是** |
| DC | Anti-affinity | DC01、DC02 | 否 |
| VGA | Node pinning（node11） | WinClient、UBClient | 否 |

其他發現：

- `ha-manager rules config` **沒有任何輸出**：ProxCenter 的規則沒有同步到 PVE。
- ProxCenter **DRS 是關閉的**，但已預設為 Automatic、每 1 小時、同時平衡 VM 與 LXC。
- PVE CRS 為預設的 `basic`，只依各節點 HA 服務的「數量」決定放置。

**風險：** 更新 AdGuard 所在的節點時，PVE 可能把它搬到 Pi-hole 所在的節點；接著更新那台節點時，兩台 DNS 會一起中斷。

## 1. 在 PVE 建立 DNS 互斥規則

**Datacenter → HA → Rules → Add → Resource Affinity**

| 欄位 | 值 |
| --- | --- |
| Rule | 建議填好認的名稱，例如 `dns-separate`（未填會自動產生 `ha-rule-xxxx`） |
| HA Resources | `100`、`101` |
| Affinity | **Keep Separate (negative)** |
| Comment | AdGuard and Pi-hole must run on different nodes |

驗證：

~~~bash
ha-manager rules config
ha-manager status | grep -E 'ct:100|ct:101'
~~~

本案結果：規則為 `enabled 1`、`in use`、`resource-affinity`、`ct:100,ct:101`；兩台 DNS 仍在 node10、node12，建立規則沒有觸發搬移。

`ha-manager rules config` 的表格**不會顯示 affinity 是 negative 還是 positive**。一定要再打開規則（或看 `/etc/pve/ha/rules.cfg`）確認是 **Keep Separate**；選成 Keep Together 會讓 HA 把兩台 DNS 搬到一起，效果完全相反。

三節點加兩個互斥的服務是可行的：任何一台維護時，剩下兩台各放一台 DNS。

## 2. 調整 CRS（Cluster Resource Scheduling）

**Datacenter → Options → Cluster Resource Scheduling**

| Scheduling Mode | 依據 |
| --- | --- |
| Default (basic) / Basic (Resource Count) | 各節點 HA 服務的數量 |
| **Static Load** | 各服務**設定的** CPU、記憶體 |
| Dynamic Load | 推測為即時負載；細節未查證，請看 Help |

本案設定：

| 欄位 | 值 | 理由 |
| --- | --- | --- |
| Scheduling Mode | **Static Load** | 故障轉移時依服務大小分配，結果穩定、可預測 |
| Rebalance on Start | ☑ | HA 服務啟動時挑負載較輕的節點 |
| Automatic Rebalance | ☐ **不開** | HA 資源全是容器，LXC 只能重啟式遷移，自動平衡會造成反覆中斷 |

驗證：

~~~bash
grep crs /etc/pve/datacenter.cfg
ha-manager status | grep -E 'ct:'
~~~

本案結果：`crs: ha-rebalance-on-start=1,ha=static`；五個 HA 容器都留在原節點。這個設定只影響「之後啟動或故障轉移時放哪裡」，不會搬動正在運作的服務。

Static Load 依據的是設定值，設定值要接近實際需求，否則放置判斷會失準。

## 3. ProxCenter DRS：目前維持關閉

DRS 關閉時，ProxCenter 平常不搬任何東西，和 PVE 的設定不衝突。

若將來要開啟，先改兩項再打開開關：

| 設定 | 目前預設 | 建議 |
| --- | --- | --- |
| Operation mode | Automatic | **Manual**，先看建議是否合理 |
| Guest types | VMs + Containers (LXC) | **只留 VMs**，避免容器每小時被搬、被重啟 |

ProxCenter 的 Load Overview 會在叢集名稱旁顯示模式標籤（例如 AUTOMATIC）。本案 DRS 開關關閉時，標籤仍顯示 AUTOMATIC：**標籤是設定的模式，不代表正在執行**，要以 Configuration 頁的 DRS enabled 開關為準。

原則：**平常負責搬移的只能有一個。** ProxCenter DRS 與 PVE 的 Automatic Rebalance 同時開啟，會互相把服務搬來搬去（乒乓效應）。

## 規則的正本放哪裡

| 規則 | 正本 | 副本 | 說明 |
| --- | --- | --- | --- |
| DNS 互斥 | **PVE HA rules** | ProxCenter | HA 資源，維護與故障時由 PVE 搬 |
| DC 互斥 | **ProxCenter** | — | DC 不是 HA 資源，PVE 不會搬 |
| VGA 固定 node11 | **ProxCenter** | — | 顯示卡直通的 VM 本來就無法遷移 |

一句話原則：**會在故障或維護時被自動搬動的東西，規則放 PVE；其他的放 ProxCenter。** 同一條規則存在兩邊時，修改要兩邊一起改。

### DC 的提醒

ProxCenter DRS 關閉、DC 又不是 HA 資源，所以 **目前沒有機制會自動檢查 DC 互斥**：

- 手動遷移 DC 時，自己確認不要搬到另一台 DC 所在的節點。
- 每更新完一台節點，檢查兩台 DC 是否被搬到一起：

~~~bash
pvesh get /cluster/resources --type vm --output-format json | grep -oE '"id":"qemu/10[67]"[^}]*"node":"[^"]*"'
~~~

本案 DC02 曾被手動移到 node10，DC01 在 node12，仍符合互斥。

## 4. DRS 看不到「服務太集中」：手動分散 node10

ProxCenter Load Overview（2026-10-02）：

| 節點 | CPU | RAM | 台數 |
| --- | --- | --- | --- |
| node11 | 1.0% | 33.4% | 2 |
| node10 | 2.4% | 31.4% | 9 |
| node12 | 1.0% | 23.2% | 3（標記為可接收的 Target） |

叢集 CPU 約 1%、RAM 29%，不平衡度 10%。node11 只有兩台用戶端 VM，但記憶體配置大，RAM 使用率反而最高。**從使用率看叢集很平衡，DRS 不會把 node10 視為問題。**

但 node10 承載 9 台，包含 DNS、ProxCenter、Wazuh、DC02 等，節點故障時影響範圍最大。這是可用性風險，不是效能問題，需要人工規劃。

第一步把 Wazuh（ct:112）移到 DRS 標記為 Target 的 node12：

~~~bash
ha-manager migrate ct:112 node12          # HA 資源要用 ha-manager，不要用 pct migrate
watch -n 5 "ha-manager status | grep ct:112"
~~~

本案結果：遷移完成後 `ct:112 (node12, started)`；在 node12 上確認 4 個 Wazuh 服務 active、`vm.max_map_count` 1048576、Active 數量 18（17 Agent + Manager），Dashboard 顯示 Active 17、Disconnected 0。好處是 node10 故障時，監控系統不會跟著停。

第二步把 DC02（VM 107，非 HA）以 live migration 移回 node11。先確認磁碟都在共用儲存、沒有 hostpci／usb 直通，且 DC01 不在目標節點：

~~~bash
qm config 107 | grep -E 'scsi|virtio|sata|ide|hostpci|usb'
qm migrate 107 node11 --online       # 在 VM 目前所在的節點執行
~~~

本案結果：記憶體 4 GB、實際傳輸 3.4 GiB，平均 342.9 MiB/s，**停頓 63 ms**（上限 100 ms），整體 17 秒完成；DC01 在 node12、DC02 在 node11，仍符合互斥。輸出中的 `conntrack state migration not supported or disabled` 表示防火牆連線追蹤狀態不會跟著搬，本案資料中心防火牆未啟用，影響不大。

調整後各節點台數由 9／2／3 變為 7／3／4（node10／node11／node12）。

## 待驗證與後續

| 項目 | 狀態 |
| --- | --- |
| 用 ProxCenter 完整逐台更新三台，每台確認 DNS／DC 位置 | 待下次更新 |
| ProxCenter 搬移非 HA VM 時是否遵守 Affinity rules | 未確認 |
| 單節點故障演練（實測 Ceph I/O latency 與 HA 恢復時間） | 未演練 |
| node10 承載大部分服務，需分散 | 進行中：Wazuh 移至 node12、DC02 移回 node11，台數 7／3／4 |
| Dynamic Load 與 Automatic Rebalance 的實際行為 | 未查證 |

單節點故障的預期行為（依 Ceph 預設值推估，未實測）：節點剛失聯的十幾到數十秒，主副本在該節點上的資料讀寫會短暫卡住；確認 OSD 下線後恢復讀寫，但剩下兩台承擔全部負載，且在節點回來前沒有再壞一顆硬碟的餘裕。

## 參考資料

- [Proxmox VE：High Availability（含 CRS、HA rules）](https://pve.proxmox.com/pve-docs/chapter-ha-manager.html)
- [Ceph：Monitor／OSD 心跳與 down／out 設定](https://docs.ceph.com/en/latest/rados/configuration/mon-osd-interaction/)
- [ProxCenter 文件：DRS](https://docs.proxcenter.io/automation/drs/)
