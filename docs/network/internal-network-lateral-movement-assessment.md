---
layout: default
title: "內網橫向感染評估：先看清楚網路長怎樣，再決定要不要裝防火牆"
date: 2026-10-31
categories: [Network, Security, PVE]
permalink: /docs/network/internal-network-lateral-movement-assessment/
last_modified_at: 2026-11-01
---

# 內網橫向感染評估：先看清楚網路長怎樣，再決定要不要裝防火牆

> **一句話**：想「在叢集上建一台軟體防火牆來防橫向感染」，先盤點後發現——叢集／備份網已經在**獨立的交換器**上，真正的缺口是「管理介面和使用者在同一個網段」；現階段結論是**不裝防火牆、不啟用完整 PVE Firewall**，改評估風險小很多的 `pveproxy` 來源限制（⏳ 盤點做到一半，已暫停）。

> 文中 IP 都是文件示範位址（服務／管理網 192.0.2.0/24、叢集／備份網 198.51.100.0/24）；最後一個數字和真實環境對得上，但網段不是真的。

| 項目 | 內容 |
| --- | --- |
| 適合誰看 | 想評估「內網要不要加防火牆」、手上只有不能設定的交換器；PVE 管理頁面和一般設備在同一網段的人 |
| 環境 | PVE 9.2 三節點（node10／11／12）、Ceph、PBS31；兩台 TP-Link 交換器（TL-SX1008 10G、TL-SG108-M2 2.5G）；上游是中華電信數據機（NAT 模式、DHCP 由數據機發） |
| 日期 | 2026-10-31（討論與唯讀盤點）；2026-11-01（數據機轉送刪除後的外部驗證）；**這篇沒有改任何 PVE 設定** |
| 結論 | ✅ 叢集／備份網已物理隔離 ✅ 節點不轉送封包（`ip_forward = 0`）✅ 8006、3000 的數據機轉送規則已刪除，只剩 UDP 51820 → WireGuard，11/01 已從外部驗證（8006、3000 連不上、VPN 可用）⚠️ 管理介面與使用者同網段 ⚠️ Ceph MON 綁在服務網 ⏳ `pveproxy` 來源限制的白名單盤點中（暫停） |

## 1. 先認識幾個名詞

| 名詞 | 白話解釋 |
| --- | --- |
| **橫向感染（lateral movement）** | 一台機器中毒後，從內網跳去感染其他機器，不是從外面打進來 |
| **無網管交換器（unmanaged switch）** | 插上就能用、沒有管理介面；不能設定 VLAN、不能做 port mirror、不能設存取規則 |
| **VLAN** | 在同一台交換器上劃出彼此隔離的虛擬網段；要有網管功能才能設 |
| **port mirror（SPAN）** | 把某個埠的流量複製給另一個埠，讓 IDS 之類的設備偵測；也要網管功能 |
| **雙網卡主機（dual-homed）** | 同時接在兩個網段的主機；不設防時，它就是兩個網段之間唯一的橋 |
| **Ceph `public_network`／`cluster_network`** | `public` 是 MON、MGR 與客戶端連 Ceph 用的網路；`cluster` 是 OSD 之間複寫、修復用的網路 |
| **`local_network`** | PVE Firewall 自動偵測的別名，預設代表「節點所在的網段」，預設規則會放行它到管理埠 |
| **`pveproxy`** | 提供 PVE 網頁（8006）與 API 的服務；可用 `/etc/default/pveproxy` 設來源允許／拒絕清單 |
| **NAT 模式** | 數據機把內網位址換成對外 IP；外部主動連進來的流量，沒有轉送規則就會被擋 |

## 2. 網路全貌

```text
中華電信數據機（NAT，DHCP；只轉送 UDP 51820 → CT109）
        │
        ▼
SG108-M2（2.5G，無網管）── 服務／管理網 192.0.2.0/24
        │                  管理員電腦、DC、PVE 管理介面、ProxCenter、Grafana、JT-IPAM、WireGuard…
        │
   node10／node11／node12、PBS31、CT110（ProxCenter）
   ＝ 各有兩張網卡，同時接兩台交換器
        │
        ▼
SX1008（10G，無網管）── 叢集／備份網 198.51.100.0/24
                         Corosync、Ceph cluster_network、PBS 資料網、tokyo16
```

