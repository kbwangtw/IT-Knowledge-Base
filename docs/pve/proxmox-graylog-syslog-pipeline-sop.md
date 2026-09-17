---
layout: default
title: "Proxmox VE Graylog Syslog 集中管理與 Pipeline 分類建置技術文件"
date: 2026-09-17
categories: [PVE, Graylog, Syslog]
permalink: /docs/pve/proxmox-graylog-syslog-pipeline-sop/
---

<div class="kb-hero">
<h1>Proxmox VE Graylog Syslog 集中管理與 Pipeline 分類建置技術文件</h1>
<p>三節點 Syslog 集中收集、多 Stage Pipeline、PVE Task 欄位解析與任務監控 Dashboard 的實際建置紀錄。</p>
<div class="kb-badges"><span class="kb-badge">PVE</span><span class="kb-badge">Graylog 7.1.9</span><span class="kb-badge">SOP</span><span class="kb-badge">2026-09-17 更新</span></div>
</div>

> **公開版本注意：**公開版本已將實際內網 IP 替換為文件示例位址 `192.0.2.24`；套用指令前請改成自己的 Graylog 位址。節點名稱與分類邏輯沿用實際建置紀錄。

## 文件導覽

* TOC
{:toc}

版本 1.2｜建置紀錄日期 2026 年 9 月 17 日｜文件類型：企業內部 SOP 與建置紀錄

## 1. 目的與目前完成狀態

本文件記錄 Proxmox VE 日誌集中送往 Graylog、Stream / Index、Pipeline Rule、Stage 分層、實際測試與故障排除。

目前 `node10`、`node11`、`node12` 均持續透過 rsyslog 將系統日誌送至 Graylog。已完成 PVE 節點識別、Authentication、Infrastructure System Errors、systemd Service Events、PVE Task Events 與 PVE Task Started 分類；Stage 0、Stage 1、Stage 2 均已建立，且 Service 與 Task 分類已使用實際訊息驗證。

截至 2026-09-17，PVE Task Pipeline 已完成 node10／node11／node12 實機驗證，node11／node12 已使用 pveupdate／aptupdate 實測 success。Dashboard「PVE 任務監控」的 8 個 Widget 已完成，均指定 Infrastructure Syslog Stream。下一階段為 Alerts → Event Definitions → PVE Task Failed Alert，尚未開始。

## 2. 環境資訊

| 項目 | 設定 |
| --- | --- |
| Graylog | 7.1.9，部署於 PVE LXC |
| 公開文件示例管理位址 | 192.0.2.24:9000 |
| Syslog | UDP 1514 |
| PVE 節點 | node10、node11、node12 |
| Stream | Infrastructure Syslog |
| Pipeline | Infrastructure Syslog |
| Index prefix | infra_syslog |
| 實際驗證 Index | infra_syslog_0 |
| PVE 設備欄位 | `device_type=pve` |
| PVE Cluster 標籤 | `pve_cluster=PVE-Cluster` |

資料流程：

```text
PVE node10 / node11 / node12
  → rsyslog
  → Graylog Syslog UDP 1514
  → Infrastructure Syslog Stream
  → Infrastructure Syslog Pipeline
      Stage 0：設備識別 / Authentication / System Errors
      Stage 1：PVE Service Events
      Stage 2：PVE Task 分類 / 欄位解析 / 狀態
  → infra_syslog Index Set
  → Graylog Search / PVE 任務監控 Dashboard
```

## 3. PVE Syslog 轉送

三台 PVE 節點使用 `/etc/rsyslog.d/60-graylog.conf`：

```bash
cat > /etc/rsyslog.d/60-graylog.conf <<'EOF'
# Forward PVE syslog messages to Graylog
*.* @192.0.2.24:1514
EOF
```

檢查並重啟：

```bash
rsyslogd -N1
systemctl restart rsyslog
systemctl status rsyslog --no-pager
```

> 單一 `@` 為 UDP。公開文件使用 TEST-NET 位址，實際環境請替換為自己的 Graylog IP。

## 4. Stage 0：基礎識別與通用分類

Stage 0 目前包含三條 Rule，Continue processing 設定為：

```text
At least one of the rules on this stage matches the message
```

### 4.1 PVE - Identify Cluster Nodes

```text
When：OR
source = node10
source = node11
source = node12

Then：
device_type = pve
pve_cluster = PVE-Cluster
```

已以真實訊息確認三台節點可被標記。

