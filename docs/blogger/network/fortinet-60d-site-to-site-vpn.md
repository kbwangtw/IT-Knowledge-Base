---
layout: default
title: "FortiGate 60D 兩廠之間建立 Site-to-Site IPsec VPN"
date: 2014-04-29
categories: [Network, Fortinet, VPN, Firewall, Blogger 舊文]
permalink: /docs/blogger/network/fortinet-60d-site-to-site-vpn/
last_modified_at: 2026-10-24
---

# FortiGate 60D 兩廠之間建立 Site-to-Site IPsec VPN

> **一句話**：兩台 FortiGate 各自設定 Phase 1（對方 WAN IP + 預先共用金鑰）與 Phase 2，再加一條「往對方內網走 VPN 介面」的靜態路由，以及兩條雙向放行的防火牆政策，兩廠內網就能互通。

| 項目 | 內容 |
| --- | --- |
| 適合誰看 | 兩個據點各有一台 FortiGate，想讓兩邊內網互通的人 |
| 環境 | FortiGate 60D × 2（FortiOS 5.x 中文介面）；介面模式（Interface Mode）的 IPsec VPN |
| 日期 | 2014-04-29（原文發表於 Blogger，2026-10-24 改寫為新手版） |
| 結論 | ✅ 兩廠內網經由 VPN 互通 |

> 原文附了 13 張設定截圖，因為畫面中含有客戶據點名稱，這裡改用表格整理截圖中的設定值。

## 1. 先認識幾個名詞

| 名詞 | 白話解釋 |
| --- | --- |
| **Site-to-Site VPN** | 兩個地點的防火牆之間建一條加密通道，兩邊內網像接在一起 |
| **IPsec** | 最常見的 VPN 加密標準 |
| **Phase 1（IKE）** | 兩台防火牆先「認識彼此、交換金鑰」的階段 |
| **Phase 2** | 決定實際資料怎麼加密的階段 |
| **預先共用金鑰（PSK）** | 兩邊事先講好的同一組密碼 |
| **DH 群組** | 交換金鑰時用的數學參數；兩邊必須一致 |
| **介面模式 VPN** | VPN 會變成一個虛擬介面，可以像一般介面一樣寫路由和政策 |

## 2. 架構

```text
     舊廠                               新廠
 內網 192.0.2.0/24                  內網 198.51.100.0/24
 FortiGate internal 192.0.2.1       FortiGate internal 198.51.100.1
        │                                  │
 FortiGate wan1 <舊廠 WAN IP>  ══ IPsec ══  FortiGate wan1 <新廠 WAN IP>
                         （網際網路）
```

> 原文 WAN 與內網都是私有位址的測試環境，這裡改用示範位址與代稱。

## 3. 步驟一：舊廠設定 Phase 1

**怎麼做**：**VPN → IPsec → Auto Key (IKE)** → 建立 Phase 1：

| 欄位 | 設定 |
| --- | --- |
| 名稱 | `Fortiget_VPN_P1`（自訂） |
| 遠端閘道 | 固定 IP 位址 |
| IP 位址 | `<新廠 WAN IP>` |
| 本地介面 | `wan1` |
| 模式 | 主要模式（Main，ID 保護） |
| 認證方式 | 預先共用金鑰，輸入兩邊相同的 `<共用金鑰>` |
| Peer 選項 | 接受任何 Peer ID |
| IKE 版本 | 1 |
| P1 提議 | 3DES／SHA1、AES128／SHA1 |
| DH 群組 | 5 |
| 金鑰週期 | 28800 秒 |
| XAUTH | 關閉 |
| NAT Traversal | 啟用 |
| 保持連線頻率 | 10 秒 |
| 對點連線偵測（DPD） | 啟用 |

> 2014 年的預設提議含 3DES、SHA1、DH 5，現在都已不建議。新設備請改用 **AES256 + SHA256、DH 14 以上**，兩邊一致即可。

## 4. 步驟二：舊廠設定 Phase 2

| 欄位 | 設定 |
| --- | --- |
| 名稱 | `Fortiget_VPN_P2` |
| Phase 1 | 選剛剛的 `Fortiget_VPN_P1` |
| P2 提議 | 3DES／SHA1、AES128／SHA1 |
| 重送偵測 | 啟用 |
| 完全正向保密（PFS） | 啟用，DH 5 |
| 金鑰週期 | 1800 秒 |
| 快速模式選擇器 | 來源、目的都是 `0.0.0.0/0`（不限制） |

## 5. 步驟三：舊廠加一條往新廠的路由

**怎麼做**：**路由 → 靜態路由 → 新增**：

| 欄位 | 設定 |
| --- | --- |
| 目的 IP／網路遮罩 | `198.51.100.0/255.255.255.0`（新廠內網） |
| 設備 | `Fortiget_VPN_P1`（VPN 介面） |
| 距離 | 10 |

**意思**：要去新廠內網的封包，丟進 VPN 通道。

## 6. 步驟四：舊廠加兩條防火牆政策

| 欄位 | 政策 A（舊廠 → 新廠） | 政策 B（新廠 → 舊廠） |
| --- | --- | --- |
| 入介面 | `internal` | `Fortiget_VPN_P1` |
| 來源位址 | 舊廠內網物件 | 新廠內網物件 |
| 出介面 | `Fortiget_VPN_P1` | `internal` |
| 目的位址 | 新廠內網物件 | 舊廠內網物件 |
| 排程／服務 | always／ALL | always／ALL |
| 動作 | ACCEPT | ACCEPT |
| NAT | **不勾** | **不勾** |

> 先在 **防火牆物件 → 位址** 建好兩邊內網的位址物件，政策裡才選得到。

## 7. 步驟五：新廠做相同設定（鏡像）

新廠照步驟一～四再做一次，只要把「對方」換過來：

| 項目 | 新廠的值 |
| --- | --- |
| Phase 1 遠端閘道 | `<舊廠 WAN IP>` |
| 共用金鑰、提議、DH、週期 | **和舊廠完全相同** |
| 靜態路由目的 | `192.0.2.0/255.255.255.0`（舊廠內網） |
| 政策 | 一樣兩條，方向對調 |

## 8. 步驟六：確認

**怎麼做**：**VPN → 監控 → IPsec 監控**。

**應該看到什麼**：`Fortiget_VPN_P1` 狀態為「上」（綠色），進出流量位元組有數字在增加；兩邊內網電腦可以互相 ping 通。

## 9. 常見問題

| 現象 | 怎麼辦 |
| --- | --- |
| Phase 1 一直起不來 | 兩邊的共用金鑰、提議、DH 群組、模式要完全一致；確認對方 WAN IP 正確 |
| 通道是上的，但 ping 不通 | 少了靜態路由或政策；政策不要勾 NAT |
| 只有單向通 | 兩邊各要有「出」和「進」兩條政策 |
| 一陣子沒流量就斷線 | 開啟 DPD 與保持連線；或兩邊金鑰週期不一致 |

## 10. 延伸閱讀

- [Fortinet 文件庫：IPsec VPN](https://docs.fortinet.com/)
- [FortiGate 只允許指定外網 IP ping WAN](../fortigate-local-in-policy-ping/)
- [Blogger 原文](https://kbwangtw.blogspot.com/2014/04/fortinet-60d-vpn.html)
