---
layout: default
title: "圖書館 Nebula 網路改造：VLAN 隔離讀者、CIP 過濾、兩條 FTTB 分流"
permalink: /docs/network/zyxel-nebula-library-vlan-dual-wan-plan/
date: 2026-10-20
categories: [Network, VLAN, Zyxel, Nebula, Dual WAN]
last_modified_at: 2026-10-22
---

# 圖書館 Nebula 網路改造：VLAN 隔離讀者、CIP 過濾、兩條 FTTB 分流

> **一句話**：館員和讀者原本共用一個 SSID、一個 /24 網段，讀者看得到館內設備，而且原本設定的上網過濾其實沒有生效。這次把網路切成四個網段：館員有線、館員無線、讀者有線、讀者無線，每段各有一個 VLAN；再用安全政策擋住讀者連館員網段、讓讀者一律套用 CIP 過濾，最後用 Policy Route 讓館員和讀者各走一條 FTTB。

| 項目 | 內容 |
| --- | --- |
| 適合誰看 | 公共場所（圖書館、活動中心）同時有內部人員與訪客上網、想把兩邊分開的人；第一次在 Nebula 設定 VLAN、搞不懂 Trunk／Access／PVID 的人 |
| 環境 | USG FLEX 100H ×1、XGS2220 ×1（核心）、GS1920 ×3（1F～3F 各一台）、NWA90AX ×9（每層 3 台），全部由 Nebula 管理（Nebula 版本 20.20）；FTTB ×2 |
| 日期 | 2026-10-20 規劃；2026-10-21～22 實作 |
| 資料來源 | 現場設定與驗收結果；設定觀念參考 Zyxel 台灣社群官方教學（見第 11 節） |
| 結論 | ✅ 館員無線、讀者無線分 VLAN 並完成分流；✅ 出口對調（館員走 WAN B、讀者走 WAN A）並驗收；✅ 讀者 CIP 過濾、讀者禁止連館員網段的安全政策已啟用；✅ 10 台讀者有線電腦全部搬到 VLAN 90，過渡用的規則、綁定、物件已清除；⏳ 現場驗收（櫃台作業、讀者手機與電腦的外網 IP／過濾／隔離）、Layer 2 isolation、授權到期影響待確認 |

## 1. 先認識幾個名詞

| 名詞 | 白話解釋 |
| --- | --- |
| **VLAN** | 在同一套實體交換器上切出好幾個「虛擬的獨立網路」，彼此預設不互通 |
| **802.1Q／VLAN Tag** | VLAN 的國際標準：在乙太網路幀（Frame）裡插入一個「我屬於哪個 VLAN」的標籤 |
| **Tagged／Untagged** | 帶有 VLAN 標籤的幀叫 Tagged；沒有標籤的叫 Untagged。電腦、印表機送出來的幀都是 Untagged |
| **PVID**（Port VLAN ID） | 埠的「預設 VLAN」。像在埠上裝一台**標籤機**：沒貼標籤的幀進來，就自動貼上 PVID 指定的標籤 |
| **Access 模式** | 給「終端設備」（電腦、印表機）用的埠：進來的幀貼上 PVID 標籤，送出去前把標籤撕掉 |
| **Trunk 模式** | 給「中繼設備」（防火牆、交換器、AP）用的埠：一條線同時跑多個 VLAN，幀離開時保留標籤 |
| **允許的 VLANs**（Allowed VLANs） | 只有 Trunk 有：這個埠放行哪些 VLAN 的通行清單，預設「全部（All）」 |
| **VLAN 介面** | 防火牆上代表一個網段的「虛擬網卡」：有自己的 IP（當預設閘道）和 DHCP |
| **Zone** | 防火牆把介面分組（LAN、WAN、DMZ…），安全政策用「從哪個 Zone 到哪個 Zone」來寫規則 |
| **SSID** | 無線網路的名稱。一台 AP 可以同時廣播好幾個 SSID，每個 SSID 對應一個 VLAN |
| **FTTB／WAN** | 光纖到大樓的固定制網路；防火牆接網際網路的那一側叫 WAN，本案兩條 FTTB＝兩個 WAN |
| **Policy Route**（政策路由） | 依「從哪裡進來、誰送的」決定走哪條 WAN |
| **SNAT** | 封包出去時把來源改成 WAN 的外網 IP，本案設為 Outgoing interface（用出去那條線的 IP） |
| **安全政策**（Security policy） | 防火牆的放行／拒絕規則，**由上往下比對，第一條符合的就生效** |
| **CIP** | 本案防火牆上的內容過濾設定檔名稱，套用在讀者上網流量（推測為兒少上網保護類的過濾，未向原廠確認） |
| **位址物件／服務物件** | 把 IP 範圍、網段、服務埠先取好名字，規則裡直接選名字，不必每次手打 |

