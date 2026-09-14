---
layout: default
title: "PVE Cluster Fail2Ban 排查與強化：遞增封鎖、iptables 驗證與管理介面暴露檢查"
permalink: /docs/pve/pve-cluster-fail2ban-hardening/
date: 2026-09-14
categories: [PVE, Security, Fail2Ban, Network]
---

<div class="kb-hero">
<h1>PVE Cluster Fail2Ban 排查與強化</h1>
<p>從 root@pam 重複登入失敗追到 1h → 2h 遞增封鎖，驗證 Linux 防火牆確實拒絕封包，再檢查 PVE Firewall 與管理介面的外部可達性。</p>
<div class="kb-badges"><span class="kb-badge">PVE 9.2.18</span><span class="kb-badge">三節點 Cluster</span><span class="kb-badge">Fail2Ban</span><span class="kb-badge">Security</span></div>
</div>

> **紀錄狀態：node10、node11、node12 均已完成 Fail2Ban 設定；本文保留的完整 Log 與封包計數驗證來自 node10。PVE Firewall 僅完成安全檢查，尚未啟用 Cluster Firewall，也尚未確認上游轉送方式。** 本文依管理者提供的實機輸出整理，並非另一次遠端重測。保留案例 IOC `77.90.185.226` 與必要私網拓樸；省略 MAC、程序識別碼、無關 VM 清單及其他敏感資訊。

## 1. 問題現象與處理目標

node10 持續出現來源 `77.90.185.226` 嘗試登入 `root@pam` 的認證失敗紀錄。Fail2Ban 已能識別並封鎖，但原本固定封鎖一小時，解封後同一來源又繼續嘗試。

本次目標是確認「有偵測、有延長封鎖、有實際阻擋」，並釐清為何外部來源能到達管理介面。認證失敗代表嘗試未通過；**不能只憑這些 Log 判定已成功入侵，也不能據此證明完全沒有其他成功登入。** IOC 僅代表本次觀察來源，不作攻擊者身分歸因。

## 2. 環境與原始設定

| 項目 | 實機紀錄 |
|---|---|
| PVE | 9.2.18；node10 回報 `pve-manager/9.2.18` |
| Cluster | node10、node11、node12 |
| Fail2Ban jail | `sshd`、`proxmox` |
| proxmox backend | `systemd` |
| Journal match | `_SYSTEMD_UNIT=pvedaemon.service` |
| 原始門檻 | `maxretry=3`、`findtime=2d`、`bantime=1h` |
| proxmox action | `iptables-multiport` |
| action ports | TCP 80、443、8006 |
| 本次變更 | 僅在 `[proxmox]` 覆寫封鎖參數；sshd 維持既有設定 |

`findtime=2d` 是 48 小時的失敗事件統計視窗，並不是封鎖兩天；`bantime=1h` 才是基礎封鎖時間。`sshd` 保護 SSH，`proxmox` 處理 PVE 認證失敗，兩者不能混為一談。

## 3. 先確認 runtime，再追設定來源

以下指令在 PVE 節點以具管理權限的 shell 執行。先讀取現況：

```bash
pveversion
systemctl status fail2ban --no-pager
fail2ban-client status
fail2ban-client status sshd
fail2ban-client status proxmox
fail2ban-client get proxmox maxretry
fail2ban-client get proxmox findtime
fail2ban-client get proxmox bantime
fail2ban-client get proxmox ignoreip
fail2ban-client get proxmox actions
```

node10 的三個時間／門檻查詢依序為 `3`、`172800`、`3600`，action 為 `iptables-multiport`。當時 `ignoreip` 回報 `No IP address/network is ignored`，表示沒有明列的忽略來源；這不等同於所有自身位址相關的預設保護都關閉。

找出實際定義位置與合併結果：

```bash
grep -Rni 'proxmox' /etc/fail2ban
ls -lah /etc/fail2ban/jail.d/
fail2ban-client -d | grep -i -A20 -B5 proxmox
journalctl -u pvedaemon --since '2 days ago' --no-pager | grep -F '77.90.185.226'
grep -F '77.90.185.226' /var/log/fail2ban.log | tail -30
```

本次發現 `[proxmox]` 原本定義於 `/etc/fail2ban/jail.conf`。不能只搜尋 `jail.local` 的 `bantime` 就認定那是 proxmox 生效值；其他 section 或 DEFAULT 可能不同。既有 filter 已能抓到認證失敗，本次未更動 filter。

## 4. 建立 jail 專用覆寫檔

本次新增 `/etc/fail2ban/jail.d/proxmox.local`。日後重做前，先備份既有檔案；若檔案已存在，應合併所需參數，避免蓋掉其他自訂內容。

