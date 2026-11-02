# IT Knowledge Base（資訊黑手的 IT 維運筆記）

> **一句話**：這是一本「實際維運紀錄」的筆記本：遇到什麼問題、怎麼查、怎麼處理、驗證到哪裡，都照實寫下來，方便日後自己查、也讓剛入行的人看得懂。

**👉 建議直接閱讀網站版：[kbwangtw.github.io/IT-Knowledge-Base](https://kbwangtw.github.io/IT-Knowledge-Base/)**（排版比較好讀，下面的連結是原始 Markdown 檔）

## 這裡記錄的是什麼環境

| 類別 | 內容 |
| --- | --- |
| 虛擬化平台 | Proxmox VE（PVE）三台節點組成的叢集，共用 Ceph 儲存 |
| 備份 | Proxmox Backup Server（PBS）、Synology NAS、Synology DP340 |
| 監控與資安 | Graylog（集中日誌）、Wazuh（資安監控）、LibreNMS（設備監控）、Grafana（戰情中心） |
| 網路 | WireGuard VPN、jt-ipam（IP 位址管理）、DNS |
| 其他 | GCP 雲端主機、Nutanix、HPE 伺服器硬體 |

## 怎麼讀這些文章

1. **先看開頭**：每篇開頭都有日期、版本和「驗證到哪裡」。「已恢復」不等於每項測試都做完，實測結果和待辦會分開寫。
2. **指令不要直接照抄**：文章裡的主機名稱、IP、VM 編號都是本環境的例子。執行前先換成自己的環境，並弄懂這行指令是「查詢」、「改設定」還是「停止服務」。
3. **IP 與機密都已遮蔽**：文件使用示範位址（`192.0.2.x`、`198.51.100.x`）或 `<Graylog IP>` 這類代稱；密碼、token、金鑰一律不放進來。

## 文章目錄

### 日誌、監控與資安

- [把 PVE、PBS 與 NAS 的日誌集中到 Graylog（一）](docs/pve/proxmox-graylog-syslog-pipeline-sop.md)：收集、分類、主機名稱查表、Gmail 寄信設定
- [Graylog 告警與監控（二）](docs/pve/graylog-alerts-monitoring.md)：14 個告警、PVE 監控腳本、監控 Graylog 本身、NAS 複寫與備份監控（2026-10-19 從上篇拆出）
- [Graylog 告警與監控（三）：中文告警信與摘要](docs/pve/graylog-alert-templates.md)：13 個通知的中文範本、主旨、每個告警的摘要寫法（2026-10-19 從（二）拆出）
- [PVE 告警實測：三項核心告警完整驗證成功](docs/pve/graylog-pve-alert-validation-2026-09-18.md)
- [在 PVE Cluster 用 LXC 架設 Wazuh（一）：安裝與接上 Agent](docs/pve/wazuh-lxc-ubuntu2204-sop.md)
- [Wazuh 維運（二）：資料保留、告警調校、弱點修補與整合](docs/pve/wazuh-lxc-ubuntu2204-operations.md)：告警調校、弱點修補、LibreNMS 動態群組、jt-ipam／Grafana 整合
- [用 Grafana 建立戰情中心（一）：接上 Wazuh](docs/pve/grafana-war-room-wazuh.md)
- [用 Grafana 建立戰情中心（二）：接上 LibreNMS](docs/pve/grafana-war-room-librenms.md)
- [用 Grafana 建立戰情中心（三）：接上 Prometheus（Ceph 與 PVE）](docs/pve/grafana-war-room-prometheus.md)
- [LibreNMS 溫度告警誤報：LXC 重複感測器與門檻整理](docs/pve/librenms-temperature-sensor-cleanup.md)：停用 LXC 的 sensors 模組、依硬體規格重設節點門檻
- [PVE 一直被嘗試登入：怎麼確認 Fail2Ban 真的有擋？](docs/pve/pve-cluster-fail2ban-hardening.md)
- [不再把 PVE 8006 開到網際網路：改用 WireGuard 連回家](docs/pve/wireguard-remote-access-replace-8006.md)：VPN 異常會寄 Gmail
- [PHP2Shell（CVE-2026-109618、109619）：檢查環境有沒有中、怎麼修補](docs/pve/php2shell-check.md)
- [Node2Shell（CVE-2026-111497）與 LiteLLM 供應鏈攻擊：檢查環境有沒有中、怎麼修補](docs/pve/node2shell-litellm-check.md)
- [用 Claude Code 取代 Hermes：去識別化閘道與手機遙控](docs/pve/claude-code-redact-gateway.md)：`rx` 閘道在 [tools/redact-gateway](tools/redact-gateway/)

### PVE 叢集與 Ceph 儲存

- [PVE 重開後 Ceph 又故障：修正 BlueStore 裡的 OSD 金鑰](docs/pve/ceph-bluestore-osd-key-recovery-2026-09-22.md)
- [PVE 出現問號、儲存變成 0：這次怎麼救回來？](docs/pve/ceph-osd-cephfs-keyring-recovery.md)
- [Ceph 換金鑰：為什麼 HEALTH_OK 還不夠？](docs/pve/ceph-20-2-4-cephx-aes256k-migration.md)
- [Ceph 出現 BlueStore 慢操作告警：硬碟壞了嗎？備份排程怎麼排？](docs/pve/ceph-bluestore-slow-op-backup-schedule.md)：硬碟正常、備份錯開、slow ops 歷史、10/31 復發（osd.1）與三顆 OSD 碟的 SMART、碟溫、型號規格、寫入量比較
- [PVE HA 放置策略：PVE HA rules 和 ProxCenter 怎麼分工？](docs/pve/pve-ha-placement-policy.md)
- [PVE 更新重開後 HA 服務卡在 error：原因與救回步驟](docs/pve/pve-ha-service-error-after-reboot.md)
- [整個 PVE 叢集安全關機與開機：一鍵腳本（含 HA、Ceph）](docs/pve/pve-cluster-full-shutdown.md)：腳本在 `tools/pve-cluster-power/`
- [從 VMware ESXi 滾動式轉換到 PVE：新機先上、舊機回收（規劃 SOP）](docs/pve/esxi-to-pve-rolling-migration-sop.md)：Unity 380 走 FC 的 shared LVM、QDevice 隨節點數調整、舊 DL360 回收成節點（規劃，未實測）
- [ProxCenter 逐台更新 PVE：三個卡關點怎麼排除？](docs/pve/proxcenter-ceph-rolling-update.md)
- [ProxCenter 企業版更新與擴容：1.4.11 → 1.4.12](docs/pve/proxcenter-enterprise-update.md)：重跑安裝腳本帶 token、`up -d` 的陷阱、CT110 擴容、Node 仍是 26.12.0
- [PVE 9 登入一直跳「No valid subscription」：網路上的 sed 為什麼沒效？](docs/pve/pve9-subscription-nag-removal.md)
- [一次檢查並統一所有 LXC 的時區](docs/pve/pve-lxc-timezone.md)：從 node10 查全部容器、先盤點排程、改成 Asia/Taipei、LibreNMS 的 PHP 與 MariaDB
- [LXC 自動更新後，怎麼檢查「待重啟的服務」：逐一重啟 dbus 的坑與整個容器重開](docs/pve/lxc-needrestart-service-restart.md)：唯讀盤點、應用服務單獨重啟、dbus／logind 整個容器重開、CT112／CT114 重開前後對照
- [把 PVE／PBS 通知改成繁體中文](docs/pve/proxmox-zh-tw-notification.md)：程式在 [`tools/proxmox-zh-tw-notification/`](tools/proxmox-zh-tw-notification/)（2026-10-16 以新手角度改寫）

### 備份與還原

- [PBS 更新後，怎麼確認備份還能用？](docs/pve/ProxCenter-PBS-Update-and-DR-Validation-SOP.md)
- [從 PBS 還原 ProxCenter：先複製一台，再確認能用](docs/pve/proxcenter-pbs-restore-dr-runbook.md)
- [Ubuntu VM 從 PBS 還原：6 分 38 秒代表什麼？](docs/pve/ubuntu-vm112-pbs-disaster-recovery.md)
- [用 DP340 備份 PVE：先把還原測試安排好](docs/pve/synology-dp340-pve-cluster-validation.md)
- [用 DP340 備份 Google Workspace：先授權，再逐項驗證](docs/synology/dp340-google-workspace-apm20-sop.md)
- [DP340 顯示省下 75% 空間，該怎麼看？](docs/synology/dp340-google-workspace-apm20-dedup-test.md)

### 網路與 IP 管理

- [jt-ipam 導入紀錄：從 IP 掃描到 PVE、LibreNMS 與機櫃管理](docs/network/jt-ipam-adoption-itbh.md)
- [內網橫向感染評估：先看清楚網路長怎樣，再決定要不要裝防火牆](docs/network/internal-network-lateral-movement-assessment.md)：兩台無網管交換器、叢集網已物理隔離、Ceph public_network 在服務網；結論不啟用完整 PVE Firewall，`pveproxy` 白名單盤點中（暫停）
- [有用中華電信資安艦隊：DNS 為什麼不能設 8.8.8.8？](docs/network/cht-security-fleet-dns-filtering.md)：須指定 210.69.1.1；過濾機制未向中華電信確認
- [圖書館 Nebula 網路改造：VLAN 隔離讀者、CIP 過濾、兩條 FTTB 分流](docs/network/zyxel-nebula-library-vlan-dual-wan-plan.md)：已完成並現場驗收
- [圖書館 Nebula 網路改造（附錄）：設定清單與實作紀錄](docs/network/zyxel-nebula-library-vlan-implementation-record.md)：實際設定、逐日紀錄、現場確認清單範本
- [Nebula 兩層樓 Site-to-Site VPN：6F USG FLEX 100 × 10F USG FLEX 50HP](docs/network/zyxel-nebula-site-to-site-vpn-6f-10f-plan.md)：兩邊皆 PPPoE 固定 IP；VPN 規劃工具建立中心和分支（6F Hub），2026-10-29 結案（兩層樓互 ping 成功）

### 雲端、超融合與硬體

- [GCP 網站主機磁碟 100%：清 log 之後，又查出四個問題](docs/gcp/gce-disk-full-log-cleanup-2026-10-05.md)
- [Nutanix 收到高風險安全警示：要等歲修嗎？VM 要關機嗎？](docs/nutanix/nutanix-security-advisory-upgrade-guide.md)：規劃參考，未實測
- [ML30 Gen11 擴充紀錄：哪些零件裝好了？哪些還要測？](docs/hardware/hpe/ml30-gen11/index.md)

## 倉庫裡有什麼

```text
IT-Knowledge-Base/
├── index.md        # 網站首頁
├── docs/           # 所有文章（依主題分資料夾：pve、network、synology、gcp…）
├── tools/          # 文章用到的程式（不會出現在網站上）
│   └── proxmox-zh-tw-notification/   # PVE／PBS 中文通知範本與安裝腳本
├── assets/         # 網站樣式、可下載的附件
└── _config.yml     # 網站設定（GitHub Pages + Jekyll）
```

網站是用 **GitHub Pages** 自動產生的：`docs/` 裡的 Markdown 檔一合併進 `main` 分支，GitHub 就會把它轉成網頁，大約 1 分鐘後上線。

## 寫作與維護原則

| 原則 | 說明 |
| --- | --- |
| 照實記錄 | 「做了什麼」「看到什麼結果」「哪些還沒驗證」分開寫；推測的地方要標明 |
| 不放機密 | 不放真實 IP、網域、密碼、token、私鑰、完整憑證；改用示範位址或代稱 |
| SOP 只留可照做的步驟 | 失敗或做到一半的清理步驟不寫進 SOP；踩過的雷整理成「常見問題」 |
| 新手看得懂 | 依固定版型撰寫（見 [`CLAUDE.md`](CLAUDE.md)）：一句話 → 總覽表 → 名詞 → 步驟（做什麼／怎麼做／應該看到什麼）→ 常見問題 → 待辦（結案文章可省略）→ 延伸閱讀 |
| 太長就拆篇 | 超過約 1,500 行或讀者目的不同（例如安裝 vs. 維運）時拆成上下篇，互相連結 |
| 修改走 PR | 在分支上修改 → 開 Pull Request → 合併到 `main` → 網站自動更新；所有修改都能從 Git 歷史追查 |

## 附件

- Graylog 文章的可下載 Markdown：上篇 [`assets/downloads/Proxmox_Graylog_SOP_public.md`](assets/downloads/Proxmox_Graylog_SOP_public.md)、下篇 [`assets/downloads/Graylog_Alerts_Monitoring_public.md`](assets/downloads/Graylog_Alerts_Monitoring_public.md)、第三篇 [`assets/downloads/Graylog_Alert_Templates_public.md`](assets/downloads/Graylog_Alert_Templates_public.md)（與文章同步）；同目錄的 Word 檔是早期版本，沒有同步。
