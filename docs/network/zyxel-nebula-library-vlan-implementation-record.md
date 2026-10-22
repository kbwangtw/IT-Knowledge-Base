---
layout: default
title: "圖書館 Nebula 網路改造（附錄）：設定清單與實作紀錄"
permalink: /docs/network/zyxel-nebula-library-vlan-implementation-record/
date: 2026-10-22
categories: [Network, VLAN, Zyxel, Nebula, Dual WAN]
last_modified_at: 2026-10-22
---

# 圖書館 Nebula 網路改造（附錄）：設定清單與實作紀錄

> **一句話**：這篇是〈[圖書館 Nebula 網路改造](../zyxel-nebula-library-vlan-dual-wan-plan/)〉的附錄，把改造完成後**每一項實際設定**（VLAN、介面、SSID、交換器埠、路由、物件、安全政策、MAC 綁定）整理成清單，並附上逐日實作紀錄和現場確認清單範本。觀念和做法請看主文章，這裡只列「最後設成什麼」。

| 項目 | 內容 |
| --- | --- |
| 適合誰看 | 要照抄同樣架構的人；之後接手維護這個環境的人；想對照「規劃」和「實際結果」差在哪的人 |
| 環境 | USG FLEX 100H ×1、XGS2220 ×1、GS1920 ×3（1F～3F）、NWA90AX ×9，全部由 Nebula 管理；FTTB ×2 |
| 日期 | 2026-10-21～22 實作；設定狀態以 2026-10-22 為準 |
| 結論 | ✅ 四個網段、出口分流、讀者 CIP 過濾與隔離都已設定完成；⏳ 現場驗收、Layer 2 isolation、授權到期影響待確認（見第 9 節） |
| 去識別化 | 外網 IP、內網網段、SSID、電腦名稱、MAC、電路編號、機構名稱都已改為代稱或移除 |

## 1. 代稱說明

| 代稱 | 代表 |
| --- | --- |
| `<WAN A IP>`、`<WAN B IP>` | 兩條 FTTB 的固定外網 IP。WAN A 接防火牆 ge1，WAN B 接 ge2 |
| `<LAN1>` | 館員有線網段（/24）的前三碼，例如 `<LAN1>.70` 表示這個網段的 `.70` |
| `<VLAN110>`、`<VLAN80>`、`<VLAN90>` | 館員無線、讀者無線、讀者有線網段（皆為 /24）的前三碼 |
| `<館員 SSID>`、`<讀者 SSID>` | 兩個無線網路名稱 |
| 館員電腦 1～12、兒童區 1～4、成人區 1～5、櫃台 | 實際的電腦名稱 |
| 資安艦隊 DNS | 中華電信資安艦隊指定的 DNS（見[這篇](../cht-security-fleet-dns-filtering/)） |

## 2. 全貌

```text
             WAN A（ge1）──────┐        ┌──────── WAN B（ge2）
               讀者出口         │        │         館員出口
                          USG FLEX 100H
            LAN1（ge3，實體埠 p3；p4～p7 未接）＋ vlan110 ＋ vlan80 ＋ vlan90
                                │
                         XGS2220 第 25 埠
          ┌──────────────────────┼──────────────────────┐
     第 2 埠                  第 6 埠                  第 4 埠
   1F-GS1920 第 25 埠      2F-GS1920 第 26 埠      3F-GS1920 第 25 埠
   AP：第 9、22、18 埠     AP：第 25、23、24 埠    AP：第 2、1、3 埠
   兒童區：第 10、11 埠    成人區：第 1～5 埠
   櫃台：第 19 埠
```

> 2F 的上行埠是 **26**，1F、3F 是 **25**；2F 的第 25 埠接的是 AP，容易搞混。

## 3. 網段與防火牆介面

**位置**：Configure → Firewall → Port & Interface

