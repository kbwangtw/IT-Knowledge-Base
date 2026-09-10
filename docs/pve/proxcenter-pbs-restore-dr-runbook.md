---
layout: default
title: "ProxCenter + PBS Restore／DR SOP：LXC 實戰紀錄"
date: 2026-08-28
categories: [PVE, PBS, ProxCenter, DR]
---

<div class="kb-hero">
<h1>ProxCenter + PBS Restore／DR SOP：LXC 實戰紀錄</h1>
<p>透過 ProxCenter 將 PBS 上的正式 LXC 備份，以新 VMID 還原至另一節點，完整記錄一次應用程式層級的 DR 演練與三項實際卡關問題的排除過程。</p>
<div class="kb-badges"><span class="kb-badge">PVE</span><span class="kb-badge">PBS</span><span class="kb-badge">ProxCenter</span><span class="kb-badge">DR</span></div>
</div>

## 摘要

本次在三節點 `ITBH-Cluster`（PVE `9.2.11`）完成一次應用程式層級的災難復原演練：透過 ProxCenter 將 PBS 上的正式 ProxCenter LXC 備份，以新 VMID 還原到 `node12` 的 Ceph storage。演練確認 Debian、網路、Docker、PostgreSQL、Frontend、Orchestrator 與 WeasyPrint 均可恢復，並實際排除 PBS datastore mapping、LXC Override name 及靜態 IP 衝突三項問題。

本文不包含密碼、API Token、Token Secret、Private Key 或完整憑證。

## 本次驗證範圍與結果

| 項目 | 本次實際值／結果 |
|---|---|
| PVE Cluster | `ITBH-Cluster`，3 nodes，PVE `9.2.11` |
| 還原來源 | PBS storage `PBS31`、datastore `Tokyo16` |
| PVE 使用的 PBS server | `172.16.10.31` |
| PBS 原管理／API URL | `https://192.168.10.31:8007` |
| PBS 備份資料網路 | `172.16.10.31` |
| 原 LXC | CT110，ProxCenter |
| 還原目標 | `node12`、新 VMID `210`、storage `VM_Pool` |
| Restore 選項 | Unique MAC ON、Start after restore OFF、Override name OFF |
| 測試 IP | `192.168.10.210/24`，gateway `192.168.10.1` |
| 應用程式入口 | `http://192.168.10.210:3000`，不是 TCP 443 |
| 最終結果 | OS、網路與 4 個 Docker services 全部正常／healthy |

> **重要：** 本文保留內部 RFC 1918 位址，以精確記錄此次演練。它們不是認證資訊；若文件將公開或轉交第三方，仍應依組織政策去識別化。

## 復原路徑

```text
CT110（正式 ProxCenter）
  └─ Backup → PBS31 / Tokyo16（172.16.10.31）
       └─ ProxCenter Restore → node12
            └─ CT210 / VM_Pool / Unique MAC
                 └─ 啟動前改為 192.168.10.210
                      └─ OS、Network、Docker、DB、Web 驗證
```

## 不可省略的安全規則

- 一律 **Restore as new VMID**，不得覆寫正式 CT。
- **Start after restore 必須 OFF**；還原完成後先檢查並更換靜態 IP。
- Unique MAC 必須 ON，但它只解決 MAC 重複，**不會改掉 guest 內的靜態 IP**。
- 啟動 DR 複本前，確認 VMID、MAC、IP、hostname 與掛載資源不會和正式機衝突。
- 還原的資料庫可能保留正式 PVE／PBS connections、API tokens 與排程；DR 驗證只檢查登入頁與基本 UI，不執行 Rolling Update、Backup、Restore、DRS 或其他 production automation。
- 未建立完整網路隔離時，應限制 DR 複本對正式管理端點的連線；測試完成後關機。
- 命令輸出若含 token、password、cookie、private key 或完整憑證，不得貼入 ticket、文件或 Git。

## 1. Restore 前置檢查

### Cluster、storage 與備份

從 PVE 節點確認 Cluster 與目標 storage 健康：

```bash
pveversion
pvecm status
pvesm status
pvesm status --storage PBS31
pvesm list PBS31
```

本次 `node12` 上的 `PBS31` 為 active，且 `pvesm list PBS31` 能列出 CT110 的備份。這證明 **PVE 到 PBS storage 的路徑與備份內容正常**；若 ProxCenter 仍報 mapping 錯誤，應檢查 ProxCenter 的 PBS Connection endpoint，而不是反覆新增 PVE storage。

### 記錄正式機，避免資源衝突

```bash
pct status 110
pct config 110
ip neigh show
pct status 210
```

至少記錄正式 VMID、IP、MAC、bridge、storage、rootfs 大小、hostname、啟動順序與應用程式入口。若 VMID 210 已存在，停止流程並另選新 VMID；不要刪除或覆寫既有 guest。

