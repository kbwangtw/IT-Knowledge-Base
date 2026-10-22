---
layout: default
title: "Nebula 兩層樓 Site-to-Site VPN 規劃：6F USG FLEX 100 × 10F USG FLEX 50HP"
permalink: /docs/network/zyxel-nebula-site-to-site-vpn-6f-10f-plan/
date: 2026-10-22
categories: [Network, VPN, Zyxel, Nebula]
last_modified_at: 2026-10-22
---

# Nebula 兩層樓 Site-to-Site VPN 規劃：6F USG FLEX 100 × 10F USG FLEX 50HP

> **一句話**：6 樓已經有一台 USG FLEX 100（PPPoE 固定 IP），10 樓要新增一台 USG FLEX 50HP 和一台 Wi-Fi 7 AP。兩台防火牆都在 Nebula 管理，只要放在**同一個組織、各自一個站點**，在兩邊打開 Nebula VPN、勾選要互通的網段，Nebula 就會自動幫兩邊建好 IPsec 通道，不用手動填金鑰和對方 IP。關鍵只有一個：**三個網段不能重疊**，本案 192.168.0.0/24、192.168.200.0/24、192.168.10.0/24 沒有重疊，可以直接做。

| 項目 | 內容 |
| --- | --- |
| 適合誰看 | 公司有兩個地點（兩層樓、總部與分點），想讓兩邊電腦互相連線；第一次在 Nebula 做 Site-to-Site VPN 的人 |
| 環境 | 6F：USG FLEX 100（既有）；10F：USG FLEX 50HP、Zyxel Wi-Fi 7 AP（BE5100 等級，實際型號待確認）；全部由 Nebula 管理 |
| 日期 | 2026-10-22 規劃 |
| 資料來源 | 現場既有設定與新增需求；Nebula 操作路徑依 Nebula 介面整理，版本不同時選單名稱可能略有差異 |
| 結論 | ✅ 網段規劃無重疊，可做 Site-to-Site VPN；⏳ 10F 設備註冊與設定；⏳ VPN 建立與驗收；⏳ 待確認事項（第 3 節）：10F WAN 型態、6F LAN 2 是否加入 VPN、6F 機型是否為 H 系列、AP 型號與 PoE |

## 1. 先認識幾個名詞

| 名詞 | 白話解釋 |
| --- | --- |
| **Nebula** | Zyxel 的雲端管理平台。設備接上網路後，設定都在網頁上改，設備自己去雲端拿設定 |
| **組織（Organization）／站點（Site）** | Nebula 的兩層分類：組織是「公司」，站點是「一個地點」。**一個站點只能放一台防火牆**，所以 6F、10F 要各開一個站點 |
| **Site-to-Site VPN** | 兩個地點的防火牆之間拉一條加密通道，讓兩邊內網像接在同一個網路一樣互通；電腦不用裝任何軟體 |
| **IPsec** | Site-to-Site VPN 最常用的加密協定。Nebula VPN 底層就是 IPsec |
| **Nebula VPN** | Nebula 的「自動 VPN」：同一個組織裡的防火牆打開這個功能，Nebula 自動交換金鑰、對方 IP 和網段，不用手動設定 |
| **VPN 區域（VPN area）** | Nebula VPN 的分組。**同一個區域**內的站點才會自動互連 |
| **拓撲（Topology）** | 通道怎麼連：Site-to-Site（每個站點兩兩互連，Full mesh）或 Hub-and-Spoke（全部先連到中心點）。只有兩個站點時兩者效果一樣 |
| **Local networks／Use VPN** | 防火牆上每個 LAN 網段旁邊的開關：Use VPN 打開，這個網段才會被放進 VPN、讓對方看得到 |
| **PPPoE** | 用帳號密碼「撥號」上網的方式。中華電信光世代常見，可以搭配固定 IP |
| **WAN／LAN** | 防火牆接網際網路的那一側叫 WAN；接內部電腦的那一側叫 LAN |
| **Port group（埠群組）** | 把幾個實體埠綁成同一個網段，例如 P3～P5 同屬 LAN 1 |
| **DHCP Pool／約期（Lease）** | 防火牆自動發 IP 的範圍；約期是發出去的 IP 可以用多久，到期前電腦會自動續約 |
| **網段重疊** | 兩邊用了同一個網段（例如都是 192.168.1.0/24），防火牆分不出封包該留在本地還是送進 VPN，VPN 會不通 |
| **PoE** | 用網路線同時供電。10F 的 AP 可以直接插在 50HP 的 PoE 埠上取電 |
| **MTU／MSS** | 一個封包最大能多大。PPPoE 和 IPsec 都會吃掉封包空間，太大的封包可能被丟掉 |

