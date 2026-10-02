---
layout: default
title: "在 PVE Cluster 用 LXC 架設 Wazuh（Ubuntu 22.04）"
date: 2026-09-29
categories: [PVE, LXC, Wazuh, Security]
permalink: /docs/pve/wazuh-lxc-ubuntu2204-sop/
last_modified_at: 2026-09-30
---

# 在 PVE Cluster 用 LXC 架設 Wazuh（Ubuntu 22.04）

Graylog 負責「把日誌收集起來、查得到」；Wazuh 則多做一層「安全判讀」：主機完整性檢查（FIM）、弱點偵測、設定稽核與入侵告警。本文記錄在 PVE Cluster 上建立一台 Ubuntu 22.04 LXC，以 All-in-one（Indexer + Server + Dashboard 同一台）方式安裝 Wazuh 的步驟。

> 文件狀態：**主要流程已實測**（2026-09-29～09-30）。Step 0～8 完成驗證；Agent 已涵蓋 PVE 節點、Debian 13 與 Ubuntu 容器、Ubuntu VM、Windows 用戶端、網域控制站、CA 與 PBS，共 17 台 Active。7-3 的 PVE 資料中心防火牆屬另案規劃，本文未啟用。

## 進度表

| # | 步驟 | 狀態 | 實測紀錄 |
| --- | --- | --- | --- |
| 0 | 規劃資源與網路 | 已實測 | 2026-09-29：PVE 9.2.20、kernel 7.0.14-19-pve、Quorate: Yes；rootfs 選 VM_Pool（RBD），CT ID 112 |
| 1 | PVE 節點設定 `vm.max_map_count` | 已實測 | 2026-09-29：三台值皆 ≥ 262144 |
| 2 | 下載 Ubuntu 22.04 範本 | 已完成 | 2026-09-29：使用 ubuntu 22.04 範本 |
| 3 | 建立 LXC | 已實測 | 2026-09-29：CT 112 位於 node12；已補 nesting=1、onboot=1，rootfs 線上加大為 80G（見 3-4） |
| 4 | 容器內基本設定 | 已實測 | 2026-09-29：systemd running、79G、8G RAM／512M swap、max_map_count 1048576、IP 與 Gateway 正常；DNS 只回 IPv6，依決定略過 IPv6 測試；時區由 UTC 改為 Asia/Taipei |
| 5 | 安裝 Wazuh All-in-one | 已實測 | 2026-09-30：安裝助手 4.14 `-a` 完成，Indexer／Manager／Filebeat／Dashboard 皆 started，結尾 `Installation finished`（見 5-1） |
| 6 | 驗證服務與登入 Dashboard | 已實測 | 2026-09-30：4 個服務 active、5 個 Port 正常、Filebeat→Indexer OK、Dashboard 以 admin 登入成功（見 6-1） |
| 7 | 安全收尾（密碼、防火牆、鎖定套件庫） | 已實測 | 2026-09-30：7-1 密碼更換完成、Dashboard 新密碼登入 OK；7-2 套件庫已停用；7-3 資料中心防火牆未啟用、另案規劃；7-4 API 只聽 127.0.0.1，外部 55000 已不通、443 正常 |
| 8 | 備份與 HA | 已實測 | 2026-09-30：既有 all 排程已涵蓋；手動備份完成（受保護）；node12→node10 遷移驗證通過；還原測試（CT 114）通過；已加入 HA（ct:112 started） |
| 9 | 接上 Agent | 已實測 | 2026-09-30：三台 PVE 節點（001～003）與 7 台 Debian 13 容器（004～010）、UBClient（011）、WinClient（012）、ai（013）皆 Active；DC02（014）、DC01（015）、ca（016）、pbs31（017）皆 Active，AD／CA 前後檢查一致；共 17 台 |
| 10 | 資料保留 | 已實測 | 2026-10-02：告警索引 ISM 保留 30 天（套用 3 個現有索引）；告警文字檔以 cron 保留 30 天 |
| 11 | 告警調校 | 進行中 | 2026-10-02：找出前 15 名；修正 ai 容器重複的 hermes-gateway 與 IPv6 優先順序，AppArmor 告警與服務失敗告警皆歸零，ai 容器停擺三天的 syslog 恢復 |

## 先認識四個名詞

| 元件 | 白話意思 | 預設 Port |
| --- | --- | --- |
| Wazuh Indexer | 存資料、給人搜尋的資料庫（以 OpenSearch 為基礎） | 9200/tcp（只給本機或叢集內用） |
| Wazuh Server（Manager） | 接收 Agent 資料、套規則、產生告警 | 1514/tcp（Agent 連線）、1515/tcp（Agent 註冊）、55000/tcp（API） |
| Wazuh Dashboard | 網頁介面 | 443/tcp |
| Wazuh Agent | 裝在被監控主機上的小程式 | 主動往 Server 連線 |

~~~text
被監控主機（Agent）──1514/1515 tcp──▶ Wazuh Server ──▶ Wazuh Indexer
                                                          ▲
                                   管理者瀏覽器 ──443──▶ Wazuh Dashboard
~~~

注意：Graylog 在本環境用的是 **UDP** 1514，Wazuh Agent 用的是 **TCP** 1514。兩者在不同容器、不同 IP 時互不影響；若將來想讓 Wazuh 也收 syslog，要另外規劃 Port，避免混淆。

## 0. 規劃資源與網路

### 0-1 建議規格

All-in-one 的 Indexer 是 Java 程式，吃記憶體與磁碟 I/O。以下是本案預定值，Agent 數量增加時要再調整：

| 項目 | 預定值 | 說明 |
| --- | --- | --- |
| CT ID | `<CTID>` | 不可和現有 VM／CT 重複；以叢集查詢結果為準 |
| Hostname | `wazuh` | |
| vCPU | 4 | 官方 All-in-one 最低建議量級；少於 4 核安裝可能被擋 |
| RAM | 8 GiB | Indexer 預設會拿約一半記憶體當 Java heap |
| Swap | 0～512 MiB | 資料庫類服務不建議依賴 swap；pct 的 `--swap` 單位是 MiB |
| Rootfs | 80 GiB 以上 | 告警資料會持續累積；放在叢集共用儲存（如 Ceph RBD）才能遷移／HA |
| 類型 | Unprivileged（非特權） | 安全性較好；本案所需設定都在 PVE 主機端完成 |
| Features | `nesting=1` | Ubuntu 22.04 的 systemd 需要 |
| IP | `192.0.2.32/24`（示範位址） | 請換成自己的；建議固定 IP，Agent 會寫死這個位址 |
| Gateway | `192.0.2.1`（示範位址） | |
| DNS | `192.0.2.20`、`192.0.2.21`（示範位址） | 兩台 DNS，用空白分隔 |
| Agent 數量 | 30 台以內 | 此規模 4 vCPU／8 GiB 足夠；超過再擴充 |

