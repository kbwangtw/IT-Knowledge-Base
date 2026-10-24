---
layout: default
title: "HPE Aruba 1930／1920S 網頁介面切 VLAN：Tagged 對防火牆、Untagged 給電腦"
date: 2022-01-17
categories: [Network, HPE, VLAN, Blogger 舊文]
permalink: /docs/blogger/network/hp-1930s-vlan/
last_modified_at: 2026-10-24
---

# HPE Aruba 1930／1920S 網頁介面切 VLAN：Tagged 對防火牆、Untagged 給電腦

> **一句話**：在 1930 的網頁介面建好 VLAN 10、15、20，把接防火牆的 Port 1 設成三個 VLAN 都 **Tagged**，接電腦的 Port 10／15／20 各自設成對應 VLAN 的 **Untagged**，最後一定要按 **Save**。

| 項目 | 內容 |
| --- | --- |
| 適合誰看 | 第一次在 HPE／Aruba 網管交換器上切 VLAN 的人；熟 Cisco、想知道 HP 怎麼對應的人 |
| 環境 | HPE（Aruba）OfficeConnect 1930，網頁管理介面；1920S 操作方式相同 |
| 日期 | 2022-01-17（原文發表於 Blogger，2026-10-24 改寫為新手版） |
| 結論 | ✅ VLAN 10／15／20 建立 ✅ Port 1 三個 VLAN Tagged ✅ Port 10／15／20 各自 Untagged |

## 1. 先認識幾個名詞

| 名詞 | 白話解釋 |
| --- | --- |
| **VLAN** | 在同一台交換器上切出好幾個互不相通的網段，像在一棟樓裡隔出好幾間辦公室 |
| **VLAN ID** | 每個 VLAN 的編號（1～4094），本例用 10、15、20 |
| **Tagged** | 封包帶著「我屬於哪個 VLAN」的標籤出去；一條線可以同時跑多個 VLAN，用在交換器↔防火牆／交換器之間 |
| **Untagged** | 封包不帶標籤；電腦、印表機這類一般設備只看得懂這種 |
| **Trunk（Cisco 用語）** | 等於 HP 的「一個 Port 設多個 VLAN Tagged」 |
| **Access（Cisco 用語）** | 等於 HP 的「一個 Port 只在一個 VLAN 裡 Untagged」 |
| **Participation** | 1930 介面上設定「這個 Port 要不要加入這個 VLAN」的選項 |

### Cisco 和 HP 用語對照

| 想做的事 | Cisco 說法 | HP／Aruba 說法 |
| --- | --- | --- |
| 一條線跑多個 VLAN | Trunk | 在每個 VLAN 都設 **Tagged** |
| 一個 Port 只給一個 VLAN | Access | 在該 VLAN 設 **Untagged** |

## 2. 要做到的架構

```text
                 防火牆
                   │  Port 1：VLAN 10、15、20 都是 Tagged
            ┌──────┴──────────────────────────┐
            │         HPE 1930 交換器          │
            └──┬──────────┬──────────┬────────┘
       Port 10 │  Port 15 │  Port 20 │      （都是 Untagged）
            VLAN 10    VLAN 15    VLAN 20
            的電腦      的電腦      的電腦
```

| Port | 接什麼 | VLAN 設定 |
| --- | --- | --- |
| 1 | 防火牆 | 10、15、20 都 **Tagged** |
| 10 | VLAN 10 的設備 | 10 **Untagged** |
| 15 | VLAN 15 的設備 | 15 **Untagged** |
| 20 | VLAN 20 的設備 | 20 **Untagged** |

## 3. 步驟一：建立 VLAN

**做什麼**：先把 VLAN 10、15、20 建出來。

**怎麼做**：登入 1930 網頁介面 → VLAN 設定頁 → 新增 VLAN，分別輸入 **VLAN ID** 和**名稱**（例如 `VLAN10`），共建三個。

**應該看到什麼**：VLAN 清單中出現 10、15、20。

## 4. 步驟二：（需要的話）在 VLAN 介面設 IP

