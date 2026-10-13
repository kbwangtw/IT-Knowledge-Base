---
layout: default
title: "不再把 PVE 8006 開到網際網路：改用 WireGuard 連回家"
permalink: /docs/pve/wireguard-remote-access-replace-8006/
date: 2026-10-12
categories: [PVE, WireGuard, VPN, Security, Network]
last_modified_at: 2026-10-13
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

3. 把 VPN 加入監控：已於 10/13 完成，見第 9 節。

## 9. VPN 監控：Wazuh 偵測、Graylog 寄信

8006 不對外之後，VPN 是唯一的遠端管理入口，它出問題要能先知道。ct:109 早在 9/30 就裝了 Wazuh Agent（ID 010），但 Agent 是 Active 只代表主機活著：**wg0 停掉或 WGDashboard 掛掉時，Wazuh 預設不會告警**。WGDashboard 停掉也要注意，因為 wg0 是靠它開機時帶起來的。

本次補上的告警路徑：

~~~text
ct:109 內部：wg-health.sh（每 5 分鐘）→ Wazuh Agent 010 → 規則 100150
ct:109 外部：Wazuh Manager 的 wg-reach.sh（每 5 分鐘）→ 規則 100151
  → syslog_output → Graylog Syslog UDP 1514 → Infrastructure Syslog
  → Event Definition「WireGuard VPN 異常」→ Gmail
~~~

兩個角度互補：內部檢查抓得到 wg0、WGDashboard 停掉；但 ct:109 整台停機時，它自己也無法回報，要靠 Manager 從外面檢查。

### 9-1 ct:109：健康檢查 script 與指令監控

在 ct:109 內：

~~~bash
cat > /usr/local/bin/wg-health.sh <<'EOF2'
#!/bin/sh
# 給 Wazuh 指令監控用：輸出一行 wg0 與 WGDashboard 的狀態
if ip link show wg0 >/dev/null 2>&1; then W=up; else W=down; fi
D=$(systemctl is-active wg-dashboard 2>/dev/null)
echo "wg-health: wg0=$W dashboard=$D"
EOF2
chmod 755 /usr/local/bin/wg-health.sh
/usr/local/bin/wg-health.sh          # wg-health: wg0=up dashboard=active
~~~

在 Agent 的 `ossec.conf` 最後加一個 `<ossec_config>` 區塊（檔案可以有多個區塊，不必動原本內容），先備份：

~~~xml
<ossec_config>
  <localfile>
    <log_format>full_command</log_format>
    <command>/usr/local/bin/wg-health.sh</command>
    <alias>wg-health</alias>
    <frequency>300</frequency>
  </localfile>
</ossec_config>
~~~

重啟 `wazuh-agent` 後，`/var/ossec/logs/ossec.log` 出現 `Monitoring full output of command(300): /usr/local/bin/wg-health.sh`，代表已載入。把檢查寫成獨立 script，比直接在 XML 裡寫 `&&` 好維護。

### 9-2 Wazuh Manager：告警規則

先列出 `local_rules.xml` 已使用的規則 ID，避免衝突（本案已用到 100140），再加入：

~~~xml
<group name="wireguard,vpn,">
  <rule id="100150" level="10">
    <if_sid>530</if_sid>
    <match>wg-health</match>
    <regex type="pcre2">wg0=down|dashboard=(?!active)</regex>
    <description>WireGuard ct:109: wg0 down or WGDashboard not active</description>
  </rule>

  <rule id="100151" level="10">
    <if_sid>530</if_sid>
    <match>wg-reach: unreachable</match>
    <description>WireGuard ct:109: unreachable from Wazuh manager (container down or network)</description>
  </rule>
</group>
~~~

- 530 是 Wazuh 內建「指令輸出」事件的基礎規則；`<match>` 與 `<regex>` 都要符合才觸發。
- `dashboard=(?!active)` 表示 dashboard 後面不是 active，`inactive`、`failed` 都算。
- 100151 比對 Manager 自己執行的 wg-reach 輸出，見 9-3。

`/var/ossec/bin/wazuh-analysisd -t` 通過後再重啟 `wazuh-manager`。

### 9-3 Manager 從外部檢查：wg-reach