## 2. 全貌圖

```text
                          網際網路
             ┌───────────────┴───────────────┐
   PPPoE 固定 IP：<6F 固定 IP>        10F WAN：⏳ 型態待確認
             │                                 │
   ┌─────────┴─────────┐   IPsec 通道   ┌───────┴─────────┐
   │ 6F USG FLEX 100   │◀═════════════▶│ 10F USG FLEX 50HP │
   │ （站點：6F）        │  Nebula VPN    │ （站點：10F）      │
   └──┬─────────────┬──┘  自動建立       └───────┬─────────┘
      │             │                           │ P2～P5
  P3～P5          P6                       LAN 1：192.168.10.0/24
  LAN 1           LAN 2                         │
  192.168.0.0/24  192.168.200.0/24          Wi-Fi 7 AP（PoE）
  Use VPN：是      Use VPN：⏳ 待確認           無線用戶也在 192.168.10.x

        ▲ 兩個站點放在 Nebula 同一個組織、同一個 VPN 區域 ▲
```

### 2-1 網段總表

| 地點 | 網段 | 實體埠 | 閘道 | DHCP Pool | DNS | 約期 | 加入 VPN |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 6F LAN 1 | 192.168.0.0/24 | P3～P5 | 192.168.0.1 | 192.168.0.10～70（61 個） | 8.8.4.4、101.101.101.101 | 2 天 | ✅ 是 |
| 6F LAN 2 | 192.168.200.0/24 | P6 | 192.168.200.1 | 192.168.200.33～200（168 個） | 192.168.200.1 | 2 天 | ⏳ 待確認（建議先不加入） |
| 10F LAN 1 | 192.168.10.0/24 | P2～P5 | 192.168.10.1 | 192.168.10.10～50（41 個） | 8.8.4.4、101.101.101.101 | 2 天 | ✅ 是 |

| 檢查項目 | 結果 |
| --- | --- |
| 三個網段有沒有重疊 | ✅ 沒有。192.168.0.x、192.168.200.x、192.168.10.x 前三碼都不同 |
| 6F 的 WAN | PPPoE 撥接帶固定 IP（本文以 `<6F 固定 IP>` 代稱） |
| 10F 的 WAN | P1，型態 ⏳ 待確認（PPPoE 固定 IP／PPPoE 浮動 IP／DHCP） |

## 3. 開工前要先確認的事

這幾件事會影響設定方式，建議先問清楚再動手：

| 問題 | 為什麼重要 | 建議 |
| --- | --- | --- |
| **10F 的 WAN 是哪一種？** | Nebula VPN 支援浮動 IP（雲端會通知對方新 IP），但固定 IP 最穩定；若 10F 的 50HP 前面還有一台 ISP 數據機在做 NAT（防火牆拿到的是私有 IP），通道可能建不起來 | 優先申請 PPPoE 固定 IP；至少讓 50HP 直接撥 PPPoE、拿到公網 IP |
| **6F 的 LAN 2 要不要讓 10F 連？** | LAN 2 的 DNS 指向閘道本身、範圍又很大，看起來像訪客或另一個用途的網段；加入 VPN 就等於 10F 看得到它 | 不確定用途前，**先只把 LAN 1 加入 VPN**；之後需要再打開 Use VPN 即可 |
| **6F 是 USG FLEX 100 還是 USG FLEX 100H？** | USG FLEX 50HP 是 H 系列（uOS 韌體）。舊款 USG FLEX 100（ZLD 韌體）和 H 系列在 Nebula 上的選單不同，兩者之間能不能直接用 Nebula VPN 自動互連，**未確認** | 看機身標籤或 Nebula 裝置清單上的型號；若是舊款，先查 Zyxel 官方相容說明，不行就改用第 7 節的手動 IPsec |
| **AP 的實際型號？** | 「BE5100」是 Wi-Fi 7 速率等級（合計約 5.1 Gbps），不是型號；要確認它是 Nebula 可管理的商用 AP，以及耗電是否在 50HP PoE 埠的供電範圍內 | 抄下機身上的型號（例如 NWA／WBE 開頭），到 Nebula 註冊頁確認能加入 |
| **10F 預計多少台設備？** | 10F 的 Pool 只有 41 個 IP，**有線和無線共用**；手機、筆電、印表機加起來很快會用完 | 預估超過 30 台，建議把 Pool 放大到例如 192.168.10.10～200 |
| **兩邊要互通哪些服務？** | 預設全部打開最省事，但 10F 一台中毒電腦就能直接掃到 6F | 先全通驗收，之後再用安全政策收斂到需要的服務（檔案分享、印表機、ERP…） |

