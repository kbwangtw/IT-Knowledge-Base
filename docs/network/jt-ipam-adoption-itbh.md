---
layout: default
title: jt-ipam 導入紀錄
last_modified_at: 2026-10-15
---

# jt-ipam 導入紀錄

本文件依 jt-ipam 官方 Adoption Roadmap 整理本環境的實際導入進度。公開文件不記錄密碼、Token Secret、私鑰或完整憑證。

## 導入狀態

| 階段 | 內容 | 狀態 |
| --- | --- | --- |
| Phase 0 | 安裝、安全與基本環境 | 部分完成 |
| Phase 1 | IP / Subnet 規劃 | 基本架構完成 |
| Phase 2 | Discovery / Scan | 已完成並持續運作 |
| Phase 3 | 外部系統整合 | Proxmox VE、LibreNMS 已完成 |
| Phase 4 | 機房、機櫃與設備 | 建檔中，U 位待實機確認 |
| Phase 5 | 維運、自動化 | 待進行 |

## 已完成項目

jt-ipam 部署於（2026-10-15 由 v0.6.19 升級至 v1.0.11） Proxmox VE 的 Debian 13 LXC，並以 HTTPS 提供 Web 服務。已建立 ITBH-Network，納管主要 LAN 與 PVE Cluster Network；現場目前沒有 VLAN，因此不建立虛構 VLAN 資料。

本機 Scan Agent 已啟用 ICMP、ARP L2 與 Reverse PTR 探索，能找到 LAN 上的主機並取得部分 hostname 與 MAC，用來和人工維護資料比對。

Proxmox VE 已使用獨立唯讀 API 帳號與 Token 整合三節點 Cluster。初次同步曾遇到 HTTP 401，經直接驗證 PVE API 並重新保存認證資訊後恢復正常。實測 PVE API 版本為 9.2.20 / release 9.2。PVE 的 VM / CT 資料主要呈現在 Virtualization 視角，不應因一般 Device 清單沒有同步出相同資料就判定整合失敗。

LibreNMS 已完成 API 整合，Device、ARP、鄰居與 online status 等資料可供 jt-ipam 比對。相同 VM / CT 可能同時出現在 Virtualization 與 Device，前者代表虛擬化資產，後者代表監控視角，不應只因名稱相同就刪除。

## 升級到 v1.0.11（2026-10-15）

為使用 Graylog 整合（v1.0 才有）而升級。官方方式為在容器內執行 `bash /opt/jt-ipam/scripts/jt-ipam.sh upgrade`（含 git pull → 備份 → 相依套件 → alembic → 建置前端 → 重啟），完成後以 `jt-ipam.sh doctor` 檢查。0.5.170 以前的版本需執行兩次，本案不需要。

| 步驟 | 內容 |
| --- | --- |
| 檢查 | 容器 4 核／8 GB（官方最低 2 核／4 GB，建置前端峰值約 1.6 GB）；`git status` 無本機修改 |
| 快照 | `pct snapshot <CTID> pre-v1-upgrade` |
| 升級 | 第一次停在 `Building frontend…`：`FATAL: pnpm is required to build the frontend` |
| 原因 | 腳本已把 pnpm 裝到 `/usr/local/bin`，但以 `pct enter` 進入的 shell PATH 只有 `/sbin:/bin:/usr/sbin:/usr/bin`，找不到 |
| 修正 | `export PATH=/usr/local/sbin:/usr/local/bin:$PATH` 後重跑 upgrade（加 `2>&1 \| tee /root/upgrade-<時間>.log` 保留紀錄），從建置前端繼續完成 |
| 驗收 | doctor：No problems；前後端皆 1.0.11、資料庫結構到最新、nginx WebSocket 與 geoip／oui／recog 更新排程已安裝；同步無錯誤、Wazuh Agent 18 筆、網頁正常 |

升級中途失敗時，doctor 會顯示「frontend build is 0.6.x but backend is 1.0.x」與缺少的排程，照 `→` 的提示重跑 upgrade 即可。`perl: warning: Setting locale failed` 是容器沒有產生 en_US.UTF-8 語系，與升級無關。

