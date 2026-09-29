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
| 1 | PVE 節點設定 `vm.max_map_count` | 已完成 | 2026-09-29：三台已移除誤寫入的 99-wazuh.conf；值皆 ≥ 262144 |
| 1b | 清除 node10 主機上的 Wazuh | 已實測 | 2026-09-29：node10 已完整移除 Wazuh 4.14.8，套件、服務、Port、套件庫皆清空，`vm.max_map_count` 回到 1048576；殘留日誌目錄與 wazuh-indexer 帳號也已清除（見 1-4） |
| 2 | 下載 Ubuntu 22.04 範本 | 已完成 | 2026-09-29：使用 ubuntu 22.04 範本 |
| 3 | 建立 LXC | 已實測 | 2026-09-29：CT 112 位於 node12；已補 nesting=1、onboot=1，rootfs 線上加大為 80G（見 3-4） |
| 4 | 容器內基本設定 | 待做 | |
| 5 | 安裝 Wazuh All-in-one | 待做 | |
| 6 | 驗證服務與登入 Dashboard | 待做 | |
| 7 | 安全收尾（密碼、防火牆、鎖定套件庫） | 待做 | |
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

### 1-1 本案實測與修正（2026-09-29）

**第一次檢查：** node11、node12 原值是 `1048576`，node10 是 `262144`，全部都已經 ≥ 262144，其實不需要設定。但當時直接執行了「寫入 99-wazuh.conf」，node11、node12 因此被**調小**成 262144。

**移除 99-wazuh.conf 後，node10 仍是 262144。** 用 `grep` 查設定來源：

| 設定檔 | 值 | 來源判讀 |
| --- | --- | --- |
| `/usr/lib/sysctl.d/10-pve-ct-inotify-limits.conf` | 262144 | PVE 內建 |
| `/usr/lib/sysctl.d/50-default.conf` | 1048576 | systemd 內建 |
| `/etc/sysctl.d/99-wazuh-indexer.conf` | 262144 | **Wazuh Indexer 留下的檔案** |
| `/usr/lib/sysctl.d/wazuh-indexer.conf` | 262144 | **Wazuh Indexer 套件提供的檔案** |
| `/etc/sysctl.d/99-wazuh.conf` | 262144 | 本次誤寫入，已移除 |

`sysctl --system` 會把 `/etc`、`/run`、`/usr/lib` 各目錄的檔案合在一起**依檔名排序**，後載入的覆蓋前面的。`wazuh-indexer.conf` 以 w 開頭，排序在所有數字開頭的檔案之後，所以最後生效的是 262144。

**進一步追查：** PVE 主機上出現 wazuh-indexer 的設定檔，代表這台節點可能安裝過 Wazuh。Wazuh 應該只裝在 CT 112 裡；主機上若有殘留服務，會占用記憶體，也會開啟不必要的 Port。確認方式：

~~~bash
dpkg -l | grep -i wazuh
systemctl list-units --all | grep -i wazuh
ss -tlnp | grep -E ':9200|:9300|:1514|:1515|:55000|:443 '
ls /etc/apt/sources.list.d/ | grep -i wazuh
~~~

學到的事：

- 改 kernel 參數前，先用 `grep` 找出目前由哪些檔案設定、哪一個最後生效。
- sysctl 設定檔依「檔名」排序，不是依「目錄」排序。
- 主機上出現不認識的設定檔時，先查是哪個套件留下的（`dpkg -S <檔案路徑>`），不要直接刪除。

### 1-2 發現：node10 主機上跑著完整的 Wazuh（2026-09-29）

| 檢查 | node10 結果 |
| --- | --- |
| 套件 | wazuh-dashboard、wazuh-indexer、wazuh-manager，皆為 4.14.8-1 |
| 服務 | 三個服務都 active (running) |
| Port | 1514、1515、55000 對所有介面開放；9200、9300 只聽 127.0.0.1 |
| 套件庫 | `/etc/apt/sources.list.d/wazuh.list` 存在 |
| node11、node12 | 沒有 Wazuh 套件 |

也就是說，node10 主機本身就是一台 Wazuh All-in-one。這解釋了 node10 的 `vm.max_map_count` 為何一開始就是 262144。

**為什麼不該留在 PVE 主機上：**

- Indexer 的 Java heap 會占用數 GB 記憶體，和 VM、Ceph OSD 搶資源。
- 1514／1515／55000 對外開放，擴大主機的攻擊面。
- Wazuh 套件庫留在主機上，日後 `apt full-upgrade` 可能連帶升級，影響 PVE 更新流程。
- 無法享有 CT 的備份、快照、遷移與 HA。