## 4. 步驟一：在 Nebula 建立 10F 站點並註冊設備

**做什麼**：10F 需要自己的站點，因為一個站點只能有一台防火牆。

**怎麼做**：

1. 確認 6F 所在的組織，在**同一個組織**底下新增站點，名稱例如 `10F`
   - 路徑參考：左上角站點下拉選單 →「Create site」，或 Organization-wide → Organization-wide manage → 新增站點
2. 在 10F 站點註冊兩台設備（USG FLEX 50HP、AP），需要機身上的 **MAC 位址** 和 **序號（S/N）**
   - 路徑參考：Site-wide → Devices（或 Organization-wide → License & inventory）→ Add
3. 確認授權：Nebula VPN 需要防火牆在 Nebula 管理模式下；USG FLEX 50HP 的授權方案若影響 Nebula VPN 功能，以 Zyxel 官方說明為準（**未確認**）

**應該看到什麼**：10F 站點的裝置清單出現兩台設備，狀態為離線（還沒接線），沒有錯誤訊息。

> **注意**：不要把 10F 的防火牆加到 6F 的站點，Nebula 會不讓你加；就算是不同組織，也沒辦法用 Nebula VPN 自動互連。

## 5. 步驟二：設定 10F 防火牆的 WAN、LAN 與 DHCP

**做什麼**：先把 10F 自己的上網和內網弄好，確認能上網，再做 VPN。

### 5-1 埠的分配

| 實體埠 | 角色 | 說明 |
| --- | --- | --- |
| P1 | WAN | 接 ISP 的光纖數據機 |
| P2～P5 | LAN 1（同一個 Port group） | 接電腦、交換器、AP；AP 建議插在有 PoE 標示的埠 |

> 50HP 哪幾個埠有 PoE，以機身標示為準（**未確認**是哪一埠）。

### 5-2 WAN 設定

**怎麼做**：Site-wide → Configure → Firewall（H 系列可能顯示為 Security gateway）→ Interface，編輯 WAN：

| 欄位 | 填法 |
| --- | --- |
| 連線類型 | 依第 3 節確認的結果：PPPoE（填 ISP 給的帳號、密碼；有固定 IP 就填固定 IP）或 DHCP |
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
| Pool 大小／結束 | 到 192.168.10.50（共 41 個；若第 3 節評估不夠就放大） |
| 第一 DNS | 8.8.4.4 |
| 第二 DNS | 101.101.101.101 |
| 約期（Lease time） | 2 天 |

| DNS | 是誰的 |
| --- | --- |
| 8.8.4.4 | Google Public DNS 的第二組位址 |
| 101.101.101.101 | TWNIC 的 Quad101 公共 DNS |

> 跟 6F LAN 1 用同一組 DNS，兩層樓的上網行為才一致。

**應該看到什麼**：設備接上電、接好 WAN 線後，Nebula 顯示 50HP 上線；10F 電腦插 P2～P5 任一埠，拿到 192.168.10.10～50 之間的 IP，閘道 192.168.10.1，可以開網頁。

## 6. 步驟三：兩邊打開 Nebula VPN

**做什麼**：在 6F、10F 兩個站點都打開 Nebula VPN，放進同一個 VPN 區域，並勾選要互通的網段。

### 6-1 6F 站點

**怎麼做**：切換到 6F 站點 → Site-wide → Configure → Firewall → Site-to-Site VPN

| 欄位 | 填法 |
| --- | --- |
| Outgoing interface | WAN（PPPoE 那個介面） |
| Local networks：LAN 1（192.168.0.0/24） | Use VPN：**是** |
| Local networks：LAN 2（192.168.200.0/24） | Use VPN：**否**（第 3 節確認前先不加入） |
| Nebula VPN | 啟用 |
| VPN area | 新建或選擇一個區域，例如 `HQ-VPN` |
| 拓撲 | Site-to-Site |

### 6-2 10F 站點

