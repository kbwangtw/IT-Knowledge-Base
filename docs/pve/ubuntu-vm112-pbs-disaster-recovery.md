---
layout: default
title: "Proxmox VE Cluster + PBS：Ubuntu VM112 災難復原實機驗證"
permalink: /docs/pve/ubuntu-vm112-pbs-disaster-recovery/
categories: [PVE, PBS, Ubuntu, DR]
---

# Proxmox VE Cluster + Proxmox Backup Server：Ubuntu VM 災難復原實機驗證

本紀錄以三節點 Proxmox VE Cluster 中的 VM112 為測試對象，規劃正常關閉 Ubuntu、刪除原 VM 與虛擬磁碟，以模擬 VM 完全遺失，再使用 PBS31 的備份還原為 VM112，逐項驗證作業系統、網路、檔案系統、資料與服務，並量測還原耗時及服務恢復時間。

> **紀錄狀態：已整理測試環境、備份資訊與刪除前 baseline；刪除、還原及還原後驗證的實際執行結果與時間待補。本文的操作流程與驗收條件不代表已完成或通過測試。**

## 實測影片

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

[觀看 YouTube 實測影片：我直接把 Proxmox VM 刪掉！PBS 到底救不救得回來？Ubuntu 完整還原實測](https://youtu.be/yWz5n7C9la8)

影片作為實測參考；本文未以影片標題推定還原成功，也未推算未提供的操作時間。可核對的影片時間碼與任務紀錄待補。

## 1. 測試目的與範圍

本次要回答的問題：當 PVE 上的 VM112 及其虛擬磁碟已不存在，但 PBS 備份仍可存取時，能否從指定備份重建 VM112，並恢復 Ubuntu 與所需服務？

驗證範圍包括：

- 使用指定 PBS 備份重建 VMID `112`。
- 比對 VM 硬體設定與 Ubuntu 身分、網路設定。
- 確認根檔案系統掛載、容量與資料可用性。
- 執行指定應用程式的服務及功能驗證。
- 記錄 Restore Time、OS 恢復時間、服務恢復耗時，並與 RTO 目標比較。

此情境為 VM 層級的遺失演練，不涵蓋整個 Cluster 或 PBS 同時損毀。是否跨節點還原待補，不能據此宣告 HA 自動接管或整站災難復原已驗證。

## 2. 實測環境

| 項目 | 紀錄 |
| --- | --- |
| Proxmox VE | **9.2.18**（依提供的實機紀錄） |
| Cluster | 3-node cluster |
| 節點 | `node10` / `node11` / `node12` |
| 測試 VM | `VM112` |
| 作業系統 | Ubuntu 22.04 |
| 原所在節點 | `node11` |
| CPU | 4 vCPU |
| 記憶體 | 約 16 GiB RAM |
| 虛擬磁碟 | 60 GiB |
| 備份來源 | Proxmox Backup Server，PVE 儲存項目 `PBS31` |
| PBS 軟體版本 | 待補 |
| PBS datastore / namespace | 待補 |
| 還原目標節點 | 待補 |
| 還原目標 storage | 待補 |
| Network Bridge / VLAN | 待補 |
| 演練執行日期 | 待補 |

`PBS31` 為本紀錄採用的備份來源名稱，不代表 PBS 軟體版本。

## 3. 備份還原點

| 項目 | 紀錄 |
| --- | --- |
| 備份 VM | `112` |
| 備份時間 | **2026-09-12 21:09:25**（原畫面顯示） |
| 對話記載的 snapshot | `vm/112/2026-09-12T13:09:25Z` |
| 時區核對 | 上述兩個時間相差 UTC+08:00；PVE 顯示時區設定待補 |
| Verify State | **OK** |
| Verify 執行時間 / log | 待補 |
| 備份時的應用程式一致性證據 | 待補 |

PBS Verify 用於檢查備份資料完整性；`Verify State: OK` 不等同於已完成 Ubuntu 開機或應用服務驗證。後者仍須透過實際還原確認。參考：[Proxmox Backup Server — Verification](https://pbs.proxmox.com/docs/maintenance.html#verification)。

備份點早於刪除前 baseline。備份後新增或修改的檔案、套件與設定，不應預期必然出現在還原後系統中；資料比對應以該備份點所涵蓋的內容為準。

## 4. 刪除前 Baseline

| 驗證項目 | 刪除前紀錄 | 還原後紀錄 | 判定 |
| --- | --- | --- | --- |
| Hostname | `ubclient` | 待補 | 待補 |
| OS | Ubuntu 22.04 | 待補 | 待補 |
| 網路介面 | `ens18` | 待補 | 待補 |
| MAC address | `bc:24:11:e7:8e:c0` | 待補 | 待補 |
| IPv4 | `192.168.10.68/24` | 待補 | 待補 |
| 位址取得方式 | DHCP（dynamic） | 待補 | 待補 |
| 根檔案系統裝置 | `/dev/sda2` | 待補 | 待補 |
| 根檔案系統容量 | 約 59 GB | 待補 | 待補 |
| 已使用空間 | 約 29 GB | 待補 | 待補 |
| 使用率 | 52% | 待補 | 待補 |
| 預設路由 / DNS | 待補 | 待補 | 待補 |
| 重要資料 / checksum | 待補 | 待補 | 待補 |
| 應用服務 / 功能測試 | 待補 | 待補 | 待補 |

容量、已用空間與使用率保留原紀錄的近似值，未由四捨五入後的容量重新計算。虛擬磁碟的 60 GiB 與 guest 內根檔案系統的約 59 GB 是不同層級的數值。

DHCP 位址是否維持 `192.168.10.68`，需同時核對 MAC、DHCP 租約或保留設定。取得不同位址時，應記錄原因及服務連線影響，不能只憑 IP 改變判定還原失敗。

## 5. 演練流程

```text
記錄 VM112 baseline
  ↓
確認 PBS31 指定備份與 Verify OK
  ↓
正常關閉 Ubuntu，確認 stopped
  ↓
刪除原 VM112 與虛擬磁碟
  ↓
由 PBS31 Restore 為 VM112
  ↓
啟動 Ubuntu → 驗證網路與 filesystem → 驗證 data 與 service
  ↓
彙整結果與恢復時間
```

### 5.1 記錄 baseline 與確認備份

在 Ubuntu 記錄以下輸出，作為還原後比較依據；此處列出的是採證指令，未代表已取得所有結果。

```bash
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
```

另行記錄重要資料路徑、備份點對應的 checksum 或資料筆數、必要服務名稱與功能測試方式。目前清單與證據待補。

### 5.2 正常關機並模擬 VM 完全遺失

1. 正常關閉 Ubuntu，並在 PVE 確認 VM112 狀態為 `stopped`。
2. 核對刪除對象為原 `node11` 上的 VM112，保留 PBS31 上的指定備份。
3. 刪除原 VM112 與其虛擬磁碟，保存刪除任務紀錄。
4. 確認 Cluster 中原 VM112 設定及原磁碟已移除，記錄模擬遺失時間 `T0`。

正常關機可使用 PVE 的 Shutdown，或於 Ubuntu 執行：

```bash
sudo shutdown -h now
```

刪除是否完成、原磁碟是否移除，以及 `T0` 的證據均待補。PBS 備份不屬於此次刪除範圍。

### 5.3 從 PBS31 還原 VM112

在 PVE 的 PBS31 備份清單選取 VM112 的指定備份，進入 Restore，核對以下設定後執行。實際介面位置以實機為準。

| 設定 | 本次預定值 / 實際紀錄 |
| --- | --- |
| 來源 | PBS31，2026-09-12 21:09:25 備份 |
| VM ID | `112`，須確認已無其他 VM 使用 |
| Target Node | 待補 |
| Target Storage | 待補 |
| 網路 MAC / Unique 選項 | 實際選項待補；核對是否重建 MAC |
| Start after restore | 預定先不勾選，以分開記錄還原與開機時間；實際值待補 |
| Restore 開始 / 完成時間 | 待補 |
| Restore 任務狀態 / log | 待補 |

若選擇 `node10` 或 `node12`，需核對目標節點的儲存空間、Bridge/VLAN、CPU 與裝置相容性，再將結果列為跨節點還原證據。目前不能確認已執行跨節點還原。

### 5.4 開機與還原後驗證

還原任務完成後，核對 VM 的 4 vCPU、約 16 GiB RAM、60 GiB disk 與網路設定，再啟動 Ubuntu。重跑 baseline 指令並保存輸出。

| 層級 | 驗收方式 | 實際結果 |
| --- | --- | --- |
| Restore | 任務成功結束，保存 log 與 VM 設定 | 待補 |
| Ubuntu | 可正常開機與登入，hostname、OS 版本符合預期 | 待補 |
| Network | 核對 ens18、MAC、IP、路由、DNS，從外部用戶端測試所需連線 | 待補 |
| Filesystem | 核對根目錄掛載、裝置、容量與讀寫狀態，檢查相關錯誤 | 待補 |
| Data | 比對備份點已有的重要檔案 checksum、內容或資料庫資料 | 待補 |
| Service | 確認必要服務狀態，並執行實際功能測試 | 待補 |

`systemctl --failed` 可作為系統服務檢查的一部分，但不能取代應用功能測試；`df -h` 的容量接近也不能證明資料完整。服務名稱、測試端點、預期回應及資料樣本均待補。

## 6. Restore Time 與 RTO

為避免將選擇備份、設定還原、啟動作業系統與服務驗證全部混算為 Restore Time，本紀錄分開定義時間點。各系統時鐘與時區需一致；實際時間一律待補。

| 時間點 | 定義 | 實際時間 |
| --- | --- | --- |
| Ts | 服務因正常關機而停止的時間 | 待補 |
| T0 | 原 VM112 刪除完成、確認模擬遺失的時間 | 待補 |
| Tr | Restore 任務實際開始時間 | 待補 |
| T1 | Restore 任務成功完成時間 | 待補 |
| T2 | Ubuntu 正常開機並可登入的時間 | 待補 |
| T3 | 必要資料與服務完成驗收、可提供服務的時間 | 待補 |

| 指標 | 計算 / 定義 | 結果 |
| --- | --- | --- |
| Restore Time | `T1 − Tr`，還原任務本身耗時 | 待補 |
| 遺失至還原完成 | `T1 − T0`，包含還原前操作時間 | 待補 |
| OS 恢復時間 | `T2 − T0` | 待補 |
| 實測服務恢復耗時 | `T3 − T0`，供 RTO 達標比較 | 待補 |
| 演練總停機時間 | `T3 − Ts`，包含關機與刪除準備階段 | 待補 |
| RTO 目標 | 事先約定的可接受恢復時間上限 | 待補 |
| RTO 達標判定 | 實測服務恢復耗時與約定目標比較；起算點須一致 | 待補 |

RTO 是目標值；本紀錄將量測值稱為「實測服務恢復耗時」。若對外報告使用「實際 RTO」一詞，應明確註明是 `T3 − T0` 的實測值。若組織採服務中斷為起算點，應改用 `Ts` 比較其 RTO 目標。

最後備份時間已知，但遺失時間及資料驗證結果尚未提供，因此資料落差與 RPO 達標情況也待補。刪除時間與備份時間之差僅能提供時間窗口，不能單獨證明實際遺失多少資料。

## 7. 證據與待補清單

| 證據 | 目前狀態 |
| --- | --- |
| VM112 原設定與 node11 所在位置 | 已有對話紀錄；原始截圖歸檔待補 |
| PBS31 備份時間與 Verify OK | 已有對話紀錄；原始截圖與 Verify log 歸檔待補 |
| Ubuntu 刪除前 baseline | 已有上述數值；完整輸出歸檔待補 |
| VM 與原磁碟刪除證據 | 待補 |
| Restore 目標節點、storage 與設定 | 待補 |
| Restore 任務完整 log | 待補 |
| Ubuntu 開機、網路與 filesystem 輸出 | 待補 |
| 資料與應用功能驗證 | 待補 |
| 時間點、Restore Time、RTO 目標與達標判定 | 待補 |
| 影片對應時間碼 | 待補 |

## 8. 目前結論

目前已具備 VM112 的環境資料、PBS31 備份時間、`Verify State: OK` 與刪除前 baseline，可作為災難復原驗證紀錄的基礎。

**實際還原是否成功、Ubuntu 與服務是否恢復、資料是否符合備份點，以及 Restore Time / RTO 是否達標，均待補。** 完成上述採證後，再更新本節為最終實測結論。
