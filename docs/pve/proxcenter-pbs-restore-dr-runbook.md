---
layout: default
title: "從 PBS 還原 ProxCenter：先複製一台，再確認能用"
date: 2026-08-28
categories: [PVE, PBS, ProxCenter, DR]
last_modified_at: 2026-10-17
---

# 從 PBS 還原 ProxCenter：先複製一台，再確認能用

> **一句話**：把 ProxCenter（PVE 管理工具）的備份，從 PBS 還原成一台**新的測試容器**，確認開得起來、服務正常；重點是還原出來的副本**不能干擾正式環境**。

| 項目 | 內容 |
| --- | --- |
| 適合誰看 | 第一次做 LXC 容器還原演練的人 |
| 環境 | PVE 9.2.11；正式容器 CT110 → 還原成 node12 上的 CT210 |
| 實測日期 | 2026-08-28 |
| 結論 | ✅ 可開機、四個 Docker 容器 healthy、網頁 3000 埠連得上；⏳ 業務功能、排程、資料完整性**尚未驗證** |

> 文中 IP 都是文件示範位址（管理網 192.0.2.0/24、內部網段 198.51.100.0/24）；VMID、IP、儲存名稱只供本案對照，不能直接套用。

## 1. 先認識幾個名詞

| 名詞 | 白話解釋 |
| --- | --- |
| **ProxCenter** | 管理 PVE 叢集的網頁工具，裡面有 API token 和自動排程 |
| **LXC（CT）** | 輕量級容器，和主機共用核心；CT110 就是編號 110 的容器 |
| **Datastore** | PBS 上存放備份的空間，本案叫 Tokyo16 |
| **Endpoint** | 連線的目標位址 |
| **Unique MAC** | 還原時產生新的網卡 MAC 位址，避免和正式機衝突 |
| **Docker 容器 healthy** | Docker 自己的健康檢查通過 |

## 2. 資料走哪條路

```text
正式 CT110
  → PBS31 的 Tokyo16 備份
  → 還原成 node12 上的新 CT210（磁碟放 VM_Pool）
  → 換成測試 IP 後開機
  → 檢查系統、Docker 與網頁
```

> ⚠️ 用新 VMID 和新 MAC，可以避免覆蓋或混淆正式機。但副本**仍可能帶著相同的 IP、API token 和排程**，所以還原完**不能**直接接回正式網路。

## 3. 步驟一：確認來源與目標

```bash
pvecm status                  # 叢集狀態
pvesm status                  # 所有儲存狀態
pvesm status --storage PBS31
pvesm list PBS31              # 列出 PBS 上的備份
pct status 110
pct config 110                # 正式機的設定，留作對照
pct status 210                # 確認 210 沒被使用
```

**要確認的事**：選對 CT110 的快照、node12 能使用 PBS31、VM_Pool 空間夠、210 沒被其他工作佔用。

> 備份清單列得出來，只能證明「存取得到」，不能代替實際還原。

## 4. 踩雷一：找不到 datastore 對應

**錯誤訊息**：

```text
No PVE storage on node node12 maps to PBS datastore Tokyo16
```

**原因**：PVE 用 PBS 的**資料網**位址 198.51.100.31 連 PBS，而 ProxCenter 原本用**管理網**位址。

**解法**：替 ProxCenter 加一張 198.51.100.30/24 的網卡（不設預設閘道），並對齊 PBS 的 endpoint 後，還原就能繼續。

查位址與路由：

```bash
ip -br addr
ip route
ping -c 4 198.51.100.31
```

- 這樣調整後成功了，但產品內部怎麼比對 endpoint，**沒有從程式碼證實**。遇到同樣錯誤，仍要一起核對目標節點、datastore 名稱、PVE storage 與認證。
- 排查時曾用 `curl -k` 測 8007 埠。`-k` 會**略過憑證驗證**，只適合判斷「連不連得上」，不能當成伺服器身分已驗證的證據。

## 5. 步驟二：還原設定（先保持關機）

