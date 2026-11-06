---
layout: default
title: "在 PVE 用 VM + Docker Compose 架設 Nextcloud Server（一）：建立、部署、備份與還原演練"
date: 2026-11-06
categories: [PVE, Nextcloud, Docker, Cloud-Init]
permalink: /docs/pve/nextcloud-vm-docker-compose-sop/
last_modified_at: 2026-11-06
---
{% raw %}

# 在 PVE 用 VM + Docker Compose 架設 Nextcloud Server（一）：建立、部署、備份與還原演練

> **一句話**：Nextcloud 是可以自己架的私有雲端硬碟。這篇在 PVE 叢集建一台 Ubuntu VM（用官方 cloud image，免跑安裝程式），資料放在獨立的 100G 資料碟，再用 Docker Compose 跑 Nextcloud + MariaDB + Redis，最後用 PBS 備份並實際還原一次驗證。

| 項目 | 內容 |
| --- | --- |
| 適合誰看 | 想在 PVE 自架 Nextcloud 的人；第一次用 cloud image、Cloud-Init、Docker Compose 部署服務的人 |
| 環境 | PVE 9.2.25（3 節點叢集、Ceph RBD `VM_Pool` 3 副本）；VM 115 跑在 node11；Ubuntu 24.04.5 LTS cloud image；2 vCPU／4 GB RAM／系統碟 32G＋資料碟 100G；Docker 29.9.3、Compose v5.7.0；Nextcloud 35.0.2.2（`nextcloud:35.0.2-apache`）、MariaDB 11.8.9、Redis 7.4 |
| 日期 | 2026-11-06 |
| 結論 | ✅ VM、資料碟、Docker、Nextcloud 部署完成，用 IP 與網域名稱都能登入；✅ cron 背景工作、快取與檔案鎖、資料庫調校、後台檢查（資料庫項目 0 個問題）完成；✅ PBS 備份完成，並**實際還原成另一台 VM 驗證**（開機、資料碟自動掛載、四個容器、使用者與檔案都正確）；⏳ 目前只有 HTTP（內網），HTTPS、2FA、防火牆留待對外開放前；⏳ 今晚 21:30 的排程備份尚未確認第一次執行結果 |
| 下篇 | [Nextcloud Server 監控與日誌（二）：Wazuh、LibreNMS 與 Graylog](https://kbwangtw.github.io/IT-Knowledge-Base/docs/pve/nextcloud-monitoring-wazuh-librenms-graylog/) |
| 官方文件 | [Nextcloud Administration Manual](https://docs.nextcloud.com/server/latest/admin_manual/)、[Nextcloud 官方 Docker image](https://github.com/nextcloud/docker) |

> 文中 IP 都是文件示範位址（192.0.2.0/24），`<網域>`、`<管理帳號>` 等 `<…>` 的內容**要整段換成自己的值**（連角括號一起換掉），指令執行前請替換。帳號與密碼不寫在文章裡。

**這篇怎麼讀**：第一次接觸先讀第 1～3 節；要動手就照第 4 節起的步驟，每一步都是「做什麼 → 怎麼做 → 應該看到什麼」；出問題先看第 5 節「常見問題」。

## 1. 先認識幾個名詞

| 名詞 | 白話解釋 |
| --- | --- |
| **Nextcloud** | 開源的私有雲端硬碟，能同步檔案、行事曆、聯絡人，資料都在自己的伺服器上 |
| **cloud image** | 發行版官方提供的「已經裝好的系統映像」，直接匯入當成硬碟開機，不必走安裝程式 |
| **Cloud-Init** | 開機時自動套用帳號、IP、DNS、SSH 金鑰的機制；PVE 會把設定做成一張虛擬光碟交給 VM |
| **Docker Compose** | 用一個 `compose.yaml` 描述多個容器（程式、資料庫、快取）並一次啟動 |
| **MariaDB** | 資料庫，Nextcloud 的使用者、檔案索引、設定都存在這裡 |
| **Redis** | 記憶體快取，也負責檔案鎖定（避免兩個人同時改同一個檔案出錯） |
| **APCu** | 單機本地快取，Nextcloud 官方單機部署的建議搭配 |
| **cron（背景工作）** | 定時執行的工作（清理、通知、索引…）。官方建議用 cron 模式，不要用預設的 AJAX 模式 |
| **occ** | Nextcloud 的命令列管理工具，要在容器內用 `www-data` 身分執行 |
| **trusted_domains** | Nextcloud 允許的網址清單，用沒列入的網址連線會被拒絕 |
| **維護模式** | 暫時讓 Nextcloud 顯示「維護中」，改設定、重啟資料庫時用，使用者看到的是維護頁而不是錯誤 |
| **副本數（replica）** | Ceph 把資料存幾份；本環境是 3，所以虛擬碟實際會吃到 3 倍的叢集容量（thin provisioning，只算實際寫入的） |
| **snapshot 與備份** | snapshot 和 VM 在同一個儲存體，儲存壞了一起沒；備份（PBS）放在別處，才是真正的保險 |

## 2. 全貌

```text
瀏覽器 ──HTTP 80──▶ VM 115（Ubuntu 24.04，固定 IP 192.0.2.34）
                     ├─ 系統碟 32G（/，Docker 與 Compose 檔案）
                     ├─ 資料碟 100G（/srv/nextcloud-data）
                     │     ├─ data/  ← Nextcloud 使用者檔案
                     │     └─ db/    ← MariaDB 資料
                     └─ Docker Compose（/opt/nextcloud）
                           ├─ app    Nextcloud + Apache（對外 80）
                           ├─ cron   同一個映像，每 5 分鐘跑背景工作
                           ├─ db     MariaDB（只在容器內部網路）
                           └─ redis  快取與檔案鎖（只在容器內部網路）

PVE 每晚備份 ──▶ PBS（VM 整台，含兩顆碟）
```

## 3. 開工前先決定的事（風險與盲點）

| 項目 | 說明 |
| --- | --- |
| 部署方式 | 官方手冊的自動化安裝方式是 **Nextcloud AIO**（官方、免費，AGPL v3）；Docker Hub 上的 `nextcloud` 映像是**社群維護，官方明說不提供支援**，手冊中也找不到 docker-compose 的範例。本篇選社群映像 + Compose：元件看得清楚、適合學習維運；代價是升級、cron 要自己處理 |
| 版本 | 官方手冊 `latest` 頁顯示 36（upcoming），`stable` 頁是 35。本篇用穩定版 35，映像標籤**鎖定完整版本**（`35.0.2-apache`），不用 `latest`。Nextcloud 不能跳大版本升級 |
| 系統需求 | 官方列出 Ubuntu 24.04 LTS、PHP 8.3～8.5（8.5 為 recommended）、MariaDB 11.8 為 recommended；SQLite 只適合測試 |
| 資料碟 | 官方建議資料目錄放在 webroot 外，而且**安裝時就決定**，事後很難搬。所以一開始就用獨立資料碟 |
| 容量 | 虛擬容量 32G + 100G = 132 GiB，3 副本時最多佔叢集約 396 GiB（寫滿的情況）；容量規劃要乘以副本數 |
| 先內網、後對外 | 目前只有 HTTP，密碼是明文傳輸。對外開放前一定要 HTTPS、HSTS、2FA、防火牆（見待辦） |
| 備份一致性 | PBS 對運作中的 VM 做快照備份（有 guest agent 會先凍結檔案系統），屬於「crash-consistent」；官方手冊的標準流程是開維護模式後備份，要不要再加每日 `mariadb-dump` 當第二層保險，列入待辦評估 |
| 兩台 DNS 不同步 | 環境的兩台 DNS 是各自獨立的，A record **要兩台都加** |

## 4. 步驟

### 4-1 下載並驗證 cloud image

**做什麼**：在 VM 所在的 PVE 節點下載 Ubuntu 24.04 的 cloud image，並驗證雜湊值。

**怎麼做**：

```bash
mkdir -p /root/cloudimg && cd /root/cloudimg
wget https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img
wget -O SHA256SUMS https://cloud-images.ubuntu.com/noble/current/SHA256SUMS
sha256sum -c SHA256SUMS --ignore-missing
```

**應該看到**：`noble-server-cloudimg-amd64.img: OK`。不是 OK 就不要往下。

`current` 是滾動更新的，雜湊值會隨時間改變，**以你下載的 `SHA256SUMS` 為準**。2026-11-06 查到的檔案約 621 MB（621,284,352 bytes），雜湊值開頭是 `04e8f246`。

### 4-2 建立 VM、匯入系統碟、加資料碟

**做什麼**：建立 VM 115，把映像匯入成系統碟並放大到 32G，再加一顆 100G 空白資料碟。

**怎麼做**（在 VM 所在的節點）：

```bash
qm status 115
qm create 115 --name nextcloud --memory 4096 --cores 2 \
  --net0 virtio,bridge=vmbr0 --ostype l26 --agent enabled=1 \
  --scsihw virtio-scsi-single --onboot 1
qm set 115 --scsi0 VM_Pool:0,import-from=/root/cloudimg/noble-server-cloudimg-amd64.img,discard=on,iothread=1
qm disk resize 115 scsi0 32G
qm set 115 --scsi1 VM_Pool:100,discard=on,iothread=1
qm set 115 --ide2 VM_Pool:cloudinit
qm set 115 --boot order=scsi0
```

| 片段 | 意思 |
| --- | --- |
| `qm status 115` | 先確認 VMID 沒被占用，應回報 `does not exist` |
| 沒有指定 `--cpu` | 用 PVE 的預設 CPU 類型。叢集內各節點 CPU 型號不一定相同，預設類型對 live migration 與 HA 較友善；實際類型可用 `qm config 115` 查看（本案**未確認**輸出） |
| `--agent enabled=1` | 啟用 guest agent，PVE 才能讀 IP、乾淨關機、備份時凍結檔案系統 |
| `VM_Pool:0,import-from=...` | 在 Ceph 建碟並直接匯入映像，不用另外查 `unused0` 的名稱 |
| `disk resize ... 32G` | 映像約 3.5G，放大到 32G；首次開機 Cloud-Init 會自動擴展檔案系統 |
| `--scsi1 VM_Pool:100` | 100G 空白資料碟，4-6 才處理 |
| `--ide2 VM_Pool:cloudinit` | 放 Cloud-Init 設定的虛擬光碟 |
| `--onboot 1` | 節點重開機後自動啟動 VM |

**應該看到**：`scsi0: successfully created disk ...`、`scsi1: successfully created disk ...`。

### 4-3 Cloud-Init：帳號、固定 IP、DNS、SSH 金鑰

**做什麼**：用 Cloud-Init 設定登入帳號、固定 IP、DNS，並放入 SSH 公鑰。

**怎麼做**：

```bash
qm set 115 --ciuser <管理帳號>
read -rsp "輸入密碼: " PW; echo
qm set 115 --cipassword "$PW"
unset PW
qm set 115 --sshkeys /root/nextcloud-admin.pub
qm set 115 --ipconfig0 ip=192.0.2.34/24,gw=192.0.2.1
qm set 115 --nameserver "192.0.2.20 192.0.2.21"
qm set 115 --searchdomain <網域>
qm set 115 --ciupgrade 0
qm config 115
```

| 片段 | 意思 |
| --- | --- |
| `read -rsp` | 互動輸入密碼，不會顯示在畫面，也不會留在 shell history |
| `--sshkeys` | 公鑰檔案（只放**公鑰**）。在 PVE 網頁 VM → Cloud-Init 分頁貼上公鑰也可以 |
| `--ipconfig0` | 固定 IP 與 gateway |
| `--nameserver`、`--searchdomain` | 兩台 DNS（空白分隔）與搜尋網域，**網域要和 DNS 實際網域完全一致** |
| `--ciupgrade 0` | 首次開機**不要**自動 `apt upgrade`，避免網路不通時卡住，更新改手動做 |

**應該看到**：`qm config 115` 有 `scsi0`（32G）、`scsi1`（100G）、`ide2: ...cloudinit`、`boot: order=scsi0`、`ipconfig0`、`nameserver`、`searchdomain`、`agent: enabled=1`、`onboot: 1`；密碼顯示為 `**********`。

### 4-4 開機並驗證

**做什麼**：啟動 VM，確認 Cloud-Init 設定都套用。

**怎麼做**：

```bash
qm start 115
```

約 1 分鐘後用 SSH 登入 `192.0.2.34`（金鑰登入），執行：

```bash
cloud-init status --wait
hostnamectl
ip -br a
lsblk
df -h /
ping -c 2 1.1.1.1
nslookup archive.ubuntu.com 192.0.2.20
sudo apt update
```

**應該看到**：

| 項目 | 結果 |
| --- | --- |
| `cloud-init status` | `status: done` |
| hostname | `nextcloud`（由 PVE 的 VM 名稱決定） |
| `ip -br a` | `eth0` 為 `192.0.2.34/24` |
| `lsblk` | `sda` 32G（`sda1` 31G，掛載 `/`）、`sdb` 100G 且沒有分割 |
| `df -h /` | `/` 約 30G，已用約 6% |
| `ping`、`nslookup`、`apt update` | 都成功，代表 IP、DNS、HTTP 對外都通 |

Cloud image 只接受 **SSH 金鑰登入**，密碼只能從 PVE 的 Console 登入，原因見第 5 節。

### 4-5 更新系統、時區、guest agent

**做什麼**：套用更新、時區改台北、安裝並啟動 guest agent。

**怎麼做**：

```bash
sudo apt update
sudo apt full-upgrade -y
sudo timedatectl set-timezone Asia/Taipei
sudo apt install -y qemu-guest-agent
sudo systemctl enable --now qemu-guest-agent
timedatectl
systemctl status qemu-guest-agent --no-pager
```

**應該看到**：`Time zone: Asia/Taipei`、`System clock synchronized: yes`、guest agent `active (running)`。本案更新了 kernel（6.8.0-147 → 6.8.0-149），重開機後生效。登入畫面的「新版本 26.04.1 LTS 可升級」**先不要升級**，大版本升級另外評估。

### 4-6 資料碟：分割、格式化、以 UUID 掛載

**做什麼**：把 100G 的 `sdb` 建一個分割、格式化成 ext4，用 UUID 寫進 `/etc/fstab` 開機自動掛載。

**怎麼做**（**每一步看結果再做下一步**）：

```bash
lsblk -f /dev/sdb
```

確認 `sdb` 沒有 FSTYPE、LABEL、掛載點，底下也沒有分割，再往下：

```bash
sudo parted -s /dev/sdb mklabel gpt mkpart ncdata ext4 1MiB 100%
sudo mkfs.ext4 -L ncdata /dev/sdb1
sudo blkid /dev/sdb1
UUID=$(sudo blkid -s UUID -o value /dev/sdb1)
echo "UUID=[$UUID]"
```

`UUID=[...]` 的中括號內**必須有值**才繼續：

```bash
sudo mkdir -p /srv/nextcloud-data
test -n "$UUID" && echo "UUID=$UUID /srv/nextcloud-data ext4 defaults,nofail 0 2" | sudo tee -a /etc/fstab
sudo findmnt --verify
sudo systemctl daemon-reload
sudo mount -a
sudo mkdir -p /srv/nextcloud-data/data /srv/nextcloud-data/db
lsblk -f
df -h /srv/nextcloud-data
```

| 片段 | 意思 |
| --- | --- |
| `mklabel gpt`、`mkpart ncdata ext4 1MiB 100%` | GPT 分割表，建立一個吃滿整顆碟的分割（1MiB 起算是為了對齊） |
| `mkfs.ext4 -L ncdata` | 格式化為 ext4，標籤 `ncdata`（會清除該分割，所以第一步要確認是空的） |
| `UUID=...` | 用 UUID 而不是 `/dev/sdb1`，避免裝置名稱改變 |
| `test -n "$UUID" &&` | 防呆：UUID 不是空的才寫入 `fstab` |
| `defaults,nofail` | `nofail` 讓資料碟掛載失敗時系統仍能開機，不會卡在 emergency mode |
| `findmnt --verify` | 檢查 `fstab` 語法與裝置是否存在；在 `daemon-reload` 之前執行時可能出現「systemd 仍用舊版」的警告，可忽略 |
| `data/`、`db/` 子目錄 | Nextcloud 檔案與 MariaDB 各用子目錄，不直接用掛載點根目錄（ext4 根目錄有 `lost+found`） |

**應該看到**：`sdb1` 為 `ext4`、LABEL `ncdata`，掛載在 `/srv/nextcloud-data`；`df` 約 98G，已用 28K，可用約 93G。

再**重開機驗證自動掛載**：

```bash
sudo reboot
```

登入後：

```bash
uptime -s
findmnt /srv/nextcloud-data
df -h /srv/nextcloud-data
```

**應該看到**：資料碟已自動掛載。本案 `mkfs` 約在 11:57，`uptime -s` 為 11:59:29，確認是重開機後自動掛載。

### 4-7 安裝 Docker Engine 與 Compose

**做什麼**：用 Docker 官方的 apt 套件庫安裝（不要用 Ubuntu 內建的 `docker.io`）。

**怎麼做**：

```bash
curl -4 -sI --max-time 15 https://download.docker.com/linux/ubuntu/gpg | head -n 3
sudo apt update
sudo apt install -y ca-certificates curl
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc

sudo tee /etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: $(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}")
Components: stable
Signed-By: /etc/apt/keyrings/docker.asc
EOF

sudo apt update
sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
sudo docker --version
sudo docker compose version
sudo docker run --rm hello-world
```

以上依[官方安裝文件](https://docs.docker.com/engine/install/ubuntu/)整理，若與官網不同以官網為準。

**應該看到**：`Docker version 29.9.3`、`Docker Compose version v5.7.0`、`hello-world` 印出 `Hello from Docker!`（同時驗證能從 Docker Hub 拉映像）。Docker 啟動時 log 的 `Deleting nftables ... error ... status 1` 是第一次啟動沒有舊規則可刪，可忽略。

> 先不要把使用者加入 `docker` 群組：加入群組等於給該帳號 root 等級權限。目前一律用 `sudo docker …`。

### 4-8 撰寫 Compose 檔與密碼檔

**做什麼**：建立 `/opt/nextcloud`，隨機產生密碼檔，寫 `compose.yaml`。

**怎麼做**（目錄與權限）：

```bash
sudo mkdir -p /opt/nextcloud
sudo chown <管理帳號>:<管理帳號> /opt/nextcloud
sudo chown 33:33 /srv/nextcloud-data/data
sudo chmod 750 /srv/nextcloud-data/data
ls -ln /srv/nextcloud-data
```

容器內的 `www-data` 使用者 UID／GID 是 33，檔案目錄要讓它能寫入；`db` 目錄保持 root 擁有，MariaDB 容器第一次啟動會自行處理。

**密碼檔 `.env`**（密碼由伺服器隨機產生，不顯示、不貼給別人）：

```bash
cd /opt/nextcloud
umask 077
cat > .env <<EOF
MYSQL_ROOT_PASSWORD=$(openssl rand -base64 32 | tr -d '/+=')
MYSQL_PASSWORD=$(openssl rand -base64 32 | tr -d '/+=')
REDIS_PASSWORD=$(openssl rand -base64 32 | tr -d '/+=')
NEXTCLOUD_ADMIN_USER=<管理者帳號>
NEXTCLOUD_ADMIN_PASSWORD=$(openssl rand -base64 24 | tr -d '/+=')
EOF
ls -l .env
```

**應該看到**：`-rw------- ... .env`。管理者初次登入密碼用 `grep ADMIN_PASSWORD /opt/nextcloud/.env` 查看。**把 `.env` 存到密碼管理工具，不要放進 Git**；這個檔案遺失，資料庫就進不去。

**`compose.yaml`**（用 `<<'EOF'` 寫入，讓 `${...}` 保持原樣交給 Compose）：

```bash
cat > compose.yaml <<'EOF'
services:
  db:
    image: mariadb:11.8.9
    restart: unless-stopped
    command:
      - --transaction-isolation=READ-COMMITTED
      - --innodb-log-file-size=256M
      - --slow-query-log=ON
      - --long-query-time=2
    environment:
      MARIADB_ROOT_PASSWORD: ${MYSQL_ROOT_PASSWORD}
      MARIADB_DATABASE: nextcloud
      MARIADB_USER: nextcloud
      MARIADB_PASSWORD: ${MYSQL_PASSWORD}
    volumes:
      - /srv/nextcloud-data/db:/var/lib/mysql
    healthcheck:
      test: ["CMD", "healthcheck.sh", "--connect", "--innodb_initialized"]
      interval: 10s
      timeout: 5s
      retries: 10

  redis:
    image: redis:7.4-alpine
    restart: unless-stopped
    command: ["redis-server", "--requirepass", "${REDIS_PASSWORD}"]

  app:
    image: nextcloud:35.0.2-apache
    restart: unless-stopped
    depends_on:
      db:
        condition: service_healthy
      redis:
        condition: service_started
    ports:
      - "80:80"
    environment:
      MYSQL_HOST: db
      MYSQL_DATABASE: nextcloud
      MYSQL_USER: nextcloud
      MYSQL_PASSWORD: ${MYSQL_PASSWORD}
      REDIS_HOST: redis
      REDIS_HOST_PASSWORD: ${REDIS_PASSWORD}
      NEXTCLOUD_ADMIN_USER: ${NEXTCLOUD_ADMIN_USER}
      NEXTCLOUD_ADMIN_PASSWORD: ${NEXTCLOUD_ADMIN_PASSWORD}
      NEXTCLOUD_TRUSTED_DOMAINS: "192.0.2.34 nextcloud.<網域>"
    volumes:
      - nextcloud_html:/var/www/html
      - /srv/nextcloud-data/data:/var/www/html/data

  cron:
    image: nextcloud:35.0.2-apache
    restart: unless-stopped
    entrypoint: /cron.sh
    depends_on:
      - app
    volumes:
      - nextcloud_html:/var/www/html
      - /srv/nextcloud-data/data:/var/www/html/data

volumes:
  nextcloud_html:
EOF
sudo docker compose config --quiet && echo "語法 OK"
```

| 片段 | 意思 |
| --- | --- |
| 映像標籤 | 全部鎖定完整版本，升級要自己決定 |
| `--transaction-isolation=READ-COMMITTED` | 官方手冊要求的 MariaDB 隔離等級；MariaDB 預設不開 binlog，所以不需另外設（官方要求 binlog 停用或 `ROW`） |
| `--innodb-log-file-size=256M`、`--slow-query-log=ON`、`--long-query-time=2` | 後台「資料庫」檢查的建議值（InnoDB log 預設約 96 MB，建議至少 128 MB；慢查詢 log 預設關閉、門檻 10 秒建議 2 秒）。**這三個參數是第一次後台檢查看到警告後才加的**，新部署可以一開始就放進去 |
| `healthcheck` + `service_healthy` | 資料庫真的準備好，Nextcloud 才啟動，避免第一次安裝失敗 |
| `redis` 沒有 `ports` | 只在 Compose 內部網路可達，不對主機開埠 |
| `MYSQL_*`、`REDIS_*`、`NEXTCLOUD_ADMIN_*` | 映像看到這些變數，第一次啟動會自動完成安裝，不必走網頁精靈 |
| `NEXTCLOUD_TRUSTED_DOMAINS` | 只在**第一次安裝**時生效，之後改要用 `occ`（4-13） |
| `/srv/nextcloud-data/data:/var/www/html/data` | 把資料碟的 `data` 掛進容器當資料目錄 |
| `cron` 服務 | 用映像內建的 `/cron.sh` 定期跑背景工作 |

**應該看到**：`語法 OK`。

### 4-9 啟動與首次驗證

**做什麼**：啟動四個容器，確認自動安裝完成。

**怎麼做**：

```bash
cd /opt/nextcloud
sudo docker compose up -d
sudo docker compose ps
sudo docker compose logs -f app
```

首次啟動要拉映像並安裝，約 1 到數分鐘；log 看到 `Apache ... configured -- resuming normal operations` 就可以 `Ctrl+C` 離開。

```bash
curl -sI http://localhost/ | head -n 3
sudo docker compose exec -u www-data app php occ status
```

**應該看到**：

| 項目 | 結果 |
| --- | --- |
| `docker compose ps` | 四個服務 `Up`，`db` 為 `(healthy)`；只有 `app` 對外開 `0.0.0.0:80`，3306、6379 只在容器內 |
| log | `Nextcloud was successfully installed`、`Installing with MySQL database`、`Using Redis as PHP session handler`、`trusted_domains` 兩筆（IP 與網域名稱）、PHP 8.5.12、Apache 2.4.69 |
| `curl` | `HTTP/1.1 302 Found`（導向登入頁） |
| `occ status` | `installed: true`、`version: 35.0.2.2`、`maintenance: false`、`needsDbUpgrade: false` |

`AH00558: Could not reliably determine the server's fully qualified domain name` 只是 Apache 的警告，不影響功能。用瀏覽器開 `http://192.0.2.34` 與 `http://nextcloud.<網域>`（DNS 要先建好）都能登入。

### 4-10 後台設定與檢查

**做什麼**：改用 cron 模式、補幾個建議設定，並用內建檢查確認沒有遺漏。

**怎麼做**（`occ` 要在容器內用 `www-data` 執行，先定義短指令，只在這次連線有效）：

```bash
occ() { sudo docker compose -f /opt/nextcloud/compose.yaml exec -u www-data app php occ "$@"; }
occ background:cron
occ config:system:set maintenance_window_start --type=integer --value=1
occ config:system:set logtimezone --value=Asia/Taipei
occ config:system:set default_phone_region --value=TW
occ config:system:set overwrite.cli.url --value=http://nextcloud.<網域>
```

| 設定 | 意思 |
| --- | --- |
| `background:cron` | 背景工作從預設 AJAX 改為 cron，搭配 `cron` 容器 |
| `maintenance_window_start` | 重度維護工作排在 UTC 01:00 起（台北 09:00），這個時段你可依使用習慣調整 |
| `logtimezone` | log 時間改用台北時區 |
| `default_phone_region` | 消除後台「未設定預設電話區碼」的警告 |
| `overwrite.cli.url` | cron、命令列產生的連結用實際網址，預設是 `http://localhost`；改 HTTPS 時要同步改 |

**檢查快取與檔案鎖**（映像在設了 `REDIS_HOST` 時會自動寫入）：

```bash
occ config:system:get trusted_domains
occ config:system:get memcache.local
occ config:system:get memcache.distributed
occ config:system:get memcache.locking
occ config:system:get redis host
```

**應該看到**：`trusted_domains` 為 `localhost`、`192.0.2.34`、`nextcloud.<網域>`；`memcache.local` 為 `\OC\Memcache\APCu`；`memcache.distributed` 與 `memcache.locking` 為 `\OC\Memcache\Redis`；`redis host` 為 `tcp://redis`。這是官方手冊單機建議的組合（APCu 做本地快取、Redis 做分散式快取與檔案鎖）。

**驗證 cron 真的在跑**（等 5 分鐘以上）：

```bash
occ config:app:get core lastcron
date +%s
sudo docker compose -f /opt/nextcloud/compose.yaml logs --tail=20 cron
```

**應該看到**：`lastcron` 與 `date +%s` 相差 5 分鐘內（本案 95 秒）。`cron` 容器 log 開頭會有 `Not installed`：`cron` 容器比 `app` 先啟動，Nextcloud 當時還在安裝，這是第一次部署的競態，無害。

**mimetype 遷移與後台檢查**：

```bash
occ maintenance:repair --include-expensive
occ setupchecks | grep -E "⚠|Mimetype"
```

新安裝資料量小，很快跑完。`occ setupchecks` 在 35.0.2 可以用。資料庫的詳細檢查要看網頁：`http://nextcloud.<網域>/index.php/settings/admin/serverinfo#database`。

**本案實測**：

| 檢查項目 | 結果 |
| --- | --- |
| 資料庫檢查（調校前） | 3 項：InnoDB log file size 100,663,296 bytes（建議至少 128 MB，失敗）、Slow query log 關閉（提示）、Long query time 10 秒（提示） |
| 資料庫檢查（調校後） | `innodb_log_file_size` 268,435,456、`slow_query_log` 1、`long_query_time` 2；網頁顯示結果 0、通過 13、略過 24；資料庫連線 1／151、每秒查詢 12、延遲 0.51 ms |
| `occ setupchecks` | **會顯示舊的快取結果**：網頁已經通過時，命令列仍顯示 `Database configuration` failing，以網頁為準 |
| Mimetype migrations | 執行 `--include-expensive` 後 `None` |
| 刻意保留 | `HTTP headers` 的 HSTS 警告（只有 HTTPS 才有意義，內網 HTTP 階段不要設）；log 內的 4 筆 error（見第 5 節，均無害，近 7 天視窗過後預期會消失，未實測） |

**對運作中的資料庫補參數**時，建議先開維護模式再重建 `db`，使用者看到的是維護頁而不是錯誤：

```bash
occ maintenance:mode --on
sudo docker compose up -d db
sudo docker compose ps db
occ maintenance:mode --off
```

### 4-11 備份（PBS）

**做什麼**：確認 VM 115 被排程備份涵蓋，並手動做一次備份。

**怎麼做**：本環境三個節點各有一個「備份該節點所有客體」的排程（`cat /etc/pve/jobs.cfg` 可看）：

| 節點 | 時間 | 範圍 | 保留（日／週／月） |
| --- | --- | --- | --- |
| node10 | 21:00 | all | 7 / 4 / 3 |
| node11 | 21:30 | all | 7 / 4 / 6 |
| node12 | 22:00 | all | 7 / 4 / 3 |

VM 115 在 node11，被 21:30 的排程涵蓋，**不需要另外新增備份工作**（新增只會備份兩次）；因為每個節點都有 `all` 排程，VM 被 HA 搬到別的節點也仍被涵蓋。手動備份：

```bash
pvesm status | grep PBS31
vzdump 115 --storage PBS31 --mode snapshot --notes-template '{{guestname}} manual-1'
pvesm list PBS31 | grep "vm/115"
```

| 片段 | 意思 |
| --- | --- |
| `--mode snapshot` | 不關機備份，PVE 先用 guest agent 凍結檔案系統 |
| `--notes-template` | 備份備註，方便辨識 |

**應該看到**：`Finished Backup of VM 115`、`Backup job finished successfully`；清單有一筆 `vm/115/<時間>`。本案手動備份時間為 `2026-11-06T06:17:48Z`（台北 14:17），顯示的大小 141,733,921,846 bytes（約 132 GiB）是兩顆碟的**邏輯容量**（32G + 100G），不是 PBS 實際佔用的空間（PBS 會去重複，資料碟 99% 是空的）。

PBS 另有 Verify Job（本環境每天 22:45、勾選 Skip Verified、15 天後重新驗證）：新備份約 20 小時後就會被驗證到。注意 Verify 只驗證「備份資料完整」，不等於「能還原」，所以下一步一定要做還原演練。

### 4-12 還原演練

**做什麼**：把備份還原成**另一台** VM（VMID 915），**先斷網路**，驗證能開機、資料完整，再清理。

**怎麼做**（在 VM 所在的節點；`<時間>` 換成 `pvesm list` 看到的值）：

```bash
qmrestore PBS31:backup/vm/115/<時間> 915 --storage VM_Pool --unique 1
qm set 915 --net0 virtio,bridge=vmbr0,link_down=1
qm set 915 --onboot 0
qm set 915 --name nextcloud-restore-test
qm config 915 | grep -E "^name|net0|onboot|ipconfig0"
```

| 片段 | 意思 |
| --- | --- |
| `915` | 演練用的新 VMID，**不要用 115**；若已存在，`qmrestore` 會報錯而不會覆蓋 |
| `--unique 1` | 產生新的 MAC，避免與原 VM 重複 |
| `link_down=1` | 網卡設為「已中斷」，**必要**：Cloud-Init 設定一起還原，IP 與原 VM 相同，不斷網一開機就會搶 IP |
| `--onboot 0`、`--name` | 避免節點重開時自動啟動、避免與正式機混淆 |

**應該看到**：還原進度（本案資料碟 107,374,182,400 bytes，`zeroes = 99%`，2.32 秒完成）、`net0` 含 `link_down=1`、`onboot: 0`。確認 `link_down=1` 之後才開機：

```bash
qm start 915
```

用 PVE 網頁開 **915** 的 Console 登入（視窗標題要是 915，不要在 115 操作），執行：

```bash
lsblk -f
df -h /srv/nextcloud-data
sudo docker compose -f /opt/nextcloud/compose.yaml ps
sudo docker compose -f /opt/nextcloud/compose.yaml exec -u www-data app php occ status
sudo docker compose -f /opt/nextcloud/compose.yaml exec -u www-data app php occ user:list
sudo ls /srv/nextcloud-data/data
```

**應該看到**：

| 項目 | 結果 |
| --- | --- |
| 登入提示與 hostname | `nextcloud-restore-test`（Cloud-Init 用新的 VM 名稱當 hostname） |
| `lsblk`／`df` | `sdb1` 自動掛載，UUID 與原 VM 相同，已用 413M |
| 四個容器 | 都自動 `Up`，`db` 為 `(healthy)`，容器的 `CREATED` 是原 VM 建立當時的時間（代表是還原的，不是重新部署） |
| `occ status` | `installed: true`、`version: 35.0.2.2` |
| `user:list`、資料目錄 | 管理者帳號還在；資料目錄有使用者資料夾、`appdata_*`、`nextcloud.log` |

開機時系統日誌會出現 `system.journal corrupted or uncleanly shut down`：備份是 VM 運作中的快照（crash-consistent），還原後等於「突然斷電後開機」，屬預期。

**清理**（在節點的 shell，不是 Console；**確認是 915 不是 115**）：

```bash
qm list | grep -E "115|915"
qm stop 915
qm destroy 915 --purge
qm list | grep -E "115|915"
```

**應該看到**：最後只剩 115，915 與它的磁碟已移除。

### 4-13 之後要改 IP 或主機名稱

**做什麼**：IP、hostname 都是由 **PVE 的 Cloud-Init** 決定的，改 PVE 這邊，不要只改 VM 裡的 netplan 或 `hostnamectl`（下次 Cloud-Init 重新套用會改回去）。

**怎麼做**：先改 Nextcloud 這一側（還連得上時做），索引依 `occ config:system:get trusted_domains` 的順序調整：

```bash
occ config:system:get trusted_domains
occ config:system:set trusted_domains 1 --value=<新 IP>
occ config:system:set trusted_domains 2 --value=<新主機名稱>.<網域>
sed -i 's/<舊 IP>/<新 IP>/; s/<舊主機名稱>/<新主機名稱>/' /opt/nextcloud/compose.yaml
```

`compose.yaml` 裡的 `NEXTCLOUD_TRUSTED_DOMAINS` 安裝後不再讀取，改它只是讓文件與實際一致。再改 PVE（VM 所在節點）：

```bash
qm set 115 --name <新主機名稱>
qm set 115 --ipconfig0 ip=<新 IP>/24,gw=192.0.2.1
qm set 115 --searchdomain <網域>
qm cloudinit update 115
qm reboot 115
```

然後在**兩台 DNS 各自**新增新的 A record（舊的刪除），最後驗證：

```bash
hostnamectl
ip -br a
sudo docker compose -f /opt/nextcloud/compose.yaml ps
```

**應該看到**：hostname、IP 都是新值，四個容器都 `Up`；瀏覽器用新網址能登入，舊 IP 不通。本案實測 VM 重開後容器都自動啟動。

## 5. 常見問題

| 現象 | 怎麼辦 |
| --- | --- |
| 用 Ubuntu Server ISO 安裝時，在 `installing kernel` 失敗（`curtin` log：`apt-get install --download-only linux-generic`，`Exit code: 100`，stderr 是空的） | 分割與格式化其實都成功了，失敗的是下載套件。同一網路在 VM 裝好後 `apt update` 是通的，所以**確切原因未確認**（推測與安裝程式環境的 IPv6 或 mirror 有關）。改用 cloud image 就不需要安裝程式，本篇即採此做法 |
| SSH 顯示 `No supported authentication methods available (server sent: publickey)` | Ubuntu cloud image 預設**禁止 SSH 密碼登入**，Cloud-Init 設的密碼只能在 Console 用。用 `--sshkeys` 或 PVE 網頁的 Cloud-Init 分頁貼上公鑰（公鑰在網頁貼得上），再重新開機 |
| PVE 的 noVNC Console 沒辦法貼上文字 | 改用 SSH 操作；要貼公鑰就用 PVE 網頁的 Cloud-Init 欄位 |
| `df` 顯示 `/srv/nextcloud-data` 在 `/dev/sda1`，不是 `/dev/sdb1` | 資料碟沒掛上，目錄只是系統碟上的資料夾。看 `lsblk -f`、`/etc/fstab`、`sudo findmnt --verify`。**不要往沒掛載的目錄寫資料** |
| `fstab` 出現 `UUID= /srv/nextcloud-data ...`（`=` 後面是空的） | `mkfs` 沒成功，`blkid` 查不到 UUID 卻照樣寫入。移除那一行，重新 `mkfs`，確認 `UUID=[...]` 有值再寫入（4-6 已加防呆） |
| `Access through untrusted domain` | 用了沒列入 `trusted_domains` 的網址，用 `occ config:system:set trusted_domains <索引> --value=...` 新增 |
| 後台「Errors in the log」顯示 `Not installed`（app: cron） | `cron` 容器比 `app` 先啟動的競態，無害 |
| log 出現 3 筆 `Failed to connect to the database ... [2002] Connection refused` | 重建 `db` 容器的那幾秒網站收到請求，資料庫恢復後正常；重啟前先開維護模式可避免（4-10） |
| `occ setupchecks` 還顯示 `Database configuration` failing，網頁卻是 0 個問題 | 命令列顯示的是快取的舊結果，以網頁 `serverinfo#database` 為準 |
| 還原演練的 VM 開機後和正式機搶 IP | 還原後**先設 `link_down=1` 再開機**（4-12） |
| 還原後開機訊息出現 `journal ... uncleanly shut down` | 預期，見 4-12 |
| 改了 VM 內的 netplan 或 hostname，重開機後又變回去 | IP 與 hostname 由 PVE Cloud-Init 決定，改 PVE（4-13） |
| 改了 IP，網頁卻連不上或域名解析到舊 IP | 兩台 DNS 是各自獨立的，A record 要**兩台都改**；`trusted_domains` 也要同步 |
| 指令貼上後出現 `<…>` 的奇怪錯誤 | 文中 `<…>` 是占位字，**整段（含角括號）要換成真實值**，不能原封不動貼上（下篇 Wazuh 有實際踩雷） |

## 6. 目前狀態與待辦

| 範圍 | 狀態 |
| --- | --- |
| VM、資料碟、Docker、Nextcloud 35.0.2.2 | ✅ |
| cron、快取與檔案鎖、資料庫調校、後台檢查 | ✅ |
| 手動備份、還原演練 | ✅ |
| 排程備份（node11 21:30） | ⏳ VM 已被涵蓋，第一次執行結果尚未確認 |
| HTTPS、HSTS、2FA、防火牆 | ⏳ 對外開放前處理 |
| 監控與日誌 | 見[下篇](https://kbwangtw.github.io/IT-Knowledge-Base/docs/pve/nextcloud-monitoring-wazuh-librenms-graylog/) |

待辦：

- [ ] 排程備份第一次執行後，用 `pvesm list PBS31 | grep "vm/115"` 確認多了一筆
- [ ] 確認 PBS 的 Verify Job 的 Datastore 與 PVE 的 `PBS31` 儲存體對應（Verify 畫面顯示的 Datastore 名稱與 `PBS31` 不同，是否同一個資料倉庫**未確認**）
- [ ] 對外開放前：HTTPS（reverse proxy）、HSTS、`trusted_proxies`、`overwriteprotocol`、`overwrite.cli.url`
- [ ] 啟用 2FA；評估 fail2ban（官方要求 `loglevel` 設為 2 以下並監控 `nextcloud.log`）
- [ ] 防火牆：VM 本機 `ufw` 是 inactive；Docker 與 `ufw` 有已知的交互問題，建議改用 PVE Firewall 限制來源
- [ ] 評估每日 `mariadb-dump --single-transaction` 作為第二層保險（官方手冊的資料庫備份指令）
- [ ] 確認 CPU 類型：`qm config 115` 的 `cpu:`（沒有這行代表用預設）
- [ ] 後台「Errors in the log」7 天後確認是否消失
- [ ] 大版本升級流程（35 → 36 不可跳版，另外記錄）

## 7. 延伸閱讀

- [Nextcloud Administration Manual](https://docs.nextcloud.com/server/latest/admin_manual/)（系統需求、背景工作、快取、備份）
- [Nextcloud 官方 Docker image](https://github.com/nextcloud/docker)
- [Nextcloud All-in-One（官方安裝方式）](https://github.com/nextcloud/all-in-one)
- [Docker Engine 安裝（Ubuntu）](https://docs.docker.com/engine/install/ubuntu/)
- [Ubuntu cloud images](https://cloud-images.ubuntu.com/)
- [Proxmox VE：Cloud-Init Support](https://pve.proxmox.com/wiki/Cloud-Init_Support)

{% endraw %}
