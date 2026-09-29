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
| 0 | 規劃資源與網路 | 已實測 | 2026-09-29：PVE 9.2.20、kernel 7.0.14-19-pve、Quorate: Yes；rootfs 選 VM_Pool（RBD），CT ID 待確認 |
| 1 | PVE 節點設定 `vm.max_map_count` | 修正中 | 2026-09-29：三台原值已是 1048576，不需設定；誤寫入的 99-wazuh.conf 將值降為 262144，須移除並復原（見步驟 1 的實測紀錄） |
| 2 | 下載 Ubuntu 22.04 範本 | 待做 | |
| 3 | 建立 LXC | 待做 | |
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

三台節點原值都已是 `vm.max_map_count = 1048576`（`sysctl --system` 輸出可見由既有的系統設定檔提供），其實不需要設定。但當時直接執行了「寫入 99-wazuh.conf」，而 `99-` 開頭的檔案最後載入，會覆蓋前面的設定，結果三台都被**調小**成 262144。

修正方式（每台執行）：

~~~bash
rm -f /etc/sysctl.d/99-wazuh.conf
sysctl --system | grep max_map_count
sysctl vm.max_map_count      # 應回到 1048576
~~~

學到的事：sysctl 設定檔依檔名排序載入，後載入的覆蓋前面的。改 kernel 參數前，先用 `grep` 找出目前由哪個檔案設定。

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
  --swap 0 \
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
| Memory | Memory／Swap | 8192／0 |
| Network | Bridge／IPv4 | vmbr0／Static `192.0.2.32/24`，Gateway `192.0.2.1` |
| DNS | DNS servers | 依環境 |
| Confirm | Start after created | 先不勾，確認設定後再開機 |

### 3-3 開機前檢查並啟動

~~~bash
pct config <CTID>      # 核對 cores、memory、swap、rootfs、net0、unprivileged、features
pct start <CTID>
pct status <CTID>
pct enter <CTID>       # 進入容器
~~~

## 4. 容器內基本設定

以下在容器內執行：

~~~bash
# 網路與 DNS
ip -4 addr show eth0
ping -c 3 192.0.2.1
getent hosts packages.wazuh.com

# 核對 kernel 參數有從主機帶進來
sysctl vm.max_map_count

# 更新系統與必要工具
apt update && apt -y full-upgrade
apt -y install curl gnupg apt-transport-https ca-certificates

# 時區與時間（告警時間要正確）
timedatectl
~~~

若 `packages.wazuh.com` 解析不到，先處理 DNS 或對外防火牆，後續安裝需要連線到此網址。

## 5. 安裝 Wazuh All-in-one

使用官方安裝助手。`4.x` 請換成 [Quickstart](https://documentation.wazuh.com/current/quickstart.html) 頁面上當下的版本號（例：`4.12`）：

~~~bash
cd /root
curl -sO https://packages.wazuh.com/4.x/wazuh-install.sh
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
