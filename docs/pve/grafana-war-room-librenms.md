---
layout: default
title: "用 Grafana 建立戰情中心（二）：接上 LibreNMS"
date: 2026-10-14
categories: [PVE, Grafana, LibreNMS]
permalink: /docs/pve/grafana-war-room-librenms/
last_modified_at: 2026-10-30
---
{% raw %}

# 用 Grafana 建立戰情中心（二）：接上 LibreNMS

> **一句話**：讓 Grafana 戰情中心也看得到「哪些設備斷線了」：以**唯讀**帳號的 API Token 讀取 LibreNMS，做出一格「斷線設備」數字和一張設備清單；10/30 再補上 LibreNMS 原本完全沒有的**告警規則與寄信**，設備斷線和恢復都會收到信。

| 項目 | 內容 |
| --- | --- |
| 適合誰看 | 想把監控系統的資料接到 Grafana 的人 |
| 環境 | LibreNMS 26.9.1（LXC，CT 102，nginx）、Grafana 13.2.3（CT 114）、Infinity plugin |
| 紀錄日期 | 2026-10-14（10/15 補充設備清單欄位與 SNMP 修正；10/22 補上 DC01、DC02、CA；10/30 告警寄信） |
| 結果 | ✅ 斷線設備數字、設備清單（16 台，10/22 起 19 台）已上線；Token 屬唯讀使用者、寫入測試被拒（403）；✅ DC01、DC02、CA 以 Ping 監控，斷線實測會變紅；✅ 設備斷線告警：CA 實測斷線約 1.5 分鐘收到信、恢復也收到信；✅ 中文範本含 IP、斷線原因、持續時間 |