**處理決定（2026-09-29）：完整移除**，改在 CT 112 重新安裝。

#### 1-3 移除 PVE 主機上的 Wazuh（在 node10 執行）

**(1) 移除前清點**：記下有哪些 Agent 註冊在這台，日後要把它們改指到 CT 112。

~~~bash
/var/ossec/bin/agent_control -l
dpkg -l | grep -E 'wazuh|filebeat'     # All-in-one 通常還會裝 filebeat
free -h
~~~

**(2) 停止並停用服務**

~~~bash
systemctl disable --now wazuh-dashboard wazuh-manager wazuh-indexer
systemctl disable --now filebeat 2>/dev/null
~~~

**(3) 移除套件與資料目錄**（依 Dashboard → Manager → Filebeat → Indexer 順序）

~~~bash
apt-get remove --purge -y wazuh-dashboard
rm -rf /var/lib/wazuh-dashboard /usr/share/wazuh-dashboard /etc/wazuh-dashboard

apt-get remove --purge -y wazuh-manager
rm -rf /var/ossec

apt-get remove --purge -y filebeat     # 若 (1) 沒看到 filebeat 可略過
rm -rf /var/lib/filebeat /usr/share/filebeat /etc/filebeat

apt-get remove --purge -y wazuh-indexer
rm -rf /var/lib/wazuh-indexer /usr/share/wazuh-indexer /etc/wazuh-indexer

systemctl daemon-reload
~~~

`rm -rf` 前請逐字核對路徑，特別注意不要多打空白（例如 `/ var`）。

**(4) 移除套件庫、sysctl 檔與安裝殘留**

~~~bash
rm -f /etc/apt/sources.list.d/wazuh.list /usr/share/keyrings/wazuh.gpg
rm -f /etc/sysctl.d/99-wazuh-indexer.conf
rm -f /root/wazuh-install.sh /root/wazuh-install-files.tar /var/log/wazuh-install.log
apt update
sysctl --system > /dev/null
~~~

`wazuh-install-files.tar` 內含舊安裝的全部密碼，舊系統移除後即無用途，直接刪除。

**(5) 驗證乾淨**

~~~bash
dpkg -l | grep -E 'wazuh|filebeat'                      # 應無輸出（或只剩 rc 狀態，可再 purge）
systemctl list-units --all | grep -iE 'wazuh|filebeat'   # 應無輸出
ss -tlnp | grep -E ':443 |:1514|:1515|:9200|:9300|:55000' # 應無 Wazuh 程序
ls /etc/apt/sources.list.d/ | grep -i wazuh              # 應無輸出
sysctl vm.max_map_count                                  # 應回到 1048576
free -h                                                  # 和 (1) 比較，記憶體應釋放
apt autoremove --dry-run                                 # 只列出、不執行；確認清單都是 Wazuh 相依套件再決定
~~~

PVE 主機上不要直接執行 `apt autoremove -y`，先用 `--dry-run` 看清單，避免移除 PVE 需要的套件。

#### 1-4 移除結果（2026-09-29，node10）

| 檢查 | 結果 |
| --- | --- |
| Wazuh／filebeat 套件 | 無 |
| Wazuh／filebeat 服務 | 無 |
| 443／1514／1515／9200／9300／55000 | 無程序監聽 |
| Wazuh 套件庫 | 已移除 |
| `vm.max_map_count` | 1048576（回到 systemd 預設） |
| 移除前清點 | Agent 只有 000（node10 自己）；另有 filebeat 7.10.2-2 |
| 記憶體（移除前 → 後） | used 13 → 11 GiB、buff/cache 27 → 15 GiB、available 48 → 50 GiB |
| 磁碟釋放 | 套件約 3.4 GB（dashboard 1,049 MB、manager 1,152 MB、indexer 1,105 MB、filebeat 73.6 MB），另加資料目錄 |
| `apt autoremove --dry-run` | 只列出 libmpfr6、libsigsegv2 兩個小型函式庫；判定保留不處理 |

移除前沒有任何外部 Agent 註冊到 node10，因此這次移除不會造成其他主機斷線。

`apt purge` 過程出現 `directory ... not empty so not removed` 警告：套件只刪自己安裝的檔案，執行期間產生的資料與日誌會留下。其中 `/var/lib/wazuh-indexer`、`/etc/wazuh-indexer`、`/etc/filebeat`、`/usr/share/filebeat` 已由後續 `rm -rf` 清除；`/var/log/wazuh-indexer` 不在原清單內，需補清：

