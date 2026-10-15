---
layout: default
title: "PVE 一直被嘗試登入：怎麼確認 Fail2Ban 真的有擋？"
permalink: /docs/pve/pve-cluster-fail2ban-hardening/
date: 2026-09-14
categories: [PVE, Security, Fail2Ban, Network]
last_modified_at: 2026-10-15
---

# PVE 一直被嘗試登入：怎麼確認 Fail2Ban 真的有擋？

本次先確認登入失敗有被記錄，再確認 Fail2Ban 把來源加入封鎖，最後查看封包是否真的命中規則。node10 的證據顯示，重複來源的封鎖時間由 1 小時增加到 2 小時，iptables 規則也有封包計數。

**服務顯示 running，只代表程式在執行；要知道有沒有擋到，還得看規則與封包。**

> 紀錄日期：2026-09-14；PVE 9.2.18。三台已配置，但完整封鎖與封包證據來自 node10，不能擴大成三台都有同樣驗證結果。

## Fail2Ban 在做什麼？

它讀登入失敗日誌，符合門檻時把來源加入防火牆規則。本案 proxmox jail 讀 pvedaemon 的 systemd 日誌；SSH 由另一個 sshd jail 處理。

這裡的 jail 可以理解成「一組判斷與封鎖規則」，不是 VM 或容器。

## 1. 先確認現在真正生效的設定

~~~bash
systemctl status fail2ban --no-pager
fail2ban-client status
fail2ban-client status proxmox
fail2ban-client status sshd
fail2ban-client get proxmox maxretry
fail2ban-client get proxmox findtime
fail2ban-client get proxmox bantime
fail2ban-client get proxmox ignoreip
fail2ban-client get proxmox actions
~~~

再查設定來源：

~~~bash
grep -Rni 'proxmox' /etc/fail2ban
ls -lah /etc/fail2ban/jail.d/
fail2ban-client -d | grep -i -A20 -B5 proxmox
~~~

只看某個檔案不夠，因為其他設定可能覆蓋它。要把檔案內容和正在執行的值對起來。

## 2. 只調整 proxmox 這組規則

本次在 /etc/fail2ban/jail.d/proxmox.local 加入：

~~~ini
[proxmox]
maxretry = 3
findtime = 2d
bantime = 1h
bantime.increment = true
bantime.factor = 1
bantime.maxtime = 7d
~~~

白話是：以 48 小時為觀察範圍，基礎門檻為 3 次失敗、基礎封鎖 1 小時；有重複封鎖紀錄時延長，設定上限為 7 天。

這份片段依賴原本已存在的 jail、filter 與 action，不是全新主機的完整安裝設定。放在 [proxmox] 而非 [DEFAULT]，可避免無意間改到 SSH 等其他 jail。

## 3. 語法通過，再套用與核對

~~~bash
fail2ban-client -t
fail2ban-client -d | grep -E "'proxmox'.*(maxretry|findtime|bantime)"
~~~

確認測試成功後，才於維護操作中重啟：

~~~bash
systemctl restart fail2ban
fail2ban-client status proxmox
fail2ban-client status sshd
fail2ban-client get proxmox maxretry
fail2ban-client get proxmox findtime
fail2ban-client get proxmox bantime
~~~

本次執行值為 maxretry 3、findtime 172800 秒、bantime 3600 秒。最後一項仍顯示基礎 1 小時，不代表某個來源沒有被加長封鎖。

## 4. 用實際紀錄確認「1 小時變 2 小時」

本次來源 77.90.185.226 的紀錄出現：