100151 最初寫成接內建規則 504（`Agent disconnected`），想在 Agent 010 斷線時告警。**實測沒有觸發**：用 `ha-manager` 停掉 ct:109 後，`agent_control` 顯示 Disconnected，但 `alerts.json` 沒有 504 也沒有 100151。

**原因是接錯了規則，不是 Wazuh 沒有產生事件。** `ha-manager ... --state stopped` 是正常關機，Agent 停止前會先通知 Manager，產生的是 **506（Wazuh agent stopped，level 3）**；Manager 已經知道它是主動停止，就不會再產生 504。實測證據：

| 測試 | 關機方式 | Wazuh 產生的告警 |
| --- | --- | --- |
| ct:109（10:14） | `ha-manager set ct:109 --state stopped` | 506，agent wireguard |
| UBClient（10:32） | VM 內 `sudo poweroff` | 506，agent ubclient；超過 17 分鐘仍沒有 504 |

| 規則 | 意思 | 何時出現 |
| --- | --- | --- |
| 506 Wazuh agent stopped | Agent 主動通知「要停了」 | 正常關機、服務停止 |
| 504 Agent disconnected | Manager 等不到 Agent 回報 | 斷電、當機、網路中斷等來不及通知的情況（本次**未實測**） |

排查過程中先後排除了：`log_alert_level` 為 3（504 是 level 3，會寫入）、`local_rules.xml` 沒有任何規則動到 504。一度懷疑 `agents_disconnection_alert_time` 為 0 會停用斷線告警（Wazuh 5.0-beta 文件這樣寫），但改成 1m 後正常關機仍只有 506，這個推測與本次現象無關；它在 4.14 對 504 的實際作用仍未驗證。

只接 506 也不夠：它抓不到斷電與網路中斷。

改成由 Manager（ct:112）主動檢查 ct:109 的 WGDashboard port。WireGuard 本身是 UDP，而且不回應沒有金鑰的封包，沒辦法這樣檢查；10086 連得上，代表容器活著、網路通、WGDashboard 也正常。

在 ct:112 內：

~~~bash
cat > /usr/local/bin/wg-reach.sh <<'EOF2'
#!/bin/bash
# 給 Wazuh 指令監控用：從 Manager 檢查 ct:109 的 WGDashboard port 能不能連
H=<ct:109 IP>
if timeout 3 bash -c "</dev/tcp/$H/10086" 2>/dev/null; then
  echo "wg-reach: reachable"
else
  echo "wg-reach: unreachable"
fi
EOF2
chmod 755 /usr/local/bin/wg-reach.sh
~~~

Manager 的 `ossec.conf` 一樣用 `<localfile>` 加上 `full_command`，`<command>` 指向 `/usr/local/bin/wg-reach.sh`，`<alias>wg-reach</alias>`，`<frequency>300</frequency>`。Manager 自己產生的告警，agent 會顯示 `000`。

偵測時間從原本預期的約 16 分鐘（15 分鐘斷線判定再加告警），縮短為最多 5 分鐘。

### 9-4 Wazuh → Graylog

在 Manager 的 `ossec.conf` 加入，只轉送 `wireguard` 群組，不把全部告警灌進 Graylog：

~~~xml
<ossec_config>
  <syslog_output>
    <server><Graylog IP></server>
    <port>1514</port>
    <group>wireguard</group>
    <format>json</format>
  </syslog_output>
</ossec_config>
~~~

Wazuh 4.14 執行 `wazuh-control enable client-syslog` 會提示此選項已過時，csyslogd 預設就會啟動；重啟後用 `wazuh-control status` 確認 `wazuh-csyslogd is running`。

**踩雷：`<server>` 第一次填成 ct:109 自己的 IP**，告警被送到 WireGuard 容器、直接丟掉，Graylog 搜不到。填之前先用 `pct exec <Graylog CTID> -- ip -br addr show eth0` 確認 Graylog 的 IP。用 `sed` 修正時也要注意 `s#舊#新#` 的順序，寫反了不會報錯，只是什麼都沒改。

Graylog 收到的訊息：

| 欄位 | 結果 |
| --- | --- |
| Received by | Syslog UDP 1514（與 PVE、PBS 同一個 Input） |
| Routed into streams | Infrastructure Syslog |
| source | wazuh |
| message | JSON，含 `"id":"100150"`、描述，以及 `full_log` 裡的 `wg0=up dashboard=inactive` |