~~~bash
ls -d /var/log/wazuh-indexer /var/log/filebeat /var/lib/wazuh-indexer /etc/wazuh-indexer \
      /etc/filebeat /usr/share/filebeat /var/ossec 2>&1
rm -rf /var/log/wazuh-indexer /var/log/filebeat

# 套件建立的系統帳號（有列出才處理）
getent passwd | grep -E 'wazuh|filebeat'
getent group  | grep -E 'wazuh|filebeat'
~~~

本案結果：其他目錄都已不存在，只剩 `/var/log/filebeat`、`/var/log/wazuh-indexer`，已用 `rm -rf` 清除。另留下系統帳號 `wazuh-indexer`（UID 999、GID 990、shell 為 nologin）。確認沒有檔案仍屬於它之後再刪除：

~~~bash
find / -xdev -uid 999 2>/dev/null | head     # -xdev：不跨掛載點，避免掃到 /etc/pve、CephFS
ls -ld /home/wazuh-indexer 2>&1
userdel wazuh-indexer                        # 同名主群組通常會一併刪除
getent passwd wazuh-indexer; getent group wazuh-indexer   # 應無輸出
~~~

本案結果：`find` 無輸出、`/home/wazuh-indexer` 不存在；`userdel` 後帳號與群組皆已刪除，兩個日誌目錄也確認不存在。**node10 主機上的 Wazuh 已完全清除。**

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

## 5. 安裝 Wazuh All-in-one

使用官方安裝助手。2026-09-29 從 Wazuh 套件庫取得的版本是 4.14.8，因此網址使用 `4.14`；日後請以 [Quickstart](https://documentation.wazuh.com/current/quickstart.html) 當下的版本號為準：

~~~bash
cd /root
curl -sO https://packages.wazuh.com/4.14/wazuh-install.sh
bash ./wazuh-install.sh -a
~~~

- `-a` 代表 All-in-one：同時安裝 Indexer、Server、Dashboard。
- 安裝約需 10～20 分鐘，視網路與儲存速度而定。
- 結束時畫面會顯示 Dashboard 網址、帳號 `admin` 與隨機密碼。**只記在密碼管理工具，不要貼進本倉庫或聊天紀錄。**
- 所有元件密碼另存於 `/root/wazuh-install-files.tar` 的 `wazuh-passwords.txt`。

安裝助手若因硬體檢查中止，先回頭確認 CPU／RAM 是否達標。`-i`（忽略檢查）只在確認資源足夠、且理解風險時才使用。

## 6. 驗證服務與登入 Dashboard

~~~bash
systemctl status wazuh-indexer wazuh-manager wazuh-dashboard --no-pager
/var/ossec/bin/wazuh-control status
ss -tlnp | grep -E ':443|:1514|:1515|:9200|:55000'
~~~

從管理電腦瀏覽 `https://192.0.2.32`，以 `admin` 登入。憑證是自簽，瀏覽器會出現警告，確認網址無誤後繼續。

驗收標準：三個服務都 `active (running)`、Port 都在監聽、Dashboard 能登入並看到 Wazuh Server 本身（agent 000）。

## 7. 安全收尾

### 7-1 換掉預設密碼

~~~bash
tar -O -xvf /root/wazuh-install-files.tar wazuh-install-files/wazuh-passwords.txt | less
# 依官方文件使用 wazuh-passwords-tool.sh 變更 admin 密碼
~~~

`wazuh-install-files.tar` 含全部密碼，確認已安全保存後，移到只有管理者能存取的位置或刪除。

### 7-2 暫停 Wazuh 套件自動更新

Wazuh 各元件版本要一致才能正常運作，`apt upgrade` 時被單獨升級容易出問題。官方建議安裝後先停用套件庫，升級時再依官方升級程序手動打開：

~~~bash
sed -i "s/^deb /#deb /" /etc/apt/sources.list.d/wazuh.list
apt update
~~~

### 7-3 限制誰能連

建議在 PVE Firewall（CT → Firewall）只開放必要來源：

| Port | 允許來源 |
| --- | --- |
| 443/tcp | 管理網段 |
| 1514/tcp、1515/tcp | 需要裝 Agent 的主機網段 |
| 55000/tcp | 管理網段（沒有用 API 可不開） |
| 22/tcp | 管理網段 |

開啟防火牆前，先加好管理網段的允許規則，避免把自己擋在外面。

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
