---
layout: default
title: "用 Grafana 建立戰情中心（二）：接上 LibreNMS"
date: 2026-10-14
categories: [PVE, Grafana, LibreNMS]
permalink: /docs/pve/grafana-war-room-librenms/
last_modified_at: 2026-10-22
---

# 用 Grafana 建立戰情中心（二）：接上 LibreNMS

> **一句話**：讓 Grafana 戰情中心也看得到「哪些設備斷線了」：以**唯讀**帳號的 API Token 讀取 LibreNMS，做出一格「斷線設備」數字和一張設備清單。

| 項目 | 內容 |
| --- | --- |
| 適合誰看 | 想把監控系統的資料接到 Grafana 的人 |
| 環境 | LibreNMS 26.9.1（LXC，CT 102，nginx）、Grafana 13.2.3（CT 114）、Infinity plugin |
| 紀錄日期 | 2026-10-14（10/15 補充設備清單欄位與 SNMP 修正；10/22 補上 DC01、DC02、CA） |
| 結果 | ✅ 斷線設備數字、設備清單（16 台，10/22 起 19 台）已上線；Token 屬唯讀使用者、寫入測試被拒（403）；✅ DC01、DC02、CA 以 Ping 監控，斷線實測會變紅 |

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

## 10. 還原方式

```bash
pct exec 102 -- mysql librenms -e "delete t from personal_access_tokens t join users u on u.user_id=t.tokenable_id where u.username='grafana';"
```

再到 LibreNMS 刪除 `grafana` 使用者，並在 Grafana 移除 LibreNMS 資料來源和兩個面板。LibreNMS 本身沒有其他變更。

第 9 節的三台：`lnms device:remove <主機名稱>` 移除設備；CA 上 `Remove-NetFirewallRule -DisplayName "LibreNMS ICMPv4 Echo"`。

## 11. 待辦

| 項目 | 狀態 |
| --- | --- |
| LibreNMS 啟用 HTTPS（Token 目前以 HTTP 傳送） | 待改善 |
| 2027-10-14 前更換 Grafana 用的 LibreNMS Token | 長期追蹤（已排入 Google Calendar 2027-10-01） |
| 評估 jt-ipam 改用權限較小的 LibreNMS 使用者 | 待評估 |
| 「目前告警」面板（`/api/v0/alerts?state=1`） | 可擴充 |
| DC01、DC02、CA 加入 LibreNMS（只用 Ping） | ✅ 完成（2026-10-22，第 9 節） |
| LibreNMS 告警：**沒有任何告警規則**（`alert_rules` 0 筆、近 7 天 `alert_log` 0 筆，9-4 的斷線也沒留下告警）；容器內 postfix 已安裝、只聽本機，但 `relayhost` 空白、`myhostname` 是 `librenms.localdomain` | ⏳ 待辦（2026-10-22 盤點）：先建「設備斷線」等少數規則，再比照 PVE／PBS 設定 Gmail 轉寄 |
| DC／CA 的 CPU、磁碟用量：先在非 DC 的測試機試用 SNMPv3 agent（snmp4windows），或等 jt-snmpd 支援 v3 | ⏳ 待評估 |
| 設備清單改為「類型」＋「發行版」 | ✅ 完成（2026-10-15） |
| 6 台補 `extend distro` | ✅ 完成（2026-10-15） |
| 6 台 `rouser snmpuser` 加上 `priv` | ✅ 完成（2026-10-15） |

## 12. 延伸閱讀

- [LibreNMS：API Authentication](https://docs.librenms.org/API/)、[API Devices](https://docs.librenms.org/API/Devices/)
- [Jt-snmpd: a read-only SNMP agent for Windows hosts（LibreNMS Community）](https://community.librenms.org/t/jt-snmpd-a-read-only-snmp-agent-for-windows-hosts/29432)
- [Net-SNMP README.win32](https://net-snmp.sourceforge.io/docs/README.win32.html)
- [Laravel Sanctum：API Token Authentication](https://laravel.com/docs/sanctum#api-token-authentication)
- [Grafana Infinity data source](https://grafana.com/docs/plugins/yesoreyeram-infinity-datasource/latest/)
- [用 Grafana 建立戰情中心（一）：接上 Wazuh](https://kbwangtw.github.io/IT-Knowledge-Base/docs/pve/grafana-war-room-wazuh/)
- [用 Grafana 建立戰情中心（三）：接上 Prometheus（Ceph 與 PVE）](https://kbwangtw.github.io/IT-Knowledge-Base/docs/pve/grafana-war-room-prometheus/)