- 兩台交換器**彼此沒有互連**（2026-10-31 使用者確認）。
- 使用者只有一位（管理員本人），無線與手機不納入評估。
- 兩台交換器型號是依機身照片判斷，「無網管」是依型號與面板推測，**未對照官方規格表確認**。

## 3. 為什麼「叢集上建一台軟體防火牆」幫助有限

| 想法 | 為什麼幫助有限 |
| --- | --- |
| 在叢集上建 OPNsense／pfSense VM 當防火牆 | 同一個二層網段內的機器彼此通訊，**封包根本不經過任何路由器或防火牆**。使用者、管理介面和服務都在服務網的同一台交換器上，防火牆 VM 看不到這些流量 |
| 想用它做 IDS／流量偵測 | 需要 port mirror，無網管交換器做不到 |
| 想用它切網段 | 要先有網管功能（VLAN），或增加實體網卡與交換器重新佈線 |
| 閘道 VM 放在叢集上 | 磁碟在 Ceph 時，叢集冷開機要等 Ceph 起來才有閘道；網路壞了還可能連不上 PVE 去修它（循環依賴） |

**真正有效的位置在主機本身**：過濾發生在每台機器上，不靠交換器。

## 4. 實際盤點（node10，唯讀）

### 4-1 做什麼

查節點在兩個網段之間的角色、防火牆現況、誰在連管理埠。**全部是唯讀指令**。

```bash
grep -E 'public_network|cluster_network' /etc/pve/ceph.conf
grep -E 'ring[0-9]_addr|link' /etc/pve/corosync.conf
ip -br addr
sysctl net.ipv4.ip_forward
pve-firewall status
pve-firewall localnet
cat /etc/pve/firewall/cluster.fw
grep -l 'firewall=1' /etc/pve/qemu-server/*.conf /etc/pve/lxc/*.conf
ss -lntup | grep -E ':(22|8006|3128|3300|6789|8007) '
ss -tn state established '( sport = :3300 or sport = :6789 )'
awk '{print $1}' /var/log/pveproxy/access.log | sort | uniq -c | sort -rn | head -20
```

| 片段 | 意思 |
| --- | --- |
| `grep … ceph.conf` | Ceph 的 `public_network`、`cluster_network` 在哪個網段 |
| `grep … corosync.conf` | Corosync 心跳走哪個位址、有幾條 link |
| `ip -br addr` | 每張網卡的 IP；節點是否有兩張網卡 |
| `sysctl net.ipv4.ip_forward` | `0` 代表節點不在兩個網段之間轉送封包 |
| `pve-firewall status`、`localnet` | 防火牆現況，以及 `local_network` 偵測到哪個網段 |
| `grep -l 'firewall=1' …` | 列出「網卡防火牆旗標已開」的 VM／CT（`/etc/pve` 是整個叢集共用） |
| `ss -lntup \| grep …` | 這些服務在哪些位址監聽；`0.0.0.0`、`*` 代表所有網卡都聽 |
| `ss -tn state established …` | 現在有誰連到 Ceph MON |
| `awk … access.log` | 近期連到 8006 的來源 IP 排行 |

### 4-2 看到的結果

