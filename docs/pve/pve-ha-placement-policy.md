---
layout: default
title: "PVE HA 放置策略：PVE HA rules 和 ProxCenter 怎麼分工？"
date: 2026-10-02
categories: [PVE, HA, ProxCenter]
permalink: /docs/pve/pve-ha-placement-policy/
last_modified_at: 2026-10-03
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
| Affinity rules | — | 確認需要的規則都是 **Active**，再打開 DRS，否則 DRS 開始運作時不知道這些限制 |

ProxCenter 的 Load Overview 會在叢集名稱旁顯示模式標籤（例如 AUTOMATIC）。本案 DRS 開關關閉時，標籤仍顯示 AUTOMATIC：**標籤是設定的模式，不代表正在執行**，要以 Configuration 頁的 DRS enabled 開關為準。

原則：**平常負責搬移的只能有一個。** ProxCenter DRS 與 PVE 的 Automatic Rebalance 同時開啟，會互相把服務搬來搬去（乒乓效應）。

## 規則的正本放哪裡

| 規則 | 正本 | 副本 | 說明 |
| --- | --- | --- | --- |
| DNS 互斥 | **PVE HA rules** | ProxCenter | HA 資源，維護與故障時由 PVE 搬 |
| DC 互斥 | **PVE HA rules**（2026-10-03 起） | ProxCenter | DC01、DC02 已加入 HA，維護與故障時由 PVE 搬（見第 5 節） |
| VGA 固定 node11 | **ProxCenter** | — | 顯示卡直通的 VM 本來就無法遷移，**不可加入 HA** |

DRS 關閉時，ProxCenter 的規則不會自動執行；但逐台更新搬移非 HA VM、手動遷移等功能是否會參考這些規則尚未確認。規則開著沒有副作用，本案三條規則維持 **Active**。

一句話原則：**會在故障或維護時被自動搬動的東西，規則放 PVE；其他的放 ProxCenter。** 同一條規則存在兩邊時，修改要兩邊一起改。

### DC 的提醒

> 2026-10-03 起 DC01、DC02 已加入 HA 並建立 PVE 互斥規則，以下為加入前的狀況，保留作為紀錄。

ProxCenter DRS 關閉、DC 又不是 HA 資源，所以 **當時沒有機制會自動檢查 DC 互斥**：

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

遷移後在 DC02 上確認：`dcdiag /q` 無輸出、`repadmin /replsummary` 兩台 DC 皆 0／5 失敗、DNS／Kdc／Netlogon／NTDS 皆 Running；Wazuh 上 DC02（ID 014）維持 Active。

調整後各節點台數由 9／2／3 變為 7／3／4（node10／node11／node12）。

## 5. 逐台更新結果與 DC 加入 HA（2026-10-03）

三台以 ProxCenter Rolling Update 一次一台更新為 pve-manager 9.2.21、kernel 7.0.14-20（順序 node11 → node12 → node10；ProxCenter 所在的 node11 先更新，之後更新其他節點時 ProxCenter 不會中斷）。

**更新前後的檢查腳本**（唯讀，每台更新後執行一次）：