## 2. 排除 PBS datastore mapping 錯誤

### 現象與診斷

ProxCenter Restore 顯示：

```text
No PVE storage on node node12 maps to PBS datastore Tokyo16
```

當時 PVE 的 `PBS31` 指向 datastore `Tokyo16`、server `172.16.10.31`，但 ProxCenter PBS Connection Base URL 使用管理網路 `https://192.168.10.31:8007`，且 ProxCenter 原本只有 `192.168.10.30/24`。

先證明 PVE storage 本身正常：

```bash
pvesm status --storage PBS31
pvesm list PBS31
```

兩者都成功後，mapping 錯誤的關鍵差異是：PVE storage 以 `172.16.10.31` 識別 PBS，但 ProxCenter 使用 `192.168.10.31`。兩個位址雖指向同一台 PBS，當時版本的 mapping 流程並未將它們視為相同 endpoint。

### 修正

替正式 ProxCenter 增加第二張 NIC：

```text
172.16.10.30/24
default gateway：不設定
```

不要在第二張 NIC 設 default gateway，以免改變既有管理流量的預設路徑。進入 ProxCenter guest 後驗證：

```bash
ip -br addr
ip route
ping -c 4 172.16.10.31
curl -k -I https://172.16.10.31:8007
```

本次 ping 成功，`curl` 也收到 HTTP response；status code 不必是 `200`，此處目的是證明 TLS/API endpoint 可達。接著將 ProxCenter 的 PBS Connection Base URL 改為：

```text
https://172.16.10.31:8007
```

重新執行 Restore 後，`Tokyo16` mapping 錯誤消失。

> Base URL 變更前，先確認現有 credential／certificate 驗證方式仍適用；不要在文件或截圖中揭露 token。

## 3. 建立 Restore Job

本次設定：

```text
Source backup          CT110 / ProxCenter
Target node            node12
New VMID               210
Target Storage         VM_Pool
Unique MAC             ON
Start after restore    OFF
Override name          OFF
```

送出前再次確認 VMID 210 未被使用、`VM_Pool` 容量正常、使用新 MAC、沒有勾選 Start after restore，且已保留不會與正式機衝突的測試 IP。

## 4. LXC Override name 導致 PVE API 400

啟用 LXC `Override name` 時，Restore 在建立 CT 階段失敗：

```text
PVE API 400
/nodes/node12/lxc/
name property is not defined in schema
```

關閉 **Override name**，其他設定不變後重試，本次隨即成功進入並完成 `vzrestore`。這是送往 LXC 建立 API 的欄位／schema 相容性問題，不是 PBS 備份損壞或 `VM_Pool` 寫入失敗。

看到相同訊息時：

1. 保留 job log 與 PVE／ProxCenter 版本資訊。
2. 關閉 Override name 後以新 VMID 重試。
3. 還原成功後再用 PVE 支援的方式處理 hostname；不要混淆 display name 與 LXC hostname。

## 5. 還原完成後，啟動前更換 IP

保持 CT210 停止並檢查：

```bash
pct status 210
pct config 210
```

本次看到：

```text
rootfs: VM_Pool:vm-210-disk-0,size=10G
```

這證明 rootfs 已還原到 `VM_Pool`。Unique MAC 也確實產生了與 CT110 不同的新 MAC；但是 net0 仍保留正式 CT 的靜態 IP `192.168.10.30/24`。

在 **第一次啟動前** 修改為測試 IP：

```bash
pct set 210 -net0 name=eth0,bridge=vmbr0,firewall=1,ip=192.168.10.210/24,gw=192.168.10.1,type=veth
pct config 210
```

確認 IP 為 `192.168.10.210/24`、gateway 為 `192.168.10.1`、bridge 為 `vmbr0`、firewall 為 `1`，且 MAC 與 CT110 不同。

若 guest 網路設定不是由 PVE 的 `ip=` 管理，還必須掛載 rootfs 或在隔離網路內修改 guest OS 設定；不可只看到 Unique MAC 就直接啟動。

## 6. 啟動與 OS／網路驗證

```bash
pct start 210
pct status 210
ping -c 4 192.168.10.210
```

本次結果為 `running`，ping `0% packet loss`。進入 guest：

```bash
pct enter 210
ip -br addr
ip route
systemctl --failed
```

本次確認：

```text
eth0                    192.168.10.210/24
default via             192.168.10.1
systemctl --failed      0 loaded units listed
```

## 7. Docker 與應用程式層驗證

在 CT210 內執行：

```bash
docker ps
docker ps -a
ss -lntp
```

本次四個服務均為 Up／healthy：

```text
proxcenter-orchestrator
proxcenter-frontend
proxcenter-weasyprint
proxcenter-postgres
```

Frontend 實際 port mapping 為 `0.0.0.0:3000 -> container:3000`，所以從其他管理主機測試：

