---
layout: default
title: "Ubuntu VM 從 PBS 還原：6 分 38 秒代表什麼？"
permalink: /docs/pve/ubuntu-vm112-pbs-disaster-recovery/
categories: [PVE, PBS, Ubuntu, DR]
last_modified_at: 2026-10-17
---

# Ubuntu VM 從 PBS 還原：6 分 38 秒代表什麼？

> **一句話**：把一台 Ubuntu 虛擬機從 PBS 備份還原回來，還原任務花了約 6 分 38 秒、開機後基本資訊都對得上；但這個數字**只是「磁碟還原」那一段**，不是「從出事到服務恢復」的完整時間。

| 項目 | 內容 |
| --- | --- |
| 適合誰看 | 第一次做備份還原演練、想知道「還原成功」要怎麼判斷的人 |
| 環境 | PVE 9.2.18；VM 112（Ubuntu 22.04）；還原到 node11 |
| 證據 | 有完整操作影片 |
| 結論 | ✅ 還原、開機、基本網卡檢查通過；⏳ 資料比對、應用功能測試、完整時間點尚未補齊，所以**還不能宣布 RTO／RPO 達標** |

> 文中 IP 都是文件示範位址（管理網 192.0.2.0/24），照做前請換成自己的位址。

## 1. 先認識幾個名詞

| 名詞 | 白話解釋 |
| --- | --- |
| **PBS** | Proxmox Backup Server，存放 PVE 備份的伺服器 |
| **還原（Restore）** | 把備份的磁碟映像寫回 PVE，變成一台可以開機的 VM |
| **Verify** | PBS 定期檢查備份資料有沒有損壞；Verify OK ≠ 實際還原成功 |
| **RTO** | Recovery Time Objective：事先約定「最多可以中斷多久」 |
| **RPO** | Recovery Point Objective：事先約定「最多可以遺失多久的資料」 |
| **Snapshot ID** | 某一次備份的識別碼 |
| **failed unit** | Linux systemd 裡啟動失敗的服務 |

## 2. 實測影片與關鍵畫面

<div style="position: relative; width: 100%; height: 0; padding-bottom: 56.25%; margin: 1.5rem 0;">
  <iframe
    src="https://www.youtube.com/embed/yWz5n7C9la8"
    title="Proxmox VE + PBS：Ubuntu VM112 完整還原實測"
    style="position: absolute; top: 0; left: 0; width: 100%; height: 100%; border: 0;"
    loading="lazy"
    allow="accelerometer; autoplay; clipboard-write; encrypted-media; gyroscope; picture-in-picture; web-share"
    referrerpolicy="strict-origin-when-cross-origin"
    allowfullscreen>
  </iframe>
</div>

