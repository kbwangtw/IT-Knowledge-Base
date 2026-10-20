---
layout: default
title: "PVE HA 放置策略：PVE HA rules 和 ProxCenter 怎麼分工？"
date: 2026-10-02
categories: [PVE, HA, ProxCenter]
permalink: /docs/pve/pve-ha-placement-policy/
last_modified_at: 2026-10-19
---

# PVE HA 放置策略：PVE HA rules 和 ProxCenter 怎麼分工？

> **一句話**：節點維護或故障時，真正在搬 HA 服務的是 **PVE**，不是 ProxCenter；所以互斥規則（例如兩台 DNS 不能放同一台）要設在 PVE HA rules。2026-10-13 起決定**只留 PVE 原生機制**，ProxCenter DRS 停用、規則刪除，也不另裝 ProxLB。

| 項目 | 內容 |
| --- | --- |
| 適合誰看 | 同時用 PVE 和 ProxCenter，不確定規則該設在哪邊的人 |
| 環境 | Proxmox VE 9.2.20 → 9.2.21，三節點（node10、node11、node12），Ceph 共用儲存 |
| 日期 | 2026-10-02 首次整理；10/03、10/08 逐台更新驗證；10/13 定案；10/19 再次分散 |
| 結論 | ✅ DNS、DC 互斥規則在 PVE 生效（兩次逐台更新全程分開）；✅ CRS 改為 Static Load；✅ ProxCenter DRS 停用、規則刪除，Operation mode 改為 Manual；✅ 10/19 HA 資源分散為 4／5／4；⏳ 單節點故障演練 |

## 1. 先認識幾個名詞

| 名詞 | 白話解釋 |
| --- | --- |
| **HA 資源** | 交給 PVE HA 管的 VM／CT；主機掛了會自動在別台重新啟動 |
| **CRM／LRM** | HA 的「總指揮」和「各台執行者」，跑在每台節點上 |
| **fencing** | 失聯的節點由 watchdog 強制重開，確認它停了才在別處啟動服務，避免同一顆磁碟被兩邊寫 |
| **HA rules（Resource Affinity）** | 規定哪些服務要分開（Keep Separate）或放一起（Keep Together） |
| **CRS** | Cluster Resource Scheduling，決定 HA 服務啟動或故障轉移時放哪台 |
| **ProxCenter DRS** | ProxCenter 的自動負載平衡，和 PVE HA／CRS **沒有整合** |
| **維護模式** | 告訴 HA「這台要維修」，HA 會先把服務搬走 |
| **live migration** | VM 不關機直接搬到另一台；LXC 做不到，只能重啟式搬移 |

## 2. 先說結論

| 問題 | 答案 |
| --- | --- |
| 以 ProxCenter 為主要管理介面，可以關掉 PVE HA 嗎？ | **不行。** 故障轉移和 fencing 只有 PVE HA 做得到 |
| ProxCenter 的 Affinity rules 在維護或故障時會生效嗎？ | **HA 資源不一定會**，因為那時是 PVE 在搬 |
| 規則要設在哪裡？ | **全部放 PVE HA rules** |
| 平常的自動平衡交給誰？ | **只留 PVE 一套**；ProxCenter DRS 停用，不另裝 ProxLB |
| PVE 的自動平衡要開嗎？ | **目前不開。** HA 資源大多是容器，搬一次就中斷一次 |

## 3. 用 VMware 來理解

| VMware | Proxmox | 角色 |
| --- | --- | --- |
| vCenter | ProxCenter | 管理平面：統一介面、DRS、逐台更新 |
| vSphere HA（每台 ESXi 上的 agent） | PVE HA（每台節點上的 CRM／LRM） | 故障轉移：主機掛掉時把服務拉起來 |

vCenter 掛掉時 vSphere HA 照樣運作；PVE 也一樣，HA 跑在每台節點上，不依賴外部管理工具。

**不能只靠 ProxCenter 的三個理由**：

1. **ProxCenter 本身就跑在叢集裡**（CT 110，也是 HA 資源）。它所在的節點掛掉時 ProxCenter 也跟著停，是 PVE HA 把它在別台拉起來。
2. **只有 PVE HA 能做 fencing。**
3. **ProxCenter 也需要更新、可能需要還原**，這段期間叢集的保護不能跟著消失。

## 4. 誰在搬服務？