**做什麼**：如果要從某個 VLAN 連進交換器管理，或要讓交換器在這個網段有位址，就在該 VLAN 的介面上設 IP。原作者在 VLAN 15 設了一個。

**怎麼做**：介面設定 → 選 **VLAN 15** → 輸入 IP 位址與遮罩（例如 `192.0.2.x/24`，請換成你的網段）。

> 只是要切網段、路由交給防火牆做的話，這步可以略過。

## 5. 步驟三：把電腦用的 Port 設成 Untagged

**做什麼**：讓 Port 15 只屬於 VLAN 15，接上去的電腦就在 VLAN 15。

**怎麼做**：

1. 進 VLAN 的 Port 設定頁，**VLAN ID** 選 **15**。
2. 在 Port 清單選 **Port 15** → 按 **Edit**。
3. **Participation** 選 **Include**，**Tagging** 選 **Untagged** → 按 **Apply**。

**再重複兩次**：

| VLAN ID 選 | 設定的 Port | Participation | Tagging |
| --- | --- | --- | --- |
| 10 | Port 10 | Include | Untagged |
| 20 | Port 20 | Include | Untagged |

## 6. 步驟四：把接防火牆的 Port 1 設成 Tagged

**做什麼**：讓 Port 1 同時帶著三個 VLAN 跑到防火牆。

**怎麼做**：在每個 VLAN 都做一次——**VLAN ID** 依序選 10、15、20，每次都選 **Port 1** → **Edit** → **Participation** 選 **Include**，**Tagging** 選 **Tagged** → **Apply**。

| VLAN ID 選 | 設定的 Port | Participation | Tagging |
| --- | --- | --- | --- |
| 10 | Port 1 | Include | **Tagged** |
| 15 | Port 1 | Include | **Tagged** |
| 20 | Port 1 | Include | **Tagged** |

> 小技巧：同一個 VLAN 的 Untagged Port 和 Port 1 可以一起設好再換下一個 VLAN，比較不會漏。

## 7. 步驟五：存檔

**做什麼**：把設定寫進開機設定檔。

**怎麼做**：按介面上的 **Save**（儲存設定）。

**應該看到什麼**：存檔成功的提示。

> ⚠️ 只按 Apply 不按 Save，**重開機後設定全部消失**。

## 8. 步驟六：確認

| 檢查項目 | 應該看到的結果 |
| --- | --- |
| Port 15 接一台電腦 | 拿到 VLAN 15 網段的 IP（由防火牆的 DHCP 發），通得到 VLAN 15 的閘道 |
| Port 10 和 Port 15 的電腦互 ping | 防火牆沒開放的話應該**不通**（不同 VLAN） |
| 防火牆那端 | Port 1 接的介面要建好 VLAN 10／15／20 子介面，ID 要對上 |

## 9. 常見問題

| 現象 | 怎麼辦 |
| --- | --- |
| 電腦接上去拿不到 IP | 檢查那個 Port 是否在正確 VLAN 設成 Untagged；防火牆端該 VLAN 有沒有開 DHCP |
| 某個 VLAN 出不去，其他正常 | Port 1 在那個 VLAN 可能漏設 Tagged；防火牆端 VLAN ID 是否一致 |
| 重開機後設定不見 | 沒按 Save |
| Port 還在 VLAN 1 裡 | 預設每個 Port 都在 VLAN 1 Untagged；確認不需要的話把它從 VLAN 1 移除（Exclude），避免一個 Port 兩個 Untagged VLAN |

## 10. 待辦

- [ ] 補上網頁介面截圖（原文截圖在 Blogger 上已失效）

## 11. 延伸閱讀

- [HPE 社群：VLAN setup on HP OfficeConnect 1920S](https://community.hpe.com/t5/LAN-Routing/VLAN-setup-on-HP-OfficeConnect-1920s/m-p/7017815)
- [Blogger 原文](https://kbwangtw.blogspot.com/2022/01/hp-1930s-vlan.html)
