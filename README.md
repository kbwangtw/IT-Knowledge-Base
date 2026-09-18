# IT Knowledge Base

用白話記錄 IT 維運：問題是什麼、如何排查、做了哪些處理、驗證到哪裡。

[閱讀 GitHub Pages 網站](https://kbwangtw.github.io/IT-Knowledge-Base/)

## 全部文章

- [ML30 Gen11 擴充紀錄：哪些零件裝好了？哪些還要測？](docs/hardware/hpe/ml30-gen11/index.md)
- [PBS 更新後，怎麼確認備份還能用？](docs/pve/ProxCenter-PBS-Update-and-DR-Validation-SOP.md)
- [Ceph 換金鑰：為什麼 HEALTH_OK 還不夠？](docs/pve/ceph-20-2-4-cephx-aes256k-migration.md)
- [PVE 出現問號、儲存變成 0：這次怎麼救回來？](docs/pve/ceph-osd-cephfs-keyring-recovery.md)
- [ProxCenter 逐台更新 PVE：三個卡關點怎麼排除？](docs/pve/proxcenter-ceph-rolling-update.md)
- [從 PBS 還原 ProxCenter：先複製一台，再確認能用](docs/pve/proxcenter-pbs-restore-dr-runbook.md)
- [把三台 PVE 的日誌集中到 Graylog](docs/pve/proxmox-graylog-syslog-pipeline-sop.md)
- [把 PVE／PBS 通知改成繁體中文](docs/pve/proxmox-zh-tw-notification.md)
- [PVE 一直被嘗試登入：怎麼確認 Fail2Ban 真的有擋？](docs/pve/pve-cluster-fail2ban-hardening.md)
- [用 DP340 備份 PVE：先把還原測試安排好](docs/pve/synology-dp340-pve-cluster-validation.md)
- [Ubuntu VM 從 PBS 還原：6 分 38 秒代表什麼？](docs/pve/ubuntu-vm112-pbs-disaster-recovery.md)
- [DP340 顯示省下 75% 空間，該怎麼看？](docs/synology/dp340-google-workspace-apm20-dedup-test.md)
- [用 DP340 備份 Google Workspace：先授權，再逐項驗證](docs/synology/dp340-google-workspace-apm20-sop.md)

## 閱讀與維護方式

全站 13 篇文章於 2026-09-18 完成白話整理，保留既有網址、圖片與影片。每篇的原始日期、環境版本、實測結果與待驗證項目分開呈現；演練計畫不等於完成報告。

文章中的主機名稱、位址和指令都是案例內容，操作前需核對自己的環境。金鑰、密碼、token、私鑰與完整憑證不得放入本倉庫。

Graylog 的可下載 Markdown 與文章同步；既有 Word 附件保留為歷史版本。網站使用 Markdown 維護，修改紀錄可從 Git 歷史追查。
