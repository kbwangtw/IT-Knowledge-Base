---
layout: default
title: "Nebula 兩層樓 Site-to-Site VPN 規劃：6F USG FLEX 100 × 10F USG FLEX 50HP"
permalink: /docs/network/zyxel-nebula-site-to-site-vpn-6f-10f-plan/
date: 2026-10-22
categories: [Network, VPN, Zyxel, Nebula]
last_modified_at: 2026-10-22
---

# Nebula 兩層樓 Site-to-Site VPN 規劃：6F USG FLEX 100 × 10F USG FLEX 50HP

> **一句話**：6 樓已經有一台 USG FLEX 100（PPPoE 固定 IP），10 樓要新增一台 USG FLEX 50HP 和一台 NWA50BE 無線 AP。兩台防火牆都在 Nebula 管理，只要放在**同一個組織、各自一個站點**，打開 Nebula VPN 並選 **Hub-and-Spoke**（6F 當 Hub、10F 的 H 系列當 Spoke，這是 Zyxel 官方對「H 系列配舊款 USG FLEX」的建議設定），Nebula 就會自動建好 IPsec 通道，不用手動填金鑰和對方 IP。互通的只有 6F LAN 1 和 10F LAN 1，6F LAN 2 不加入。

| 項目 | 內容 |
| --- | --- |
| 適合誰看 | 公司有兩個地點（兩層樓、總部與分點），想讓兩邊電腦互相連線；第一次在 Nebula 做 Site-to-Site VPN 的人 |
| 環境 | 6F：USG FLEX 100（既有，ZLD 韌體）；10F：USG FLEX 50HP（H 系列，uOS 韌體）、NWA50BE（Wi-Fi 7 雙頻 AP）；全部由 Nebula 管理 |
| 規模 | 10F：1 人、3 台設備 |
| 日期 | 2026-10-22 規劃 |
| 資料來源 | 現場既有設定與新增需求；Zyxel 社群官方 FAQ（H 系列當 Spoke 的設定方式，2025-03）與社群討論；NWA50BE 規格取自經銷商頁面與 Zyxel 社群回覆，正式數字以 Zyxel 官方 datasheet 為準 |
| 結論 | ✅ 網段規劃無重疊；✅ 拓撲定為 Hub-and-Spoke（6F Hub、10F Spoke）；✅ 6F LAN 2 不加入 VPN；✅ AP 確定為 NWA50BE；✅ 10F DHCP Pool 41 個足夠；⏳ 10F WAN 型態未定；⏳ 10F 設備註冊與設定、VPN 建立與驗收 |

## 1. 先認識幾個名詞

