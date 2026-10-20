---
layout: default
title: "Zyxel Nebula VLAN 設定：防火牆介面、交換器 Trunk／Access、AP SSID 一次搞懂"
permalink: /docs/network/zyxel-nebula-switch-vlan/
date: 2026-10-20
categories: [Network, VLAN, Zyxel, Nebula]
last_modified_at: 2026-10-20
---

# Zyxel Nebula VLAN 設定：防火牆介面、交換器 Trunk／Access、AP SSID 一次搞懂

> **一句話**：先在防火牆為每個 VLAN 建好介面（閘道＋DHCP）；交換器只要分清楚埠接的是「終端設備」還是「中繼設備」：接電腦、印表機、IP Cam 的埠設 **Access** 並把 **PVID** 設成要加入的 VLAN；接交換器、AP、防火牆的埠維持 **Trunk**、**PVID 1**，並確認「允許的 VLANs」有包含所有要通過的 VLAN。AP 端再把每個 SSID 指派到各自的 VLAN ID，員工和訪客網路就分開了。

| 項目 | 內容 |
| --- | --- |
| 適合誰看 | 第一次在 Nebula 雲端管理介面設定交換器 VLAN、搞不懂 Trunk／Access／PVID 的人 |
| 環境 | Zyxel Nebula Control Center（三篇原文截圖皆為 Nebula 19.00 版）、Nebula 防火牆、Nebula 交換器、Nebula AP |
| 資料來源 | Zyxel 台灣社群官方教學：〈[Nebula Switch VLAN 設定教學](https://community.zyxel.com/tw/discussion/16355/nebula-switch-vlan-%E8%A8%AD%E5%AE%9A%E6%95%99%E5%AD%B8)〉（2023-03-21 發布）、〈[Nebula 防火牆 LAN 介面設定教學](https://community.zyxel.com/tw/discussion/16371/nebula-%E9%98%B2%E7%81%AB%E7%89%86-lan-%E4%BB%8B%E9%9D%A2%E8%A8%AD%E5%AE%9A%E6%95%99%E5%AD%B8)〉（2023-03-22 發布）、〈[Nebula 如何設定無線網路 (SSID) 的 VLAN ID](https://community.zyxel.com/tw/discussion/16659/nebula-%E5%A6%82%E4%BD%95%E8%A8%AD%E5%AE%9A%E7%84%A1%E7%B7%9A%E7%B6%B2%E8%B7%AF-ssid-%E7%9A%84-vlan-id)〉（2023-04-19 發布） |
| 驗證程度 | ⏳ 整理自原廠教學，**本環境尚未實機驗證**；新版 Nebula 介面名稱可能與 19.00 版不同 |
| 結論 | ✅ 防火牆 → LAN1 的 VLAN ID 留空，每個 VLAN 新增一個 VLAN 介面並開 DHCP；✅ 終端設備 → Access + PVID＝該 VLAN；✅ 中繼設備 → Trunk + PVID 1 + 允許的 VLANs 要包含所有需要的 VLAN；✅ SSID → 在 SSID 進階設定填 VLAN ID，**記得按儲存** |

## 1. 先認識幾個名詞

| 名詞 | 白話解釋 |
| --- | --- |
| **VLAN** | 在同一台實體交換器上切出好幾個「虛擬的獨立網路」，彼此預設不互通，例如電腦一個網段、監視器一個網段 |
| **802.1Q** | VLAN 的國際標準，規定怎麼在乙太網路幀（Frame）裡插入一個 **VLAN Tag** |
| **VLAN Tag（VLAN 標籤）** | 貼在幀上的「我屬於哪個 VLAN」標記，交換器靠它把流量分組、隔離 |
| **Tagged／Untagged** | 帶有 VLAN 標籤的幀叫 Tagged；沒有標籤的叫 Untagged。電腦、印表機送出來的幀都是 Untagged |
| **PVID**（Port VLAN ID） | 埠的「預設 VLAN」。像在埠上裝一台**標籤機**：沒貼標籤的幀進來，就自動貼上 PVID 指定的標籤 |
| **Access 模式（存取）** | 給「終端設備」用的埠：進來的幀貼上 PVID 標籤，送出去前把標籤撕掉，終端設備完全不用懂 VLAN |
| **Trunk 模式** | 給「中繼設備」用的埠：一條線同時跑多個 VLAN，幀離開時保留標籤，讓下一台設備知道它屬於哪個 VLAN |
| **允許的 VLANs**（Allowed VLANs） | 只有 Trunk 模式有：這個埠放行哪些 VLAN 的通行清單，預設是「全部（All）」 |
| **Native VLAN** | Trunk 埠上「不帶標籤傳送」的那個 VLAN，在 Nebula 裡就是 Trunk 埠的 PVID（通常是 1） |
| **終端設備** | 後面不會再接其他設備，例如 PC、印表機、IP 監視器 |
| **中繼設備** | 後面還會再接其他設備，例如防火牆、AP、交換器 |
| **LAN 介面／VLAN 介面** | 防火牆上代表一個網段的「虛擬網卡」：有自己的 IP（當閘道）和 DHCP。LAN1 是預設介面，每多一個 VLAN 就新增一個 VLAN 介面 |
| **埠群組**（Port Group／LAN Group） | 防火牆把哪幾個實體埠綁成一組，給哪個 LAN 介面使用 |
| **DHCP Pool** | DHCP 可以發出去的 IP 範圍，由「起始位址＋Pool 大小」決定 |
| **租約時間**（Lease Time） | 發出去的 IP 借給設備多久，到期沒續約就收回 |
| **SSID** | 無線網路的名稱，例如 `Employee_WiFi`、`Guest_WiFi`。一台 AP 可以同時廣播好幾個 SSID |
| **預設閘道**（Default Gateway） | 一個網段要連到其他網段或外網時，封包先送去的設備，這裡是防火牆的 VLAN 介面 |
| **語音 VLAN**（Voice VLAN） | Access 埠的特殊功能：自動認出網路電話等設備，把它的流量分到另一個 VLAN |

## 2. 全貌：一個幀怎麼被貼標籤、撕標籤

```text
【Access 埠】接 PC（PVID 10）

  PC ──(Untagged)──▶ 進入埠：貼上 VLAN 10 標籤 ──▶ 交換器內部（VLAN 10）
  PC ◀─(Untagged)─── 送出埠：撕掉標籤          ◀── 交換器內部（VLAN 10）
  ※ 收到「已帶標籤」的幀 → 直接丟棄

【Trunk 埠】接防火牆（PVID 1，允許 1,10,20,30）

  VLAN 10／20／30 的幀 ──▶ 保留標籤（Tagged）通過
  VLAN 1 的幀          ──▶ 撕掉標籤（Untagged）送出，因為 VLAN 1 = PVID
  對方送來的 Untagged 幀 ─▶ 視為 VLAN 1
  VLAN 40 的幀         ──▶ 不在允許清單，阻擋
```

本篇的範例架構（依交換器原文的架構圖改繪；防火牆的 VLAN 介面依第 4 節建立）：

```text
設定順序：防火牆（第 4 節）→ 交換器（第 5～7 節）→ AP（第 8 節）→ 驗收（第 9 節）
```

```text
                    ┌──────────────┐
                    │   防火牆      │  LAN 1：VLAN 1（管理，未標記）
                    │ (已建 VLAN    │  另有 VLAN 10、VLAN 20 介面
                    │  10／20 介面) │
                    └──────┬───────┘
                           │ P28：Trunk，PVID 1，允許 All
                    ┌──────┴───────────────────────────────┐
                    │        Nebula 交換器                   │
                    └──┬──────────────┬──────────────┬─────┘
       P1～P10         │   P11～P14   │   P15～P24   │
  Access，PVID 10      │ Access，PVID 20  Trunk，PVID 1，允許 All
                       │              │              │
                   PC（VLAN 10） 監視器（VLAN 20）  AP（多個 SSID）
```

## 3. 判斷每個埠要設什麼

做什麼：先把每個埠「接什麼設備」列出來，再決定模式。

| 接的設備 | 屬於 | 類型 | PVID | 允許的 VLANs |
| --- | --- | --- | --- | --- |
| PC、印表機、IP 監視器 | 終端設備 | **Access** | 該設備要加入的 VLAN ID（例如 10） | （Access 沒有這個欄位） |
| 交換器、AP、防火牆 | 中繼設備 | **Trunk**（預設） | 1（或你規劃的 Native VLAN） | 所有需要通過的 VLAN（例如 `1,10,20,30`），或預設 All |
| 網路電話 | 終端設備（特殊） | **Access** + VLAN 類型選語音 VLAN | 電腦用的 VLAN | — |

> **口訣**：後面還會再接東西的 → Trunk；後面不會再接東西的 → Access。

## 4. 防火牆：設定 LAN 介面與 VLAN 介面

每個 VLAN 都要在防火牆有一個介面，當作該網段的**預設閘道**並發 **DHCP**，交換器和 AP 的 VLAN 才有意義。

### 4-1 確認實體埠屬於哪個介面

做什麼：確認防火牆的實體埠被分到哪個埠群組（LAN Group），也就是屬於哪個介面。

怎麼做：依序點選 **整個站點 > 防火牆 > 設定 > 埠**。

應該看到：每個實體埠所屬的介面。只需要一個 LAN Group 的話，可以把預設的 LAN Group 2 移除，做法見原廠另一篇[教學](https://community.zyxel.com/tw/discussion/16369)。

### 4-2 設定 LAN1 介面

做什麼：設定 LAN1 的 IP、網段和 DHCP。LAN1 就是第 7-2 節交換器 P28（PVID 1）收到的**未標記**管理網段。

怎麼做：依序點選 **設定 > 防火牆 > 介面**，看目前各介面的 IP，在 LAN1 點 **編輯**。

重要參數（建議修改）：

| 參數 | 怎麼填 |
| --- | --- |
| **VLAN ID** | LAN1 **保留空白，不要填任何數值**，否則會造成網路異常 |
| IP 位址、子網路遮罩 | 依規劃填寫，**不要和其他網段重疊**（可用[子網路計算工具](http://www.subnet-calculator.com/subnet.php?net_class=B)驗算） |
| DHCP | 要讓防火牆發 IP 時，選 **DHCP 伺服器** |
| IP pool 起始位址 | DHCP 從哪個 IP 開始發 |
| Pool 大小 | 從起始位址開始，總共發幾個 IP |
| DNS 伺服器 | 可填外部 DNS（原文舉例 `168.95.1.1`、`8.8.8.8`）或內部自建 DNS |
| 租約時間 | 員工網段可設 **7 天**；訪客網段建議 **8 小時**，避免 Pool 被用光。**任何情況都不要設「無限」**，否則 IP 發出去就不會釋放 |

用例子看懂 Pool（原文例子，IP 換成文件專用的 `192.0.2.x`）：

| 設定 | 結果 |
| --- | --- |
| IP pool 起始位址 `192.0.2.33` | `192.0.2.2`～`192.0.2.32` **不會**發給使用者，可以保留給伺服器設固定 IP |
| Pool 大小 `200` | DHCP 發放範圍是 `192.0.2.33`～`192.0.2.232`，共 200 個 IP |

次要參數（可保留預設值）：

| 參數 | 說明 |
| --- | --- |
| 靜態的 DHCP 表 | 手動綁定 IP 與 MAC，讓特定 IP 只發給特定 MAC 位址 |
| MTU | 建議維持原本數值 |
| 進階選項 | 特殊需求才用，不需要就保留預設的空白 |

應該看到：LAN1 介面顯示新的 IP；接在 LAN1 網段的設備（例如第 7-2 節的交換器本身）拿到這個網段的 IP。

> ⚠️ **DNS 填 8.8.8.8 前先確認線路**：如果線路有申請中華電信資安艦隊，DNS 不能填 `8.8.8.8`，詳見[這篇](../cht-security-fleet-dns-filtering/)。

### 4-3 新增 VLAN 介面

做什麼：為每個 VLAN（例如 10、20）各建一個介面，當作該網段的閘道並發 DHCP。

怎麼做：在 **設定 > 防火牆 > 介面** 新增 VLAN 介面，重要參數如下：

| 參數 | 怎麼填 |
| --- | --- |
| **介面名稱** | 只能用英文和數字，**儲存後無法再修改**。建議用 `vlan`＋ID，例如 `vlan10` |
| **埠群組** | 這個 VLAN Tag 要綁在哪個 LAN 介面，一般選 **LAN Group 1** |
| **VLAN ID** | 這個介面要帶哪個 VLAN Tag 給下面的設備，例如 `10` |
| 其他（IP、DHCP、Pool、DNS、租約） | 和 LAN1 一樣，參考 4-2 |

應該看到：介面清單多出 `vlan10`、`vlan20` 等介面，各有自己的 IP 網段。

> **和交換器怎麼對起來**：LAN1 不帶標籤（VLAN ID 空白）＝交換器 Trunk 埠的 PVID 1；VLAN 介面帶標籤＝交換器 Trunk 埠「允許的 VLANs」裡要有這些 ID。

## 5. 打開交換器埠設定頁

做什麼：進到 Nebula 的交換器埠清單，選好要改的埠。

怎麼做：

1. 登入 Nebula Control Center，選擇要設定的站點
2. 依序點選 **交換器 > 設定 > 交換器埠**
3. 勾選要編輯 VLAN 的埠（**可以一次勾選多個**，例如 P1～P10 一起勾）
4. 點 **編輯**

應該看到：跳出「埠編輯」視窗，裡面有以下 VLAN 相關欄位：

| 欄位 | 意思 |
| --- | --- |
| **類型**（Type） | 選 `Trunk` 或 `存取`（Access） |
| **PVID** | 這個埠的預設 VLAN ID |
| **允許的 VLANs** | 只有 Trunk 會出現；預設 `全部`（All） |
| **VLAN 類型** | 只有 Access 會出現；預設 `無`（None），用語音 VLAN 時才改 |

> 截圖請參考[原文](https://community.zyxel.com/tw/discussion/16355/nebula-switch-vlan-%E8%A8%AD%E5%AE%9A%E6%95%99%E5%AD%B8)，畫面是 Nebula 19.00 版。

## 6. 設定 Access 埠（接終端設備）

### 6-1 P1～P10 接 PC → VLAN 10

做什麼：讓接在 P1～P10 的電腦都拿到 VLAN 10 的網段。

怎麼做：勾選 P1～P10 → 編輯，填入：

| 欄位 | 值 |
| --- | --- |
| 類型 | `存取`（Access） |
| PVID | `10` |
| VLAN 類型 | `無`（None，維持預設） |

應該看到：儲存後，埠清單裡 P1～P10 的類型顯示 Access、PVID 10；電腦插上去後，會從防火牆 VLAN 10 介面的 DHCP 拿到該網段 IP。

### 6-2 P11～P14 接網路監視器 → VLAN 20

做什麼：把監視器放進獨立的 VLAN 20。

怎麼做：勾選 P11～P14 → 編輯，填入：

| 欄位 | 值 |
| --- | --- |
| 類型 | `存取`（Access） |
| PVID | `20` |

應該看到：P11～P14 顯示 Access、PVID 20；監視器取得 VLAN 20 網段的 IP。

> **Access 埠的規則**：
> - 收到終端設備送來的 Untagged 幀 → 貼上 PVID 標籤
> - 收到意外帶標籤的幀 → **直接丟棄**
> - 要送給終端設備的幀 → 先撕掉標籤，讓它變回「乾淨」的 Untagged 幀

### 6-3（選用）語音 VLAN

做什麼：讓網路電話的流量自動分到另一個 VLAN，和電腦分開。

怎麼做：Access 埠的編輯畫面裡有一個 **VLAN 類型** 選項，選語音 VLAN。交換器會用 MAC 位址等方式認出特定設備，把它的流量放到一個**和 PVID 不同**的 VLAN。

應該看到：沒有這個需求時，維持預設 `無`（None）就好。

> 語音 VLAN 的完整設定原文沒有展開，請參考「延伸閱讀」的英文教學。

## 7. 設定 Trunk 埠（接中繼設備）

### 7-1 P15～P24 接 AP

做什麼：AP 要同時承載好幾個 SSID（例如員工 Wi-Fi、訪客 Wi-Fi），每個 SSID 對應不同 VLAN，所以要用 Trunk。

怎麼做：勾選 P15～P24 → 編輯，填入：

| 欄位 | 值 | 為什麼 |
| --- | --- | --- |
| 類型 | `Trunk`（維持預設） | AP 是中繼設備 |
| PVID | `1` | 對應 AP 本身的管理 VLAN |
| 允許的 VLANs | `全部`（All，維持預設） | 讓所有 SSID 的 VLAN 都能通過 |

應該看到：P15～P24 顯示 Trunk、PVID 1；AP 上線，各 SSID 的用戶拿到對應 VLAN 的 IP。

> 💡 **安全提示（原文）**：比較嚴格的環境，建議不要允許「全部」，改成明確列出需要的 VLAN，例如 `1,10,20`。

### 7-2 P28 接防火牆

做什麼：防火牆要收到 VLAN 10 的 PC、VLAN 20 的監視器等所有 VLAN 的流量，才能做路由和安全政策。

怎麼做：勾選 P28 → 編輯，填入：

| 欄位 | 值 | 為什麼 |
| --- | --- | --- |
| 類型 | `Trunk`（維持預設） | 防火牆是中繼設備 |
| PVID | `1` | 交換器本身用未標記的管理流量，從防火牆的 LAN 1 介面取得 IP |
| 允許的 VLANs | `全部`（All，維持預設） | 所有 VLAN 都要送到防火牆 |

應該看到：交換器本身在 Nebula 維持上線（管理 IP 從防火牆 LAN 1 取得）；不同 VLAN 之間能依防火牆政策互通。

### 7-3（選用）只放行指定 VLAN 的 Trunk

做什麼：想比預設更嚴格，只讓 VLAN 10、20、30 通過。

怎麼做：

| 欄位 | 值 |
| --- | --- |
| 類型 | `Trunk` |
| PVID | `1` |
| 允許的 VLANs | `1,10,20,30` |

逐段說明 `1,10,20,30`：

| 片段 | 意思 |
| --- | --- |
| `1` | Native VLAN（就是 PVID）本身通常也要加進允許清單，否則管理流量會斷 |
| `10,20,30` | 需要通過這條 Trunk 的業務 VLAN |
| 其他沒列的（如 `40`） | 一律被阻擋 |

應該看到的效果：

- VLAN 10、20、30 的 Tagged 流量正常通過
- 其他 VLAN（例如 VLAN 40）的流量被擋下
- 對向設備傳來的 Untagged 流量，被當成 VLAN 1
- 本機送出的 VLAN 1 流量，離開這個埠時**不帶標籤**

> **兩端 PVID 要一致**：Trunk 埠會把「和 PVID 相同 VLAN」的幀撕掉標籤送出；對面收到 Untagged 幀，再用它自己的 PVID 貼回去。兩邊 PVID 不一樣，管理流量就會被歸到錯的 VLAN。

## 8. 設定 AP 的 SSID VLAN ID（員工／訪客分開）

做什麼：讓不同 SSID 的使用者進到不同 VLAN，例如訪客連不到公司內部伺服器，也可以對不同群組套用各自的頻寬限制與安全政策。

原文的範例規劃：

| SSID | VLAN ID | 用途 |
| --- | --- | --- |
| `Employee_WiFi`（員工） | 10 | 內部網路 |
| `Guest_WiFi`（訪客） | 20 | 訪客網路 |

> ⚠️ **注意 VLAN 編號衝突**：兩篇原文是各自獨立的範例。交換器那篇的 VLAN 20 是**監視器**，SSID 這篇的 VLAN 20 是**訪客**。兩篇要放在同一個環境時，訪客請改用另一個沒用過的 VLAN ID（例如 30，這是本篇建議，不是原文），並同步加到第 7-3 節 Trunk 的允許清單。

### 8-1 開啟 SSID 進階模式

做什麼：讓 SSID 設定頁顯示 VLAN ID 等進階欄位。

怎麼做：

1. 依序點選 **設定 > 無線基地台 > SSID 設置**
2. 打開頁面上的 **進階模式** 開關

應該看到：SSID 列表與所有可用的設定選項都顯示出來。

### 8-2 設定員工 SSID 的 VLAN ID

做什麼：把員工 SSID 指派到 VLAN 10。

怎麼做：

1. 在 SSID 列表找到員工 SSID，點右側的 **編輯**
2. 捲到編輯頁**最下方**，找到 **VLAN ID** 欄位
3. 填入 `10`
4. 點 **返回** 回到 SSID 列表

應該看到：回到 SSID 列表（這時**還沒生效**，要等 8-4 儲存）。

### 8-3 設定訪客 SSID 的 VLAN ID

做什麼：把訪客 SSID 指派到另一個 VLAN。

怎麼做：重複 8-2，點訪客 SSID 的 **編輯**，在 **VLAN ID** 填入**不同**的編號（原文範例為 `20`），再點 **返回**。

### 8-4 儲存（最重要）

做什麼：讓所有變更正式生效。

怎麼做：兩組 SSID 都設好後，點主設定頁面**右下角**的 **儲存**。

應該看到：設定被儲存。沒按這個按鈕的話，前面的 VLAN ID 都不會生效。

### 8-5 確認整條路徑都設好了

SSID 填 VLAN ID 只是第一步，使用者要拿得到 IP、上得了網，流量經過的每台設備都要配合：

| 設備 | 必須完成的設定 | 對應本篇章節 |
| --- | --- | --- |
| 交換器 | 接 AP 的埠設成 **Trunk** | 7-1 |
| 交換器 | 這個 Trunk 埠的「允許的 VLANs」要包含員工與訪客的 VLAN（例如 10、20） | 7-1、7-3 |
| 路由器／防火牆 | 為每個 VLAN 建立**虛擬介面**（Virtual Interface），當作該網段的預設閘道 | 4-3 |
| 路由器／防火牆 | 為每個 VLAN 網段設定 **DHCP**，發 IP 給使用者 | 4-2、4-3 |

## 9. 設定完成後怎麼確認

| 檢查 | 應該看到 |
| --- | --- |
| Nebula 埠清單 | 每個埠的類型、PVID 和第 3 節規劃的表格一致 |
| 交換器狀態 | 交換器在 Nebula 仍顯示上線 |
| PC（P1～P10） | 拿到 VLAN 10 網段 IP |
| 監視器（P11～P14） | 拿到 VLAN 20 網段 IP |
| AP（P15～P24） | AP 上線 |
| 連員工 SSID | 拿到員工 VLAN 網段 IP，可以存取內部資源 |
| 連訪客 SSID | 拿到訪客 VLAN 網段 IP，**連不到**內部伺服器（取決於防火牆政策） |

> 這份檢查表是依原文設定推導出來的驗收項目，三篇原文都沒有寫驗證步驟（**未實測**）。

## 10. 常見問題

| 現象 | 怎麼辦 |
| --- | --- |
| 接防火牆或 AP 後，只有一個 VLAN 通，其他 VLAN 都不通 | **最常見的錯誤**：把應該是 Trunk 的埠（接防火牆、AP 的上行埠）設成 Access。改回 Trunk |
| Trunk 埠設好了，某個 VLAN 還是不通 | 檢查「允許的 VLANs」有沒有包含這個 VLAN ID；沒列的會被擋 |
| 改了允許清單後，交換器或 AP 從 Nebula 離線 | 允許清單漏了 Native VLAN（`1`）。把 PVID 對應的 VLAN 加回清單 |
| 兩台設備之間管理流量怪怪的、拿到錯的網段 | Trunk 兩端 PVID 不一致，改成一樣（通常都是 1） |
| 終端設備插在 Access 埠上，網路完全不通 | 確認這台設備沒有自己送出帶標籤的幀；Access 埠收到 Tagged 幀會直接丟棄 |
| PC 拿到錯的網段 | 檢查該埠的 PVID 是否為規劃的 VLAN ID |
| SSID 設了 VLAN ID，但完全沒生效 | 回到 SSID 設置頁，確認有按右下角的 **儲存**；只按「返回」不會儲存 |
| 找不到 SSID 的 VLAN ID 欄位 | 先打開 SSID 設置頁的 **進階模式**，欄位在編輯頁最下方 |
| 連上員工或訪客 SSID 後拿不到 IP | 依 8-5 逐項檢查：交換器接 AP 的埠是不是 Trunk、允許清單有沒有這個 VLAN、防火牆有沒有該 VLAN 的介面和 DHCP |
| 改完 LAN1 之後整個網路異常 | 檢查 LAN1 的 VLAN ID 是否被填了數值，LAN1 要**留空** |
| 新使用者拿不到 IP，舊的正常 | DHCP Pool 用完了：調整子網路遮罩與 Pool 大小；訪客網段把租約縮短到 8 小時；確認租約不是「無限」 |
| VLAN 介面名稱打錯了 | 名稱儲存後不能改，只能刪掉重建（**推測**，原文只寫「儲存後無法再修改」） |
| 介面找不到文中的欄位名稱 | 原文是 Nebula 19.00 版截圖，新版名稱可能不同（未確認） |

## 11. 待辦

- [ ] 在本環境的 Nebula 交換器實機設定一次，補上實際截圖與結果
- [ ] 確認目前 Nebula 版本的選單路徑與欄位名稱是否和 19.00 版相同
- [ ] 規劃本環境的 VLAN 編號表（管理、使用者、監視器、訪客、語音），避免兩篇原文範例的 VLAN 20 衝突
- [ ] 確認防火牆對訪客 VLAN 的政策：擋內網、限制頻寬
- [ ] 規劃各網段的子網路與 DHCP Pool，保留固定 IP 區段給伺服器
- [ ] 評估 AP 與防火牆的 Trunk 是否從 `全部` 改成明確列出 VLAN

## 12. 延伸閱讀

- [Nebula 防火牆 LAN 介面設定教學（原文）](https://community.zyxel.com/tw/discussion/16371/nebula-%E9%98%B2%E7%81%AB%E7%89%86-lan-%E4%BB%8B%E9%9D%A2%E8%A8%AD%E5%AE%9A%E6%95%99%E5%AD%B8)：Zyxel 台灣社群，第 4 節的來源，含截圖
- [Nebula Switch VLAN 設定教學（原文）](https://community.zyxel.com/tw/discussion/16355/nebula-switch-vlan-%E8%A8%AD%E5%AE%9A%E6%95%99%E5%AD%B8)：Zyxel 台灣社群，第 5～7 節的來源，含截圖
- [Nebula 如何設定無線網路 (SSID) 的 VLAN ID（原文）](https://community.zyxel.com/tw/discussion/16659/nebula-%E5%A6%82%E4%BD%95%E8%A8%AD%E5%AE%9A%E7%84%A1%E7%B7%9A%E7%B6%B2%E8%B7%AF-ssid-%E7%9A%84-vlan-id)：Zyxel 台灣社群，第 8 節的來源，含截圖
- [有用中華電信資安艦隊：DNS 為什麼不能設 8.8.8.8？](../cht-security-fleet-dns-filtering/)：防火牆 DNS 要填什麼
- [Configuration and explanation of VLAN (Trunk/Access/PVID) on Nebula switch](https://community.zyxel.com/en/discussion/10887/configuration-and-explanation-of-vlan-trunk-access-pvid-on-nebula-switch)：英文版說明
- [How to Configure Management VLAN on Nebula Switch via Nebula?](https://community.zyxel.com/en/discussion/16675/how-to-configure-management-vlan-on-nebula-switch-via-nebula)：管理 VLAN 不用 VLAN 1 時怎麼改
- [[NEBULA] How to Configure Voice VLAN on Zyxel Nebula Switch](https://community.zyxel.com/en/discussion/2730/nebula-how-to-configure-voice-vlan-on-zyxel-nebula-switch)：語音 VLAN 設定
