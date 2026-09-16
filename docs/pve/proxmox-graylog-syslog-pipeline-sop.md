---
layout: default
title: "Proxmox VE Graylog Syslog 集中管理與 Pipeline 分類建置技術文件"
date: 2026-09-16
categories: [PVE, Graylog, Syslog]
permalink: /docs/pve/proxmox-graylog-syslog-pipeline-sop/
---

<div class="kb-hero">
<h1>Proxmox VE Graylog Syslog 集中管理與 Pipeline 分類建置技術文件</h1>
<p>三節點 Syslog 集中收集、三條 Pipeline 規則與改名故障排除的實際建置紀錄。</p>
<div class="kb-badges"><span class="kb-badge">PVE</span><span class="kb-badge">Graylog 7.1.9</span><span class="kb-badge">SOP</span></div>
</div>

> **公開版本注意：**公開版本已將實際內網 IP 替換為文件示例位址 192.0.2.24；套用指令前請改成自己的 Graylog 位址。節點名稱與分類邏輯沿用建置紀錄。

**下載：**[Word 技術文件（公開版）]({{ '/assets/downloads/Proxmox_Graylog_SOP_public.docx' | relative_url }}) · [Markdown 原始文件（公開版）]({{ '/assets/downloads/Proxmox_Graylog_SOP_public.md' | relative_url }})

## 文件導覽

* TOC
{:toc}


版本 1.0｜建置紀錄日期 2026 年 9 月 16 日｜文件類型 企業內部 SOP 與建置紀錄

## 1 目的與完成結論

本文件供系統管理人員維護 Proxmox VE 日誌集中收集與分類環境，涵蓋 Syslog 轉送、Graylog Input、Stream、Index Set、Pipeline Rule、實際測試及故障排除。

目前 node10、node11、node12 均已透過 rsyslog 持續將系統日誌送至 Graylog。三條自訂規則已建立並掛載於 Infrastructure Syslog Pipeline 的 Stage 0；PVE 節點識別、認證事件與系統錯誤分類均有成功驗證紀錄。系統錯誤規則改名後的掛載失效已修復，並完成重新測試。

**範圍注意：**服務事件分類、Stage 分層、Synology 與 TP-Link Switch 納管、Dashboard 與 Alert 均屬後續規劃，不列入本次完成項目。本文件為既有建置紀錄，不代表已重新登入正式環境執行驗收。

## 2 環境資訊與架構

| 項目 | 已記錄設定 |
| --- | --- |
| Graylog | 7.1.9，部署於 PVE LXC |
| 管理介面 | 192.0.2.24:9000 |
| Syslog 目的地 | 192.0.2.24，UDP 1514 |
| Input | Syslog UDP 1514；Bind address 0.0.0.0；RUNNING 1/1 |
| PVE 節點 | node10、node11、node12 |
| rsyslog | 8.2504.0；節點服務為 active (running)，已 enabled |
| Stream | Infrastructure Syslog |
| Pipeline | Infrastructure Syslog，連接同名 Stream |
| Index Set | Infrastructure Syslog；prefix 為 infra_syslog |
| 實際驗證 Index | infra_syslog_0 |
| 後端元件 | MongoDB 8.0.32、OpenSearch 2.19.5 |

資料處理關係如下，Routing 與分類為不同用途：

```text
PVE node10 / node11 / node12
  → 本機 rsyslog
  → 192.0.2.24:1514/UDP
  → Syslog UDP 1514 Input
  → Wizard Routing → Infrastructure Syslog Stream
  → Infrastructure Syslog Pipeline / Stage 0
  → 加入 device_type、pve_cluster、event_category
  → Infrastructure Syslog Index Set → OpenSearch
  → Graylog Search（驗證時索引為 infra_syslog_0）
```

Wizard 已完成 Stream 建立與啟動、Pipeline 建立、Routing、Pipeline 與 Stream 連接及 Input 啟動。自動產生的 gl_route_... Routing Rule 保留使用，不計入本文件的三條自訂分類規則。

Index Set 當時採 Data Tiering，Min. in storage 14 days、Max. in storage 18 days、1 shard、0 replicas、Field refresh interval 5 seconds。這些是已設定值，不代表已經過完整保留週期測試。infra_syslog_0 是當次訊息實際存放的索引，不應將後續驗收限定只能使用此尾碼。

## 3 PVE Syslog 收集設定

### 3.1 節點與服務確認

於各 PVE 節點的管理 Shell 執行以下檢查。當次 pvecm nodes 顯示 node10、node11、node12 三個成員。

```bash
hostname
systemctl status rsyslog --no-pager
```

```bash
pvecm nodes
```

### 3.2 永久轉送設定