| 名詞 | 白話解釋 |
| --- | --- |
| **Nebula** | Zyxel 的雲端管理平台。設備接上網路後，設定都在網頁上改，設備自己去雲端拿設定 |
| **組織（Organization）／站點（Site）** | Nebula 的兩層分類：組織是「公司」，站點是「一個地點」。**一個站點只能放一台防火牆**，所以 6F、10F 要各開一個站點 |
| **ZLD／uOS** | Zyxel 防火牆的兩種韌體。舊款 USG FLEX 100 跑 ZLD；名稱有 H 的新款（例如 USG FLEX 50HP）跑 uOS。兩種在 Nebula 上的選單和功能不完全一樣 |
| **Site-to-Site VPN** | 兩個地點的防火牆之間拉一條加密通道，讓兩邊內網像接在同一個網路一樣互通；電腦不用裝任何軟體 |
| **IPsec** | Site-to-Site VPN 最常用的加密協定。Nebula VPN 底層就是 IPsec |
| **Nebula VPN** | Nebula 的「自動 VPN」：同一個組織裡的防火牆打開這個功能，Nebula 自動交換金鑰、對方 IP 和網段，不用手動設定 |
| **拓撲（Topology）** | 通道怎麼連。**Site-to-Site**：每個站點兩兩互連；**Hub-and-Spoke**：一個中心點（Hub），其他站點（Spoke）都連到它 |
| **Hub／Spoke** | 像腳踏車輪：Hub 是輪軸（中心），Spoke 是輻條（分點）。本案 6F 是 Hub、10F 是 Spoke |
| **Local networks／Use VPN** | 防火牆上每個 LAN 網段旁邊的開關：Use VPN 打開，這個網段才會被放進 VPN、讓對方看得到 |
| **PPPoE** | 用帳號密碼「撥號」上網的方式。中華電信光世代常見，可以搭配固定 IP |
| **DDNS** | 動態 DNS：IP 會變的線路，用一個固定名稱指到目前的 IP。Nebula VPN 用它找到浮動 IP 的那一端 |
| **WAN／LAN** | 防火牆接網際網路的那一側叫 WAN；接內部電腦的那一側叫 LAN |
| **Port group（埠群組）** | 把幾個實體埠綁成同一個網段，例如 P2～P5 同屬 LAN 1 |
| **DHCP Pool／約期（Lease）** | 防火牆自動發 IP 的範圍；約期是發出去的 IP 可以用多久，到期前電腦會自動續約 |
| **網段重疊** | 兩邊用了同一個網段（例如都是 192.168.1.0/24），防火牆分不出封包該留在本地還是送進 VPN，VPN 會不通 |
| **PoE／PoE+（802.3at）** | 用網路線同時供電。PoE+ 每埠最多約 30 W，NWA50BE 典型耗電約 16 W，在範圍內 |
| **MTU／MSS** | 一個封包最大能多大。PPPoE 和 IPsec 都會吃掉封包空間，太大的封包可能被丟掉 |

## 2. 全貌圖

```text
                          網際網路
             ┌───────────────┴───────────────┐
   PPPoE 固定 IP：<6F 固定 IP>        10F WAN（P1）：⏳ 型態未定
             │                                 │
   ┌─────────┴─────────┐   IPsec 通道   ┌───────┴──────────┐
   │ 6F USG FLEX 100   │◀═════════════▶│ 10F USG FLEX 50HP │
   │ 站點：6F【Hub】     │  Nebula VPN    │ 站點：10F【Spoke】 │
   └──┬─────────────┬──┘  自動建立       └───────┬──────────┘
      │             │                           │ P2～P5
  P3～P5          P6                       LAN 1：192.168.10.0/24
  LAN 1           LAN 2                         │
  192.168.0.0/24  192.168.200.0/24          NWA50BE（PoE+）
  Use VPN：是      Use VPN：否                1 人、3 台設備
                  （10F 連不到）

        ▲ 兩個站點放在 Nebula 同一個組織 ▲
```

### 2-1 網段總表

| 地點 | 網段 | 實體埠 | 閘道 | DHCP Pool | DNS | 約期 | 加入 VPN |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 6F LAN 1 | 192.168.0.0/24 | P3～P5 | 192.168.0.1 | 192.168.0.10～70（61 個） | 8.8.4.4、101.101.101.101 | 2 天 | ✅ 是 |
| 6F LAN 2 | 192.168.200.0/24 | P6 | 192.168.200.1 | 192.168.200.33～200（168 個） | 192.168.200.1 | 2 天 | ❌ 否 |
| 10F LAN 1 | 192.168.10.0/24 | P2～P5 | 192.168.10.1 | 192.168.10.10～50（41 個） | 8.8.4.4、101.101.101.101 | 2 天 | ✅ 是 |

| 檢查項目 | 結果 |
| --- | --- |
| 三個網段有沒有重疊 | ✅ 沒有。192.168.0.x、192.168.200.x、192.168.10.x 前三碼都不同 |
| 6F 的 WAN | PPPoE 撥接帶固定 IP（本文以 `<6F 固定 IP>` 代稱） |
| 10F 的 WAN | P1，型態 ⏳ 未定（PPPoE 固定 IP／PPPoE 浮動 IP／DHCP） |
| 10F 的 IP 夠不夠 | ✅ 1 人、3 台設備，Pool 41 個綽綽有餘 |

