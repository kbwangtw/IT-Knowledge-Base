---
layout: default
title: "把三台 PVE 的日誌集中到 Graylog"
date: 2026-09-17
categories: [PVE, Graylog, Syslog]
permalink: /docs/pve/proxmox-graylog-syslog-pipeline-sop/
last_modified_at: 2026-09-18
---

# 把三台 PVE 的日誌集中到 Graylog

日誌分散在三台主機時，要查「哪台出錯、哪個工作失敗」得逐台找。本次把 node10、node11、node12 的日誌送進 Graylog，再替訊息加上來源、類型與任務狀態，最後做成一張任務監控看板。

> 實測日期：2026-09-17；Graylog 7.1.9，部署於 LXC。三台來源與任務看板已有驗證；失敗告警尚未建置。本文保留已提供的規則範例，但沒有完整最新版任務解析規則可供直接匯入。

## 先認識四個名詞

| 名稱 | 白話意思 | 本案名稱 |
| --- | --- | --- |
| Input | 收日誌的入口 | Syslog UDP 1514 |
| Stream | 把相關訊息放在一起 | Infrastructure Syslog |
| Pipeline | 替訊息分類、拆出欄位的規則 | Infrastructure Syslog |
| Index Set | 決定訊息存在哪一組索引 | infra_syslog |

本次實際索引可見 infra_syslog_0。看板只是呈現資料，來源分類與欄位解析要先做好。

~~~text
三台 PVE → rsyslog → Graylog UDP 1514
  → Infrastructure Syslog Stream
  → 分類與欄位解析
  → infra_syslog 索引
  → 搜尋與「PVE 任務監控」看板
~~~

## 1. 先讓三台日誌都進得來

在各 PVE 節點設定轉送；192.0.2.24 是文件示範位址，請替換成自己的 Graylog：

~~~bash
cat > /etc/rsyslog.d/60-graylog.conf <<'EOF'
# Forward PVE syslog messages to Graylog
*.* @192.0.2.24:1514
EOF
~~~

先檢查語法，成功後才重啟：

~~~bash
rsyslogd -N1
systemctl restart rsyslog
systemctl status rsyslog --no-pager
~~~

這裡單一 @ 表示 UDP。Graylog 也要有對應的 UDP 1514 Input。完成後逐台搜尋 source，確認 node10、node11、node12 都有新訊息，不只看服務顯示 running。

## 2. 第一層：認出主機，再標記一般事件

Stage 0 放三類規則：

| 規則 | 在做什麼 |
| --- | --- |
| PVE - Identify Cluster Nodes | source 是三台節點之一時，加入 device_type=pve、pve_cluster=PVE-Cluster |
| PVE-Authentication Events | 標記認證相關訊息 |
| Infrastructure - System Errors | 找 DENIED、failed、error 等字樣，標記 system_error |

一般錯誤的文字比對是初步分類，不能單靠一個 error 字樣就判定整個服務故障；仍須看原訊息。

可產生可辨識的測試訊息：

~~~bash
logger -p auth.info -t pam_unix "Graylog authentication pipeline test"
logger -p kern.warning -t INFRA_ERROR_TEST "DENIED Graylog infrastructure system error test"
~~~

回到 Graylog 開啟訊息，核對來源與新增欄位。訊息收到了、欄位卻沒有出現，問題可能在規則或 Pipeline 與 Stream 的連接。

### 規則改名後，Stage 也要檢查

本次曾出現：

~~~text
Rule PVE - System Errors has been renamed or removed. This rule will be skipped.
~~~

原因是 Stage 還引用舊名稱。移除舊引用，再加入新的 Infrastructure - System Errors 後恢復。規則清單裡有新名稱，不代表所有 Stage 已自動更新。

## 3. 第二層：把 systemd 的服務事件分出來

Stage 1 判讀 systemd 相關訊息中的 Started、Stopped、Starting、Stopping、Reached target，標記 event_category=service。

本次已測過五種訊息。規則使用 Source Code Editor 編輯，避免把「systemd 且任一事件文字」誤設成全部條件都必須成立：

~~~text
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
~~~

測試範例：

