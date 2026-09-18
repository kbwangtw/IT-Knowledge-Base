---
layout: default
title: "從 PBS 還原 ProxCenter：先複製一台，再確認能用"
date: 2026-08-28
categories: [PVE, PBS, ProxCenter, DR]
last_modified_at: 2026-09-18
---

# 從 PBS 還原 ProxCenter：先複製一台，再確認能用

本次把正式 ProxCenter 容器 CT110 的 PBS 備份，還原成 node12 上的新容器 CT210。最後確認系統能開機、四個 Docker 容器 healthy，網頁可從 3000 埠連入。

這是一次**系統與基本服務恢復**的驗證，還沒有證明所有業務功能、排程或資料都完全正確。

> 實測日期：2026-08-28；PVE 9.2.11。以下 VMID、IP 與儲存名稱僅供本案例對照，不能直接套用到另一套環境。

## 這次資料走哪條路？

~~~text
正式 CT110
  → PBS31 的 Tokyo16 備份
  → node12 上的新 CT210
  → 磁碟放在 VM_Pool
  → 換成測試 IP 後開機
  → 檢查系統、Docker 與網頁
~~~

使用新 VMID 與新 MAC，是為了避免覆蓋或混淆正式機。但副本仍可能帶著相同 IP、API token 和排程，因此不能還原完就直接接回正式網路。

## 1. 先確認來源和目標

在 PVE 檢查叢集、PBS 和容器設定：

~~~bash
pvecm status
pvesm status
pvesm status --storage PBS31
pvesm list PBS31
pct status 110
pct config 110
pct status 210
~~~

重點是確認：選對 CT110 的快照、node12 可使用 PBS31、VM_Pool 空間足夠，而且 210 沒有被其他工作佔用。備份清單列得出來，只能證明可存取，不能替代實際還原。

## 2. 找不到 datastore 對應時，先核對連線地址

本次錯誤：

~~~text
No PVE storage on node node12 maps to PBS datastore Tokyo16
~~~

PVE 使用 PBS 的資料網地址 172.16.10.31，ProxCenter 原本使用管理網地址。替 ProxCenter 增加 172.16.10.30/24 網卡、不新增預設閘道，並對齊 PBS endpoint 後，還原才能繼續。

可以先查位址與路由：

~~~bash
ip -br addr
ip route
ping -c 4 172.16.10.31
~~~

本次調整後成功，但產品內部如何比對 endpoint 並未由程式碼證實。遇到相同錯誤仍應一起核對目標節點、datastore 名稱、PVE storage 與認證。

原排查曾用 curl -k 測試 8007 埠；-k 會略過憑證驗證，只適合辨別當下連線問題，不能當成伺服器身分已驗證的證據。

## 3. 還原設定：先保持關機

| 選項 | 本次設定 |
| --- | --- |
| 來源 | CT110 的指定 PBS 備份 |
| 目標節點 | node12 |
| 新 VMID | 210 |
| 目標儲存 | VM_Pool |
| Unique MAC | ON |
| Start after restore | OFF |
| Override name | OFF |

開啟 Override name 時曾出現：

~~~text
PVE API 400
/nodes/node12/lxc/
name property is not defined in schema
~~~

關閉後還原成功。這是本版本的實測解法；沒有完整 payload 或原始碼證據，不能進一步斷定是哪一層的程式缺陷。

## 4. 開機前：把所有會撞到正式機的設定處理完

~~~bash
pct status 210
pct config 210
~~~

本次 rootfs 為 VM_Pool:vm-210-disk-0，大小 10G；管理 IP 改為 192.168.10.210/24。

修改網路時逐張核對網卡。若複製了第二張資料網網卡，它的 IP 也可能重複。保留原有 bridge、VLAN、MTU、防火牆與其他必要欄位，不要只複製一條精簡的 net0 範例去覆蓋完整設定。

ProxCenter 是管理工具，副本裡的 API token 和自動排程也可能仍有效。啟動前先安排測試網路與自動工作的隔離，避免兩台同時管理正式叢集。

## 5. 確認隔離後，才啟動與驗證

在 PVE 啟動測試容器：

~~~bash
pct start 210
pct status 210
ping -c 4 192.168.10.210
pct enter 210
~~~

在容器內看系統與程式：

~~~bash
ip -br addr
ip route
systemctl --failed
docker ps
docker ps -a
ss -lntp
~~~

本次 IP 與預設路由正確、Ping 沒有掉包、systemctl 沒有 failed unit，以下四個容器皆 healthy：

| 容器 | 用途 |
| --- | --- |
| proxcenter-orchestrator | 後端工作 |
| proxcenter-frontend | 網頁介面 |
| proxcenter-weasyprint | 文件產生 |
| proxcenter-postgres | 資料庫 |

網頁入口是：

~~~bash
curl -I http://192.168.10.210:3000
~~~

若誤用 443 埠，連不上不代表還原失敗。先看實際監聽位置，再查網路。

## 6. 如何判定完成？

本次已確認 PBS 備份可還原、CT210 可開機、網路與四個容器正常、基本網頁可用。若要正式驗收，還要補做登入、關鍵資料比對與主要功能測試，並記下各階段時間。

完整復原時間應量到服務可用，不只量檔案複製。本文沒有足夠時間紀錄，不能給出正式 RTO／RPO。

演練後應關閉或隔離副本，確認它不會再操作正式環境。以下是收尾操作範例，本文不把它當成已執行的結果：

~~~bash
pct shutdown 210 --timeout 60
pct status 210
~~~

## 遇到問題時，先分清楚卡在哪一層

| 現象 | 優先檢查 |
| --- | --- |
| 找不到 PBS 對應 | endpoint、datastore、節點上的 storage |
| 還原 API 400 | 本次是 Override name；先看完整錯誤欄位 |
| 開機後 IP 衝突 | 所有網卡的靜態 IP，不只新 MAC |
| 系統正常、網頁不通 | Docker、監聽埠、網路規則 |
| 網頁正常但功能異常 | 資料庫、憑證、外部服務與應用日誌 |

[後續 PBS 更新與驗證紀錄](https://kbwangtw.github.io/IT-Knowledge-Base/docs/pve/ProxCenter-PBS-Update-and-DR-Validation-SOP/)把主機更新和還原演練的證據分開整理，可搭配閱讀。
