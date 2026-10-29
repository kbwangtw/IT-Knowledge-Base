---
layout: default
title: 資訊黑手的 Knowledge Base
last_modified_at: 2026-10-22
---

# 資訊黑手的 IT 維運筆記

> **一句話**：這裡記錄的是一個小型機房的真實維運過程：遇到什麼問題、怎麼查、怎麼處理、最後驗證到哪裡。每篇都用剛入行也看得懂的方式寫，指令旁邊會說明它在做什麼。

| 項目 | 內容 |
| --- | --- |
| 適合誰看 | 剛接觸虛擬化、備份、監控的 IT 新鮮人；想找實際案例對照的維運人員 |
| 文章數 | 40 篇，分 6 類 |
| 最近更新 | 2026-10-17：全站改寫為新手版 |

## 1. 這裡記錄的是什麼環境

```text
                     ┌───────────── PVE 叢集（3 台節點，共用 Ceph 儲存）─────────────┐
                     │  DNS ×2、網域控制站 ×2、CA、Graylog、Wazuh、LibreNMS、         │
                     │  Grafana、jt-ipam、WireGuard、ProxCenter …（VM 與容器）        │
                     └───────────────┬───────────────────────────────────────────┘
                                     │ 每晚備份
                                     ▼
                     PBS（備份伺服器，資料放在 NAS 上）  ── Synology NAS／DP340
外面連回來 ── WireGuard VPN ──▶ 內網           GCP 雲端主機、Nutanix、HPE 伺服器（另外記錄）
```

| 類別 | 用到的東西 |
| --- | --- |
| 虛擬化 | Proxmox VE（PVE）三節點叢集、Ceph 共用儲存、ProxCenter 管理工具 |
| 備份 | Proxmox Backup Server（PBS）、Synology NAS、Synology DP340 |
| 監控與資安 | Graylog（集中日誌）、Wazuh（資安監控）、LibreNMS（設備監控）、Grafana（戰情中心） |
| 網路 | WireGuard VPN、jt-ipam（IP 位址管理）、DNS |
| 其他 | GCP 雲端主機、Nutanix、HPE ML30 伺服器 |

## 2. 先認識幾個名詞

| 名詞 | 白話解釋 |
| --- | --- |
| **PVE（Proxmox VE）** | 免費的虛擬化平台，一台實體主機上跑很多台虛擬機 |
| **VM／CT（LXC）** | 虛擬機／輕量容器；容器和主機共用 Linux kernel，比較省資源 |
| **叢集（Cluster）** | 多台 PVE 一起管理；一台壞了，服務可以搬到別台 |
| **HA（高可用）** | 主機掛了，PVE 自動把服務在別台重新啟動 |
| **Ceph** | 把三台主機的硬碟合成一個共用儲存，資料存三份 |
| **PBS** | 專門存 PVE 備份的伺服器 |
| **Syslog** | 主機把日誌送到別台的標準方式 |
| **Agent** | 裝在被監控主機上的小程式 |
| **SOP** | 標準作業程序，照著做就能完成的步驟 |

## 3. 第一次來，建議這樣讀

| 順序 | 文章 | 讀完會知道 |
| --- | --- | --- |
| 1 | [把 PVE／PBS 通知改成繁體中文](docs/pve/proxmox-zh-tw-notification/) | 最短、最好上手；看懂 PVE 通知怎麼運作 |
| 2 | [PVE 更新重開後 HA 服務卡在 error](docs/pve/pve-ha-service-error-after-reboot/) | HA 是什麼、為什麼重開前要進維護模式 |
| 3 | [從 PBS 還原 ProxCenter](docs/pve/proxcenter-pbs-restore-dr-runbook/) | 備份做完，怎麼確認真的還原得回來 |
| 4 | [把 PVE、PBS 與 NAS 的日誌集中到 Graylog（一）](docs/pve/proxmox-graylog-syslog-pipeline-sop/) | 日誌集中、分類、寄信設定；告警與監控接著讀（二） |
| 5 | [不再把 PVE 8006 開到網際網路：改用 WireGuard](docs/pve/wireguard-remote-access-replace-8006/) | 為什麼管理介面不能直接開到外網 |

## 4. 文章目錄

### 4-1 儲存出問題（Ceph）

| 文章 | 適合什麼時候看 |
| --- | --- |
| [PVE 出現問號、儲存變成 0：這次怎麼救回來？](docs/pve/ceph-osd-cephfs-keyring-recovery/) | 主機都在線，但 Ceph 儲存顯示 0、CephFS 掛不上 |
| [PVE 重開後 Ceph 又故障：修正 BlueStore 裡的 OSD 金鑰](docs/pve/ceph-bluestore-osd-key-recovery-2026-09-22/) | 修好後一重開又壞；要輪換 OSD 金鑰 |
| [Ceph 換金鑰：為什麼 HEALTH_OK 還不夠？](docs/pve/ceph-20-2-4-cephx-aes256k-migration/) | 換 Ceph 金鑰時，有哪些地方容易漏掉 |
| [Ceph 出現 BlueStore 慢操作告警：硬碟壞了嗎？](docs/pve/ceph-bluestore-slow-op-backup-schedule/) | 看到慢操作警告；要排 PVE／PBS 備份時間 |