| 使用者 | VLAN | 介面 | 閘道 | DHCP 發放 | 租約 | DNS | Zone | Members |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 館員有線＋網路設備管理 | 1（不帶標籤） | ge3（LAN1） | `<LAN1>.253` | `.1` 起 199 個 | 7 天 | 資安艦隊 DNS | LAN | p3 |
| 館員無線（只給館員手機） | 110 | `vlan110` | `<VLAN110>.254` | `.1` 起 240 個 | 7 天 | 資安艦隊 DNS | LAN | p3 |
| 讀者無線 | 80 | `vlan80` | `<VLAN80>.254` | `.1` 起 240 個 | 8 小時 | 資安艦隊 DNS | LAN | p3 |
| 讀者有線 | 90 | `vlan90` | `<VLAN90>.254` | `.1` 起 240 個 | 1 天 | 資安艦隊 DNS | LAN | p3 |

> LAN1 是原有網段，這次**完全沒動**（VLAN ID 保持空白）。新增的三個介面都只選接核心交換器的 `p3`。
>
> 介面說明欄填了 FTTB 的**電路編號**，在 Policy route 選 Next Hop 時會顯示在介面旁邊，報修時很方便。

## 4. SSID

**位置**：Configure → Access point → SSID settings（Advanced mode）

| SSID | VLAN ID | 加密 | Forwarding mode | 隔離 | Band | 802.11r |
| --- | --- | --- | --- | --- | --- | --- |
| `<館員 SSID>`（新增） | 110 | WPA2-Personal | Local bridge | 都關 | 5／6 GHz | 開 |
| `<讀者 SSID>`（原有） | 80（原本 1） | WPA2-Personal | Local bridge | **Intra-BSS traffic blocking 開**；Layer 2 isolation 關（待補） | 5／6 GHz | 開 |

> 兩個 SSID 都只開 5 GHz（這款 AP 沒有 6 GHz），只支援 2.4 GHz 的舊設備連不上。這是原有設定，這次沒有改。

## 5. 交換器埠

**位置**：Switch → Configure → Switch ports

### 5-1 Trunk 埠（全部維持預設，未修改）

| 交換器 | 埠 | 接到 | 設定 |
| --- | --- | --- | --- |
| XGS2220 | 25 | 防火牆 p3 | Trunk／PVID 1／Allowed All |
| XGS2220 | 2、6、4 | 1F、2F、3F 交換器 | 同上 |
| 1F-GS1920 | 25（上行）、9、22、18（AP） | | 同上 |
| 2F-GS1920 | 26（上行）、25、23、24（AP） | | 同上 |
| 3F-GS1920 | 25（上行）、2、1、3（AP） | | 同上 |

### 5-2 改成讀者 VLAN 的 Access 埠

| 交換器 | 埠 | 接的電腦 | 設定 | 日期 |
| --- | --- | --- | --- | --- |
| 1F-GS1920 | 10 | 兒童區 1 | Access／PVID 90 | 2026-10-21 |
| 1F-GS1920 | 11（下接小型交換器） | 兒童區 2、3、4 | Access／PVID 90 | 2026-10-21 |
| 1F-GS1920 | 19 | 櫃台 | Access／PVID 90 | 2026-10-21 |
| 2F-GS1920 | 1～5（每埠一台） | 成人區 1～5 | Access／PVID 90 | 2026-10-22 |

> 遠端改 PVID 後，開著的電腦不會自動換 IP。要把該埠 **Port enabled** 關掉再打開（斷線再接上），或請現場重開機。

### 5-3 不能動的埠（維持 Access／PVID 1）

| 交換器 | 埠 | 接的設備 |
| --- | --- | --- |
| 1F-GS1920 | 5、6、7 | 館員用公用電腦 |
| 1F-GS1920 | 8（下接小型交換器） | 館員用公用電腦、1F 印表機、一台不明筆電 |
| 1F-GS1920 | 17、20 | 用途不明的設備（待查） |
| 2F-GS1920 | 13、15～22 | 館員電腦 |
| 2F-GS1920 | 14 | 2F 事務機 |

> 交換器的 AP 埠上會看到經 AP 連線的手機（MAC 第二碼是 2、6、A、E 的隨機 MAC），那不是接在交換器上的設備。

## 6. 路由與 NAT

**位置**：Configure → Firewall → Routing → Policy route

