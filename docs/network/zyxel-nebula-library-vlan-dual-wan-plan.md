---
layout: default
title: "圖書館 Nebula 網路規劃：讀者 Wi-Fi 切 VLAN、兩條 FTTB 分流"
permalink: /docs/network/zyxel-nebula-library-vlan-dual-wan-plan/
date: 2026-10-20
categories: [Network, VLAN, Zyxel, Nebula, Dual WAN]
last_modified_at: 2026-10-20
---

# 圖書館 Nebula 網路規劃：讀者 Wi-Fi 切 VLAN、兩條 FTTB 分流

> **一句話**：館員和讀者共用一個 SSID、一個 /24 網段時，讀者看得到館內設備，IP 也容易用光；做法是多開一個館員 SSID，把讀者 SSID 移到獨立 VLAN，再用 Policy Route 讓讀者走另一條 FTTB。**順序是先開館員 SSID，再搬讀者**。

| 項目 | 內容 |
| --- | --- |
| 適合誰看 | 公共場所（圖書館、活動中心）同時有內部人員與訪客上網，想把兩邊分開的人 |
| 環境 | USG FLEX 100H ×1、XGS2220 ×1（核心）、GS1920 ×3（1F～3F 各一台）、NWA90AX ×9（每層 3 台），全部由 Nebula 管理；FTTB ×2。架構依 Nebula 拓撲圖確認 |
| 日期 | 2026-10-20 規劃 |
| 結論 | ⏳ 規劃完成，**尚未實作**；雙 WAN 備援行為與部分 Nebula 欄位**未確認** |
| 設定方法 | 見 [Zyxel Nebula VLAN 設定 SOP](../zyxel-nebula-switch-vlan/)，本篇只寫這個案例的規劃與順序 |

## 1. 先認識幾個名詞

| 名詞 | 白話解釋 |
| --- | --- |
| **FTTB** | 光纖到大樓的固定制網路，本案有兩條，各有一個固定外網 IP |
| **WAN** | 防火牆「接網際網路」的那一側；兩條 FTTB＝兩個 WAN |
| **Policy Route**（政策路由） | 依「誰送的」決定走哪條 WAN，例如讀者網段一律走 WAN B |
| **WAN Trunk**（負載平衡） | 把多條 WAN 綁在一起，自動分流或主備切換 |
| **用戶端隔離** | 同一個 SSID 裡的手機彼此看不到，避免讀者互相掃描（Nebula 欄位名稱未確認） |
| **DPPSK** | 一個 SSID、每人一組密碼，並依密碼分到不同 VLAN。本案**沒有採用**，原因見第 4 節 |

## 2. 現況與問題

```text
              WAN A（FTTB）    WAN B（FTTB）
                    \            /
                   USG FLEX 100H        ← <內網>/24 的閘道 + DHCP
                         │
                   Core-XGS2220（核心）
           ┌─────────────┼─────────────┐
       1F-GS1920     2F-GS1920     3F-GS1920
       AP01～03       AP01～03      AP01～03     ← NWA90AX ×9
         （每層 3 台；SSID：<SSID>，館員與讀者共用）
```

| 問題 | 說明 |
| --- | --- |
| 讀者和館內設備在同一網段 | 連 Wi-Fi 的讀者可以直接掃描、存取館內電腦、印表機 |
| IP 不夠用 | /24 只有 254 個 IP，扣掉網路設備 14 台、館內電腦，剩下的要給所有讀者手機 |
| 兩條 FTTB 沒分工 | 讀者大量下載時，可能拖慢館員的業務系統（推測，未量測） |

## 3. 目標架構