### 4.2 PVE-Authentication Events

用途：分類認證相關訊息。

已驗證測試：

```bash
logger -p auth.info -t pam_unix "Graylog authentication pipeline test"
```

結果包含：

```text
device_type = pve
pve_cluster = PVE-Cluster
event_category = authentication
```

### 4.3 Infrastructure - System Errors

此 Rule 原名 `PVE-System Errors`，後改名為通用 Infrastructure 分類。

```text
When：OR
message contains DENIED
message contains failed
message contains error

Then：
event_category = system_error
```

測試：

```bash
logger -p kern.warning -t INFRA_ERROR_TEST "DENIED Graylog infrastructure system error test"
```

已確認：

```text
device_type = pve
pve_cluster = PVE-Cluster
event_category = system_error
```

### 4.4 Rule 改名故障排除

Rule 改名後 Stage 曾顯示：

```text
Rule PVE - System Errors has been renamed or removed. This rule will be skipped.
```

處理方式：Stage 0 → Edit → Remove 舊參照 → 選入 `Infrastructure - System Errors` → Update stage → 重新送測試訊息驗證。

**重要：**在本次 Graylog 7.1.9 實際操作中，Rule 改名後應重新檢查 Stage 關聯，不要假設 Stage 會自動更新名稱。

## 5. Stage 1：PVE Service Events

Stage 1：

```text
Continue processing on next stage when:
None or more rules on this stage match

Rule:
PVE - Service Events
```

此 Rule 因需要 `systemd AND (Started OR Stopped...)` 的巢狀邏輯，改用 Source Code Editor。

```text
rule "PVE - Service Events"
when
    contains(to_string($message.message), "systemd", true)
    &&
    (
        contains(to_string($message.message), "Started", true)
        ||
        contains(to_string($message.message), "Stopped", true)
        ||
        contains(to_string($message.message), "Starting", true)
        ||
        contains(to_string($message.message), "Stopping", true)
        ||
        contains(to_string($message.message), "Reached target", true)
    )
then
    set_field("event_category", "service");
end
```

### 5.1 五種 Service Event 實測

已分別送出並在 Graylog Message Details 驗證：

```bash
logger -p daemon.info -t systemd "Started graylog-pipeline-test.service - Graylog Pipeline Test Service"
logger -p daemon.info -t systemd "Stopped graylog-pipeline-test.service - Graylog Pipeline Test Service"
logger -p daemon.info -t systemd "Starting graylog-pipeline-test.service - Graylog Pipeline Test Service"
logger -p daemon.info -t systemd "Stopping graylog-pipeline-test.service - Graylog Pipeline Test Service"
logger -p daemon.info -t systemd "Reached target graylog-pipeline-test.target - Graylog Pipeline Test Target"
```

五種訊息均成功產生：

```text
device_type = pve
pve_cluster = PVE-Cluster
event_category = service
```

因此 `Started / Stopped / Starting / Stopping / Reached target` 五個分支均已逐一驗證。

## 6. Stage 2：PVE Task Events

Stage 2：

```text
Continue processing on next stage when:
None or more rules on this stage match
```

初期建置包含（保留以下歷史 Rule 範例，最新欄位與驗證狀態見 6.4 節）：

```text
PVE - Task Events
PVE - Task Started
```

### 6.1 PVE - Task Events

依 Graylog 匯出的實際訊息清單分析，PVE Task 可見 `pvedaemon` 與 `UPID:`。基礎 Rule：

```text
rule "PVE - Task Events"
when
    contains(to_string($message.message), "pvedaemon", true)
    &&
    contains(to_string($message.message), "UPID:", true)
then
    set_field("event_category", "pve_task");
end
```

Simulation 成功後加入 Stage 2，再以 PVE Web UI 實際開啟 VM/LXC Console 產生真實 Task Log。

真實訊息格式例如：

```text
node10 pvedaemon[...]: <root@pam> starting task UPID:node10:...:vncproxy:100:root@pam:
```

以及：

```text
node10 pvedaemon[...]: <root@pam> end task UPID:node10:...:vncproxy:103:root@pam: OK
```

真實 `starting task` 訊息已確認：

```text
device_type = pve
pve_cluster = PVE-Cluster
event_category = pve_task
```

### 6.2 PVE - Task Started（初期建置紀錄）

本節程式碼為初期使用 `task_status` 的歷史範例；目前 Dashboard 與後續 Alert 統一使用 `pve_task_status`，請勿直接以舊欄位建立查詢。

