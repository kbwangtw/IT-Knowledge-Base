---
layout: default
title: "Edge-core ES4612 接 Cisco 3500XL 一直被 Spanning Tree 擋住"
date: 2011-03-03
categories: [Network, Cisco, Edge-core, STP, Blogger 舊文]
permalink: /docs/blogger/network/edgecore-es4612-cisco-3500xl-stp/
last_modified_at: 2026-10-24
---

# Edge-core ES4612 接 Cisco 3500XL 一直被 Spanning Tree 擋住

> **一句話**：兩台不同廠牌的交換器對接時，Cisco 一直報 Spanning Tree 錯誤並封鎖 Port；先把兩端 Port 類型對齊（都 Trunk 或都 Access），仍然 VLAN 不一致時，最後在 ES4612 上關閉 Spanning Tree 才連通。

| 項目 | 內容 |
| --- | --- |
| 適合誰看 | 不同廠牌交換器對接，Port 一直被 block、Log 一直跳 SPANTREE 訊息的人 |
| 環境 | Edge-core ES4612（12 Port 光纖交換器，出廠預設）↔ Cisco 3500XL Gi0/1；光纖或 RJ-45 皆同 |
| 日期 | 2011-03-03（原文發表於 Blogger，2026-10-24 改寫為新手版） |
| 結論 | ✅ 關閉 ES4612 的 Spanning Tree 後連通 ⏳ 根本原因（VLAN 不一致）未進一步處理 |

## 1. 先認識幾個名詞

| 名詞 | 白話解釋 |
| --- | --- |
| **Spanning Tree（STP）** | 防止交換器之間形成迴圈的協定；發現異常時會把 Port 擋掉（block） |
| **BPDU** | 交換器之間交換 STP 資訊的封包 |
| **Trunk／Access** | 一條線跑多個 VLAN（帶標籤）／只跑一個 VLAN（不帶標籤） |
| **802.1Q（dot1q）** | VLAN 標籤的標準格式 |
| **PVID** | Port 預設的 VLAN 編號（native VLAN） |

## 2. 問題經過

```text
第一個錯誤：Port 類型不一致
  ES4612 端是 802.1Q（帶標籤）   ×   3500XL Gi0/1 是 Access（不帶標籤）
        │ 把 3500XL 改成 Trunk
        ▼
第二個錯誤：VLAN 不一致
  ES4612 送來的 BPDU 是 VLAN 236   ×   3500XL 這端是 VLAN 1
        │ 在 ES4612 關閉 Spanning Tree
        ▼
連線正常
```

## 3. 第一個錯誤：Port 類型不一致

**看到的訊息**（Cisco 3500XL）：

```text
%SPANTREE-7-RECV_1Q_NON_TRUNK: Received 802.1Q BPDU on non trunk GigabitEthernet0/1 VLAN1.
%SPANTREE-7-BLOCK_PORT_TYPE: Blocking GigabitEthernet0/1 on VLAN0001. Inconsistent port type.
```

**意思**：對面送來的是帶 802.1Q 標籤的 BPDU，但 Gi0/1 是 Access Port，兩邊類型對不上，所以 Cisco 把這個 Port 擋掉。

**解法（二選一）**：

| 做法 | 在哪裡改 |
| --- | --- |
| A. 對面（ES4612）的 Port 改成 Access（不帶標籤） | ES4612 |
| B. 3500XL 的 Gi0/1 改成 Trunk | Cisco，指令如下 |

```text
interface GigabitEthernet0/1
 switchport trunk encapsulation dot1q
 switchport mode trunk
```

## 4. 第二個錯誤：VLAN 不一致

改成 Trunk 後，訊息換成：

```text
%SPANTREE-2-RECV_PVID_ERR: Received BPDU with inconsistent peer vlan id 236 on GigabitEthernet0/1 VLAN1.
%SPANTREE-2-BLOCK_PVID_LOCAL: Blocking GigabitEthernet0/1 on VLAN0001. Inconsistent local vlan.
```

**意思**：對面送來的 BPDU 標示的是 VLAN 236，但 Cisco 這端的 native VLAN 是 1，兩邊 native VLAN 不一致，Port 又被擋了。

## 5. 最後的處理：關閉 ES4612 的 Spanning Tree

原作者在 ES4612 上用 `nospa` 指令停用 Spanning Tree 之後，兩台就能正常連線。

> ⚠️ 關掉 STP 後，若網路中有人不小心接出迴圈，會造成廣播風暴。較好的做法是**把兩端的 native VLAN（PVID）設成一致**，保留 STP。原文當時沒有實測這個做法，屬於建議（未確認）。

## 6. 常見問題

| 現象 | 怎麼辦 |
| --- | --- |
| `Inconsistent port type` | 兩端一個 Trunk、一個 Access；改成一致 |
| `inconsistent peer vlan id` | 兩端 native VLAN 不同；查 ES4612 的 PVID 並和 Cisco 對齊 |
| 關掉 STP 後網路變得很慢、燈號狂閃 | 可能出現迴圈；找出多接的那條線，並考慮把 STP 開回來 |

## 7. 待辦

- [ ] 改用「兩端 native VLAN 一致」的方式，把 ES4612 的 STP 開回來

## 8. 延伸閱讀

- [Cisco 3750 與 2960 之間設定 Trunk](../cisco-3750-2960-trunk/)
- [Blogger 原文](https://kbwangtw.blogspot.com/2011/03/edge-core-es4612-cisco-3500xl-es4612.html)