```text
                  WAN A ───────┐         ┌─────── WAN B
             （館員、管理）     │         │     （讀者）
                          USG FLEX 100H
             LAN1（VLAN 1，不帶標籤）＋ vlan10 ＋ vlan20
                                │ Trunk：PVID 1，允許 1,10,20
                          Core-XGS2220
                                │ Trunk
                    1F／2F／3F-GS1920（各 1 台）
                                │ Trunk
                     每層 AP01～AP03（共 9 台）
                    ┌───────────┴───────────┐
           <SSID>-staff（VLAN 10）    <SSID>（VLAN 20）
               館員 Wi-Fi                 讀者 Wi-Fi
```

| VLAN | 用途 | 網段大小 | DHCP 租約 | 走哪條 WAN |
| --- | --- | --- | --- | --- |
| 1（不變） | 管理＋館員有線 | /24（維持現狀） | 維持現狀 | A |
| 10（新增） | 館員 Wi-Fi | /24 | 7 天 | A |
| 20（新增） | 讀者 Wi-Fi | /23（約 510 個 IP） | 8 小時 | B |

設計上的考量：

| 決定 | 為什麼 |
| --- | --- |
| 原本的網段**不動** | 防火牆、交換器、AP 的管理 IP 和館員電腦都不用重設，改錯也不會讓設備從 Nebula 離線 |
| 讀者用 /23 | 沒有尖峰人數資料，先保守取大一點 |
| 讀者租約 8 小時 | 讀者來來去去，租約太長，Pool 會被已經離開的手機占住 |

## 4. 為什麼多開一個 SSID，而不用 DPPSK

| 做法 | 優點 | 缺點 |
| --- | --- | --- |
| **多開館員 SSID**（採用） | 不需要額外授權，所有 AP 都支援 | 多一個 SSID 名稱；館員設備要重新連線一次 |
| DPPSK（一個 SSID 依密碼分 VLAN） | 讀者、館員看到同一個 SSID | 需要 Nebula Pro Pack 授權；Zyxel 社群列出的支援清單**沒有 NWA90AX**（未向原廠確認） |

## 5. 實作順序

做什麼：在不影響館員作業的前提下，把讀者搬到 VLAN 20。建議在**閉館時段**進行。