~~~bash
cat > /root/cluster-check.sh <<'CKEOF'
#!/bin/bash
loc() { pvesh get /cluster/resources --type vm --output-format json | python3 -c "import json,sys; print({r['vmid']:r['node'] for r in json.load(sys.stdin)}.get($1,'?'))"; }
echo "===== Ceph"; ceph health; ceph osd stat; ceph osd dump | grep -E '^flags' | grep -o 'noout' || echo "noout: not set"
ceph -s | grep -E 'pgs:'
echo "===== Versions"; for n in node10 node11 node12; do echo "$n: $(ssh $n "pveversion | cut -d' ' -f1; uname -r" | tr '\n' ' ')"; done
echo "===== HA"; ha-manager status | grep -E 'lrm|service' | grep -vE 'started\)$|active,' || echo "all services started, all lrm active"
echo "===== Placement"
pvesh get /cluster/resources --type vm --output-format json | python3 -c "
import json,sys,collections
c=collections.defaultdict(list)
for r in json.load(sys.stdin): c[r['node']].append(f\"{r.get('name','')}({r['status'][0]})\")
for n in sorted(c): print(n, len(c[n]), ' '.join(sorted(c[n])))"
a=$(loc 100); p=$(loc 101); d1=$(loc 106); d2=$(loc 107)
echo "DNS: AdGuard=$a Pihole=$p $([ "$a" != "$p" ] && echo OK-separate || echo '!!! SAME NODE')"
echo "DC : DC01=$d1 DC02=$d2 $([ "$d1" != "$d2" ] && echo OK-separate || echo '!!! SAME NODE')"
echo "===== Wazuh agents"; w=$(loc 112); echo "active=$(ssh $w "pct exec 112 -- /var/ossec/bin/agent_control -l" | grep -c Active) (17 agents + manager = 18)"
echo "===== LibreNMS down devices"; l=$(loc 102); ssh $l "pct exec 102 -- mysql -N librenms -e \"select hostname from devices where status=0\"" | tr '\n' ' '; echo "(end)"
CKEOF
chmod 700 /root/cluster-check.sh
~~~

**結果**：Ceph `HEALTH_OK`、`noout` 已解除、PG 全部 active+clean；HA 全部 started；Wazuh 18（17 Agent + Manager）、LibreNMS 無斷線設備。

**發現**：

| 現象 | 原因／處理 |
| --- | --- |
| 更新過程中 DC01、DC02 一度在同一台節點 | 更新時把 DC 手動加入 HA，但當時尚無 DC 互斥規則，維護模式由 PVE 依負載選擇目的地；之後建立 PVE 規則 |
| 更新後服務集中在 node10（8／4／2） | 維護結束後服務沒有全部回到原節點；以 `ha-manager migrate` 與 `qm migrate --online` 移回，恢復 6／4／4 |
| VM 加入 HA 後 `qm migrate` 顯示 `Requesting HA migration` | HA 資源的遷移會交給 HA 執行，VM 仍為 live migration |

**目前 HA 資源**：9 個 LXC（100、101、102、103、105、109、110、112、113）與 VM 106（DC01）、107（DC02）、111（CA）。WinClient（108）有 `hostpci0` 顯示卡直通、UBClient（104）同屬 VGA 固定規則，**不加入 HA**（其他節點沒有對應硬體，維護時遷移會失敗）。

**PVE HA 規則**（`/etc/pve/ha/rules.cfg`）：

~~~text
resource-affinity: <自動產生的名稱>
        comment AdGuard and Pi-hole must run on different nodes
        affinity negative
        resources ct:100,ct:101

resource-affinity: <自動產生的名稱>
        comment DC01 and DC02 must run on different nodes
        affinity negative
        resources vm:106,vm:107
~~~

VM 加入 HA 後的注意事項：

- 關機要用 HA 操作（`ha-manager set vm:106 --state stopped` 或網頁的 HA 選項），直接在客體內關機，HA 會把它重新開起來。
- 遷移一律由 HA 執行；互斥規則會讓 HA 拒絕把兩台 DC 放在同一台節點。

## 6. 第二次逐台更新（2026-10-08）

更新內容：kernel 7.0.14-20 → 7.0.14-22、Ceph 20.2.4-pve4 → pve5（上游版本相同，僅 Proxmox 打包版次）、libpve-common-perl 9.2.3、libpve-storage-perl 9.1.12、proxmox-backup-client 4.2.8、xz-utils／liblzma5。pve-manager 維持 9.2.21。

**順序依 ProxCenter 所在節點調整**：更新前 ProxCenter 在 node12（不是上次的 node11）。ProxCenter 是 LXC，搬移會重開機，若在 Rolling Update 途中被搬走，流程會中斷。因此：

1. 先更新 node11（只有已關機的 WinClient、UBClient，不需遷移任何服務）
2. 以 `ha-manager migrate ct:<ProxCenter ID> node11` 把 ProxCenter 搬到已更新的 node11（執行前先確認 CT 編號）
3. 再以 ProxCenter 更新 node12 → node10

**原則：每次更新前先看 ProxCenter 在哪一台，先更新沒有 ProxCenter 的節點，再把 ProxCenter 搬到已更新的節點。**

更新前準備：WinClient（108）、UBClient（104）不在 HA、無法遷移，先在客體內關機，全部更新完再開機。Wazuh 在這段期間顯示這兩台 Disconnected，屬預期。

每台更新後執行 `cluster-check.sh`，下一台在 Ceph `HEALTH_OK`、PG 全部 `active+clean` 後才開始。

| 觀察 | 說明 |
| --- | --- |
| 節點剛重開機時 PG 顯示 96／97 active+clean | OSD 剛上線仍在 peering，1～2 分鐘內恢復 |
| LibreNMS 短暫顯示剛重開機的節點或剛搬移的 LXC 為 down | 輪詢間隔 5 分鐘，狀態尚未更新；確認 snmpd 為 active 後等下一輪輪詢即恢復 |
| node12 的服務（CA、DC01、Pihole、wazuh）維護後自動回到 node12 | 符合預期 |
| node10 維護後 DC02、ai 一度留在 node11 | 服務不一定全部自動回到原節點，維護後要比對更新前的 Placement |
| DC01／DC02、AdGuard／Pihole 全程在不同節點 | PVE HA 互斥規則有效 |

**結果**：三台 kernel 皆為 `7.0.14-22-pve`；Ceph `HEALTH_OK`、97 PG active+clean、`noout` 已解除；HA 全部 started；配置恢復為更新前（node10：AdGuard、DC02、Graylog、IPAM、ai、librenms、wireguard；node11：ProxCenter、UBClient、WinClient；node12：CA、DC01、Pihole、wazuh）；Wazuh 18（17 Agent + Manager）；LibreNMS 無斷線設備。

舊 kernel 7.0.14-20 保留作為開機退路，穩定運作一週以上再清除。

## 待驗證與後續

| 項目 | 狀態 |
| --- | --- |
| 用 ProxCenter 完整逐台更新三台，每台確認 DNS／DC 位置 | **完成（2026-10-03）**，見第 5 節 |
| ProxCenter 搬移非 HA VM 時是否遵守 Affinity rules | 已改為 DC 加入 HA、由 PVE 規則保證，不再依賴 |
| 下次逐台更新時，確認 DC 規則全程有效、HA 資源維護後是否自動搬回原節點 | **完成（2026-10-08）**：DC 規則全程有效；服務不一定全部自動搬回，見第 6 節 |
| 單節點故障演練（實測 Ceph I/O latency 與 HA 恢復時間） | 未演練 |
| node10 承載大部分服務，需分散 | 完成：更新後恢復為 6／4／4 |
| Dynamic Load 與 Automatic Rebalance 的實際行為 | 未查證 |

單節點故障的預期行為（依 Ceph 預設值推估，未實測）：節點剛失聯的十幾到數十秒，主副本在該節點上的資料讀寫會短暫卡住；確認 OSD 下線後恢復讀寫，但剩下兩台承擔全部負載，且在節點回來前沒有再壞一顆硬碟的餘裕。

## 參考資料

- [Proxmox VE：High Availability（含 CRS、HA rules）](https://pve.proxmox.com/pve-docs/chapter-ha-manager.html)
- [Ceph：Monitor／OSD 心跳與 down／out 設定](https://docs.ceph.com/en/latest/rados/configuration/mon-osd-interaction/)
- [ProxCenter 文件：DRS](https://docs.proxcenter.io/automation/drs/)
