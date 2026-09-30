---
layout: default
title: "在 PVE Cluster 用 LXC 架設 Wazuh（Ubuntu 22.04）"
date: 2026-09-29
categories: [PVE, LXC, Wazuh, Security]
permalink: /docs/pve/wazuh-lxc-ubuntu2204-sop/
last_modified_at: 2026-09-29
---

# 在 PVE Cluster 用 LXC 架設 Wazuh（Ubuntu 22.04）

Graylog 負責「把日誌收集起來、查得到」；Wazuh 則多做一層「安全判讀」：主機完整性檢查（FIM）、弱點偵測、設定稽核與入侵告警。本文記錄在 PVE Cluster 上建立一台 Ubuntu 22.04 LXC，以 All-in-one（Indexer + Server + Dashboard 同一台）方式安裝 Wazuh 的步驟。

> 文件狀態：**草稿，邊做邊寫**（2026-09-29 起）。下方「進度表」會隨實際操作更新；尚未標示「已實測」的步驟，都只是預定作法，不是完成報告。

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
| 7 | 安全收尾（密碼、防火牆、鎖定套件庫） | 進行中 | 2026-09-30：7-1 密碼更換完成、Dashboard 新密碼登入 OK；7-2 套件庫已停用；7-3 資料中心防火牆未啟用、另案規劃；7-4 API 已改為只聽 127.0.0.1 |
| 8 | 備份與 HA | 待做 | |
| 9 | 第一台 Agent（建議先接一台 PVE 節點） | 待做 | |

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
| Dashboard 與外部 55000 測試 | 待確認 |

升級 Wazuh 後要再檢查一次這行設定是否保留。

**回復方式**：

~~~bash
cp -a /var/ossec/api/configuration/api.yaml.bak-<日期> /var/ossec/api/configuration/api.yaml
systemctl restart wazuh-manager
~~~

**判讀限制**：管理與 Agent 都在同一網段時，這組規則的主要效果是關閉 55000 與其他未列出的 Port，並阻擋其他網段（如 VPN、其他 VLAN）連入；同網段內的主機仍可連 443／1514／1515。

## 8. 備份與 HA

- 將 CT 加入既有 PBS 備份排程；Indexer 持續寫入，建議用 snapshot 模式，並另排一次還原測試。
- 要加入 HA 前，確認：rootfs 在共用儲存、所有節點都已完成步驟 1、`nesting=1` 已設定。
- 做一次手動遷移（`pct migrate` 或 GUI Migrate），確認換節點後 Indexer 能正常啟動。

## 9. 第一台 Agent

建議先把一台 PVE 節點接進來，驗證 1514／1515 通、告警有進 Dashboard，再擴大範圍。詳細步驟待實作時補上。

## 風險與注意事項

- **LXC 不是 Wazuh 官方列出的標準部署形態**（官方以實體機、VM、容器映像為主）。LXC 可以跑，但遇到問題時要先排除「kernel 參數」「cgroup 資源限制」這類容器特有原因。追求官方支援與隔離度時，改用 VM 較單純。
- 所有節點 `vm.max_map_count` 都必須 ≥ 262144，否則 HA／遷移後 Indexer 可能起不來。
- 資料量成長很快，需規劃 Index 保留天數（Index State Management），並監控 rootfs 用量。
- Indexer 對儲存 I/O 敏感；放在 Ceph 上時，觀察 Ceph 延遲是否因此上升。
- 文中 IP 皆為文件示範位址（192.0.2.0/24），指令執行前請替換。

## 參考資料

- [Wazuh Quickstart（All-in-one 安裝）](https://documentation.wazuh.com/current/quickstart.html)
- [Wazuh 安裝指南](https://documentation.wazuh.com/current/installation-guide/index.html)
- [Wazuh 密碼管理](https://documentation.wazuh.com/current/user-manual/user-administration/password-management.html)
- [Proxmox VE：Linux Container](https://pve.proxmox.com/wiki/Linux_Container)
- [Proxmox VE：pct 手冊](https://pve.proxmox.com/pve-docs/pct.1.html)