| 步驟 | 做什麼 | 對誰有影響 | 應該看到 |
| --- | --- | --- | --- |
| 0 | 截圖記錄目前的防火牆介面、交換器埠、SSID 設定 | 無 | 有可以回滾的依據 |
| 1 | 100H 新增 `vlan10`、`vlan20` 介面＋DHCP（[SOP 4-3](../zyxel-nebula-switch-vlan/#4-3-新增-vlan-介面)） | 無 | 介面清單多兩個介面 |
| 2 | 確認 100H↔核心、核心↔三台 GS1920、GS1920↔AP 共 13 條連線的埠都是 Trunk，允許的 VLANs 包含 1、10、20（[SOP 7](../zyxel-nebula-switch-vlan/#7-設定-trunk-埠接中繼設備)） | 無 | 埠清單符合規劃 |
| 3 | 新增 `<SSID>-staff`，VLAN ID 10（[SOP 8](../zyxel-nebula-switch-vlan/#8-設定-ap-的-ssid-vlan-id員工訪客分開)） | 無 | 手機連上拿到 VLAN 10 的 IP，能列印、能上網 |
| 4 | 館員設備改連 `<SSID>-staff`，並在設備上「忘記」`<SSID>` | 館員短暫斷線 | 館員設備都在 VLAN 10 |
| 5 | 100H 加安全政策（第 6 節） | 無 | — |
| 6 | `<SSID>` 的 VLAN ID 改成 20，按**儲存** | 讀者斷線重連 | 讀者拿到 VLAN 20 的 IP，ping 不到館內網段 |
| 7 | 加 Policy Route（第 7 節） | 短暫 | 讀者查外網 IP＝WAN B；館員＝WAN A |
| 8 | 拔 WAN B 的線測試 | 讀者短暫斷線 | 讀者是否自動改走 WAN A（**未確認**） |

> ⚠️ **為什麼步驟 3、4 要在步驟 6 前面**：館員原本也連 `<SSID>`。先把 `<SSID>` 改到 VLAN 20 的話，館員的筆電會被擋在讀者網段，連不到館內印表機和系統。

**回滾**：把 `<SSID>` 的 VLAN ID 清空並儲存，讀者就會回到原本的網段。

## 6. 安全政策

| 來源 | 目的 | 動作 |
| --- | --- | --- |
| VLAN 20（讀者） | VLAN 1、VLAN 10 | 拒絕 |
| VLAN 20（讀者） | 防火牆管理介面 | 拒絕 |
| VLAN 20（讀者） | 網際網路 | 允許 |
| VLAN 10（館員 Wi-Fi） | VLAN 1 | 允許（印表機、館內系統） |

## 7. 兩條 FTTB 分流

| 規則 | 來源 | 走 |
| --- | --- | --- |
| 1 | VLAN 20（讀者） | WAN B（`203.0.113.x`） |
| 2 | VLAN 1、VLAN 10（館員） | WAN A（`198.51.100.x`） |

Nebula 位置：**整個站點 > 設定 > 防火牆 > 路由**（依 Zyxel 支援文件；100H 的實際選單**未確認**）。

| 注意 | 說明 |
| --- | --- |
| 單線斷線時會不會自動切換 | **未確認**，第 5 節步驟 8 要實測 |
| WAN Trunk 在 Nebula 設不了 | Zyxel 社群回覆說 H 系列的 WAN Trunk 目前要用本機網頁設定（回覆日期不明，現在是否已支援**未確認**）。在本機網頁改的設定可能被 Nebula 覆蓋，所以先只用 Nebula 上的 Policy Route |
| 綁定外網 IP 的服務 | VPN、NAT、對方網站的 IP 白名單，分流後要確認還是走原本那條 WAN |

## 8. 常見問題

| 現象 | 怎麼辦 |
| --- | --- |
| 改完 `<SSID>` 後，館員連不到印表機 | 館員設備還連在 `<SSID>`（現在是讀者網段），請改連 `<SSID>-staff` |
| 讀者連上但拿不到 IP | 依 [SOP 8-5](../zyxel-nebula-switch-vlan/#8-5-確認整條路徑都設好了) 檢查：接 AP 的埠是否 Trunk、允許清單是否有 20、`vlan20` 介面是否開了 DHCP |
| 交換器或 AP 從 Nebula 離線 | Trunk 的允許清單漏了 `1`（管理 VLAN），把 `1` 加回去 |
| 讀者還是 ping 得到館內設備 | 第 6 節的安全政策沒有生效，或規則順序不對 |

## 9. 待辦

- [ ] 補上每條連線的埠號（設備與連線關係已從 Nebula 拓撲圖確認）
- [ ] 確認新網段沒有和 VPN 或其他網段重疊
- [ ] 統計讀者尖峰同時上線人數，確認 /23 夠不夠用
- [ ] 確認 100H 目前雙 WAN 是負載平衡還是主備
- [ ] 實作後補上實測結果與截圖，把結論改成 ✅
- [ ] 實測 Policy Route 在單線斷線時的行為

## 10. 延伸閱讀

- [Zyxel Nebula VLAN 設定：防火牆介面、交換器 Trunk／Access、AP SSID 一次搞懂](../zyxel-nebula-switch-vlan/)：本篇用到的每個設定步驟
- [Nebula USGFLEX/ATP/VPN - Routing and Traffic Shaping configuration](https://support.zyxel.eu/hc/en-us/articles/360020464860)：Nebula 路由與 Policy Route 設定位置
- [USG Flex H Series Load Balancing In Nebula Mode](https://community.zyxel.com/en/discussion/comment/77409/)：H 系列在 Nebula 下的負載平衡討論
- [[Nebula] Dynamic Personal Pre-Shared Key (DPPSK)](https://community.zyxel.com/vn/discussion/16890/nebula-dynamic-personal-pre-shared-key-dppsk)：DPPSK 支援機型清單