三台節點均使用 /etc/rsyslog.d/60-graylog.conf，建置時採用以下指令建立：

```bash
cat > /etc/rsyslog.d/60-graylog.conf <<'EOF'
# Forward PVE syslog messages to Graylog
*.* @192.0.2.24:1514
EOF
```

**操作注意：**上述指令會覆寫同名檔案。既有環境重做前，先檢視並備份原檔，確認沒有其他需要保留的設定。單一 @ 對應本次 UDP 轉送；此設定新增集中轉送用途，原有本機日誌設定未因本次建置而移除。

先檢查設定，通過後才重新啟動服務：

```bash
cat /etc/rsyslog.d/60-graylog.conf
rsyslogd -N1
```

成功檢查輸出包含：

```text
rsyslogd: End of config validation run. Bye.
```

```bash
systemctl restart rsyslog
systemctl status rsyslog --no-pager
```

服務重新啟動後已確認為 active (running)。node11 與 node12 另有逐台測試與搜尋成功紀錄；三台節點也均已確認持續傳入真實系統日誌。

### 3.3 Input 與接收確認

Graylog Input 已確認監聽 UDP 1514，且 Store full message 生效。訊息詳細欄位可見 source、facility、facility_num、level、message、full_message 與 timestamp 等解析結果。

**欄位注意：**當次自動轉送訊息的 message 仍可能含主機名稱與程式名稱，例如 node12 sudo: pam_unix(...)。service 與 log_message 拆分尚未完成，不列為現有自訂欄位。

## 4 Pipeline 架構與三條規則

三條規則均以 Graylog Rule Builder 建立。以下程式碼區塊記錄 UI 參數與邏輯，並非宣稱為匯出的 Pipeline Source Code。

### 4.1 PVE - Identify Cluster Nodes

用途為識別三台 PVE 節點，保留 source 區分主機，同時增加設備類型與叢集標籤。

```text
When：OR
Field equals：field=source，fieldValue=node10
Field equals：field=source，fieldValue=node11
Field equals：field=source，fieldValue=node12
三個條件：caseInsensitive=false；均不啟用 NOT

Then：Set field
field=device_type，value=pve
field=pve_cluster，value=PVE-Cluster
```

**設定注意：**source 條件使用 OR，不使用 AND。PVE-Cluster 為規則寫入的標籤值，不應據此推定它就是 PVE 原生叢集名稱。

### 4.2 PVE-Authentication Events

用途為以 pam_unix 辨識認證相關訊息，並排除包含 cron 的紀錄。規則名稱採實際建立與掛載紀錄中的 PVE-Authentication Events；早期操作說明曾使用帶空格的 PVE - Authentication Events。

```text
When：AND
Field contains：field=message，search=pam_unix
  ignoreCase=true；NOT 不啟用
Field contains：field=message，search=cron
  ignoreCase=true；NOT 啟用

邏輯：message contains pam_unix
      AND NOT message contains cron

Then：Set field
field=event_category，value=authentication
```

**分類邊界：**實際條件沒有 source 或 device_type 限制，也不是依 facility 分類。名稱雖含 PVE，仍會對連入此 Pipeline 且符合文字條件的訊息生效；目前驗證成功的是 node10 測試訊息，不代表所有 SSH、sudo 或登入失敗格式均已涵蓋。

### 4.3 Infrastructure - System Errors

用途為 Infrastructure Syslog 中的通用錯誤分類。最初以 PVE-System Errors 建立，後續改名為 Infrastructure - System Errors，When 與 Then 保持不變。

```text
When：OR
Field contains：field=message，search=DENIED
Field contains：field=message，search=failed
Field contains：field=message，search=error
三個條件：ignoreCase=true；均不啟用 NOT

Then：Set field
field=event_category，value=system_error
```

**重要注意：**此規則未加入 device_type=pve 限制，適用於此 Pipeline 接收的 Infrastructure Syslog 訊息。當次曾嘗試新增設備條件，但最終取消；不可將該嘗試記錄為已生效設定。實際關鍵字為 failed，不是 failure。

### 4.4 Action 共通參數與分類限制

Set field 的 prefix、suffix、default 保持空白，message 不另選，clean_field=false。填妥後須先按 Action 區塊的 Add，確認摘要出現，再儲存整條 Rule。

| 欄位 | 產生來源 | 已驗證值 |
| --- | --- | --- |
| source | Syslog 解析 | node10、node11、node12 |
| device_type | PVE 節點識別規則 | pve |
| pve_cluster | PVE 節點識別規則 | PVE-Cluster |
| event_category | 認證或系統錯誤規則 | authentication 或 system_error |

**分類限制：**認證與系統錯誤規則都寫入 event_category。若同一訊息同時包含 pam_unix 與 failed 等字詞，可能同時符合兩條規則；本次沒有完成衝突優先順序的設計或驗證，不以 Stage 0 清單顯示順序作為分類優先權。