```bash
nano /etc/fail2ban/jail.d/proxmox.local
```

內容如下：

```ini
[proxmox]
# 48 小時內的基礎失敗門檻
maxretry = 3
findtime = 2d

# 基礎封鎖時間
bantime = 1h

# 依歷史封鎖紀錄延長，最高 7 天
bantime.increment = true
bantime.factor = 1
bantime.maxtime = 7d
```

這是**既有、已啟用 proxmox jail 的覆寫檔**，不是可單獨完成全新安裝的設定。`enabled`、`filter`、`backend`、`port`、`action` 沿用本次已驗證的定義；全新主機必須先建立並驗證這些項目。不要把這次參數放入 `[DEFAULT]`，否則可能連 sshd 都一起改變。

Fail2Ban 官方建議將自訂設定放在 `.local`；遞增封鎖會參考資料庫歷史，預設公式搭配 factor=1 呈倍增趨勢，maxtime 限制上限。已有歷史時，下次封鎖不一定從 1h 起算。參考 [Fail2Ban 1.1.0 官方 jail.conf](https://github.com/fail2ban/fail2ban/blob/1.1.0/config/jail.conf)。

## 5. Configuration test 與 runtime 驗證

先檢查，不要在設定測試失敗時重啟：

```bash
fail2ban-client -t
fail2ban-client -d | grep -E "'proxmox'.*(maxretry|findtime|bantime)"
```

node10 實際輸出：

```text
OK: configuration test is successful
['set', 'proxmox', 'maxretry', 3]
['set', 'proxmox', 'findtime', '2d']
['set', 'proxmox', 'bantime', '1h']
['set', 'proxmox', 'bantime.increment', True]
['set', 'proxmox', 'bantime.factor', '1']
['set', 'proxmox', 'bantime.maxtime', '7d']
```

測試成功後，本次執行：

```bash
systemctl restart fail2ban
systemctl status fail2ban --no-pager
fail2ban-client status sshd
fail2ban-client status proxmox
fail2ban-client get proxmox maxretry
fail2ban-client get proxmox findtime
fail2ban-client get proxmox bantime
```

服務回報 `active (running)`、`Server ready`，基礎 runtime 值仍為 `3 / 172800 / 3600`。`bantime` 查到 3600 並不代表遞增失效，這個值是基礎值，個別 IP 的實際封鎖時間要看後續事件。

Log 也確認載入 `Set banTime.increment = True`、`Set banTime.factor = 1`、`Set banTime.maxtime = 7d`，且 `sshd` 與 `proxmox` jail 均 started。

重啟可能造成 action 規則短暫重建，應保留管理連線及主控台復原能力。本次重啟後尚未再次 Ban 時，一度看到 `No chain/target/match by that name`。這與 action 尚未建立 chain 的狀態一致；**不能只憑這一行判定失效，也不能在已有 Ban 後仍找不到規則時忽略錯誤。**

## 6. 實際 Log：從 1h 延長到 2h

以下為 2026-09-14 實際事件摘錄，僅省略 logger 名稱與 PID，時間沿用節點 Log：

```text
10:14:30,920 INFO   [proxmox] Found 77.90.185.226 - 2026-09-14 10:14:30
10:14:31,029 NOTICE [proxmox] Ban 77.90.185.226
10:14:31,030 INFO   [proxmox] IP 77.90.185.226 is bad: 1 # last 2026-09-14 06:08:57 - incr 1h to 2h
10:14:31,030 NOTICE [proxmox] Increase Ban 77.90.185.226 (2 # 2h -> 2026-09-14 12:14:30)
```

| 訊息 | 能證明的事 |
|---|---|
| Found | filter 識別到該來源的失敗事件 |
| Ban | jail 觸發封鎖處理；仍須核對防火牆 |
| incr 1h to 2h | observer 依歷史紀錄計算出兩小時 |
| Increase Ban | 本次期限被延長至 Log 所列 12:14:30 |

這是「遞增已實際觸發」的證據，不只是設定檔存在。不能把 observer 的 `1 # -> 2.0` 當成兩次新的原始登入事件；也不能由短短幾行 Log 重建整個 findtime 視窗。實際遞增還受歷史保留、公式與其他選項影響，本次只實測到 2h，未實測每一級直到 7d。

持續核對時可使用：

```bash
grep -F '77.90.185.226' /var/log/fail2ban.log | tail -20
fail2ban-client status proxmox
fail2ban-client get proxmox banip --with-time
```

最後一個查詢若安裝版本不支援，改以 Log 與 status 核對；本文沒有將其列為已取得的實測輸出。重啟後 `Total banned` 統計也不是資料庫內該 IP 的完整歷史次數。

## 7. iptables 證據：規則存在，而且封包命中

```bash
iptables -L f2b-proxmox -n -v --line-numbers
iptables -S INPUT | grep -F f2b-proxmox
iptables -S f2b-proxmox
fail2ban-client status proxmox
```

本次規則摘錄：

```text
-A INPUT -p tcp -m multiport --dports 443,80,8006 -j f2b-proxmox
-N f2b-proxmox
-A f2b-proxmox -s 77.90.185.226/32 -j REJECT --reject-with icmp-port-unreachable
-A f2b-proxmox -j RETURN
```

REJECT 那一列已有 **16 packets / 916 bytes**，且 jail 回報：

```text
Currently failed: 0
Total failed:     3
Currently banned: 1
Total banned:     1
Banned IP list:   77.90.185.226
```

INPUT 跳轉、來源 REJECT、非零命中計數與 jail 狀態互相吻合，證明有符合條件的封包被拒絕。雖然子鏈列印 `REJECT all`，從 INPUT 進入的條件已限定 TCP 80／443／8006，因此這組規則**不等於封鎖該 IP 的所有協定與連接埠**，也不代表 VM 的 FORWARD 流量一併受保護。計數是這條規則的合計，不能據此拆出各 port 的命中數。

## 8. 三節點完成範圍與維護方式

| 節點 | 完成情況 | 本文證據範圍 |
|---|---|---|
| node10 | 已完成設定 | configuration test、解析結果、runtime、Increase Ban、iptables 命中 |
| node11 | 已完成設定 | 管理者確認；未附同等逐項 Log |
| node12 | 已完成設定 | 管理者確認；未附同等逐項 Log |

`/etc/fail2ban/` 不是 PVE 的 `/etc/pve` 叢集檔案系統，不會因 node10 修改就自動同步。各節點的 Fail2Ban 設定及 `/var/lib/fail2ban/fail2ban.sqlite3` 歷史各自維護；node10 Ban 某 IP 不表示其他兩台同步 Ban。

後續每台都應保留第 5 節的測試與 runtime 輸出，並檢查 sshd 仍正常啟用。可查 `fail2ban-client get dbpurgeage` 評估歷史保留是否符合重複攻擊觀察需求；本次沒有修改資料庫或宣稱跨節點同步封鎖。

## 9. PVE Firewall 安全檢查

Fail2Ban 有效後，接著檢查管理介面暴露路徑。本次在 node10 執行：

```bash
ip -br addr
ip route
ss -lntp | grep ':8006'
systemctl status pve-firewall --no-pager
pve-firewall status
cat /etc/pve/firewall/cluster.fw
cat /etc/pve/nodes/node10/host.fw
iptables -L INPUT -n -v --line-numbers
iptables -t nat -L -n -v --line-numbers
```

| 檢查 | node10 結果 | 解讀 |
|---|---|---|
| vmbr0 | `192.168.10.10/24` | 管理網路私有位址 |
| Cluster | `172.16.10.10/24` | 叢集網路介面 |
| default gateway | `192.168.10.1`，via vmbr0 | 預設下一跳；未確認設備身分 |
| pveproxy | `*:8006` | wildcard 監聽；不是只綁單一管理 IPv4 |
| pve-firewall service | `active (running)` | 服務程序運作中 |
| pve-firewall status | `disabled/running` | 防火牆功能未啟用，程序仍在跑 |
| cluster.fw | `[OPTIONS] enable: 0` | Datacenter／Cluster 層級停用 |
| node10 host.fw | `[OPTIONS] enable: 1` | 節點開關存在，但不能取代 Cluster 層級啟用 |
| INPUT | policy `ACCEPT`，有 f2b-proxmox 跳轉 | 本次輸出未見 PVE 管理來源限制 |
| 本機 NAT table | 所列 chains 無規則 | 此次 iptables NAT 檢查未見本機轉送規則 |

**systemd 的 running 與防火牆 enabled 是兩件事。** 單獨看服務綠燈不能證明 PVE 防火牆正在限制管理入口。Cluster 與 Host 設定路徑及啟用行為可參考 [Proxmox 官方 Firewall 文件原始碼](https://github.com/proxmox/pve-docs/blob/master/pve-firewall.adoc)。

`*:8006` 本身不能證明 Internet 可達，也不足以單獨判定 IPv4／IPv6 全部監聽情況；本案需結合外部來源認證事件與規則證據。必要時分別用 `ss -4 -lntp`、`ss -6 -lntp` 檢查。

## 10. 架構與目前可以下的結論

```text
外部來源 77.90.185.226
          |
          v
上游到管理服務的路徑（待查：NAT / Port Forward / Proxy 等）
          |
          v
node10 管理服務 :8006
  vmbr0   192.168.10.10/24 ── 預設 gateway 192.168.10.1
  Cluster 172.16.10.10/24 ── 叢集網路（node11 / node12）
          |
          +─ INPUT → f2b-proxmox → 已 Ban 來源 REJECT
          +─ pveproxy → pvedaemon 認證事件 → Fail2Ban

PVE Firewall：Cluster enable=0；service running
```

這是邏輯示意，並非已捕捉封包重建的實際路徑。目前可以確認外部 IP 能到達 node10:8006 的管理服務，但**不能斷言經由哪一台設備、哪一種 NAT、Port Forward 或 Proxy**。node10 本機 NAT table 沒有規則，不排除上游設備做 NAT，也不排除代理、隧道或其他路由安排；還不能推定只有 node10 暴露。

若流量經過反向代理，應比較應用 Log 的來源與主機實際收到的封包來源；Log 裡的外部 IP 不必然等於每條後端 TCP 連線的來源 IP。本次 REJECT 有命中，證明部分符合規則的封包確實遭阻擋，但尚未建立完整上游架構證據。

## 11. 風險與後續建議（尚未執行）

### 11.1 優先查清入口與縮小管理來源

先盤點 `192.168.10.1` 的設備身分及上游防火牆規則、WAN port mapping、反向代理與隧道服務，再以外部測試與兩端 Log 對照。node10 可先唯讀檢查：

```bash
ip neigh show 192.168.10.1
cat /etc/network/interfaces
timeout 60 tcpdump -ni vmbr0 -c 50 'host 77.90.185.226 and tcp port 8006'
```

有看到 `77.90.185.226.<來源port> > 192.168.10.10.8006` 才能針對該次封包確認 vmbr0 入口；60 秒內沒有封包不能反證沒有暴露。來源可能正在封鎖、暫停攻擊或被代理改寫。鄰居表只協助辨識下一跳，不等於 NAT 設定證據。

確認依賴後，將管理入口限制為核准的管理來源或 VPN／跳板機，關閉不必要的外部映射。Fail2Ban 是事件觸發後的補強，不能代替入口存取控制；換 IP 或低頻嘗試仍可能避開既有門檻。

### 11.2 規劃 PVE Firewall 啟用與復原

不要直接把 `cluster.fw` 的 `enable: 0` 改成 1 就結案。這個設定影響叢集，應先盤點管理來源、Corosync、Migration、儲存、備份及其他必要流量，核對實際網段與規則；不要假設介面名稱叫 Cluster 就必然涵蓋所有叢集服務。

維護前先備份設定、備妥主控台或帶外管理與回復步驟，檢查 quorum 及現有連線。啟用後逐節點驗證 Web／SSH、新管理連線、叢集與工作負載健康，再從未授權來源驗證拒絕結果。PVE 官方也提醒啟用會改變主機入站行為，需預先允許所需服務；見 [Firewall 啟用說明](https://github.com/proxmox/pve-docs/blob/master/pve-firewall.adoc#enabling-the-firewall)。

### 11.3 持續維護與誤封處理

48 小時內三次失敗的門檻也可能誤封管理者，應先確認管理來源與復原管道，再評估最小範圍 `ignoreip`；不要直接忽略整個不可信網段。確認誤封後，可在仍可用的主控台使用 `fail2ban-client set proxmox unbanip <已確認的管理來源IP>`，不要為了測試而解除案例攻擊來源封鎖。

後續應檢查成功登入、權限變更與異常工作紀錄，評估具名管理帳號、最小權限與多因素驗證。若改用其他防火牆後端或存在 IPv6 對外路徑，需重新確認 Fail2Ban action 與實際生效規則，不能直接沿用本文 IPv4 iptables 結論。

回復本次 Fail2Ban 變更時，還原備份的 `proxmox.local`；若原本不存在，僅撤回本次新增覆寫檔，先做 configuration test 再重載或重啟，確認兩個 jail 與規則恢復。這只會回到原封鎖策略，並不解決管理入口暴露。

## 12. 結案紀錄

本次已完成三節點 proxmox jail 遞增封鎖設定；node10 具備設定測試成功、runtime 正確、1h → 2h Increase Ban，以及 REJECT 命中封包的完整證據。仍待處理的是上游入口定位與 PVE Firewall 啟用規劃，不能將「Fail2Ban 有效」寫成「整個管理網路已完成安全強化」。