| 項目 | 結果 | 判斷 |
| --- | --- | --- |
| `ip_forward` | `0` | ✅ 節點不轉送，物理隔離有效 |
| `cluster_network` | 叢集／備份網（198.51.100.x） | ✅ 在獨立的 SX1008 上 |
| `public_network` | **服務／管理網（192.0.2.x）** | ⚠️ Ceph MON（3300、6789）綁在服務網，使用者網段連得到 |
| Corosync | 只有 `ring0`、`linknumber 0`，在叢集網 | ⚠️ 單一 link；SX1008 斷電或故障時三台同時失去心跳（可用性問題，**尚未評估影響**） |
| 節點網卡 | 管理網（`vmbr0`）與叢集網（`Cluster`）各一；`wlp4s0`（Wi-Fi）DOWN | ✅ 兩張網卡；Wi-Fi 沒有啟用，請保持 |
| `pve-firewall status` | `disabled/running`；`cluster.fw` 只有 `enable: 0`、`ebtables: 0` | 防火牆完全沒用到，沒有任何規則 |
| `local_network` | 192.0.2.0/24（整個服務網） | 啟用後，預設會放行整個服務網到管理埠，**單純啟用不會限制任何人** |
| 監聽 | 22、8006、3128 在所有位址；Ceph MON 只在服務網位址 | 管理埠對服務網全開 |
| `firewall=1` 的 VM／CT | 整個叢集只有 5 個：VM106（DC01）、CT100、CT103、CT112、CT113 | 總開關啟用時只有這 5 個會被過濾 |
| Ceph MON 連線 | 9 條，**來源全是 node10 自己** | ✅ 這個時間點沒有外部 IP 連到 node10 的 MON（只看一台、一個時間點） |

8006 來源（node10 的 `access.log`，近期）：

| 來源 | 次數 | 是誰 |
| --- | --- | --- |
| 192.0.2.30 | 62,940 | ProxCenter（依 KB 的 ProxCenter 管理 IP 推測，使用者確認） |
| 192.0.2.33 | 55,890 | Grafana（CT114，使用者確認） |
| 192.0.2.29 | 9,374 | JT-IPAM（CT103，使用者確認） |
| 192.0.2.54 | 74 | **未確認**；推測可能是管理員電腦的舊 DHCP 位址 |

管理員電腦目前是 192.0.2.51，由**數據機以 DHCP 動態分配**（會變）。CT109（WireGuard；所在節點會隨 HA 變動，用 `ha-manager status` 確認，2026-11-01 起在 node12）的 `eth0` 是 192.0.2.27、`valid_lft forever`（推測是靜態設定）。

### 4-3 數據機刪除轉送規則後的外部驗證（2026-11-01）

**做什麼**：數據機上 TCP 8006（PVE）與 TCP 3000（ProxCenter）的轉送規則已在 10/31 刪除（原本只是停用），要從外部確認「對外連不上」，並確認「VPN 仍可用」。**兩個方向都要測**：只測前者，可能是整條網路不通。

| 方向 | 怎麼測 | 結果 |
| --- | --- | --- |
| 8006、3000 不對外 | 家用筆電連手機熱點（在外面的網路），瀏覽器開 `<對外 IP>:8006` 與 `<對外 IP>:3000` | ✅ 兩個都是 `ERR_CONNECTION_TIMED_OUT`（連不上） |
| VPN 仍可用 | iPhone **關掉 Wi-Fi**、只用 4G，開 WireGuard，開內網的 `https://<節點內網 IP>:8006` | ✅ 可以連上（使用者回報） |