**以 `pct enter` 在容器內執行安裝或升級腳本前，先補 PATH**，或 `pct enter` 後再 `su -` 載入完整登入環境。

待辦：

- 觀察數天無異狀後刪除快照 `pre-v1-upgrade`。
- jt-ipam 使用的 LibreNMS Token 屬於 admin 且不過期，評估改用權限較小的使用者（見戰情中心（二））。

## 每日備份加密（2026-10-15）

jt-ipam 每天 03:30 備份到 `/var/backups/jt-ipam/`（保留 14 天）。未加密時每份備份同時含資料庫與 `backend.env`（解開資料庫中 PVE、LibreNMS、Wazuh 憑證的金鑰）。於 **管理 → 系統設定 → 每日備份加密** 設定密碼（至少 12 字元，存於密碼管理器、不放在本機）後，每日備份改為單一 `jt-ipam-<日期>.jtbak`（AES-256-GCM），明文目錄自動移除。

~~~bash
systemctl start jt-ipam-backup.service
cat /var/backups/jt-ipam/last-run          # status=ok、encrypted=1
/opt/jt-ipam/backend/.venv/bin/python /opt/jt-ipam/backend/app/services/backup_crypt.py decrypt \
  /var/backups/jt-ipam/jt-ipam-<日期>.jtbak --out /root/restore-test   # 詢問密碼
ls -lh /root/restore-test/*/               # .dump、backend.env、tls.tar.gz、uploads.tar.gz
rm -rf /root/restore-test                  # 解出的是明文，測完刪除
~~~

實測：手動備份 `encrypted=1`、1.3 MB；解密測試成功後，刪除加密前留下的 14 個明文備份目錄（`find /var/backups/jt-ipam -maxdepth 1 -type d -name '2026-*' -exec rm -rf {} +`，只刪日期目錄、不動 `.jtbak`）。

範圍：加密保護的是備份檔被複製到其他地方的情境；取得容器 root 的人仍可直接讀 `/etc/jt-ipam/backend.env`。升級前快照與 PBS 對整個容器的備份仍含 `backend.env`，前者待刪除快照時清除，後者依 PBS 保留規則輪替；PBS 備份本身是否加密另行評估。

## Graylog 整合（2026-10-15）

以「IP → 主機名稱（全域）」DSV 對照表供 Graylog Lookup Table 使用，日誌中的 IP 自動補上主機名稱。設定、憑證信任與 Pipeline 規則見 [把三台 PVE 的日誌集中到 Graylog](https://kbwangtw.github.io/IT-Knowledge-Base/docs/pve/proxmox-graylog-syslog-pipeline-sop/) 第 12 節。權杖 365 天到期（2027-10-15），到期前需重新產生並更新 Graylog 資料轉接器的網址。

## 機房與機櫃

已建立 Location `ITBH Server Room` 與 12U `Rack-01`。預計納管三台 PVE 主機、兩台 Synology NAS、兩台交換器與兩片層板。

目前刻意不先填最終 U 位。非標準 rackmount 設備會放在層板上，必須等機櫃到貨後依實際尺寸、層板位置、散熱與線材空間決定。層板 U 位應視為設備底部支撐位置，而不是設備頂部。

## 下一步

1. 完成 jt-ipam 設定與資料備份／還原驗證。
2. 清理 IP、Device、Virtualization 三個視角的 stale data。
3. 建立固定 IP、保留 IP 與動態 Client 的管理規則。
4. 機櫃到貨後補 Rack U、設備與層板位置。
5. 再評估告警、異常偵測、IP 申請與其他自動化。

## 導入原則

目前已把 Scan Agent 的網路實際狀態、Proxmox VE 的虛擬化資產與 LibreNMS 的監控資料串起來。下一階段優先確保資料可信、來源可追蹤，再擴大自動建立與自動化。

## 參考資料

- [jt-ipam Adoption Roadmap](https://jasoncheng7115.github.io/jt-ipam/adoption.html)
- [jt-ipam GitHub](https://github.com/jasoncheng7115/jt-ipam)
- [jt-ipam Documentation](https://jasoncheng7115.github.io/jt-ipam/)
