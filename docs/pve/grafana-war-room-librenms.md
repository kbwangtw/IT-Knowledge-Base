---
layout: default
title: "用 Grafana 建立戰情中心（二）：接上 LibreNMS"
date: 2026-10-14
categories: [PVE, Grafana, LibreNMS]
permalink: /docs/pve/grafana-war-room-librenms/
last_modified_at: 2026-10-14
---

# 用 Grafana 建立戰情中心（二）：接上 LibreNMS

[第一階段](https://kbwangtw.github.io/IT-Knowledge-Base/docs/pve/grafana-war-room-wazuh/)已在戰情中心放上 Wazuh 的資安數字。本篇接上 LibreNMS，讓同一頁也看得到設備上下線：一格「斷線設備」數字與一張設備清單。

> 紀錄日期：2026-10-14；LibreNMS 26.9.1（LXC，nginx）、Grafana 13.2.3、Infinity plugin。文中 IP 皆為文件示範位址。

## 1. 接法：API，不直接讀資料庫

| | 直接讀 MariaDB | LibreNMS API（採用） |
| --- | --- | --- |
| 要改 LibreNMS | 改資料庫綁定位址並重啟、加防火牆、建資料庫帳號 | 不用，網頁本來就開著 |
| 權限 | 可細到資料表 | Global Read 使用者，只能讀 |
| 彈性 | 可寫任意 SQL | 設備清單、`type=down`、告警都有 API，戰情中心夠用 |
| 升級 | 資料表結構可能改變 | 相對穩定 |

原則與第一階段相同：不動來源系統的服務與資料庫，以唯讀身分讀取。

## 2. 前置檢查

在 node10（LibreNMS 為 CT 102、Grafana 為 CT 114）：

~~~bash
pct exec 102 -- ss -tlnp | grep -E 'nginx|apache|php' | awk '{print $4}'
pct exec 114 -- getent hosts librenms.<網域>
for u in http://librenms.<網域>/api/v0 https://librenms.<網域>/api/v0; do
  echo "$u -> $(pct exec 114 -- curl -sk -o /dev/null -w '%{http_code}' --max-time 5 $u)"
done
~~~

結果：nginx 只監聽 `:80`；HTTP 回 401（連得到、需要 Token），HTTPS 為 000。暫用 HTTP，Token 會以明文在內網傳送；Token 屬唯讀使用者，列為待改善（LibreNMS 啟用 HTTPS）。瀏覽器直接開 API 網址會顯示 `{"message":"Unauthenticated."}`，代表 API 有要求驗證，屬正常。

## 3. 唯讀使用者與 API Token

**使用者**：LibreNMS 管理員登入 → 齒輪 → Manage Users → Add User：`grafana`，Role **Global Read**（Normal User 只看得到被指派的設備；Admin 權限過大），密碼存入密碼管理器。以該帳號登入可見 Roles 為 Global Read、Device Permissions 為 Global Viewing Access。

**Token**：LibreNMS 26 的「建立新的 API 存取權杖」視窗**沒有選擇使用者的欄位**，Token 會屬於目前登入的帳號（管理員）；Global Read 帳號的選單也沒有 API 頁面。因此不在畫面上建立。

新版改用 Laravel Sanctum（資料表 `personal_access_tokens`，舊的 `api_tokens` 已不存在；`app/Models/User.php` 有 `use HasApiTokens`），可直接呼叫 LibreNMS 自己的 `createToken()`，由程式產生並以雜湊儲存：

~~~bash
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
~~~

- Token 格式為「編號|字串」，整串（含編號與 `|`）存入密碼管理器，只顯示一次；程式檔本身不含 Token。
- 確認擁有者為 `grafana`、到期日為一年後（2027-10-14）。

從 Grafana 容器測試（`read -s` 輸入，不留在指令歷史）：

~~~bash
read -s -p "LibreNMS token: " T; echo
curl -s -H "X-Auth-Token: $T" "http://librenms.<網域>/api/v0/devices" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('status'), d.get('count'))"
curl -s -H "X-Auth-Token: $T" "http://librenms.<網域>/api/v0/devices?type=down" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('status'), d.get('count'))"
curl -s -o /dev/null -w '%{http_code}\n' -X POST -H "X-Auth-Token: $T" -H 'Content-Type: application/json' -d '{}' "http://librenms.<網域>/api/v0/devices"
unset T
~~~

結果：全部 16 台、斷線 0、寫入測試 **403**（空內容不會新增任何東西；若回 400／422 代表權限檢查放行，應停止）。Sanctum Token 仍可用 `X-Auth-Token` header。

## 4. Infinity 資料來源