~~~bash
logger -p daemon.info -t systemd "Started graylog-pipeline-test.service - Graylog Pipeline Test Service"
logger -p daemon.info -t systemd "Stopped graylog-pipeline-test.service - Graylog Pipeline Test Service"
logger -p daemon.info -t systemd "Starting graylog-pipeline-test.service - Graylog Pipeline Test Service"
logger -p daemon.info -t systemd "Stopping graylog-pipeline-test.service - Graylog Pipeline Test Service"
logger -p daemon.info -t systemd "Reached target graylog-pipeline-test.target - Graylog Pipeline Test Target"
~~~

本案 Stage 1、Stage 2 使用「None or more rules on this stage match」的繼續條件。不要把某一類沒有命中，誤設成所有後續處理都停止。Stage 0 的來源識別也必須能讓預期的 PVE 訊息通過。

## 4. 第三層：辨認 PVE 任務與結果

PVE 的 pvedaemon 日誌會出現 UPID，也就是工作的識別資料。最基本的分類規則如下：

~~~text
rule "PVE - Task Events"
when
    contains(to_string($message.message), "pvedaemon", true)
    &&
    contains(to_string($message.message), "UPID:", true)
then
    set_field("event_category", "pve_task");
end
~~~

這段只把訊息分成 pve_task，**不會自動完成所有任務欄位解析**。

最新版看板使用的欄位：

| 欄位 | 代表什麼 |
| --- | --- |
| pve_event_type | 事件類型 |
| pve_task_name | 工作名稱 |
| pve_task_node | 執行節點 |
| pve_vmid | VM／CT 編號；有些任務沒有這個值 |
| pve_task_user | 執行使用者 |
| pve_task_status | started、success、warning 或 failed |

初期規則曾用 task_status，後續改為 pve_task_status。新看板應使用後者，不能把初期範例當作完整最新版。本紀錄沒有保存最新版全部解析原始碼，因此不提供拼湊的「一鍵匯入」。

三台任務來源已有驗證，node11、node12 的 pveupdate／aptupdate 也有真實成功事件。

### 搜尋不到時，先放寬條件

本次用 source:node10 AND "UPID:" 查最近 5 分鐘沒有結果；改查 pvedaemon 並延長到 15 分鐘，才找到訊息：

~~~text
source:node10 AND pvedaemon
~~~

零筆結果可能只是時間或查詢條件不同，不等於日誌沒送到。先找到原訊息，再核對分類欄位。

## 5. 看板：先看整體，再看異常明細

本次「PVE 任務監控」有八個 Widget：

| 區塊 | 內容 |
| --- | --- |
| 四個數字 | failed、warning、success、started |
| 狀態趨勢 | 看不同狀態隨時間的變化 |
| 節點統計 | 哪個節點有多少完成事件 |
| 任務種類統計 | 哪一類工作最多 |
| 最近異常 | 逐筆列出 warning／failed |

每個 Widget 都明確限制 Infrastructure Syslog Stream，時間範圍使用最近一天到現在。不要只因 Dashboard 名稱正確，就以為每個 Widget 都選到正確 Stream。

節點與種類統計排除 started，避免把同一工作的開始和結束都混進完成統計：

~~~text
pve_task_status:success OR pve_task_status:warning OR pve_task_status:failed
~~~

分組使用 pve_task_node 或 pve_task_name，並略過空值。最近異常使用：

~~~text
pve_task_status:warning OR pve_task_status:failed
~~~

明細依 timestamp 由新到舊，顯示時間、節點、任務、VMID、使用者與狀態。VMID 空白不一定是解析失敗，先確認那種任務是否本來就沒有 VMID。

## 目前完成與待辦

已完成三台接收、基礎分類、五種服務事件測試、任務欄位驗證與八個 Widget。畫面 0 errors/s 只能說當下沒有顯示處理錯誤，仍要抽查欄位是否正確。

尚未建置 PVE Task Failed Alert；Synology、TP-Link 的後續整合也不列入已完成範圍。做告警前，先用真實成功、警告、失敗樣本確認分類，避免把 started 當完成，或一筆事件重複通知。

## 可下載文字版

[下載同版 Markdown]({{ '/assets/downloads/Proxmox_Graylog_SOP_public.md' | relative_url }})。文字版與本文同步；倉庫若仍保留較早的 Word 檔，屬歷史附件，不代表已同步這次改寫。