> 第一階段見 [戰情中心（一）：接上 Wazuh](https://kbwangtw.github.io/IT-Knowledge-Base/docs/pve/grafana-war-room-wazuh/)。文中 IP 都是文件示範位址。

## 1. 先認識幾個名詞

| 名詞 | 白話解釋 |
| --- | --- |
| **LibreNMS** | 用 SNMP 監控網路設備與主機的系統：誰在線、流量、CPU… |
| **SNMP** | 監控系統向設備「問狀態」的標準協定；本環境都用加密的 SNMPv3 |
| **Grafana** | 把各種資料做成圖表儀表板的工具 |
| **Infinity plugin** | 讓 Grafana 讀取任意 JSON／API 資料的外掛 |
| **API Token** | 給程式用的「通行證」，代替帳號密碼 |
| **Global Read** | LibreNMS 的唯讀角色：看得到全部設備，但不能改任何東西 |
| **Laravel Sanctum** | LibreNMS 26 用來管理 API Token 的元件 |

## 2. 為什麼用 API，不直接讀資料庫

| | 直接讀 MariaDB | LibreNMS API（採用） |
| --- | --- | --- |
| 要不要改 LibreNMS | 要：改資料庫綁定位址並重啟、加防火牆、建資料庫帳號 | 不用，網頁本來就開著 |
| 權限 | 可以細到資料表 | Global Read 使用者，只能讀 |
| 彈性 | 可以寫任意 SQL | 設備清單、`type=down`、告警都有 API，戰情中心夠用 |
| 升級時 | 資料表結構可能改變 | 相對穩定 |

原則和第一階段相同：**不動來源系統的服務與資料庫，以唯讀身分讀取**。

## 3. 前置檢查：Grafana 連得到 LibreNMS 嗎？

在 node10 執行（LibreNMS 是 CT 102、Grafana 是 CT 114）：

```bash
pct exec 102 -- ss -tlnp | grep -E 'nginx|apache|php' | awk '{print $4}'   # LibreNMS 監聽哪些埠
pct exec 114 -- getent hosts librenms.<網域>                                # Grafana 解析得到名稱嗎
for u in http://librenms.<網域>/api/v0 https://librenms.<網域>/api/v0; do
  echo "$u -> $(pct exec 114 -- curl -sk -o /dev/null -w '%{http_code}' --max-time 5 $u)"
done
```

**看到的結果**：nginx 只監聽 `:80`；HTTP 回 **401**（連得到，但需要 Token），HTTPS 是 000（沒開）。

- 暫時用 HTTP，代表 Token 會以明文在內網傳送；因為 Token 屬於唯讀使用者，列為待改善（LibreNMS 啟用 HTTPS）。
- 用瀏覽器直接開 API 網址會看到 `{"message":"Unauthenticated."}`，代表 API 有要求驗證，屬正常。

## 4. 建立唯讀使用者與 API Token

### 4-1 唯讀使用者

LibreNMS 管理員登入 → 齒輪 → **Manage Users** → **Add User**：

| 欄位 | 設定 | 為什麼 |
| --- | --- | --- |
| 帳號 | `grafana` | — |
| Role | **Global Read** | Normal User 只看得到被指派的設備；Admin 權限太大 |
| 密碼 | 存進密碼管理器 | — |

用這個帳號登入確認：Roles 是 Global Read、Device Permissions 是 Global Viewing Access。

### 4-2 為什麼不能在畫面上建立 Token

LibreNMS 26 的「建立新的 API 存取權杖」視窗**沒有選擇使用者的欄位**，Token 會屬於「目前登入的帳號」，也就是管理員；而 Global Read 帳號的選單裡沒有 API 頁面。所以在畫面上建，Token 就會擁有管理員權限。

### 4-3 用程式替 `grafana` 建立 Token

新版 LibreNMS 用 Laravel Sanctum 管理 Token（資料表 `personal_access_tokens`，舊的 `api_tokens` 已不存在；`app/Models/User.php` 有 `use HasApiTokens`）。可以直接呼叫 LibreNMS 自己的 `createToken()`，由程式產生、以雜湊儲存：

```bash
cat > /tmp/mktoken.php <<'PHP'
<?php
require '/opt/librenms/vendor/autoload.php';
$app = require '/opt/librenms/bootstrap/app.php';
$app->make(Illuminate\Contracts\Console\Kernel::class)->bootstrap();
$u = App\Models\User::where('username', 'grafana')->firstOrFail();
echo "Token (shown once): " . $u->createToken('Grafana war room', ['*'], now()->addYear())->plainTextToken . PHP_EOL;
PHP
pct push 102 /tmp/mktoken.php /tmp/mktoken.php --perms 644
pct exec 102 -- su - librenms -s /bin/bash -c "cd /opt/librenms && php /tmp/mktoken.php"
pct exec 102 -- rm -f /tmp/mktoken.php; rm -f /tmp/mktoken.php
pct exec 102 -- mysql librenms -e "select t.id, u.username, t.name, t.expires_at from personal_access_tokens t left join users u on u.user_id=t.tokenable_id;"
```

- Token 格式是「編號|字串」，**整串**（含編號和 `|`）存進密碼管理器，只會顯示這一次。程式檔本身不含 Token。
- **應該看到**：最後一行查詢，擁有者是 `grafana`、到期日是一年後（2027-10-14）。

### 4-4 測試 Token 只能讀、不能寫

從 Grafana 容器測試（用 `read -s` 輸入，不會留在指令歷史）：

```bash
read -s -p "LibreNMS token: " T; echo
curl -s -H "X-Auth-Token: $T" "http://librenms.<網域>/api/v0/devices" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('status'), d.get('count'))"
curl -s -H "X-Auth-Token: $T" "http://librenms.<網域>/api/v0/devices?type=down" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('status'), d.get('count'))"
curl -s -o /dev/null -w '%{http_code}\n' -X POST -H "X-Auth-Token: $T" -H 'Content-Type: application/json' -d '{}' "http://librenms.<網域>/api/v0/devices"
unset T
```

| 測試 | 結果 | 意思 |
| --- | --- | --- |
| 全部設備 | 16 台 | 讀得到 |
| 斷線設備 | 0 | 讀得到 |
| 寫入（POST 空內容） | **403** | ✅ 權限被拒，Token 確實是唯讀 |

> 寫入測試送的是空內容，不會新增任何東西。如果回的是 400／422，代表權限檢查**放行了**，要立刻停止。Sanctum Token 一樣用 `X-Auth-Token` header。

## 5. 在 Grafana 建立 Infinity 資料來源

Connections → Add new connection → Infinity → Install → **Add new data source**：

| 欄位 | 設定 |
| --- | --- |
| Name | `LibreNMS` |
| Auth type | API Key Value pair：Key `X-Auth-Token`、Value 填 Token、Add to **Header** |
| **Allowed hosts** | `http://librenms.<網域>`：Token 只會送往清單內的網址，查詢打錯網址也不會外送 |

## 6. 做兩個面板

| 面板 | 查詢 | 顯示設定 |
| --- | --- | --- |
| 斷線設備（LibreNMS） | JSON／Parser **JSONata**／URL `.../api/v0/devices?type=down`；Columns：selector `count`（Number） | Stat；Calculation Last \*；No value 0；綠、≥1 紅 |
| 設備清單（LibreNMS） | JSON／JSONata／URL `.../api/v0/devices`；**Rows／Root 填 `devices`**；Columns：`hostname`、`status`（Number）、`uptime`（Number）、`os`（類型）、`features`（發行版） | Table；狀態用 Value mappings：1→Up 綠、0→Down 紅，Cell type Colored background；上線時間 Unit **duration (s)** |

設定小提醒：

| 情況 | 說明 |
| --- | --- |
| 找不到「Backend」Parser | 新版 Infinity 的 Parser 分 Backend（JSONata、JQ）和 Frontend 兩類，沒有叫「Backend」的單一選項 |
| 斷線數字顯示 0 是真的嗎？ | 直接讀 API 的 `count`，沒有斷線時就是真正的 0。驗證：暫時把 URL 拿掉 `?type=down`，應顯示 16（紅），改回後是 0 |
| 表格只有一列 | 沒設 Rows／Root 時，整個回應被當成一列（`count`、`devices`、`status` 三欄）；設成 `devices` 才會每台一列 |
| 上線時間差了 1000 倍 | `uptime` 單位是秒，要選 duration (s)，不是 (ms) |
| Columns 在哪裡 | 查詢區的 **Parsing options & Result fields** 裡 |

點表格「狀態」欄標題排序，Down 會排在最上面。

**驗收結果**：16 列都是 Up；上線時間合理（grafana 1 天、多數 2 天）。melayu17 只有 1 小時，查證是當天更新 DSM 後重開，屬預期。

## 7. 「系統」欄為什麼都顯示 proxmox？（2026-10-15 修正）

**原因**：LXC 容器和 PVE 主機**共用同一個核心（kernel）**，SNMP 回報的 `version` 都是 `7.0.14-23-pve`，所以 LibreNMS 把容器的 `os` 也判斷成 proxmox。實際的發行版在 `features` 欄，由 snmpd 的 `extend distro` 回報。

```bash
pct exec 102 -- mysql librenms -e "select hostname, os, version, features, hardware from devices order by hostname;"
```

用 `snmp-v3-add.sh` 加入的主機有值（例如 Ubuntu 24.04、Debian 13.7、Debian 12.15）；adguard、pihole、wireguard 和三台 PVE 節點是空的；NAS 是 dsm，沒有這欄。所以表格改成「**類型**」（`os`）和「**發行版**」（`features`）兩欄。

### 7-1 替 6 台補上 `extend distro`

這 6 台既沒有 `/usr/bin/distro`，snmpd.conf 也沒有 `extend distro`（PVE 節點只有 `extend proxmox`）。從 LibreNMS 容器取出官方 distro 腳本，逐台補上：

```bash
pct pull 102 /usr/bin/distro /root/distro
# 容器（同節點；其他節點的容器先 scp 到該節點再 pct push）
pct exec <CTID> -- cp -a /etc/snmp/snmpd.conf /etc/snmp/snmpd.conf.bak-distro-$(date +%Y%m%d)
pct push <CTID> /root/distro /usr/bin/distro --perms 755
pct exec <CTID> -- bash -c "grep -q '^extend distro' /etc/snmp/snmpd.conf || echo 'extend distro /usr/bin/distro' >> /etc/snmp/snmpd.conf"
pct exec <CTID> -- systemctl restart snmpd
# PVE 節點
scp /root/distro <節點>:/usr/bin/distro
ssh <節點> "chmod 755 /usr/bin/distro && cp -a /etc/snmp/snmpd.conf /etc/snmp/snmpd.conf.bak-distro-\$(date +%Y%m%d) && (grep -q '^extend distro' /etc/snmp/snmpd.conf || echo 'extend distro /usr/bin/distro' >> /etc/snmp/snmpd.conf) && systemctl restart snmpd"
# 不等每 6 小時的自動偵測，手動重新偵測 os 模組
pct exec 102 -- su - librenms -s /bin/bash -c "cd /opt/librenms && ./discovery.php -h <主機名稱> -m os"
```

**結果**：三個容器是 Debian 13.7，三台 PVE 節點是 `Debian 13.7/PVE 9.2.21`（distro 腳本會辨識 PVE）；snmpd 都 active，原本的 `extend proxmox` 不受影響。表格的「發行版」只剩兩台 NAS 空白。修改 snmpd.conf 會產生 Wazuh 檔案異動紀錄，屬預期。

### 7-2 順便強制加密：`rouser snmpuser priv`

這 6 台的 `rouser snmpuser` 原本沒有 `priv`（允許「只驗證、不加密」），而用腳本加入的主機都是 `rouser snmpuser priv`。同日改成一致：

```bash
pct exec <CTID> -- cp -a /etc/snmp/snmpd.conf /etc/snmp/snmpd.conf.bak-priv-$(date +%Y%m%d)
pct exec <CTID> -- sed -i 's/^rouser snmpuser[[:space:]]*$/rouser snmpuser priv/' /etc/snmp/snmpd.conf
pct exec <CTID> -- systemctl restart snmpd
pct exec 102 -- su - librenms -s /bin/bash -c "cd /opt/librenms && ./lnms device:poll <主機名稱> -m core"
```

（PVE 節點在節點上直接執行同樣的 cp／sed／restart。）

**結果**：6 台都是 `rouser snmpuser priv`、snmpd active；LibreNMS 一律以 authPriv（驗證＋加密）輪詢，6 台 poll 都有 `Snmpget` 回應、沒有逾時。還原：把 `.bak-priv-日期` 複製回 snmpd.conf 並重啟 snmpd。

## 8. 發現：jt-ipam 的 LibreNMS Token 屬於 admin

`personal_access_tokens` 只有兩筆：`admin` 的 `jt-ipam`（**不會過期**）和 `grafana` 的 `Grafana war room`。jt-ipam 主機如果被入侵，那把 Token 可以修改 LibreNMS 任何設定。jt-ipam 的「自動加入監控」功能可能需要寫入權限，所以暫不更動，列為待評估。

## 9. 補上 DC01、DC02、CA：只用 Ping 監控（2026-10-22）

**為什麼**：Grafana 把「設備清單（LibreNMS）」和 PVE 的「VM／CT 位置與 HA」並排後發現，網域控制站 DC01、DC02 和憑證伺服器 CA **不在 LibreNMS 裡**，它們掛掉時戰情中心看不出來。

**為什麼不用 SNMP**：

| 選項 | 評估 |
| --- | --- |
| Windows 內建 SNMP | 只支援 v1／v2c（community 明文），跟本環境統一的 SNMPv3 authPriv 不一致，微軟也已標為淘汰 |
| Net-SNMP（Windows 版） | 支援 v3，但找得到的 Windows 安裝檔和文件停在 5.6～5.7 版，查不到仍在維護的官方 Windows 版 |
| snmp4windows（商用 SNMPv3 agent） | 有試用版，但找不到 Server 2022／2025 的實測紀錄 |
| jt-snmpd（開源） | 目前只有 v2c |
| **只用 Ping（✅ 採用）** | DC 完全不用安裝或改設定，先補上「主機有沒有活著」 |

DC 和 CA 是網域最核心的主機，不在上面跑沒有維護或沒驗證過的網路服務。資安事件已由 Wazuh Agent（9/30 安裝）監控；CPU、磁碟用量之後再評估（先在非 DC 的測試機試用 SNMPv3 agent）。

### 9-1 先確認解析得到、Ping 得到

```bash
pct exec 102 -- bash -c 'for h in dc01 dc02 ca; do echo "== $h"; getent hosts $h.<網域> || getent hosts $h || echo "解析不到"; done'
pct exec 102 -- fping -c 3 dc01.<網域> dc02.<網域> ca.<網域>
```

**看到的結果**：三台都解析得到；dc01、dc02 `3/3/0%`，**ca `3/0/100%`**。推測原因：升級成網域控制站時會自動開放 AD 的 ICMP Echo 規則，CA 只是成員伺服器，Windows 預設擋 Ping。

### 9-2 CA 只對 LibreNMS 開放 Ping

在 CA 以系統管理員身分開 PowerShell（LibreNMS 的 IP 用 `pct exec 102 -- hostname -I` 查）：

```powershell
Get-NetConnectionProfile | Select-Object InterfaceAlias, NetworkCategory
New-NetFirewallRule -DisplayName "LibreNMS ICMPv4 Echo" -Direction Inbound -Protocol ICMPv4 -IcmpType 8 -RemoteAddress <LibreNMS IP> -Action Allow -Profile Any
Get-NetFirewallRule -DisplayName "LibreNMS ICMPv4 Echo" | Get-NetFirewallAddressFilter
```

| 片段 | 意思 |
| --- | --- |
| `-Protocol ICMPv4 -IcmpType 8` | 只開放 Ping 請求，不開其他 ICMP |
| `-RemoteAddress <LibreNMS IP>` | 只有 LibreNMS 能 Ping，其他來源照樣擋 |
| `-Profile Any` | 不分網路設定檔；安全性靠來源 IP 限制 |

**看到的結果**：再跑一次 fping，ca 變成 `3/3/0%`。新增規則可能產生一筆 Wazuh 的防火牆變更事件，屬預期。

> **10/30 更新**：之後作者刻意改用 Windows 內建的「核心網路診斷 - ICMP 回應要求 (ICMPv4-In)」規則（Domain 設定檔、內部名稱 `CoreNet-Diag-ICMP4-EchoRequest-In-NoScope`，允許任何來源），`LibreNMS ICMPv4 Echo` 已不存在，跟兩台 DC 一樣網域內都能 Ping。Windows 防火牆事件記錄查不到新增或刪除的紀錄（推測已被新紀錄蓋掉）。之後測試斷線要改停用這條內建規則（10-5）。

### 9-3 加入 LibreNMS

```bash
for h in dc01 dc02 ca; do
  pct exec 102 -- su - librenms -s /bin/bash -c "cd /opt/librenms && ./lnms device:add --ping-only $h.<網域>"
done
for h in dc01 dc02 ca; do
  pct exec 102 -- su - librenms -s /bin/bash -c "cd /opt/librenms && ./lnms device:poll $h.<網域>" | tail -3
done
pct exec 102 -- mysql librenms -e "select device_id, hostname, status, status_reason, os, last_polled from devices where hostname like 'dc0%' or hostname like 'ca.%';"
```

| 片段 | 意思 |
| --- | --- |
| `device:add --ping-only` | 新增設備，不使用 SNMP，只用 Ping |
| `device:poll` | 立刻輪詢一次，不等 5 分鐘的排程 |
| `status` | 1 上線、0 斷線；`status_reason` 是斷線原因 |

**看到的結果**：`Added device …`（device_id 24、25、26），三台 `status` 都是 1。Grafana 的設備清單從 16 列變成 **19 列**，三台都是 Up。

> `devices` 資料表**沒有** `snmp_disable` 欄位，查詢會出現 `ERROR 1054 Unknown column`；不影響設備加入。

### 9-4 實測：讓 CA「假裝斷線」

只停用 CA 上的 Ping 規則，CA 本身照常運作：

```powershell
Disable-NetFirewallRule -DisplayName "LibreNMS ICMPv4 Echo"
```

```bash
pct exec 102 -- su - librenms -s /bin/bash -c "cd /opt/librenms && ./lnms device:poll ca.<網域>" | tail -3
pct exec 102 -- mysql librenms -e "select hostname, status, status_reason from devices where hostname like 'ca.%';"
```

**看到的結果**：`status 0`、`status_reason icmp`；Grafana「斷線設備」變成紅色 1，清單裡 ca 是 Down。

恢復：`Enable-NetFirewallRule -DisplayName "LibreNMS ICMPv4 Echo"`，再 `device:poll` 一次，`status` 回到 1、Grafana 回到綠色 0。

當時 LibreNMS **沒有任何告警規則**，所以這次斷線只在畫面上看得到、`alert_log` 沒有紀錄，也沒有寄信，補在第 10 節。

## 10. LibreNMS 告警：規則、Operation 與寄信（2026-10-30）

**為什麼**：9-4 實測時發現 LibreNMS 從來沒寄過告警。盤點結果：

```bash
pct exec 102 -- mysql librenms -e "select (select count(*) from alert_rules) as 規則總數, (select count(*) from alert_rules where disabled=0) as 啟用中, (select count(*) from alerts where state=1) as 觸發中, (select count(*) from alert_log where time_logged > now() - interval 7 day) as 近7天紀錄;"
pct exec 102 -- postconf -h relayhost myhostname inet_interfaces
```

**看到的結果**：四個數字都是 **0**（沒有任何規則）；容器裡 postfix 有裝、只聽本機，但 `relayhost` 是空白，`myhostname` 是 `librenms.localdomain`。也就是「沒有規則」和「寄不出去」兩個缺口都要補。

> `mysql -e` 查不到資料時**什麼都不顯示**，空白不代表出錯；所以改用 `count(*)`，一定會印出數字。

```text
規則 Devices up/down → Operation「Gmail 立即通知」→ 傳送方式 Mail → postfix（CT 102）→ Gmail → 信箱
```

| 名詞 | 白話解釋 |
| --- | --- |
| **警報規則（Alert Rule）** | 什麼情況算告警，例如 `macros.device_down = 1` |
| **警報操作（Operation）** | LibreNMS 26.x 新增：何時寄、隔多久再寄、寄到哪裡。**規則沒有選 Operation 時照樣觸發，但不會寄任何信** |
| **警報傳送（Transport）** | 寄送的管道，例如 Mail |
| **relayhost** | postfix 把信交給誰轉寄，本環境是 Gmail |

### 10-1 postfix 透過 Gmail 轉寄（照抄 PVE 節點）

先看範本（node10）和 CT 102 的差異，只看參數與權限，不看密碼內容：

```bash
postconf -n | grep -E '^(relayhost|smtp_sasl|smtp_tls|smtp_use_tls|myhostname|inet_interfaces)'
ls -l /etc/postfix/sasl_passwd*
pct exec 102 -- bash -c "postconf -n | grep -E '^(relayhost|smtp_sasl|smtp_tls|myhostname|inet_interfaces|mydestination)'; ls -l /etc/postfix/sasl_passwd* 2>&1; dpkg -l libsasl2-modules 2>/dev/null | tail -1"
```

**看到的結果**：node10 是 `relayhost = smtp.gmail.com:587`、`smtp_sasl_auth_enable = yes`、`smtp_tls_security_level = encrypt`；CT 102 沒有 `sasl_passwd`，**`libsasl2-modules` 也沒裝**（`un`），沒有它 postfix 無法用帳密登入 Gmail。

在 **CT 102 所在節點**執行（當天 CT 102 在 node11；不確定時先 `ha-manager status | grep 102`）：

```bash
pct exec 102 -- apt install -y libsasl2-modules
ssh root@node10 cat /etc/postfix/sasl_passwd | pct exec 102 -- sh -c 'umask 077; cat > /etc/postfix/sasl_passwd'
pct exec 102 -- bash -c "
cp -a /etc/postfix/main.cf /etc/postfix/main.cf.bak-\$(date +%Y%m%d)
postconf -e 'relayhost = smtp.gmail.com:587' \
  'smtp_sasl_auth_enable = yes' \
  'smtp_sasl_password_maps = hash:/etc/postfix/sasl_passwd' \
  'smtp_sasl_security_options = noanonymous' \
  'smtp_tls_security_level = encrypt' \
  'myhostname = librenms.<網域>'
postmap /etc/postfix/sasl_passwd
chmod 600 /etc/postfix/sasl_passwd /etc/postfix/sasl_passwd.db
postfix check && echo CHECK-OK
systemctl reload postfix
"
```

| 片段 | 意思 |
| --- | --- |
| `ssh … cat … \| pct exec 102 -- sh -c '…'` | 帳密直接從 node10 用管線送進容器，不顯示在畫面、不留暫存檔；沿用同一組 Gmail 應用程式密碼 |
| `umask 077` | 新檔權限 600 |
| `relayhost` | 要跟 `sasl_passwd` 裡的寫法**一字不差** |
| `noanonymous` | 不允許匿名登入；node10 是空白（全部允許），這裡稍微嚴格，搭配強制加密照樣能登入 Gmail |
| `chmod 600 … .db` | `.db` 是 `postmap` 產生的查詢檔，**同樣含有密碼**，也要 600 |

**看到的結果**：`CHECK-OK`；兩個檔案都是 `-rw-------`。`postfix: Postfix is using backwards-compatible default settings` 三行是提醒，不影響寄信。

> ⚠️ `pct` 只能操作本節點的容器。在 node10 執行會出現 `Configuration file 'nodes/node10/lxc/102.conf' does not exist`，帳密不會寫到任何地方，換到正確的節點再執行即可。

寄一封測試信：

```bash
read -p "收件 Gmail：" TO
printf 'Subject: [TEST] LibreNMS CT102 mail relay\nContent-Type: text/plain; charset=UTF-8\n\n這是 LibreNMS 容器（CT 102）透過 postfix + Gmail 寄出的測試信。\n' | pct exec 102 -- /usr/sbin/sendmail "$TO"
pct exec 102 -- bash -c "journalctl --since '5 min ago' --no-pager | grep -E 'postfix/.*status=' | tail -3"
```

**看到的結果**：`relay=smtp.gmail.com[…]:587 … status=sent (250 2.0.0 OK …)`，3 秒寄出；信進收件匣，寄件人顯示 `root <你的 Gmail>`（Gmail 會把寄件地址改成登入的帳號）。

### 10-2 LibreNMS 寄信設定

```bash
read -p "寄件 Gmail（跟 postfix 登入的同一個）：" FROM
for kv in "email_backend sendmail" "email_from $FROM" "email_user LibreNMS"; do
  pct exec 102 -- su - librenms -s /bin/bash -c "cd /opt/librenms && ./lnms config:set $kv"
done
pct exec 102 -- su - librenms -s /bin/bash -c "php -r 'echo ini_get(\"sendmail_path\"), PHP_EOL;'"
```

| 設定 | 意思 |
| --- | --- |
| `email_backend sendmail` | 交給本機 sendmail（postfix） |
| `email_from` | 寄件地址；Gmail 反正會改成登入帳號，直接填同一個 |
| `email_user LibreNMS` | 寄件人顯示名稱 |

**看到的結果**：三個設定都成功；PHP 的 `sendmail_path` 是 `/usr/sbin/sendmail -t -i`，所以不用另外設定路徑（`email_sendmail_path` 會回 `This is not a valid setting`，不是有效設定）。

### 10-3 警報傳送（Transport）

**警報 → 警報傳送 → Create alert transport**：

| 欄位 | 設定 |
| --- | --- |
| Transport name | 自訂，例如 `ITBH -Infra GMail` |
| Transport type | Mail |
| Default Alert | ON |
| Contact Type | Specified Email |
| Email | 收件信箱（**手動輸入**） |
| Include Graphs | ON |

按 **Test**，收到測試信、寄件人顯示 **LibreNMS**。

> 存檔時出現「email 必須是有效的電子郵件地址」：欄位裡帶了看不見的空白（複製貼上造成），清空後手動輸入即可。

### 10-4 警報操作（Operation）與規則

**警報 → 警報操作 → 新增**：

| 欄位 | 設定 | 意思 |
| --- | --- | --- |
| 名稱 | `Gmail 立即通知` | |
| 預設步驟持續時間 | 60 | |
| 抑制通知 | OFF | |
| 步驟從／**步驟到** | 1／**1** | **只寄一封**；「步驟到」留空是 ∞，會一直重複寄到問題解決 |
| 起始（秒） | 0 | 立刻寄 |
| 步驟持續時間（秒） | 60 | |
| 傳輸方式／群組 | `Mail: ITBH -Infra GMail` | |

**警報 → 警報規則 → Create rule from collection → `Devices up/down`**：條件 `macros.device_down = Yes`、Severity **Critical**、Recovery alerts **ON**、Acknowledgement alerts ON、Match devices 空白（全部設備），**Operation 選 `Gmail 立即通知`**。存檔後作者把規則名稱改成 **`設備連/斷線`**；Operation、範本是用規則編號連結，改名不受影響。

> 舊版的 Max alerts、Delay、Interval 已經不在規則裡（Advanced 分頁只剩 Override SQL），改由 Operation 決定。Transport 開 Default Alert **不會**讓規則自動寄信，一定要選 Operation。

### 10-5 實測：CA 斷線與恢復

在 CA 暫時停用 Domain 的 Ping 規則（同一個 PowerShell 視窗做到恢復）：

```powershell
$r = Get-NetFirewallRule -DisplayName "核心網路診斷 - ICMP 回應要求 (ICMPv4-In)" | Where-Object { $_.Profile -match 'Domain' }
$r | Select-Object Name, DisplayName, Profile, Enabled
$r | Disable-NetFirewallRule
```

```bash
pct exec 102 -- su - librenms -s /bin/bash -c "cd /opt/librenms && ./lnms device:poll ca.<網域>" | tail -3
sleep 120
pct exec 102 -- mysql librenms -e "select (select count(*) from alerts where state=1) as 觸發中, (select count(*) from alert_log where time_logged > now() - interval 10 minute) as 近10分鐘紀錄;"
pct exec 102 -- bash -c "journalctl --since '5 min ago' --no-pager | grep -E 'postfix/.*status=' | tail -3"
```

恢復：`$r | Enable-NetFirewallRule`（視窗關了就用 `Enable-NetFirewallRule -Name "CoreNet-Diag-ICMP4-EchoRequest-In-NoScope"`），再 `device:poll` 一次。

**看到的結果**：

| 時間 | 事件 |
| --- | --- |
| 14:56:29 | 停用規則；輪詢顯示 `Device was down (icmp), unable to poll.` |
| 14:57:27 | 告警產生，觸發中 1、近 10 分鐘紀錄 1 |
| 14:58:04 | postfix `status=sent`，收到「Alert for device ca.<網域> - Devices up/down」，Severity critical |
| 約 14:59 | 啟用規則、輪詢 |
| 15:00:10 | 恢復，`Time elapsed: 2m 43s`；15:01:14 寄出「Device ca.<網域> recovered from Devices up/down」，觸發中回到 0 |

預設範本內容很少（`Faults:`、`Alert sent to:` 都是空的），所以接著改成中文範本（10-6）。

### 10-6 中文告警範本（加上 IP、斷線原因、持續時間）

**做什麼**：**不改預設範本**，另外新增一個只套用在「設備連/斷線」的範本；改壞了移除即可。範本是 Laravel **Blade** 語法：`{{ … }}` 換成實際的值，`@if … @endif` 是條件。

**警報 → 警報範本 → 新增**：

| 欄位 | 設定 |
| --- | --- |
| Template name | `中文告警` |
| Attach template to rules | `設備連/斷線` |
| Alert title | `【LibreNMS 告警】{{ $alert->hostname }}：{{ $alert->name }}` |
| Recovery title | `【LibreNMS 恢復】{{ $alert->hostname }}：{{ $alert->name }}` |

Template：

```blade
@php($dev = \App\Models\Device::find($alert->device_id))
@if ($alert->state == 0)
【已恢復】{{ $alert->hostname }}
@elseif ($alert->state == 2)
【已確認】{{ $alert->hostname }}
@else
【告警】{{ $alert->hostname }}
@endif

規則：{{ $alert->name ?: $alert->rule }}
嚴重程度：{{ ['critical' => '嚴重', 'warning' => '警告', 'ok' => '正常'][$alert->severity] ?? $alert->severity }}
主機：{{ $alert->hostname }}
@if ($dev && $dev->ip)
IP：{{ $dev->ip }}
@endif
@if ($alert->state != 0 && $dev && $dev->status_reason)
斷線原因：{{ ['icmp' => 'Ping 無回應（ICMP）', 'snmp' => 'SNMP 無回應'][$dev->status_reason] ?? $dev->status_reason }}
@endif
@if ($alert->state == 0)
持續時間：{{ $alert->elapsed }}
@endif
時間：{{ $alert->timestamp }}
編號：{{ $alert->uid }}
@if ($alert->faults)
@foreach ($alert->faults as $key => $value)
@if (!empty($value['string']))
細項 {{ $key }}：{{ $value['string'] }}
@endif
@endforeach
@endif
```

| 片段 | 意思 |
| --- | --- |
| `@php($dev = \App\Models\Device::find($alert->device_id))` | 用設備編號從資料庫查出這台設備 |
| `$alert->state` | 0 已恢復、1 告警中、2 已確認 |
| `['critical' => '嚴重', …][…] ?? …` | 英文換中文；對照表沒有的值顯示原文 |
| `$dev->ip`、`$dev->status_reason` | IP 和斷線原因改從設備資料讀 |
| `@if (… && …)` | 有值才顯示這一行，沒有就整行略過 |
| `$alert->elapsed` | 持續時間，只有恢復通知才有 |
| `!empty($value['string'])` | 設備斷線的細項是空的，避免印出空白的 `#1:` |

**為什麼要查資料庫**：第一版直接用 `$alert->ip`、`$alert->status_reason`，信裡**沒有這兩行**；查資料庫 `devices` 表卻有值：

```bash
pct exec 102 -- mysql librenms -e "select device_id, hostname, inet6_ntoa(ip) as ip, overwrite_ip, status, status_reason from devices where hostname like 'ca.%';"
```

結果是 `ip 192.0.2.23`、`status_reason icmp`。也就是告警資料沒有帶這兩個值（`status_reason` 本來就不在官方欄位清單裡），改用 `$alert->device_id` 查設備後就出現了。

**實測**（停用 CA 的 Ping 規則兩次）：

| 編號 | 時間 | 內容 |
| --- | --- | --- |
| 3 | 15:23:19 | 第一版範本：中文、主旨正確，**沒有 IP、斷線原因** |
| 4 | 15:25:34 | 第一版恢復信：持續時間 `2m 15s` |
| 5 | 15:27:25 | 第二版：`IP：192.0.2.23`、`斷線原因：Ping 無回應（ICMP）` ✅ |
| 6 | 15:28:48 | 第二版恢復信：IP、`持續時間：1m 23s` ✅ |

收到的信：

```text
主旨：【LibreNMS 告警】ca.<網域>：設備連/斷線

【告警】ca.<網域>

規則：設備連/斷線
嚴重程度：嚴重
主機：ca.<網域>
IP：192.0.2.23
斷線原因：Ping 無回應（ICMP）
時間：2026-10-30 15:27:25
編號：5
```

> Blade 範本可以執行任意 PHP（`@php`），官方文件提醒只能讓信任的管理員編輯範本。

## 11. 還原方式

```bash
pct exec 102 -- mysql librenms -e "delete t from personal_access_tokens t join users u on u.user_id=t.tokenable_id where u.username='grafana';"
```

再到 LibreNMS 刪除 `grafana` 使用者，並在 Grafana 移除 LibreNMS 資料來源和兩個面板。LibreNMS 本身沒有其他變更。

第 9 節的三台：`lnms device:remove <主機名稱>` 移除設備（CA 的 Ping 現在由內建規則放行，作者刻意保留）。

第 10 節：在網頁刪除範本 `中文告警`、規則 `設備連/斷線`、警報操作 `Gmail 立即通知`、警報傳送；`lnms config:set email_backend mail`；CT 102 把 `main.cf.bak-日期` 複製回 `/etc/postfix/main.cf`、刪除 `/etc/postfix/sasl_passwd*`，再 `systemctl reload postfix`。

## 12. 待辦

| 項目 | 狀態 |
| --- | --- |
| LibreNMS 啟用 HTTPS（Token 目前以 HTTP 傳送） | 待改善 |
| 2027-10-14 前更換 Grafana 用的 LibreNMS Token | 長期追蹤（已排入 Google Calendar 2027-10-01） |
| 評估 jt-ipam 改用權限較小的 LibreNMS 使用者 | 待評估 |
| 「目前告警」面板（`/api/v0/alerts?state=1`） | 可擴充 |
| DC01、DC02、CA 加入 LibreNMS（只用 Ping） | ✅ 完成（2026-10-22，第 9 節） |
| LibreNMS 告警規則與寄信（原本 0 條規則、postfix 未設轉寄） | ✅ 完成（2026-10-30，第 10 節）：「設備連/斷線」，斷線與恢復都會寄信 |
| 告警範本改成中文，加上 IP、斷線原因、持續時間 | ✅ 完成（2026-10-30，10-6） |
| 評估再加其他規則（例如磁碟將滿、連接埠斷線），一次加一條、觀察信件量 | ⏳ 待評估 |
| PVE 三台與 PBS31 的 `/etc/postfix/sasl_passwd.db` 權限改成 600（node10、node12、pbs31 原本 644） | ✅ 完成（2026-10-30），見 [Graylog 告警與監控（二）](https://kbwangtw.github.io/IT-Knowledge-Base/docs/pve/graylog-alerts-monitoring/) 9-3 |
| node10 沒有 pbs31 的 SSH 主機金鑰紀錄（`Host key verification failed`） | ⏳ 需要時再於 PBS31 主控台確認指紋後加入 |
| node10 的 `smtp_tls_CAfile` 指向 Entrust 根憑證，但 Gmail 不是 Entrust 簽發；`encrypt` 模式不驗證憑證所以沒影響，日後改成驗證憑證時要一併修正 | ⏳ 待評估 |
| DC／CA 的 CPU、磁碟用量：先在非 DC 的測試機試用 SNMPv3 agent（snmp4windows），或等 jt-snmpd 支援 v3 | ⏳ 待評估 |
| 設備清單改為「類型」＋「發行版」 | ✅ 完成（2026-10-15） |
| 6 台補 `extend distro` | ✅ 完成（2026-10-15） |
| 6 台 `rouser snmpuser` 加上 `priv` | ✅ 完成（2026-10-15） |

## 13. 延伸閱讀

- [LibreNMS：API Authentication](https://docs.librenms.org/API/)、[API Devices](https://docs.librenms.org/API/Devices/)
- [Jt-snmpd: a read-only SNMP agent for Windows hosts（LibreNMS Community）](https://community.librenms.org/t/jt-snmpd-a-read-only-snmp-agent-for-windows-hosts/29432)
- [Net-SNMP README.win32](https://net-snmp.sourceforge.io/docs/README.win32.html)
- [LibreNMS：Alerting Operations](https://docs.librenms.org/Alerting/Operations/)、[Alerting](https://docs.librenms.org/Alerting/)、[Templates](https://docs.librenms.org/Alerting/Templates/)
- [Postfix：SASL（sasl_passwd 權限建議）](https://www.postfix.org/SASL_README.html)
- [Laravel Sanctum：API Token Authentication](https://laravel.com/docs/sanctum#api-token-authentication)
- [Grafana Infinity data source](https://grafana.com/docs/plugins/yesoreyeram-infinity-datasource/latest/)
- [用 Grafana 建立戰情中心（一）：接上 Wazuh](https://kbwangtw.github.io/IT-Knowledge-Base/docs/pve/grafana-war-room-wazuh/)
- [用 Grafana 建立戰情中心（三）：接上 Prometheus（Ceph 與 PVE）](https://kbwangtw.github.io/IT-Knowledge-Base/docs/pve/grafana-war-room-prometheus/)

{% endraw %}