| # | Name | Incoming | Source | Next Hop | SNAT | Link down 自動停用 |
| --- | --- | --- | --- | --- | --- | --- |
| 1 | Librarian_WiFi_SNAT | vlan110 | Any | Interface ge2（WAN B） | Outgoing interface | 開 |
| 2 | Reader_WiFi_SNAT | vlan80 | Any | Interface ge1（WAN A） | Outgoing interface | 開 |
| 3 | Staff_PC_SNAT_WAN2 | ge3 | Office_PC_Group | Interface ge2（WAN B） | Outgoing interface | 開 |
| 4 | Reader_PC_VLAN90_SNAT | vlan90 | Any | Interface ge1（WAN A） | Outgoing interface | 開 |

Destination、Service、Source port 都是 Any，Schedule 是 Always，Connectivity Check 都關閉。

> 不在 `Office_PC_Group` 裡的 LAN1 設備（印表機、事務機、網路設備、不明設備）走預設路由。
>
> Policy route **不能拖曳排序**、**名稱不能改**。名稱裡寫了 WAN 編號的規則，之後如果改 Next Hop，建議另外新增一條。

## 7. 物件與安全政策

### 7-1 位址物件、群組、服務群組

**位置**：Configure → Firewall → Object

| 物件 | 類型 | 內容 | 用在 |
| --- | --- | --- | --- |
| LAN1_SUBNET（原有） | Interface subnet | ge3 | Staff_Net |
| Office_PC_Range（原有） | Range | `<LAN1>.70`～`.90` | Office_PC_Group |
| PC0（原有） | Host | `<LAN1>.200`（館員用公用電腦） | Office_PC_Group |
| Office_PC_Group（原有） | 群組 | Office_PC_Range、PC0 | 路由規則 3 |
| `Reader_WiFi_Net` | Interface subnet | vlan80 | Reader_All |
| `Staff_WiFi_Net` | Interface subnet | vlan110 | Staff_Net |
| `Reader_PC_Net` | Subnet | `<VLAN90>.0/24` | Reader_All |
| `Reader_All` | 群組 | Reader_WiFi_Net、Reader_PC_Net | 安全政策 1～3 |
| `Staff_Net` | 群組 | LAN1_SUBNET、Staff_WiFi_Net | 安全政策 1 |
| `Mgmt_Service_Group` | 服務群組 | HTTP、HTTPS、SSH-TCP | 安全政策 2 |

> 已刪除：舊的讀者電腦 IP 範圍物件與讀者群組物件（讀者電腦全部搬到 VLAN 90 後就沒有用到）。

### 7-2 安全政策順序

**位置**：Configure → Firewall → Security policy

| # | Name | Action | 設定檔 | From → To | Source | Destination | Service | Log |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 1 | Reader_to_Staff_Deny | Deny | — | LAN → LAN | Reader_All | Staff_Net | Any | 開 |
| 2 | Reader_to_Device_Deny | Deny | — | LAN → ZyWALL | Reader_All | Any | Mgmt_Service_Group | 開 |
| 3 | Reader_CIP_Outgoing | Allow | default_profile、CIP | LAN → Any (Excluding ZyWALL) | Reader_All | Any | Any | 開 |
| 4 | LAN_Outgoing | Allow | — | LAN → Any (Excluding ZyWALL) | Any | Any | Any | 關 |
| 5 之後 | 原有的 DMZ／VPN／LAN_to_Device／WAN 相關規則 | | | | | | | |
| 最後 | Default | Deny | | | | | | 開 |

> ⚠️ **第 4 條一定要在第 3 條下面**：放在上面，讀者會先被不過濾的規則放行，CIP 就失效了。
>
> ⚠️ **第 4 條不能少**：少了它，館員和網路設備的對外流量都會掉到最後的 Default Deny（見第 8 節 2026-10-22 的事件）。
>
> 已刪除：原本的 `Reader_PC_Policy`（為讀者套用 CIP，但因排序與條件問題從未生效）。

## 8. MAC 綁定（Static DHCP table）

### 8-1 LAN1（ge3）

| 設備 | IP | 備註 |
| --- | --- | --- |
| 館員電腦 1～12 | `<LAN1>.70`～`.81` | 原有 |
| 1F 印表機 | `<LAN1>.131` | 2026-10-22 補綁，沿用原本 DHCP 發的 IP |
| 館員用公用電腦 | `<LAN1>.200` | 2026-10-22 補綁，IP 原本設在電腦本身 |