| 片段 | 意思 |
| --- | --- |
| 家用筆電連手機熱點 | 流量從外部的行動網路進來，避開家用數據機的 hairpin NAT（在家裡連自己的對外 IP 常逾時，不代表規則已關） |
| iPhone 關 Wi-Fi 只用 4G | 確保手機不在家裡網路；KB 的 [WireGuard 文章](https://kbwangtw.github.io/IT-Knowledge-Base/docs/pve/wireguard-remote-access-replace-8006/) 也是這樣測 |

- 家裡的筆電沒有安裝 WireGuard，所以 VPN 方向改用手機測，不必為了測試多建一個 peer。
- 另外也在手機開 VPN 的情況下用熱點給筆電測過，結果同樣連不上；但**熱點流量是否經過手機的 VPN 不確定**，這項不當作證據。
- 「逾時」只代表連不上，分不出是數據機丟棄封包還是別的原因；對「沒有對外開放」這個結論來說，兩者結果相同。
- 這是單一時間點的測試，不是持續掃描；全面的外部掃描（例如 `nmap`）沒有做。

## 5. 對照官方文件：啟用 PVE Firewall 的兩個地雷

文件：[Proxmox VE Firewall](https://pve.proxmox.com/pve-docs/chapter-pve-firewall.html)

| # | 文件寫的 | 對這個環境的意思 |
| --- | --- | --- |
| 1 | 啟用後預設放行：管理主機到 8006、22、3128、5900-5999、60000-60050；**叢集網的 Corosync UDP 5405-5412**。文件這一頁**沒有提到 Ceph** | Ceph 的 3300、6789 與 OSD 埠都在服務網上，總開關啟用後**會被擋**；Ceph 一斷，VM／CT 磁碟卡住，HA 資源跟著出事 |
| 2 | VM／CT 的每張虛擬網卡有**自己的防火牆旗標**，要和總開關同時啟用才生效 | 上表 5 個旗標已開的 VM／CT，在總開關啟用的那一刻開始被過濾。VM 層的預設進站政策我記得是 DROP，但這份文件沒寫，**未在這個環境驗證** |

另外：`local_network` 預設就是整個服務網，所以「只啟用、不改規則」既不會限制使用者，又會讓 Ceph 出事。要限制管理來源，必須改 `local_network` 別名或管理 IP set。

> 2026-10-15 的決定（[Fail2Ban 強化文件第 9 節](https://kbwangtw.github.io/IT-Knowledge-Base/docs/pve/pve-cluster-fail2ban-hardening/)）是「PVE Firewall 長期可選，設錯可能擋到 Corosync／Ceph」。今天的盤點**沒有推翻**這個決定，反而找到具體的擋法：Ceph 在服務網、5 個 VM／CT 旗標已開。

## 6. 選項比較

| 選項 | 內容 | 風險 | 評估 |
| --- | --- | --- | --- |
| A. 維持現狀 | 8006 對服務網全開，靠 TOTP、Fail2Ban、SSH 金鑰 `from=` 限制 | 低 | 可接受；風險是 VM／CT 被入侵後有路徑打 8006 |
| **B. `pveproxy` 的 `ALLOW_FROM`** | 只對 8006 加來源限制，先在一台節點試 | **低**（只影響 8006，SSH 仍可進節點還原） | **建議**；白名單盤點完成後再做 |
| C. 完整 PVE Firewall | 節點、VM、CT、Ceph、Corosync 全部納入 | 高 | **目前不建議** |

使用者只有管理員一人，所以「來源白名單」放的就是管理員自己的電腦；**電腦被入侵時，白名單擋不住**。B 真正防的是「VM、LXC 或其他有線設備被入侵後去打 8006」。

### 6-1 B 的設定草稿（尚未套用）

```text
# /etc/default/pveproxy
ALLOW_FROM="127.0.0.1,<三台節點的管理網與叢集網 IP>,<ProxCenter>,<Grafana>,<JT-IPAM>,<WireGuard CT109>,<管理員電腦>"
DENY_FROM="all"
POLICY="deny"
```

依官方文件（[pveproxy 手冊](https://pve.proxmox.com/pve-docs/pveproxy.8.html)）：

| 片段 | 意思 |
| --- | --- |
| `ALLOW_FROM` | 允許連 8006 的來源，可用逗號、範圍與 CIDR |
| `DENY_FROM="all"` | `all` 等於 `0/0` 與 `::/0` |
| `POLICY` | 沒有符合任何規則時的預設；文件寫預設是 `allow` |

注意事項：

- 文件**沒寫**怎麼套用 ACL；**推測**要重啟 `pveproxy`（文件的 `LISTEN_IP` 段落是這樣寫），且重啟可能中斷長時間的 worker，要挑沒有進行中任務的時段。
- 文件說叢集上**不建議用 `LISTEN_IP`**，這個方案不用它。
- 白名單要包含所有合法的 8006 使用者；漏掉節點自己（兩個網段的 IP 都放，叢集內部操作可能互相呼叫 API，**未驗證**）會讓切換節點、遷移失敗。
- 用 WireGuard 連回來時，PVE 看到的來源是 **CT109 的 `eth0` IP**（KB 寫過 CT109 用 `MASQUERADE -o eth0`），不是手機或筆電的 IP；漏放它，遠端就連不上 8006。
- 管理員電腦是 DHCP 動態位址，要先在數據機做 DHCP 保留（或電腦手動設固定 IP，且不在 DHCP 範圍內），否則 IP 一換就被擋在 8006 外。
- 只擋 8006；SSH（22）、spiceproxy（3128）、Ceph MON 不受影響。

## 7. 常見問題

| 現象 | 怎麼辦 |
| --- | --- |
| 想在叢集上建防火牆 VM 防橫向感染 | 先看第 3 節：同網段流量不經過它；先做主機層限制 |
| 啟用 PVE Firewall 後 Ceph 或 VM 出問題 | 第 5 節兩個地雷：Ceph 不在自動放行清單、VM／CT 網卡旗標已開；啟用前先建立規則，且要有實體主控台 |
| 盤點 SSH 來源，輸出只有 `108 for from` | `awk` 欄位取錯。用 `grep -oE 'Accepted [a-z-]+ for [^ ]+ from [0-9.]+' \| awk '{print $4, $6}'`，第 4 欄是帳號、第 6 欄是來源 IP |
| `access.log` 只看到一台節點的來源 | 每台節點各自記錄，三台都要看，監控系統可能只連其中一台 |
| 白名單的某個 IP 不認得 | **不要放進去**，先查清楚是誰（JT-IPAM、DHCP 租約表） |
| 用 VPN 連回來後 8006 打不開 | 白名單少了 CT109 的 `eth0` IP |

## 8. 待辦

- [ ] 確認 192.0.2.54 是誰（是不是管理員電腦的舊 DHCP 位址）
- [ ] 在數據機為管理員電腦做 DHCP 保留（或電腦手動固定 IP）
- [ ] 三台節點各自的 `access.log` 來源排行、SSH 來源（修正版指令）、`/etc/default/pveproxy` 現況
- [x] node10 的 `grep -E 'auth_(cluster|service|client)_required' /etc/pve/ceph.conf`：確認 Ceph 是否強制 `cephx`（2026-11-01 確認 `auth_client_required`、`auth_cluster_required`、`auth_service_required` 三項都是 `cephx`，所以 Ceph MON 在服務網連得到，並不等於不用認證就能存取）
- [ ] 決定是否採用選項 B；採用時先在一台節點測試「允許的來源連得到、不在名單的來源被拒絕」，並備妥還原方式（⏳ 2026-10-31 暫停）
- [x] 數據機刪除 8006、3000 轉送規則後，從外部再測一次（2026-11-01 完成，見 4-3）
- [ ] 評估 Corosync 增加第二條 link（可用性，不是資安；目前單一 link 在 SX1008）
- [ ] 對照官方規格表，確認 TL-SX1008、TL-SG108-M2 確實沒有網管功能

## 9. 延伸閱讀

- [Proxmox VE Firewall](https://pve.proxmox.com/pve-docs/chapter-pve-firewall.html)
- [pveproxy 手冊（Host-based Access Control）](https://pve.proxmox.com/pve-docs/pveproxy.8.html)
- [Ceph 網路設定參考](https://docs.ceph.com/en/latest/rados/configuration/network-config-ref/)
- [不再把 PVE 8006 開到網際網路：改用 WireGuard 連回家](https://kbwangtw.github.io/IT-Knowledge-Base/docs/pve/wireguard-remote-access-replace-8006/)
- [PVE 一直被嘗試登入：怎麼確認 Fail2Ban 真的有擋？](https://kbwangtw.github.io/IT-Knowledge-Base/docs/pve/pve-cluster-fail2ban-hardening/)