## 3. 規劃確認結果

| 問題 | 結果 | 對設定的影響 |
| --- | --- | --- |
| 6F 機型 | ✅ **USG FLEX 100**（ZLD，非 H 系列） | 和 10F 的 50HP（uOS）是不同韌體。Zyxel 官方 FAQ 的做法是 **Hub-and-Spoke，H 系列當 Spoke**，所以 6F 當 Hub、10F 當 Spoke（第 6 節） |
| 6F LAN 2 加入 VPN？ | ✅ **不要** | 6F 的 LAN 2 Use VPN 設為「否」，10F 連不到 192.168.200.x |
| AP 型號 | ✅ **NWA50BE** | Wi-Fi 7、**雙頻**（2.4 GHz＋5 GHz，**沒有 6 GHz**）、2.5G 網路埠、PoE+ 供電，典型耗電約 16 W（經銷商與 Zyxel 社群資料；正式數字以官方 datasheet 為準） |
| 10F 規模 | ✅ **1 人、3 台設備** | DHCP Pool 192.168.10.10～50 維持原規劃 |
| 10F 的 WAN | ⏳ **還不確定** | 見下方 3-1 |

### 3-1 10F 的 WAN 還沒定：各選項的影響

| 選項 | Nebula VPN | 手動 IPsec（第 7 節備案） | 建議 |
| --- | --- | --- | --- |
| PPPoE 固定 IP（50HP 自己撥號） | ✅ 最穩 | ✅ 可以 | **首選** |
| PPPoE 浮動 IP（50HP 自己撥號） | ✅ 可以，靠 DDNS 找到 10F；注意第 10 節的 DDNS 已知問題 | ⚠️ 可以，6F 固定、10F 主動撥入；設定較麻煩 | 可接受 |
| 50HP 接在 ISP 數據機或路由器後面（拿到私有 IP） | ⚠️ 可能可以，但社群回報過 H 系列 WAN 在 192.168.1.0/24 時通道建立卻不通的案例 | ⚠️ 麻煩 | 盡量避免；若無法避免，請 ISP 改橋接模式 |

> **推測**：因為 10F 是 Spoke、由 10F 主動連 6F（Hub），6F 有固定 IP，所以就算 10F 是浮動 IP，通道應該也建得起來。但社群有回報 H 系列 DDNS 不更新導致 Nebula VPN 建不起來的 bug，實際結果要以驗收為準。

## 4. 步驟一：在 Nebula 建立 10F 站點並註冊設備

**做什麼**：10F 需要自己的站點，因為一個站點只能有一台防火牆。

**怎麼做**：

1. 確認 6F 所在的組織，在**同一個組織**底下新增站點，名稱例如 `10F`
   - 路徑參考：左上角站點下拉選單 →「Create site」，或 Organization-wide → Organization-wide manage → 新增站點
2. 在 10F 站點註冊兩台設備（USG FLEX 50HP、NWA50BE），需要機身上的 **MAC 位址** 和 **序號（S/N）**
   - 路徑參考：Site-wide → Devices（或 Organization-wide → License & inventory）→ Add
3. 確認授權：Nebula VPN 需要防火牆在 Nebula 管理模式下；USG FLEX 50HP 的授權方案若影響 Nebula VPN 功能，以 Zyxel 官方說明為準（**未確認**）
4. 設備上線後，**兩台防火牆都先升到最新韌體**（Site-wide → Configure → Firmware management，名稱依版本可能不同）。社群回報過 H 系列和舊款 USG FLEX 之間的 Nebula VPN 問題是韌體 bug

**應該看到什麼**：10F 站點的裝置清單出現兩台設備，狀態為離線（還沒接線），沒有錯誤訊息。

