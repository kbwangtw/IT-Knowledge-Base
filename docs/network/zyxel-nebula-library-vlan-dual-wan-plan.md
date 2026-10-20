---
layout: default
title: "圖書館 Nebula 網路規劃：VLAN 隔離讀者 Wi-Fi、兩條 FTTB 分流"
permalink: /docs/network/zyxel-nebula-library-vlan-dual-wan-plan/
date: 2026-10-20
categories: [Network, VLAN, Zyxel, Nebula, Dual WAN]
last_modified_at: 2026-10-20
---

# 圖書館 Nebula 網路規劃：VLAN 隔離讀者 Wi-Fi、兩條 FTTB 分流

> **一句話**：館員和讀者共用一個 SSID、一個 /24 網段時，讀者看得到館內設備，IP 也容易用光。做法是在防火牆替每個 VLAN 建介面，交換器之間和接 AP 的埠維持 **Trunk**，多開一個館員 SSID，把讀者 SSID 移到獨立 VLAN，再用 Policy Route 讓讀者走另一條 FTTB。**順序是先開館員 SSID，再搬讀者**。

| 項目 | 內容 |
| --- | --- |
| 適合誰看 | 公共場所（圖書館、活動中心）同時有內部人員與訪客上網、想把兩邊分開的人；第一次在 Nebula 設定 VLAN、搞不懂 Trunk／Access／PVID 的人 |
| 環境 | USG FLEX 100H ×1、XGS2220 ×1（核心）、GS1920 ×3（1F～3F 各一台）、NWA90AX ×9（每層 3 台），全部由 Nebula 管理；FTTB ×2。架構依 Nebula 拓撲圖確認 |
| 日期 | 2026-10-20 規劃 |
| 資料來源 | 現場現況截圖；設定方法整理自 Zyxel 台灣社群官方教學（Nebula 19.00 版截圖）：〈[Nebula 防火牆 LAN 介面設定教學](https://community.zyxel.com/tw/discussion/16371/nebula-%E9%98%B2%E7%81%AB%E7%89%86-lan-%E4%BB%8B%E9%9D%A2%E8%A8%AD%E5%AE%9A%E6%95%99%E5%AD%B8)〉、〈[Nebula Switch VLAN 設定教學](https://community.zyxel.com/tw/discussion/16355/nebula-switch-vlan-%E8%A8%AD%E5%AE%9A%E6%95%99%E5%AD%B8)〉、〈[Nebula 如何設定無線網路 (SSID) 的 VLAN ID](https://community.zyxel.com/tw/discussion/16659/nebula-%E5%A6%82%E4%BD%95%E8%A8%AD%E5%AE%9A%E7%84%A1%E7%B7%9A%E7%B6%B2%E8%B7%AF-ssid-%E7%9A%84-vlan-id)〉 |
| 結論 | ⏳ 規劃完成，**尚未實作**；雙 WAN 備援行為與部分 Nebula 欄位**未確認**；新版 Nebula 介面名稱可能與 19.00 版不同 |

## 1. 先認識幾個名詞

| 名詞 | 白話解釋 |
| --- | --- |
| **VLAN** | 在同一套實體交換器上切出好幾個「虛擬的獨立網路」，彼此預設不互通，例如館員一個網段、讀者一個網段 |
| **802.1Q／VLAN Tag** | VLAN 的國際標準：在乙太網路幀（Frame）裡插入一個「我屬於哪個 VLAN」的標籤，交換器靠它把流量分組、隔離 |
| **Tagged／Untagged** | 帶有 VLAN 標籤的幀叫 Tagged；沒有標籤的叫 Untagged。電腦、印表機送出來的幀都是 Untagged |
| **PVID**（Port VLAN ID） | 埠的「預設 VLAN」。像在埠上裝一台**標籤機**：沒貼標籤的幀進來，就自動貼上 PVID 指定的標籤 |
| **Access 模式（存取）** | 給「終端設備」（電腦、印表機）用的埠：進來的幀貼上 PVID 標籤，送出去前把標籤撕掉，終端設備完全不用懂 VLAN |
| **Trunk 模式** | 給「中繼設備」（防火牆、交換器、AP）用的埠：一條線同時跑多個 VLAN，幀離開時保留標籤 |
| **允許的 VLANs**（Allowed VLANs） | 只有 Trunk 有：這個埠放行哪些 VLAN 的通行清單，預設是「全部（All）」 |
| **Native VLAN** | Trunk 埠上「不帶標籤傳送」的那個 VLAN，在 Nebula 裡就是 Trunk 埠的 PVID（通常是 1） |
| **LAN 介面／VLAN 介面** | 防火牆上代表一個網段的「虛擬網卡」：有自己的 IP（當預設閘道）和 DHCP。LAN1 是預設介面，每多一個 VLAN 就新增一個 VLAN 介面 |
| **DHCP Pool／租約** | DHCP 可以發出去的 IP 範圍（起始位址＋Pool 大小），以及每個 IP 借給設備多久 |
| **SSID** | 無線網路的名稱。一台 AP 可以同時廣播好幾個 SSID，每個 SSID 對應一個 VLAN |
| **FTTB／WAN** | 光纖到大樓的固定制網路；防火牆接網際網路的那一側叫 WAN，本案兩條 FTTB＝兩個 WAN |
| **Policy Route**（政策路由） | 依「從哪裡進來、誰送的」決定走哪條 WAN，例如讀者網段一律走 WAN B |
| **SNAT** | 封包出去時把來源改成 WAN 的外網 IP，本案設為 Outgoing-interface（用出去那條線的 IP） |
| **DPPSK** | 一個 SSID、每人一組密碼，並依密碼分到不同 VLAN。本案**沒有採用**，原因見第 4 節 |

## 2. VLAN 怎麼運作：貼標籤、撕標籤

```text
【Access 埠】接讀者電腦（PVID 30）

  電腦 ──(Untagged)──▶ 進入埠：貼上 VLAN 30 標籤 ──▶ 交換器內部（VLAN 30）
  電腦 ◀─(Untagged)─── 送出埠：撕掉標籤          ◀── 交換器內部（VLAN 30）
  ※ 收到「已帶標籤」的幀 → 直接丟棄

【Trunk 埠】接 AP 或上一層交換器（PVID 1，允許 1,10,20,30）

  VLAN 10／20／30 的幀 ──▶ 保留標籤（Tagged）通過
  VLAN 1 的幀          ──▶ 撕掉標籤（Untagged）送出，因為 VLAN 1 = PVID
  對方送來的 Untagged 幀 ─▶ 視為 VLAN 1
  VLAN 40 的幀         ──▶ 不在允許清單，阻擋
```

判斷每個埠要設什麼：

| 接的設備 | 屬於 | 類型 | PVID | 允許的 VLANs |
| --- | --- | --- | --- | --- |
| 電腦、印表機 | 終端設備 | **Access** | 該設備要加入的 VLAN ID | （Access 沒有這個欄位） |
| 防火牆、交換器、AP | 中繼設備 | **Trunk**（預設） | 1 | 所有需要通過的 VLAN，或預設 All |

> **口訣**：後面還會再接東西的 → Trunk；後面不會再接東西的 → Access。原廠教學指出最常見的錯誤，就是把接防火牆、AP 的埠誤設成 Access，其他 VLAN 的流量就全被擋掉。

## 3. 現況與問題

```text
              WAN A（FTTB）    WAN B（FTTB）
                ge1 \            / ge2
                   USG FLEX 100H        ← LAN1（ge3）：<內網>/24 的閘道 + DHCP
                         │
                   Core-XGS2220（核心）
           ┌─────────────┼─────────────┐
       1F-GS1920     2F-GS1920     3F-GS1920
       AP01～03       AP01～03      AP01～03     ← NWA90AX ×9
         （每層 3 台；SSID：<SSID>，館員與讀者共用）
```

已經做好的部分：

| 項目 | 現況 |
| --- | --- |
| 兩條 FTTB 分工 | Policy Route 兩條：Incoming `ge3`（LAN1）＋來源物件「館員電腦群組」→ ge1（WAN A）；「讀者電腦範圍」→ ge2（WAN B），SNAT 都是 Outgoing-interface。不在物件裡的（Wi-Fi 使用者、網路設備）走預設路由 |
| 有線電腦分類 | 館員電腦 → WAN A；兒童區、成人區讀者電腦與櫃台電腦（歸類為讀者電腦）→ WAN B |
| 館員電腦固定 IP | LAN1 的靜態 DHCP 表用 MAC 綁 IP |
| DHCP 租約 | 1 天 |

還存在的問題：

| 問題 | 說明 |
| --- | --- |
| 讀者 Wi-Fi 和館內設備在同一網段 | 連 Wi-Fi 的讀者可以直接掃描、存取館內電腦、印表機 |
| IP 不夠用 | /24 只有 254 個 IP，扣掉網路設備 14 台、館內電腦，剩下的要給所有讀者手機 |
| 讀者電腦和館員電腦在同一網段 | 公用電腦誰都能操作，卻可以直接存取館員電腦 |

## 4. 目標架構

```text
                  WAN A ───────┐         ┌─────── WAN B
             （館員、管理）     │         │     （讀者）
                          USG FLEX 100H
          LAN1（VLAN 1，不帶標籤）＋ vlan10 ＋ vlan20 ＋ vlan30
                                │ Trunk：PVID 1，允許 1,10,20,30
                          Core-XGS2220
                                │ Trunk
                    1F／2F／3F-GS1920（各 1 台）
                 ┌──────────────┴──────────────┐
                 │ Trunk                        │ Access：PVID 30
       每層 AP01～AP03（共 9 台）           讀者電腦（第二階段）
          ┌──────────┴──────────┐
  <SSID>-staff（VLAN 10）  <SSID>（VLAN 20）
      館員 Wi-Fi              讀者 Wi-Fi
```

| VLAN | 用途 | 網段大小 | DHCP 租約 | 走哪條 WAN |
| --- | --- | --- | --- | --- |
| 1（不變） | 管理＋館員有線 | /24（維持現狀） | 維持現狀 | A |
| 10（新增） | 館員 Wi-Fi | /24 | 7 天 | A |
| 20（新增） | 讀者 Wi-Fi | /23（約 510 個 IP） | 8 小時 | B |
| 30（第二階段，選用） | 讀者電腦（兒童區、成人區、櫃台） | /24 | 1 天 | B |

設計上的考量：

| 決定 | 為什麼 |
| --- | --- |
| 原本的網段**不動** | 防火牆、交換器、AP 的管理 IP 和館員電腦都不用重設，改錯也不會讓設備從 Nebula 離線 |
| 讀者 Wi-Fi 用 /23 | 沒有尖峰人數資料，先保守取大一點 |
| 租約：館員 7 天、讀者 8 小時 | 原廠建議：員工網段 7 天；訪客網段 8 小時，避免 Pool 被已經離開的手機占住 |
| 多開館員 SSID，不用 DPPSK | DPPSK 需要 Nebula Pro Pack 授權，Zyxel 社群列出的支援清單**沒有 NWA90AX**（未向原廠確認）；多開 SSID 不需額外授權，代價是館員設備要重新連線一次 |

## 5. 第一階段：Wi-Fi 分 VLAN（建議閉館時段）

| 步驟 | 做什麼 | 對誰有影響 |
| --- | --- | --- |
| 5-0 | 截圖記錄目前的防火牆介面、交換器埠、SSID、路由設定 | 無 |
| 5-1 | 防火牆新增 `vlan10`、`vlan20` | 無 |
| 5-2 | 確認交換器的 Trunk 埠 | 無 |
| 5-3 | 新增館員 SSID | 無 |
| 5-4 | 館員設備換到館員 SSID | 館員短暫斷線 |
| 5-5 | 防火牆加安全政策 | 無 |
| 5-6 | 讀者 SSID 改到 VLAN 20 | 讀者斷線重連 |
| 5-7 | 新增 Policy Route | 短暫 |
| 5-8 | 驗收與拔線測試 | 讀者短暫斷線 |

> ⚠️ **為什麼 5-3、5-4 要在 5-6 前面**：館員原本也連 `<SSID>`。先把 `<SSID>` 改到 VLAN 20 的話，館員的筆電會被擋在讀者網段，連不到館內印表機和系統。

### 5-1 防火牆新增 VLAN 介面

做什麼：每個 VLAN 都要在防火牆有一個介面，當作該網段的預設閘道並發 DHCP，交換器和 AP 的 VLAN 才有意義。

怎麼做：

1. 先到 **整個站點 > 防火牆 > 設定 > 埠**，確認實體埠屬於哪個埠群組（LAN Group）。只需要一個 LAN Group 的話，可以把預設的 LAN Group 2 移除，做法見原廠[教學](https://community.zyxel.com/tw/discussion/16369)
2. 到 **設定 > 防火牆 > 介面**，新增 VLAN 介面，依下表填入，`vlan10`、`vlan20` 各建一個

| 參數 | 怎麼填 |
| --- | --- |
| **介面名稱** | 只能用英文和數字，**儲存後無法再修改**。用 `vlan10`、`vlan20` |
| **埠群組** | 一般選 **LAN Group 1** |
| **VLAN ID** | `10`、`20` |
| IP 位址、子網路遮罩 | 依規劃填寫，**不要和其他網段重疊**（可用[子網路計算工具](http://www.subnet-calculator.com/subnet.php?net_class=B)驗算） |
| DHCP | 選 **DHCP 伺服器** |
| IP pool 起始位址、Pool 大小 | 見下方例子 |
| DNS 伺服器 | 可填外部 DNS（原廠舉例 `168.95.1.1`、`8.8.8.8`）或內部 DNS |
| 租約時間 | `vlan10` 7 天、`vlan20` 8 小時。**任何情況都不要設「無限」**，否則 IP 發出去就不會釋放 |
| 靜態的 DHCP 表、MTU、進階選項 | 保留預設；MAC 綁定需要時再加（見 5-4） |

用例子看懂 Pool（原廠例子，IP 換成文件專用的 `192.0.2.x`）：

| 設定 | 結果 |
| --- | --- |
| IP pool 起始位址 `192.0.2.33` | `192.0.2.2`～`192.0.2.32` **不會**發給使用者，可以保留給固定 IP |
| Pool 大小 `200` | 發放範圍是 `192.0.2.33`～`192.0.2.232`，共 200 個 IP |

應該看到：介面清單多出 `vlan10`、`vlan20`，各有自己的 IP 網段。

> ⚠️ **不要動 LAN1 的 VLAN ID**：原廠教學特別提醒，LAN1 的 VLAN ID **保留空白，不要填任何數值**，否則會造成網路異常。LAN1 不帶標籤，正好對上交換器 Trunk 埠的 PVID 1。
>
> ⚠️ **DNS 填 8.8.8.8 前先確認線路**：線路有申請中華電信資安艦隊的話，DNS 不能填 `8.8.8.8`，詳見[這篇](../cht-security-fleet-dns-filtering/)。

### 5-2 確認交換器的 Trunk 埠

做什麼：讓 VLAN 10、20 能從防火牆一路通到 AP。

怎麼做：到 **交換器 > 設定 > 交換器埠**，勾選要看的埠（可以一次勾選多個）→ **編輯**，確認下列 13 條連線兩端的埠：

| 連線 | 類型 | PVID | 允許的 VLANs |
| --- | --- | --- | --- |
| 100H ↔ Core-XGS2220 | Trunk | 1 | All，或 `1,10,20,30` |
| Core-XGS2220 ↔ 1F／2F／3F-GS1920（3 條） | Trunk | 1 | 同上 |
| 各層 GS1920 ↔ AP01～03（9 條） | Trunk | 1 | 同上 |

埠編輯視窗裡的欄位：

| 欄位 | 意思 |
| --- | --- |
| **類型** | `Trunk` 或 `存取`（Access） |
| **PVID** | 這個埠的預設 VLAN ID |
| **允許的 VLANs** | 只有 Trunk 會出現；預設 `全部`（All） |
| **VLAN 類型** | 只有 Access 會出現；預設 `無`（None），用語音 VLAN 時才改 |

應該看到：這些埠都是 Trunk、PVID 1。埠如果還是預設值（Trunk／1／All），**這一步不用改**。

如果要改成只放行指定 VLAN（原廠的安全建議），逐段看 `1,10,20,30`：

| 片段 | 意思 |
| --- | --- |
| `1` | Native VLAN（就是 PVID），**一定要列**，否則管理流量會斷、設備從 Nebula 離線 |
| `10,20,30` | 館員 Wi-Fi、讀者 Wi-Fi、讀者電腦 |
| 其他沒列的 | 一律被阻擋 |

> **兩端 PVID 要一致**：Trunk 埠會把「和 PVID 相同 VLAN」的幀撕掉標籤送出，對面再用自己的 PVID 貼回去。兩邊 PVID 不一樣，管理流量會被歸到錯的 VLAN。

### 5-3 新增館員 SSID

做什麼：開一個館員專用的 SSID，放進 VLAN 10。

怎麼做：

1. 到 **設定 > 無線基地台 > SSID 設置**，打開 **進階模式** 開關
2. 新增 `<SSID>-staff`，加密用 WPA2／WPA3-Personal、強密碼，不要公告
3. 進入它的 **編輯** 頁，捲到**最下方**的 **VLAN ID**，填 `10`，點 **返回**
4. 點主設定頁**右下角**的 **儲存**（沒按這個，前面的設定都不會生效）

應該看到：用手機連 `<SSID>-staff`，拿到 VLAN 10 的 IP，能上網、能列印到 VLAN 1 的印表機。

### 5-4 館員設備換到館員 SSID

做什麼：讓館員的筆電、手機改連 `<SSID>-staff`。

怎麼做：逐台改連，並在設備上「忘記」`<SSID>`，避免之後自動連回去。

應該看到：館員設備都拿到 VLAN 10 的 IP。

> **MAC 綁定要重建**：LAN1 的靜態 DHCP 表不會帶到 VLAN 10，需要固定 IP 的設備要在 `vlan10` 重建。手機和新版 Windows 預設會在每個 Wi-Fi 用「隨機 MAC 位址（私人位址）」，要綁定的設備請針對 `<SSID>-staff` 關掉這個功能。

### 5-5 防火牆加安全政策

| 來源 | 目的 | 動作 |
| --- | --- | --- |
| VLAN 20（讀者 Wi-Fi） | VLAN 1、VLAN 10 | 拒絕 |
| VLAN 20（讀者 Wi-Fi） | 防火牆管理介面 | 拒絕 |
| VLAN 20（讀者 Wi-Fi） | 網際網路 | 允許 |
| VLAN 10（館員 Wi-Fi） | VLAN 1 | 允許（印表機、館內系統） |

### 5-6 讀者 SSID 改到 VLAN 20

做什麼：把 `<SSID>` 變成讀者專用。

怎麼做：在 SSID 設置頁編輯 `<SSID>`，最下方 **VLAN ID** 填 `20` → **返回** → 右下角 **儲存**。建議同時開啟用戶端隔離，讓讀者手機彼此看不到（Nebula 欄位名稱未確認）。

應該看到：讀者手機重新連線後拿到 VLAN 20 的 IP，ping 不到館內網段。

### 5-7 新增 Policy Route

做什麼：讓館員 Wi-Fi 走 WAN A、讀者 Wi-Fi 走 WAN B。

現有兩條規則的 Incoming 都是 `ge3`（LAN1）。新 VLAN 的流量從 `vlan10`／`vlan20` 進來，**不會被現有規則抓到**，所以只要新增規則，現有的不用動。

怎麼做：到 **整個站點 > 設定 > 防火牆 > 路由**（依 Zyxel 支援文件；100H 的實際選單**未確認**），新增規則 0、3、4：

| # | Incoming | Source | Destination | Next-Hop | SNAT | 說明 |
| --- | --- | --- | --- | --- | --- | --- |
| 0 | Any | Any | 內網各網段 | 依路由表（欄位未確認） | 不做 | 新增：內網互通不送外網 |
| 1 | ge3 | 館員電腦群組 | Any | ge1（WAN A，`198.51.100.x`） | Outgoing-interface | 現有，不動 |
| 2 | ge3 | 讀者電腦範圍 | Any | ge2（WAN B，`203.0.113.x`） | Outgoing-interface | 現有，不動 |
| 3 | vlan10 | Any | Any | ge1 | Outgoing-interface | 新增：館員 Wi-Fi |
| 4 | vlan20 | Any | Any | ge2 | Outgoing-interface | 新增：讀者 Wi-Fi |

> **規則 0 的原因（推測，未確認）**：Destination 是 Any 的 Policy Route，可能把館員 Wi-Fi 到館內印表機（VLAN 1）的流量也送去外網。原本全部在同一網段、不經過路由，所以沒遇到；切 VLAN 之後就要防。如果 Next-Hop 沒有「依路由表」的選項，改成在規則 3、4 的 Destination 用「非內網」物件。

### 5-8 驗收與拔線測試

| 檢查 | 應該看到 |
| --- | --- |
| 讀者手機查外網 IP | WAN B 的 IP |
| 館員 Wi-Fi 查外網 IP | WAN A 的 IP |
| 館員 Wi-Fi 列印到 VLAN 1 的印表機 | 印得出來（驗證規則 0） |
| 讀者手機 ping 館內設備 | ping 不到 |
| 有線館員電腦、讀者電腦的外網 IP | 和改之前一樣 |
| 交換器、AP 在 Nebula | 全部在線 |
| 拔掉 WAN B 的線 | 讀者是否自動改走 WAN A（**未確認**，要實測） |

**回滾**：把 `<SSID>` 的 VLAN ID 清空並儲存，讀者就回到原本的網段；停用規則 0、3、4 即可回到原本的分流。

## 6. 第二階段（選用）：讀者電腦搬到 VLAN 30

做什麼：把兒童區、成人區、櫃台的有線電腦放進 VLAN 30，和館員電腦隔開。

| 步驟 | 做什麼 | 應該看到 |
| --- | --- | --- |
| 6-1 | 查出讀者電腦接在哪幾層、哪幾個埠 | 對照表 |
| 6-2 | 防火牆新增 `vlan30`＋DHCP（做法同 5-1，租約 1 天）；新增路由規則（Incoming `vlan30` → ge2）；安全政策拒絕 VLAN 30 → VLAN 1／10 | — |
| 6-3 | 把這些埠改成 **Access、PVID 30**（見下表） | 讀者電腦拿到 VLAN 30 的 IP、外網走 WAN B、ping 不到館內網段 |
| 6-4 | 有 MAC 綁定的話，在 `vlan30` 重建 | IP 固定 |
| 6-5 | 測試櫃台電腦的館務系統（借還書等） | 正常登入、借還 |
| 6-6 | 都正常後，停用原本的規則 2（讀者電腦範圍） | 讀者電腦仍走 WAN B |

6-3 的埠設定：

| 欄位 | 值 |
| --- | --- |
| 類型 | `存取`（Access） |
| PVID | `30` |
| VLAN 類型 | `無`（None，維持預設） |

> **Access 埠的規則**：收到電腦送來的 Untagged 幀 → 貼上 PVID 標籤；收到意外帶標籤的幀 → **直接丟棄**；送給電腦的幀 → 先撕掉標籤。
>
> 櫃台電腦和讀者公用電腦會在同一個 VLAN、可以互連（本案的決定）。想再加強，可以在櫃台電腦開 Windows 防火牆，擋掉同 VLAN 其他電腦的連入。

## 7. 雙 WAN 還沒確認的地方

| 注意 | 說明 |
| --- | --- |
| 單線斷線時會不會自動切換 | **未確認**，5-8 要實測 |
| WAN Trunk 在 Nebula 設不了 | Zyxel 社群回覆說 H 系列的 WAN Trunk 目前要用本機網頁設定（回覆日期不明，現在是否已支援**未確認**）。在本機網頁改的設定可能被 Nebula 覆蓋，所以先只用 Nebula 上的 Policy Route |
| 預設路由走哪條 | 不在規則裡的流量（例如網路設備本身）走哪條 WAN **未確認** |
| 綁定外網 IP 的服務 | VPN、NAT、對方網站的 IP 白名單，分流後要確認還是走原本那條 WAN |

## 8. 常見問題

| 現象 | 怎麼辦 |
| --- | --- |
| 改完 `<SSID>` 後，館員連不到印表機 | 館員設備還連在 `<SSID>`（現在是讀者網段），請改連 `<SSID>-staff` |
| SSID 設了 VLAN ID，但完全沒生效 | 回到 SSID 設置頁，確認有按右下角的 **儲存**；只按「返回」不會儲存 |
| 找不到 SSID 的 VLAN ID 欄位 | 先打開 SSID 設置頁的 **進階模式**，欄位在編輯頁最下方 |
| 連上 Wi-Fi 卻拿不到 IP | 依序檢查：接 AP 的埠是否 Trunk、允許清單有沒有這個 VLAN、防火牆有沒有該 VLAN 的介面和 DHCP |
| 只有一個 VLAN 通，其他 VLAN 都不通 | 接防火牆或 AP 的埠被設成 Access，改回 Trunk |
| 交換器或 AP 從 Nebula 離線 | Trunk 的允許清單漏了 `1`（管理 VLAN），把 `1` 加回去 |
| 改完 LAN1 之後整個網路異常 | 檢查 LAN1 的 VLAN ID 是否被填了數值，LAN1 要**留空** |
| 新使用者拿不到 IP，舊的正常 | DHCP Pool 用完了：調整子網路遮罩與 Pool 大小、縮短租約、確認租約不是「無限」 |
| VLAN 介面名稱打錯了 | 名稱儲存後不能改，只能刪掉重建（**推測**，原廠只寫「儲存後無法再修改」） |
| 館員 Wi-Fi 的流量跑到 WAN B | 現有規則的 Incoming 是 `ge3`，抓不到 `vlan10`；要另外新增 Incoming＝`vlan10` 的規則 |
| 館員 Wi-Fi 上得了網，卻印不到館內印表機 | Policy Route 的 Destination 是 Any，內網流量被送去外網（推測）；加上規則 0，或把 Destination 改成「非內網」 |
| 館員筆電搬到 VLAN 10 後 IP 不固定 | 在 `vlan10` 重建 MAC 綁定，並對這個 SSID 關掉「隨機 MAC 位址」 |
| 靜態 DHCP 表有兩筆同名 | 只是名稱重複，不影響發 IP，但查 log 會混淆，建議更正（本案現況就有一筆） |
| 讀者電腦搬到 VLAN 30 後外網 IP 變了或連不上 | `vlan30` 的路由規則沒建或 Incoming 選錯；Incoming 要選 `vlan30`，不是 `ge3` |
| 讀者還是 ping 得到館內設備 | 5-5 的安全政策沒有生效，或規則順序不對 |
| 介面找不到文中的欄位名稱 | 原廠教學是 Nebula 19.00 版截圖，新版名稱可能不同（未確認） |

## 9. 待辦

- [ ] 補上每條連線的埠號（設備與連線關係已從 Nebula 拓撲圖確認）
- [ ] 確認新網段沒有和 VPN 或其他網段重疊
- [ ] 統計讀者尖峰同時上線人數，確認 /23 夠不夠用
- [ ] 確認預設路由走哪條 WAN、Policy Route 有沒有「依路由表」的 Next-Hop
- [ ] 盤點讀者電腦台數與接埠（第二階段用）
- [ ] 實作第一階段，補上實測結果與截圖，把結論改成 ✅
- [ ] 實測 Policy Route 在單線斷線時的行為

## 10. 延伸閱讀

- [Nebula 防火牆 LAN 介面設定教學](https://community.zyxel.com/tw/discussion/16371/nebula-%E9%98%B2%E7%81%AB%E7%89%86-lan-%E4%BB%8B%E9%9D%A2%E8%A8%AD%E5%AE%9A%E6%95%99%E5%AD%B8)：Zyxel 台灣社群，5-1 的來源，含截圖
- [Nebula Switch VLAN 設定教學](https://community.zyxel.com/tw/discussion/16355/nebula-switch-vlan-%E8%A8%AD%E5%AE%9A%E6%95%99%E5%AD%B8)：Zyxel 台灣社群，第 2 節、5-2、6-3 的來源，含截圖
- [Nebula 如何設定無線網路 (SSID) 的 VLAN ID](https://community.zyxel.com/tw/discussion/16659/nebula-%E5%A6%82%E4%BD%95%E8%A8%AD%E5%AE%9A%E7%84%A1%E7%B7%9A%E7%B6%B2%E8%B7%AF-ssid-%E7%9A%84-vlan-id)：Zyxel 台灣社群，5-3、5-6 的來源，含截圖
- [Nebula USGFLEX/ATP/VPN - Routing and Traffic Shaping configuration](https://support.zyxel.eu/hc/en-us/articles/360020464860)：Nebula 路由與 Policy Route 設定位置
- [USG Flex H Series Load Balancing In Nebula Mode](https://community.zyxel.com/en/discussion/comment/77409/)：H 系列在 Nebula 下的負載平衡討論
- [[Nebula] Dynamic Personal Pre-Shared Key (DPPSK)](https://community.zyxel.com/vn/discussion/16890/nebula-dynamic-personal-pre-shared-key-dppsk)：DPPSK 支援機型清單
- [How to Configure Management VLAN on Nebula Switch via Nebula?](https://community.zyxel.com/en/discussion/16675/how-to-configure-management-vlan-on-nebula-switch-via-nebula)：管理 VLAN 不用 VLAN 1 時怎麼改
- [有用中華電信資安艦隊：DNS 為什麼不能設 8.8.8.8？](../cht-security-fleet-dns-filtering/)：防火牆 DNS 要填什麼