## 2. VLAN 怎麼運作：貼標籤、撕標籤

```text
【Access 埠】接讀者電腦（PVID 90）

  電腦 ──(Untagged)──▶ 進入埠：貼上 VLAN 90 標籤 ──▶ 交換器內部（VLAN 90）
  電腦 ◀─(Untagged)─── 送出埠：撕掉標籤          ◀── 交換器內部（VLAN 90）
  ※ 收到「已帶標籤」的幀 → 直接丟棄

【Trunk 埠】接 AP 或上一層交換器（PVID 1，允許 All）

  VLAN 80／90／110 的幀 ──▶ 保留標籤（Tagged）通過
  VLAN 1 的幀           ──▶ 撕掉標籤（Untagged）送出，因為 VLAN 1 = PVID
  對方送來的 Untagged 幀  ─▶ 視為 VLAN 1
```

> **口訣**：後面還會再接東西的 → Trunk；後面不會再接東西的 → Access。最常見的錯誤，就是把接防火牆、AP 的埠誤設成 Access，其他 VLAN 的流量就全被擋掉。

## 3. 改造前的現況與問題

```text
              WAN A（FTTB）    WAN B（FTTB）
                ge1 \            / ge2
                   USG FLEX 100H        ← LAN1（ge3，實體埠 p3）：館員有線網段 /24
                         │
                   Core-XGS2220（核心）
           ┌─────────────┼─────────────┐
       1F-GS1920     2F-GS1920     3F-GS1920
       AP01～03       AP01～03      AP01～03     ← NWA90AX ×9
         （每層 3 台；SSID：<讀者 SSID>，館員與讀者共用）
```

| 項目 | 現況 |
| --- | --- |
| 兩條 FTTB 分工 | Policy Route 兩條：Incoming `ge3`＋來源物件「館員電腦群組」→ ge1；「讀者電腦範圍」→ ge2 |
| 有線電腦 | 館員電腦約 12 台＋館員用公用電腦 4 台；讀者電腦 10 台（兒童區、成人區、櫃台），全部在同一個 /24，用 MAC 綁 IP |
| DNS | 防火牆 DHCP 發給用戶端的 DNS 是中華電信資安艦隊專用 DNS（見[這篇](../cht-security-fleet-dns-filtering/)），兩條線都能使用 |

| 問題 | 說明 |
| --- | --- |
| 讀者無線和館內設備同網段 | 連 Wi-Fi 的讀者可以直接掃描、存取館內電腦、印表機 |
| 讀者電腦和館員電腦同網段 | 公用電腦誰都能操作，卻可以直接存取館員電腦 |
| **讀者的上網過濾沒有生效** | 安全政策裡為讀者套用 CIP 的規則，排在「LAN 全部放行」規則的**後面**，而且比對條件完全一樣，所以從來沒有被比對到（見 5-6） |
| IP 不夠用 | /24 只有 254 個 IP，要給網路設備、館內電腦和所有讀者手機 |

## 4. 目標架構

```text
             WAN A（ge1）──────┐        ┌──────── WAN B（ge2）
               讀者出口         │        │         館員出口
                          USG FLEX 100H（p3）
     LAN1（VLAN 1，不帶標籤）＋ vlan110 ＋ vlan80 ＋ vlan90（Zone 都是 LAN）
                                │ Trunk：PVID 1，允許 All
                          Core-XGS2220
                                │ Trunk
                    1F／2F／3F-GS1920（各 1 台）
                 ┌──────────────┴──────────────┐
                 │ Trunk                        │ Access：PVID 90
       每層 AP01～AP03（共 9 台）           讀者有線電腦
          ┌──────────┴──────────┐
  <館員 SSID>（VLAN 110）  <讀者 SSID>（VLAN 80）
     館員手機上網              讀者 Wi-Fi
```

| 使用者 | VLAN | 網段大小 | DHCP 租約 | 出口 | CIP 過濾 |
| --- | --- | --- | --- | --- | --- |
| 館員有線（含網路設備管理） | 1（不變） | /24 | 7 天（維持） | WAN B | 不過濾 |
| 館員無線（只給館員手機上網） | 110 | /24 | 7 天 | WAN B | 不過濾 |
| 讀者無線 | 80 | /24 | 8 小時 | WAN A | **過濾** |
| 讀者有線（兒童區、成人區、櫃台） | 90 | /24 | 1 天 | WAN A | **過濾** |