> **注意**：不要把 10F 的防火牆加到 6F 的站點，Nebula 會不讓你加；就算是不同組織，也沒辦法用 Nebula VPN 自動互連。

## 5. 步驟二：設定 10F 防火牆的 WAN、LAN 與 DHCP

**做什麼**：先把 10F 自己的上網和內網弄好，確認能上網，再做 VPN。

### 5-1 埠的分配

| 實體埠 | 角色 | 說明 |
| --- | --- | --- |
| P1 | WAN | 接 ISP 的光纖數據機 |
| P2～P5 | LAN 1（同一個 Port group） | 接電腦、AP；NWA50BE 插在有 PoE 標示的埠 |

> 50HP 哪一埠有 PoE，以機身標示為準（**未確認**是哪一埠）。

### 5-2 WAN 設定

**怎麼做**：Site-wide → Configure → Firewall（H 系列可能顯示為 Security gateway）→ Interface，編輯 WAN：

| 欄位 | 填法 |
| --- | --- |
| 連線類型 | 依 3-1 定案的結果：PPPoE（填 ISP 給的帳號、密碼；有固定 IP 就填固定 IP）或 DHCP |
| 對應實體埠 | P1 |

### 5-3 LAN 1 與 DHCP 設定

編輯 LAN 1：

| 欄位 | 填法 |
| --- | --- |
| 對應實體埠 | P2、P3、P4、P5 |
| IP 位址 | 192.168.10.1 |
| 子網路遮罩 | 255.255.255.0（/24） |
| DHCP | DHCP Server |
| IP Pool 起始 | 192.168.10.10 |
| Pool 大小／結束 | 到 192.168.10.50（共 41 個；10F 只有 3 台設備，足夠） |
| 第一 DNS | 8.8.4.4 |
| 第二 DNS | 101.101.101.101 |
| 約期（Lease time） | 2 天 |

| DNS | 是誰的 |
| --- | --- |
| 8.8.4.4 | Google Public DNS 的第二組位址 |
| 101.101.101.101 | TWNIC 的 Quad101 公共 DNS |

> 跟 6F LAN 1 用同一組 DNS，兩層樓的上網行為才一致。

**應該看到什麼**：設備接上電、接好 WAN 線後，Nebula 顯示 50HP 上線；10F 電腦插 P2～P5 任一埠，拿到 192.168.10.10～50 之間的 IP，閘道 192.168.10.1，可以開網頁。

## 6. 步驟三：兩邊打開 Nebula VPN（Hub-and-Spoke）

**做什麼**：在 6F、10F 兩個站點都打開 Nebula VPN，拓撲選 Hub-and-Spoke：6F（USG FLEX 100）當 Hub，10F（USG FLEX 50HP，H 系列）當 Spoke，並勾選要互通的網段。

> **為什麼不用 Site-to-Site 拓撲？** 只有兩個站點時，兩種拓撲的效果一樣；但 Zyxel 官方 FAQ 對「H 系列配舊款 USG FLEX／ATP」的設定方式是 Hub-and-Spoke、H 系列當 Spoke。照官方驗證過的方式做，出問題時也比較好找原廠支援。

### 6-1 6F 站點（Hub）

**怎麼做**：切換到 6F 站點 → Site-wide → Configure → Firewall → Site-to-Site VPN

| 欄位 | 填法 |
| --- | --- |
| Outgoing interface | WAN（PPPoE 那個介面） |
| Local networks：LAN 1（192.168.0.0/24） | Use VPN：**是** |
| Local networks：LAN 2（192.168.200.0/24） | Use VPN：**否** |
| Nebula VPN | 啟用 |
| 拓撲 | **Hub-and-Spoke**，本站點為 **Hub** |

### 6-2 10F 站點（Spoke）

切換到 10F 站點，同一個頁面：