```bash
curl -I http://192.168.10.210:3000
```

瀏覽器入口為 `http://192.168.10.210:3000`。不要因 `https://192.168.10.210` 或 TCP 443 無回應就判定 Restore 失敗；本次應用程式沒有在 host 的 443 監聽。

只驗證登入頁、基本 UI 與必要的 read-only 狀態。不要啟動任何會操作正式 PVE／PBS 的 automation。

## 完整驗證清單

### Restore 前

- [ ] Cluster quorate，三節點狀態正常
- [ ] `PBS31` active，且可列出 `Tokyo16` 上的目標備份
- [ ] ProxCenter 可達 `https://172.16.10.31:8007`
- [ ] ProxCenter PBS Base URL 與 PVE storage endpoint 一致
- [ ] 新 VMID 未使用，Target Storage 容量正常
- [ ] Unique MAC ON、Start after restore OFF
- [ ] 已規劃不衝突的測試 IP 與網路隔離方式

### 啟動前

- [ ] `vzrestore` 完成，rootfs 位於 `VM_Pool`
- [ ] `pct config 210` 顯示新 MAC
- [ ] 靜態 IP 已由正式 `192.168.10.30` 改為測試 `192.168.10.210`
- [ ] bridge、gateway 與 firewall 設定正確
- [ ] 已評估 DR 複本對正式 PVE／PBS API 的存取風險

### 啟動後

- [ ] `pct status 210` 為 `running`
- [ ] ping 測試 IP 為 `0% packet loss`
- [ ] `ip -br addr` 與 default route 正常
- [ ] `systemctl --failed` 為 0
- [ ] 4 個 ProxCenter containers 全部 Up／healthy
- [ ] `ss -lntp`／Docker port mapping 確認 Frontend 為 TCP 3000
- [ ] 登入頁與基本 UI 可開啟，未執行 production automation

## 故障排除表

| 現象 | 本次原因／優先檢查 | 處置與驗證 |
|---|---|---|
| `No PVE storage ... maps to PBS datastore Tokyo16` | ProxCenter 使用 `192.168.10.31`，PVE storage 使用 `172.16.10.31` | 先驗證 `PBS31` active／可列備份；增加 ProxCenter 的 `172.16.10.30/24` NIC，再把 Base URL 改為 `https://172.16.10.31:8007` |
| ProxCenter 無法連到 PBS 備份網路 | 缺少介面、路由或 firewall | `ip -br addr`、`ip route`、ping、`curl -k -I`；第二 NIC 不設 default gateway |
| PVE API 400：`name property is not defined in schema` | LXC Override name 欄位不被 API schema 接受 | 關閉 Override name，以新 VMID 重試；本次 `vzrestore` 成功 |
| 還原後可能搶正式 IP | 備份保留 CT110 的靜態 IP | 保持 Start after restore OFF；第一次啟動前用 `pct set 210 -net0 ... ip=192.168.10.210/24` |
| Unique MAC 已開但仍有網路衝突 | Unique MAC 不會更改 IP | 同時比較 CT110／CT210 的 MAC，並明確更換 guest 靜態 IP |
| `https://測試IP`／443 無回應 | Frontend 實際映射 TCP 3000 | `docker ps`、`ss -lntp`；改測 `http://測試IP:3000` |
| `docker0` 顯示 DOWN | 不足以單獨判定 Docker 故障 | 以 `docker ps`、container health、port mapping 與應用頁面綜合判斷 |
| CT running 但 UI 不通 | container 未 healthy、port 不同或 firewall | `docker ps -a`、`docker logs <container>`、`ss -lntp`，再從外部 `curl -I` |

## 演練完成與收尾

記錄 Backup snapshot 時間、Restore job 結果、目標 VMID、storage／IP／MAC 差異、OS／Docker health 與實際 RTO；先移除所有認證資訊。

完成 UI 驗證後：

```bash
pct shutdown 210 --timeout 60
pct status 210
```

確認 CT210 已 stopped。是否保留或刪除 DR guest 應依證據保存與變更流程另行批准；本 Runbook 不包含自動刪除步驟。

## 本次演練結論

```text
PBS backup 可列出                       ✅
ProxCenter ↔ PBS data endpoint          ✅
PBS datastore ↔ PVE storage mapping     ✅
LXC vzrestore 至 VM_Pool                ✅
新 VMID／新 MAC                         ✅
啟動前改為隔離測試 IP                  ✅
Debian boot／route／systemd             ✅
PostgreSQL／Frontend／Orchestrator       ✅
WeasyPrint                              ✅
Frontend TCP 3000                       ✅
```

這次 Restore 不只證明備份檔可以讀取，也驗證到 ProxCenter 的資料庫與應用服務能實際啟動。往後演練仍須逐次確認 endpoint mapping、靜態 IP、API connection 與 automation 隔離，不能因本次成功而省略前置檢查。