### 4-2 更新主機與日常管理

| 文章 | 適合什麼時候看 |
| --- | --- |
| [從 VMware ESXi 滾動式轉換到 PVE：新機先上、舊機回收（規劃 SOP）](docs/pve/esxi-to-pve-rolling-migration-sop/) | 要把 ESXi 換成 PVE，但硬體不夠多；Unity 走 FC 的 shared LVM、搬 VM、舊機回收成節點（規劃，未實測） |
| [ProxCenter 逐台更新 PVE：三個卡關點](docs/pve/proxcenter-ceph-rolling-update/) | 想用工具一次一台安全地更新叢集 |
| [PVE 更新重開後 HA 服務卡在 error](docs/pve/pve-ha-service-error-after-reboot/) | HA 服務顯示 error；要手動重開節點 |
| [整個 PVE 叢集安全關機與開機：一鍵腳本](docs/pve/pve-cluster-full-shutdown/) | 搬機房、停電維護，要把三台全關再開回來 |
| [PVE HA 放置策略：PVE 和 ProxCenter 怎麼分工？](docs/pve/pve-ha-placement-policy/) | 兩台 DNS 不能放同一台，規則要設在哪裡 |
| [PBS 更新後，怎麼確認備份還能用？](docs/pve/ProxCenter-PBS-Update-and-DR-Validation-SOP/) | 更新 PBS 前後要查什麼；怎麼安全清理舊 kernel |
| [PVE 9 登入一直跳「No valid subscription」](docs/pve/pve9-subscription-nag-removal/) | 沒買訂閱，想取消登入提示 |
| [一次檢查並統一所有 LXC 的時區](docs/pve/pve-lxc-timezone/) | 容器時間差 8 小時；改時區前先看排程會不會移位；補上缺少的 en_US.UTF-8 語系 |
| [把 PVE／PBS 通知改成繁體中文](docs/pve/proxmox-zh-tw-notification/) | 備份通知信看不懂，想改成中文 |

### 4-3 備份與還原

| 文章 | 適合什麼時候看 |
| --- | --- |
| [從 PBS 還原 ProxCenter：先複製一台，再確認能用](docs/pve/proxcenter-pbs-restore-dr-runbook/) | 第一次做容器還原演練 |
| [Ubuntu VM 從 PBS 還原：6 分 38 秒代表什麼？](docs/pve/ubuntu-vm112-pbs-disaster-recovery/) | 有影片的 VM 還原實測；怎麼解讀還原時間 |
| [用 DP340 備份 PVE：先把還原測試安排好](docs/pve/synology-dp340-pve-cluster-validation/) | 用 Synology 備份 PVE，要怎麼規劃驗證 |
| [用 DP340 備份 Google Workspace](docs/synology/dp340-google-workspace-apm20-sop/) | 備份公司 Gmail、Drive；授權與還原測試 |
| [DP340 顯示省下 75% 空間，該怎麼看？](docs/synology/dp340-google-workspace-apm20-dedup-test/) | 看懂重複資料刪除的數字 |

### 4-4 日誌、監控與資安

| 文章 | 適合什麼時候看 |
| --- | --- |
| [把 PVE、PBS 與 NAS 的日誌集中到 Graylog（一）：收集、分類與寄信設定](docs/pve/proxmox-graylog-syslog-pipeline-sop/) | 想把各主機日誌集中查詢、設定 Gmail 寄信 |
| [Graylog 告警與監控（二）：告警清單與監控腳本](docs/pve/graylog-alerts-monitoring/) | 告警有哪些、Graylog 掛了怎麼知道、NAS 複寫與備份監控 |
| [Graylog 告警與監控（三）：中文告警信與摘要](docs/pve/graylog-alert-templates/) | 告警信改成中文、摘要直接寫出哪台什麼事 |
| [PVE 告警實測：三項核心告警完整驗證成功](docs/pve/graylog-pve-alert-validation-2026-09-18/) | 告警設好了，怎麼證明它真的會寄信 |
| [在 PVE Cluster 用 LXC 架設 Wazuh（一）：安裝與接上 Agent](docs/pve/wazuh-lxc-ubuntu2204-sop/) | 自建資安監控：建容器、安裝、備份與 HA、幫各種主機裝 Agent |
| [Wazuh 維運（二）：資料保留、告警調校、弱點修補與整合](docs/pve/wazuh-lxc-ubuntu2204-operations/) | Wazuh 裝好後：磁碟不爆、告警降噪、看弱點、接其他系統 |
| [用 Grafana 建立戰情中心（一）：接上 Wazuh](docs/pve/grafana-war-room-wazuh/) | 把資安數據放進一頁儀表板 |
| [用 Grafana 建立戰情中心（二）：接上 LibreNMS](docs/pve/grafana-war-room-librenms/) | 把設備上下線狀態放進同一頁 |
| [用 Grafana 建立戰情中心（三）：接上 Prometheus（Ceph 與 PVE）](docs/pve/grafana-war-room-prometheus/) | Ceph 健康、節點負載、VM 在哪台節點與 HA 狀態 |
| [LibreNMS 溫度告警誤報：LXC 重複感測器與門檻整理](docs/pve/librenms-temperature-sensor-cleanup/) | 一直跳 Temperature above threshold；容器重複回報、門檻不合理 |
| [PVE 一直被嘗試登入：怎麼確認 Fail2Ban 真的有擋？](docs/pve/pve-cluster-fail2ban-hardening/) | 有人一直猜密碼；加上兩步驟驗證 |
| [不再把 PVE 8006 開到網際網路：改用 WireGuard](docs/pve/wireguard-remote-access-replace-8006/) | 在外面要管理家裡或公司的主機 |
| [PHP2Shell（CVE-2026-109618、109619）：檢查環境有沒有中](docs/pve/php2shell-check/) | 聽到 PHP 漏洞，想知道哪些主機受影響、修補了沒有 |
| [Node2Shell 與 LiteLLM 供應鏈攻擊：檢查環境有沒有中](docs/pve/node2shell-litellm-check/) | 找出所有 Node.js（含程式自帶的）和 LiteLLM，判斷怎麼修 |
| [用 Claude Code 取代 Hermes：去識別化閘道與手機遙控](docs/pve/claude-code-redact-gateway/) | 想讓 AI 自己操作伺服器，但 IP、帳號不上雲；手機也能遙控 |