| 欄位 | 填法 |
| --- | --- |
| Outgoing interface | WAN（P1） |
| Local networks：LAN 1（192.168.10.0/24） | Use VPN：**是** |
| Nebula VPN | 啟用 |
| 拓撲 | **Hub-and-Spoke**，本站點為 **Spoke**，Hub 選 6F |

### 6-3 確認拓撲

**怎麼做**：Organization-wide → Organization-wide manage → VPN orchestrator（名稱依版本可能不同）。

**應該看到什麼**：6F 顯示為 Hub、10F 顯示為 Spoke，中間有一條線連起來；幾分鐘後兩邊的 VPN 狀態變成已連線（綠色）。

> **為什麼不用填對方 IP 和預先共用金鑰？** Nebula 知道同組織裡每台防火牆目前的 WAN IP 和勾選的網段，會自動把這些資訊推給對方。10F 若是浮動 IP，IP 變了 Nebula 也會透過 DDNS 重新通知 6F。

## 7. 備案：手動 IPsec（只在 Nebula VPN 建不起來時用）

社群有回報過 H 系列和舊款 USG FLEX 之間 Nebula VPN 建不起來、改用手動 IPsec 就通的案例。若升級韌體後仍不通，改在 Site-to-Site VPN 頁面的「Non-Nebula VPN peers」（名稱依版本可能不同）各自新增對方：

| 欄位 | 6F 這邊填 | 10F 這邊填 |
| --- | --- | --- |
| 對方公網 IP | 10F 的公網 IP（10F 若是浮動 IP，需由 10F 主動連 6F，依介面選項設定） | `<6F 固定 IP>` |
| 對方網段（Remote subnet） | 192.168.10.0/24 | 192.168.0.0/24 |
| 預先共用金鑰 | 兩邊填同一組長字串，**不要寫進文件** | 同左 |
| IKE 版本、加密演算法 | 兩邊必須完全相同，例如 IKEv2、AES256、SHA256 | 同左 |

> 手動 IPsec 最好兩邊都有固定 IP，這也是 3-1 建議 10F 申請固定 IP 的原因。

## 8. 步驟四：設定 10F 的 NWA50BE 與 SSID

**做什麼**：讓 10F 的無線設備也在 192.168.10.x，自然就能走 VPN 連到 6F。

**怎麼做**：

1. NWA50BE 插在 50HP 的 PoE 埠（P2～P5 之中有 PoE 的那一埠），AP 會從 LAN 1 拿到 192.168.10.x 的管理 IP
2. 切到 10F 站點 → Site-wide → Configure → Access points → SSID settings，新增 SSID：

| 欄位 | 填法 |
| --- | --- |
| SSID 名稱 | `<10F SSID>` |
| 安全性 | WPA2/WPA3 Personal（混合模式，舊裝置用 WPA2、新裝置用 WPA3） |
| VLAN | 不設（Untagged），直接走 LAN 1 |
| 頻段 | 2.4 GHz＋5 GHz（NWA50BE 是雙頻，沒有 6 GHz） |

**應該看到什麼**：手機連上 `<10F SSID>`，拿到 192.168.10.x 的 IP，可以上網。

> 本案 AP 和有線電腦在同一個網段，最簡單。若之後要做訪客 Wi-Fi，建議另開一個 VLAN 網段並**不要**加入 VPN，做法可參考[圖書館 Nebula 網路改造](../zyxel-nebula-library-vlan-dual-wan-plan/)。

## 9. 步驟五：驗收

**做什麼**：從兩邊互相連線，證明通道真的通，而不是只有 Nebula 顯示綠燈。

### 9-1 看 Nebula 狀態

Site-wide → Monitor → Firewall → VPN connections（名稱依版本可能不同），兩個站點都要看：

**應該看到什麼**：對方站點狀態為已連線，對方網段顯示 192.168.0.0/24（在 10F 看）或 192.168.10.0/24（在 6F 看）。6F 這邊**不應該**把 192.168.200.0/24 列為本地 VPN 網段。