> 官方要求以官方文件為準：[Wazuh Quickstart](https://documentation.wazuh.com/current/quickstart.html)。撰寫本文時無法連線官方頁面核對最新版號與規格表，操作前請先開啟確認。

### 0-2 事前確認清單

在任一 PVE 節點執行，確認 CT ID 未被使用、共用儲存存在且有空間：

~~~bash
pvesh get /cluster/nextid          # 叢集建議的下一個可用 ID
pvesm status                       # 看儲存名稱、類型、剩餘空間
pvecm status                       # 確認叢集 Quorate: Yes
~~~

**CT ID 一定要用叢集查詢確認，不能憑印象。** `nextid` 回傳的是「最小的可用 ID」；例如回傳 114，代表 100～113 可能都已被占用。想用別的號碼時，先查叢集全部資源：

~~~bash
pvesh get /cluster/resources --type vm --output-format json \
  | grep -o '"vmid":[0-9]*' | sort -t: -k2 -n
~~~

**確認 rootfs 儲存允許放容器。** RBD 儲存要在 Content 勾選 `Container`（rootdir）才能放 CT：

~~~bash
pvesm status --content rootdir     # 有列出 VM_Pool 才能選它當 rootfs
grep -A6 '^rbd: VM_Pool' /etc/pve/storage.cfg
~~~

### 0-3 本案實測（2026-09-29）

| 項目 | 結果 |
| --- | --- |
| PVE 版本 | pve-manager 9.2.20，kernel 7.0.14-19-pve |
| 叢集 | Quorate: Yes |
| `nextid` | 114 |
| 可用共用儲存 | VM_Pool（rbd，可用約 1.46 TiB）、cephfs、PBS31（備份用） |
| rootfs 選擇 | VM_Pool |
| CT ID | 112（`nextid` 回傳 114，是因為 112 已被這台新 CT 使用） |
| Swap | 512 MiB |

## 1. PVE 節點設定 `vm.max_map_count`

**為什麼要在主機做？** LXC 和主機共用同一個 Linux kernel。Wazuh Indexer 要求 `vm.max_map_count` 至少 262144，而這個值屬於 kernel，非特權容器裡改不了，只能在 PVE 主機上改。

**為什麼每一台都要做？** 容器將來可能遷移或被 HA 拉到其他節點；只改一台的話，換節點後 Indexer 會起不來。

**先檢查，不夠才設定。** 在 **每一台** PVE 節點執行：

~~~bash
# 1. 看目前值，以及是哪個設定檔給的
sysctl vm.max_map_count
grep -rs max_map_count /etc/sysctl.conf /etc/sysctl.d /run/sysctl.d /usr/lib/sysctl.d

# 2. 只有小於 262144 才寫入
cur=$(sysctl -n vm.max_map_count)
if [ "$cur" -lt 262144 ]; then
  echo "vm.max_map_count=262144" > /etc/sysctl.d/99-wazuh.conf
  sysctl --system > /dev/null
fi

# 3. 確認
sysctl vm.max_map_count
~~~

預期結果：值 ≥ 262144。**原本就更大時什麼都不用做，千萬不要調小。**

### 1-1 本案實測（2026-09-29）

三台節點的 `vm.max_map_count` 均 ≥ 262144，符合 Wazuh Indexer 需求。

## 2. 下載 Ubuntu 22.04 範本

在任一節點執行（範本存在 `local` 這類儲存，若是節點本機儲存，建立 CT 時要選同一節點）：

~~~bash
pveam update
pveam available --section system | grep ubuntu-22.04
# 以上一行列出的實際檔名為準，例如：
pveam download local ubuntu-22.04-standard_22.04-1_amd64.tar.zst
pveam list local
~~~

## 3. 建立 LXC

可以用 GUI（右上角「Create CT」），也可以用指令。指令的好處是參數一目了然、可留存紀錄。

### 3-1 指令方式

先把自己的公鑰放在節點上（例：`/root/.ssh/wazuh_admin.pub`），用金鑰登入，避免在指令歷史留下密碼：

~~~bash
pct create <CTID> local:vztmpl/ubuntu-22.04-standard_22.04-1_amd64.tar.zst \
  --hostname wazuh \
  --cores 4 \
  --memory 8192 \
  --swap 512 \
  --rootfs VM_Pool:80 \
  --net0 name=eth0,bridge=vmbr0,ip=192.0.2.32/24,gw=192.0.2.1 \
  --nameserver "192.0.2.20 192.0.2.21" \
  --unprivileged 1 \
  --features nesting=1 \
  --ostype ubuntu \
  --onboot 1 \
  --timezone Asia/Taipei \
  --ssh-public-keys /root/.ssh/wazuh_admin.pub
~~~

需要 VLAN 時在 `--net0` 後加 `,tag=<VLAN ID>`。

### 3-2 GUI 對照

| GUI 頁籤 | 欄位 | 值 |
| --- | --- | --- |
| General | CT ID／Hostname | `<CTID>`／`wazuh`；勾選 Unprivileged container、Nesting |
| General | Password 或 SSH public key | 建議用 SSH 金鑰 |
| Template | Template | ubuntu-22.04-standard |
| Disks | Storage／Size | VM_Pool／80 |
| CPU | Cores | 4 |
| Memory | Memory／Swap | 8192／512 |
| Network | Bridge／IPv4 | vmbr0／Static `192.0.2.32/24`，Gateway `192.0.2.1` |
| DNS | DNS servers | 依環境 |
| Confirm | Start after created | 先不勾，確認設定後再開機 |

### 3-3 開機前檢查並啟動

`pct config` 應看到下列關鍵行（數值依規劃）：

| 設定行 | 預期 | 不符合時 |
| --- | --- | --- |
| `cores: 4` | 4 | `pct set <CTID> --cores 4` |
| `memory: 8192` | 8192 | `pct set <CTID> --memory 8192` |
| `swap: 512` | 512 | `pct set <CTID> --swap 512` |
| `rootfs: VM_Pool:vm-<CTID>-disk-0,size=80G` | 在 VM_Pool、≥ 80G | 容量不足：`pct resize <CTID> rootfs 80G`（只能加大） |
| `unprivileged: 1` | 1 | 無法直接切換；需重建或備份還原時改選 |
| `features: nesting=1` | 含 nesting=1 | `pct set <CTID> --features nesting=1`（需重開 CT） |
| `net0: ...ip=.../24,gw=...` | 固定 IP | `pct set <CTID> --net0 ...` |
| `onboot: 1` | 1 | `pct set <CTID> --onboot 1` |

~~~bash
pct config <CTID>      # 核對 cores、memory、swap、rootfs、net0、unprivileged、features
pct start <CTID>
pct status <CTID>
pct enter <CTID>       # 進入容器
~~~

### 3-4 本案核對結果（2026-09-29，CT 112 位於 node12）

| 設定行 | 實際 | 判定 |
| --- | --- | --- |
| `cores: 4`／`memory: 8192`／`swap: 512` | 同規劃 | ✅ |
| `unprivileged: 1` | 1 | ✅ |
| `rootfs: VM_Pool:vm-112-disk-0,size=60G` | 在 VM_Pool，但只有 60G | ⚠️ 加大到 80G |
| `features` | **沒有這一行** | ❌ 缺 nesting=1 |
| `onboot: 0` | 0 | ⚠️ 節點重開後不會自動啟動 |
| `net0: ...firewall=1...` | 網卡已啟用 PVE Firewall | ℹ️ 若 CT 防火牆的 Input Policy 是 DROP，要先放行 443／1514／1515，否則 Agent 連不上 |
| `ip6=auto` | 自動取得 IPv6 | ℹ️ 不影響；不用 IPv6 可改成不設定 |

修正指令（在 node12 執行）：

~~~bash
pct set 112 --features nesting=1 --onboot 1
pct resize 112 rootfs 80G        # 只能加大；可在開機狀態執行
pct reboot 112                   # nesting 需重開才生效；未開機則用 pct start 112
pct config 112 | grep -E 'features|onboot|rootfs'
~~~

本案實測：CT 為 running、未鎖定。`pct set` 無輸出（成功）；`pct resize` 先擴大 RBD 映像，再由 resize2fs 線上擴充檔案系統至 20971520 個 4k 區塊（= 80 GiB）。訊息中的 `is mounted on /tmp` 是 PVE 為了線上擴充而暫時掛載，屬正常現象。修正後 `features: nesting=1`、`onboot: 1`、`size=80G`；nesting 需重開 CT 才生效。

## 4. 容器內基本設定

以下在容器內執行：

~~~bash
# 網路與 DNS
ip -4 addr show eth0
ping -c 3 192.0.2.1
getent hosts packages.wazuh.com

# 核對 kernel 參數有從主機帶進來
sysctl vm.max_map_count

# 確認 systemd 正常（nesting 生效的間接指標）與磁碟容量
systemctl is-system-running        # running 最好；degraded 時用 systemctl --failed 查原因
systemctl --failed
df -h /

# 更新系統與必要工具
apt update && apt -y full-upgrade
apt -y install curl gnupg apt-transport-https ca-certificates

# 時區與時間（告警時間要正確）
timedatectl
~~~

若 `packages.wazuh.com` 解析不到，先處理 DNS 或對外防火牆，後續安裝需要連線到此網址。

### 4-1 本案實測（2026-09-29）

| 檢查 | 結果 | 判定 |
| --- | --- | --- |
| `systemctl is-system-running` | running；`--failed` 0 個 | ✅ nesting 生效 |
| `df -h /` | 79G，已用 907M | ✅ |
| `free -h` | 8.0Gi／swap 512Mi | ✅ |
| `vm.max_map_count` | 1048576（來自 node12） | ✅ |
| eth0 | 192.0.2.32/24（示範位址），ping Gateway 0% loss | ✅ |
| `getent hosts packages.wazuh.com` | **只列出 IPv6 位址** | ⚠️ 需確認 |

`getent hosts` 會優先顯示 IPv6（AAAA）結果。CT 的 net0 設定 `ip6=auto`，若自動取得了 IPv6 位址、卻沒有真正通往外部的 IPv6 路由，curl 與 apt 會先嘗試 IPv6，造成下載緩慢、逾時或失敗。安裝前分別測試 IPv4 與 IPv6：

~~~bash
getent ahostsv4 packages.wazuh.com | head -3      # 有沒有 IPv4 位址
ip -6 addr show eth0 scope global                 # 有沒有取得全域 IPv6
ip -6 route show default                          # 有沒有 IPv6 預設路由
curl -4 -sS -o /dev/null -w 'IPv4: %{http_code} %{time_total}s\n' https://packages.wazuh.com/4.14/wazuh-install.sh
curl -6 -sS -m 10 -o /dev/null -w 'IPv6: %{http_code} %{time_total}s\n' https://packages.wazuh.com/4.14/wazuh-install.sh
~~~

判讀：兩者都是 200 代表正常；IPv4 200、IPv6 失敗或逾時時，擇一處理：

- 環境沒有要用 IPv6：在 node12 移除 CT 的 IPv6 設定（`pct set 112 --net0 name=eth0,bridge=vmbr0,firewall=1,gw=<GW>,hwaddr=<原MAC>,ip=<IP>/24,type=veth`，保留原 MAC），再重開 CT。
- 只想讓 apt 走 IPv4：`echo 'Acquire::ForceIPv4 "true";' > /etc/apt/apt.conf.d/99force-ipv4`。

本案決定：**略過 IPv6 測試**，直接安裝。若安裝時下載卡住或出現連線逾時，先套用上面「apt 強制 IPv4」的設定，再依第 5 節的失敗處理重跑。

### 4-2 時區與時間（2026-09-29 實測）

| 項目 | 實際 | 判讀 |
| --- | --- | --- |
| Time zone | Etc/UTC → Asia/Taipei | ✅ 已修正 |
| System clock synchronized | yes | ✅ |
| NTP service | inactive | ✅ LXC 正常現象 |
| RTC time | n/a | ✅ LXC 正常現象 |

LXC 沒有自己的系統時鐘，時間直接來自 PVE 主機的 kernel，所以容器內 NTP 顯示 inactive 是正常的，**也不要在容器內安裝 chrony／ntpd**（非特權容器沒有權限調整時鐘）。時間準不準取決於主機，要在 PVE 節點上確認：

~~~bash
# 在 PVE 節點（本案 node12，也建議三台都查）
chronyc tracking | grep -E 'Reference|System time|Leap'
~~~

容器內設定時區（只影響顯示與日誌時間格式，不影響時鐘本身）：

~~~bash
timedatectl set-timezone Asia/Taipei
timedatectl | grep 'Time zone'
~~~

本案結果：`Time zone: Asia/Taipei (CST, +0800)`。

Wazuh Indexer 內部以 UTC 儲存時間，Dashboard 依瀏覽器時區顯示；容器時區主要影響 `/var/ossec/logs` 等本機日誌的時間，與 PVE、Graylog 一致較方便對照。

## 5. 安裝 Wazuh All-in-one

使用官方安裝助手。2026-09-29 從 Wazuh 套件庫取得的版本是 4.14.8，因此網址使用 `4.14`；日後請以 [Quickstart](https://documentation.wazuh.com/current/quickstart.html) 當下的版本號為準：

**(1) 更新系統並安裝工具**

~~~bash
apt update && apt -y full-upgrade
apt -y install curl gnupg apt-transport-https ca-certificates tmux
~~~

**(2) 在 tmux 裡執行安裝**：安裝要 10～20 分鐘，若 SSH／Console 中途斷線，前景程式會被中斷、留下裝到一半的元件。tmux 讓程式在斷線後繼續執行：

~~~bash
tmux new -s wazuh          # 開一個名為 wazuh 的工作階段
# 斷線後重新連回：pct enter 112 → tmux attach -t wazuh
~~~

**(3) 下載並執行安裝助手**

~~~bash
cd /root
curl -sO https://packages.wazuh.com/4.14/wazuh-install.sh
bash ./wazuh-install.sh -a
~~~

注意兩點：

- 要用 `bash ./wazuh-install.sh`，不要直接打 `./wazuh-install.sh`。curl 下載的檔案沒有執行權限（x），直接執行會出現 `Permission denied`；交給 `bash` 讀取就不需要執行權限。
- 一定要加 `-a`，不加參數只會顯示說明，不會安裝。

**(4) 安裝失敗時**：先看 `/var/log/wazuh-install.log` 最後幾十行找原因，修正後用安裝助手的移除選項清掉半套元件再重裝：

~~~bash
tail -50 /var/log/wazuh-install.log
bash ./wazuh-install.sh -u      # 移除本機已安裝的 Wazuh 元件
bash ./wazuh-install.sh -a
~~~

- `-a` 代表 All-in-one：同時安裝 Indexer、Server、Dashboard。
- 安裝約需 10～20 分鐘，視網路與儲存速度而定。
- 結束時畫面會顯示 Dashboard 網址、帳號 `admin` 與隨機密碼。**只記在密碼管理工具，不要貼進本倉庫或聊天紀錄。**
- 所有元件密碼另存於 `/root/wazuh-install-files.tar` 的 `wazuh-passwords.txt`。

安裝助手若因硬體檢查中止，先回頭確認 CPU／RAM 是否達標。`-i`（忽略檢查）只在確認資源足夠、且理解風險時才使用。

### 5-1 本案實測（2026-09-30）

安裝在 CT 112 的 tmux 工作階段中執行。第一次誤打 `./wazuh-install.sh`（未加 `bash`、未加 `-a`）出現 `Permission denied`，改用 `bash ./wazuh-install.sh -a` 後正常安裝。

安裝輸出後段的關鍵時間點：

| 時間 | 事件 |
| --- | --- |
| 08:45:17 | Wazuh indexer 安裝完成，服務啟動 |
| 08:45:26 | Indexer 叢集安全設定初始化完成 |
| 08:46:15 | Wazuh manager 安裝完成，漏洞偵測設定完成 |
| 08:46:30 | wazuh-manager 服務啟動 |
| 08:46:42 | Filebeat 安裝完成並啟動 |
| 08:48:39 | wazuh-dashboard 服務啟動 |
| 08:48:43 | 內部使用者密碼更新，備份存於 `/etc/wazuh-indexer/internalusers-backup` |
| 08:49:13 | Dashboard web 應用初始化完成；顯示 admin 帳號與密碼（已存入密碼管理工具，未記錄於本文） |
| 08:49:16 | 移除安裝過程暫用的 gawk，`Installation finished` |

從 Indexer 完成到整體結束約 4 分鐘；Dashboard 安裝約 2 分鐘是其中最久的一段。

## 6. 驗證服務與登入 Dashboard

~~~bash
systemctl status wazuh-indexer wazuh-manager wazuh-dashboard --no-pager
/var/ossec/bin/wazuh-control status
ss -tlnp | grep -E ':443|:1514|:1515|:9200|:55000'
~~~

從管理電腦瀏覽 `https://192.0.2.32`，以 `admin` 登入。憑證是自簽，瀏覽器會出現警告，確認網址無誤後繼續。

驗收標準：三個服務都 `active (running)`、Port 都在監聽、Dashboard 能登入並看到 Wazuh Server 本身（agent 000）。

### 6-1 本案實測（2026-09-30）

| 檢查 | 結果 |
| --- | --- |
| `systemctl is-active wazuh-indexer wazuh-manager filebeat wazuh-dashboard` | 4 個皆 `active` ✅ |
| Port 監聽 | 1514（wazuh-remoted）、1515（wazuh-authd）、443（node）、55000（python3，IPv4＋IPv6）對所有介面；9200（java）只聽 127.0.0.1 ✅ |
| `filebeat test output` | 連 `https://127.0.0.1:9200`：連線、TLS 1.2 握手（憑證鏈驗證啟用）、`talk to server... OK`，回報版本 7.10.2 ✅ |
| Dashboard 登入 | `https://192.0.2.32`（示範位址）接受自簽憑證警告後，以 admin 登入成功 ✅ |
| Overview 畫面 | Agents Summary 顯示「no agents registered」；Last 24 hours alerts：Critical 0、High 0、Medium 213、Low 112 |

Agents Summary 只計算外部 Agent，Manager 本身（ID 000）不列入，所以顯示沒有 Agent 是正常的。告警全部來自 Manager 自己：剛安裝完的系統會因套件安裝、設定稽核（SCA）、rootcheck 等產生一批告警。Critical／High 為 0，Medium／Low 屬安裝後的正常雜訊，接上 Agent 後再用 Threat Hunting 看實際內容與數量變化。

## 7. 安全收尾

### 7-1 密碼與安裝檔

安裝助手已替每個內部帳號產生隨機強密碼，**不需要為了「換掉預設值」而改密碼**。需要處理的是：

1. **admin 密碼已存進密碼管理工具**，並確認能用它登入。
2. **密碼曾經外流時才更換**（例如出現在截圖、共用畫面、聊天紀錄）。
3. **妥善處理 `/root/wazuh-install-files.tar`**：它包含所有內部帳號密碼與 TLS 憑證私鑰。日後新增 Wazuh 節點或重建憑證會用到，不建議直接刪除。

~~~bash
# 只讓 root 可讀
chmod 600 /root/wazuh-install-files.tar
ls -l /root/wazuh-install-files.tar
~~~

建議另存一份到離線、受控的位置（例如內部加密儲存），不要放到雲端或本倉庫。注意：CT 112 的 PBS 備份也會包含這個檔案，備份的存取權限要一併管控。

#### 更換 admin 密碼

密碼規則：8～64 字元，須同時包含大寫、小寫、數字，以及 `.*+?-` 其中一個符號（其他符號可能被工具拒絕）。

用 `read -s` 輸入密碼，畫面不顯示、也不會留在 bash history：

`read` 引號內的文字只是**提示字**，照抄即可；按 Enter 後，在「新的 admin 密碼:」後面輸入密碼（畫面不會顯示），再按 Enter。**不要把密碼寫進引號裡**，否則密碼會顯示在畫面上並留在 history。執行工具前先用 `echo "長度：${#NEWPW}"` 確認不是 0。

~~~bash
read -rsp '新的 admin 密碼: ' NEWPW; echo
bash /usr/share/wazuh-indexer/plugins/opensearch-security/tools/wazuh-passwords-tool.sh -u admin -p "$NEWPW"
unset NEWPW
~~~

改完驗證：

~~~bash
filebeat test output          # 最後要出現 talk to server... OK
systemctl is-active filebeat wazuh-dashboard
~~~

再用新密碼登入 Dashboard（本案 2026-09-30 已確認可登入）。

**為什麼要測 Filebeat？** All-in-one 的 Filebeat 預設用 admin 帳號寫入 Indexer，密碼存在 Filebeat keystore。All-in-one 環境下工具通常會一併更新；若 `talk to server` 失敗，手動更新 keystore：

~~~bash
read -rsp '新的 admin 密碼: ' NEWPW; echo
echo "$NEWPW" | filebeat keystore add password --stdin --force
unset NEWPW
systemctl restart filebeat
filebeat test output
~~~

Dashboard 連 Indexer 用的是另一個內部帳號（kibanaserver），改 admin 不影響 Dashboard 服務本身。

**同步更新 Wazuh Server 的 keystore。** 工具最後會出現 WARNING，提醒要更新 Wazuh dashboard、Wazuh server、Filebeat 的密碼並重啟服務。All-in-one 的 Filebeat 已由工具自動更新；Wazuh Server（Manager）的漏洞偵測模組透過 indexer-connector 連線 Indexer，帳號密碼存在 Manager 自己的 keystore，預設也是 admin，需要手動更新：

~~~bash
read -rsp '新的admin密碼:' NEWPW; echo
echo "$NEWPW" | /var/ossec/bin/wazuh-keystore -f indexer -k password
unset NEWPW
systemctl restart wazuh-manager filebeat
systemctl is-active wazuh-manager filebeat
grep -iE 'indexer-connector|401|unauthorized' /var/ossec/logs/ossec.log | tail -5
~~~

`filebeat test output` 會重新讀取 keystore，但執行中的 Filebeat 程序仍使用啟動時載入的舊密碼，所以一起重啟。

#### 本案實測（2026-09-30）

| 時間 | 事件 |
| --- | --- |
| 09:30:52 | `Updating the internal users` |
| 09:30:53 | 舊設定備份至 `/etc/wazuh-indexer/internalusers-backup` |
| 09:30:55 | `filebeat.yml` 改用 Filebeat keystore 的帳號密碼 |
| 09:31:09 | WARNING：提醒更新 dashboard／server／Filebeat 的密碼並重啟服務 |
| 之後 | `filebeat test output` → `talk to server... OK` |

第一次操作時把密碼誤寫在 `read` 的引號內（提示字位置），`NEWPW` 長度為 0，未執行變更；清除 history 後重做成功。

Manager keystore 更新：`NEWPW` 長度 13（非 0），`wazuh-manager`、`filebeat` 重啟後皆 `active`。`ossec.log` 中 indexer-connector 對各 `wazuh-states-inventory-*` 索引皆顯示 `IndexerConnector initialized successfully`，沒有 401／Unauthorized；`filebeat test output` 仍為 `talk to server... OK`。

小提醒：多行指令一次貼上時，`read` 仍會等待鍵盤輸入（本案終端機的 bracketed paste 正常）。若終端機不支援 bracketed paste，下一行指令可能被 `read` 當成密碼讀走，因此 `read` 那一行建議單獨執行。

### 7-2 暫停 Wazuh 套件自動更新

Wazuh 各元件版本要一致才能正常運作，`apt upgrade` 時被單獨升級容易出問題。官方建議安裝後先停用套件庫，升級時再依官方升級程序手動打開：

~~~bash
sed -i "s/^deb /#deb /" /etc/apt/sources.list.d/wazuh.list
apt update
~~~

**本案實測（2026-09-30）**：`wazuh.list` 已變成 `#deb [signed-by=/usr/share/keyrings/wazuh.gpg] https://packages.wazuh.com/4.x/apt/ stable main`；`apt update` 只剩 Ubuntu jammy 的三個來源，不再連 packages.wazuh.com。

### 7-3 限制誰能連（PVE Firewall）

本案管理電腦與 Agent 都在同一個網段（示範：`192.0.2.0/24`）。規劃：

| Port | 用途 | 允許來源 |
| --- | --- | --- |
| 443/tcp | Dashboard | 管理網段 |
| 1514/tcp | Agent 傳送資料 | Agent 網段 |
| 1515/tcp | Agent 註冊 | Agent 網段 |
| 22/tcp | SSH | 管理網段 |
| ICMP | ping 排錯 | 管理網段 |
| 55000/tcp | Wazuh API | **不開放**：Dashboard 在本機以 127.0.0.1 呼叫 API，外部不需要 |

**(1) 先確認現況**（在任一節點）：

~~~bash
cat /etc/pve/firewall/cluster.fw 2>/dev/null | head -20   # 資料中心層級：[OPTIONS] 是否 enable: 1
cat /etc/pve/firewall/112.fw 2>/dev/null                  # CT 層級：是否已有規則
~~~

PVE 防火牆分三層：資料中心 → 節點 → VM／CT。**資料中心層級沒有啟用時，CT 的規則不會生效**。啟用資料中心防火牆會影響所有節點（包括 8006 管理介面與 SSH），屬於另一項變更，須另行規劃，不在本 SOP 內直接開啟。

**(2) 寫入 CT 規則**（檔案在叢集檔案系統上，任一節點寫入即同步）：

~~~bash
cat > /etc/pve/firewall/112.fw <<'FWEOF'
[OPTIONS]
enable: 1
policy_in: DROP
policy_out: ACCEPT

[RULES]
IN ACCEPT -source 192.0.2.0/24 -p tcp -dport 443 # Wazuh Dashboard
IN ACCEPT -source 192.0.2.0/24 -p tcp -dport 1514 # Wazuh agent events
IN ACCEPT -source 192.0.2.0/24 -p tcp -dport 1515 # Wazuh agent enrollment
IN SSH(ACCEPT) -source 192.0.2.0/24 # SSH
IN Ping(ACCEPT) -source 192.0.2.0/24 # ICMP ping
FWEOF
pve-firewall compile > /dev/null && echo "syntax OK"
~~~

`policy_in: DROP` 表示「沒有明確允許的連入一律丟棄」。網卡需有 `firewall=1`（本案已設定）規則才會套用。

**(3) 驗證**（從管理網段的電腦）：

| 測試 | 預期 |
| --- | --- |
| 瀏覽 `https://<Wazuh IP>` | 可登入 |
| `Test-NetConnection <Wazuh IP> -Port 1514`（Windows）或 `nc -zv <Wazuh IP> 1514`（Linux） | 成功 |
| 同上測 55000 | **失敗**（已被擋） |

**回復方式**：規則有誤時，把 `112.fw` 的 `enable: 1` 改成 `enable: 0` 即停用。即使網路規則寫錯，仍可在節點上用 `pct enter 112` 進入容器。

**本案現況（2026-09-30）**：

| 檔案 | 內容 | 意思 |
| --- | --- | --- |
| `cluster.fw` | `[OPTIONS] enable: 0`、`ebtables: 0` | 資料中心防火牆**未啟用** |
| `112.fw` | 不存在 | CT 112 從未設定規則 |

因此即使寫入 `112.fw`，規則也不會生效。要讓 PVE Firewall 生效就得啟用資料中心防火牆，但這會讓三台節點的主機層也開始套用預設的連入政策；Ceph（MON 3300／6789、OSD 6800–7300）、Corosync、8006、SSH 等流量需事先確認都有允許規則，否則可能影響叢集與儲存。這屬於獨立的變更，需另排維護時段評估，不在本次 Wazuh 部署中直接開啟。

**本案決定（2026-09-30）**：採應用程式層做法，把 Wazuh API（55000）改成只聽本機，達成「關閉 55000 對外」這項主要目標，不動 PVE 防火牆。資料中心防火牆另案規劃。

#### 7-4 Wazuh API 只監聽本機

**(1) 確認現況**

~~~bash
grep -n 'host' /var/ossec/api/configuration/api.yaml
grep -n 'url:' /usr/share/wazuh-dashboard/data/wazuh/config/wazuh.yml
~~~

本案結果：`api.yaml` 沒有未註解的 `host:`，代表使用預設值（所有介面）；Dashboard 的 API 位址是 `url: https://127.0.0.1`，改成只聽本機後 Dashboard 仍連得到。

**(2) 備份並加入設定**

~~~bash
cp -a /var/ossec/api/configuration/api.yaml /var/ossec/api/configuration/api.yaml.bak-$(date +%F)
tail -c1 /var/ossec/api/configuration/api.yaml | od -c | head -1   # 確認檔尾是 \n
echo "host: ['127.0.0.1']" >> /var/ossec/api/configuration/api.yaml
grep -n '^host' /var/ossec/api/configuration/api.yaml              # 只能有一行
~~~

YAML 最上層不能有重複的 key，所以加入前要確認沒有其他未註解的 `host:`。

**(3) 重啟並驗證**

~~~bash
systemctl restart wazuh-manager
systemctl is-active wazuh-manager
ss -tlnp | grep ':55000'                     # 應只剩 127.0.0.1:55000
tail -5 /var/ossec/logs/api.log
~~~

再到 Dashboard 開啟 Agents management 或 Server management，頁面能正常載入、沒有 API 連線錯誤。從管理電腦測試 55000 應連不上：`Test-NetConnection <Wazuh IP> -Port 55000`。

**本案實測（2026-09-30）**：

| 檢查 | 結果 |
| --- | --- |
| 檔尾 | `\n` ✅ |
| 加入後 `grep '^host'` | 第 80 行 `host: ['127.0.0.1']`，只有一行 ✅ |
| `wazuh-manager` | active ✅ |
| `ss` | 只剩 `127.0.0.1:55000`（原本的 `0.0.0.0` 與 `[::]` 已消失）✅ |
| `api.log` | `RBAC database integrity check finished successfully`、`Listening on ['127.0.0.1']:55000` ✅ |
| 外部測試（管理電腦 PowerShell） | `Test-NetConnection -Port 55000` → `TcpTestSucceeded : False`（Ping 仍 True）；`-Port 443` → `True` ✅ |

升級 Wazuh 後要再檢查一次這行設定是否保留。

**回復方式**：

~~~bash
cp -a /var/ossec/api/configuration/api.yaml.bak-<日期> /var/ossec/api/configuration/api.yaml
systemctl restart wazuh-manager
~~~

**判讀限制**：管理與 Agent 都在同一網段時，這組規則的主要效果是關閉 55000 與其他未列出的 Port，並阻擋其他網段（如 VPN、其他 VLAN）連入；同網段內的主機仍可連 443／1514／1515。

## 8. 備份與 HA

### 8-1 先做一次手動備份

安裝與安全設定完成後，先留一個「乾淨狀態」的備份點。在 CT 所在節點：

~~~bash
pvesh get /cluster/backup --output-format yaml     # 看既有的排程備份工作（是否已包含 112 或 all）
vzdump 112 --storage PBS31 --mode snapshot --protected 1 --notes-template '{{guestname}} Wazuh 4.14 安裝完成'
~~~

`vzdump` 要在 **CT 目前所在的節點**執行。`--protected 1` 讓這份備份不會被 prune 保留策略自動刪除；不再需要時，到 PBS31 取消保護即可。

| 模式 | 說明 | 本案選擇 |
| --- | --- | --- |
| snapshot | 不停機；先對 RBD 做快照再備份 | ✅ 日常排程 |
| suspend | 短暫凍結 CT | — |
| stop | 關機備份，資料一致性最高，會停機數分鐘 | 需要「完全一致」的備份點時使用 |

**本案實測（2026-09-30）**：

| 項目 | 結果 |
| --- | --- |
| 資料量 | 14.611 GiB，其中 14.215 GiB 需上傳（壓縮後 3.749 GiB） |
| 重複利用 | 405.59 MiB（2.7%），首次備份幾乎是全量 |
| 速度／時間 | 平均 92.4 MiB/s；Duration 157.64 s，整體 00:02:40 |
| 收尾 | 暫存 `vzdump` 快照已移除；`Backup job finished successfully`；已通知 `mail-to-root` |

Indexer 持續寫入，snapshot 模式得到的是「像突然斷電那一刻」的狀態（crash-consistent）。OpenSearch 通常能自行恢復，但**只有做過還原測試才算數**。

### 8-2 加入排程備份

本案現況（2026-09-30）：既有排程工作已涵蓋全部 guest，CT 112 自動納入，不需另外設定。

| 項目 | 值 |
| --- | --- |
| 範圍 | `all: 1`（全部 VM／CT） |
| 時間 | 每天 21:00 |
| 模式 | snapshot（fleecing 未啟用） |
| 目的地 | PBS31 |
| 保留 | keep-last 3、keep-daily 7 |
| 備註範本 | `{{guestname}}` |


Datacenter → Backup：若既有工作是「All」則已自動包含；否則編輯工作把 112 加入，或新增一個工作（Storage：PBS31、Mode：Snapshot）。保留策略依 PBS 的 prune 設定。

### 8-3 還原測試

還原成**另一個 CT ID**，開機前把網卡設為斷線（`link_down=1`），避免和正式機衝突：

~~~bash
pvesh get /cluster/nextid                                   # 取一個可用的 CT ID
pvesm list PBS31 --vmid 112                                 # 找到剛才那份備份的 volid
pct restore <新CTID> <volid> --storage VM_Pool --unique 1   # --unique：產生新的 MAC
pct set <新CTID> --onboot 0 --net0 name=eth0,bridge=vmbr0,ip=192.0.2.99/24,gw=192.0.2.1,link_down=1
pct start <新CTID>
~~~

| 設定 | 目的 |
| --- | --- |
| `--unique 1` | 重新產生 MAC，避免與正式機重複 |
| `--onboot 0` | 測試機不要在節點重開時自動啟動 |
| `link_down=1` | 網卡斷線：IP、hostname、Manager 身分都和正式機相同，斷線才不會搶 Agent 或造成 IP 衝突 |

等 1～2 分鐘讓服務啟動後驗證：

~~~bash
pct exec <新CTID> -- systemctl is-active wazuh-indexer wazuh-manager filebeat wazuh-dashboard
pct enter <新CTID>
curl -sk -u admin 'https://127.0.0.1:9200/_cluster/health?pretty'   # 會詢問 admin 密碼；status 應為 green
curl -sk -u admin 'https://127.0.0.1:9200/_cat/indices/wazuh-alerts-*?v&s=index'   # 告警索引與筆數
exit
~~~

**本案實測（2026-09-30，還原到 node11 的 CT 114）**：

| 項目 | 結果 |
| --- | --- |
| 選用備份 | `PBS31:backup/ct/112/2026-09-30T05:29:26Z`（台灣時間 13:29 的手動備份；PBS 以 UTC 命名）|
| 另一份 | `2026-09-29T13:05:01Z`（0.9 GB，昨晚排程，安裝 Wazuh 前）不使用 |
| 還原 | 在 VM_Pool 建立 80G ext4（20971520 個 4k 區塊），14.611 GiB 於 1 分 52.8 秒完成，平均 132.6 MiB/s |
| 網路隔離 | `pct set` 後 net0 含 `link_down=1`、IP 改為 .99、MAC 已重新產生；容器內 `ip -br addr show eth0` → `DOWN`、無 IP ✅ |
| Indexer 健康 | `status: green`，1 個節點，23 個 primary shard 全部 active，unassigned 0，`active_shards_percent` 100% ✅ |
| 告警資料 | `wazuh-alerts-4.x-2026.09.30`：green／open，3 primary、0 replica，1718 筆，2.2 MB ✅ |

結論：snapshot 模式的備份可完整還原，Indexer 啟動後資料一致，告警索引與筆數都在。從 PBS 還原約 2 分鐘，加上服務啟動約 1～2 分鐘，可作為 RTO 參考。

測試完成後已刪除 CT 114（`pct destroy 114 --purge`）。

操作提醒：`pct enter` 會開新的 shell，和後面的指令一起貼上時，後面幾行會排在節點的 shell，等離開容器後才在**節點上**執行。`pct enter` 要單獨執行。

驗收標準：4 個服務 active、叢集健康 green（或 yellow 並能說明原因）、可以看到還原前的告警索引。

驗收後刪除測試 CT：

~~~bash
pct stop <新CTID>
pct destroy <新CTID> --purge
~~~

### 8-4 遷移測試與 HA

LXC 不支援線上遷移，只能「重啟式遷移」，會中斷約 1～2 分鐘加上服務啟動時間：

~~~bash
pct migrate 112 <目標節點> --restart
# 遷移後在目標節點
pct exec 112 -- systemctl is-active wazuh-indexer wazuh-manager filebeat wazuh-dashboard
~~~

**本案紀錄（2026-09-30）**：CT 112 已由 node12 遷移至 node10（8-1 手動備份即在 node10 執行）。遷移後驗證：

~~~bash
pct status 112
pct exec 112 -- systemctl is-active wazuh-indexer wazuh-manager filebeat wazuh-dashboard
pct exec 112 -- sysctl vm.max_map_count
pct exec 112 -- ss -tlnp | grep -E ':443 |:1514|:1515|:55000'
~~~

遷移後驗證結果：

| 檢查 | 結果 |
| --- | --- |
| `pct status` | running ✅ |
| 4 個服務 | 皆 active ✅（Indexer 換節點後正常啟動） |
| `vm.max_map_count` | 1048576（node10 kernel）✅ |
| Port | 443／1514／1515 聽 0.0.0.0；55000 只聽 127.0.0.1 ✅（設定隨 CT 保留） |
| Dashboard | 登入正常 ✅ |

2026-10-02 為分散 node10 的負載，以 `ha-manager migrate ct:112 node12` 將 CT 112 移至 node12（HA 資源要透過 ha-manager 遷移）。容器為重啟式遷移，中斷約 1～2 分鐘；遷移後在 node12 確認 4 個服務 active、`vm.max_map_count` 1048576、`agent_control -l` 中 Active 為 18，Dashboard 顯示 17 台 Agent Active。IP 不變，Agent 不需修改設定。

加入 HA 前確認：rootfs 在共用儲存（VM_Pool）、所有節點 `vm.max_map_count` ≥ 262144、`nesting=1` 已設定、手動遷移測試成功。

**加入前先看 HA 現況**（任一節點）：

~~~bash
ha-manager status          # quorum、master、各節點 lrm 狀態、既有 HA 資源
ha-manager config          # 既有 HA 資源清單
ha-manager rules config 2>/dev/null   # PVE 9 的 HA 規則（取代舊版 HA groups）
~~~

**盲點：HA 會啟用節點的 watchdog 自我隔離（fencing）。** 節點上一旦有 HA 資源，該節點的 LRM 會變成 active 並啟動 watchdog；之後若這台節點失去 quorum（例如叢集網路中斷），它會**自動重開機**以保護資料。如果叢集原本已經有 HA 資源，這是既有行為；如果 CT 112 是第一個 HA 資源，等於替叢集新增了這項機制，需要先確認叢集網路穩定。

**本案現況（2026-09-30）**：

| 項目 | 狀態 |
| --- | --- |
| quorum | OK；HA master 為 node12；fencing armed |
| LRM | node10 active／watchdog active；node11 idle／standby；node12 active／watchdog active |
| 既有 HA 資源 | ct:100、ct:110、ct:113（node10）；ct:101（node12），皆 started |
| HA 規則 | 未設定 |

CT 112 目前在 node10，而 node10 的 LRM 本來就是 active，加入 HA 不會新增 fencing 行為。

加入 HA：

~~~bash
ha-manager add ct:112 --state started --max_restart 1 --max_relocate 1
ha-manager status | grep -E 'ct:112|lrm'
~~~

| 參數 | 意思 |
| --- | --- |
| `--state started` | HA 會確保它維持開機 |
| `--max_restart 1` | 在原節點啟動失敗時，重試 1 次 |
| `--max_relocate 1` | 仍失敗時，最多搬到其他節點 1 次 |

節點故障時，HA 會在 fencing 完成後（通常約 2～3 分鐘）於其他節點重新啟動 CT 112。LXC 是重新開機而非線上接手，服務會中斷數分鐘。

**本案實測（2026-09-30）**：`ha-manager add ct:112 --state started --max_restart 1 --max_relocate 1` 後，`ha-manager status` 顯示 `service ct:112 (node10, started)`，三台 LRM 狀態與加入前相同；加入 HA 過程未重開 CT。

加入後 node10 上有 4 個 HA 資源（ct:100、110、112、113）。node10 故障時會同時在其他節點重啟，目前 node11 可用記憶體約 44 GiB，容量足夠；資源增加後可考慮用 HA 規則分散。

| 想做的事 | 不要用 | 改用 |
| --- | --- | --- |
| 關機 | `pct shutdown 112` | GUI Shutdown，或 `ha-manager set ct:112 --state stopped` |
| 遷移 | `pct migrate 112 ...` | GUI Migrate，或 `ha-manager migrate ct:112 <節點>` |
| 維護時暫停 HA 管理 | — | `ha-manager set ct:112 --state ignored` |

注意：加入 HA 後，要關機或遷移請透過 HA（GUI 或 `ha-manager`），直接 `pct shutdown` 可能被 HA 自動拉起來。

## 9. 接上 Agent

本案順序（2026-09-30 決定）：先接一台 PVE 節點（node11），再接測試用 Linux VM／CT，最後接 Windows 管理電腦。node11 目前沒有 HA 資源、負載最輕，Agent 有狀況時影響最小。

### 9-1 版本原則

Agent 版本不可高於 Manager（本案 4.14.8）。安裝時指定版本號，避免裝到比 Manager 新的版本。

### 9-2 Linux（Debian／Ubuntu）：下載 .deb 安裝，不加套件庫

PVE 節點或其他重要主機建議用這個方式：直接安裝 .deb，不在主機上新增 Wazuh 套件庫，日後 `apt upgrade` 不會連帶升級 Agent。

~~~bash
apt-get install -y lsb-release        # Agent 的相依套件；PVE 9（Debian 13）預設沒有安裝
cd /tmp
wget https://packages.wazuh.com/4.x/apt/pool/main/w/wazuh-agent/wazuh-agent_4.14.8-1_amd64.deb
WAZUH_MANAGER='192.0.2.32' WAZUH_AGENT_NAME='<主機名稱>' dpkg -i ./wazuh-agent_4.14.8-1_amd64.deb
systemctl daemon-reload
systemctl enable --now wazuh-agent
systemctl is-active wazuh-agent
~~~

也可在 Dashboard 的 **Deploy new agent** 精靈選擇作業系統與 Manager 位址，產生對應指令後核對版本再執行。

### 9-2a PVE 節點安裝前檢查

~~~bash
cat /etc/debian_version                        # PVE 9 為 Debian 13（trixie）
dpkg -l | grep -i wazuh                        # 應無輸出
timeout 3 bash -c '</dev/tcp/192.0.2.32/1514' && echo "1514 OK"
timeout 3 bash -c '</dev/tcp/192.0.2.32/1515' && echo "1515 OK"
~~~

本案結果（2026-09-30）：node10、node11、node12 皆為 Debian 13.7，沒有 Wazuh 套件，1514／1515 皆 OK。安裝順序：先 node11 驗證成功，再依序安裝 node10、node12。

`/dev/tcp/<IP>/<Port>` 是 bash 內建的連線測試，不需要另外安裝 nc。兩個 Port 都要 OK，否則 Agent 無法註冊或回報。

#### 本案踩到的相依性問題（2026-09-30，node11）

第一次 `dpkg -i` 出現：

~~~text
dpkg: dependency problems prevent configuration of wazuh-agent:
 wazuh-agent depends on lsb-release; however:
  Package lsb-release is not installed.
~~~

`dpkg -i` 只安裝指定的檔案，不會自動下載相依套件，所以套件被解開但停在「未設定」狀態。處理方式：

~~~bash
apt-get install -s lsb-release          # 模擬：確認只會新增 lsb-release
apt-get install -y lsb-release          # 從 Debian 官方套件庫安裝；apt 會順便完成 wazuh-agent 的設定
grep -A2 '<server>' /var/ossec/etc/ossec.conf    # 檢查 Manager 位址
~~~

apt 在完成 wazuh-agent 設定時沒有帶 `WAZUH_MANAGER` 環境變數，設定檔中的位址停在佔位字 `MANAGER_IP`。本案實測：帶環境變數重跑 `dpkg -i`（同版本覆蓋安裝）**不會**改寫位址，仍是 `MANAGER_IP`；環境變數只在全新安裝時套用。因此手動修正：

~~~bash
sed -i 's|<address>MANAGER_IP</address>|<address>192.0.2.32</address>|' /var/ossec/etc/ossec.conf
grep -A2 '<server>' /var/ossec/etc/ossec.conf    # <address> 必須是 Manager IP
~~~

Agent 名稱沒有另外寫入設定檔時，註冊時會使用主機名稱（本案即 node11）。

**避免重蹈覆轍**：其他節點先安裝 `lsb-release`，再帶環境變數做全新安裝，並在啟動前一定用 `grep` 確認 `<address>`。

### 9-3 驗證

~~~bash
# Agent 端
grep -iE 'connected|error' /var/ossec/logs/ossec.log | tail -5

# Manager 端（CT 112 內）
/var/ossec/bin/agent_control -l
~~~

Dashboard → Agents management → Summary 應看到新 Agent，狀態為 **Active**。

#### 本案實測：node11（2026-09-30）

| 檢查 | 結果 |
| --- | --- |
| Agent log | `14:30:31 wazuh-agentd: INFO: (4102): Connected to the server ([192.0.2.32]:1514/tcp).` ✅ |
| Manager `agent_control -l` | `ID: 001, Name: node11, IP: any, Active` ✅ |
| Dashboard Endpoints | Active 1；node11、IP 192.0.2.11、群組 default、Debian GNU/Linux 13、v4.14.8、active ✅ |

#### 本案實測：node12（2026-09-30）

依修正後順序操作：`apt-get install -y lsb-release`（新安裝 12.1-1，來自 Debian trixie 官方套件庫）→ 下載 .deb（13,227,800 bytes）→ 帶環境變數全新安裝 → `grep` 顯示 `<address>192.0.2.32</address>` → 啟動，`is-active` 為 active。

**結論：先裝好 lsb-release，再帶環境變數做全新安裝，Manager 位址會正確寫入。** node11 的 `MANAGER_IP` 問題來自「相依套件缺少、安裝被中斷，之後由 apt 補完設定」的順序，不是環境變數本身失效。

node10 原本已有 lsb-release（12.1-1），apt 只將它標記為手動安裝；之後的下載、全新安裝、位址檢查與啟動過程與 node12 相同。

#### 三台 PVE 節點總驗收（2026-09-30）

Manager 端 `agent_control -l`：

| ID | 名稱 | 狀態 |
| --- | --- | --- |
| 000 | wazuh (server) | Active/Local |
| 001 | node11 | Active |
| 002 | node10 | Active |
| 003 | node12 | Active |

Dashboard 上的「Cluster node: node01」是 Wazuh Manager 叢集的節點名稱（安裝預設值），不是 PVE 節點名稱。

### 9-4 回復方式（要移除 Agent 時）

~~~bash
# Agent 端
systemctl disable --now wazuh-agent
apt-get remove --purge -y wazuh-agent
rm -rf /var/ossec

# Manager 端（CT 112 內），<ID> 由 agent_control -l 查得
/var/ossec/bin/manage_agents -r <ID>
~~~

### 9-5 PVE 節點的告警調校（接上後觀察）

預設的檔案完整性監控（FIM）會掃 `/etc`，其中包含叢集檔案系統 `/etc/pve`。`/etc/pve` 的變更會同步到每台節點，三台都裝 Agent 時同一個變更會產生三份告警。先以預設值觀察一段時間，再決定是否在 Agent 的 `ossec.conf` 加入 `<ignore>/etc/pve</ignore>`，或改由 Manager 端規則處理。FIM 只記錄雜湊值，除非啟用 `report_changes`，不會保存檔案內容。

### 9-6 Debian 13 LXC 容器：從 PVE 節點推送安裝

本案 Debian 13 的服務都跑在 LXC 容器裡（AdGuard、Graylog、IPAM、LibreNMS、Pi-hole、ProxCenter、WireGuard）。做法是在 PVE 節點把 .deb 推進容器、用 `pct exec` 安裝：

- 容器內不需要 wget／curl，也不必能連到 packages.wazuh.com。
- 所有指令都在節點上執行，容易逐台複製。
- 同樣不在容器內新增 Wazuh 套件庫。

`pct push`／`pct exec` 只能操作**目前在這台節點上**的容器，先確認 CT ID 與所在節點：

~~~bash
pct list        # 在每台節點各執行一次
~~~

本案清單（2026-09-30 `pct list`）：

| CT ID | 名稱 | 節點 | 狀態 | 安裝順序 |
| --- | --- | --- | --- | --- |
| 103 | IPAM | node10 | running | ① 試裝 |
| 102 | librenms | node10 | running | ② |
| 105 | Graylog | node10 | running | ② |
| 110 | ProxCenter | node10 | running | ② |
| 100 | AdGuard | node10 | running | ③ DNS |
| 101 | Pihole | node12 | running | ③ DNS |
| 109 | wireguard | node10 | **stopped** | 暫緩，開機後再裝（`pct exec` 無法操作關機中的容器） |

node11 目前沒有容器。

以一台容器為例（`<CTID>` 換成實際 ID），在該容器所在的節點執行：

~~~bash
# 1. 節點上準備 .deb（已下載過可略過）
cd /tmp && [ -f wazuh-agent_4.14.8-1_amd64.deb ] || wget https://packages.wazuh.com/4.x/apt/pool/main/w/wazuh-agent/wazuh-agent_4.14.8-1_amd64.deb

# 2. 容器能連到 Manager
pct exec <CTID> -- bash -c "timeout 3 bash -c '</dev/tcp/192.0.2.32/1514' && timeout 3 bash -c '</dev/tcp/192.0.2.32/1515' && echo 'port OK'"

# 3. 推送 .deb，先裝相依套件，再全新安裝
pct push <CTID> /tmp/wazuh-agent_4.14.8-1_amd64.deb /tmp/wazuh-agent_4.14.8-1_amd64.deb
pct exec <CTID> -- apt-get install -y lsb-release
pct exec <CTID> -- env WAZUH_MANAGER='192.0.2.32' dpkg -i /tmp/wazuh-agent_4.14.8-1_amd64.deb

# 4. 啟動前確認位址
pct exec <CTID> -- grep -A2 '<server>' /var/ossec/etc/ossec.conf

# 5. 啟動、驗證、清掉安裝檔
pct exec <CTID> -- bash -c 'systemctl daemon-reload && systemctl enable --now wazuh-agent && systemctl is-active wazuh-agent'
pct exec <CTID> -- rm -f /tmp/wazuh-agent_4.14.8-1_amd64.deb
~~~

#### 本案實測：IPAM（CT 103，2026-09-30）

| 步驟 | 結果 |
| --- | --- |
| Port 測試 | `port OK` |
| lsb-release | 容器內已有（12.1-1） |
| `dpkg -i` | 全新安裝，無相依性錯誤 |
| `<address>` | 192.0.2.32 ✅ |
| 服務 | enable 並 active |
| Agent log | logcollector 自動開始讀取 `/var/log/nginx/error.log`；07:04:25 `Connected to the server` |
| Manager | 剛註冊時為 `ID: 004, Name: IPAM, Pending`，稍後轉為 `Active` |

`Pending` 表示已註冊、Manager 尚未收到第一次完整回報，通常數十秒內會轉為 Active。容器 log 時間為 UTC（容器時區未改），與節點台灣時間相差 8 小時，屬顯示差異。

#### 本案實測：librenms（CT 102，2026-09-30）

手動逐步安裝。07:08:14 `Connected to the server`；logcollector 同樣自動讀取 `/var/log/nginx/error.log`；Manager 顯示 `ID: 005, Name: librenms, Active`。

已安裝的容器不要放進批次迴圈：同版本覆蓋安裝沒有好處，還可能讓 Agent 重啟。

#### 批次安裝其餘容器

試裝成功後，用迴圈處理同一節點上的其他容器。位址不正確的容器不會被啟動：

~~~bash
DEB=/tmp/wazuh-agent_4.14.8-1_amd64.deb
MGR=192.0.2.32
for id in 102 105 110; do
  echo "===== CT $id ====="
  pct exec $id -- bash -c "timeout 3 bash -c '</dev/tcp/$MGR/1514' && timeout 3 bash -c '</dev/tcp/$MGR/1515'" \
    || { echo "CT $id：連不到 Manager，跳過"; continue; }
  pct push $id $DEB $DEB
  pct exec $id -- apt-get install -y lsb-release
  pct exec $id -- env WAZUH_MANAGER=$MGR dpkg -i $DEB
  if pct exec $id -- grep -q "<address>$MGR</address>" /var/ossec/etc/ossec.conf; then
    pct exec $id -- bash -c 'systemctl daemon-reload && systemctl enable --now wazuh-agent && systemctl is-active wazuh-agent'
  else
    echo "CT $id：Manager 位址不正確，未啟動"
  fi
  pct exec $id -- rm -f $DEB
done
~~~

本案結果：以迴圈安裝 Graylog（105）、ProxCenter（110），Manager 顯示 `ID: 006, Name: Graylog, Active`、`ID: 007, Name: ProxCenter, Active`。

#### DNS 容器：先做快照

AdGuard（100）與 Pi-hole（101）是全網路依賴的服務。安裝 Agent 不會重啟 DNS 服務，但保險起見先做快照，出問題可以立即回復：

~~~bash
pct snapshot <CTID> pre-wazuh-agent --description "安裝 Wazuh Agent 前"
# 安裝完成並確認 DNS 正常後
pct exec <CTID> -- systemctl is-active AdGuardHome     # AdGuard
pct exec <CTID> -- systemctl is-active pihole-FTL      # Pi-hole
# 觀察一段時間沒問題再刪除快照
pct delsnapshot <CTID> pre-wazuh-agent
~~~

回復方式：`pct rollback <CTID> pre-wazuh-agent`（會回到快照當下，快照之後的變更全部消失）。

本案結果（2026-09-30）：AdGuard（100，node10）與 Pi-hole（101，node12）先做快照再安裝；安裝後 `AdGuardHome`、`pihole-FTL` 皆 active；Manager 顯示 `ID: 008, Name: AdGuard, Active`、`ID: 009, Name: Pihole, Active`。快照觀察兩天、DNS 正常後，已於 2026-10-02 刪除（CT 100、101、109）。

WireGuard（109）：開機後先做快照再跑迴圈。輸出顯示 `Unpacking wazuh-agent (4.14.8-1) over (4.14.8-1)`，代表容器內**原本已裝過 Agent**，這次是同版本覆蓋安裝；設定檔位址正確、服務 active，`wg show` 顯示 wg0 不受影響。Manager 端只有一筆 `ID: 010, Name: wireguard, Active`，沒有重複註冊。另以 `apt autoremove`（先 `--dry-run` 確認）移除容器內用不到的 `linux-image-6.12.73+deb13-rt-amd64`，釋放 111 MB；容器使用主機 kernel，不需要自己的 kernel 套件。安裝前可先用 `pct exec <CTID> -- dpkg -l wazuh-agent` 確認，避免重複安裝。

#### Debian 13 容器總驗收（2026-09-30）

| ID | 名稱 | CT | 節點 | 狀態 |
| --- | --- | --- | --- | --- |
| 004 | IPAM | 103 | node10 | Active |
| 005 | librenms | 102 | node10 | Active |
| 006 | Graylog | 105 | node10 | Active |
| 007 | ProxCenter | 110 | node10 | Active |
| 008 | AdGuard | 100 | node10 | Active |
| 009 | Pihole | 101 | node12 | Active |
| 010 | wireguard | 109 | node10 | Active |
| 013 | ai（Ubuntu 24.04.5，HA 資源） | 113 | node10 | Active |

說明：

- `pct exec <CTID> -- env 變數=值 指令`：`pct exec` 不經過 shell，要用 `env` 把環境變數帶給 dpkg。
- 沒有指定 `WAZUH_AGENT_NAME` 時，Agent 以容器的 hostname 註冊。
- 先挑一台影響最小的容器試裝，確認 Dashboard 出現 Active 後再逐台安裝。DNS（AdGuard、Pi-hole）與 VPN（WireGuard）這類基礎服務排在後面。
- 容器與主機共用 kernel，Agent 在容器內看到的是容器自己的檔案與行程；rootcheck 等模組在容器內可能出現與實體主機不同的結果，接上後觀察再調校。

### 9-7 Ubuntu VM（UBClient）

UBClient 是 VM，不是容器，`pct push`／`pct exec` 不適用，要登入 VM 內安裝（SSH 或 PVE Console）。先在節點確認 VM 狀態：

~~~bash
qm list        # 各節點執行，找 UBClient 的 VMID 與狀態
~~~

本案 VM 清單（2026-09-30 `qm list`）：

| VMID | 名稱 | 節點 | 狀態 |
| --- | --- | --- | --- |
| 104 | UBClient | node11 | running |
| 108 | WinClient | node11 | running |
| 107 | DC02 | node11 | running |
| 106 | DC01 | node12 | running |
| 111 | CA | node12 | running |

node10 沒有 VM。

VM 內（一般使用者需 `sudo`）：

~~~bash
lsb_release -a                                  # Ubuntu 預設已有 lsb-release
timeout 3 bash -c '</dev/tcp/192.0.2.32/1514' && timeout 3 bash -c '</dev/tcp/192.0.2.32/1515' && echo "port OK"
cd /tmp
wget https://packages.wazuh.com/4.x/apt/pool/main/w/wazuh-agent/wazuh-agent_4.14.8-1_amd64.deb
sudo WAZUH_MANAGER='192.0.2.32' dpkg -i ./wazuh-agent_4.14.8-1_amd64.deb
sudo grep -A2 '<server>' /var/ossec/etc/ossec.conf
sudo systemctl daemon-reload
sudo systemctl enable --now wazuh-agent
systemctl is-active wazuh-agent
rm -f /tmp/wazuh-agent_4.14.8-1_amd64.deb
~~~

`sudo 變數=值 指令`：sudo 允許在指令前指定環境變數並傳給該指令；寫成 `WAZUH_MANAGER=... sudo dpkg ...` 則變數可能被 sudo 過濾掉。`/var/ossec` 只有 root 能讀，查設定檔也要 `sudo`。

#### 本案實測：UBClient（VM 104，2026-09-30）

| 項目 | 結果 |
| --- | --- |
| 作業系統 | `lsb_release -a` 顯示 **Ubuntu 24.04.4 LTS（noble）**；PVE 標籤原寫 ub22.04，已於 2026-09-30 更正為 ub24.04 |
| `No LSB modules are available.` | Ubuntu 的正常訊息，不影響 |
| SSH | 桌面版預設沒有 SSH 伺服器，先安裝 `openssh-server` 再連線操作 |
| Port | `port OK` |
| 安裝 | sudo 密碼輸入錯誤 3 次後重來；未加 sudo 時 dpkg 回報需要超級使用者權限；加上 sudo 後全新安裝成功 |
| `<address>` | 192.0.2.32 ✅ |
| 服務 | enable 並 active |
| Manager | `ID: 011, Name: ubclient, Active` |

sudo 輸入錯誤發生在 Agent 安裝之前；logcollector 預設只讀取啟動後的新紀錄，所以那幾次失敗不會出現在 Wazuh。要驗證 Agent 是否正常回報，可在安裝後故意輸錯一次 sudo 或 SSH 密碼，再到 Dashboard 搜尋。

**端到端告警驗證（2026-09-30）**：在 UBClient 執行 `sudo ls` 並故意輸入錯誤密碼（出現「抱歉，請重試」）。注意：沒有輸入密碼就取消時只會顯示「sudo: 需要密碼」，不算驗證失敗，不會產生告警。

Dashboard → Threat intelligence → Threat Hunting → Events，搜尋 `agent.name:ubclient`，時間範圍 Last 15 minutes：

| 時間 | Agent | 描述 | 等級 | 規則 |
| --- | --- | --- | --- | --- |
| 2026-09-30 16:16:23 | ubclient | PAM: User login failed. | 5 | 5503 |

確認 log → Agent → Manager → Indexer → Dashboard 整條路徑正常。也可在 Manager 上查：`grep -A6 'ubclient' /var/ossec/logs/alerts/alerts.log | tail -40`。

### 9-8 Windows（WinClient）

以系統管理員身分開啟 PowerShell：

~~~powershell
# 1. 確認連得到 Manager
Test-NetConnection 192.0.2.32 -Port 1514
Test-NetConnection 192.0.2.32 -Port 1515

# 2. 下載並安裝（指定 4.14.8，與 Manager 相同）
Invoke-WebRequest -Uri https://packages.wazuh.com/4.x/windows/wazuh-agent-4.14.8-1.msi -OutFile $env:TEMP\wazuh-agent.msi
Start-Process msiexec.exe -ArgumentList "/i `"$env:TEMP\wazuh-agent.msi`" /q WAZUH_MANAGER=`"192.0.2.32`"" -Wait

# 3. 啟動前確認位址
Select-String -Path 'C:\Program Files (x86)\ossec-agent\ossec.conf' -Pattern '<address>'

# 4. 啟動並確認
NET START Wazuh
Get-Service | Where-Object DisplayName -like 'Wazuh*'
Get-Content 'C:\Program Files (x86)\ossec-agent\ossec.log' -Tail 20 | Select-String 'Connected|ERROR'
Remove-Item $env:TEMP\wazuh-agent.msi
~~~

說明：`Start-Process ... -Wait` 會等安裝完成才回到提示字元；直接執行 `msiexec` 會立刻返回，下一步可能在安裝完成前就執行。

#### 本案實測：WinClient（VM 108，2026-09-30）

| 項目 | 結果 |
| --- | --- |
| 下載與安裝 | `Invoke-WebRequest` 與 `Start-Process ... -Wait` 皆無錯誤訊息 |
| `<address>` | `ossec.conf` 第 11 行為 192.0.2.32 ✅ |
| 啟動 | `NET START Wazuh` → 「Wazuh 服務已經啟動成功」 |
| 服務 | `Get-Service`：Status Running、Name **WazuhSvc**、DisplayName **Wazuh** |
| log | 剛啟動時 `Connected` 尚未出現；稍後 16:04:02 `Connected to the server ([192.0.2.32]:1514/tcp)` ✅。同時段的 `Ignore 'registry' entry ...` 是預設設定中排除的登錄機碼，屬正常訊息 |
| Manager | `ID: 012, Name: WinClient, Active` ✅ |

#### Agent 總驗收（2026-09-30）

| 類型 | ID | 名稱 | 安裝方式 |
| --- | --- | --- | --- |
| PVE 節點 | 001～003 | node11、node10、node12 | 節點上下載 .deb，`dpkg -i` |
| Debian 13 容器 | 004～010 | IPAM、librenms、Graylog、ProxCenter、AdGuard、Pihole、wireguard | 節點上 `pct push` + `pct exec` |
| Ubuntu VM | 011 | ubclient | SSH 登入，`sudo 變數=值 dpkg -i` |
| Windows VM | 012 | WinClient | PowerShell，MSI + `WAZUH_MANAGER` |
| Windows 網域控制站 | 014～015 | DC02、DC01 | 同 Windows VM；裝前快照、AD 健康基準，裝後比對（9-9） |
| Windows 憑證伺服器 | 016 | ca | 同上，以 CertSvc 與 `certutil -ping` 比對 |
| Proxmox Backup Server | 017 | pbs31 | 主機上下載 .deb，先裝 lsb-release 再 `dpkg -i`（9-10） |
| Ubuntu 24.04 容器 | 013 | ai | 節點上 `pct push` + `pct exec`（安裝前先以 `dpkg -l` 確認未安裝） |

共 17 個 Agent，全部 Active。

服務內部名稱為 `WazuhSvc`，顯示名稱為 `Wazuh`；`NET START`／`NET STOP` 用顯示名稱或內部名稱皆可，PowerShell 可用 `Restart-Service WazuhSvc`。

### 9-9 網域控制站與 CA（DC01、DC02、CA）

安裝方式與 9-8 相同（MSI + PowerShell），差別在安裝前後的檢查。

| VMID | 名稱 | 節點 |
| --- | --- | --- |
| 106 | DC01 | node12 |
| 107 | DC02 | node11 |
| 111 | CA | node12 |

#### (1) 安裝前：快照與 VM-GenerationID

~~~bash
qm config <VMID> | grep -E 'vmgenid|ostype'
qm snapshot <VMID> pre-wazuh-agent --description "before Wazuh agent install"
qm listsnapshot <VMID>
~~~

**網域控制站的快照回復有風險。** 多台 DC 的環境中，把其中一台回復到舊快照，可能造成 **USN rollback**：這台 DC 的複寫紀錄倒退，與其他 DC 不一致。Windows Server 2012 以後搭配 hypervisor 的 **VM-GenerationID**（PVE 的 `vmgenid` 設定）可以偵測回復並保護 AD，因此要先確認 `vmgenid` 存在。即使有保護，**DC 的快照只作為最後手段**；Agent 有問題時優先解除安裝，而不是回復快照。

本案結果（2026-09-30）：DC01（106）、DC02（107）、CA（111）皆為 `ostype: win11`，且都有 `vmgenid`，具備回復偵測保護。

快照：DC01 16:34:51、CA 16:34:57、DC02 16:35:36 建立完成。輸出中的 `freeze guest filesystem`／`thaw guest filesystem` 表示 VM 內的 QEMU Guest Agent 在快照前凍結檔案系統，取得一致的狀態；CA 另有 EFI 與 TPM state 磁碟一併快照。

`qm listsnapshot` 出現 `Wide character in printf`、中文描述變成亂碼，是命令列輸出編碼的顯示問題，不影響快照；描述改用英文即可避免。

#### (2) 安裝前：記錄 AD 健康基準（在 DC 上，系統管理員 PowerShell）

~~~powershell
netdom query fsmo                       # 哪台 DC 持有 FSMO 角色
repadmin /replsummary                   # 複寫摘要，fails 應為 0
dcdiag /q                               # 只列出錯誤；沒有輸出代表健康
Get-Service NTDS,DNS,Netlogon,Kdc | Format-Table Name,Status
~~~

先記下安裝前的結果，安裝後才能比較。安裝順序：先裝**沒有 FSMO 角色**的 DC，確認正常後再裝持有 FSMO 的 DC，最後裝 CA。

CA 的基準：

~~~powershell
Get-Service CertSvc | Format-Table Name,Status
certutil -ping
~~~

本案基準（2026-09-30 16:23）：

| 項目 | 結果 |
| --- | --- |
| FSMO | 5 個角色（架構主機、網域命名主機、PDC、RID 集區管理員、基礎結構主機）**全部在 DC01** |
| 複寫 | `repadmin /replsummary`：DC01、DC02 作為來源與目的地皆為 0／5 失敗，最大差異值約 30～32 分鐘 |
| DC 服務 | DNS、Kdc、Netlogon、NTDS 皆 Running |
| CA | CertSvc Running；`certutil -ping` 連到企業根 CA 的 ICertRequest2 介面，15 ms 回應 |
| `dcdiag /q` | DC01、DC02 皆無輸出（健康） |
| DC02 服務（16:30） | DNS、Kdc、Netlogon、NTDS 皆 Running；複寫 0／5 失敗 |

依此決定順序：**DC02 → DC01 → CA**。

#### (3) 安裝

依 9-8 的步驟執行（Test-NetConnection → 下載 MSI → `Start-Process ... -Wait` → 確認 `<address>` → `NET START Wazuh`）。

#### (4) 安裝後：再跑一次 (2) 的檢查並比較

結果應與安裝前一致。確認後才進行下一台。

**本案實測：DC02（2026-09-30）**

| 檢查 | 安裝前 | 安裝後 |
| --- | --- | --- |
| 1515 連線 | — | `TcpTestSucceeded : True` |
| `<address>` | — | 192.0.2.32 ✅ |
| 服務 | — | `NET START Wazuh` 成功；WazuhSvc Running |
| Agent log | — | 16:45:19 `Connected to the server` |
| `dcdiag /q` | 無輸出 | **無輸出** ✅ |
| 複寫 | 0／5 失敗 | **0／5 失敗**、0 錯誤 ✅ |
| DNS、Kdc、Netlogon、NTDS | Running | **Running** ✅ |

安裝前後一致，Agent 未影響 AD。

**本案實測：DC01（持有全部 FSMO，2026-09-30）**

| 檢查 | 安裝前 | 安裝後 |
| --- | --- | --- |
| 1514／1515 連線 | — | 皆 `TcpTestSucceeded : True` |
| `<address>` | — | 192.0.2.32 ✅ |
| 服務 | — | `NET START Wazuh` 成功；WazuhSvc Running |
| Agent log | — | 16:48:32 `Connected to the server` |
| `dcdiag /q` | 無輸出 | **無輸出** ✅ |
| 複寫 | 0／5 失敗 | **0／5 失敗**、0 錯誤 ✅ |
| DNS、Kdc、Netlogon、NTDS | Running | **Running** ✅ |
| FSMO | 5 個角色在 DC01 | **5 個角色仍在 DC01** ✅ |

**本案實測：CA（2026-09-30）**

| 檢查 | 安裝前 | 安裝後 |
| --- | --- | --- |
| 1514／1515 連線 | — | 皆 `TcpTestSucceeded : True` |
| `<address>` | — | 192.0.2.32 ✅ |
| 服務 | — | `NET START Wazuh` 成功；WazuhSvc Running |
| Agent log | — | 16:54:52 `Connected to the server` |
| CertSvc | Running | **Running** ✅ |
| `certutil -ping` | 成功（15 ms） | **成功（16 ms）** ✅ |

複寫的「最大差異值」由約 30 分鐘變成約 52 分鐘，只代表這段期間沒有 AD 變更需要複寫，不是異常。

#### 注意

- 網域控制站的 Security 事件記錄量很大（登入、Kerberos 票證等），接上後告警與 Indexer 使用量會明顯增加，需觀察 CT 112 的 rootfs 與 CPU。
- 快照觀察 1～2 天後刪除：`qm delsnapshot <VMID> pre-wazuh-agent`。本案已於 2026-10-02 刪除 VM 106、107、111 的快照；刪除前先用 `qm listsnapshot` 確認只刪 `pre-wazuh-agent`。DC02 當時已不在原節點（`107.conf does not exist`），需先用 `pvesh get /cluster/resources --type vm` 找到所在節點再操作；兩台 DC 仍在不同節點。

### 9-10 Proxmox Backup Server（PBS31）

PBS 是獨立主機，不在 PVE 的 VM／CT 清單中；做法與 PVE 節點相同（9-2、9-2a），直接在 PBS 上以 root 執行。

~~~bash
# 1. 環境確認
proxmox-backup-manager versions
cat /etc/debian_version
dpkg -l | grep -i wazuh || echo "尚未安裝"
timeout 3 bash -c '</dev/tcp/192.0.2.32/1514' && timeout 3 bash -c '</dev/tcp/192.0.2.32/1515' && echo "port OK"

# 2. 先裝相依套件，再帶環境變數全新安裝（不新增 Wazuh 套件庫）
apt-get install -y lsb-release
cd /tmp
wget https://packages.wazuh.com/4.x/apt/pool/main/w/wazuh-agent/wazuh-agent_4.14.8-1_amd64.deb
WAZUH_MANAGER='192.0.2.32' dpkg -i ./wazuh-agent_4.14.8-1_amd64.deb

# 3. 啟動前確認位址
grep -A2 '<server>' /var/ossec/etc/ossec.conf

# 4. 啟動
systemctl daemon-reload
systemctl enable --now wazuh-agent
systemctl is-active wazuh-agent
rm -f /tmp/wazuh-agent_4.14.8-1_amd64.deb
~~~

注意：

- 避開排程備份時段（本案每天 21:00）安裝，雖然 Agent 不會重啟 PBS 服務，仍以不干擾備份為原則。
- **不要把 datastore 目錄加入 FIM**：備份資料量大、變動頻繁，會產生大量事件並拖慢掃描。預設 FIM 只監控系統目錄，不包含 datastore。
- 安裝後確認 PBS 服務不受影響：`systemctl is-active proxmox-backup proxmox-backup-proxy`。

**本案實測（2026-09-30）**：

| 項目 | 結果 |
| --- | --- |
| 版本 | proxmox-backup-server 4.2.6-1（running 4.2.6），Debian 13.7 |
| 事前檢查 | 尚未安裝；1514／1515 `port OK` |
| `<address>` | 192.0.2.32 ✅（先裝 lsb-release 再全新安裝，位址一次寫入） |
| 服務 | wazuh-agent enable 並 active |
| PBS 服務 | proxmox-backup、proxmox-backup-proxy 皆 active ✅ |
| Manager | `ID: 017, Name: pbs31, Active` |

第一次貼上 Port 測試指令時被換行截斷，出現 `bash: -c: option requires an argument`；重新完整貼上一行即正常。

## 10. 資料保留（30 天）

### 10-1 先看空間用在哪裡（2026-10-02 實測，17 台 Agent 上線約 2 天）

| 位置 | 大小 | 內容 |
| --- | --- | --- |
| `/var/ossec/queue/vd` | 9.9 GB | 弱點偵測內容資料庫（CVE 情資），大小相對固定 |
| `/var/ossec/queue/indexer` | 1.7 GB | 等待送往 Indexer 的佇列，需觀察是否持續成長 |
| `/var/ossec/queue/db` | 201 MB | 各 Agent 的本機資料庫 |
| `/var/lib/wazuh-indexer` | 131 MB | 全部索引 |
| `/var/ossec/logs/alerts` | 95 MB | 告警的文字檔備份（alerts.json／alerts.log），**預設永不刪除** |

每日告警索引：9/30 約 48 MB（含初始掃描）、10/01 約 42.5 MB（第一個完整的一天）。索引日期以 UTC 切分。告警本身佔用很小，磁碟主要被弱點資料庫使用。

### 10-2 Indexer：告警索引保留 30 天（ISM）

在 CT 112 內建立政策檔：

~~~bash
cat > /root/wazuh-alerts-30d.json <<'JSONEOF'
{
  "policy": {
    "description": "Delete wazuh-alerts indices older than 30 days",
    "default_state": "hot",
    "states": [
      {
        "name": "hot",
        "actions": [],
        "transitions": [ { "state_name": "delete", "conditions": { "min_index_age": "30d" } } ]
      },
      {
        "name": "delete",
        "actions": [ { "delete": {} } ],
        "transitions": []
      }
    ],
    "ism_template": [ { "index_patterns": ["wazuh-alerts-*"], "priority": 100 } ]
  }
}
JSONEOF
~~~

建立政策，並套用到**已經存在**的告警索引（`ism_template` 只會自動套用到之後新建的索引）：

~~~bash
curl -sk -u admin -X PUT 'https://127.0.0.1:9200/_plugins/_ism/policies/wazuh-alerts-30d' \
  -H 'Content-Type: application/json' -d @/root/wazuh-alerts-30d.json

curl -sk -u admin -X POST 'https://127.0.0.1:9200/_plugins/_ism/add/wazuh-alerts-*' \
  -H 'Content-Type: application/json' -d '{"policy_id": "wazuh-alerts-30d"}'

curl -sk -u admin 'https://127.0.0.1:9200/_plugins/_ism/explain/wazuh-alerts-*?pretty' | grep -E '"index"|policy_id'
~~~

每個指令都會詢問 admin 密碼。也可以在 Dashboard 的 **Index Management → Index policies** 建立同樣的政策。

**本案實測（2026-10-02）**：

| 步驟 | 結果 |
| --- | --- |
| PUT 政策 | 回傳 `"_id":"wazuh-alerts-30d"`；系統自動為 delete 動作加上重試（3 次、指數退避、初始 1 分鐘） |
| 套用到現有索引 | `"updated_indices":3`、`"failures":false` |
| explain | 9/30、10/01、10/02 三個告警索引的 `policy_id` 皆為 `wazuh-alerts-30d` |

`min_index_age` 從索引建立時間起算，9/30 的索引預計在 10/30 左右被刪除；ISM 每隔一段時間才檢查一次，實際刪除時間會稍晚。

### 10-3 Manager：告警文字檔保留 30 天

Indexer 的政策管不到 `/var/ossec/logs/alerts/`。以排程刪除 30 天前、已按日期歸檔的檔案（只處理年份子目錄，不碰目前正在寫入的 alerts.json）：

~~~bash
cat > /etc/cron.d/wazuh-alerts-cleanup <<'CRONEOF'
# Remove archived Wazuh alert logs older than 30 days
17 3 * * * root find /var/ossec/logs/alerts/20* -type f -mtime +30 -delete; find /var/ossec/logs/alerts/20* -mindepth 1 -type d -empty -delete
CRONEOF
chmod 644 /etc/cron.d/wazuh-alerts-cleanup
find /var/ossec/logs/alerts/20* -type f -mtime +30 | head    # 先預覽：目前應沒有符合的檔案
~~~

本案實測（2026-10-02）：已建立 `/etc/cron.d/wazuh-alerts-cleanup`（權限 644）；預覽沒有符合的檔案。cron 會忽略權限或擁有者不正確的設定檔且不報錯，建立後用 `ls -l` 確認為 `-rw-r--r-- root`。

### 10-4 注意

- 30 天後的告警無法再查詢。PBS 排程的保留策略（keep-daily 7、keep-last 3）也只涵蓋約一週，**沒有更長期的告警副本**；若日後有稽核或事件調查需求，需重新評估保留天數或另行封存。
- `/var/ossec/queue` 內的檔案由 Manager 管理，不要手動刪除。持續觀察 `du -sh /var/ossec/queue/*`，特別是 `indexer` 是否不斷成長。

## 11. 告警調校

### 11-1 先找出最常觸發的規則

在 CT 112 內對 Indexer 做彙總查詢，取過去 24 小時數量最多的 15 條規則：

~~~bash
cat > /root/top-rules.json <<'JSONEOF'
{
  "size": 0,
  "query": { "range": { "timestamp": { "gte": "now-24h" } } },
  "aggs": {
    "rules": {
      "terms": { "field": "rule.id", "size": 15 },
      "aggs": {
        "desc":   { "terms": { "field": "rule.description", "size": 1 } },
        "level":  { "max":   { "field": "rule.level" } },
        "agents": { "terms": { "field": "agent.name", "size": 3 } }
      }
    }
  }
}
JSONEOF
curl -sk -u admin 'https://127.0.0.1:9200/wazuh-alerts-*/_search' \
  -H 'Content-Type: application/json' -d @/root/top-rules.json > /root/top-rules.out
head -c 100 /root/top-rules.out; echo     # 必須是 { 開頭；若是 Unauthorized 代表密碼錯誤
~~~

再用 Python 整理成表格（見本案操作紀錄）。輸出存檔時錯誤訊息也會被寫進檔案，所以存完要先看開頭。

**本案前 15 名（2026-10-02，過去 24 小時）**：

| 規則 | 等級 | 數量 | 說明 | 主要主機 | 分類 |
| --- | --- | --- | --- | --- | --- |
| 52002 | 3 | 75,070 | AppArmor DENIED | node10 | 根因待查 |
| 60137 | 3 | 13,968 | Windows User Logoff | DC02、DC01 | 正常活動 |
| 60106 | 3 | 8,003 | Windows Logon Success | DC02、DC01 | 正常活動（需保留人員登入） |
| 40704 | 5 | 6,183 | Systemd: Service exited due to a failure | ai | 根因待查 |
| 31101 | 5 | 1,865 | Web server 400 error code | librenms | 待查 |
| 750 | 5 | 1,693 | Registry Value Integrity Checksum Changed | DC01、WinClient、ca | 掃描類 |
| 510 | 7 | 1,344 | rootcheck 異常 | wazuh、AdGuard、Graylog（容器） | 掃描類 |
| 5501／5502 | 3 | 各約 1,300 | PAM 工作階段開啟／關閉 | 三台 PVE 節點 | 推測為 ProxCenter 定期登入 |
| 5402 | 3 | 1,281 | Successful sudo to ROOT | 三台 PVE 節點 | 同上 |
| 61104 | 3 | 1,012 | 服務啟動類型變更 | DC01、DC02、ca | 待查 |
| 60642 | 3 | 330 | Software protection service scheduled | ca、DC01、DC02 | 正常活動 |
| 550 | 7 | 326 | Integrity checksum changed | ubclient、node11、node12 | 掃描類 |

原則：先處理「可能有東西壞了」的類別，修好根因後告警自然消失；正常活動只針對特定主機或帳號降級，不整條關閉。

### 11-2 AppArmor DENIED（52002）與 ai 服務失敗（40704）

**追查**（node10）：

~~~bash
journalctl -k --since "1 hour ago" | grep 'apparmor="DENIED"' \
  | sed -E 's/.*operation="([^"]*)".*profile="([^"]*)".*name="([^"]*)".*comm="([^"]*)".*/\1 | \2 | \3 | \4/' \
  | sort | uniq -c | sort -rn | head -10
~~~

一小時 2,178 次皆為同一組合：namespace `lxc-113`（ai 容器）、profile `rsyslogd`、操作 `sendmsg`、目標 `/run/systemd/journal/dev-log`、程式 `systemd-journal`。容器內 Ubuntu 24.04 的 rsyslog AppArmor 規則擋下 journald 轉送日誌；容器與主機共用 kernel，紀錄寫在 node10 的 kernel 日誌，被 node10 的 Agent 收集。

40704 來自 ai 容器內的 `hermes-gateway.service`：

| 發現 | 說明 |
| --- | --- |
| 系統層級服務 | `/etc/systemd/system/hermes-gateway.service`，PID 287，自 9/29 穩定運作 |
| **使用者層級服務** | `/root/.config/systemd/user/hermes-gateway.service`（8/27 建立，非刻意設定），由 `systemd[264]`（root 的使用者層級 systemd）啟動，**restart counter 13,270** |
| 原因 | 兩個 gateway 搶同一個 Telegram Bot，使用者層級的啟動約 20 秒後失敗退出、再被重啟 |
| 網路 | `api.telegram.org` 的 DNS 優先回 IPv6，但容器沒有 IPv6 路由（`curl -6` 立即失敗，`curl -4` 回 302） |

每次失敗都印出數十行 traceback，journald 每一行都轉給 rsyslog、每一行都被 AppArmor 擋，因此兩條告警量都很大。

**處理**（node10，保留系統層級的 gateway）：

~~~bash
pct exec 113 -- systemctl --user --machine=root@.host disable --now hermes-gateway.service
pct exec 113 -- bash -c "ps -ef | grep -v grep | grep 'gateway run'"      # 只剩 --replace 那個
pct exec 113 -- bash -c "grep -q '^precedence ::ffff:0:0/96' /etc/gai.conf || echo 'precedence ::ffff:0:0/96  100' >> /etc/gai.conf"
pct exec 113 -- getent ahosts api.telegram.org | head -3                    # 第一筆應為 IPv4
pct exec 113 -- systemctl restart hermes-gateway
~~~

`/etc/gai.conf` 的 precedence 設定讓系統連線時優先使用 IPv4，不需要變更容器網路。

**驗證（處理後 10 分鐘）**：

| 檢查 | 處理前（10 分鐘） | 處理後 |
| --- | --- | --- |
| 使用者層級 gateway 失敗 | 約 30 次 | **0** |
| Telegram `Timed out` | 持續出現 | **0** |
| node10 AppArmor DENIED | 約 360 次 | **8** |

AppArmor 告警減少約 98%。剩餘的是正常日誌量造成的轉送阻擋，可再停用容器內 rsyslog 的 AppArmor 規則（容器本身仍受主機 LXC AppArmor 規則限制）：

~~~bash
pct exec 113 -- ln -s /etc/apparmor.d/usr.sbin.rsyslogd /etc/apparmor.d/disable/usr.sbin.rsyslogd
pct exec 113 -- apparmor_parser -R /etc/apparmor.d/usr.sbin.rsyslogd
pct exec 113 -- systemctl restart rsyslog
~~~

本案結果（2026-10-02）：三行指令第一次執行皆無輸出（成功）；重複執行時出現 `File exists`、`Profile doesn't exist`，代表第一次已完成，不是錯誤。`/sys/kernel/security/apparmor/profiles` 已無 rsyslogd，rsyslog 維持 active。

復原方式：刪除 `disable/` 內的連結，再以 `apparmor_parser -r` 重新載入並重啟 rsyslog。

**移除規則後仍被擋：要一併重啟 journald。** 移除規則、重啟 rsyslog 後，node10 仍出現同樣的 DENIED（profile 仍為 `rsyslogd`，對象是自 9/29 未重啟的 journald，PID 6881）；`logger` 測試訊息也沒有寫入 syslog。檢查發現 ai 容器的 `/var/log/syslog` **最後一筆停在 9/29 開機時**，也就是這三天 rsyslog 完全收不到 journald 轉送的日誌。推測 journald 既有的 socket 仍帶著舊規則的標記，重啟相關服務後解決：

~~~bash
pct exec 113 -- systemctl restart systemd-journald
pct exec 113 -- systemctl restart syslog.socket rsyslog
pct exec 113 -- logger -t wazuhtest "rsyslog test after journald restart"
pct exec 113 -- tail -3 /var/log/syslog      # 最後一行出現 wazuhtest 即正常
~~~

本案結果：syslog 出現 03:27（UTC）rsyslog 啟動紀錄與測試訊息，停擺三天的 syslog 恢復寫入。之後追蹤 node10 的 kernel 日誌，最後一筆 DENIED 發生在重啟當下的 11:27:09（台灣時間），之後不再出現，52002 告警歸零。rsyslog 啟動時的 `imklog: cannot open kernel log (/proc/kmsg): Permission denied` 是非特權容器的正常限制。

## 風險與注意事項

- **LXC 不是 Wazuh 官方列出的標準部署形態**（官方以實體機、VM、容器映像為主）。LXC 可以跑，但遇到問題時要先排除「kernel 參數」「cgroup 資源限制」這類容器特有原因。追求官方支援與隔離度時，改用 VM 較單純。
- 所有節點 `vm.max_map_count` 都必須 ≥ 262144，否則 HA／遷移後 Indexer 可能起不來。
- 資料量成長很快，需規劃 Index 保留天數（Index State Management），並監控 rootfs 用量。
- Indexer 對儲存 I/O 敏感；放在 Ceph 上時，觀察 Ceph 延遲是否因此上升。
- PVE 節點裝上 Agent 後告警量會明顯增加（`/etc/pve` 變更、套件異動、CIS 設定稽核），先觀察再調校，不要一次關閉大量規則。
- 文中 IP 皆為文件示範位址（192.0.2.0/24），指令執行前請替換。

## 參考資料

- [Wazuh Quickstart（All-in-one 安裝）](https://documentation.wazuh.com/current/quickstart.html)
- [Wazuh 安裝指南](https://documentation.wazuh.com/current/installation-guide/index.html)
- [Wazuh 密碼管理](https://documentation.wazuh.com/current/user-manual/user-administration/password-management.html)
- [Proxmox VE：Linux Container](https://pve.proxmox.com/wiki/Linux_Container)
- [Proxmox VE：pct 手冊](https://pve.proxmox.com/pve-docs/pct.1.html)