Graylog Pipeline DSL 不接受本次嘗試的 `{ }` 形式 inline `if` 寫法，因此沒有修改已穩定運作的 `PVE - Task Events`，改為獨立 Rule：

```text
rule "PVE - Task Started"
when
    contains(to_string($message.message), "pvedaemon", true)
    &&
    contains(to_string($message.message), "UPID:", true)
    &&
    contains(to_string($message.message), "starting task", true)
then
    set_field("task_status", "started");
end
```

Simulation 已成功產生：

```text
task_status = started
```

將 `PVE - Task Started` 與 `PVE - Task Events` 同時加入 Stage 2 後，再以真實 PVE Console 操作驗證。同一筆真實訊息成功同時得到：

```text
device_type = pve
pve_cluster = PVE-Cluster
event_category = pve_task
task_status = started
```

這證明 Stage 2 的兩條 Rule 可共同處理同一筆 PVE Task 訊息。

### 6.3 Task Log 搜尋注意事項

曾使用：

```text
source:node10 AND "UPID:"
```

在 5 分鐘時窗得到 0 筆；放寬為：

```text
source:node10 AND pvedaemon
```

並將時間範圍調為 15 分鐘後，可看到多筆真實 `starting vnc proxy`、`starting task UPID:`、`end task ... OK` 與 `successful auth` 訊息。

因此排查 Task 時，建議先以 `source + pvedaemon` 廣搜，再從 Message Details 確認 UPID，不要只用單一片語搜尋結果判斷「PVE 沒有產生 Task Log」。

### 6.4 PVE Task Pipeline 最新驗證狀態

PVE Task Pipeline 已完成三節點實機驗證。目前解析欄位如下；各任務實際欄位值以 Message Details 為準。

| 欄位 | 用途／已確認內容 |
| --- | --- |
| `device_type` | `pve` |
| `event_category` | `pve_task` |
| `pve_cluster` | `PVE-Cluster` |
| `pve_event_type` | PVE 事件類型 |
| `pve_task_name` | 任務名稱／類型 |
| `pve_task_node` | 任務所屬節點 |
| `pve_vmid` | VM／LXC 識別欄位；依任務內容可能為空 |
| `pve_task_user` | 執行任務的使用者 |
| `pve_task_status` | 任務狀態；Dashboard 使用 started／success／warning／failed |

| 節點 | 驗證結果 |
| --- | --- |
| node10 | PVE Task Pipeline 實機驗證完成 |
| node11 | PVE Task Pipeline 實機驗證完成；以 pveupdate／aptupdate 實測 success |
| node12 | PVE Task Pipeline 實機驗證完成；以 pveupdate／aptupdate 實測 success |

目前完成紀錄未提供最新完整 Rule 原始碼與 Rule 名稱清單，因此保留前述初期範例供追溯；最新欄位以本節為準。warning／failed 已納入 Dashboard 查詢，並不代表已刻意製造警告／失敗任務或完成 Alert 觸發測試。

## 7. 目前 Pipeline 架構

```text
Infrastructure Syslog
│
├─ Stage 0
│  ├─ PVE - Identify Cluster Nodes
│  ├─ PVE-Authentication Events
│  └─ Infrastructure - System Errors
│
├─ Stage 1
│  └─ PVE - Service Events
│
└─ Stage 2
   └─ PVE Task 分類 / 欄位解析 / 狀態（見 6.4 節）
```

已驗證欄位：

| 類型 | 欄位 |
| --- | --- |
| PVE 節點 | `device_type=pve`、`pve_cluster=PVE-Cluster` |
| Authentication | `event_category=authentication` |
| System Error | `event_category=system_error` |
| Service Event | `event_category=service` |
| PVE Task | `event_category=pve_task` |
| PVE Task 狀態 | `pve_task_status`（started／success／warning／failed） |
| PVE Task 解析 | `pve_event_type`、`pve_task_name`、`pve_task_node`、`pve_vmid`、`pve_task_user` |

## 8. 驗收狀態與 PVE 任務監控 Dashboard