| 設計決定 | 為什麼 |
| --- | --- |
| VLAN ID 用網段的第三碼 | 看 IP 就知道屬於哪個 VLAN |
| 館員有線網段**不動** | 防火牆、交換器、AP 的管理 IP 和館員電腦都不用重設，改錯也不會讓設備從 Nebula 離線 |
| 多開一個館員 SSID，不用 DPPSK | DPPSK 需要 Nebula Pro Pack 授權，Zyxel 社群列出的支援清單**沒有 NWA90AX**（未向原廠確認） |
| 讀者無線租約 8 小時 | 原廠建議訪客網段 8 小時，避免 Pool 被已經離開的手機占住 |
| 櫃台電腦歸類為讀者電腦 | 案主決定。櫃台和讀者公用電腦同一個 VLAN、可以互連 |
| 最初規劃館員走 WAN A、讀者走 WAN B | 實作當天案主改為**對調**（見 5-8） |

## 5. 實作過程（第一階段：無線與安全政策）

| 步驟 | 做什麼 | 影響 | 結果 |
| --- | --- | --- | --- |
| 5-1 | 防火牆新增 `vlan110`、`vlan80` | 無 | ✅ |
| 5-2 | 確認交換器 Trunk 埠 | 無 | ✅ 16 個埠都是預設值，不用改 |
| 5-3 | 新增館員 SSID（VLAN 110） | 無 | ✅ |
| 5-4 | Policy Route：`vlan110`、`vlan80` | 無 | ✅ |
| 5-5 | 建位址物件、服務群組 | 無 | ✅ |
| 5-6 | 安全政策：新增 3 條（先不啟用）→ 排序 → 逐條啟用 | 讀者開始被過濾 | ✅ |
| 5-7 | 讀者 SSID 改到 VLAN 80 | 讀者斷線重連 | ✅ 讀者手機取得 VLAN 80 的 IP |
| 5-8 | 出口對調 | 短暫 | ✅ |

### 5-1 防火牆新增 VLAN 介面

做什麼：每個 VLAN 都要在防火牆有一個介面，當作該網段的預設閘道並發 DHCP。

怎麼做：**Configure → Firewall → Port & Interface**，新增 VLAN 介面：

| 欄位 | 填法 | 說明 |
| --- | --- | --- |
| Interface name | `vlan110`、`vlan80` | 只能英數，**存檔後不能改名** |
| Type／Member type | VLAN／Port | |
| **Members** | **只選接核心交換器的那個實體埠（本案 `p3`）** | 預設會帶入全部 LAN 埠；到埠狀態看哪個埠連線中 |
| **Zone** | **LAN** | 選單只有 None／WAN／LAN／DMZ／VPN 類，沒有 Guest。留 None 推測會沒有任何規則放行（未確認）；DMZ 的預設政策不確定會不會擋 DNS，所以選 LAN，隔離改用安全政策 |
| VLAN ID | `110`、`80` | |
| IPv4 address/Network Mask | 網段的 `.254/24` | |
| DHCP | DHCP server，Start IP `.1`、Pool size `240` | 發放 `.1～.240`，不會包到閘道 `.254` |
| First DNS server | 跟 LAN1 一樣 | 本案為資安艦隊 DNS；確認讀者電腦原本走另一條線也能用這組 DNS，才沿用 |
| Lease time | 館員 7 天、讀者 8 小時 | **任何情況都不要設「無限」** |
| Connectivity check／MAC／MTU | 預設 | |

> ⚠️ **不要動 LAN1 的 VLAN ID**：LAN1 要保持空白（不帶標籤），正好對上交換器 Trunk 埠的 PVID 1。

### 5-2 確認交換器 Trunk 埠

做什麼：VLAN 要從防火牆一路通到 AP，中間每個埠都要放行。

怎麼做：**Switch → Configure → Switch ports**，逐台看防火牆↔核心、核心↔三台樓層交換器、樓層交換器↔9 台 AP 兩端的埠。

結果：16 個埠都是預設的 **Trunk／PVID 1／Allowed VLANs All**，**不用改**。

> 先從 Nebula 拓撲圖確認設備連接關係，再請現場提供埠號，做成接線對照表。注意各樓層交換器的上行埠不一定一樣（本案 2F 是 26，1F、3F 是 25）。

### 5-3 新增館員 SSID

怎麼做：**Configure → Access point → SSID settings**，打開 **Advanced mode** → **+ Add SSID network** → **Edit**：

| 欄位 | 填法 | 說明 |
| --- | --- | --- |
| Security options | **WPA Personal With WPA2**，填強密碼 | ⚠️ **新 SSID 預設是 Open**，一定要改 |
| Sign-in method | Disabled | |
| Forwarding mode | **Local bridge** | 選 NAT mode 的話 AP 會自己發 IP，VLAN 和防火牆分流都不會生效 |
| **VLAN ID** | **`110`** | 在頁面最下方 Advanced settings，預設是 `1` |
| Band mode、802.11r 等 | 跟讀者 SSID 一樣 | |
| Layer 2 isolation、Intra-BSS | 關 | 館員可能要連館內設備 |