Connections → Add new connection → Infinity → Install → Add new data source：

| 欄位 | 設定 |
| --- | --- |
| Name | `LibreNMS` |
| Auth type | API Key Value pair：Key `X-Auth-Token`、Value 為 Token、Add to **Header** |
| **Allowed hosts** | `http://librenms.<網域>`：Token 只會送往清單內的網址，查詢打錯網址也不會外送 |

## 5. 面板

| 面板 | 查詢 | 設定 |
| --- | --- | --- |
| 斷線設備（LibreNMS） | JSON／Parser **JSONata**／URL `.../api/v0/devices?type=down`；Columns：selector `count`（Number） | Stat；Calculation Last \*；No value 0；綠、≥1 紅 |
| 設備清單（LibreNMS） | JSON／JSONata／URL `.../api/v0/devices`；**Rows／Root `devices`**；Columns：`hostname`、`status`（Number）、`uptime`（Number）、`os` | Table；狀態 Value mappings 1→Up 綠、0→Down 紅，Cell type Colored background；上線時間 Unit **duration (s)** |

- 新版 Infinity 的 Parser 分成 Backend（JSONata、JQ）與 Frontend 兩類，沒有名為「Backend」的單一選項。
- 「斷線設備」直接讀 API 的 `count`，沒有斷線時拿到的是真正的 0。驗證方式：暫時把 URL 改成不含 `?type=down`，應顯示 16（紅），改回後為 0。
- 沒設 Rows／Root 時，整個回應被當成一列（`count`、`devices`、`status` 三欄）；設成 `devices` 後每台設備一列。
- `uptime` 單位是秒；選 duration (ms) 會少 1000 倍。
- 點表格「狀態」欄標題排序，Down 會排在最上面。

驗收：16 列皆為 Up；上線時間合理（grafana 1 day、多數 2 days）。表格上 melayu17 只有 1 hour，查證為當天更新 DSM 後重開，屬預期。

**「系統」欄顯示 proxmox**：LXC 容器與 PVE 主機共用 kernel，SNMP 回報的 `version` 都是 `7.0.14-23-pve`，LibreNMS 因此把容器的 `os` 判斷為 proxmox。實際發行版在 `features` 欄（由 snmpd 的 `extend distro` 回報）：

~~~bash
pct exec 102 -- mysql librenms -e "select hostname, os, version, features, hardware from devices order by hostname;"
~~~

以 `snmp-v3-add.sh` 加入的主機有值（如 Ubuntu 24.04、Debian 13.7、Debian 12.15）；adguard、pihole、wireguard 與三台 PVE 節點為空（推測 snmpd 設定沒有 `extend distro`，待確認）；NAS 為 dsm、無此欄。

## 6. 發現：jt-ipam 的 LibreNMS Token 屬於 admin

`personal_access_tokens` 只有兩筆：`admin` 的 `jt-ipam`（不過期）與 `grafana` 的 `Grafana war room`。jt-ipam 主機若被入侵，該 Token 可修改 LibreNMS 任何設定。jt-ipam 的「自動加入監控」功能可能需要寫入權限，暫不更動，列為待評估。

## 還原

~~~bash
pct exec 102 -- mysql librenms -e "delete t from personal_access_tokens t join users u on u.user_id=t.tokenable_id where u.username='grafana';"
~~~

再到 LibreNMS 刪除 `grafana` 使用者，並在 Grafana 移除 LibreNMS 資料來源與兩個面板。LibreNMS 本身沒有其他變更。

## 待辦

| 項目 | 狀態 |
| --- | --- |
| LibreNMS 啟用 HTTPS（Token 目前以 HTTP 傳送） | 待改善 |
| 2027-10-14 前更換 Grafana 用的 LibreNMS Token | 長期追蹤 |
| 評估 jt-ipam 改用權限較小的 LibreNMS 使用者 | 待評估 |
| 「目前告警」面板（`/api/v0/alerts?state=1`） | 可擴充 |
| 設備清單「系統」欄：LXC 與 PVE 節點都顯示 proxmox（見下方說明），改為「類型」（`os`）＋「發行版」（`features`） | 待做 |
| adguard、pihole、wireguard、node10～12 的 `features` 為空，補 `extend distro` | 待做 |

## 參考資料

- [LibreNMS：API Authentication](https://docs.librenms.org/API/)
- [LibreNMS：API Devices](https://docs.librenms.org/API/Devices/)
- [Laravel Sanctum：API Token Authentication](https://laravel.com/docs/sanctum#api-token-authentication)
- [Grafana Infinity data source](https://grafana.com/docs/plugins/yesoreyeram-infinity-datasource/latest/)