### 4-5 網路與 IP 管理

| 文章 | 適合什麼時候看 |
| --- | --- |
| [jt-ipam 導入紀錄：從 IP 掃描到 PVE、LibreNMS 與機櫃管理](docs/network/jt-ipam-adoption-itbh/) | 想用工具管理 IP 位址，不再用 Excel |
| [有用中華電信資安艦隊：DNS 為什麼不能設 8.8.8.8？](docs/network/cht-security-fleet-dns-filtering/) | ping 得到外網，網址卻打不開 |
| [圖書館 Nebula 網路改造：VLAN 隔離讀者、CIP 過濾、兩條 FTTB 分流](docs/network/zyxel-nebula-library-vlan-dual-wan-plan/) | 第一次用 Nebula 切 VLAN；館員、讀者共用網路，想分開、過濾讀者上網並讓兩條線分工（已完成並現場驗收） |
| [圖書館 Nebula 網路改造（附錄）：設定清單與實作紀錄](docs/network/zyxel-nebula-library-vlan-implementation-record/) | 要照抄同樣架構，或接手維護這個環境 |
| [Nebula 兩層樓 Site-to-Site VPN 規劃：6F USG FLEX 100 × 10F USG FLEX 50HP](docs/network/zyxel-nebula-site-to-site-vpn-6f-10f-plan/) | 兩個地點的防火牆都在 Nebula，想讓兩邊內網互通；H 系列配舊款 USG FLEX 要用 Hub-and-Spoke（規劃，未實作） |

### 4-6 雲端、超融合與硬體

| 文章 | 適合什麼時候看 |
| --- | --- |
| [GCP 網站主機磁碟 100%：清 log 之後，又查出四個問題](docs/gcp/gce-disk-full-log-cleanup-2026-10-05/) | 雲端主機磁碟滿了，不知道從哪裡查 |
| [Nutanix 收到高風險安全警示：要等歲修嗎？](docs/nutanix/nutanix-security-advisory-upgrade-guide/) | 收到廠商安全公告，判斷要多急（規劃參考，未實測） |
| [ML30 Gen11 擴充紀錄](docs/hardware/hpe/ml30-gen11/) | 伺服器加裝光碟機、M.2、設定 iLO |

### 4-7 Blogger 舊文（2011–2025）

| 文章 | 適合什麼時候看 |
| --- | --- |
| [Blogger 舊文總覽](docs/blogger/) | 舊部落格 62 篇全數搬入：Cisco／HPE 網路設備、防火牆、伺服器硬體、Windows、Linux 與 NAS 筆記（2011–2025） |

## 5. 怎麼讀每一篇文章

每篇的結構都一樣：

| 段落 | 內容 |
| --- | --- |
| 一句話 | 這篇在講什麼、結論是什麼 |
| 總覽表 | 適合誰、環境、日期、結論（✅ 已完成／⏳ 待辦） |
| 先認識幾個名詞 | 文中會用到的術語白話解釋 |
| 步驟 | **做什麼 → 怎麼做（指令） → 應該看到什麼** |
| 常見問題 | 遇到某個現象時該怎麼辦 |
| 待辦、延伸閱讀 | 還沒做完的事，以及相關文章 |

**照做前請注意**：

- 文中的主機名稱、IP、VM 編號都是本環境的例子，先換成自己的。
- 每行指令執行前，先弄懂它是「只讀取」、「改設定」還是「停止服務」。
- 「已恢復」不等於每項測試都做完，實測結果和待辦會分開寫。
- IP 使用示範位址（`192.0.2.x`、`198.51.100.x`）或 `<Graylog IP>` 這類代稱；**密碼、token、金鑰一律不放進來**。

原始檔與修改紀錄都在 [GitHub 倉庫](https://github.com/kbwangtw/IT-Knowledge-Base)。
