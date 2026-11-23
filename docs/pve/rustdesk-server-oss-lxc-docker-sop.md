---
layout: default
title: "在 PVE 用 LXC + Docker 架設 RustDesk Server（開源版）"
date: 2026-11-04
categories: [PVE, LXC, Docker, RustDesk]
permalink: /docs/pve/rustdesk-server-oss-lxc-docker-sop/
last_modified_at: 2026-11-23
---
{% raw %}

# 在 PVE 用 LXC + Docker 架設 RustDesk Server（開源版）

> **一句話**：RustDesk 是開源的遠端桌面軟體；自己架一台 Server（hbbs + hbbr），遠端連線就不用經過別人的伺服器。這篇在 PVE 建一台 LXC，用 Docker Compose 跑 RustDesk Server OSS，再讓 Client 指到自己的 Server。

| 項目 | 內容 |
| --- | --- |
| 適合誰看 | 想在 PVE 自建遠端桌面中繼／註冊服務的人；第一次接觸 RustDesk 的人 |
| 環境 | PVE 9.x；LXC（Ubuntu 22.04 範本，unprivileged）；Docker Compose；`rustdesk/rustdesk-server` 映像檔 |
| 日期 | 2026-11-04（部署）；2026-11-06 結案；2026-11-23 從備份還原為 CT 116，重新啟用（第 7 節） |
| 結論 | ✅ CT 115 完成 RustDesk Server OSS 部署：Docker Compose 跑 hbbs／hbbr、ufw 只放行必要 Port、兩台 Client 互連正常、PBS 備份與還原後 Key 一致、已加入 HA 並驗證遷移；VPN 使用者從外部連入未實測（結案原因見第 6 節）。**已結案**，環境無外部使用者，僅作架設練習；CT 115 已於 2026-11-06 下線並刪除。**2026-11-23 重新啟用**：從 11/04 的 protected 備份還原成 CT 116（VMID 115 已被 nextcloud 使用），沿用原 IP，公鑰雜湊 `42ce40056630` 與 11/04 記錄一致，現有 Client 互連成功；當天又完成映像確認（無新版）、LibreNMS（SNMPv3，關閉 sensors 模組）、HA（ct:116，5／5／5）、DHCP 保留、兩台內網 DNS 記錄，之後再把 IP 調整為同網段另一個位址（第 7-4 節）；套件更新、還原點備份、排程備份結果尚未回報（第 7-3 節） |
| 官方文件 | [RustDesk Server OSS](https://rustdesk.com/docs/en/self-host/rustdesk-server-oss/)、[Docker 安裝](https://rustdesk.com/docs/en/self-host/rustdesk-server-oss/docker/)、[Client 設定](https://rustdesk.com/docs/en/self-host/client-configuration/) |

> 文中 IP 都是文件示範位址（192.0.2.0/24），`<網域>` 請換成自己的網域，指令執行前請替換。

## 1. 先認識幾個名詞

| 名詞 | 白話解釋 | 預設 Port |
| --- | --- | --- |
| **hbbs** | ID／Rendezvous Server：讓 Client 登記自己的 ID、互相「找到對方」、協助穿透 NAT | 21115/tcp、21116/tcp+udp、（選用）21118/tcp |
| **hbbr** | Relay Server：兩台機器無法直連時，由它中繼流量 | 21117/tcp、（選用）21119/tcp |
| **Key（id_ed25519.pub）** | hbbs 第一次啟動自動產生的公鑰；Client 填了才會加密並只連你的 Server | — |
| **NAT 穿透（hole punching）** | 兩端各在路由器後面，先試著打洞直連；失敗才走 hbbr 中繼 | — |
| **OSS 與 Pro** | OSS 免費、只有 hbbs／hbbr；Web 管理介面、API、OIDC、LDAP、2FA、裝置管理屬於 Pro（付費） | — |
| **LXC／CT** | 輕量容器，和 PVE 主機共用 Linux kernel | — |
| **Docker Compose** | 用一個 `compose.yml` 描述並啟動多個容器 | — |

```text
Client A ──21116──▶ hbbs（登記 ID、協助打洞）◀──21116── Client B
    │                                                      │
    └──────── 直連成功：A ◀────────────▶ B ────────────────┘
    │
    └── 直連失敗 ──21117──▶ hbbr（中繼）◀──21117── Client B

hbbs + hbbr 都跑在同一台 LXC（Docker, network_mode: host）
```

## 2. 開工前先決定的事（風險與盲點）

| 項目 | 說明 |
| --- | --- |
| 要不要對外網開放 | 只在內網／VPN 用最安全；要讓外面的人連，需要固定公網 IP 或網域，並在邊界防火牆轉發 Port。是否沿用既有的 WireGuard 入口，請依自己的環境決定 |
| 內網用網域還是 IP | Client 可以直接填 IP；用網域較好維護，但內網解析要正確。內網兩端若出現連不上，請見「常見問題」的 NAT loopback |
| 21118／21119 要不要開 | 只有用 Web Client 才需要。官方警告：這兩個 Port 開著時，hbbs／hbbr 會信任 `X-Real-IP`、`X-Forwarded-For` 標頭而不驗證；要用的話只放在反向代理後面並用防火牆限制，**不用就不要放行**。注意：本案實測這兩個 Port 預設就會監聽，所以要靠防火牆擋，不是不設定就關閉 |
| Key 與 `data` 目錄 | `data` 目錄裡有 Server 的私鑰，遺失或重建後所有 Client 都要重填新 Key。備份 CT 時務必一併涵蓋 |
| 開源版沒有管理介面 | 不能在網頁上看裝置清單、做權限控管；需要這些要評估 Pro |

## 3. 進度表

| # | 步驟 | 狀態 | 實測紀錄 |
| --- | --- | --- | --- |
| 0 | 確認環境、下載範本 | ✅ | 2026-11-04：PVE 9.2.24、kernel 7.0.14-26-pve；cluster nextid 為 115；`local` 下載 Ubuntu 22.04 範本（124M，checksum OK） |
| 1 | 規劃 IP 與 Port | ⏳ | 連線方式：內網＋VPN，不轉發公網 Port；需加入 HA |
| 2 | 建立 LXC | ✅ | 2026-11-04：CT 115 建立並啟動；rootfs 16G 放 VM_Pool、unprivileged、onboot=1；Gateway、外網、DNS 解析皆通；`pct config` 確認 `features: nesting=1,keyctl=1`、`cores: 2` |
| 3 | 容器內安裝 Docker | ⏳ | — |
| 3 | 容器內更新並安裝 Docker | ✅ | 2026-11-04：CT 內 `apt` 更新、時區 Asia/Taipei；Docker 安裝完成，`hello-world` 成功（nesting 有效） |
| 4 | 部署 hbbs／hbbr | ✅ | 2026-11-04：兩容器穩定運行；21115／21116（tcp＋udp）／21117／21118／21119 皆在監聽；`data` 下自動產生 Key 與資料庫 |
| 5 | 取得 Key、設定 Client | ✅ | 2026-11-04：UBClient 與 WinClient 先顯示「就緒」但連線出現「金鑰不符」；用 SHA256 比對發現兩台的 Key 與 Server 不同，重貼 `id_ed25519.pub` 後雜湊一致，UBClient → WinClient 連線成功（見 4-5） |
| 6 | 防火牆與對外連線 | ✅ | 2026-11-04：CT 內 ufw 啟用，只放行 21115／21116（tcp＋udp）／21117；UBClient 實測 21115～21117 連得上、21118／21119 逾時；CT 重開後規則保留、容器自動啟動；ufw 啟用後兩台 Client 互連正常 |
| 7 | 備份與 HA | ✅ | 2026-11-04：既有排程已涵蓋；手動備份完成（protected）；還原成另一個 CT 後公鑰雜湊與原機一致；已加入 HA（ct:115 started）；手動遷移後容器、ufw、Key 與 Client 連線驗證通過 |

## 4. 步驟

### 4-0 確認環境、下載範本

**做什麼**：建 CT 之前，先確認 ID、儲存池、網路橋接與範本都就緒。

**怎麼做**（在 PVE 節點 shell）：

```bash
pveversion
pvesm status
pvesh get /cluster/nextid
pvesh get /cluster/resources --type vm --output-format json-pretty | grep -E '"vmid"|"name"|"node"'
pveam update
pveam available --section system | grep ubuntu-22.04
pveam download local ubuntu-22.04-standard_22.04-1_amd64.tar.zst
pveam list local
```

| 指令 | 意思 |
| --- | --- |
| `pvesh get /cluster/nextid` | 整個 cluster 內下一個可用 ID。`pct list` 只列本節點，會漏看別的節點的 CT |
| `pvesh get /cluster/resources --type vm ...` | 列出全 cluster 的 VM／CT，確認 ID 沒被占用 |
| `pveam update` / `available` | 更新並查詢可下載的 LXC 範本 |
| `pveam download local ...` | 把範本下載到 `local`（節點本機），建 CT 時只讀一次 |

**本案實測**（2026-11-04）：

- PVE 9.2.24、kernel 7.0.14-26-pve；儲存池有 `VM_Pool`（RBD，可用約 1.4 TB）、`cephfs`、`local`、`local-lvm`、`PBS31`
- 橋接為 `vmbr0`
- cluster 內 ID 100～114 已使用，`nextid` 回 **115**，RustDesk 使用 CT 115
- `local` 原本沒有範本，下載 `ubuntu-22.04-standard_22.04-1_amd64.tar.zst`（124M），`checksum verified`
- rootfs 放 `VM_Pool`（共享儲存），之後才能加入 HA

### 4-1 規劃 IP 與 Port

**做什麼**：替這台 Server 準備一個固定 IP，並列出要開放的 Port。

| Port | 協定 | 用途 | 是否必開 |
| --- | --- | --- | --- |
| 21115 | TCP | NAT 類型測試 | 必開 |
| 21116 | TCP **和** UDP | ID 註冊／心跳（UDP）、打洞與連線（TCP） | 必開 |
| 21117 | TCP | Relay 中繼 | 必開 |
| 21118 | TCP | Web Client（選用） | 不用就關 |
| 21119 | TCP | Web Client（選用） | 不用就關 |
| 21114 | TCP | Web 管理介面 | 僅 Pro 使用，OSS 不需要 |

> 21116 一定要 TCP 與 UDP 都通，是最常漏掉的地方。

### 4-2 在 PVE 建立 LXC

**做什麼**：建一台 unprivileged LXC，並開啟 `nesting`（Docker 跑在 LXC 內需要）。

**怎麼做**（在 PVE 節點 shell；CT ID、儲存池、IP 請依環境替換）：

```bash
pct create 115 local:vztmpl/ubuntu-22.04-standard_22.04-1_amd64.tar.zst \
  --hostname rustdesk \
  --cores 2 --memory 1024 --swap 512 \
  --rootfs <儲存池>:16 \
  --net0 name=eth0,bridge=vmbr0,ip=192.0.2.115/24,gw=192.0.2.1 \
  --unprivileged 1 \
  --features nesting=1,keyctl=1 \
  --onboot 1
pct start 115
```

| 片段 | 意思 |
| --- | --- |
| `--cores 2 --memory 1024` | 本案預估值（**推測**）：hbbs／hbbr 很輕量，連線數多了再加 |
| `--rootfs <儲存池>:16` | 16 GB 系統碟，放 Docker 映像檔與 `data` 綽綽有餘 |
| `--unprivileged 1` | 非特權容器，安全性較好 |
| `--features nesting=1,keyctl=1` | 讓容器內能跑 Docker；`keyctl` 在 unprivileged 容器跑 Docker 時常需要 |
| `--onboot 1` | PVE 開機時自動啟動 |

**應該看到**：`pct status 115` 顯示 `status: running`；`pct enter 115` 進得去。

**本案實測**（2026-11-04）：

- `pct config 115` 顯示 `rootfs: VM_Pool:vm-115-disk-0,size=16G`、`unprivileged: 1`、`onboot: 1`、`memory: 1024`、`swap: 512`
- 網路與 DNS 以兩台內網 DNS 設定（`--nameserver "<DNS1> <DNS2>"`，多個 DNS 以空格分隔並加引號）
- 容器內 `ping` Gateway、`ping 8.8.8.8` 皆 0% loss；`getent hosts deb.debian.org` 只回 IPv6 位址（推測：內網 DNS 未回 IPv4，是否影響 apt 以 4-3 的 `apt update` 為準）
- `pct config 115` 確認 `features: nesting=1,keyctl=1`、`cores: 2`、`arch: amd64`

### 4-3 容器內安裝 Docker

**做什麼**：安裝 Docker Engine 與 Compose plugin。

**怎麼做**（`pct enter 115` 之後）：

```bash
apt update && apt install -y ca-certificates curl
curl -fsSL https://get.docker.com | sh
docker --version
docker compose version
```

> `get.docker.com` 是 Docker 官方的便利安裝腳本，適合測試與內網；正式環境想完全掌控版本，請改用 [官方 apt repository 安裝](https://docs.docker.com/engine/install/ubuntu/)。

**應該看到**：兩個 `version` 指令都有輸出；`docker run --rm hello-world` 能成功（若失敗，見「常見問題」）。

### 4-4 部署 hbbs／hbbr

**做什麼**：建立 `compose.yml`，用 host 網路跑 hbbs 與 hbbr。

**怎麼做**：

```bash
mkdir -p /opt/rustdesk && cd /opt/rustdesk
cat > compose.yml <<'EOF'
services:
  hbbs:
    container_name: hbbs
    image: rustdesk/rustdesk-server:latest
    command: hbbs
    volumes:
      - ./data:/root
    network_mode: "host"
    depends_on:
      - hbbr
    restart: unless-stopped

  hbbr:
    container_name: hbbr
    image: rustdesk/rustdesk-server:latest
    command: hbbr
    volumes:
      - ./data:/root
    network_mode: "host"
    restart: unless-stopped
EOF
docker compose up -d
docker compose ps
```

| 片段 | 意思 |
| --- | --- |
| `./data:/root` | 把主機的 `data` 目錄掛進容器，Key 與資料庫都存在這裡，重建容器不會遺失 |
| `network_mode: "host"` | 官方建議 Linux 使用；容器直接用主機網路，免去逐一對應 Port（僅 Linux 有效） |
| `restart: unless-stopped` | 容器異常或主機重開後自動拉起 |
| `latest` | 方便但版本會變動；正式環境建議改成固定版本號（**推測**：到 Docker Hub 查最新 tag） |

> 若想強制所有連線都走中繼（不嘗試直連），官方做法是在 `hbbs` 加上 `environment: - ALWAYS_USE_RELAY=Y`。一般不需要。

**應該看到**：`docker compose ps` 兩個容器都是 `running`；用下列指令確認 Port 有在監聽：

```bash
ss -tulnp | grep -E '2111[5-9]'
```

預期至少看到 21115/tcp、21116/tcp、21116/udp、21117/tcp。

**本案實測**（2026-11-04）：

- 啟動 30 秒後 `docker compose ps` 兩容器皆為 `Up`，未重啟
- `ss -tulnp` 看到 21115/tcp、21116/tcp、21116/udp、21117/tcp，以及 **21118/tcp（hbbs）、21119/tcp（hbbr）也預設在監聽**，即使沒有使用 Web Client。因為用 host 網路，它們綁在所有網卡上，需要用防火牆限制來源（見 4-6）
- `data` 目錄產生 `id_ed25519`（私鑰）、`id_ed25519.pub`（公鑰，44 bytes）、`db_v2.sqlite3`（含 -shm、-wal）
- 私鑰預設權限為 `-rw-r--r--`，已改成 600：`chmod 600 /opt/rustdesk/data/id_ed25519`，改完 `ls -l` 顯示 `-rw-------`，不需重啟容器
- 映像檔使用 `latest`（image ID `8ecdab65deb7`）；`docker exec hbbs hbbs --version` 回 `hbbs 1.1.16`。是否固定成版本 tag 仍待確認（需先到 Docker Hub 確認 tag 名稱）

### 4-5 取得 Key 並設定 Client

**做什麼**：讀出公鑰，填進每台 Client。

**怎麼做**：

```bash
ls /opt/rustdesk/data
cat /opt/rustdesk/data/id_ed25519.pub
```

> 官方文件說公鑰「通常在 hbbs 第一次執行時產生」並存成 `id_ed25519.pub`；本案實測位於 `/opt/rustdesk/data/`。**不要貼出私鑰（`id_ed25519`）**，文章與工單裡也不要貼真實 Key。

在 Client：選單（⋮）→ **網路（Network）** → 解鎖 → 填入：

| 欄位 | 填什麼 |
| --- | --- |
| ID Server | hbbs 的 IP 或網域，例如 `192.0.2.115` 或 `<網域>`（預設 21116，可省略） |
| Relay Server | 選填；指 hbbr（21117），留空時 RustDesk 會自行推斷 |
| API Server | OSS 版**不需要**（Pro 才用） |
| Key | 上面讀到的 `id_ed25519.pub` 內容 |

多台 Client 的省力做法：先設好一台 → **Export Server Config** → 在其他 Client 用 **Import Server Config** → Apply。命令列也可用 `rustdesk.exe --config <config-string>` 套用。

**應該看到**：Client 主畫面底部顯示「就緒（Ready）」；兩台 Client 互相輸入對方 ID 可連線。

> **「就緒」不代表 Key 正確。** 「就緒」只表示 Client 成功向 hbbs 註冊，註冊時不驗證 Key；發起連線時才會比對，Key 不對會出現「金鑰不符」。所以設定完一定要做下面的雜湊比對與實際連線測試。

**驗證 Key 是否一致（不用貼出 Key）**：三個地方各算一次 SHA256 前 12 碼，必須完全相同。雜湊無法還原出 Key，只取前 12 碼，可以放心貼在工單裡。

Server（CT 內）：

```bash
tr -d '\n' < /opt/rustdesk/data/id_ed25519.pub | sha256sum | cut -c1-12
```

Linux Client：

```bash
grep '^key' ~/.config/rustdesk/RustDesk2.toml | awk -F"'" '{printf "%s", $2}' | sha256sum | cut -c1-12
```

Windows Client（PowerShell）：

```powershell
$k = ((Select-String -Path "$env:APPDATA\RustDesk\config\RustDesk2.toml" -Pattern '^key').Line -replace "^key\s*=\s*'","") -replace "'$",""
[BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes($k))).Replace("-","").Substring(0,12).ToLower()
```

| 片段 | 意思 |
| --- | --- |
| `tr -d '\n'` | 去掉換行，只算 Key 本身 |
| `sha256sum \| cut -c1-12` | 取 SHA256 前 12 碼當指紋 |
| `awk -F"'" '{printf "%s", $2}'` | 設定檔的 `key = '…'` 取單引號中間的內容 |
| PowerShell 兩個 `-replace` | 去掉 `key = '` 與結尾的 `'` |

**Client 設定檔位置**（本案實測）：

| 系統 | 路徑 | 備註 |
| --- | --- | --- |
| Linux | `~/.config/rustdesk/RustDesk2.toml` | 使用者設定；服務（root）設定位置未確認 |
| Windows（使用者） | `%APPDATA%\RustDesk\config\RustDesk2.toml` | 已確認 |
| Windows（服務） | `C:\Windows\ServiceProfiles\LocalService\AppData\Roaming\RustDesk\config\RustDesk2.toml` | 已確認；兩份的 `rendezvous_server` 與 `key` 要一致 |

**本案實測**（2026-11-04）：

- 測試 Client 設定 ID Server（填 Server 的內網 IP）與 Key，中繼伺服器與 API 伺服器留空，主畫面底部顯示「就緒」
- 兩台 VM（UBClient、WinClient）都顯示「就緒」，hbbs 的 `peer` 表有兩筆 ID，但 UBClient → WinClient 連線出現「金鑰不符」
- 雜湊比對：Server `42ce40056630`；兩台 Client 皆為 `5c7441f484c1`。兩台 Client 的 Key 一致，但都不是 Server 目前的公鑰（Key 來源未查明）
- 兩台重新貼上 Server 的 `id_ed25519.pub` 並套用後，雜湊皆與 Server 一致，UBClient → WinClient 連線成功
- ⏳ 連線型態（直連或中繼）與反方向連線尚未記錄

### 4-6 防火牆與對外連線

**做什麼**：只放行必要的 Port，並限制來源。

| 場景 | 做法 |
| --- | --- |
| 只在內網用 | 內網防火牆放行 21115～21117（21116 含 UDP）即可 |
| 要讓外網連 | 邊界防火牆／路由器把 21115～21117 轉發到 `192.0.2.115`（21116 要 TCP＋UDP）；有條件的話限制來源 IP |
| 走 VPN | 讓外部 Client 先連 VPN，再用內網 IP 連 RustDesk，可不開公網 Port（建議做法，**屬建議、未實測**） |

> 若 PVE 資料中心防火牆已啟用，要為這台 CT 補上對應規則，否則 Client 連不到。

**驗證**（在另一台機器上）：

```bash
nc -zv 192.0.2.115 21115
nc -zv 192.0.2.115 21116
nc -zv 192.0.2.115 21117
```

TCP 會顯示 succeeded；UDP 21116 用 `nc -zvu` 只能做參考，最準的是 Client 實際顯示「就緒」。

**用 ufw 限制 Port（本案做法：內網加 VPN，不限來源，不做公網轉發）**：

```bash
apt install -y ufw
ufw default deny incoming
ufw default allow outgoing
ufw allow 21115/tcp
ufw allow 21116/tcp
ufw allow 21116/udp
ufw allow 21117/tcp
ufw show added
ufw enable
ufw status verbose
```

| 片段 | 意思 |
| --- | --- |
| `default deny incoming` | 沒明說放行的進站連線全擋，21118、21119 也因此被擋 |
| `allow 21116/tcp` 與 `21116/udp` | 兩個都要：UDP 負責 ID 註冊，TCP 負責連線 |
| `ufw show added` | 啟用前先列出已加的規則，確認無誤再 `enable` |

> 本案 CT 沒有放行 22（SSH）：管理一律從 PVE 節點用 `pct enter` 進入，不受 ufw 影響。hbbs／hbbr 用 `network_mode: host`，Port 直接綁在 CT 網路，所以 ufw 能管到；一般橋接模式的 `-p` 發佈 Port 可能繞過 ufw，兩者不同。

**本案實測**（2026-11-04）：

- unprivileged LXC 內 `ufw enable` 成功，`ufw status verbose` 顯示 `active`、開機自動啟用、`Default: deny (incoming), allow (outgoing)`，四條放行規則（IPv4／IPv6 各一組）
- 從 UBClient 用 `nc -zv -w2` 測試：21115、21116、21117 `succeeded`；21118、21119 `timed out`（被擋）
- `pct reboot 115` 後，`ufw status` 仍為 `active` 且四條規則保留；hbbs、hbbr 自動回到 `Up`（驗證 CT `onboot` 與 `restart: unless-stopped`）
- ufw 啟用後，兩台 Client（UBClient、WinClient）互連正常，代表 UDP 21116 未被擋
- ⏳ 連線型態（直連或中繼）未記錄；VPN 使用者從 VPN 連入的情境尚未實測

### 4-7 備份與 HA

**做什麼**：確認 `data`（Key）有被備份且還原後 Key 不變，再加入 HA，節點故障時自動接手。

#### 4-7A 確認排程並手動備份

```bash
pvesh get /cluster/backup --output-format yaml
vzdump 115 --storage <PBS 儲存名稱> --mode snapshot --protected 1 --notes-template '{{guestname}} RustDesk 部署完成'
```

| 片段 | 意思 |
| --- | --- |
| `pvesh get /cluster/backup` | 看既有排程備份工作是否涵蓋這台 CT |
| `--mode snapshot` | 不停機，先對 RBD 做快照再備份 |
| `--protected 1` | 這份備份不會被保留策略自動刪除；不再需要時到 PBS 取消保護 |

`vzdump` 要在 CT 目前所在的節點執行。`--notes-template` 含中文時會出現 `Wide character in print` 警告，不影響備份。

**本案實測**（2026-11-04）：

- 既有三個 `all: 1` 排程（各節點 21:00、21:30、22:00，保留每日 7 份加最近 3 份），CT 115 自動納入，不需另外設定
- 手動 `vzdump`：1.41 GiB，約 17 秒，`Backup job finished successfully`，已標記 protected
- ⏳ 這份 protected 備份留到 HA 與整體驗收完成後，再決定是否取消保護

#### 4-7B 還原測試（用雜湊確認 Key 不變）

```bash
pvesm list <PBS 儲存名稱> --vmid 115
pvesh get /cluster/nextid
pct restore <新ID> <備份 Volid> --storage VM_Pool
pct set <新ID> --net0 name=eth0,bridge=vmbr0,ip=192.0.2.115/24,gw=192.0.2.1,link_down=1
pct start <新ID>
pct exec <新ID> -- sh -c "tr -d '\n' < /opt/rustdesk/data/id_ed25519.pub | sha256sum | cut -c1-12"
```

| 片段 | 意思 |
| --- | --- |
| `pct restore <新ID> <Volid>` | 把備份還原成另一個 CT，不動原機 |
| `link_down=1` | 還原出來的 CT 帶著原本的 IP，先讓網卡斷線，避免和原機搶 IP |
| `pct exec ... sha256sum` | 不需要網路，直接算公鑰指紋，與原機比對 |

**本案實測**（2026-11-04）：還原成 CT 116，`net0` 確認含 `link_down=1`；還原後公鑰雜湊與原機相同，表示備份中的 Key 完整，還原後 Client 不用重設。

#### 4-7C 加入 HA

```bash
ha-manager add ct:115 --state started --max_restart 1 --max_relocate 1
ha-manager status | grep ct:115
```

| 項目 | 做法 |
| --- | --- |
| HA 條件 | rootfs 在共享儲存（本案為 Ceph RBD），其他節點才能接手 |
| 規則 | 不需要互斥規則，RustDesk 只有這一台 |
| 升級 | `cd /opt/rustdesk && docker compose pull && docker compose up -d`，升級前先備份 `data` |

**本案實測**（2026-11-04）：

- `ha-manager add ct:115 --state started --max_restart 1 --max_relocate 1` 後，`ha-manager status` 先顯示 `service ct:115 (node11, queued)`（CRM 尚未處理，過渡狀態），稍後變為 `started`；三台 LRM 維持 `active`；加入過程未重開 CT
- 手動遷移（`ha-manager migrate ct:115 node10`）完成後，hbbs／hbbr 容器、ufw 與公鑰雜湊驗證皆通過，Client 連線正常（遷移會讓 CT 短暫重啟，RustDesk 約有幾十秒不可用）

## 5. 常見問題

| 現象 | 怎麼辦 |
| --- | --- |
| `docker run` 在 LXC 內失敗，出現權限或 `sysctl`／`AppArmor` 相關錯誤 | 確認 CT 的 `features` 有 `nesting=1,keyctl=1`，改完要重開 CT；仍失敗時查 PVE 版本與 Docker 的相容說明（**未確認**具體原因，請貼實際錯誤訊息再判斷） |
| Client 一直顯示「正在連接」或「就緒」不亮 | 先查 21116 的 **UDP** 是否放行；再確認 ID Server 填對、Key 與 `id_ed25519.pub` 完全一致 |
| 可以註冊但連線很慢、一直走中繼 | 直連打洞失敗是正常現象（對稱型 NAT 等），會自動走 hbbr；確認 21117/tcp 通 |
| Client 都顯示「就緒」，連線卻出現「金鑰不符」 | 「就緒」不驗證 Key。用 SHA256 前 12 碼比對 Server 的 `id_ed25519.pub` 與各 Client 設定檔裡的 `key`（見 4-5）；不一致就把 Server 的公鑰重新貼到 Client 的「網路」頁並套用，Windows 要連服務那份設定也一併確認 |
| 在同一個內網、用網域連不上 | 可能是路由器不支援 NAT loopback；內網改填內網 IP，或設定內網 DNS 指向內網位址。官方有專文介紹 NAT loopback 問題 |
| 重建容器後所有 Client 都要重設 Key | `data` 目錄沒掛載或被刪，Server 重新產生了新 Key；從備份還原 `data` 即可 |
| 21118／21119 被掃描或濫用的疑慮 | 不用 Web Client 就不要開；要用就放在反向代理後面並以防火牆限制 |
| 想要網頁管理介面 | OSS 沒有；需評估 RustDesk Server Pro |
| 還原備份時，原本的 VMID 已經被別的 Guest 使用 | 不要還原成原 ID；用 `pvesh get /cluster/nextid` 找新 ID。`pvesm list <PBS 儲存名稱> --vmid <原 ID>` 會同時列出同一個 VMID 的 `ct/` 與 `vm/` 備份（本案 115 有 RustDesk 的 `pbs-ct` 和 nextcloud 的 `pbs-vm`），要選 `pbs-ct` 那一筆（第 7 節） |
| `pvesh get /cluster/nextid` 回 117，但 116 其實是空的 | 還原成 116 成功（PVE 不會在沒有 `--force` 時覆蓋既有的 CT）；nextid 為什麼跳過 116，**未確認**（第 7 節） |
| `docker compose pull` 之後兩個容器顯示 `Running`、沒有 `Recreated` | 拉到的映像和原本相同，沒有新版本，容器不會被重建；用 `docker exec hbbs hbbs --version` 與 `docker images --digests` 確認（第 7 節） |
| LibreNMS `device:add --ping-only` 回 `Could not connect to … using ICMP`、`xmt/rcv/%loss = 0/0/0%` | 一個封包都沒送出，是名稱解析不到：11/23 用名稱加入失敗，改用 IP 加入成功；原因是內網 DNS 還沒有這筆記錄，補上之後兩台 DNS 都解析得到（第 7 節） |
| LibreNMS 加了 CT 之後，OS 顯示 `proxmox`、有一堆溫度 sensors | LXC 與 PVE host 共用 kernel，SNMP 看到的是 host 的資訊。只要監控這台 CT 本身，就關掉 sensors 模組（第 7-3 節） |
| 腳本最後一行 `select … snmpver …` 回 `ERROR 1054 Unknown column` | LibreNMS 26.10 的 `devices` 資料表已沒有 SNMP 設定欄位，裝置其實已加入；查詢只選 `device_id, hostname` 即可（見 [Wazuh 維運](https://kbwangtw.github.io/IT-Knowledge-Base/docs/pve/wazuh-lxc-ubuntu2204-operations/) 的 26.10 說明） |
| 想看 RustDesk 的 `docker-compose.yml`，結果 `No such file or directory` | 實際檔名是 `/opt/rustdesk/compose.yml`；不確定檔名時用 `cd /opt/rustdesk && docker compose config` 印出實際生效的設定 |
| CT 換了 IP，Server 要不要改 | 本案 `compose.yml` 沒有 `-r`、也沒寫死 IP，兩個容器用 `network_mode: host`，**不用改也不用重啟**；Client 只要把 ID Server 改成新位址，Relay Server 欄位可留空（第 7-4 節） |

## 6. 結案紀錄與未驗證項目

**結案**（2026-11-06）：本篇是在 PVE 練習架設 RustDesk Server OSS。RustDesk 的典型用途是提供**外部使用者**遠端連線，但本環境沒有這類需求，所以不再投入外部連入的實測，直接結案。

| 項目 | 狀態 |
| --- | --- |
| 部署（hbbs／hbbr、Docker Compose） | ✅ 已實測 |
| Key 驗證（SHA256 前 12 碼） | ✅ 已實測 |
| 內網兩台 Client 互連 | ✅ 已實測 |
| ufw 只放行必要 Port | ✅ 已實測 |
| PBS 備份、還原後 Key 一致 | ✅ 已實測 |
| HA 與手動遷移 | ✅ 已實測 |
| VPN 使用者從外部連入 | 未實測（只確認 VPN 的 `AllowedIPs` 涵蓋 Server 所在網段，沒有實際從外部連線） |
| 映像檔固定版本 tag | 未處理：`compose.yml` 仍用 `latest`（實測為 hbbs 1.1.16） |
| Client 連線型態（直連或中繼） | 未記錄 |
| ufw 放行來源限制 | 未處理：目前不限來源，僅內網與 VPN 可達 |
| 手動備份的 protected 保護 | 未取消：這份備份不會被保留策略自動刪除，不需要時到 PBS 取消保護 |

**下線**（2026-11-06）：依下方「若要下線這台 Server」的順序處理，已從 HA 移除（`ha-manager remove ct:115`，狀態先顯示 `deleting`，等它消失才停機）、停機後以 `pct destroy 115 --purge` 刪除 CT（含 16G rootfs），其他 CT 不受影響。PBS 上的備份不會隨 `pct destroy` 一起刪除，手動備份仍為 protected，每日排程備份依保留策略逐漸清掉。（2026-11-23 這份 protected 備份被拿來還原成 CT 116，見第 7 節。）

**日後若要真的對外提供使用**，至少補做：

1. 從 VPN 或外網實際連線測試，並確認連線型態。
2. 把 `latest` 固定成版本 tag（tag 名稱先到 Docker Hub 確認）。
3. 評估 ufw 限制來源。
4. 評估是否需要 Pro 版的管理介面（OSS 沒有裝置清單與權限控管）。

**若要下線這台 Server**：先確認沒有 Client 還在使用，再從 HA 移除（`ha-manager remove ct:115`），然後停機或刪除 CT；刪除前先確認備份是否還要保留。

## 7. 2026-11-23：從備份還原成 CT 116，重新啟用

**為什麼**：使用者要整台使用 RustDesk Server（不是只拿備份裡的某個檔案）。CT 115 已在 11/06 刪除，但 11/04 部署完成時手動做的備份是 **protected**，還在 PBS 上：`PBS31:backup/ct/115/2026-11-04T06:00:14Z`（備註「rustdesk RustDesk 部署完成」，約 1.44 GiB），所以從它還原。

### 7-1 還原前要注意：VMID 115 已經是 nextcloud

| 事實 | 影響 |
| --- | --- |
| VMID 115 現在是 nextcloud 的 VM（running、在 HA、`onboot=1`） | **不能還原成 115**；PVE 網頁的還原視窗預設會帶原本的 ID，一定要改 |
| `pvesm list PBS31 --vmid 115` 同時列出 `ct/115`（RustDesk，`pbs-ct`，1,542,708,536 bytes）和 `vm/115`（nextcloud，`pbs-vm`，約 132 GiB，11/15～11/22 每晚都有） | 要選 `pbs-ct` 那一筆 |
| 備份的設定檔帶著原本的 IP | 還原後先讓網卡斷線，確認 IP 沒人用再接上 |

### 7-2 步驟與結果

| 步驟 | 指令 | 結果 |
| --- | --- | --- |
| 1. 查新 ID 與備份清單 | `pvesh get /cluster/nextid`、`pvesm list PBS31 --vmid 115` | nextid 回 117；清單有 1 筆 `ct/115`（`2026-11-04T06:00:14Z`）與 9 筆 `vm/115` |
| 2. 還原成新 CT（在 node11 執行） | `pct restore 116 PBS31:backup/ct/115/2026-11-04T06:00:14Z --storage VM_Pool --unique 1` | `restore complete (1.436 GiB processed in 11.9s)`；用 116 而不是 nextid 的 117（見下） |
| 3. 網卡斷線、不隨開機啟動 | `pct set 116 --net0 "$(pct config 116 \| sed -n 's/^net0: //p'),link_down=1" --onboot 0` | `net0` 結尾 `link_down=1`、`onboot: 0` |
| 4. 看設定 | `pct config 116 \| grep -E '^(net0\|hostname\|onboot\|memory\|cores\|rootfs)'` | `hostname: rustdesk`、`cores: 2`、`memory: 1024`、`rootfs: VM_Pool:vm-116-disk-0,size=16G`、新的 `hwaddr`（`--unique 1`）、原 IP |
| 5. 確認原 IP 沒人用 | `ping -c 2 -W 1 <備份裡的 IP>` | 使用者確認 IP 沒人用（接網卡之前） |
| 6. 開機並驗證 | `pct exec 116 -- sh -c "tr -d '\n' < /opt/rustdesk/data/id_ed25519.pub \| sha256sum \| cut -c1-12"`、`docker ps`、`ss -tulnp \| grep -E '2111[5-9]'`、`ufw status` | 見下表 |

| 驗證項目 | 結果 |
| --- | --- |
| 公鑰雜湊（SHA256 前 12 碼） | **`42ce40056630`**，和 11/04 記錄的 Server 公鑰雜湊（4-5 節）**完全相同**，Key 與原機一致 |
| 容器 | `hbbs`、`hbbr` 都是 `Up`，映像 `rustdesk/rustdesk-server:latest`，`CREATED` 約 2 週前 |
| 埠 | 21115／tcp、21116／tcp＋udp、21117／tcp、21118／tcp、21119／tcp 都在監聽（21116／udp 顯示 `UNCONN` 是 UDP 的正常顯示） |
| ufw | `active`，只放行 21115／21116（tcp＋udp）／21117（含 v6）；21118、21119 沒放行 |
| IP 衝突檢查（接上網卡後） | `ping` 2 發 2 收；`ip neigh show` 的 `lladdr` 與 CT 的 `hwaddr` 相同，只有這台在用這個 IP。這個 ping 從 node11 發出、CT 就在 node11，只能證明沒有重複，不能證明別台連得到；Client 互連才是 |
| Client | 現有 Client 互連成功，不用重設 Key（哪幾台、直連或中繼，沒有記錄） |

實際順序和上面的建議略有不同：`pct start 116` 回 `CT 116 already running`，網卡的 `link_down` 在驗證前就已經拿掉。

**nextid 117 與 116**：`pvesh get /cluster/nextid` 回 117，使用者仍用 116 還原且成功。PVE 不會在沒有 `--force` 時覆蓋既有的 CT，所以 116 是空的。nextid 為什麼跳過 116，**未確認**（11/04 的還原測試也用過 116，可能有關，沒有查證）。

### 7-3 後續處理與結果

| 項目 | 狀態 | 說明 |
| --- | --- | --- |
| 更新映像 | ✅ 無新版 | `pct exec 116 -- sh -c "cd /opt/rustdesk && docker compose pull && docker compose up -d"`：兩個容器顯示 `Running`（沒有 `Recreated`），映像沒有新版；hbbs 仍是 1.1.16，IMAGE ID 開頭 `8ecdab65deb7`。升級前先備份 |
| 加入 HA | ✅ | `ha-manager add ct:116 --state started --max_restart 1 --max_relocate 1`；ct:116 在 node11、`started`，HA 資源變成 5／5／5（共 15 個） |
| 路由器 DHCP | ✅ | 已保留這個 IP |
| DNS 名稱 | ✅ | 兩台內網 DNS 都補了 `rustdesk` 記錄，各用 `nslookup` 查一次都回同一個 IP（其中一台標 `Non-authoritative answer`，兩台角色不同，答案一致即可） |
| LibreNMS | ✅ | 先用 `--ping-only` 加入，再改成 SNMPv3（見下），device 29 |
| 密碼暫存檔 | ✅ | 腳本產生的暫存檔已清除：node11 的 `/root/.snmp-add-116` 與 CT 116 的 `/root/.snmp-cu` 都是 `No such file or directory` |
| CRS 設定 | ✅ | `grep crs /etc/pve/datacenter.cfg` 為 `crs: ha=static,ha-rebalance-on-start=1`，沒有開自動平衡 |
| 更新 CT 內的套件 | 未回報 | `pct exec 116 -- sh -c "apt-get update && apt-get -y full-upgrade"` |
| 備份一次作為還原點 | 未回報 | `vzdump 116 --storage PBS31 --mode snapshot --notes-template '{{guestname}} restored'`；node11 的 21:30 排程 `--all 1` 也會納入。CT 116 第一次排程備份與 22:45 verify 的結果**尚未回報** |
| 固定映像版本 tag | 未處理 | 同第 6 節 |

**加入 LibreNMS**（LibreNMS 是 CT 102，當時在 node12，指令在 node12 執行；做法同 [Grafana 戰情室（LibreNMS）9-3](https://kbwangtw.github.io/IT-Knowledge-Base/docs/pve/grafana-war-room-librenms/)）：

```bash
IP=$(ssh root@node11 "pct config 116" | sed -n 's/^net0:.*ip=\([0-9.]*\)\/.*/\1/p')
pct exec 102 -- su - librenms -s /bin/bash -c "cd /opt/librenms && ./lnms device:add --ping-only $IP"
pct exec 102 -- su - librenms -s /bin/bash -c "cd /opt/librenms && ./lnms device:poll $IP" | tail -3
```

用名稱（`rustdesk.<網域>`）加入失敗，改用 IP 才成功，原因是當時內網 DNS 沒有這筆記錄。不要加 `--force`，它會跳過檢查，LibreNMS 會一直顯示 Down。`--ping-only` 加成功後是 device 28。

**改成 SNMPv3**（不想只看 Ping 時）：這個環境另有一支跨節點的 SNMPv3 腳本（原理同 [Wazuh 維運](https://kbwangtw.github.io/IT-Knowledge-Base/docs/pve/wazuh-lxc-ubuntu2204-operations/) 的 SNMPv3 小節），流程如下，密碼由腳本隨機產生，不要貼到聊天或文件：

| 步驟 | 做什麼 |
| --- | --- |
| 1 | 在 CT 內安裝並設定 `snmpd`，用暫存檔建立 SNMPv3 使用者（`createUser`，之後會轉成 `usmUser`）；認證 SHA、加密 AES |
| 2 | ufw 只放行 LibreNMS 來源：`ufw allow from <LibreNMS IP> to any port 161 proto udp` |
| 3 | 刪除舊的 ping-only 裝置，再用 `lnms device:add -3 -u <使用者> -a SHA -A <密碼> -x AES -X <密碼> <IP>` 重新加入（device 28 → 29） |
| 4 | 清除兩邊的暫存檔（見上表的驗證） |

腳本最後一行原本想用 `select … snmpver …` 確認，在 LibreNMS 26.10 回 `ERROR 1054`（欄位已移除），裝置其實已加入，只查 `device_id, hostname` 即可。

**關閉 sensors 模組**：LXC 與 PVE host 共用 kernel，SNMP 看到的是 host 的溫度 sensors（10 個），OS 也顯示 `proxmox`，對這台 CT 沒有意義。關法是用資料庫把這台的 sensors 輪詢與探索都設為 0，並刪掉已建立的 temperature sensors：

```sql
DELETE FROM devices_attribs WHERE device_id=29 AND attrib_type IN ('poll_sensors','discover_sensors');
INSERT INTO devices_attribs (device_id, attrib_type, attrib_value) VALUES (29,'poll_sensors','0'),(29,'discover_sensors','0');
DELETE FROM sensors WHERE device_id=29 AND sensor_class='temperature';
```

執行後該裝置的 temperature sensors 剩 0 筆（實測）。`device_id` 要換成自己的值。

### 7-4 之後又調整了 IP

11/23 當天，使用者又把 CT 116 的 IP 從 192.0.2.52 改成 192.0.2.35（文件示範位址，非實際值）。Server 的 Key 與 IP 無關，仍是 `42ce40056630`。

| # | 項目 | 做法與結果 |
| --- | --- | --- |
| 1 | CT 116 | `pct config 116 \| grep ^net0`、`pct exec 116 -- ip -4 addr show eth0`：`net0` 與 `eth0` 都是新 IP（`/24`），MAC 與先前一致 ✅ |
| 2 | RustDesk 設定 | `cat /opt/rustdesk/docker-compose.yml` 回 `No such file or directory`，因為檔名是 `compose.yml`；`cd /opt/rustdesk && docker compose config` 顯示 hbbs 與 hbbr 的 `command:` 只有 `hbbs`／`hbbr`，沒有 `-r <IP>`，且兩個容器都是 `network_mode: host` ✅ 不用改、不用重啟 |
| 3 | LibreNMS | `lnms device:rename <舊 IP> <新 IP>` 回 `Renamed … to …`，device 29 的 SNMPv3 設定與 sensors 關閉設定都保留 ✅（改名後 SNMP 是否有資料，**未回報**） |
| 4 | DHCP 保留 | 舊 IP 的保留是否已移除，**未回報**（若還在，建議刪除，避免日後被別的設備取得） |
| 5 | 兩台內網 DNS | 都改成新 IP ✅ |
| 6 | Client | 改 ID Server 後連線成功 ✅ |

**Client 怎麼改**：沒有設 `-r`，Relay Server 欄位留空時 Client 會用 ID Server 的位址去連 relay，所以只改 ID Server（填 IP 或 DNS 名稱），Key 不變。建議統一填 DNS 名稱，之後再換 IP 就不用逐台改 Client。

**踩雷**：在 node11 執行 `lnms device:rename` 回 `Configuration file 'nodes/node11/lxc/102.conf' does not exist`，因為 CT 102 不在 node11，指令沒有改到任何東西；`pct exec` 要在 CT 所在的節點執行。

**這次沒有確認的事**：IP 為什麼要改（使用者沒有說明）。

## 8. 延伸閱讀

- [RustDesk Server OSS（官方總覽）](https://rustdesk.com/docs/en/self-host/rustdesk-server-oss/)
- [RustDesk Server OSS：Docker 安裝](https://rustdesk.com/docs/en/self-host/rustdesk-server-oss/docker/)
- [RustDesk Client 設定](https://rustdesk.com/docs/en/self-host/client-configuration/)
- [Docker Engine 安裝（Ubuntu）](https://docs.docker.com/engine/install/ubuntu/)
- 同類型的 LXC 建置範例：[在 PVE Cluster 用 LXC 架設 Wazuh（一）](https://kbwangtw.github.io/IT-Knowledge-Base/docs/pve/wazuh-lxc-ubuntu2204-sop/)

{% endraw %}