也可以登入 50HP 的本機網頁介面，在 VPN Status → IPsec VPN → Site to Site VPN 確認 Nebula VPN 已連線（Zyxel 官方 FAQ 的路徑）。

### 9-2 從 10F 電腦測試

```text
ping 192.168.0.1
tracert 192.168.0.1
```

| 片段 | 意思 |
| --- | --- |
| `ping 192.168.0.1` | 對 6F 的閘道送測試封包，有回應代表封包能過去也能回來 |
| `tracert 192.168.0.1` | Windows 的路徑追蹤，看封包經過哪些設備 |

**應該看到什麼**：

- `ping` 有回應，時間通常在幾毫秒到幾十毫秒（依兩邊線路而定）
- `tracert` 第一跳是 192.168.10.1，第二跳就到 192.168.0.1：中間沒有出現 ISP 的路由器，代表封包走的是 VPN 通道，不是網際網路

### 9-3 測真正要用的服務

| 測試 | 怎麼做 | 應該看到什麼 |
| --- | --- | --- |
| 檔案分享 | 10F 電腦開檔案總管，輸入 `\\192.168.0.<6F 檔案主機>` | 跳出登入視窗或直接看到共用資料夾 |
| 印表機 | 10F 電腦新增 6F 的網路印表機（用 IP） | 可以印出測試頁 |
| 反方向 | 從 6F 電腦 ping 10F 的電腦或 192.168.10.1 | 有回應 |
| LAN 2 隔離 | 從 10F ping 192.168.200.1 | **沒有回應**才是對的 |

### 9-4 驗收紀錄範本

| 測試項目 | 結果 | 日期 |
| --- | --- | --- |
| Nebula VPN 狀態已連線（6F Hub、10F Spoke） | ⏳ | |
| 10F → 192.168.0.1 ping 通 | ⏳ | |
| 6F → 192.168.10.1 ping 通 | ⏳ | |
| 10F 開啟 6F 檔案分享 | ⏳ | |
| 10F → 6F LAN 2（192.168.200.1）不通 | ⏳ | |
| 10F 無線設備可上網、可連 6F | ⏳ | |
| 10F WAN 換 IP（重撥 PPPoE）後 VPN 自動恢復（浮動 IP 才需測） | ⏳ | |

## 10. 常見問題

| 現象 | 怎麼辦 |
| --- | --- |
| Nebula 一直顯示 VPN 未連線 | 1. 兩個站點是不是在**同一個組織**；2. 兩邊 Nebula VPN 都有啟用，拓撲是 Hub-and-Spoke、6F 是 Hub、10F 是 Spoke；3. 10F 的 50HP 拿到的 WAN IP 是不是私有 IP（192.168.x、10.x 開頭），是的話請 ISP 改橋接、讓 50HP 自己撥 PPPoE |
| 設定都對，Nebula VPN 還是建不起來，log 一直出現 `try to nail up` | 社群回報過 H 系列 VPN 的 DDNS 不更新、導致 Nebula VPN 建不起來的韌體 bug（Zyxel 承認並私下提供修正）。先把兩台防火牆升到最新韌體；仍不行就聯絡 Zyxel 客服，或先改用第 7 節的手動 IPsec |
| 通道顯示已連線，但 ping 對方閘道不通 | 社群回報過 H 系列 WAN 在 192.168.1.0/24（接在家用型路由器後面）時，通道建立卻不通的案例。避免讓 50HP 接在其他路由器後面 |
| Nebula 顯示已連線，閘道通、對方電腦不通 | 多半是 **Windows 防火牆預設擋 ping**，不是 VPN 的問題；改用檔案分享或印表機測試。也檢查該網段的 Use VPN 是否為「是」、防火牆安全政策是否有擋 VPN 進來的流量 |
| ping 得通，但大檔案傳一半卡住、某些網頁打不開 | PPPoE 加 IPsec 讓封包可用空間變小（推測 MTU／MSS 問題）。在防火牆的 VPN 或介面設定裡調整 TCP MSS（例如 1350），再測一次 |
| 10F ping 得到 6F LAN 2 | 6F 的 LAN 2 Use VPN 應為「否」，回 6-1 檢查 |
| 以後員工在家用 Remote Access VPN 連回 6F 不通 | 家用路由器常用 192.168.0.0/24 或 192.168.1.0/24，和 6F LAN 1 **重疊**。這是本案既有網段的潛在風險，若之後要開放遠端連線，需評估是否調整網段 |
| NWA50BE 一直重開或 Wi-Fi 不穩 | 確認插在有 PoE 標示的埠，且 50HP 的 PoE 供電足夠（NWA50BE 典型約 16 W，需 PoE+）。社群有 PoE 預算不足造成開機循環的案例；也可改用 12 V 變壓器供電 |
| 手機看不到 6 GHz | NWA50BE 是雙頻機種，本來就沒有 6 GHz |
| 10F 的 WAN 是浮動 IP，偶爾斷線一下 | IP 更換時 Nebula 要重新通知對方，通道會中斷片刻（推測數秒到數分鐘）。需要穩定就申請固定 IP |