切換到 10F 站點，同一個頁面：

| 欄位 | 填法 |
| --- | --- |
| Outgoing interface | WAN（P1） |
| Local networks：LAN 1（192.168.10.0/24） | Use VPN：**是** |
| Nebula VPN | 啟用 |
| VPN area | **跟 6F 選同一個**：`HQ-VPN` |
| 拓撲 | Site-to-Site |

### 6-3 確認拓撲

**怎麼做**：Organization-wide → Organization-wide manage → VPN orchestrator（名稱依版本可能不同），看 `HQ-VPN` 區域。

**應該看到什麼**：區域內有 6F、10F 兩個站點，中間有一條線連起來；幾分鐘後兩邊的 VPN 狀態變成已連線（綠色）。

> **為什麼不用填對方 IP 和預先共用金鑰？** Nebula 知道同組織裡每台防火牆目前的 WAN IP 和勾選的網段，會自動把這些資訊推給對方。10F 若是浮動 IP，IP 變了 Nebula 也會重新通知 6F。

## 7. 備案：手動 IPsec（只在 Nebula VPN 無法互連時用）

如果第 3 節查到 6F 的機型和 50HP 之間不能用 Nebula VPN 自動互連，改在 Site-to-Site VPN 頁面的「Non-Nebula VPN peers」（名稱依版本可能不同）各自新增對方：

| 欄位 | 6F 這邊填 | 10F 這邊填 |
| --- | --- | --- |
| 對方公網 IP | 10F 的公網 IP（**需要固定 IP**） | `<6F 固定 IP>` |
| 對方網段（Remote subnet） | 192.168.10.0/24 | 192.168.0.0/24 |
| 預先共用金鑰 | 兩邊填同一組長字串，**不要寫進文件** | 同左 |
| IKE 版本、加密演算法 | 兩邊必須完全相同，例如 IKEv2、AES256、SHA256 | 同左 |

> 手動 IPsec 需要兩邊都有固定 IP（或至少一邊固定、另一邊主動撥入），這也是第 3 節建議 10F 申請固定 IP 的原因。

## 8. 步驟四：設定 10F 的 AP 與 SSID

**做什麼**：讓 10F 的無線用戶也在 192.168.10.x，自然就能走 VPN 連到 6F。

**怎麼做**：

1. AP 插在 50HP 的 PoE 埠（P2～P5 之中有 PoE 的那一埠），AP 會從 LAN 1 拿到 192.168.10.x 的管理 IP
2. 切到 10F 站點 → Site-wide → Configure → Access points → SSID settings，新增 SSID：

| 欄位 | 填法 |
| --- | --- |
| SSID 名稱 | `<10F SSID>` |
| 安全性 | WPA2/WPA3 Personal（Wi-Fi 7 的 6 GHz 頻段只能用 WPA3） |
| VLAN | 不設（Untagged），直接走 LAN 1 |
| 頻段 | 2.4 GHz、5 GHz（6 GHz 依 AP 是否支援與用戶裝置決定） |

**應該看到什麼**：手機連上 `<10F SSID>`，拿到 192.168.10.x 的 IP，可以上網。

> 本案 AP 和有線電腦在同一個網段，最簡單。若之後要做訪客 Wi-Fi，建議另開一個 VLAN 網段並**不要**加入 VPN，做法可參考[圖書館 Nebula 網路改造](../zyxel-nebula-library-vlan-dual-wan-plan/)。

## 9. 步驟五：驗收

**做什麼**：從兩邊互相連線，證明通道真的通，而不是只有 Nebula 顯示綠燈。

### 9-1 看 Nebula 狀態

Site-wide → Monitor → Firewall → VPN connections（名稱依版本可能不同）：

**應該看到什麼**：對方站點狀態為已連線，對方網段顯示 192.168.0.0/24（在 10F 看）或 192.168.10.0/24（在 6F 看）。

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
| LAN 2 隔離（若沒加入 VPN） | 從 10F ping 192.168.200.1 | **沒有回應**才是對的 |

### 9-4 驗收紀錄範本

| 測試項目 | 結果 | 日期 |
| --- | --- | --- |
| Nebula VPN 狀態已連線 | ⏳ | |
| 10F → 192.168.0.1 ping 通 | ⏳ | |
| 6F → 192.168.10.1 ping 通 | ⏳ | |
| 10F 開啟 6F 檔案分享 | ⏳ | |
| 10F → 6F LAN 2 不通（若未加入） | ⏳ | |
| 10F 無線用戶可上網、可連 6F | ⏳ | |

