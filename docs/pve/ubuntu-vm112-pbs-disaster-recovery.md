---
layout: default
title: "Ubuntu VM 從 PBS 還原：6 分 38 秒代表什麼？"
permalink: /docs/pve/ubuntu-vm112-pbs-disaster-recovery/
categories: [PVE, PBS, Ubuntu, DR]
last_modified_at: 2026-09-18
---

# Ubuntu VM 從 PBS 還原：6 分 38 秒代表什麼？

影片已確認 VM112 還原任務顯示 TASK OK，之後在 node11 進入 Ubuntu 桌面，主機名稱、MAC 和 IP 與原紀錄一致，systemctl 沒有 failed unit。

其中 **397.97 秒（約 6 分 38 秒）只代表 image restore 階段**，不是從事故發生到所有應用程式恢復的完整時間。

## 實測影片與證據位置

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

| 影片位置 | 看到了什麼 | 能支持的結論 |
| --- | --- | --- |
| [07:56](https://youtu.be/yWz5n7C9la8?t=476) | TASK OK；397.97s、154.38 MB/s | 還原任務完成，且有磁碟映像還原階段數值 |
| [08:56](https://youtu.be/yWz5n7C9la8?t=536) | node11 上的 Ubuntu 桌面 | 系統可開機 |
| [09:01](https://youtu.be/yWz5n7C9la8?t=541) | hostname、ens18、MAC、IP | 基本主機與網卡資訊一致 |
| [09:06](https://youtu.be/yWz5n7C9la8?t=546) | systemctl --failed 沒有失敗單元 | 當下沒有列出的 systemd failed unit |

影片時間碼是方便找畫面的位置，不是事故實際發生時間。本文沒有把影片長度拿來計算 RTO。

## 本次環境與還原點

| 項目 | 紀錄 |
| --- | --- |
| PVE | 9.2.18 |
| VM | 112，Ubuntu 22.04 |
| 節點 | node11 |
| 資源 | 4 vCPU、約 16 GiB RAM、60 GiB 虛擬磁碟 |
| 備份儲存名稱 | PBS31；這個名稱不是 PBS 版本 |
| 畫面備份時間 | 2026-09-12 21:09:25 |
| Snapshot ID | vm/112/2026-09-12T13:09:25Z |
| 備份驗證 | Verify OK；完整 Verify log 與時間待歸檔 |

兩種備份時間的顯示相差 8 小時，仍應以來源畫面的時區設定核對。Verify OK 與實際開機還原是兩種證據，不能互相取代。

## 怎麼設計這次演練？

原演練設計是：記錄 VM 狀態、確認備份、正常關機、模擬 VM 與磁碟遺失，再從 PBS 還原。**原 VM 和磁碟確實刪除的完整證據尚待補齊**，因此不把設計步驟全部寫成已完成事實。

若只是日常測試備份，應先評估還原到獨立 VMID 與隔離網路，無須把刪除正式 VM 當成每次驗證的必要步驟。若要演練刪除，必須另有核准範圍與可用備份。

本次還原後確認在 node11；目標 storage、Unique MAC 選項、是否自動開機等完整工作設定仍待歸檔。沒有跨節點還原證據，也沒有模擬整個機房或叢集失效。

## 還原前後，哪些有對上？

| 項目 | 原始紀錄 | 還原後結果 |
| --- | --- | --- |
| 主機名稱 | ubclient | 一致 |
| 網卡 | ens18 | UP |
| MAC | bc:24:11:e7:8e:c0 | 一致 |
| IP | 192.168.10.68/24，DHCP | 一致，dynamic |
| OS 版本 | Ubuntu 22.04 | 已進桌面；版本指令輸出待補 |
| 根檔案系統 | /dev/sda2，約 59 GB | 詳細比對待補 |
| 使用量 | 約 29 GB／52% | 詳細比對待補 |
| 路由、DNS、外部連線 | 完整基線待補 | 待補 |
| 重要資料、應用功能 | 測試清單待補 | 待補 |

容量與使用率保留原本近似值，不用四捨五入後的容量重新計算。60 GiB 虛擬磁碟也不等於 guest 內根檔案系統顯示的容量。

DHCP 能否取得相同 IP，還受 MAC、租約與保留設定影響；不同 IP 不一定代表還原失敗，要看連線與服務是否符合預期。

## 下次採證，可以前後各跑一次

以下只是採證清單，不表示本次所有輸出都已取得：

~~~bash
date --iso-8601=seconds
hostname
cat /etc/os-release
ip addr show ens18
ip route
resolvectl status
lsblk -f
findmnt /
df -h /
systemctl --failed
~~~

資料驗證另選備份點已存在的檔案、資料庫紀錄或 checksum；應用程式則定義可重複的功能測試。容量相近和服務未失敗，都不能單獨證明資料完整。

## 如何量「多久恢復」？

RTO 是事先約定「最多可以中斷多久」的目標，需用一致起算點的量測值來比較。

| 時間點 | 要記錄的事件 |
| --- | --- |
| Ts | 正式服務停止 |
| T0 | 模擬遺失確認完成 |
| Tr | 還原任務開始 |
| T1 | 還原任務完成 |
| T2 | Ubuntu 開機並可登入 |
| T3 | 必要資料與應用驗收完成 |

還原任務耗時是 T1−Tr；本次演練若以模擬遺失起算，服務恢復耗時是 T3−T0；完整停機時間則是 T3−Ts。若組織以服務中斷起算 RTO，就應用 Ts，不能任選較短的數字。

本次只有 image restore 的 397.97 秒，其他時間點與 RTO 目標未齊，因此不能宣布 RTO 達標。備份時間已知，但事故時間與資料比對未齊，也不能宣布 RPO 達標。

## 目前可以結案到哪裡？

「VM 還原、開機與基本網卡檢查通過」有影片支持。完整應用災難復原仍缺資料比對、功能測試、還原設定與工作完整日誌，以及各時間點。下一次演練優先補這些，才有辦法回答「真的能用嗎、會少多少資料、要多久」。
