---
layout: default
title: "Proxmox VE Graylog Syslog 集中管理與 Pipeline 分類建置技術文件"
date: 2026-09-16
categories: [PVE, Graylog, Syslog]
permalink: /docs/pve/proxmox-graylog-syslog-pipeline-sop/
---

<div class="kb-hero">
<h1>Proxmox VE Graylog Syslog 集中管理與 Pipeline 分類建置技術文件</h1>
<p>三節點 Syslog 集中收集、多 Stage Pipeline、systemd 服務事件與 PVE Task 分類的實際建置紀錄。</p>
<div class="kb-badges"><span class="kb-badge">PVE</span><span class="kb-badge">Graylog 7.1.9</span><span class="kb-badge">SOP</span><span class="kb-badge">2026-09-16 更新</span></div>
</div>

> **公開版本注意：**公開版本已將實際內網 IP 替換為文件示例位址 `192.0.2.24`；套用指令前請改成自己的 Graylog 位址。節點名稱與分類邏輯沿用實際建置紀錄。

## 文件導覽

* TOC
{:toc}

版本 1.1｜建置紀錄日期 2026 年 9 月 16 日｜文件類型：企業內部 SOP 與建置紀錄

## 1. 目的與目前完成狀態

本文件記錄 Proxmox VE 日誌集中送往 Graylog、Stream / Index、Pipeline Rule、Stage 分層、實際測試與故障排除。

目前 `node10`、`node11`、`node12` 均持續透過 rsyslog 將系統日誌送至 Graylog。已完成 PVE 節點識別、Authentication、Infrastructure System Errors、systemd Service Events、PVE Task Events 與 PVE Task Started 分類；Stage 0、Stage 1、Stage 2 均已建立，且 Service 與 Task 分類已使用實際訊息驗證。

目前正在進行下一項：`PVE - Task Success`，預計將 `end task ... OK` 標記為 `task_status=success`。此項尚未完成，因此本文不將它列為已驗證功能。

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
      Stage 2：PVE Task Events / Task Started
  → infra_syslog Index Set
  → Graylog Search
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

目前包含：

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

### 6.2 PVE - Task Started

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
   ├─ PVE - Task Events
   └─ PVE - Task Started
```

已驗證欄位：

| 類型 | 欄位 |
| --- | --- |
| PVE 節點 | `device_type=pve`、`pve_cluster=PVE-Cluster` |
| Authentication | `event_category=authentication` |
| System Error | `event_category=system_error` |
| Service Event | `event_category=service` |
| PVE Task | `event_category=pve_task` |
| PVE Task 開始 | `task_status=started` |

## 8. 驗收狀態

| 項目 | 狀態 |
| --- | --- |
| Syslog UDP 1514 / Stream / Index | ✅ 已完成 |
| node10 / node11 / node12 自動收集 | ✅ 已完成 |
| PVE 節點識別 | ✅ 已完成 |
| Authentication 分類 | ✅ 已驗證 |
| Infrastructure System Errors | ✅ 已驗證 |
| Rule rename 故障排除 | ✅ 已完成並複測 |
| Stage 1 Service Events | ✅ 五種狀態逐一驗證 |
| Stage 2 PVE Task Events | ✅ 真實 PVE Task 驗證 |
| `task_status=started` | ✅ 真實 PVE Task 驗證 |
| `task_status=success` | ⏳ 正在建置，尚未完成 |
| `task_status=failed` | ⏳ 尚未建立 |
| Task type / PVE user 欄位拆分 | ⏳ 尚未建立 |
| Synology / TP-Link 納管 | ⏳ 後續規劃 |
| Dashboard / Alert | ⏳ 後續規劃 |

## 9. 下一步

目前下一條 Rule 已開始建立名稱與說明：

```text
PVE - Task Success
Identify successfully completed Proxmox VE tasks from pvedaemon
```

預計條件：

```text
pvedaemon
AND UPID:
AND end task
AND OK
    ↓
task_status = success
```

此 Rule 尚未完成 Source Code、Simulation、Stage 2 掛載與真實訊息驗證；完成後再更新本文狀態。

後續再規劃 `PVE - Task Failed`、`task_type`、`pve_user`，以及 VM Start/Stop、Backup、Snapshot、Migration、Replication、HA 等 PVE 維運事件分類。

## 10. 維運原則與修訂紀錄

每次修改 Rule 名稱、條件、Action 或 Stage 掛載後，都要重新產生測試訊息並從 Message Details 驗證欄位。`0 errors/s` 只能表示當下沒有 Pipeline 執行錯誤，不能取代分類結果驗證。

版本 1.0：完成 Syslog 收集、Stage 0 三條 Rule、系統錯誤 Rule 改名故障排除。

版本 1.1：新增 Stage 1 / Stage 2、`PVE - Service Events` 五種狀態實測、`PVE - Task Events` 真實 Task 驗證、`PVE - Task Started` 與 `task_status=started` 真實驗證，並記錄 `PVE - Task Success` 為下一步。