> 2F 事務機：決定不綁定。
>
> 讀者電腦原本在這張表的 10 筆綁定，搬到 VLAN 90 後已刪除。

### 8-2 vlan90

| 設備 | IP | 接在 |
| --- | --- | --- |
| 櫃台 | `<VLAN90>.40` | 1F／19 |
| 兒童區 1 | `<VLAN90>.41` | 1F／10 |
| 兒童區 2～4 | `<VLAN90>.42`～`.44` | 1F／11 |
| 成人區 1～5 | `<VLAN90>.45`～`.49` | 2F／1～5 |

> IP 的最後一碼沿用舊網段的號碼，方便對照。
>
> Nebula **Clients** 頁面的名稱跟這張表的 Hostname 不會同步，已手動把讀者電腦改名成跟 Hostname 一致。

## 9. 實作紀錄

| 時間 | 做了什麼 | 結果 |
| --- | --- | --- |
| 10-20 | 盤點現況：單一網段、一個 SSID、兩條 FTTB 依來源 IP 分流；發現讀者 CIP 規則從未生效 | — |
| 10-21 | 防火牆新增 `vlan110`、`vlan80` | ✅ |
| 10-21 | 新增館員 SSID（VLAN 110）；**新 SSID 預設是 Open**，改成 WPA2 | ✅ |
| 10-21 | Policy route：館員無線、讀者無線 | ✅ 館員手機取得 VLAN 110 的 IP，出口正確 |
| 10-21 | 建位址物件、群組、服務群組 | ✅ |
| 10-21 | 安全政策：新增 3 條（先不啟用）→ 排到最上面 → 逐條啟用 → 停用舊的讀者規則 | ✅ |
| 10-21 | 讀者 SSID 改到 VLAN 80，開 Intra-BSS blocking | ✅ 讀者手機都取得 VLAN 80 的 IP |
| 10-21 | **出口對調**：館員改走 WAN B、讀者改走 WAN A；有線兩條規則重建，舊的刪除 | ✅ 館員有線／無線、讀者有線外網 IP 都正確 |
| 10-21 | 防火牆新增 `vlan90`＋10 筆綁定；Policy route 讀者有線 | ✅ |
| 10-21 | 1F 第 10、11、19 埠改 VLAN 90（遠端，現場無人） | ✅ 兩台開著的電腦遠端確認取得新 IP |
| 10-22 | 開館後兒童區、櫃台電腦取得 VLAN 90 的 IP；查出成人區在 2F 第 1～5 埠 | ✅ |
| 10-22 | LAN1 補綁 1F 印表機、館員用公用電腦 | ✅ |
| 10-22 | Clients 改名，讀者電腦名稱跟 DHCP Hostname 一致 | ✅ |
| 10-22 | 2F 第 1～5 埠改 VLAN 90 | ✅ 5 台都取得新 IP，讀者電腦全部搬完 |
| 10-22 | 收尾：刪除 LAN1 的讀者舊綁定、過渡用路由規則、舊物件；讀者群組改成只用 VLAN 劃分 | ✅ |
| 10-22 | ⚠️ 刪除舊的讀者規則時，`LAN_Outgoing` 一起被刪 → 館員與網路設備對外流量落到 Default Deny | ✅ 已補回，排在第 4 條 |

## 10. 規劃過程中的變更

| 原本規劃 | 最後實作 | 為什麼變 |
| --- | --- | --- |
| VLAN 10／20／30，讀者無線 /23 | VLAN 110／80／90，都是 /24 | 案主指定網段，VLAN ID 用網段第三碼 |
| 館員走 WAN A、讀者走 WAN B | 對調：館員走 WAN B、讀者走 WAN A | 案主決定 |
| 館員 SSID 給館員筆電作業用 | 只給館員手機上網 | 館員電腦全部是有線的，所以不需要列印測試 |
| 櫃台電腦另外處理 | 歸類為讀者電腦，一起搬到 VLAN 90 | 案主決定 |
| 讀者 SSID 開 Layer 2 isolation | 先開 Intra-BSS blocking | Layer 2 isolation 要填閘道 MAC，先用不需要 MAC 的做法 |
| 只隔離無線 | 讀者有線也搬到 VLAN 90 | 原本讀者電腦和館員電腦同網段，風險比無線更大 |