## 11. 待辦

- [ ] 決定 10F 的 WAN 型態（建議 PPPoE 固定 IP），確認 50HP 能直接拿到公網 IP
- [ ] 確認 50HP 哪一埠有 PoE、PoE 供電上限
- [ ] 確認 USG FLEX 50HP 的授權是否影響 Nebula VPN
- [ ] 在同一組織新增 10F 站點、註冊 50HP 與 NWA50BE
- [ ] 兩台防火牆升到最新韌體
- [ ] 設定 10F WAN、LAN 1、DHCP、SSID，確認可上網
- [ ] 兩邊啟用 Nebula VPN，Hub-and-Spoke（6F Hub、10F Spoke）
- [ ] 依第 9 節完成驗收並填寫紀錄
- [ ] 驗收後評估用安全政策收斂 VPN 只放行需要的服務

## 12. 延伸閱讀

- [圖書館 Nebula 網路改造：VLAN 隔離讀者、CIP 過濾、兩條 FTTB 分流](../zyxel-nebula-library-vlan-dual-wan-plan/)：同樣是 Nebula 環境，介紹 VLAN、Port、Zone、安全政策
- [圖書館 Nebula 網路改造（附錄）：設定清單與實作紀錄](../zyxel-nebula-library-vlan-implementation-record/)：設定清單與驗收紀錄的寫法可參考
- [有用中華電信資安艦隊：DNS 為什麼不能設 8.8.8.8？](../cht-security-fleet-dns-filtering/)：若線路有加購資安艦隊，DNS 不能照本文填
- Zyxel 社群官方 FAQ：[How to Set Up Nebula Hub-and-Spoke VPN and the USG FLEX H series model as the Spoke site?](https://community.zyxel.com/en/discussion/28770/how-to-set-up-nebula-hub-and-spoke-vpn-and-the-usg-flex-h-series-model-as-the-spoke-site)
- Zyxel 社群討論：[Nebula Site-to-Site SD-VPN between USG Flex and USG Flex H doesn't work](https://community.zyxel.com/en/discussion/comment/85199/)（DDNS 韌體 bug）
- Zyxel 社群討論：[IPSec VPN among USG Flex 50 H and USG Flex 100](https://community.zyxel.com/en/discussion/comment/86255/)（WAN 在 192.168.1.0/24 時不通）
- Zyxel 社群討論：[NWA50BE no wifi when on POE+](https://community.zyxel.com/en/discussion/comment/83558/)（PoE 供電不足）
- Nebula 線上說明：在 Nebula 介面右上角的說明（?）圖示可開啟對應頁面的官方文件