~~~text
Ban 77.90.185.226
incr 1h to 2h
Increase Ban 77.90.185.226 (2 # 2h -> 2026-09-14 12:14:30)
~~~

事件約在 10:14:31 發生，延長到 12:14:30。這證明本次 1h → 2h 有作用，沒有實測到全部遞增階段或 7 天上限。

可查看指定來源的時間紀錄：

~~~bash
grep -F '77.90.185.226' /var/log/fail2ban.log | tail -20
fail2ban-client get proxmox banip --with-time
~~~

這個 IP 是案例中的觀察來源，不代表已識別背後的人或組織。

## 5. 最後一關：封包有沒有真的進入規則？

~~~bash
iptables -L f2b-proxmox -n -v --line-numbers
iptables -S INPUT | grep -F f2b-proxmox
iptables -S f2b-proxmox
~~~

本次 INPUT 的 TCP 80、443、8006 導向 f2b-proxmox，指定來源命中 REJECT，計數為 16 個封包、916 bytes。

這組規則涵蓋的是指定埠與 INPUT 路徑，不能宣稱所有埠或轉送給 VM 的流量都被同樣封鎖。三節點的 Fail2Ban 設定與本機 SQLite 紀錄也不會因為是 PVE 叢集就自動同步。

## PVE Firewall 有 running，為什麼仍不能說已啟用？

本案同時檢查：

~~~bash
systemctl status pve-firewall --no-pager
pve-firewall status
cat /etc/pve/firewall/cluster.fw
cat /etc/pve/nodes/node10/host.fw
ss -lntp | grep ':8006'
~~~

當時 service 在執行，但 firewall 狀態為 disabled/running，cluster enable=0，host enable=1。因此不能把服務存活解讀成整套 PVE Firewall 已啟用。

8006 監聽在所有本機介面，也不能單獨證明外網直通。node10 有外部登入嘗試和封包命中證據，但上游究竟是 NAT、port forward 或 proxy，當時尚未查清；其他兩台的外部暴露範圍也未確認。

## 10/12 補記：外部登入嘗試從哪裡進來？

上游入口已查清：是路由器上的 **TCP 8006 轉送**，當初為了從外面管理 PVE 而設定。也就是說，PVE 管理介面直接對網際網路開放，Fail2Ban 只能在猜錯幾次後才封鎖，擋不了不需要密碼的漏洞攻擊。

改善方式是改用 cluster 裡的 WireGuard 容器：數據機只轉送 UDP 51820，iPhone 與筆電先連 VPN，再用內網 IP 開 PVE。10/12 完成 VPN 設定與外部連線測試；10/13 在數據機停用 8006 轉送，並在關掉 Wi-Fi 的情況下從外部確認 8006 已無法連線。10/12 曾誤記為已刪除，當天 16:19 與 20:36 仍有外部 IP 登入失敗。過程見 [不再把 PVE 8006 開到網際網路：改用 WireGuard 連回家](https://kbwangtw.github.io/IT-Knowledge-Base/docs/pve/wireguard-remote-access-replace-8006/)。

## 接下來該補哪些事？

**10/15 調整：** 管理入口已改為 WireGuard（WGDashboard 也已啟用 2FA），8006 不再對外，因此後續項目重新評估：

| 項目 | 決定 | 理由 |
| --- | --- | --- |
| 三台逐一封包驗證 | **取消** | 原本是確認外部暴力登入有被擋；外部來源已消失，node10 已驗證遞增封鎖與 iptables 命中，三台設定相同 |
| Fail2Ban 本身 | **保留運作** | 對內網的誤試或異常登入仍有保護 |
| PVE Firewall | **改為長期可選** | 防的是內網威脅（VM 被入侵當跳板、內網設備掃描）；設錯可能鎖住管理連線或擋到 Corosync／Ceph，目前效益不足以抵過風險。內網人員或設備增加、或有稽核需求時再評估 |
| PVE `root@pam` 啟用 TOTP | **10/15 已完成**（見下節） | VPN 為 split tunnel，VPN 用戶端可直達 8006；用戶端被入侵時，PVE 登入多一道驗證。啟用前確認沒有服務以 `root@pam` 帳密（而非 API token）登入 |

若日後要啟用 PVE Firewall，需先保留主控台與管理連線，盤點 Corosync、Ceph、備份和管理所需流量，再逐台測試。

ignoreip 只放必要且確認可信的管理來源。遇到誤封，先核對來源與日誌，再解除那一筆；不要為了讓管理方便，把整個大網段放行。

## 10/15 補記：`root@pam` 啟用 TOTP 與 token 清理

VPN 為 split tunnel，VPN 用戶端可以直達 8006；用戶端被入侵時，PVE 登入多一道驗證。

### 啟用後影響範圍

| 登入方式 | 啟用 TOTP 後 |
| --- | --- |
| Web UI 以 `root@pam` 登入 | 要輸入驗證碼 |
| 程式以 `root@pam` **帳號密碼**取得 ticket | **會失敗**（唯一需要先排查的風險） |
| API token（ProxCenter、jt-ipam 等） | 不受影響 |
| SSH、節點本機 `qm`／`pct`／`pvesh` | 不受影響 |

### 事前排查：有沒有程式用 `root@pam` 密碼登入（唯讀）

~~~bash
pveum user tfa list
pveum user token list root@pam
for n in node10 node11 node12; do
  echo "== $n"
  ssh root@$n 'zcat -f /var/log/pveproxy/access.log* 2>/dev/null | grep "POST /api2/json/access/ticket" | awk "{print \$1}" | sort | uniq -c | sort -rn | head -10'
done
~~~

本次結果：

- 帳密登入的內網來源只有三個：ct:109（VPN 用戶端經 NAT）、WinClient、家中裝置（1 次），都是人工操作。外部 IP 皆為 10/13 停用 8006 轉送前的紀錄。
- 最近 30 分鐘的 API 呼叫：ProxCenter、jt-ipam 都用 API token；Web UI session 來自 ct:109（VPN）。
- 結論：沒有程式以 `root@pam` 帳密登入，可以啟用。

### 清理 `root@pam` 底下的 token

兩個 token 都是 `privsep = 0`（權限與 `root@pam` 相同），而且 token 不經過 TOTP，啟用後會成為權限最大、防護最弱的入口：

| token | 用途 | 使用紀錄 | 處理 |
| --- | --- | --- | --- |
| `pdm-admin-pdm` | Proxmox Datacenter Manager 自動建立，已不再使用 | — | 刪除 |
| `hermesagent` | Hermes Agent（AI 機器人） | 三台 access.log 皆 0；實際用 Hermes 檢查三台後仍為 0 | 先停用（`--expire 1`），觀察約兩週後刪除 |

~~~bash
pveum user token remove root@pam pdm-admin-pdm
pveum user token modify root@pam hermesagent --expire 1     # 停用；要恢復改回 --expire 0
pveum user token list root@pam
~~~

用 Hermes 實際檢查時，三台的 SSH 紀錄出現來自 Hermes 主機的 root 登入（另一把 RSA 金鑰）：**Hermes 是以 SSH root 金鑰操作節點，不是用 API token**。SSH 不受 PVE TOTP 管轄，AI 機器人又可能受提示注入或誤判影響，因此另列待辦：在 `authorized_keys` 以 `from=` 限制來源，進一步改用只能執行唯讀指令的帳號。

### 新增 TOTP 與復原碼

1. Web UI **Datacenter → Permissions → Two Factor → Add → TOTP**：User `root@pam`、填描述、手機 App 掃描 QR code、輸入驗證碼。
2. 再 **Add → Recovery Keys**（User `root@pam`）：復原碼只顯示一次，**抄在紙上保存**，不存雲端。
3. 原頁面不登出，另開無痕視窗以 `root`／Linux PAM 登入，確認會要求驗證碼。

設定存在 `/etc/pve/priv/tfa.cfg`，由 cluster 同步，三台一起生效。

~~~bash
pveum user tfa list root@pam
tail -500 /var/log/pveproxy/access.log | awk '$3 ~ /token/ {print $3, $9}' | sort | uniq -c
~~~

本次結果：`totp` 與 `recovery` 各一筆；無痕視窗登入要求驗證碼並成功；ProxCenter token 啟用後 412 次呼叫全為 200。jt-ipam 呼叫頻率較低，未出現在同一段紀錄中，沒有另外確認。

### 被鎖住時

SSH 不受影響，登入任一節點移除 TOTP 即可（也可在登入畫面用復原碼）：

~~~bash
pveum user tfa list root@pam
pveum user tfa delete root@pam --id <TOTP 那一筆的 id>
~~~

## 本次結論

已確認 node10 的遞增封鎖與 iptables 命中，三台配置已處理。上游入口已於 10/12 查清（路由器轉送 8006），已改用 WireGuard，8006 轉送已於 10/13 停用並從外部確認。停用後 10/13 12:00～10/14 三台都沒有外部登入嘗試，不再另外追蹤。10/15 起取消三台逐一封包驗證，Fail2Ban 保留運作；PVE Firewall 改為長期可選，`root@pam` 已於 10/15 啟用 TOTP 與復原碼，並清理 `root@pam` 底下兩個 `privsep=0` 的 token（`pdm-admin-pdm` 刪除、`hermesagent` 停用）。待辦：約 10/29 刪除 `hermesagent`；限縮 Hermes Agent 的 SSH root 權限。

- [Fail2Ban 1.1.0 設定參考](https://github.com/fail2ban/fail2ban/blob/1.1.0/config/jail.conf)
- [Proxmox Firewall 文件](https://pve.proxmox.com/pve-docs/chapter-pve-firewall.html)
