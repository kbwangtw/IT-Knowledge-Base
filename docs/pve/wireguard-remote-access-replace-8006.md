---
layout: default
title: "不再把 PVE 8006 開到網際網路：改用 WireGuard 連回家"
permalink: /docs/pve/wireguard-remote-access-replace-8006/
date: 2026-10-12
categories: [PVE, WireGuard, VPN, Security, Network]
last_modified_at: 2026-10-12
---

# 不再把 PVE 8006 開到網際網路：改用 WireGuard 連回家

Fail2Ban 一直擋到外部 IP 嘗試登入 PVE，追查後發現原因很單純：為了在外面也能管理，路由器把 TCP 8006 直接轉送到 PVE。本次改用 cluster 裡現有的 WireGuard 容器（ct:109），讓 iPhone 和筆電先連 VPN，再用內網 IP 開 PVE。

**Fail2Ban 只能在攻擊者猜錯幾次後封鎖；PVE 管理介面本身就不應該對網際網路開放。**

> 紀錄日期：2026-10-12；PVE 9.2.21，ct:109 為 Debian 13 + WireGuard + WGDashboard。iPhone 與筆電都已從外部連上 VPN，iPhone 經 4G/5G 透過 VPN 打開 PVE。之後刪除路由器的 8006 轉送，並從外部確認 8006 已無法連線、VPN 仍可用。文中內網位址為示範值（198.51.100.0/24），不是實際環境位址；不公開對外 IP 與任何金鑰。

## 為什麼要改？

| 做法 | 對外開放的入口 | 風險 |
| --- | --- | --- |
| 轉送 TCP 8006 到 PVE（原本） | PVE Web 管理介面 | 全世界的掃描器都碰得到；PVE 或它的 Web 服務若有漏洞，可能不需要密碼就被利用；拿到權限等於控制所有 VM、Ceph 與備份 |
| 轉送 UDP 51820 到 WireGuard（本次） | WireGuard | 沒有正確金鑰的封包會直接被丟棄、不回應，掃描器幾乎看不出這個 port 有開；沒有密碼可以猜 |

家用的中華電信光世代數據機沒有 VPN 伺服器功能，所以 VPN 架在 PVE 上的 LXC。對外 IP 是申請的固定 IP，因此不需要 DDNS。

## 架構

~~~text
iPhone／筆電（外部網路）
   │  WireGuard（UDP 51820）
   ▼
數據機：只轉送 UDP 51820 → ct:109
   ▼
ct:109 wireguard（eth0 198.51.100.27，wg0 10.0.0.1/24）
   │  NAT（MASQUERADE）
   ▼
node10／node11／node12:8006 與其他內網服務
~~~

ct:109 做 NAT，PVE 看到的連線來源是 ct:109 的內網 IP，回應封包自然送回 ct:109，**數據機不需要設定靜態路由**。

ct:109 受 PVE HA 管理。一台 node 故障時，HA 會把它搬到其他 node；只有三台 node 同時停機，或數據機、對外線路中斷時，VPN 才會完全連不上。

## 1. 找回已安裝的 WireGuard

WireGuard 是之前就裝好的，但已經忘了怎麼操作。在 node10 用 `pct exec 109 --` 直接在容器裡執行指令，以下都只讀取：

~~~bash
pct exec 109 -- bash -c 'ls -l /etc/wireguard/; which docker && docker ps'
pct exec 109 -- bash -c 'systemctl status "wg-quick@*" --no-pager | head -15; systemctl is-enabled wg-quick@wg0'
pct exec 109 -- wg show
pct exec 109 -- bash -c 'ip -br addr; sysctl net.ipv4.ip_forward'
pct exec 109 -- bash -c 'systemctl list-units --type=service --all | grep -i -E "wg|dashboard"; ss -lntp | grep 10086'
pct exec 109 -- sed -E 's/^(PrivateKey|PresharedKey)\s*=.*/\1 = ***遮蔽***/' /etc/wireguard/wg0.conf
pct exec 109 -- bash -c 'iptables -t nat -S'
~~~

最後兩行會遮蔽設定檔裡的私鑰。不要直接 `cat wg0.conf` 截圖或貼到任何地方。

本次結果：

| 項目 | 結果 | 代表的意思 |
| --- | --- | --- |
| `/etc/wireguard/` | `wg0.conf` 與 `WGDashboard_Backup/` | 當初用 WGDashboard 安裝；沒有 Docker，不是 wg-easy |
| `wg-quick@wg0` | disabled | 開機時不是 wg-quick 帶起 wg0 |
| `wg-dashboard.service` | active，gunicorn 監聽 `0.0.0.0:10086` | WGDashboard 開機時把 wg0 帶起來 |
| wg0 | `Address = 10.0.0.1/24`，`ListenPort = 51820` | VPN 用戶拿 10.0.0.x |
| 轉送與 NAT | `PostUp` 有 FORWARD ACCEPT 與 `MASQUERADE -o eth0`；`ip_forward = 1` | VPN 用戶可以連到內網 |
| `SaveConfig` | `true` | wg0 停止時會把執行中的狀態寫回 `wg0.conf`；之後一律從 WGDashboard 操作，不要在 wg0 運作中手動改檔 |