**另一個踩雷：** Graylog 搜尋列左邊的 stream 欄位如果選了「All events」，只會搜尋 Graylog 自己產生的告警事件，搜不到日誌訊息。測試時保持空白，搜尋所有 stream。

### 9-5 Graylog：Event Definition 與通知

| 欄位 | 值 |
| --- | --- |
| Title／Priority | WireGuard VPN 異常／High |
| Search Query | `source:wazuh AND "WireGuard ct:109"`（兩條規則的描述都以此開頭，不必為 100151 另外設定） |
| Streams | Infrastructure Syslog |
| Search within／Execute every | 5 分鐘／1 分鐘 |
| Notification | VPN 異常通知（Email），主旨 `【VPN 告警】：${event_definition_title}` |
| Grace Period | 30 分鐘 |
| Message Backlog | 5 |

Wazuh 每 5 分鐘產生一次告警，沒有 Grace Period 就會每 5 分鐘寄一封。Grace Period 期間內再測試不會寄信，屬正常。

### 9-6 實測（2026-10-13）

停止 WGDashboard 不會讓 wg0 斷線，所以拿它來做安全測試：

~~~bash
pct exec 109 -- systemctl stop wg-dashboard
# 等 6～7 分鐘，確認後立刻啟動回來
pct exec 109 -- systemctl start wg-dashboard
~~~

| 環節 | 結果 |
| --- | --- |
| script | 停止後輸出 `dashboard=inactive`，啟動後回到 `active` |
| Wazuh | `alerts.json` 有 100150（level 10，agent 010 wireguard），停止期間每 5 分鐘一筆 |
| Graylog | 收到訊息，進入 Infrastructure Syslog |
| Event Definition | Last Matched「a minute ago」 |
| Gmail | 09:42 收到正式告警「WireGuard VPN 異常」，事件時間 09:41:27 |

ct:109 整台停機測試。ct:109 受 HA 管理，用 `pct shutdown` 會被 HA 立刻拉起來，要改用 `ha-manager`；測試期間 VPN 會斷線，要在內網操作：

~~~bash
ha-manager set ct:109 --state stopped
# 等 6 分鐘，確認後立刻開回來
ha-manager set ct:109 --state started
~~~

| 環節 | 結果 |
| --- | --- |
| wg-reach | 停機後輸出 `wg-reach: unreachable` |
| Wazuh | 10:18:33 產生 100151（level 10，agent 000 wazuh） |
| Gmail | 10:19 收到正式告警「WireGuard VPN 異常」 |
| 恢復 | `ha-manager set ct:109 --state started` 後，HA 依負載把 ct:109 放到 node11；IP 與設定不變，`wg0=up dashboard=active` |

**Grace Period 會影響測試**：上一封信 09:42 寄出，第一次停機測試的事件落在 30 分鐘內，就算觸發也不會寄信。連續測試時，要等前一封信超過 30 分鐘。

## 本次結論

外部連線已從「直接轉送 PVE 8006」改為「只轉送 WireGuard UDP 51820」：ct:109 的 WireGuard 與 WGDashboard 正常、預設改為 split tunnel、清掉舊 peer、新建兩個只用 `/32` 並啟用 PSK 的 peer，iPhone 從 4G/5G 透過 VPN 打開 PVE，筆電也已連上；8006 轉送已刪除，從外部確認無法連線，VPN 仍可用。VPN 監控已完成：wg0 或 WGDashboard 異常（100150），以及 ct:109 整台停機（100151），都會經 Graylog 寄到 Gmail，10/13 兩種情況都實測收到。待辦：檢查數據機其他轉送規則、觀察 Fail2Ban 封鎖數量變化。

## 相關紀錄

- [PVE 一直被嘗試登入：怎麼確認 Fail2Ban 真的有擋？](https://kbwangtw.github.io/IT-Knowledge-Base/docs/pve/pve-cluster-fail2ban-hardening/)
- [PVE HA 放置策略](https://kbwangtw.github.io/IT-Knowledge-Base/docs/pve/pve-ha-placement-policy/)
- [WireGuard 官方網站](https://www.wireguard.com/)
- [WGDashboard 專案](https://github.com/donaldzou/WGDashboard)