## 5 Stage 0 掛載 SOP

1. 進入 System → Pipelines → Manage pipelines → Infrastructure Syslog。
2. 確認 Connected to Streams 為 Infrastructure Syslog。
3. 點選既有 Stage 0 的 Edit，Stage 維持 0。
4. Continue processing on next stage when 維持以下選項。

```text
At least one of the rules on this stage matches the message
```

5. 由 Stage rules → Select... 加入並核對下列三條規則。

```text
PVE - Identify Cluster Nodes
PVE-Authentication Events
Infrastructure - System Errors
```

6. 點選 Update stage，確認清單內無 renamed or removed 警告。
7. 送出新測試訊息，於 Search 展開 Fields 驗證。

**掛載注意：**建立 Rule 不等於已投入處理。認證 Rule 當次曾顯示 Pipelines=0，後續加入 Stage 0 才完成掛載。Rule 內的 AND／OR 與 Stage 的繼續處理選項屬不同設定，不應混為同一條件。既有三條規則目前全部位於 Stage 0，尚未改為多個 Stage。

## 6 實際 logger 測試與驗證

### 6.1 接收與自動轉送測試

Graylog 主機的本機 UDP Input 測試：

```bash
logger -n 127.0.0.1 -P 1514 -d -t GRAYLOG_TEST "Graylog UDP 1514 test message"
```

node10 直接送往 Graylog 的網路路徑測試：

```bash
logger -n 192.0.2.24 -P 1514 -d -t PVE_NODE10_TEST "PVE node10 to Graylog UDP test"
```

node11 與 node12 分別執行的自動轉送測試：

```bash
logger -t PVE_NODE11_TEST "node11 automatic rsyslog forwarding test"
```

```bash
logger -t PVE_NODE12_TEST "node12 automatic rsyslog forwarding test"
```

搜尋對應標籤後均有成功接收紀錄。node10 的直接 UDP 測試已確認 source=node10、Stored in index=infra_syslog_0、Routed into streams=Infrastructure Syslog。

**驗證注意：**帶 -n 的測試直接指定接收端，不能單獨證明本機 rsyslog 自動轉送成功。以下 Pipeline 測試不加 -n 或 -P，透過本機日誌路徑驗證自動轉送。logger 執行後沒有終端輸出是當次正常現象，最終成功仍以 Graylog 收到訊息與欄位結果判定。

### 6.2 PVE 識別測試

於 node10 執行：

```bash
logger -t PVE_PIPELINE_TEST "Graylog PVE pipeline field test"
```

Search 搜尋 PVE_PIPELINE_TEST，時間範圍選最近 15 分鐘。展開訊息已確認 source=node10、device_type=pve、pve_cluster=PVE-Cluster，Input 為 Syslog UDP 1514、Stream 為 Infrastructure Syslog、Index 為 infra_syslog_0。

後續使用以下兩個查詢，時間範圍 Last 1 hour，均已找到三台節點的真實日誌：

```text
device_type:pve
```

```text
pve_cluster:"PVE-Cluster"
```

### 6.3 認證事件測試

於 node10 執行：

```bash
logger -p auth.info -t pam_unix "Graylog authentication pipeline test"
```

於 Search 使用完整片語搜尋，時間範圍 Last 15 minutes：

```text
"Graylog authentication pipeline test"
```

當次找到 1 筆，message 為 node10 pam_unix: Graylog authentication pipeline test。展開後確認 source=node10、facility=security/authorization、device_type=pve、pve_cluster=PVE-Cluster、event_category=authentication。

### 6.4 系統錯誤規則初次測試

於 node10 執行：

```bash
logger -p kern.warning -t PVE_SYSTEM_TEST "DENIED Graylog PVE system error pipeline test"
```

```text
"Graylog PVE system error pipeline test"
```

搜尋並展開訊息，已確認 source=node10、device_type=pve、pve_cluster=PVE-Cluster、event_category=system_error；訊息進入 Infrastructure Syslog 與 infra_syslog_0。

### 6.5 改名與重新掛載後複測

於 node10 執行：

```bash
logger -p kern.warning -t INFRA_ERROR_TEST "DENIED Graylog infrastructure system error test"
```

```text
"Graylog infrastructure system error test"
```

已確認以下訊息與欄位：

```text
message = node10 INFRA_ERROR_TEST: DENIED Graylog infrastructure system error test
source = node10
device_type = pve
pve_cluster = PVE-Cluster
event_category = system_error
Stored in index = infra_syslog_0
Routed into = Infrastructure Syslog
```