改完按 **Back**。畫面會顯示「Please allow 1-2 minutes for changes to take effect」。

結果：手機連上取得 VLAN 110 的 IP（`.2`）。

> 館員電腦全部是有線的，館員 SSID 只給館員手機上網，所以**不需要做列印測試**，讀者 SSID 搬家也不會影響館員作業。

### 5-4 Policy Route

怎麼做：**Configure → Firewall → Routing** → Policy route → **+ Add**：

| 欄位 | 館員無線 | 讀者無線 |
| --- | --- | --- |
| Incoming | Interface → `vlan110` | Interface → `vlan80` |
| Source／Destination／Service | Any | Any |
| Next Hop | Type **Interface** → WAN B | Type **Interface** → WAN A |
| SNAT address | Outgoing interface | Outgoing interface |
| Disable policy route automatically while Interface link down | **開** | **開** |
| Enable Connectivity Check | 先關 | 先關 |

> 現有的有線規則 Incoming 都是 `ge3`，新 VLAN 從 `vlan110`／`vlan80` 進來，**不會被現有規則抓到**，所以只要新增，不必改舊的。
>
> Next Hop 的 Type 預設是 `Auto`（依路由表），要改成 Interface 才能指定 WAN。Next Hop 選單裡每個 WAN 旁邊顯示的編號，是在介面說明裡填的**電路編號**，報修時很方便。

結果：手機連館員 SSID，查外網 IP 是預期的那條線。

### 5-5 位址物件與服務群組

怎麼做：**Configure → Firewall → Object**，分頁 **Address**、**Service**：

| 物件 | 類型 | 內容 |
| --- | --- | --- |
| `Reader_WiFi_Net` | **Interface subnet** | `vlan80` |
| `Staff_WiFi_Net` | **Interface subnet** | `vlan110` |
| `Reader_PC_Net` | Subnet | 讀者有線網段 /24 |
| `Reader_All`（群組） | | `Reader_WiFi_Net`、`Reader_PC_Net`（過渡期另含舊的讀者電腦範圍，搬完後移除，見 6-5） |
| `Staff_Net`（群組） | | `LAN1_SUBNET`、`Staff_WiFi_Net` |
| `Mgmt_Service_Group`（服務群組） | | HTTP、HTTPS、SSH-TCP |

> **Interface subnet** 會自動等於該介面的網段，介面 IP 改了物件也跟著變，不用手打。
>
> 另外建新群組 `Reader_All`，而不是把成員加進現有的讀者群組，因為不確定現有群組還被哪些設定使用。
>
> 安全政策的 Service 欄位**一次只能選一個**，要擋多個服務就先建服務群組。

### 5-6 安全政策

**先發現的問題**：**Configure → Firewall → Security policy** 的現況是這樣：

| # | Name | Action | 設定檔 | From → To | Source |
| --- | --- | --- | --- | --- | --- |
| 1 | LAN_Outgoing | Allow | — | LAN → Any (Excluding ZyWALL) | Any |
| 2 | Reader_PC_Policy | Allow | default_profile、CIP | LAN → Any (Excluding ZyWALL) | **Any** |

兩條的比對條件**完全一樣**，規則 1 排在前面，所以所有 LAN 流量在規則 1 就被放行了，**讀者電腦其實從來沒有被 CIP 過濾**。案主確認讀者（有線＋無線）都要過濾。

**做法**：policy 的名稱存檔後**不能修改**，所以不改舊規則，改成「新增 → 排序 → 逐條啟用 → 停用舊的」：

| 順序 | Name | Action | 設定檔 | From → To | Source | Destination | Service |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 1 | Reader_to_Staff_Deny | Deny | — | LAN → LAN | `Reader_All` | `Staff_Net` | Any |
| 2 | Reader_to_Device_Deny | Deny | — | LAN → ZyWALL | `Reader_All` | Any | `Mgmt_Service_Group` |
| 3 | Reader_CIP_Outgoing | Allow | default_profile、CIP | LAN → Any (Excluding ZyWALL) | `Reader_All` | Any | Any |
| 4 | LAN_Outgoing | Allow | — | LAN → Any (Excluding ZyWALL) | Any | Any | Any |
| 5 | Reader_PC_Policy | **停用** | | | | | |

| 步驟 | 動作 | 影響 |
| --- | --- | --- |
| ① | 新增 3 條，**Enabled 不勾**，拖到最上面 → Save | 無 |
| ② | 勾選第 3 條 → Save | ⚠️ 讀者電腦立刻開始被過濾，要選閉館時段 |
| ③ | 勾選第 1、2 條 → Save | 無 |
| ④ | 取消勾選舊的 `Reader_PC_Policy` | 無（它本來就沒作用） |