## 10. 常見問題

| 現象 | 怎麼辦 |
| --- | --- |
| Nebula 一直顯示 VPN 未連線 | 1. 兩個站點是不是在**同一個組織、同一個 VPN 區域**；2. 兩邊 Nebula VPN 都有啟用；3. 10F 的 50HP 拿到的 WAN IP 是不是私有 IP（192.168.x、10.x 開頭）——是的話前面還有一台 ISP 設備在做 NAT，請 ISP 改橋接、讓 50HP 自己撥 PPPoE |
| Nebula 顯示已連線，但 ping 對方電腦不通 | 1. 先 ping 對方**閘道**（192.168.0.1／192.168.10.1），閘道通、電腦不通，多半是 **Windows 防火牆預設擋 ping**，不是 VPN 的問題；2. 檢查該網段的 Use VPN 是否為「是」；3. 檢查防火牆安全政策是否有擋 VPN 進來的流量 |
| ping 得通，但大檔案傳一半卡住、某些網頁打不開 | PPPoE 加 IPsec 讓封包可用空間變小（推測 MTU／MSS 問題）。在防火牆的 VPN 或介面設定裡調整 TCP MSS（例如 1350），再測一次 |
| 10F 新設備拿不到 IP | DHCP Pool 只有 41 個，可能已用完。到 Nebula 看 DHCP 租約清單，必要時放大 Pool 或縮短約期 |
| 10F ping 得到 6F LAN 2，但不希望它通 | 6F 的 LAN 2 Use VPN 改成「否」；若一定要加入，用安全政策只放行需要的服務 |
| 以後員工在家用 Remote Access VPN 連回 6F 不通 | 家用路由器常用 192.168.0.0/24 或 192.168.1.0/24，和 6F LAN 1 **重疊**。這是本案既有網段的潛在風險，若之後要開放遠端連線，需評估是否調整網段 |
| AP 插上去沒有亮燈或一直重開 | 確認插在有 PoE 標示的埠；Wi-Fi 7 AP 耗電較高，檢查 50HP 的 PoE 供電上限是否足夠（以官方規格為準） |
| 10F 的 WAN 是浮動 IP，偶爾斷線一下 | IP 更換時 Nebula 要重新通知對方，通道會中斷片刻（推測數秒到數分鐘）。需要穩定就申請固定 IP |

## 11. 待辦

- [ ] 確認 10F 的 WAN 型態（PPPoE 固定 IP／浮動 IP／DHCP），並確認 50HP 能直接拿到公網 IP
- [ ] 確認 6F 機型是 USG FLEX 100 還是 100H，以及與 USG FLEX 50HP 的 Nebula VPN 相容性
- [ ] 確認 6F LAN 2 的用途，決定是否加入 VPN
- [ ] 確認 10F AP 實際型號與 PoE 需求
- [ ] 評估 10F 設備數量，決定 DHCP Pool 是否放大
- [ ] 在同一組織新增 10F 站點、註冊 50HP 與 AP
- [ ] 設定 10F WAN、LAN 1、DHCP、SSID，確認可上網
- [ ] 兩邊啟用 Nebula VPN、加入同一個 VPN 區域
- [ ] 依第 9 節完成驗收並填寫紀錄
- [ ] 驗收後評估用安全政策收斂 VPN 只放行需要的服務

## 12. 延伸閱讀

- [圖書館 Nebula 網路改造：VLAN 隔離讀者、CIP 過濾、兩條 FTTB 分流](../zyxel-nebula-library-vlan-dual-wan-plan/)：同樣是 Nebula 環境，介紹 VLAN、Port、Zone、安全政策
- [圖書館 Nebula 網路改造（附錄）：設定清單與實作紀錄](../zyxel-nebula-library-vlan-implementation-record/)：設定清單與驗收紀錄的寫法可參考
- [有用中華電信資安艦隊：DNS 為什麼不能設 8.8.8.8？](../cht-security-fleet-dns-filtering/)：若線路有加購資安艦隊，DNS 不能照本文填
- Zyxel 台灣社群（Zyxel Community）：搜尋「Nebula Site-to-Site VPN」「VPN orchestrator」可找到官方教學與機型相容說明
- Nebula 線上說明：在 Nebula 介面右上角的說明（?）圖示可開啟對應頁面的官方文件