| 項目 | 狀態 |
| --- | --- |
| Syslog UDP 1514 / Stream / Index | ✅ 已完成 |
| node10 / node11 / node12 自動收集與節點識別 | ✅ 已完成 |
| Authentication / Infrastructure System Errors | ✅ 已驗證 |
| Rule rename 故障排除 | ✅ 已完成並複測 |
| Stage 1 Service Events | ✅ 五種狀態逐一驗證 |
| PVE Task Pipeline 與欄位解析 | ✅ 三節點實機驗證完成 |
| node11 / node12 success | ✅ pveupdate／aptupdate 實測 |
| PVE 任務監控 Dashboard | ✅ 8 個 Widget 已完成 |
| PVE Task Failed Alert | ⏳ 尚未開始 |
| Synology / TP-Link 納管 | ⏳ 後續規劃 |

### 8.1 共用範圍與時間設定

- Dashboard 名稱：**PVE 任務監控**。
- 所有 PVE Widget 的 Stream 均指定 **Infrastructure Syslog**。
- Dashboard Global Override：**1 day ago → Now**。

> **已確認的設定陷阱：**未指定 Stream 會混入其他資料。每個 PVE Widget 都必須明確選擇 Infrastructure Syslog，不能只依賴 Widget 名稱或 Dashboard 名稱限制資料來源。

### 8.2 八個 Widget

| 編號 | Widget 名稱 | 統計／查詢範圍 | 分組與顯示設定 |
| --- | --- | --- | --- |
| 1 | PVE 任務失敗數 | `pve_task_status:failed` | KPI 訊息筆數 |
| 2 | PVE 任務警告數 | `pve_task_status:warning` | KPI 訊息筆數 |
| 3 | PVE 任務成功數 | `pve_task_status:success` | KPI 訊息筆數 |
| 4 | PVE 任務啟動數 | `pve_task_status:started` | KPI 訊息筆數 |
| 5 | PVE 任務狀態趨勢 | PVE 任務狀態隨時間的變化 | 狀態趨勢圖 |
| 6 | PVE 各節點任務量 | 僅 success／warning／failed | Group By：`pve_task_node`；Skip Empty Values |
| 7 | PVE 任務類型分布 | 僅 success／warning／failed | Group By：`pve_task_name`；Skip Empty Values |
| 8 | PVE 最近異常任務 | 僅 warning／failed | 訊息表格；timestamp Descending |

各節點任務量與任務類型分布使用以下狀態範圍，排除 started：

```text
pve_task_status:success OR pve_task_status:warning OR pve_task_status:failed
```

最近異常任務 Query：

```text
pve_task_status:warning OR pve_task_status:failed
```

最近異常任務欄位順序：

```text
timestamp
pve_task_node
pve_task_name
pve_vmid
pve_task_user
pve_task_status
```

排序設定為 **timestamp Descending**，最新異常列在最上方。若目前時間範圍內 warning／failed 均為 0，異常表格可為空；仍應先確認 Stream 與時間範圍正確。

### 8.3 Dashboard 版面

| 位置 | 左側 | 右側 |
| --- | --- | --- |
| 第一排 | 失敗／警告 KPI | 成功／啟動 KPI |
| 第二排 | 任務狀態趨勢 | 各節點任務量 |
| 第三排 | 任務類型分布 | 最近異常任務 |

第一排由左至右依序為：**失敗 → 警告 → 成功 → 啟動**。

## 9. 下一步

下一階段尚未開始：**Alerts → Event Definitions → PVE Task Failed Alert**。

預定以 `pve_task_status:failed` 作為失敗任務篩選條件，建立 Event Definition；Event 觸發驗證與後續 Email 通知尚未完成，不列入本次 Dashboard／Pipeline 完成範圍。

## 10. 維運原則與修訂紀錄

每次修改 Rule 名稱、條件、Action 或 Stage 掛載後，都要重新產生測試訊息並從 Message Details 驗證欄位。`0 errors/s` 只能表示當下沒有 Pipeline 執行錯誤，不能取代分類結果驗證。

版本 1.0：完成 Syslog 收集、Stage 0 三條 Rule、系統錯誤 Rule 改名故障排除。

版本 1.1：新增 Stage 1 / Stage 2、`PVE - Service Events` 五種狀態實測、`PVE - Task Events` 真實 Task 驗證、`PVE - Task Started` 與 `task_status=started` 真實驗證，並記錄 `PVE - Task Success` 為下一步。

版本 1.2：完成三節點 PVE Task Pipeline 驗證紀錄，補上 pve_* 解析欄位、node11／node12 success 實測、8 個 Dashboard Widget、Infrastructure Syslog 範圍、Global Override 與版面；下一階段更新為尚未開始的 PVE Task Failed Alert。
