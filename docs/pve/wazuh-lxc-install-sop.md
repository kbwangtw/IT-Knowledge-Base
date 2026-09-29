---
layout: default
title: "在 PVE 用 LXC 建置 Wazuh：安裝 SOP"
date: 2026-09-29
categories: [PVE, Wazuh, SIEM, Security, LXC]
permalink: /docs/pve/wazuh-lxc-install-sop/
last_modified_at: 2026-09-29
---

# 在 PVE 用 LXC 建置 Wazuh：安裝 SOP

這篇是**安裝規劃 SOP**，整理官方文件與 LXC 常見踩雷點，還沒有在實際叢集跑過完整驗收。跟著做之後，建議把你自己的實測結果（版本號、資源用量、卡關點）補回本文，取代「規劃」的定位。

> 撰寫日期：2026-09-29。目標是單機 All-in-One（Indexer + Manager + Dashboard 都在同一顆 LXC），適合實驗室／小型環境先跑起來看效果。正式環境的三節點分離部署（Indexer 叢集、Manager 叢集）不在本文範圍。

## 為什麼特別挑出 LXC 來寫？

Wazuh 官方安裝腳本是針對一般 Linux 主機設計，直接裝在 LXC 容器裡大致可行（不需要 Docker），但有兩個地方跟一般虛擬機不同，容易卡關：

1. **`vm.max_map_count` 這類部分核心參數不是每個 namespace 各自獨立**，在容器內部 `sysctl -w` 常常改了沒效果，要到 PVE Host 上設定。
2. LXC 容器的資源限制（CPU、記憶體）是 cgroup 限制，OpenSearch（Wazuh Indexer 的底層）對記憶體、mmap 數量比較敏感，資源給太少會在啟動階段就失敗，而不是慢慢變慢。

## 架構總覽

~~~text
PVE Host
 └─ LXC (unprivileged)：wazuh01
     ├─ wazuh-indexer   (OpenSearch，儲存與搜尋事件)
     ├─ wazuh-manager   (接收 Agent 事件、規則比對、API)
     └─ wazuh-dashboard (Web UI，預設監聽 443)

其他主機／裝置
 └─ 安裝 wazuh-agent，回報到 wazuh01:1514 / 1515
~~~

## 0. 事前準備

| 項目 | 建議值 | 說明 |
| --- | --- | --- |
| PVE 版本 | 8.x／9.x 皆可 | 本文指令以 `pct` 為主，跟版本關係不大 |
| LXC 模板 | Ubuntu 22.04 或 Debian 12（標準 systemd 模板） | Wazuh 官方套件庫支援 Debian／Ubuntu 系列 |
| CPU | 測試用 2～4 vCPU；正式規模再往上加 | 官方對正式環境的建議規格會隨版本調整，安裝前先到官網 Quickstart 頁面核對當下版本的建議值 |
| RAM | 測試用 4～8 GB；正式環境建議 8 GB 以上 | Indexer（OpenSearch）吃記憶體，給太少會啟動失敗 |
| 磁碟 | 至少 40～60 GB，且用獨立的 storage（不要跟系統碟共用） | 事件資料會持續累積，容量規劃比 CPU/RAM 更容易被忽略 |
| 網路 | 固定 IP 或 DHCP + 保留 | Agent 端要填 Manager IP，IP 換掉要跟著改所有 Agent 設定 |