> **為什麼第 2 條只擋管理服務、不擋 Any**：讀者要靠防火牆拿 DHCP，全擋可能連 DHCP 都擋掉（未確認），讀者會連上 Wi-Fi 卻拿不到 IP。
>
> 最右邊的 **Log** 開關可以記錄比對到的流量，新規則建議開啟，之後要查「誰被擋了」會用到。

### 5-7 讀者 SSID 改到 VLAN 80

怎麼做：編輯讀者 SSID：

| 欄位 | 改成 |
| --- | --- |
| VLAN ID | `1` → **`80`** |
| **Intra-BSS traffic blocking** | **開**（同一台 AP 下的手機彼此看不到） |
| Layer 2 isolation | 先關（原因見下方） |

> **Layer 2 isolation 要填白名單**：打開後會要求「至少填入閘道的 MAC 位址」，否則手機連閘道都碰不到、無法上網。查閘道 MAC 要另外處理，所以先用不需要 MAC 的 Intra-BSS，Layer 2 isolation 列為待辦。

結果：Nebula **Clients** 頁面上，在線的讀者手機都已取得 VLAN 80 的 IP（`.2`～`.8`）。

> ⚠️ 讀者 SSID 原本只勾 5 GHz（6 GHz 這款 AP 用不到），只支援 2.4 GHz 的舊設備連不上。這是原本就有的設定，這次沒有改動。

### 5-8 出口對調

案主在實作當天決定：館員改走 WAN B、讀者改走 WAN A。

| 規則 | 做法 |
| --- | --- |
| 無線兩條 | 直接編輯 Next Hop，Description 一起更新 |
| 有線兩條 | 舊規則名稱裡寫了外網 IP，而且名稱不能改，所以**另外新增**兩條新規則 |

> **Policy route 不能拖曳排序**：新規則排在舊規則後面、條件又一樣，就不會生效。做法是把舊規則停用或刪除，流量就會往下比對到新規則。本案直接刪除舊規則，所以還原方式改成「編輯新規則的 Next Hop」。

對調後的 Policy route：

| # | 規則 | Incoming | Source | Next Hop |
| --- | --- | --- | --- | --- |
| 1 | Librarian_WiFi_SNAT | vlan110 | Any | WAN B |
| 2 | Reader_WiFi_SNAT | vlan80 | Any | WAN A |
| 3 | Staff_PC_SNAT_WAN2 | ge3 | 館員電腦群組 | WAN B |
| 4 | Reader_PC_SNAT_WAN1 | ge3 | 讀者電腦群組 | WAN A（過渡用，讀者電腦搬完後已刪除，見 6-5） |
| 5 | Reader_PC_VLAN90_SNAT | vlan90 | Any | WAN A（第二階段新增） |

> ⚠️ **出口一換，依外網 IP 設白名單的外部系統都會連不上**。對調前要先問案主或系統廠商：哪些系統只允許某個 IP 連線。

### 5-9 驗收

| 用哪台 | 應該看到 | 結果 |
| --- | --- | --- |
| 館員有線電腦 | 外網 IP＝WAN B | ✅ |
| 館員公用電腦 | 外網 IP＝WAN B | ✅ |
| 館員手機（館員 SSID） | 外網 IP＝WAN B | ✅ |
| 讀者有線電腦（搬遷前） | 外網 IP＝WAN A | ✅ |
| 櫃台電腦館務系統（搬遷前） | 正常 | ✅ |
| 讀者手機（讀者 SSID） | 取得 VLAN 80 的 IP | ✅ |
| 讀者手機 | 外網 IP＝WAN A、連不到館內、不當網站被擋 | ⏳ 現場驗收中 |

## 6. 第二階段：讀者有線電腦搬到 VLAN 90

### 6-1 找出讀者電腦接在哪個埠

做什麼：要改交換器的埠，就要知道每台電腦接在哪台交換器的哪個埠。

怎麼做：Nebula 左側 **Clients**。點進單台可以看到 **Connected to**（交換器）和 **Port**，下方的 Current client connection 會畫出「電腦 → 埠 → 交換器 → 核心 → 防火牆」整條路徑。列表頁直接顯示所有有線、無線設備最近 24 小時的連線，用 MAC 前幾碼搜尋最快。

| 發現 | 怎麼處理 |
| --- | --- |
| 同一個埠出現好幾台設備 | 推測下面接了小型交換器。**整個埠會一起被搬**，改之前要到現場確認下面只接了讀者電腦 |
| 館員電腦和印表機共用的埠 | **絕對不能改** |
| Nebula 裡的用戶端名稱和 DHCP 表的名稱不一致（例如「公用電腦」其實是館員用） | 先跟案主確認用途，再決定搬不搬 |
| 24 小時內沒上線的電腦 | 列表裡看不到，要等開機或到現場查 |

