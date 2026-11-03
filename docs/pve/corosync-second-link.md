---
layout: default
title: "Corosync 加第二條 link（備援）：熱載入、不用重啟"
date: 2026-11-02
categories: [PVE, Corosync, HA]
permalink: /docs/pve/corosync-second-link/
last_modified_at: 2026-11-03
---

# Corosync 加第二條 link（備援）：熱載入、不用重啟

> **一句話**：PVE 叢集原本只有一條 Corosync 心跳線（在叢集網的交換器上），那台交換器壞掉三台就同時失聯；這篇在服務網加第二條 link 當備援，改一份設定檔就套用，不用重啟任何服務，實測三台兩條 link 都是 connected。

| 項目 | 內容 |
| --- | --- |
| 適合誰看 | 管理 PVE 叢集、想消除「心跳只有一條線」單點故障的人 |
| 環境 | PVE 9.2 三節點（node10／11／12）；叢集網在 TL-SX1008（10G）、服務網在 TL-SG108-M2（2.5G），兩台交換器沒有互連 |
| 日期 | 2026-11-02 上午（約 11:40） |
| 風險 | 低：新增 link 是熱載入，不重啟；做之前先備份，可以還原 |
| 結論 | ✅ link1 已加、三台兩條 link 都 connected、Quorate 沒有重新組成員 ✅ 啟用 PVE 防火牆後兩條 link 仍都正常 ⏳ 「主要 link 斷線後備援真的接手」尚未實測 |

> 文中 IP 是示範位址：叢集網 198.51.100.x、服務網 192.0.2.x，最後一個數字和真實環境對得上，但網段不是真的。

## 1. 先認識幾個名詞

| 名詞 | 白話解釋 |
| --- | --- |
| **Corosync** | 叢集的「心跳」：三台節點靠它互相確認「你還活著嗎」，並投票決定誰有多數（quorum） |
| **quorum** | 過半數節點能互相聯絡才算「叢集正常」；失去 quorum，HA 會停手、`/etc/pve` 變唯讀 |
| **link** | Corosync 的一條通訊路線。每條 link 在不同的網路上；`link0`、`link1` 是編號 |
| **ring0_addr／ring1_addr** | 設定檔裡每台節點在 link0、link1 上使用的位址 |
| **knet** | Corosync 現在用的傳輸層，支援多條 link 並自動切換 |
| **`config_version`** | 設定檔的版本號。每次改設定**一定要加 1**，叢集才會認為是新設定 |
| **熱載入** | 不重啟服務，Corosync 直接讀新設定並套用 |

## 2. 為什麼要加、怎麼設計

PVE 官方文件（Cluster Manager）的說法：Corosync 要用專用網路，不要和儲存流量共用，而且至少要有另一條在**不同實體網路**的 link 當備援。

| 項目 | 現況 |
| --- | --- |
| link0 | 叢集網（198.51.100.x，SX1008）：Corosync 原本唯一的一條，**單點** |
| link1（新增） | 服務網（192.0.2.10／11／12，SG108-M2）：三台各用自己的管理位址，只當備援 |
| 優先順序 | **不另外設 `knet_link_priority`**：官方文件說沒設優先權時，編號小的 link 先用，所以 link0 仍是主要、link1 只在 link0 不通時接手 |

```text
node10 ═══ link0（叢集網，SX1008）═══ node11 ═══ node12
   ╲                                      │
    ╲══════ link1（服務網，SG108-M2）═════╱     ← 只當備援
```

兩台交換器是兩個獨立的設備，所以其中一台掛掉，另一條 link 還活著。

## 3. 步驟（手動執行，2026-11-02 11:40）

### 3-1 做什麼

只改一份檔案：`/etc/pve/corosync.conf`（它會自動同步到三台）。要改的地方只有三類：

1. 每台節點加一行 `ring1_addr`。
2. `totem` 區塊加一組 `interface { linknumber: 1 }`。
3. `config_version` 加 1（原本 3，改成 4）。

### 3-2 怎麼做

**先備份**（兩份，一份在叢集檔案系統、一份在本機）：

```bash
cp /etc/pve/corosync.conf /etc/pve/corosync.conf.bak
cp /etc/pve/corosync.conf /root/corosync.conf.bak-20261102
```

**改在副本上，不要直接改原檔**：

```bash
cp /etc/pve/corosync.conf /etc/pve/corosync.conf.new
nano /etc/pve/corosync.conf.new
```

改完之後，相關位置長這樣（只列要動的欄位，`…` 代表原本的其他欄位不變）：

```text
nodelist {
  node {
    name: node10
    …
    ring0_addr: 198.51.100.10
    ring1_addr: 192.0.2.10
  }
  # node11（192.0.2.11）、node12（192.0.2.12）同樣各加一行 ring1_addr
}

totem {
  …
  config_version: 4
  interface {
    linknumber: 0
  }
  interface {
    linknumber: 1
  }
}
```

