---
layout: default
title: 資訊黑手的 Knowledge Base
last_modified_at: 2026-09-18
---

# 資訊黑手的 IT 維運筆記

把實際遇到的問題寫清楚：發生什麼事、怎麼查、怎麼處理，以及最後確認到哪裡。文章以白話說明，必要的指令、圖片和影片保留在操作旁邊。

> 全站文字整理：2026-09-18。「已恢復」不等於每項測試都完成；每篇會分開標示實測結果與待辦。

## 儲存不能用、PVE 出現問號

| 文章 | 適合什麼時候看 |
| --- | --- |
| [Ceph OSD 和 CephFS 金鑰故障，怎麼恢復？](docs/pve/ceph-osd-cephfs-keyring-recovery/) | 容量變 0、OSD down、掛載失敗。服務已恢復，重開持久性待查 |
| [Ceph 換金鑰，為什麼 HEALTH_OK 還不夠？](docs/pve/ceph-20-2-4-cephx-aes256k-migration/) | 想了解遷移漏項、storage 金鑰副本與舊範例更正 |

## 更新主機與日常管理

| 文章 | 適合什麼時候看 |
| --- | --- |
| [ProxCenter 逐台更新：三個卡關點](docs/pve/proxcenter-ceph-rolling-update/) | 來源檢查、SSH 網段和 sudo 問題；完整三台驗收待補 |
| [PBS 更新後，怎麼確認備份還能用？](docs/pve/ProxCenter-PBS-Update-and-DR-Validation-SOP/) | 更新、重開、網路掛載，以及備份與還原的不同判準 |
| [把 PVE／PBS 通知改成繁體中文](docs/pve/proxmox-zh-tw-notification/) | 安裝、移除與模板驗證；PVE 已測，PBS 完整流程待測 |

## 備份做完，真的還原得回來嗎？

| 文章 | 適合什麼時候看 |
| --- | --- |
| [把 ProxCenter 容器還原成一台測試機](docs/pve/proxcenter-pbs-restore-dr-runbook/) | LXC 還原、IP 衝突與基本應用檢查 |
| [Ubuntu VM 還原：6 分 38 秒代表什麼？](docs/pve/ubuntu-vm112-pbs-disaster-recovery/) | 有影片的還原實測；完整資料與應用驗收待補 |
| [DP340 備份 PVE：還原演練怎麼安排？](docs/pve/synology-dp340-pve-cluster-validation/) | 原節點與其他節點測試計畫；結果表待填 |
| [DP340 備份 Google Workspace：逐項驗證](docs/synology/dp340-google-workspace-apm20-sop/) | 授權、排程、Drive 還原；Gmail 問題未結案 |
| [DP340 省下 75% 空間，該怎麼看？](docs/synology/dp340-google-workspace-apm20-dedup-test/) | 分清合併容量、節省比例與實際還原能力 |

## 看日誌、查登入攻擊

| 文章 | 適合什麼時候看 |
| --- | --- |
| [把三台 PVE 的日誌集中到 Graylog](docs/pve/proxmox-graylog-syslog-pipeline-sop/) | 任務失敗告警已設定、Gmail 測試信已收到；完整故障觸發待驗證 |
| [PVE 一直被嘗試登入：確認 Fail2Ban 真的有擋](docs/pve/pve-cluster-fail2ban-hardening/) | 逐層核對日誌、封鎖時間與封包命中 |

## 硬體擴充與安裝

[ML30 Gen11：光碟機、M.2、iLO 與 Windows Server 2025](docs/hardware/hpe/ml30-gen11/)記錄實機組裝和辨識結果，也列出官方相容性與長時間測試的限制。

## 如何使用這些筆記

先看文章開頭的版本、日期和驗證範圍，再核對自己的節點、位址、VMID 與儲存名稱。指令是案例的一部分，執行前要知道它會查詢、改設定，還是停止服務。

文章不公開密碼、私鑰或 token。原始版本與修改紀錄保留在 [GitHub 倉庫](https://github.com/kbwangtw/IT-Knowledge-Base)。