### 6-2 防火牆新增 `vlan90`

做法同 5-1，另外在 **Static DHCP table** 加上 10 台讀者電腦：

| 欄位 | 填法 |
| --- | --- |
| Hostname | 沿用原本的電腦名稱 |
| IP address | **最後一碼沿用舊的**（例如原本 `.41`，新網段也用 `.41`），方便對照 |
| MAC address | 從 LAN1 的 Static DHCP table 照抄，**逐筆核對最後兩碼**（同一批電腦 MAC 前段都一樣，很容易打錯） |

> 還不知道接在哪個埠的電腦，**綁定也可以先建**。綁定只看 MAC，之後埠一改就會拿到對的 IP。
>
> LAN1 裡的舊綁定在搬遷期間先留著，萬一要還原才有依據；全部搬完後再刪（見 6-5）。

接著新增 Policy route `Reader_PC_VLAN90_SNAT`（Incoming `vlan90` → WAN A），做法同 5-4。

### 6-3 改交換器的埠

怎麼做：**Switch → Configure → Switch ports** → 勾選該埠 → **Edit**：

| 欄位 | 改成 |
| --- | --- |
| Type | **Access** |
| PVID | **`90`** |
| VLAN type | None |
| 其他 | 維持預設 |

> ⚠️ **遠端改埠的陷阱**：只改 PVID 不會讓網路線斷線，**開著的電腦會繼續用舊 IP**，在新 VLAN 裡等於斷網，要等 DHCP 租約更新才會恢復（舊網段租約 7 天）。解法：把該埠的 **Port enabled** 改 Disabled → Update → 等 1 分鐘 → 改回 Enabled → Update，Windows 會以為網路線被拔插，自動重新要 IP。關機中的電腦則在下次開機時就會拿到新 IP。
>
> 埠名稱維持預設，不寫電腦名稱：用戶端設備會更換，埠名寫死某台電腦反而容易誤導。

### 6-4 搬遷結果

| 區域 | 接在 | 台數 | 結果 |
| --- | --- | --- | --- |
| 櫃台 | 1F 第 19 埠 | 1 | ✅ 取得 VLAN 90 指定 IP；⏳ 館務系統、列印待櫃台確認 |
| 兒童區 | 1F 第 10 埠 | 1 | ✅ 取得 VLAN 90 指定 IP |
| 兒童區 | 1F 第 11 埠（下接小交換器） | 3 | ✅ 開館開機後取得 VLAN 90 指定 IP |
| 成人區 | 2F 第 1～5 埠（每埠一台） | 5 | ✅ 改埠、斷線再接上後取得 VLAN 90 指定 IP |

> 成人區電腦前一天沒開機，Clients 列表看不到；隔天開館開機後才查出它們在 **2F**，不在 1F。**沒上線的設備，Clients 查不到埠號**，要等開機或到現場查。
>
> 關機中的電腦，改完埠後下次開機就會直接拿到新 IP；開著的電腦要做「斷線再接上」。
>
> Nebula Clients 的名稱跟防火牆 Static DHCP table 的 Hostname **是各自獨立的**，不會自動同步。沒有名稱的用戶端會直接顯示 MAC，要到 Clients 點進該設備、按標題旁的 ✏️ 手動改名。

**還原**：該埠改回 **PVID `1`**，再做一次斷線再接上。⚠️ 舊網段的綁定已刪除（見 6-5），還原前要先把那台的綁定加回舊網段，否則會拿到隨機 IP，不會被當成讀者。

### 6-5 收尾：清掉過渡期的設定

讀者電腦全部搬完、確認都拿到新 IP 後，把過渡期留下的東西清掉：

| 項目 | 做法 | 為什麼 |
| --- | --- | --- |
| 舊網段裡讀者電腦的 10 筆綁定 | LAN1 → Static DHCP table 刪除 | 免得之後忘記；只保留館員電腦、印表機的綁定 |
| `Reader_PC_SNAT_WAN1` | Routing 刪除 | 讀者電腦都離開舊網段，這條已經沒有流量 |
| **`Reader_All` 移除舊的讀者電腦範圍** | Object → Address group | **一定要做**：舊網段的 DHCP 發放範圍包含這段 IP，綁定刪掉後這些 IP 會被發給其他設備，那些設備會被誤判成讀者（被過濾、連不到防火牆管理頁） |
| 舊的讀者範圍物件、讀者群組物件 | Object 刪除 | 已經沒有規則使用（Nebula 允許刪除，就代表沒有被引用） |

清完之後，`Reader_All` 只剩兩個以 **VLAN** 劃分的成員（讀者無線、讀者有線），不再依賴舊網段的 IP 範圍。Policy route 也剩下 4 條，每一類使用者各一條：