| 影片位置 | 看到什麼 | 能證明什麼 |
| --- | --- | --- |
| [07:56](https://youtu.be/yWz5n7C9la8?t=476) | TASK OK；397.97s、154.38 MB/s | 還原任務完成，有磁碟還原階段的數值 |
| [08:56](https://youtu.be/yWz5n7C9la8?t=536) | node11 上的 Ubuntu 桌面 | 系統可以開機 |
| [09:01](https://youtu.be/yWz5n7C9la8?t=541) | hostname、ens18、MAC、IP | 主機與網卡基本資訊一致 |
| [09:06](https://youtu.be/yWz5n7C9la8?t=546) | `systemctl --failed` 沒有失敗服務 | 當下沒有啟動失敗的 systemd 服務 |

影片時間碼只是方便找畫面，**不是**事故實際發生的時間；本文沒有用影片長度去算 RTO。

## 3. 環境與還原點

| 項目 | 紀錄 |
| --- | --- |
| PVE | 9.2.18 |
| VM | 112，Ubuntu 22.04 |
| 節點 | node11 |
| 資源 | 4 vCPU、約 16 GiB RAM、60 GiB 虛擬磁碟 |
| 備份儲存名稱 | PBS31（這是名稱，不是 PBS 版本） |
| 畫面上的備份時間 | 2026-09-12 21:09:25 |
| Snapshot ID | vm/112/2026-09-12T13:09:25Z |
| 備份驗證 | Verify OK；完整 Verify log 與時間待歸檔 |

兩種備份時間的顯示相差 8 小時（一個是台灣時間、一個是 UTC），仍要以來源畫面的時區設定核對。

## 4. 這次演練怎麼設計

原本的設計：記錄 VM 狀態 → 確認備份 → 正常關機 → 模擬 VM 與磁碟遺失 → 從 PBS 還原。

- **原 VM 和磁碟確實被刪除的完整證據還沒補齊**，所以不把設計步驟全部寫成已完成。
- 只是日常測試備份的話，建議**還原到另一個 VMID、放在隔離網路**，不需要每次都刪掉正式 VM。真的要演練刪除，必須另有核准與可用的備份。
- 還原後確認在 node11；目標 storage、Unique MAC 選項、是否自動開機等設定尚待歸檔。沒有跨節點還原，也沒有模擬整個機房或叢集失效。

## 5. 還原前後比對

| 項目 | 原始紀錄 | 還原後 |
| --- | --- | --- |
| 主機名稱 | ubclient | ✅ 一致 |
| 網卡 | ens18 | ✅ UP |
| MAC | bc:24:11:e7:8e:c0 | ✅ 一致 |
| IP | 192.0.2.68/24，DHCP | ✅ 一致，dynamic |
| OS 版本 | Ubuntu 22.04 | 已進桌面；版本指令輸出待補 |
| 根檔案系統 | /dev/sda2，約 59 GB | ⏳ 詳細比對待補 |
| 使用量 | 約 29 GB／52% | ⏳ 詳細比對待補 |
| 路由、DNS、外部連線 | 完整基線待補 | ⏳ |
| 重要資料、應用功能 | 測試清單待補 | ⏳ |

- 容量保留原本的近似值。60 GiB 虛擬磁碟**不等於** VM 裡根檔案系統顯示的容量。
- DHCP 能不能拿到相同 IP，還受 MAC、租約和保留設定影響；IP 不同**不一定**代表還原失敗，要看連線和服務是否正常。

## 6. 下次採證：還原前後各跑一次

（以下是建議清單，不代表本次都已取得輸出。）

```bash
date --iso-8601=seconds      # 記錄時間點
hostname
cat /etc/os-release          # 作業系統版本
ip addr show ens18           # 網卡、IP、MAC
ip route                     # 路由
resolvectl status            # DNS
lsblk -f                     # 磁碟與檔案系統
findmnt /
df -h /                      # 容量與使用率
systemctl --failed           # 有沒有啟動失敗的服務
```

**資料驗證**：挑幾個備份時已存在的檔案、資料庫紀錄或 checksum 比對；**應用程式**則定義可以重複執行的功能測試。容量相近、服務沒失敗，都不能單獨證明資料完整。

## 7. 「多久恢復」要怎麼量

| 時間點 | 要記錄的事件 |
| --- | --- |
| Ts | 正式服務停止 |
| T0 | 確認「模擬遺失」完成 |
| Tr | 還原任務開始 |
| T1 | 還原任務完成 |
| T2 | Ubuntu 開機並可登入 |
| T3 | 必要的資料與應用驗收完成 |

| 想知道 | 算法 |
| --- | --- |
| 還原任務花多久 | T1 − Tr（本次就是 397.97 秒） |
| 從模擬遺失到服務恢復 | T3 − T0 |
| 完整停機時間 | T3 − Ts |

組織若以「服務中斷」起算 RTO，就要用 Ts，不能挑比較短的數字。

**本次只有 397.97 秒這一段**，其他時間點與 RTO 目標都沒齊，所以**不能宣布 RTO 達標**；備份時間已知，但事故時間與資料比對沒齊，**也不能宣布 RPO 達標**。

## 8. 目前結論與待辦

✅ 「VM 還原、開機、基本網卡檢查通過」有影片支持。

| 待辦 | 為什麼 |
| --- | --- |
| 資料比對 | 確認資料真的完整 |
| 應用功能測試 | 確認服務真的能用 |
| 還原設定與完整工作日誌 | 讓演練可以重現 |
| 記錄各時間點 | 才能回答「要多久」 |

補齊這些，才能回答「**真的能用嗎、會少多少資料、要多久**」。

## 9. 延伸閱讀

- [PBS 更新後，怎麼確認備份還能用？](https://kbwangtw.github.io/IT-Knowledge-Base/docs/pve/ProxCenter-PBS-Update-and-DR-Validation-SOP/)
- [從 PBS 還原 ProxCenter：先複製一台，再確認能用](https://kbwangtw.github.io/IT-Knowledge-Base/docs/pve/proxcenter-pbs-restore-dr-runbook/)
- [Proxmox VE Backup and Restore（官方）](https://pve.proxmox.com/pve-docs/chapter-vzdump.html)