| 片段 | 意思 |
| --- | --- |
| `ring1_addr` | 這台節點在 link1 上用的位址，這裡是服務網的管理位址 |
| `interface { linknumber: 1 }` | 宣告「有第二條 link」 |
| `config_version: 4` | 比原本的 3 大，叢集才會載入 |

**套用前先用 `diff` 確認只改了該改的**：

```bash
diff /etc/pve/corosync.conf /etc/pve/corosync.conf.new
```

**應該看到**：只有 3 行 `ring1_addr`、3 行 `interface`／`linknumber: 1` 相關的新增，以及 `config_version` 3→4。我這次還看到原檔尾端多一個空白行，無害。

**確認沒問題才套用**：

```bash
mv /etc/pve/corosync.conf.new /etc/pve/corosync.conf
```

### 3-3 應該看到什麼（實測）

```bash
pvecm status
corosync-cfgtool -s
journalctl -u corosync --since "10 minutes ago"
```

| 檢查 | 結果 |
| --- | --- |
| `pvecm status` | `Config Version: 4`；`Quorate: Yes`；Ring ID 沒變（**沒有重新組成員**） |
| `corosync-cfgtool -s` | 三台各自對另外兩台，link0、link1 都是 `connected` |
| 日誌 11:40:17 | `Config reload requested by node 1`：是**熱載入**，Corosync 沒有重啟 |
| 日誌 11:40:19 | `link: Link 1 is up`；對 host 2、host 3 的 `best link: 0 (pri: 1)`：link0 仍是主要 |
| PMTUD | 1397 |
| 其他兩台 | node11、node12 的 `/etc/corosync/corosync.conf` 也已經是 `config_version` 4，並有三行 `ring1_addr` |
| PVE 防火牆 | 之後啟用 PVE 防火牆，`pve-firewall localnet` 同時列出 link 0 與 link 1，兩條 link 仍都 `connected`（2026-11-02 實測，見[啟用防火牆階段 1a](https://kbwangtw.github.io/IT-Knowledge-Base/docs/pve/pve-firewall-stage1a-ceph-hardening/)） |

## 4. 還原方法

把備份當成副本，**`config_version` 一定要比現在大**（例如改成 5），確認後再套用：

```bash
cp /root/corosync.conf.bak-20261102 /etc/pve/corosync.conf.new
nano /etc/pve/corosync.conf.new
diff /etc/pve/corosync.conf /etc/pve/corosync.conf.new
mv /etc/pve/corosync.conf.new /etc/pve/corosync.conf
```

要在 `nano` 裡把 `config_version` 改成 5。若直接把版本號 3 的備份蓋回去，叢集會認為那是舊設定，不會載入。

## 5. 常見問題

| 現象 | 怎麼辦 |
| --- | --- |
| 新增 link 要不要重啟 Corosync？ | 不用。`mv` 之後會熱載入（日誌有 `Config reload requested`） |
| 改完設定沒生效 | 檢查 `config_version` 有沒有比原本大 |
| 還原時沒生效 | 備份檔的 `config_version` 比現在小；還原時要手動改成更大的數字 |
| 想直接改原檔 | 不要。`/etc/pve` 是叢集共用檔案系統，編輯到一半就會被同步；先改副本、`diff`、再 `mv` |
| 不知道 link1 有沒有真的備援 | 用 `corosync-cfgtool -s` 看兩條都 `connected`；備援接手本身尚未實測（見待辦） |

## 6. 待辦

- [ ] 實測「備援真的接手」：官方的做法是拔掉舊 link 的線，但叢集網那條線同時載著 Ceph 複寫與備份，**不建議**；較安全的做法是只暫時擋掉 Corosync 的埠，再看 `corosync-cfgtool -s` 的變化，**尚未做**
- [ ] 過幾天清掉 `/etc/pve/corosync.conf.bak`（`/root` 的備份可保留）
- [ ] 確認 TL-SX1008、TL-SG108-M2 沒有管理功能（見[內網橫向感染評估](https://kbwangtw.github.io/IT-Knowledge-Base/docs/network/internal-network-lateral-movement-assessment/)）

## 7. 延伸閱讀

- [Proxmox VE：Cluster Manager（Corosync 冗餘網路）](https://pve.proxmox.com/pve-docs/chapter-pvecm.html)
- [內網橫向感染評估：先看清楚網路長怎樣，再決定要不要裝防火牆](https://kbwangtw.github.io/IT-Knowledge-Base/docs/network/internal-network-lateral-movement-assessment/)
- [啟用 PVE 防火牆（階段 1a）：只收緊 Ceph 與沒用的埠](https://kbwangtw.github.io/IT-Knowledge-Base/docs/pve/pve-firewall-stage1a-ceph-hardening/)