| 規則 | 誰 | 出口 |
| --- | --- | --- |
| Librarian_WiFi_SNAT | 館員無線（vlan110） | WAN B |
| Reader_WiFi_SNAT | 讀者無線（vlan80） | WAN A |
| Staff_PC_SNAT_WAN2 | 館員有線（ge3＋館員電腦群組） | WAN B |
| Reader_PC_VLAN90_SNAT | 讀者有線（vlan90） | WAN A |

### 6-6 補齊館員網段的綁定

做什麼：館員網段裡還有幾台設備沒有 MAC 綁定，IP 可能會變。

| 設備 | 原本 | 處理 |
| --- | --- | --- |
| 1F 印表機 | DHCP 自動發的 IP | 加綁定，**沿用現在的 IP**，各電腦的印表機設定都不用改 |
| 館員公用電腦（固定 IP 設在電腦本身，在 DHCP 範圍外） | 不在綁定表 | 加綁定，跟防火牆的位址物件同一個 IP |
| 2F 事務機 | Clients 頁面看不到 IP，推測在機器上手動設定 | ⏳ 查出 IP 後加綁定 |

> 手動設定 IP 的設備也建議加進綁定表：如果那個 IP 落在 DHCP 發放範圍內，加綁定等於「預約」，DHCP 就不會再把它發給別人，避免 IP 衝突。
>
> 用途不明的設備**不要綁**，等查清楚再說。

## 7. 還沒確認的地方

| 項目 | 說明 |
| --- | --- |
| 讀者手機的完整驗收 | 外網 IP、連不到館內、不當網站被擋，要現場用手機測 |
| 櫃台電腦搬到 VLAN 90 後的館務系統與列印 | 如果需要連館員網段的伺服器或印表機，會被 `Reader_to_Staff_Deny` 擋住，要在它上方加例外規則 |
| **Nebula Pro Pack 試用到期** | 安全政策頁面的 Application Patrol／Content Filter 欄位有鑽石圖示（授權功能），畫面顯示 Pro Pack 試用 30 天後到期。CIP 過濾靠的是 Pro Pack 還是防火牆本身的安全服務授權，**未確認**，要到 License & inventory 查 |
| 單線斷線時的切換 | 已開啟「Interface link down 時自動停用規則」，停用後流量走預設路由；預設路由走哪條線、實際切換效果未實測 |
| Connectivity Check | FTTB 常見「燈號正常但對外不通」，只有 Connectivity Check 抓得到；目前先關，避免偵測對象選錯造成誤停用 |
| 不在館員群組的有線設備 | 舊網段裡不在館員群組的設備（印表機、事務機、用途不明的設備）走預設路由；可考慮把館員有線規則的 Source 改成 Any，讓舊網段全部走 WAN B |
| 館員網段與網路設備管理共用 VLAN 1 | 這次刻意不動舊網段以降低風險；業界常見把網路設備管理獨立成一個 VLAN，列為日後選項 |

## 8. 常見問題

| 現象 | 怎麼辦 |
| --- | --- |
| 新 SSID 存檔後是開放網路 | 新 SSID 的 Security options 預設是 **Open**，一定要改成 WPA Personal |
| SSID 設了 VLAN ID 卻沒生效 | 確認有按 Back／Save；VLAN ID 在 SSID 編輯頁最下方的 Advanced settings |
| VLAN 介面的 Members 預設帶入全部 LAN 埠 | 只留接核心交換器的那個埠 |
| 讀者連上 Wi-Fi 卻拿不到 IP | 檢查：接 AP 的埠是否 Trunk、允許清單有沒有這個 VLAN、防火牆 VLAN 介面的 DHCP |
| 打開 Layer 2 isolation 後要求填 MAC | 那是白名單，至少要填閘道 MAC，否則無法上網；不想填就先改用 Intra-BSS traffic blocking |
| 為讀者套用過濾的規則沒效果 | 安全政策由上往下比對，條件相同時排在後面的永遠比對不到；把它拖到「LAN 全部放行」上面，或把 Source 改成讀者物件 |
| 安全政策或 Policy route 名稱打錯、想改 | 名稱存檔後不能改，只能新增一條、再停用或刪除舊的 |
| Policy route 拖不動 | 停用或刪除排在前面、條件相同的舊規則 |
| Service 欄位只能選一個服務 | 先在 Object → Service 建服務群組 |
| 改了交換器埠的 PVID，電腦還是舊 IP、不能上網 | 把該埠 Port enabled 關掉再打開，或請現場重開機 |
| 出口對調後某個系統連不上 | 那個系統可能只允許舊的外網 IP；請廠商加白名單，或為該系統另外加一條指定 Destination 的 Policy route |
| Clients 列表只顯示 MAC、沒有電腦名稱 | Clients 名稱與 DHCP 綁定表的 Hostname 不同步，點進設備按 ✏️ 手動改名 |
| 找不到某台電腦接在哪個埠 | Clients 只列出最近有上線的設備；請現場開機後再查 |
| 一個交換器埠出現好幾台設備 | 下面接了小型交換器，改 VLAN 會整個埠一起搬；改之前到現場確認 |
| 交換器的 AP 埠上出現不認識的 MAC | 經 AP 連線的手機會被交換器記在 AP 埠上；MAC 第二碼是 2、6、A、E 的通常是手機的隨機 MAC |
| 館員的新設備莫名被過濾 | 讀者群組裡還留著舊網段的 IP 範圍，DHCP 把那段 IP 發給了館員設備；讀者群組改成只用 VLAN 劃分 |
| 動畫 GIF 截圖只看到一部分 | 回報設定時用一般截圖，一個畫面一張 |

