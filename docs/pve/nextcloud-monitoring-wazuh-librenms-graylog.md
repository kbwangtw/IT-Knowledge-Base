---
layout: default
title: "Nextcloud Server 監控與日誌（二）：Wazuh、LibreNMS 與 Graylog"
date: 2026-11-06
categories: [PVE, Nextcloud, Wazuh, LibreNMS, Graylog]
permalink: /docs/pve/nextcloud-monitoring-wazuh-librenms-graylog/
last_modified_at: 2026-11-06
---
{% raw %}

# Nextcloud Server 監控與日誌（二）：Wazuh、LibreNMS 與 Graylog

> **一句話**：Nextcloud 架好之後，要有人「看著它」：Wazuh 看資安事件（登入、sudo、設定檔變更），LibreNMS 看可用性與資源（在不在線、磁碟快不快滿），Graylog 集中收日誌（主機與四個容器）。這篇把上篇的 Nextcloud VM 接進這三套既有的監控系統。

| 項目 | 內容 |
| --- | --- |
| 適合誰看 | 已經有 Wazuh、LibreNMS、Graylog，要把一台新的 Linux VM（含 Docker 容器）納管的人 |
| 環境 | Nextcloud VM 115（Ubuntu 24.04，跑在 node11，Docker Compose）；Wazuh 4.14.9（All-in-one，LXC）；LibreNMS 26.10.0（CT 102，跑在 node12）；Graylog 的 Syslog UDP 1514 Input |
| 日期 | 2026-11-06 |
| 結論 | ✅ Wazuh Agent 註冊 Active，事件進 Dashboard；✅ 主機 syslog 與四個容器的日誌都進 Graylog，`source` 與 `application_name` 欄位正確；✅ LibreNMS 以 SNMPv3（SHA／AES）納管，輪詢與探索成功，動態群組自動歸類；⏳ Wazuh 監控 Nextcloud 設定檔與登入失敗、SNMP 來源限制留待對外開放前 |
| 上篇 | [在 PVE 用 VM + Docker Compose 架設 Nextcloud Server（一）：建立、部署、備份與還原演練](https://kbwangtw.github.io/IT-Knowledge-Base/docs/pve/nextcloud-vm-docker-compose-sop/) |
| 相關文章 | [Wazuh 部署（Agent 安裝）](https://kbwangtw.github.io/IT-Knowledge-Base/docs/pve/wazuh-lxc-ubuntu2204-sop/)、[Wazuh 維運與 LibreNMS 納管](https://kbwangtw.github.io/IT-Knowledge-Base/docs/pve/wazuh-lxc-ubuntu2204-operations/)、[Graylog 日誌收集](https://kbwangtw.github.io/IT-Knowledge-Base/docs/pve/proxmox-graylog-syslog-pipeline-sop/)、[LibreNMS 戰情中心](https://kbwangtw.github.io/IT-Knowledge-Base/docs/pve/grafana-war-room-librenms/) |

> 文中 IP 都是文件示範位址（192.0.2.0/24），`<網域>`、`<管理帳號>` 等 `<…>` 的內容**要整段換成自己的值**（連角括號一起換掉）。帳號、密碼、金鑰不寫在文章裡。

**這篇怎麼讀**：第 1～3 節弄懂名詞與注意事項；第 4 節起每步都是「做什麼 → 怎麼做 → 應該看到什麼」；出問題看第 5 節。

## 1. 先認識幾個名詞

| 名詞 | 白話解釋 |
| --- | --- |
| **Wazuh Agent／Manager** | Agent 裝在被監控的主機上收集事件；Manager 集中分析、產生告警。**Agent 版本不能高於 Manager** |
| **SNMP** | 監控系統向設備「問狀態」的標準協定；本環境一律用 **SNMPv3 authPriv**（驗證＋加密） |
| **snmpd** | Linux 上回答 SNMP 查詢的服務 |
| **LibreNMS 設備（device）** | 被監控的一台機器；`device_id` 是它的編號 |
| **動態群組（dynamic group）** | 依規則（例如作業系統、kernel 字串）自動把設備歸類，新設備符合規則就自動加入 |
| **Graylog Input／Stream** | Input 是收件口（UDP 1514）；Stream 是把相關訊息歸在一起的「資料夾」 |
| **syslog logging driver** | Docker 內建的日誌輸出方式，由 Docker 主程式直接把容器日誌送到 syslog 伺服器 |
| **RFC 3164／RFC 5424** | 兩種 syslog 訊息格式；5424 有明確的主機名稱與應用程式名稱欄位 |
| **tag** | Docker 在每筆日誌上附的名稱，用來辨識是哪個容器 |
| **維護模式** | 讓 Nextcloud 暫時顯示「維護中」，重建容器時使用者看到的是維護頁而不是錯誤 |

## 2. 全貌

```text
【Nextcloud VM 115】
 ├─ Wazuh Agent ──── TCP 1514／1515 ───────▶ Wazuh Manager（資安事件）
 ├─ rsyslog（主機 auth.log、sudo、systemd…）─┐
 ├─ Docker syslog driver（app／cron／db／redis）─┴─ UDP 1514 ─▶ Graylog Input「Syslog UDP」
 │                                                              → Stream「Infrastructure Syslog」
 └─ snmpd（SNMPv3 authPriv，UDP 161）◀──── LibreNMS 輪詢（CT 102，節點 node12）
                                              └─ 動態群組 Virtual_Group 自動歸類
```

## 3. 開工前先決定的事（風險與盲點）

| 項目 | 說明 |
| --- | --- |
| 先監控「主機」，不要在容器裡裝 Agent | 容器不可變，重建就消失；主機層的 Agent 就看得到 Docker 與登入事件，容器日誌改走 Docker 的 syslog driver |
| `<…>` 占位字不能原封不動貼上 | 實際踩過：指令裡的 `<Wazuh IP>` 沒換成 IP，Wazuh 把它當成兩個 Manager，寫壞設定檔（5-1） |
| UDP 會遺失 | Graylog 重啟或停機期間，UDP 送來的日誌會遺失；Docker 的 syslog driver 選 UDP 是因為 Graylog 不在時**不會卡住容器啟動**（改 TCP 的話容器可能起不來） |
| VM 本機防火牆沒開 | `ufw` 是 inactive，UDP 161 沒有來源限制。SNMPv3 需要帳密，風險較低，但對外開放前要用 PVE Firewall 限制只有 LibreNMS 能連 |
| 這台 VM 不是 LXC | 既有的 `snmp-v3-add.sh CTID` 用 `pct exec`，進不去 VM；這台只收 SSH 金鑰，也沒有 root 登入，所以改用「SSH 連進去 + `sudo`」的做法 |
| LibreNMS 26.10 的資料表結構改了 | 實測 `devices` 資料表**沒有** `authpass`、`cryptopass`、`snmpver`、`authlevel` 欄位（`ERROR 1054 Unknown column`），既有文件裡讀取這些欄位的腳本已失效。本篇改成每台自己產生隨機密碼，不讀資料庫（5-3） |
| 每台獨立的 SNMPv3 密碼 | LibreNMS 的 SNMP 演算法與密碼以設備為單位設定，這台的密碼和其他主機不同，也比共用一組安全；密碼只存在 LibreNMS 內部，事後看不到，要換就重跑腳本 |

## 4. 進度表

| # | 步驟 | 狀態 | 實測紀錄 |
| --- | --- | --- | --- |
| 5-1 | Wazuh Agent | ✅ | Agent ID 020、名稱 `nextcloud`、狀態 Active；`sudo` 事件在 Dashboard 看到規則 5402、5501 |
| 5-2 | 主機 syslog → Graylog | ✅ | `GRAYLOG_TEST` 測試訊息在 Graylog 搜尋到 |
| 5-3 | LibreNMS（SNMPv3） | ✅ | device 27；`Snmpget[2/0.03s]`；探索 45.154 秒；Virtual_Group 由 14 台變 15 台 |
| 5-4 | 容器日誌 → Graylog | ✅ | `source` 為主機名稱、`application_name` 為容器名稱；9 筆訊息（含 Apache 存取日誌） |

## 5. 步驟

### 5-1 安裝 Wazuh Agent

**做什麼**：在 VM 上安裝與 Manager 同版本（4.14.9）的 Agent。沿用既有做法：下載 `.deb` 用 `dpkg -i`，**不加 Wazuh 套件庫**，日後 `apt upgrade` 不會連帶升級 Agent。

**怎麼做**（`<Wazuh IP>` 請換成真實的 Manager IP，文中示範為 192.0.2.32）：

先確認連得到 Manager：

```bash
timeout 3 bash -c '</dev/tcp/192.0.2.32/1514' && timeout 3 bash -c '</dev/tcp/192.0.2.32/1515' && echo "port OK"
```

安裝：

```bash
cd /tmp
wget https://packages.wazuh.com/4.x/apt/pool/main/w/wazuh-agent/wazuh-agent_4.14.9-1_amd64.deb
sudo WAZUH_MANAGER='192.0.2.32' dpkg -i ./wazuh-agent_4.14.9-1_amd64.deb
sudo grep -c '<server>' /var/ossec/etc/ossec.conf
sudo grep -A3 '<server>' /var/ossec/etc/ossec.conf
sudo systemctl daemon-reload
sudo systemctl enable --now wazuh-agent
systemctl is-active wazuh-agent
sudo tail -n 20 /var/ossec/logs/ossec.log | grep -iE "connected|enroll|error"
rm -f /tmp/wazuh-agent_4.14.9-1_amd64.deb
```

| 片段 | 意思 |
| --- | --- |
| `sudo WAZUH_MANAGER=... dpkg -i` | 變數寫在 `sudo` **後面**才會傳進 `dpkg`；寫在前面可能被 sudo 過濾掉 |
| `grep -c '<server>'` | `<server>` 區塊必須剛好 **1** 個，`<address>` 是真實 IP |
| `systemctl enable --now` | Wazuh 套件安裝後**不會自動啟動**，要手動啟動並設為開機啟動 |
| 最後一行的 `grep -iE` | 只留含 connected、enroll、error 的行，看 Agent 有沒有連上、有沒有自動註冊成功 |

**應該看到**：`port OK`、`<server>` 數量 1、`<address>` 是 Manager IP、`active`；log 有 `Connected to the server ([192.0.2.32]:1514/tcp)`。在 **Wazuh Manager** 上確認：

```bash
/var/ossec/bin/agent_control -ls | grep -i nextcloud
```

**應該看到**：`020,nextcloud,any,Active,`（IP 欄位 `any` 是自動註冊的預設，不是問題；Agent 名稱沿用 VM 的 hostname）。

**端到端驗證**：這台 VM 的 `sudo` 不需要密碼（Cloud-Init 建立的使用者預設如此），所以無法用「輸入錯誤密碼」製造失敗事件，改用成功的 `sudo` 本身：

```bash
sudo -k
sudo ls
```

到 Wazuh Dashboard：**Threat intelligence → Threat Hunting → Events**，搜尋 `agent.name:nextcloud`，時間範圍選 Last 15 minutes。

**應該看到**：

| 時間 | 描述 | 等級 | 規則 |
| --- | --- | --- | --- |
| 15:31:17.484 | `Successful sudo to ROOT executed.` | 3 | 5402 |
| 15:31:17.485 | `PAM: Login session opened.` | 3 | 5501 |

整條路徑（`auth.log` → Agent → Manager → Indexer → Dashboard）都通了。

### 5-2 主機 syslog 送到 Graylog

**做什麼**：用 rsyslog 把主機日誌（登入、sudo、systemd、dockerd 本身的訊息）以 UDP 送到 Graylog 的 1514。Ubuntu 24.04 cloud image 預設已有 rsyslog。

**怎麼做**（`GL` 換成真實的 Graylog IP，**純 IP，不要角括號或空白**）：

```bash
systemctl is-active rsyslog
GL='192.0.2.24'
echo "$GL"
echo "*.* @${GL}:1514" | sudo tee /etc/rsyslog.d/60-graylog.conf
cat /etc/rsyslog.d/60-graylog.conf
sudo rsyslogd -N1
```

確認設定檔內容是 `*.* @<Graylog IP>:1514`、`rsyslogd -N1` 結尾是 `End of config validation run. Bye.` 之後才重啟：

```bash
sudo systemctl restart rsyslog
systemctl is-active rsyslog; systemctl is-enabled rsyslog
logger -t GRAYLOG_TEST "nextcloud syslog test $(date +%s)"
```

| 片段 | 意思 |
| --- | --- |
| `@`（一個） | UDP；兩個 `@@` 是 TCP |
| `rsyslogd -N1` | 只檢查語法不重啟，語法錯誤會在這步擋下 |
| `60-graylog.conf` | rsyslog 依檔名順序載入，`60` 排在預設的 `50-default.conf` 之後，本機日誌照常寫入 |
| `logger -t GRAYLOG_TEST` | 產生一筆測試訊息 |

**應該看到**：`active`、`enabled`。在 Graylog 搜尋 `source:nextcloud AND GRAYLOG_TEST`（時間範圍最近 5～15 分鐘）找到訊息，點開確認 **Received by** 是 Syslog UDP 1514、**Routed into streams** 是 Infrastructure Syslog。查不到時，用 Graylog 的 Inputs → 該 Input → Input Diagnosis 看有沒有收到封包。

### 5-3 LibreNMS：用 SNMPv3 納管

**做什麼**：在 VM 安裝 snmpd，建立唯讀的 SNMPv3 使用者（SHA／AES），再用同一組密碼加進 LibreNMS。所有節點端的步驟都在**LibreNMS 容器所在的 PVE 節點**執行（本環境 CT 102 在 node12），不是在容器裡，也不一定是 VM 所在的節點：腳本要用 `pct exec`、`pct pull`，而 `pct` 只能操作本節點的容器。

**5-3a 準備：臨時 SSH 金鑰**

VM 只收金鑰登入，所以建一把用完就刪的臨時金鑰（在 LibreNMS 所在節點）：

```bash
pct status 102
ssh-keygen -t ed25519 -N '' -C nc-temp -f /root/.ssh/nc-temp
cat /root/.ssh/nc-temp.pub
```

`pct status 102` 應為 `running`（確認在對的節點）。把 `nc-temp.pub` 那一行（公鑰）用 SSH 登入 VM 後加進授權清單：

```bash
echo '貼上那一整行公鑰' >> ~/.ssh/authorized_keys
```

回到 LibreNMS 節點測試連線與 sudo：

```bash
ssh -i /root/.ssh/nc-temp -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new <管理帳號>@192.0.2.34 'echo ssh-ok; sudo -n true && echo sudo-nopasswd || echo sudo-needs-password'
```

**應該看到**：`ssh-ok` 與 `sudo-nopasswd`。若是 `sudo-needs-password`，腳本用 `ssh -t`，過程中會問一次 sudo 密碼。

**5-3b 建立腳本**（在 LibreNMS 所在節點）

這支腳本依既有的 `snmp-v3-add.sh` 改寫：改成 SSH 連線，**密碼改成腳本自己隨機產生**，並直接呼叫 `lnms device:add` 加入設備。密碼只存在變數裡，不印出、不寫入檔案。

```bash
cat > /root/snmp-v3-add-vm.sh <<'ADDEOF'
#!/bin/bash
# Install snmpd on a standalone VM over SSH (user + sudo) with a NEW random SNMPv3 user (SHA/AES) and add it to LibreNMS; secrets are never printed
set -e
TARGET=$1; LOC=$2; LNMS_HOST=$3
[ -n "$TARGET" ] && [ -n "$LOC" ] && [ -n "$LNMS_HOST" ] || { echo "usage: $0 user@host Location lnms-hostname"; exit 1; }
SSH_OPTS="-i /root/.ssh/nc-temp -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new"
umask 077
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
AP=$(openssl rand -base64 24 | tr -d '/+=')
PP=$(openssl rand -base64 24 | tr -d '/+=')
CONTACT=$(pct exec 102 -- grep -m1 '^syscontact' /etc/snmp/snmpd.conf || true)
pct pull 102 /usr/bin/distro $T/distro
printf 'agentAddress udp:161\nrouser snmpuser priv\nsyslocation %s\n%s\nextend distro /usr/bin/distro\n' "$LOC" "$CONTACT" > $T/snmpd.conf
printf 'createUser snmpuser SHA "%s" AES "%s"\n' "$AP" "$PP" > $T/cu
cat > $T/install.sh <<'EOS'
#!/bin/bash
set -e
D=$1
sudo apt-get update -qq
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq snmpd >/dev/null
sudo systemctl stop snmpd
[ -f /etc/snmp/snmpd.conf.bak-orig ] || sudo cp -a /etc/snmp/snmpd.conf /etc/snmp/snmpd.conf.bak-orig
sudo install -m 600 -o root -g root $D/snmpd.conf /etc/snmp/snmpd.conf
sudo install -m 755 -o root -g root $D/distro /usr/bin/distro
sudo mkdir -p /var/lib/snmp
sudo rm -f /var/lib/snmp/snmpd.conf
sudo bash -c "cat $D/cu >> /var/lib/snmp/snmpd.conf"
sudo chown Debian-snmp:Debian-snmp /var/lib/snmp/snmpd.conf 2>/dev/null || true
sudo systemctl enable snmpd >/dev/null 2>&1
sudo systemctl restart snmpd
sleep 2
echo "snmpd=$(systemctl is-active snmpd) usmUser=$(sudo grep -c ^usmUser /var/lib/snmp/snmpd.conf) createUser=$(sudo grep -c ^createUser /var/lib/snmp/snmpd.conf) udp161=$(ss -ulnp | grep -c ':161 ')"
EOS
scp -q $SSH_OPTS -r "$T" "$TARGET:/tmp/snmpadd"
ssh -t $SSH_OPTS "$TARGET" 'bash /tmp/snmpadd/install.sh /tmp/snmpadd; rc=$?; rm -rf /tmp/snmpadd; exit $rc'
pct exec 102 -- su - librenms -s /bin/bash -c "lnms device:add -3 -u snmpuser -a SHA -A '$AP' -x AES -X '$PP' $LNMS_HOST" 2>&1 | grep -v -- "$AP" | grep -v -- "$PP" || true
unset AP PP
pct exec 102 -- mysql librenms -e "select device_id, hostname from devices where hostname='$LNMS_HOST';"
ADDEOF
chmod 700 /root/snmp-v3-add-vm.sh
bash -n /root/snmp-v3-add-vm.sh && echo "語法 OK"
```

| 片段 | 意思 |
| --- | --- |
| `openssl rand ... tr -d '/+='` | 隨機產生密碼並去掉特殊字元，避免引號出問題 |
| `rouser snmpuser priv` | 唯讀使用者，**必須加密**（authPriv），沒有 v2c community |
| `extend distro /usr/bin/distro` | 回報真正的發行版，動態群組與設備清單的「發行版」欄位靠它 |
| `createUser ... SHA ... AES` | 寫入 `/var/lib/snmp/snmpd.conf`；snmpd 啟動時轉成 `usmUser` 並刪掉含明文密碼的那一行，所以驗證 `createUser=0` |
| `rm -f /var/lib/snmp/snmpd.conf` | 重跑腳本時先清掉舊的 `usmUser`，避免舊金鑰衝突，**重跑是安全的** |
| `SNMPv3 金鑰依 engineID 本地化` | 不能複製別台的 `/var/lib/snmp/snmpd.conf`，每台都要重新建立帳號 |
| `-a SHA`、`-x AES` | `lnms device:add` 的 `-a` 預設是 MD5，**必須明確指定 SHA**；`-3 -u -A -x -X` 在 LibreNMS 26.10 的 `--help` 都仍存在 |
| 最後的 `select device_id, hostname` | 只選這兩個欄位，避開 26.10 已改版的欄位 |

**應該看到**：`語法 OK`。

**5-3c 執行**

`Location` 沿用既有慣例填 VM 所在節點名稱，最後一個參數是 LibreNMS 裡的主機名稱（DNS 要先解析得到，兩台 DNS 都要有 A record）：

```bash
pct exec 102 -- getent hosts nextcloud.<網域>
/root/snmp-v3-add-vm.sh <管理帳號>@192.0.2.34 Node11 nextcloud.<網域>
```

**應該看到**：安裝過程後出現 `snmpd=active usmUser=1 createUser=0 udp161=1`，接著 `Added device nextcloud.<網域> (27)` 與一列 `device_id`（本案 27）。中間 `Scanning processes... / Scanning linux images...` 是 VM 上 `apt` 安裝後 `needrestart` 的檢查訊息，正常。

**5-3d 驗證：輪詢與探索**

```bash
pct exec 102 -- su - librenms -s /bin/bash -c "lnms device:poll 27 -m core"
pct exec 102 -- su - librenms -s /bin/bash -c "lnms device:discover 27"
```

**應該看到**：輪詢有 `Snmpget[2/0.03s]`、沒有逾時，`OS: linux`，既有的告警規則（設備連／斷線、磁碟使用率 ≥ 90%）已套用；探索約 45 秒（本案 45.154 秒，110 次 SNMP 查詢都有回應，沒有逾時）。探索結尾幾行：

```text
>>> Discovered <主機名稱> (27) in 45.154 seconds <<<
```

網頁上設備應顯示 Linux（kernel `6.8.0-149-generic`）、發行版 Ubuntu 24.04，狀態 Up。

**5-3e 收尾（務必做）**

臨時金鑰一定要刪，不要留一把能進 VM 的免密碼金鑰在節點上。**順序要在 LibreNMS 驗證完成之後**。LibreNMS 節點：

```bash
rm -f /root/.ssh/nc-temp /root/.ssh/nc-temp.pub
ls /root/.ssh/ | grep -c nc-temp
```

VM：

```bash
sed -i '/nc-temp/d' ~/.ssh/authorized_keys
grep -c nc-temp ~/.ssh/authorized_keys
```

**應該看到**：兩個計數都是 `0`。

**5-3f 動態群組：用 `os equal linux` 自動歸類**

環境的 `Virtual_Group` 規則原本是「`devices.sysDescr` contains `-pve` AND `devices.features` not contains `PVE`」，靠 LXC 與 PVE 共用 kernel 抓 LXC；**有自己 kernel 的 VM 不符合**（nextcloud 的 kernel 是 `6.8.0-149-generic`，沒有 `-pve`），所以這台一開始**不屬於任何群組**。先用唯讀查詢確認各種 `os` 的分布：

```bash
pct exec 102 -- mysql librenms -e "SELECT os, COUNT(*) AS cnt, GROUP_CONCAT(hostname SEPARATOR ', ') AS hosts FROM devices GROUP BY os;"
```

本案結果：

| `os` | 台數 | 主機 |
| --- | --- | --- |
| `dsm` | 2 | Synology NAS |
| `linux` | 1 | nextcloud |
| `ping` | 3 | DC01、DC02、CA（Ping only） |
| `proxmox` | 14 | 3 台 PVE 節點、LXC、PBS |

`linux` 只有這台 VM，所以在 `Virtual_Group` **最上層**多加**一條**規則，之後任何用 SNMP 加入、`os` 為 `linux` 的新 VM 都會自動進群組，不必每台寫一條 `sysName`：

```text
最上層 OR
  ├─ devices.sysName equal dc01.<網域>
  ├─ devices.sysName equal dc02.<網域>
  ├─ devices.sysName equal ca.<網域>
  ├─ devices.os equal linux                     ← 新增
  └─ 子群組 AND：devices.features doesn't contain PVE  AND  devices.sysDescr contains -pve   ← 原規則，不動
```

操作：Devices → Manage Groups → `Virtual_Group` → Edit → 最上層 Add rule（`devices.os` / `equal` / `linux`，**要在最上層，不是子群組裡**）→ 確認最上層是 **OR** → 儲存。再用輪詢讓 LibreNMS 重新計算群組並查成員：

```bash
pct exec 102 -- su - librenms -s /bin/bash -c "lnms device:poll 27 -m core" | grep -iE "polled|Device Groups"
pct exec 102 -- mysql librenms -e "SELECT g.name, COUNT(*) AS cnt, GROUP_CONCAT(d.hostname SEPARATOR ', ') AS hosts FROM device_group_device gd JOIN device_groups g ON g.id=gd.device_group_id JOIN devices d ON d.device_id=gd.device_id GROUP BY g.name;"
```

**應該看到**：`Virtual_Group` 由 14 台變 **15 台**（多了 nextcloud）；`Physical_Group`（3 台 PVE 節點）與 `Storage_Group`（2 台 NAS）不變。

**限制**：`os equal linux` 也會抓到將來加入的「裸機 Linux」（目前沒有這類設備），到時再加排除條件。Ping only 的 DC 仍靠原本逐台的 `sysName` 規則。

**為什麼同樣是 Ubuntu 24.04，有的顯示 `proxmox pve`、有的顯示 `Linux`**：LibreNMS 看 SNMP 回報的 kernel 版本判斷作業系統。LXC 容器和 PVE 宿主機共用 kernel，回報的是宿主機的 `...-pve`，所以顯示 `proxmox pve`；VM 有自己獨立的 kernel，顯示一般的 `Linux`。括號裡的 `Ubuntu 24.04` 來自 `extend distro`，兩邊都是真實的發行版。

### 5-4 Docker 容器日誌送到 Graylog

**做什麼**：四個容器的日誌（Apache 存取日誌、資料庫、Redis、cron）用 Docker 內建的 syslog driver，由 Docker 主程式直接以 UDP 送到 Graylog 的 1514，不經過 VM 的 rsyslog（所以和 5-2 不會重複）。

**怎麼做**：

```bash
cd /opt/nextcloud
GL='192.0.2.24'
cp compose.yaml compose.yaml.bak-logging
[ "$(grep -c '^    restart: unless-stopped$' compose.yaml)" = 4 ] && echo "pattern OK" || echo "STOP: pattern mismatch"
```

必須看到 `pattern OK`（四個服務各有一行 `restart: unless-stopped`）才繼續，`GL` 換成真實 IP：

```bash
cat > /tmp/x-logging.yaml <<EOF
x-logging: &syslog-logging
  driver: syslog
  options:
    syslog-address: "udp://${GL}:1514"
    syslog-format: rfc5424micro
    tag: "{{.Name}}"

EOF
cat /tmp/x-logging.yaml compose.yaml > /tmp/compose.new && cp /tmp/compose.new compose.yaml
sed -i 's/^    restart: unless-stopped$/&\n    logging: *syslog-logging/' compose.yaml
rm -f /tmp/x-logging.yaml /tmp/compose.new
sudo docker compose config --quiet && echo "語法 OK"
grep -n "logging" compose.yaml
```

| 片段 | 意思 |
| --- | --- |
| `x-logging: &syslog-logging` | 定義一份共用的日誌設定（YAML 錨點），四個服務共用，只需維護一處 |
| `syslog-format: rfc5424micro` | RFC 5424 格式（含主機名稱欄位，時間到微秒）。**不設定會用預設格式，Graylog 會把 tag 誤當成 `source`**（見第 6 節） |
| `tag: "{{.Name}}"` | 用容器名稱當 tag，例如 `nextcloud-app-1`；容器名稱已含 Compose 專案前綴，**不要再加自己的前綴**，否則變成 `nextcloud-nextcloud-app-1` |
| `sed ... &\n    logging: *syslog-logging` | 在每個服務的 `restart:` 後面加一行引用共用設定 |

**應該看到**：`語法 OK`；`grep -n "logging"` 共 5 行（1 行定義、4 行 `logging: *syslog-logging`）。此時**只改了檔案**，容器還在跑舊設定。

重建容器會讓網站中斷數十秒，先開維護模式：

```bash
occ() { sudo docker compose -f /opt/nextcloud/compose.yaml exec -u www-data app php occ "$@"; }
occ maintenance:mode --on
sudo docker compose up -d
sudo docker compose ps
curl -sI http://localhost/ | head -n 1
sudo docker compose logs --tail=3 app
```

**應該看到**：`Maintenance mode enabled`；四個容器 `Recreated` 後 `Started`、都 `Up`（`db` 要等 10～30 秒變 `(healthy)`）；`curl` 回 `HTTP/1.1 503 Service Unavailable`（維護中）；`docker compose logs` 仍讀得到最近幾行（Docker 的「雙重記錄」讓改用 syslog driver 後本機仍保留一份）。

到 Graylog 搜尋（時間範圍最近 5 分鐘）：

```text
source:nextcloud AND application_name:nextcloud-app-1
```

**應該看到**：`source` 是 `nextcloud`（主機名稱）、`application_name` 是 `nextcloud-app-1`；有 `"HEAD / HTTP/1.1" 503 ... "curl/8.5.0"` 的 Apache 存取日誌，以及 Apache 啟動的 `AH00094`、`AH00163`、`Using Redis as PHP session handler` 等（本案共 9 筆）。確認後關閉維護模式：

```bash
occ maintenance:mode --off
curl -sI http://localhost/ | head -n 1
sudo docker compose ps
occ status | grep -E "installed|maintenance"
```

**應該看到**：`Maintenance mode disabled`、`HTTP/1.1 302 Found`、四個容器 `Up`（`db` 為 `healthy`）、`installed: true`、`maintenance: false`；瀏覽器能正常登入。

**搜尋提醒**：Graylog 會把 `nextcloud-app-1` 拆成 `nextcloud`、`app`、`1` 三個詞分別比對，直接搜這串會抓到一堆無關的主機日誌（`sudo`、`systemd-networkd`、`ceph-mon`…）。要找特定容器，用欄位查詢 `application_name:nextcloud-app-1`。

## 6. 常見問題

| 現象 | 怎麼辦 |
| --- | --- |
| `wazuh-agent` 起不來，`systemctl status` 顯示 `control process exited with error code`；`ossec.log` 有 `ERROR: (1226): Error reading XML file 'etc/ossec.conf' (line 0)` | 看 `sudo grep -A3 '<server>' /var/ossec/etc/ossec.conf`。本案實際原因：指令的 `WAZUH_MANAGER` 被填成字面的 `<Wazuh IP>`，安裝程式把空白當分隔、拆成兩個 Manager，寫出 `<address><Wazuh</address>` 與 `<address>IP></address>` 兩個壞掉的 `<server>` 區塊。處理：先 `cp -a` 備份 `ossec.conf`，用 `nano` 把兩個區塊合成**一個** `<server>`（`<address>` 填真實 IP），再 `systemctl restart wazuh-agent`。重跑 `dpkg -i` **不會**改寫位址（環境變數只在全新安裝時套用） |
| `dpkg -i` 顯示 `requires superuser privilege`、或 `--install needs at least one package archive file argument` | 要加 `sudo`，而且後面要接 `.deb` 檔名；套件其實已經安裝，不需要重裝 |
| `/tmp` 出現 `wazuh-agent_...deb.1` | `wget` 跑了兩次，第二次自動改名，可刪 |
| 用輸入錯誤密碼測試 Wazuh，卻沒有提示輸入密碼 | 這台 VM 的 `sudo` 不需要密碼，改看成功的 `sudo` 事件（規則 5402、5501） |
| LibreNMS 腳本讀資料庫時 `ERROR 1054 (42S22) at line 1: Unknown column 'authpass' in 'SELECT'` | LibreNMS 26.10 的 `devices` 資料表已沒有 `authpass`、`cryptopass`、`snmpver`、`authlevel`，既有腳本失效。改用 5-3 的做法：每台自己產生隨機密碼，用 `lnms device:add -3 -u -a -A -x -X` 加入 |
| `pct exec 102` 顯示 `Configuration file ... does not exist` | 你不在 CT 102 所在的節點，`pct` 只能操作本節點的容器；用 `pct status 102` 確認 |
| 腳本重跑 | 安全：會先清掉 `/var/lib/snmp/snmpd.conf` 的舊 `usmUser` 再建立；LibreNMS 若已有該設備，`device:add` 會回報已存在，可到網頁調整或刪除重加 |
| LibreNMS 新設備不在任何動態群組 | 檢查群組規則是否涵蓋該設備的 `os`、`sysDescr`、`features`；VM 有自己的 kernel，不符合依 `-pve` 的規則，需另加條件（5-3f） |
| 設備清單的「位置」欄顯示 `node11`（小寫），我設的是 `Node11` | 原因未確認（可能被 jt-ipam 同步覆蓋），純外觀，不影響監控 |
| 設備的「指標（port）」數是 8，其他主機是 2 | 這台有 Docker：`docker0`、`br-…`、`veth…` 都被當成 port，容器重啟時可能觸發 port down 告警。要不要忽略這些介面，待辦中評估 |
| 設備清單狀態條是橘色 | 我推測是剛開機未滿一天（未確認），其他主機運作超過一天都是綠色，過一天再看 |
| Graylog 搜尋 `nextcloud-app-1` 出現大量無關訊息 | 搜尋詞被拆成三個詞；改用 `application_name:nextcloud-app-1` |
| Graylog 裡容器日誌的 `source` 是 `nextcloud-nextcloud-cron-1[957]:` 這種怪名字 | Docker 預設的 syslog 格式沒有主機名稱欄位，Graylog 把 tag 當成 `source`（推測）。加上 `syslog-format: rfc5424micro` 並重建容器；同時 `tag` 不要加重複前綴 |
| 重建容器後網站短暫連不上 | 預期；先開維護模式再重建（5-4） |

## 7. 目前狀態與待辦

| 範圍 | 狀態 |
| --- | --- |
| Wazuh Agent、事件進 Dashboard | ✅ |
| 主機與容器日誌進 Graylog | ✅ |
| LibreNMS SNMPv3 納管、動態群組 | ✅ |
| Wazuh 監控 Nextcloud 設定檔與登入失敗 | ⏳ 選做，對外開放前再做 |

待辦：

- [ ] Wazuh：FIM 監控 `/opt/nextcloud/`（`compose.yaml`、`.env`）；讀取 `/srv/nextcloud-data/data/nextcloud.log`（JSON）並針對「登入失敗」寫規則（Agent 以 root 執行，可讀資料目錄）
- [ ] SNMP：用 PVE Firewall 限制 UDP 161 只有 LibreNMS 能連；對外開放前一併處理 VM 的入站規則
- [ ] LibreNMS：評估忽略 Docker 的 `veth*`、`br-*` 介面（語法要查 26.10 的文件，**未確認**）
- [ ] 確認設備狀態條在運作一天後變綠
- [x] 既有文件已加註：[Wazuh 維運與 LibreNMS 納管](https://kbwangtw.github.io/IT-Knowledge-Base/docs/pve/wazuh-lxc-ubuntu2204-operations/)的 11-11（`snmp-v3-add.sh`、`snmp-v3-lnms.sh`、Graylog v2c 改 v3 的 `UPDATE`）與 11-12（`snmp-v3-upgrade.sh`、`UPDATE devices SET authalgo…`）在 LibreNMS 26.10 之後已失效，兩節開頭都有警示（2026-11-06）；26.10 之後調整既有設備認證演算法的替代做法**尚未驗證**
- [ ] 驗證 LibreNMS 26.10 之後調整**既有設備**認證演算法的做法（網頁設備設定的 SNMP 分頁，或官方 CLI／API），驗證後補回上述文件
- [ ] 觀察 Graylog 索引大小：`app` 容器每個請求一筆日誌，使用者增加後留意
- [ ] 評估是否要為這台 VM 的日誌補 Graylog Pipeline 規則（目前進 Infrastructure Syslog Stream，但沒有針對 Linux VM 或 Docker 的分類欄位）

## 8. 延伸閱讀

- [Wazuh 文件：Agent 安裝](https://documentation.wazuh.com/current/installation-guide/wazuh-agent/index.html)
- [LibreNMS 文件：Adding a device](https://docs.librenms.org/Support/Adding-a-Device/)、[SNMP 設定](https://docs.librenms.org/Support/SNMP-Configuration-Examples/)
- [Docker：syslog logging driver](https://docs.docker.com/engine/logging/drivers/syslog/)
- [Nextcloud Administration Manual](https://docs.nextcloud.com/server/latest/admin_manual/)

{% endraw %}