**測試覆蓋注意：**兩筆系統錯誤測試文字同時含 DENIED 與 error，因此證明整條規則可生效，但不構成三個 OR 分支各自獨立的測試。認證測試亦未單獨驗證 cron 排除分支；這些可列為後續補測。

## 7 故障排除與處理紀錄

### 7.1 Rule 改名後 Stage 關聯失效

事件經過：系統錯誤規則改名並儲存後，Stage 0 仍指向舊名稱。當次畫面出現：

```text
Rule PVE - System Errors has been renamed or removed. This rule will be skipped.
```

該警告表示此 Stage 中的舊參照會被略過。本次實際結果顯示，僅更新 Rule 名稱不足以完成 Stage 參照更新；不能以原先「改名應保留關聯」的預期代替檢查。

處理程序：

1. 開啟 Infrastructure Syslog Pipeline → Stage 0 → Edit。
2. Remove 舊的失效規則參照 PVE - System Errors。
3. 由 Select... 選入 Infrastructure - System Errors。
4. 保留前兩條規則及 At least one... 選項，按 Update stage。
5. 確认不再出現 renamed or removed，執行第 6.5 節的新訊息複測。

處理結果：複測訊息仍具有 PVE 標籤與 event_category=system_error，且 Stream、Index 均正確，故本次故障已完成修復。

### 7.2 Then Action 未儲存

認證 Rule 曾顯示建立成功，但重新開啟後 Then 為空。處理方式為重新加入 Set field，填入 event_category 與 authentication，先按區塊內 Add，看到 Set 'authentication' to field 'event_category' 後再按 Update rule & close，後續完成掛載及實測。

### 7.3 搜尋結果混入其他 system 訊息

未將測試片語加上雙引號時，結果曾出現其他 systemd 訊息。處理方式為使用第 6 節的完整雙引號片語，並點開真正的測試訊息核對 source 與 Fields，不只查看搜尋結果筆數。

### 7.4 Rule Builder 條件操作

Field equals 為當次介面的正式選項名稱。條件旁顯示 Not 按鈕，不代表該條件已啟用反向；認證規則僅 cron 條件啟用 NOT。系統錯誤規則未將 device_type=pve 放入 OR 同層，避免把所有 PVE 訊息都當成錯誤。

## 8 完成狀態與維運驗收

| 項目 | 狀態與證據 |
| --- | --- |
| UDP Input、Stream 與 Index | 已完成；測試訊息接收、路由及寫入驗證成功 |
| 三台 PVE 自動收集 | 已完成；三台均持續傳入真實系統日誌 |
| PVE 節點識別 | 已完成；兩個自訂欄位查詢均找到三台節點 |
| Authentication 分類 | 已完成；node10 測試產生 authentication |
| System Errors 分類 | 已完成；初次測試與改名後複測成功 |
| Stage 0 規則掛載 | 已完成；三條自訂規則，失效參照已替換 |
| 多 Stage 與分類優先權 | 尚未完成 |
| 服務欄位與服務事件分類 | 尚未完成 |
| NAS、Switch、Dashboard、Alert | 尚未完成 |

維運檢查時，先查看 Input 與 rsyslog 服務狀態，再以最近 5 分鐘或適當時窗分別搜尋 source:node10、source:node11、source:node12。若無結果，先確認所選 Stream、時間範圍及新訊息是否已產生。

每次修改 Rule 名稱、條件、Action 或 Stage 掛載後，都應重新發送測試訊息並保存 Message Details。當次 0 errors/s 等畫面數值只代表觀察時點，不代替持續監控，也不能單憑沒有處理錯誤就判定分類正確。

## 9 後續規劃

1. 設計 Stage 分層：先完成設備識別，再安排事件分類，正式調整前確認欄位相依性與分類優先權。
2. 新增 PVE／Linux 服務事件分類，評估 Started、Stopped、Starting、Stopping 等訊息；Failed 與既有系統錯誤條件重疊，須先處理 event_category 衝突。
3. 補做各錯誤關鍵字、CRON 排除與多規則同時命中的測試，並檢討認證規則的設備範圍。
4. 規劃 service、log_message 等欄位拆分，再逐步納入 Synology 與 TP-Link Switch，逐設備驗證格式與分類。
5. 依實際日誌量檢討保留時間與儲存容量，再建置 Dashboard、Alert；AppArmor DENIED 的原因分析與處置另案進行。

## 10 紀錄來源與修訂

來源為 2026 年 9 月 16 日「手把手安裝Graylog Server」對話的操作指令、終端輸出及當次畫面確認紀錄。

版本 1.0 彙整收集設定、三條自訂規則、Stage 0 掛載、測試驗證、改名故障排除與未完成事項。後續變更應另記錄日期、操作者、修改內容與重新驗證結果。