## 9. 待辦

- [ ] 櫃台電腦：確認館務系統與列印正常
- [ ] 讀者電腦、讀者手機現場驗收（外網 IP、隔離、CIP）
- [ ] 到現場確認兒童區小交換器下只接讀者電腦
- [ ] 2F 事務機查出 IP 後加綁定
- [ ] 查閘道 MAC，讀者 SSID 補開 Layer 2 isolation
- [ ] 確認 CIP 過濾依賴的授權與到期日
- [ ] 實測單線斷線時的切換行為；評估 Connectivity Check
- [ ] 查出用途不明的有線設備
- [ ] （選用）館員有線規則的 Source 改成 Any
- [ ] （選用）網路設備管理獨立成一個 VLAN

## 10. 這次的心得

| 心得 | 說明 |
| --- | --- |
| 先看現況再改 | 這次在安全政策裡發現讀者過濾從來沒有生效，如果直接照原計畫新增規則，就不會發現 |
| 新規則先建成停用狀態 | 排好順序、閉館時段再逐條啟用，出問題取消勾選就能還原 |
| 規則名稱不要寫會變的東西 | 名稱不能改，寫了外網 IP 或 WAN 編號，之後一調整就名實不符 |
| 一次只改一件事 | 出口對調、讀者 SSID 搬家、讀者有線搬家分開做，出問題才知道是哪一步 |
| 改埠前先對 MAC 和埠號 | Nebula Clients 頁面能看到每台設備接在哪個埠，也能發現一個埠下接了好幾台的情況 |
| 過渡期的東西要記得清 | 搬完立刻刪舊綁定、舊規則、舊物件，免得之後忘記；刪之前先想想「它被刪了之後，那段 IP 會發給誰」 |
| 用 VLAN 劃分，不要用 IP 範圍 | 位址物件改用 Interface subnet 或整個網段，比手動維護 IP 範圍可靠，新設備不會被誤判 |

## 11. 延伸閱讀

- [Nebula 防火牆 LAN 介面設定教學](https://community.zyxel.com/tw/discussion/16371/nebula-%E9%98%B2%E7%81%AB%E7%89%86-lan-%E4%BB%8B%E9%9D%A2%E8%A8%AD%E5%AE%9A%E6%95%99%E5%AD%B8)：Zyxel 台灣社群，VLAN 介面與 DHCP 參數
- [Nebula Switch VLAN 設定教學](https://community.zyxel.com/tw/discussion/16355/nebula-switch-vlan-%E8%A8%AD%E5%AE%9A%E6%95%99%E5%AD%B8)：Zyxel 台灣社群，Trunk／Access／PVID
- [Nebula 如何設定無線網路 (SSID) 的 VLAN ID](https://community.zyxel.com/tw/discussion/16659/nebula-%E5%A6%82%E4%BD%95%E8%A8%AD%E5%AE%9A%E7%84%A1%E7%B7%9A%E7%B6%B2%E8%B7%AF-ssid-%E7%9A%84-vlan-id)：Zyxel 台灣社群，SSID 對應 VLAN
- [Nebula USGFLEX/ATP/VPN - Routing and Traffic Shaping configuration](https://support.zyxel.eu/hc/en-us/articles/360020464860)：Nebula 路由與 Policy Route
- [USG Flex H Series Load Balancing In Nebula Mode](https://community.zyxel.com/en/discussion/comment/77409/)：H 系列在 Nebula 下的負載平衡討論
- [[Nebula] Dynamic Personal Pre-Shared Key (DPPSK)](https://community.zyxel.com/vn/discussion/16890/nebula-dynamic-personal-pre-shared-key-dppsk)：DPPSK 支援機型清單
- [有用中華電信資安艦隊：DNS 為什麼不能設 8.8.8.8？](../cht-security-fleet-dns-filtering/)：防火牆 DNS 要填什麼