| 情境 | HA 資源由誰搬 | 非 HA 的 VM |
| --- | --- | --- |
| 節點故障 | **PVE HA** | 不會自動處理，要人工 |
| 在 PVE 上手動逐台更新（維護模式） | **PVE HA** | 依操作而定 |
| **用 ProxCenter 逐台更新** | **PVE HA** | ProxCenter |
| 平常的負載平衡 | ProxCenter DRS（若開啟） | ProxCenter DRS（若開啟） |

ProxCenter 逐台更新的日誌就看得出來（見 [ProxCenter 逐台更新 PVE](https://kbwangtw.github.io/IT-Knowledge-Base/docs/pve/proxcenter-ceph-rolling-update/)）：

```text
Enabling maintenance mode
Waiting for HA migrations
Migrating non-HA VMs
```

HA 服務是交給 PVE 維護模式搬的。**換用 ProxCenter 更新，HA 服務並不會改為遵守 ProxCenter 的規則。**

## 5. 2026-10-02 的現況與風險

**HA 資源**：

| HA 資源 | 服務 | 所在節點 |
| --- | --- | --- |
| ct:100 | AdGuard（DNS） | node10 |
| ct:101 | Pi-hole（DNS） | node12 |
| ct:110 | ProxCenter | node10 |
| ct:112 | Wazuh | node10（之後移到 node12，見第 9 節） |
| ct:113 | AI Agent | node10 |

**ProxCenter 的 Affinity rules**：

| 規則 | 類型 | 對象 | 涉及 HA 資源？ |
| --- | --- | --- | --- |
| DNS | Anti-affinity | AdGuard、Pi-hole | **是** |
| DC | Anti-affinity | DC01、DC02 | 否 |
| VGA | Node pinning（node11） | WinClient、UBClient | 否 |

**其他發現**：

- `ha-manager rules config` **沒有任何輸出**：ProxCenter 的規則沒有同步到 PVE。
- ProxCenter **DRS 是關閉的**，但已預設為 Automatic、每 1 小時、同時平衡 VM 與 LXC。
- PVE CRS 為預設的 `basic`，只依各節點 HA 服務的「數量」決定放置。

> ⚠️ **風險**：更新 AdGuard 所在的節點時，PVE 可能把它搬到 Pi-hole 那台；接著更新那台時，**兩台 DNS 一起中斷**。

## 6. 步驟一：在 PVE 建立 DNS 互斥規則

**Datacenter → HA → Rules → Add → Resource Affinity**

| 欄位 | 值 |
| --- | --- |
| Rule | 建議填好認的名稱，例如 `dns-separate`（沒填會自動產生 `ha-rule-xxxx`） |
| HA Resources | `100`、`101` |
| Affinity | **Keep Separate (negative)** |
| Comment | AdGuard and Pi-hole must run on different nodes |

**驗證**：

```bash
ha-manager rules config
ha-manager status | grep -E 'ct:100|ct:101'
```

**看到的結果**：規則為 `enabled 1`、`in use`、`resource-affinity`、`ct:100,ct:101`；兩台 DNS 仍在 node10、node12，建立規則沒有觸發搬移。

> ⚠️ `ha-manager rules config` 的表格**不會顯示** affinity 是 negative 還是 positive。一定要再打開規則（或看 `/etc/pve/ha/rules.cfg`）確認是 **Keep Separate**；選成 Keep Together 會把兩台 DNS 搬到一起，效果完全相反。

三節點加兩個互斥服務是可行的：任何一台維護時，剩下兩台各放一台 DNS。

## 7. 步驟二：調整 CRS

**Datacenter → Options → Cluster Resource Scheduling**

| Scheduling Mode | 依據 |
| --- | --- |
| Default (basic)／Basic (Resource Count) | 各節點 HA 服務的**數量** |
| **Static Load** | 各服務**設定的** CPU、記憶體 |
| Dynamic Load | 依節點的即時負載（10/20 查證，見第 15 節） |

**本案設定**：

| 欄位 | 值 | 理由 |
| --- | --- | --- |
| Scheduling Mode | **Static Load** | 故障轉移時依服務大小分配，結果穩定、可預測 |
| Rebalance on Start | ☑ | HA 服務啟動時挑負載較輕的節點 |
| Automatic Rebalance | ☐ **不開** | LXC 只能重啟式遷移，自動平衡會造成反覆中斷 |

**驗證**：

```bash
grep crs /etc/pve/datacenter.cfg
ha-manager status | grep -E 'ct:'
```

**看到的結果**：`crs: ha-rebalance-on-start=1,ha=static`；五個 HA 容器都留在原節點。這個設定只影響「之後啟動或故障轉移時放哪裡」，**不會搬動正在運作的服務**。

> Static Load 依據的是設定值，設定值要接近實際需求，否則放置判斷會失準。

## 8. ProxCenter DRS 的注意事項

DRS 關閉時，ProxCenter 平常不搬任何東西，和 PVE 的設定不衝突。

如果將來要開啟，先改這幾項再打開開關：

| 設定 | 目前預設 | 建議 |
| --- | --- | --- |
| Operation mode | Automatic | **Manual**，先看建議是否合理 |
| Guest types | VMs + Containers (LXC) | **只留 VMs**，避免容器每小時被搬、被重啟 |
| Affinity rules | — | 確認需要的規則都是 **Active** 再開 DRS |

- ProxCenter 的 Load Overview 在叢集名稱旁顯示的模式標籤（例如 AUTOMATIC），在 DRS 關閉時仍顯示 AUTOMATIC：**標籤是設定的模式，不代表正在執行**，要看 Configuration 頁的 DRS enabled 開關。
- **原則：平常負責搬移的只能有一個。** ProxCenter DRS 和 PVE 的 Automatic Rebalance 同時開，會互相把服務搬來搬去（乒乓效應）。

### 10/02～10/12 規則正本放哪裡（歷史紀錄）

> 2026-10-13 起 ProxCenter 的三條規則已全部刪除，現況見第 12 節。

| 規則 | 正本 | 副本 | 說明 |
| --- | --- | --- | --- |
| DNS 互斥 | **PVE HA rules** | ProxCenter | HA 資源，維護與故障時由 PVE 搬 |
| DC 互斥 | **PVE HA rules**（10/03 起） | ProxCenter | DC01、DC02 已加入 HA（第 10 節） |
| VGA 固定 node11 | **ProxCenter** | — | 顯示卡直通的 VM 本來就無法遷移，**不可加入 HA** |

當時的原則：**會在故障或維護時被自動搬動的東西，規則放 PVE；其他的放 ProxCenter。** 同一條規則存在兩邊時，修改要兩邊一起改。

DC 加入 HA 前，沒有機制會自動檢查 DC 互斥，所以每更新完一台要手動檢查兩台 DC 有沒有被搬到一起：

```bash
pvesh get /cluster/resources --type vm --output-format json | grep -oE '"id":"qemu/10[67]"[^}]*"node":"[^"]*"'
```

當時 DC02 曾被手動移到 node10、DC01 在 node12，仍符合互斥。

## 9. 步驟三：手動分散 node10（DRS 看不到「服務太集中」）

**ProxCenter Load Overview（2026-10-02）**：

| 節點 | CPU | RAM | 台數 |
| --- | --- | --- | --- |
| node11 | 1.0% | 33.4% | 2 |
| node10 | 2.4% | 31.4% | 9 |
| node12 | 1.0% | 23.2% | 3（標記為可接收的 Target） |

叢集 CPU 約 1%、RAM 29%，不平衡度 10%。node11 只有兩台用戶端 VM，但記憶體配置大，RAM 使用率反而最高。**從使用率看很平衡，DRS 不會把 node10 視為問題。**

但 node10 承載 9 台，包含 DNS、ProxCenter、Wazuh、DC02，節點故障時影響最大。這是**可用性風險**，不是效能問題，需要人工規劃。

**第一步：Wazuh（ct:112）移到 node12**

```bash
ha-manager migrate ct:112 node12          # HA 資源要用 ha-manager，不要用 pct migrate
watch -n 5 "ha-manager status | grep ct:112"
```

**看到的結果**：`ct:112 (node12, started)`；在 node12 確認 4 個 Wazuh 服務 active、`vm.max_map_count` 1048576、Active 18（17 Agent + Manager），Dashboard 顯示 Active 17、Disconnected 0。好處是 node10 故障時，監控系統不會跟著停。

**第二步：DC02（VM 107，當時非 HA）live migration 到 node11**

先確認磁碟都在共用儲存、沒有 hostpci／usb 直通，且 DC01 不在目標節點：

```bash
qm config 107 | grep -E 'scsi|virtio|sata|ide|hostpci|usb'
qm migrate 107 node11 --online       # 在 VM 目前所在的節點執行
```

**看到的結果**：記憶體 4 GB、實際傳輸 3.4 GiB，平均 342.9 MiB/s，**停頓 63 ms**（上限 100 ms），17 秒完成；DC01 在 node12、DC02 在 node11。輸出中的 `conntrack state migration not supported or disabled` 表示防火牆連線追蹤狀態不會跟著搬，本案資料中心防火牆沒啟用，影響不大。

遷移後在 DC02 上確認：`dcdiag /q` 無輸出、`repadmin /replsummary` 兩台 DC 都是 0／5 失敗、DNS／Kdc／Netlogon／NTDS 都是 Running；Wazuh 上 DC02（ID 014）維持 Active。

調整後各節點台數由 9／2／3 變成 7／3／4（node10／node11／node12）。

## 10. 第一次逐台更新與 DC 加入 HA（2026-10-03）

三台用 ProxCenter Rolling Update 一次一台更新為 pve-manager 9.2.21、kernel 7.0.14-20。順序 node11 → node12 → node10：ProxCenter 所在的 node11 先更新，之後更新其他節點時 ProxCenter 不會中斷。

### 10-1 更新前後的檢查腳本（唯讀）

每台更新後執行一次：

```bash
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
```

| 段落 | 在查什麼 |
| --- | --- |
| `loc()` | 小函式：輸入 VMID，回傳它目前在哪台節點 |
| Ceph | 健康狀態、OSD、noout、PG |
| Versions | 三台的 pve-manager 和 kernel 版本 |
| HA | 只列出**不是** started／active 的項目；全部正常就印一行 OK |
| Placement | 每台節點上有哪些 VM／CT |
| DNS／DC | 互斥的兩台是否分開，同台就印 `!!! SAME NODE` |
| Wazuh／LibreNMS | Agent 數量、有沒有斷線設備 |

> 加入 grafana（CT 114）後，Wazuh 那行的預期值已改為 19（18 agents + manager），見 [戰情中心（一）](https://kbwangtw.github.io/IT-Knowledge-Base/docs/pve/grafana-war-room-wazuh/)。

### 10-2 結果與發現

**結果**：Ceph `HEALTH_OK`、`noout` 已解除、PG 全部 active+clean；HA 全部 started；Wazuh 18、LibreNMS 無斷線設備。

| 現象 | 原因／處理 |
| --- | --- |
| 更新過程中 DC01、DC02 一度在同一台 | 更新時把 DC 手動加入 HA，但當時還沒有 DC 互斥規則，維護模式由 PVE 依負載選目的地；之後建立 PVE 規則 |
| 更新後服務集中在 node10（8／4／2） | 維護結束後服務沒有全部回到原節點；用 `ha-manager migrate` 和 `qm migrate --online` 移回，恢復 6／4／4 |
| VM 加入 HA 後 `qm migrate` 顯示 `Requesting HA migration` | HA 資源的遷移會交給 HA 執行，VM 仍是 live migration |

### 10-3 目前 HA 資源與規則

**HA 資源**：9 個 LXC（100、101、102、103、105、109、110、112、113）與 VM 106（DC01）、107（DC02）、111（CA）。

WinClient（108）有 `hostpci0` 顯示卡直通、UBClient（104）同屬 VGA 固定規則，**不加入 HA**（其他節點沒有對應硬體，維護時遷移會失敗）。

**PVE HA 規則**（`/etc/pve/ha/rules.cfg`）：

```text
resource-affinity: <自動產生的名稱>
        comment AdGuard and Pi-hole must run on different nodes
        affinity negative
        resources ct:100,ct:101

resource-affinity: <自動產生的名稱>
        comment DC01 and DC02 must run on different nodes
        affinity negative
        resources vm:106,vm:107
```

**VM 加入 HA 後的注意事項**：

- 關機要用 HA 操作（`ha-manager set vm:106 --state stopped` 或網頁的 HA 選項）。直接在客體內關機，HA 會把它重新開起來。
- 遷移一律由 HA 執行；互斥規則會讓 HA 拒絕把兩台 DC 放在同一台。

## 11. 第二次逐台更新（2026-10-08）

**更新內容**：kernel 7.0.14-20 → 7.0.14-22、Ceph 20.2.4-pve4 → pve5（上游版本相同，只是 Proxmox 打包版次）、libpve-common-perl 9.2.3、libpve-storage-perl 9.1.12、proxmox-backup-client 4.2.8、xz-utils／liblzma5。pve-manager 維持 9.2.21。

**順序依 ProxCenter 所在節點調整**：更新前 ProxCenter 在 node12（不是上次的 node11）。ProxCenter 是 LXC，搬移會重開機，如果在 Rolling Update 途中被搬走，流程會中斷。所以：

1. 先更新 node11（只有已關機的 WinClient、UBClient，不需遷移任何服務）。
2. 用 `ha-manager migrate ct:<ProxCenter ID> node11` 把 ProxCenter 搬到已更新的 node11（執行前先確認 CT 編號）。
3. 再用 ProxCenter 更新 node12 → node10。

> **原則：每次更新前先看 ProxCenter 在哪一台，先更新沒有 ProxCenter 的節點，再把 ProxCenter 搬到已更新的節點。**

**更新前準備**：WinClient（108）、UBClient（104）不在 HA、無法遷移，先在客體內關機，全部更新完再開機。這段期間 Wazuh 顯示這兩台 Disconnected，屬預期。

每台更新後執行 `cluster-check.sh`，Ceph `HEALTH_OK`、PG 全部 `active+clean` 後才開始下一台。

| 觀察 | 說明 |
| --- | --- |
| 節點剛重開時 PG 顯示 96／97 active+clean | OSD 剛上線還在 peering，1～2 分鐘內恢復 |
| LibreNMS 短暫顯示剛重開的節點或剛搬移的 LXC 為 down | 輪詢間隔 5 分鐘；確認 snmpd 為 active 後等下一輪即恢復 |
| node12 的服務（CA、DC01、Pihole、wazuh）維護後自動回到 node12 | 符合預期 |
| node10 維護後 DC02、ai 留在 node11，沒自動搬回 | 服務不一定全部自動回原節點；比對更新前的 Placement，用 `ha-manager migrate` 手動搬回 |
| DC01／DC02、AdGuard／Pihole 全程在不同節點 | PVE HA 互斥規則有效 |

**結果**：三台 kernel 都是 `7.0.14-22-pve`；Ceph `HEALTH_OK`、97 PG active+clean、`noout` 已解除；HA 全部 started；配置恢復為更新前（node10：AdGuard、DC02、Graylog、IPAM、ai、librenms、wireguard；node11：ProxCenter、UBClient、WinClient；node12：CA、DC01、Pihole、wazuh）；Wazuh 18；LibreNMS 無斷線設備。

舊 kernel 7.0.14-20 原本保留作開機退路；10/13 三台升到 7.0.14-23 後，10/14 用 `apt autoremove` 移除（見 [PBS 更新後，怎麼確認備份還能用？](https://kbwangtw.github.io/IT-Knowledge-Base/docs/pve/ProxCenter-PBS-Update-and-DR-Validation-SOP/)），三台實測剩 6.17.13-21、7.0.14-22、7.0.14-23，`Manually selected kernels` 為 None。

## 12. 決定只留 PVE 一套機制（2026-10-13）

ProxCenter DRS 和 PVE HA／CRS **沒有整合**，各自獨立運作。兩套同時存在時，規則要兩邊維護，自動平衡也可能互相打架。所以決定只留一套，並一併評估了第三方的 [ProxLB](https://github.com/credativ/ProxLB)（v2.3.0）。

### 12-1 為什麼留 PVE

| 比較 | PVE（HA＋CRS） | ProxCenter DRS | ProxLB |
| --- | --- | --- | --- |
| 故障轉移、fencing | **只有它做得到** | 否 | 否 |
| 維護、故障時搬 HA 服務 | **一定是 PVE** | 規則不會生效 | 否 |
| 執行位置 | 每台節點，不依賴外部服務 | CT 110，所在節點掛了就停 | 另一個 daemon，要自己維護 |
| 平衡非 HA guest | 否 | 可 | 可 |

PVE HA 本來就必須留，故障和維護時也一定照 PVE 的規則搬。只留 ProxCenter 或 ProxLB 還是得同時維護兩套規則，所以**只留 PVE 是唯一不會打架的選擇**。

ProxLB 的 README 也提到，PVE 9.2 起內建 Dynamic Load Balancing，可以平衡 HA 資源；ProxLB 的優勢在平衡非 HA guest 和更複雜的排程邏輯。本叢集重要服務都已加入 HA，用不到這些功能，所以**不安裝**。

### 12-2 實際處理

| 項目 | 結果 |
| --- | --- |
| ProxCenter → DRS → Affinity | DNS、DC、VGA 三條規則已刪除，畫面顯示 `No affinity rules configured` |
| ProxCenter → DRS → General settings | `DRS enabled` 維持關閉 |
| PVE HA 狀態 | quorum OK、fencing armed、三台 lrm active；master 顯示 `static load CRS` |
| PVE HA Resource Affinity Rules | DNS（ct:100、ct:101）、DC（vm:106、vm:107）都是 negative、enabled |
| PVE HA Node Affinity Rules | 無 |
| `grep crs /etc/pve/datacenter.cfg` | `crs: ha=static,ha-rebalance-on-start=1`，和 10/02 相同，沒有自動平衡 |

- **10/19 保險設定**：ProxCenter **DRS → Configuration → General settings** 改成下表後按 Save，重新整理確認已保存。就算日後有人誤開 DRS，也只會在 Recommendations 頁列出建議，不會自己搬。

  | 欄位 | 修改前 | 修改後 |
  | --- | --- | --- |
  | DRS enabled | 關閉 | **維持關閉**（決定不開啟「只給建議」模式） |
  | Operation mode | Automatic（Fully automatic balancing） | **Manual**（Recommendations only） |
  | Per-cluster mode（ITBH-Cluster） | Global default (Automatic) | Global default (Manual)，跟著全域設定 |
  | Guest types to balance | VMs + Containers (LXC) | **只留 VMs (QEMU)** |

  **為什麼只留 VM**：比「重開機」的話容器比較快，但 DRS 搬移時兩者方式不同。VM 用 **live migration**，不重開機，實測停頓約 63 ms（第 9 節 DC02）；容器只能**重啟式遷移**（關機 → 搬移 → 開機），裡面的 DNS 會短暫查不到，Graylog、Wazuh 這類 Java＋資料庫服務要好幾分鐘才完全就緒。這個欄位的說明寫明它**只影響 DRS 負載平衡**，維護模式與 HA 規則仍會搬所有類型，所以不影響 PVE 的維護與故障轉移。

- **兩者怎麼相輔相成**：PVE HA 自動負責故障轉移與維護搬移（遵守互斥規則）；DRS 的長處是看負載，但不認得 PVE 的規則。所以不讓兩者同時自動執行；需要參考負載時，可以開啟 DRS 並維持 Manual，由人看過建議、確認沒有把 DNS 或 DC 搬到同一台後再套用。
- ProxCenter 的 Rolling Update 不屬於 DRS，可以繼續使用；它呼叫 PVE 維護模式，HA 服務仍由 PVE 搬。

### 12-3 HA Resources 的 Auto-Rebalance 欄位

HA Resources 清單中 12 台的 `Auto-Rebalance` 都顯示 `true`，但 `datacenter.cfg` 沒有開啟自動平衡的參數。推測這一欄代表「允許被自動平衡」，要等全域開關打開才生效（未查證官方文件）。目前沒有觀察到任何服務被自動搬移。

### 12-4 只留 PVE 的代價

- **非 HA 的 guest 沒人自動平衡、也沒有規則保護。** WinClient（108）、UBClient（104）有顯示卡直通，本來就無法遷移；更新前照第 11 節先關機。
- **新增重要服務時，要記得加入 HA resources**，必要時一併建立 HA rules，否則 PVE 不會管它。
- **服務集中只能人工分散。** 10/13 的 HA 資源分布：node10 7 台（AdGuard、librenms、IPAM、Graylog、wireguard、ai、DC02）、node11 1 台（ProxCenter）、node12 4 台（Pihole、wazuh、DC01、CA）。`static` CRS 只影響啟動和故障轉移時放哪裡，不會搬動正在運作的服務（10/19 已再分散，見第 13 節）。

## 13. 再次手動分散 HA 資源（2026-10-19）

**為什麼**：10/13 之後 Grafana（ct:114）也加入 HA，HA 資源變成 13 個，分布是 **8／1／4**。node10 一台掛掉會有 8 個服務同時重啟；CRS static 不會自己搬動正在運作的服務，只能人工分散。

**分配原則**：

| 原則 | 做法 |
| --- | --- |
| DNS、DC 分開 | 既有的兩條 Resource Affinity 規則保證（第 6、10 節） |
| 三套監控分開 | Graylog、LibreNMS、Wazuh 各在一台，任一台掛了還有兩套能看 |
| 遠端救援的路要保留 | WireGuard 不跟最多服務的節點放一起 |
| Grafana 放第三台 | 它讀 LibreNMS（node10）和 Wazuh（node12），放 node11 時任一台掛了還看得到另一邊 |

**① 盤點**（node10，只讀取）：

```bash
ha-manager status | grep -E '^service' | sort -k3
for n in node10 node11 node12; do
  pvesh get /nodes/$n/status --output-format json | python3 -c "
import json,sys; d=json.load(sys.stdin); m=d['memory']
print('$n', '已用 %.1f / 共 %.1f GiB（%.0f%%）' % (m['used']/2**30, m['total']/2**30, 100*m['used']/m['total']))"
done
for id in 105 109 113; do
  node=$(pvesh get /cluster/resources --type vm --output-format json | python3 -c "import json,sys; print([r['node'] for r in json.load(sys.stdin) if r['vmid']==$id][0])")
  echo "ct:$id（$node）$(ssh root@$node "pct config $id" < /dev/null | grep -E '^(hostname|memory|cores|swap):' | tr '\n' ' ')"
done
ha-manager rules config
grep crs /etc/pve/datacenter.cfg
```

**看到的結果**：

| 節點 | HA 資源 | 記憶體 |
| --- | --- | --- |
| node10 | AdGuard(100)、LibreNMS(102)、IPAM(103)、Graylog(105)、WireGuard(109)、ai(113)、Grafana(114)、DC02(vm:107)（8） | 16.7 / 62.1 GiB（27%） |
| node11 | ProxCenter(110)（1） | 22.1 / 62.1 GiB（36%，顯示卡直通 VM 佔用） |
| node12 | Pi-hole(101)、Wazuh(112)、DC01(vm:106)、CA(vm:111)（4） | 17.7 / 62.1 GiB（29%） |

要搬到 node11 的設定值：Graylog 8 GiB／4 核、ai 2 GiB／2 核、WireGuard 0.5 GiB／1 核，加上 Grafana，合計約 12 GiB；node11 搬完約 55%，仍有空間。DNS、DC 兩條規則 `enabled`、`in use`，`crs: ha=static,ha-rebalance-on-start=1`。

**② 逐台搬移**：先搬不重要的（ai）量時間，WireGuard 最後搬，而且**在內網操作**（透過 VPN 操作的話，搬的時候連線會斷）。用一個小函式搬移並計時：

```bash
mig() {
  id=$1; t0=$(date +%s)
  ha-manager migrate ct:$id node11
  for i in $(seq 1 100); do
    sleep 3
    if ha-manager status | grep -q "ct:$id (node11, started)"; then
      echo "✅ ct:$id 已在 node11 啟動，耗時 $(( $(date +%s) - t0 )) 秒"; return 0
    fi
  done
  echo "⚠️ ct:$id 5 分鐘內沒有完成，目前狀態："; ha-manager status | grep "ct:$id"
}
mig 113        # ai
mig 114        # Grafana
mig 105        # Graylog（漏收 1～3 分鐘日誌；外部健康檢查可能寄一封【Graylog 異常】，屬預期）
mig 109        # WireGuard（最後、在內網）
```

| 片段 | 意思 |
| --- | --- |
| `ha-manager migrate` | HA 資源要用它搬；LXC 自動走「關機 → 搬移 → 開機」 |
| `grep "ct:$id (node11, started)"` | 每 3 秒檢查，直到在 node11 啟動 |

**③ 每台搬完的檢查**：

```bash
ssh root@node11 "pct exec 114 -- curl -s http://localhost:3000/api/health" < /dev/null
ssh root@node11 "pct exec 105 -- sh -c 'curl -s -o /dev/null -w \"lbstatus http=%{http_code}\n\" http://\$(hostname -I | awk \"{print \\\$1}\"):9000/api/system/lbstatus'" < /dev/null
ssh root@node11 "pct exec 109 -- wg show | grep -E 'interface|listening|peer|latest handshake'" < /dev/null
```

**看到的結果**：四台都在 node11 `started`；Grafana `"database": "ok"`（13.2.3）；Graylog `lbstatus http=200`；WireGuard 搬完後用手機行動網路連 VPN，連得上、能進內網服務（容器 IP 跟著容器走，路由器的 port forwarding 指向容器 IP，不用改）。

**搬完的分布（4／5／4）**：

| 節點 | HA 資源 |
| --- | --- |
| node10 | AdGuard、LibreNMS、IPAM、DC02 |
| node11 | ProxCenter、Graylog、WireGuard、ai、Grafana |
| node12 | Pi-hole、Wazuh、DC01、CA |

一台故障時同時重啟的服務，從最多 8 個降到最多 5 個。維護後服務不一定回到這個位置（CRS static 不會自動搬回），每次逐台更新後用 `ha-manager status` 對照這張表，必要時手動 `ha-manager migrate`。

## 14. 常見問題

| 現象 | 怎麼辦 |
| --- | --- |
| ProxCenter 設了規則，維護時沒遵守 | 維護時是 PVE 在搬 HA 資源；規則要設在 PVE HA rules |
| `ha-manager rules config` 看不出是分開還是放一起 | 打開規則或看 `/etc/pve/ha/rules.cfg` 的 `affinity negative` |
| 搬 HA 資源用 `pct migrate` 沒反應或被拒 | HA 資源要用 `ha-manager migrate` |
| VM 在客體內關機後又自己開起來 | HA 資源要用 `ha-manager set … --state stopped` |
| 維護後服務沒回到原節點 | 正常；對照第 13 節的分布表，手動 `ha-manager migrate` |
| Rolling Update 中途中斷 | 可能是 ProxCenter 自己被搬走；先更新沒有 ProxCenter 的節點 |
| 叢集使用率很平均，但某台服務特別多 | DRS 只看使用率；可用性風險要人工分散 |

## 15. 待驗證與後續

| 項目 | 狀態 |
| --- | --- |
| 用 ProxCenter 完整逐台更新三台，每台確認 DNS／DC 位置 | ✅ 2026-10-03（第 10 節） |
| ProxCenter 搬移非 HA VM 時是否遵守 Affinity rules | 已改為 DC 加入 HA、由 PVE 規則保證，不再依賴 |
| 逐台更新時 DC 規則全程有效、服務維護後是否自動搬回 | ✅ 2026-10-08：規則有效；服務不一定自動搬回，需手動（第 11 節） |
| 單節點故障演練：實測 Ceph I/O latency、HA 恢復時間，並確認告警鏈（Graylog「節點離線」、另兩台的監控腳本與 postfix 寄信）在一台失聯時仍會寄信 | ⏳ 未演練（2026-10-19 列入待辦；需事先排時段、避開 21:00～03:00 備份） |
| Dynamic Load 與 Automatic Rebalance 的實際行為 | ✅ 10/20 查證（未找到官方 admin guide 章節，依開發者郵件論壇與官方論壇公告）：pve-ha-manager 5.2.0（pve-manager 9.1.8）起加入 Dynamic Load，可勾選 Automatic Rebalance 並設定不平衡門檻等參數，避免不必要的遷移；**只平衡 HA 資源**，且遷移一定遵守 node／resource affinity 規則；開發者標示為 technology preview，目標在 9.2 穩定。本叢集維持 `ha=static`、不開自動平衡（LXC 遷移會重啟） |
| ProxCenter DRS 停用、規則改由 PVE 統一管理 | ✅ 2026-10-13（第 12 節） |
| ProxCenter Operation mode 改為 Manual（保險） | ✅ 2026-10-19，Guest types 同時改為只留 VMs（第 12-2 節） |
| HA 資源集中在 node10，是否再分散 | ✅ 2026-10-19 由 8／1／4 分散為 4／5／4（第 13 節） |

**單節點故障的預期行為**（依 Ceph 預設值推估，未實測）：節點剛失聯的十幾到數十秒，主副本在該節點上的資料讀寫會短暫卡住；確認 OSD 下線後恢復讀寫，但剩下兩台承擔全部負載，而且在節點回來前沒有再壞一顆硬碟的餘裕。

## 16. 延伸閱讀

- [PVE 更新重開後 HA 服務卡在 error：原因與救回步驟](https://kbwangtw.github.io/IT-Knowledge-Base/docs/pve/pve-ha-service-error-after-reboot/)（Shutdown Policy 改為 migrate）
- [ProxCenter 逐台更新 PVE](https://kbwangtw.github.io/IT-Knowledge-Base/docs/pve/proxcenter-ceph-rolling-update/)
- [Proxmox VE：High Availability（含 CRS、HA rules）](https://pve.proxmox.com/pve-docs/chapter-ha-manager.html)
- [Ceph：Monitor／OSD 心跳與 down／out 設定](https://docs.ceph.com/en/latest/rados/configuration/mon-osd-interaction/)
- [ProxCenter 文件：DRS](https://docs.proxcenter.io/automation/drs/)
- [ProxLB（含與 PVE Dynamic Load Balancing 的比較）](https://github.com/credativ/ProxLB)
- [Proxmox 論壇：pve-manager 9.1.8／pve-ha-manager 5.2.0 Dynamic load 介紹](https://forum.proxmox.com/goto/post?id=849718)、[pve-devel 郵件論壇：load balancer 文件 patch](https://lore.proxmox.com/all/20260409114224.323102-1-d.kral@proxmox.com)