WGDashboard 的 10086 監聽所有網卡，所以容器的內網和 VPN 用戶都能開管理頁面。**10086 絕對不能在數據機上轉送**，否則等於把 VPN 管理介面開到網際網路。

## 2. WGDashboard 的帳號密碼

WGDashboard 的帳號密碼存在安裝目錄的 `wg-dashboard.ini`（本案為 `/etc/wgdashboard/src/`）的 `[Account]` 區段，密碼以雜湊儲存，看不到原文。查看格式時只顯示開頭：

~~~bash
INI=/etc/wgdashboard/src/wg-dashboard.ini
grep -A6 '^\[Account\]' "$INI" | sed -E 's/^(password\s*=\s*.{4}).*/\1...（已截斷）/'
~~~

本案為 `$2b$` 開頭的 bcrypt。最後找到了原本的密碼，沒有重設；若要重設，做法是停止 `wg-dashboard`、備份 ini、用 WGDashboard 自己的 Python 環境以 bcrypt 產生新雜湊替換 `password` 那一行，再啟動服務。

同一段輸出會顯示 `totp_key`。本案雙因素驗證沒有啟用；若之後要啟用，應先換一把新的 key，不要沿用曾經顯示在畫面上的那一把。

## 3. 調整 Peer 預設值：改成 split tunnel

WGDashboard 的 **Settings → Peers Settings** 是新增 peer 時的預設值：

| 欄位 | 原本 | 調整後 |
| --- | --- | --- |
| DNS | 內網 DNS | 不變（新增 peer 時填兩台 DNS） |
| Endpoint Allowed IPs | `0.0.0.0/0` | `10.0.0.0/24, 198.51.100.0/24` |
| MTU／Persistent Keepalive | 1420／21 | 不變 |
| Peer Remote Endpoint | 固定的對外 IP | 不變（固定 IP，不需要 DDNS） |

`0.0.0.0/0` 會讓手機與筆電**所有流量**都繞回家，看影片、上網都會變慢，也吃家裡的上傳頻寬。改成只有 VPN 網段與家中內網走 VPN（split tunnel），一般上網照常。DNS 伺服器在內網網段裡，所以 DNS 查詢仍經過 VPN，內網名稱照樣能解析。

畫面上的警告寫著這個設定會套用到所有 peer 的 QR code 與設定檔。改完後，已匯入舊設定的客戶端需要重新匯入。

## 4. 清掉舊的 peer

`wg show` 原本有一個 `10.0.0.3/32` 的 peer，但 WGDashboard 的 wg0 頁面是空的，而且這個 peer 沒有 `latest handshake`，從 wg0 這次啟動以來沒有連線過。它對應很久以前建立的 client01。刪除 client01 後，確認執行中的狀態與設定檔都已經沒有 peer：

~~~bash
pct exec 109 -- wg show wg0 | grep -E "peer|allowed ips|latest handshake"
pct exec 109 -- grep -E "^\[Peer\]|^AllowedIPs" /etc/wireguard/wg0.conf
~~~

兩個指令都沒有輸出，代表兩邊一致，從乾淨的狀態重新建立。

## 5. 建立 peer：伺服器端 Allowed IPs 只能放 /32

在 wg0 頁面按 **⊕ Peer**。本次建立 iPhone12（10.0.0.2）與筆電（10.0.0.3），兩個都啟用 Pre-Shared Key。

**這一步差點出錯。** 新增視窗的 Allowed IPs 自動帶入了兩個值：

~~~text
Allowed IPs:  10.0.0.2/32   198.51.100.0/24
~~~

要把內網網段刪掉，只留 `/32`。WGDashboard 有兩個名稱很像、用途相反的欄位：

| 欄位 | 寫在哪一端 | 意思 | 正確的值 |
| --- | --- | --- | --- |
| Allowed IPs | 伺服器端 | 目的地是哪些 IP 的封包，要交給這台設備 | 這台設備自己的 VPN IP，例如 `10.0.0.2/32` |
| Endpoint Allowed IPs（在 Advanced Options） | 客戶端 | 設備上哪些流量要走 VPN | `10.0.0.0/24, 198.51.100.0/24` |

如果伺服器端留著內網網段，WireGuard 會在 ct:109 加一條「內網 → wg0」的路由：ct:109 自己連不到內網，NAT 也跟著失效；這台設備沒連線時，送往內網的封包就直接消失。

建立後馬上確認：

~~~bash
pct exec 109 -- wg show wg0 | grep -E "peer|allowed ips|preshared"
pct exec 109 -- ip route | grep wg0
~~~

本次結果：兩個 peer 的 `allowed ips` 分別只有 `10.0.0.2/32`、`10.0.0.3/32`，`preshared key: (hidden)`；路由只有 `10.0.0.0/24 dev wg0`。**如果出現「內網網段 dev wg0」的路由，代表設定錯了。**