## 11. 現場確認清單（範本）

改完之後請現場人員逐項確認。結果欄勾「正常」或「異常」，異常要拍照回報。

| 編號 | 用哪台 | 怎麼做 | 應該看到 |
| --- | --- | --- | --- |
| 1-1 | 館員電腦 | 開新聞網站或公務系統 | 正常 |
| 1-2 | 館員手機 | 連 `<館員 SSID>` 開網站 | 正常 |
| 1-3 | 館員電腦 | 列印到 1F 印表機 | 正常印出 |
| 1-4 | 所有館員 | 這兩天有沒有系統「連不上」或「被拒絕存取」 | 沒有（有的話可能是外部系統的 IP 白名單） |
| 2-1～2-4 | 櫃台電腦 | 登入借還書系統、實際借還一本、列印收據、開網站 | 都正常 |
| 3-1 | 讀者電腦（兒童區、成人區各一台） | 開查詢外網 IP 的網站 | `<WAN A IP>` |
| 3-2 | 同上 | 開新聞網站 | 正常 |
| 3-3 | 同上 | 開資訊人員提供的測試網址（不當網站） | 被阻擋 |
| 3-4 | 同上 | 命令提示字元 `ping <LAN1>.70` | 要求等候逾時（連不到館員電腦） |
| 4-1 | 手機 | 連 `<讀者 SSID>`，看 IP | `<VLAN80>.` 開頭 |
| 4-2～4-4 | 同上 | 查外網 IP、開不當網站、開新聞網站 | `<WAN A IP>`、被阻擋、正常 |
| 5-1～5-4 | 現場查看 | 小型交換器下接了什麼、不明設備是誰的 | 記錄結果，**只看不拔** |
| 6-1 | 館員電腦 | `ping <LAN1>.253` 後 `arp -a <LAN1>.253`，拍照回傳 | 取得閘道 MAC（給 Layer 2 isolation 用） |

## 12. 常見問題

這次實作的完整常見問題見主文章〈[常見問題](../zyxel-nebula-library-vlan-dual-wan-plan/#8-常見問題)〉。下面是附錄這份清單特別相關的：

| 現象 | 怎麼辦 |
| --- | --- |
| 刪了一條安全政策後，館員突然不能上網、Nebula 設備離線 | 檢查 `LAN_Outgoing`（LAN 對外放行）還在不在。刪除規則前先截圖，刪完再對一次清單 |
| 照著這份清單做，畫面欄位名稱不一樣 | 本案 Nebula 版本 20.20；不同版本選單名稱可能不同 |
| 要把某台讀者電腦改回舊網段 | LAN1 的讀者舊綁定已刪除，要先把綁定加回 LAN1，再把交換器埠改回 PVID 1 |

## 13. 待辦

- [ ] 現場確認清單（第 11 節）全部完成並回收
- [ ] 取得閘道 MAC，讀者 SSID 補開 Layer 2 isolation
- [ ] 確認 CIP 過濾依賴的授權與到期日（Pro Pack 試用約 30 天後到期）
- [ ] 拔線測試：單一 WAN 斷線時的切換；預設路由走哪條線
- [ ] 查出用途不明的有線設備（1F 第 8、17、20 埠）
- [ ] 確認新網段沒有和 VPN 或其他分館重疊
- [ ] 觀察讀者無線尖峰時段的 IP 使用量
- [ ] （選用）路由規則 3 的 Source 改成 Any；網路設備管理獨立成一個 VLAN

## 14. 延伸閱讀

- [圖書館 Nebula 網路改造：VLAN 隔離讀者、CIP 過濾、兩條 FTTB 分流](../zyxel-nebula-library-vlan-dual-wan-plan/)：主文章，觀念、做法與踩雷
- [有用中華電信資安艦隊：DNS 為什麼不能設 8.8.8.8？](../cht-security-fleet-dns-filtering/)：防火牆 DNS 要填什麼