先到 [Wazuh 官方 Quickstart](https://documentation.wazuh.com/current/quickstart.html) 確認目前版本的安裝指令與資源需求——Wazuh 版本更新頻繁，本文不鎖定特定版本號，避免文件過期後指令直接失效。

## 1. 在 PVE Host 建立 LXC 容器

~~~bash
# 範例 VMID 210，依你自己的編號規則調整
pct create 210 local:vztmpl/ubuntu-22.04-standard_22.04-1_amd64.tar.zst \
  --hostname wazuh01 \
  --cores 4 \
  --memory 8192 \
  --swap 512 \
  --rootfs local-lvm:60 \
  --net0 name=eth0,bridge=vmbr0,ip=dhcp \
  --unprivileged 1 \
  --onboot 1

pct start 210
pct enter 210
~~~

不需要 `nesting=1`：Wazuh 直接裝系統套件，不靠 Docker，容器不用跑巢狀容器。維持預設的 unprivileged，先不要為了「怕裝不起來」就改成 privileged——真正會卡關的是下一步的核心參數，跟容器是否 privileged 無關。

進容器後先做基本設定：

~~~bash
apt update && apt -y upgrade
apt -y install curl gnupg apt-transport-https lsb-release chrony
timedatectl set-timezone Asia/Taipei
systemctl enable --now chrony
~~~

時間同步很重要：OpenSearch 的憑證驗證與事件時間戳都依賴系統時間，時間跑掉會出現一堆難以對應原因的 TLS 或索引錯誤。

## 2. 在 PVE Host 設定核心參數（不是在容器裡）

`vm.max_map_count` 這個值影響 OpenSearch 能開的記憶體映射數量，官方要求至少 262144。這是**整台宿主機共用的核心設定**，不會因為是哪個 LXC 容器而各自獨立，所以要在 PVE Host（不是容器內部）執行：

~~~bash
# 在 PVE Host 執行
cat > /etc/sysctl.d/99-wazuh-indexer.conf <<'EOF'
vm.max_map_count=262144
EOF
sysctl --system
sysctl vm.max_map_count
~~~

如果在容器內執行 `sysctl -w vm.max_map_count=262144` 卻沒有噴錯，也不代表生效——用上面這行在 Host 端確認過的值才是實際生效的值。這一步沒做，Indexer 服務通常會在啟動時直接失敗並在 log 裡出現 `max virtual memory areas vm.max_map_count is too low` 之類的訊息。

進階調優（可選，先讓基本安裝跑起來再考慮）：

~~~bash
# 同樣在 PVE Host 執行，降低 swappiness、停用 THP
echo 'vm.swappiness=1' >> /etc/sysctl.d/99-wazuh-indexer.conf
sysctl --system
echo never > /sys/kernel/mm/transparent_hugepage/enabled
~~~

停用 THP 用 `echo` 寫入 `/sys` 不會在重開機後保留，要做成開機腳本或 systemd oneshot service 才會持久，這裡先記下踩坑點，沒有展開完整做法。

## 3. 安裝 Wazuh（All-in-One）

回到容器內執行。官方提供一鍵安裝腳本，會依序裝好 Indexer、Manager、Dashboard 並自動產生憑證：

~~~bash
curl -sO https://packages.wazuh.com/4.x/wazuh-install.sh
bash wazuh-install.sh -a
~~~

安裝過程請對照 [Quickstart 頁面](https://documentation.wazuh.com/current/quickstart.html) 上當下版本的實際指令（URL 中的版本路徑會隨發版更新），不要直接照抄本文的網址而不核對。

安裝完成後畫面會顯示 `admin` 帳號的密碼，**只會顯示一次**，務必立刻記下來。同一層目錄會產生 `wazuh-install-files.tar.gz`，裡面含有憑證與密碼記錄檔，這個檔案要備份到容器外面（例如存到 PBS 備份範圍或另外複製一份），容器如果重建就拿不回來了。之後忘記密碼可以用官方的 `wazuh-passwords-tool.sh` 重設，但前提是 `wazuh-install-files.tar.gz` 還在。

## 4. 驗證安裝

~~~bash
systemctl status wazuh-indexer --no-pager
systemctl status wazuh-manager --no-pager
systemctl status wazuh-dashboard --no-pager
~~~

三個服務都要是 `active (running)`。`running` 只代表程式在跑，不代表功能正常，繼續往下確認：

~~~bash
curl -k -u admin:<你的密碼> https://localhost:9200
~~~

回傳 JSON 且包含 `cluster_name` 等欄位，代表 Indexer 有正常回應。接著用瀏覽器連到：

~~~text
https://<容器IP>/
~~~

用 `admin` 帳密登入 Dashboard，看得到儀表板畫面才算安裝完成。憑證是自簽的，瀏覽器會跳警告，這是預期行為，不是安裝失敗。

## 5. PVE 防火牆規則

| Port | 協定 | 用途 | 對外開放範圍 |
| --- | --- | --- | --- |
| 443 | TCP | Dashboard Web UI | 只開放管理來源，不建議直接暴露公網 |
| 1514 | TCP | Agent 回報事件 | 開放給有安裝 Agent 的主機來源 |
| 1515 | TCP | Agent 註冊（enrollment） | 同上；註冊完成後可視情況收緊 |
| 55000 | TCP | Wazuh API | 只開放管理來源 |
| 9200 | TCP | Indexer API | 不對外開放，僅供本機／內部服務呼叫 |

實際 port 清單以你安裝版本的官方文件為準，這裡列的是目前常見的預設值。在 PVE 可以參考本站另一篇 [Fail2Ban 硬化紀錄](../pve-cluster-fail2ban-hardening/) 的查驗方式：規則存在不代表真的擋到／放行到，設定完要用 `pve-firewall status` 或從外部實際測試連線來確認。

## 6. 加入第一個 Agent

不要照抄網路上的套件檔名，Wazuh 每版套件檔名都會變。最可靠的方式是登入 Dashboard 後，用內建的「Add agent」精靈：它會依你選的作業系統與目前安裝的版本，自動組出對應的安裝指令（含正確的套件網址與版本號），複製貼上到目標主機執行即可。

大致流程：

1. Dashboard → Agents → Add agent
2. 選擇目標主機的作業系統
3. 填入 Manager 位址（就是這台 LXC 的 IP 或 hostname）
4. 複製精靈產生的安裝指令，到目標主機上執行
5. 完成後回到 Dashboard 確認該 Agent 顯示為 Active

## 常見卡關點

| 現象 | 常見原因 | 怎麼查 |
| --- | --- | --- |
| wazuh-indexer 啟動失敗 | Host 端 `vm.max_map_count` 沒設定或沒生效 | `sysctl vm.max_map_count`（在 PVE Host 上查，不是容器內） |
| Indexer 啟動後很快被 OOM Kill | 容器記憶體給太少 | `pct config <vmid>` 確認 memory 設定；`journalctl -u wazuh-indexer` 找 OOM 訊息 |
| Dashboard 打不開但服務都是 running | 防火牆沒放行 443，或容器網路設定問題 | 從容器內 `curl -k https://localhost` 先排除服務本身問題，再往外查防火牆 |
| Agent 顯示 Never connected | Port 1514/1515 沒開，或 Agent 端填錯 Manager IP | 在 Manager 端 `netstat -lntp \| grep -E '1514\|1515'` 確認有在監聽 |
| 密碼忘記、找不到 `wazuh-install-files.tar.gz` | 安裝當下沒備份這個檔案 | 只能靠官方重設流程處理，之後務必把這個檔案納入備份範圍 |

## 後續建議

- 資料具狀態（Indexer 的索引資料在容器磁碟上），建議比照本站 [PBS 備份與還原](../ProxCenter-PBS-Update-and-DR-Validation-SOP/) 的做法，排定備份並實際做一次還原演練，不要只靠「有排程」就當作可還原。
- 正式環境如果 Agent 數量變多，評估是否要把 Indexer／Manager 拆到不同節點，而不是繼續塞在同一顆 LXC 裡。
- 裝完之後，把本文的「規劃」字樣拿掉，補上實際版本號、資源用量與遇到的問題，讓這篇變成跟其他文章一樣的「實測紀錄」。

## 參考資料

- [Wazuh 官方文件 - Quickstart](https://documentation.wazuh.com/current/quickstart.html)
- [Wazuh 官方文件 - Installation guide](https://documentation.wazuh.com/current/installation-guide/index.html)
- [Proxmox pct 指令文件](https://pve.proxmox.com/pve-docs/pct.1.html)