## 6. 匯入客戶端

| 設備 | 做法 |
| --- | --- |
| iPhone | App Store 安裝官方 WireGuard（開發者 WireGuard Development Team），**+ → 使用 QR 碼建立**，掃描 WGDashboard 上 peer 的 QR code |
| 筆電 | 從 [wireguard.com/install](https://www.wireguard.com/install/) 安裝，在 WGDashboard 下載 peer 的 `.conf`，**匯入通道**後立刻刪除下載的檔案並清空資源回收筒 |

QR code 與 `.conf` 都含有客戶端的私鑰，不要截圖或傳給別人。

匯入後確認：位址是各自的 `/32`、DNS 兩台、節點公鑰與 WGDashboard 上 wg0 的 Public Key 一致、預交換金鑰已啟用、允許的位址是 split tunnel 的兩個網段、連接點是對外 IP:51820。

iOS App 的繁體中文介面把 Persistent keepalive 顯示成 `tunnelPeer...` 開頭的文字。按「編輯」可以看到實際值是 21，這是 App 翻譯缺漏，不是設定錯誤。查看編輯畫面時要按「取消」離開；編輯畫面會顯示預交換金鑰的內容，截圖時要遮掉。

## 7. 從外部測試

數據機新增 **UDP** 51820 轉送到 ct:109 後，iPhone **關掉 Wi-Fi、改用 4G/5G**，打開 WireGuard 通道。在家裡 Wi-Fi 測試不算數：很多家用數據機不支援從內網連自己的對外 IP（hairpin NAT），失敗也不代表設定錯。

~~~bash
pct exec 109 -- wg show wg0 | grep -A5 "<iPhone peer 公鑰開頭>"
~~~

本次結果：

~~~text
endpoint: <電信業者 IP>:<port>
allowed ips: 10.0.0.2/32
latest handshake: 18 seconds ago
transfer: 244 B received, 92 B sent
~~~

`endpoint` 是電信業者的 IP，代表封包從外部經數據機轉送進來；`latest handshake` 有時間，代表金鑰與 PSK 都正確。只有幾百 bytes 是握手與 keepalive，還要實際傳資料才算通。

接著 iPhone 保持 4G/5G 與 VPN，用 Safari 打開 `https://<node 的內網 IP>:8006`，出現 PVE 登入頁（自簽憑證警告屬正常）。筆電也已設定並連上 VPN。

連不上時最常見的原因：轉送規則選成 TCP（要 UDP）、內部 IP 沒有指到 ct:109，或測試時其實還連著家裡 Wi-Fi。

## 8. 刪除 8006 轉送，從外部確認

VPN 確認可用後，刪除數據機的 TCP 8006 轉送，保留 UDP 51820。接著用兩個方向驗證：

| 測試 | 做法 | 結果 |
| --- | --- | --- |
| 8006 已不對外 | iPhone **關掉 WireGuard**、使用 4G/5G，打開 `https://<對外 IP>:8006` | ✅ 打不開 |
| VPN 仍可用 | iPhone **打開 WireGuard**，打開 `https://<node 的內網 IP>:8006` | ✅ 出現 PVE 登入頁 |

兩個方向都要測：只測第一個，可能其實是整條網路不通；只測第二個，不能證明 8006 已經關閉。

從現在開始，在外面管理 PVE 一定要先連 VPN。

尚未記錄的後續：

1. 數據機上是否還有其他不需要的轉送（例如 22、8007、3128、10086）。
2. 隔天比較 Fail2Ban 的封鎖數量，預期明顯減少：

~~~bash
fail2ban-client status proxmox
grep "Ban " /var/log/fail2ban.log | awk '{print $1}' | sort | uniq -c | tail -7
~~~

3. 把 ct:109 的 WireGuard 狀態加入既有監控（Wazuh、LibreNMS 或 Graylog 告警），VPN 出問題時能先知道。

## 本次結論

外部連線已從「直接轉送 PVE 8006」改為「只轉送 WireGuard UDP 51820」：ct:109 的 WireGuard 與 WGDashboard 正常、預設改為 split tunnel、清掉舊 peer、新建兩個只用 `/32` 並啟用 PSK 的 peer，iPhone 從 4G/5G 透過 VPN 打開 PVE，筆電也已連上；8006 轉送已刪除，從外部確認無法連線，VPN 仍可用。待辦：檢查數據機其他轉送規則、觀察 Fail2Ban 封鎖數量變化、把 VPN 加入監控。

## 相關紀錄

- [PVE 一直被嘗試登入：怎麼確認 Fail2Ban 真的有擋？](https://kbwangtw.github.io/IT-Knowledge-Base/docs/pve/pve-cluster-fail2ban-hardening/)
- [PVE HA 放置策略](https://kbwangtw.github.io/IT-Knowledge-Base/docs/pve/pve-ha-placement-policy/)
- [WireGuard 官方網站](https://www.wireguard.com/)
- [WGDashboard 專案](https://github.com/donaldzou/WGDashboard)