| 選項 | 本次設定 | 為什麼 |
| --- | --- | --- |
| 來源 | CT110 的指定 PBS 備份 | — |
| 目標節點 | node12 | — |
| 新 VMID | 210 | 不覆蓋正式機 |
| 目標儲存 | VM_Pool | — |
| Unique MAC | ON | 避免 MAC 衝突 |
| Start after restore | **OFF** | 先改好設定再開機 |
| Override name | **OFF** | 見下方踩雷 |

**踩雷二**：開啟 Override name 時出現：

```text
PVE API 400
/nodes/node12/lxc/
name property is not defined in schema
```

關閉後還原成功。這是本版本的實測解法；沒有完整的 payload 或原始碼證據，不能斷定是哪一層的問題。

## 6. 步驟三：開機前，處理所有會撞到正式機的設定

```bash
pct status 210
pct config 210
```

本次 rootfs 是 `VM_Pool:vm-210-disk-0`，大小 10G；管理 IP 改成 192.0.2.210/24。

- **每一張網卡都要檢查**：如果複製了第二張資料網網卡，它的 IP 也會重複。
- 修改時保留原本的 bridge、VLAN、MTU、防火牆等欄位，**不要**只拿一條精簡的 net0 範例去覆蓋完整設定。
- ProxCenter 是管理工具，副本裡的 **API token 和自動排程可能仍然有效**。開機前先安排隔離的測試網路、停用自動工作，避免兩台同時管理正式叢集。

## 7. 步驟四：確認隔離後，啟動並驗證

在 PVE 上：

```bash
pct start 210
pct status 210
ping -c 4 192.0.2.210
pct enter 210
```

在容器內：

```bash
ip -br addr          # IP 是否正確
ip route             # 預設路由
systemctl --failed   # 有沒有失敗的服務
docker ps            # 運作中的容器
docker ps -a         # 包含已停止的容器
ss -lntp             # 有哪些埠在監聽
```

**看到的結果**：IP 與預設路由正確、ping 沒掉封包、沒有 failed 服務，四個容器都是 healthy：

| 容器 | 用途 |
| --- | --- |
| proxcenter-orchestrator | 後端工作 |
| proxcenter-frontend | 網頁介面 |
| proxcenter-weasyprint | 文件產生 |
| proxcenter-postgres | 資料庫 |

網頁入口：

```bash
curl -I http://192.0.2.210:3000
```

> 網頁在 **3000 埠**。誤用 443 連不上，不代表還原失敗；先看 `ss -lntp` 實際監聽在哪裡。

## 8. 怎麼判定完成

| 項目 | 狀態 |
| --- | --- |
| PBS 備份可以還原 | ✅ |
| CT210 可以開機 | ✅ |
| 網路與四個容器正常 | ✅ |
| 基本網頁可用 | ✅ |
| 登入、關鍵資料比對、主要功能測試 | ⏳ 待補 |
| 各階段時間紀錄（RTO／RPO） | ⏳ 沒有足夠紀錄，不能給出正式數字 |

完整復原時間要量到「**服務可用**」，不只是檔案複製完。

**演練後收尾**：關閉或隔離副本，確認它不會再操作正式環境。以下是收尾範例（本文不把它當成已執行的結果）：

```bash
pct shutdown 210 --timeout 60
pct status 210
```

## 9. 常見問題：先分清楚卡在哪一層

| 現象 | 優先檢查 |
| --- | --- |
| 找不到 PBS 對應 | endpoint、datastore 名稱、節點上的 storage |
| 還原時 API 400 | 本次是 Override name；先看完整錯誤欄位 |
| 開機後 IP 衝突 | **所有**網卡的靜態 IP，不只 MAC |
| 系統正常、網頁不通 | Docker、監聽埠、網路規則 |
| 網頁正常、功能異常 | 資料庫、憑證、外部服務與應用日誌 |

## 10. 延伸閱讀

- [PBS 更新後，怎麼確認備份還能用？](https://kbwangtw.github.io/IT-Knowledge-Base/docs/pve/ProxCenter-PBS-Update-and-DR-Validation-SOP/)：主機更新與還原演練的證據分開整理
- [Ubuntu VM 從 PBS 還原：6 分 38 秒代表什麼？](https://kbwangtw.github.io/IT-Knowledge-Base/docs/pve/ubuntu-vm112-pbs-disaster-recovery/)
