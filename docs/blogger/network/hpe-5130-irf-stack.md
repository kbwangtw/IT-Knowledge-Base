---
layout: default
title: "HPE 5130 四台用 IRF 堆疊成一台：10G Port 環狀交叉接線"
date: 2018-07-20
categories: [Network, HPE, IRF, Blogger 舊文]
permalink: /docs/blogger/network/hpe-5130-irf-stack/
last_modified_at: 2026-10-24
---

# HPE 5130 四台用 IRF 堆疊成一台：10G Port 環狀交叉接線

> **一句話**：每台用 10G Port 49、50 當 IRF Port，先改會員編號並重開，再設優先權、綁定 IRF 邏輯 Port、啟用；接線時**一台的 /1 接下一台的 /2**，四台接成一個環，最後在主機上就能看到全部成員。

| 項目 | 內容 |
| --- | --- |
| 適合誰看 | 要把多台 HPE Comware 交換器（5130 等）堆疊成一台管理的人 |
| 環境 | HPE 5130 × 4（主機名稱 2F-1～2F-4），每台 Ten-GigabitEthernet x/0/49、x/0/50 做 IRF |
| 日期 | 2018-07-20（原文發表於 Blogger，2026-10-24 改寫為新手版） |
| 結論 | ✅ 四台組成 IRF，2F-1 為 Master |

> **先做 IRF，再做 VLAN、IP 等其他設定**：IRF 成立後，成員的設定會被 Master 覆蓋。

## 1. 先認識幾個名詞

| 名詞 | 白話解釋 |
| --- | --- |
| **IRF** | HPE 的堆疊技術，多台交換器變成一台：一個管理 IP、一份設定 |
| **成員編號（member）** | 每台在 IRF 裡的編號，也是介面名稱的第一個數字（`2/0/49` 就是第 2 台） |
| **優先權（priority）** | 1～32，越大越優先當 Master |
| **Master** | 堆疊裡負責管理的那台 |
| **IRF 邏輯 Port（`irf-port X/1`、`X/2`）** | 每台有兩個 IRF 邏輯 Port，實體 Port 綁到它上面 |
| **Comware** | HPE 這系列交換器的作業系統；`<HPE>` 是使用者視圖，`[HPE]` 是設定視圖（`system-view`） |

## 2. 規劃與接線

| 主機 | 成員編號 | 優先權 | IRF 1 → 實體 Port | IRF 2 → 實體 Port |
| --- | --- | --- | --- | --- |
| 2F-1 | 1 | 32 | `irf-port 1/1` → 1/0/49 | `irf-port 1/2` → 1/0/50 |
| 2F-2 | 2 | 31 | `irf-port 2/1` → 2/0/49 | `irf-port 2/2` → 2/0/50 |
| 2F-3 | 3 | 30 | `irf-port 3/1` → 3/0/49 | `irf-port 3/2` → 3/0/50 |
| 2F-4 | 4 | 29 | `irf-port 4/1` → 4/0/49 | `irf-port 4/2` → 4/0/50 |

```text
        49 ─────────── 50
   2F-1                    2F-2
    50                       49
     │                        │
    49                       50
   2F-4                    2F-3
        50 ─────────── 49

一台的 49（IRF /1）接到下一台的 50（IRF /2），四台接成環
```

> **最重要的觀念**：IRF 接線必須「交叉」——`/1` 一定接對方的 `/2`，**不能 /1 接 /1**。

## 3. 步驟一：第一台（2F-1，預設就是成員 1）

```text
<HPE> system-view
[HPE] sysname 2F-1
[2F-1] irf member 1 priority 32
[2F-1] interface range Ten-GigabitEthernet 1/0/49 to Ten-GigabitEthernet 1/0/50
[2F-1-if-range] shutdown
[2F-1-if-range] quit
[2F-1] irf-port 1/1
[2F-1-irf-port1/1] port group interface Ten-GigabitEthernet 1/0/49
[2F-1-irf-port1/1] quit
[2F-1] irf-port 1/2
[2F-1-irf-port1/2] port group interface Ten-GigabitEthernet 1/0/50
[2F-1-irf-port1/2] quit
[2F-1] interface range Ten-GigabitEthernet 1/0/49 to Ten-GigabitEthernet 1/0/50
[2F-1-if-range] undo shutdown
[2F-1-if-range] quit
[2F-1] irf-port-configuration active
[2F-1] save
```

| 片段 | 意思 |
| --- | --- |
| `irf member 1 priority 32` | 第 1 台優先權設最高，確保它當 Master |
| `shutdown` → 綁定 → `undo shutdown` | 實體 Port 要先關閉才能綁進 IRF 邏輯 Port |
| `port group interface ...` | 把實體 Port 綁到 IRF 邏輯 Port |
| `irf-port-configuration active` | 讓 IRF Port 設定生效 |
| `save` | 存檔 |

## 4. 步驟二：其他三台——先改編號並重開

以第二台為例（第三、四台把 2 換成 3、4）：

```text
<HPE> system-view
[HPE] sysname 2F-2
[2F-2] irf member 1 renumber 2
[2F-2] save
[2F-2] quit
<2F-2> reboot
```

| 片段 | 意思 |
| --- | --- |
| `irf member 1 renumber 2` | 出廠都是成員 1，改成 2 |
| `reboot` | **一定要先重開**，新編號才會生效，介面名稱才會變成 `2/0/xx` |

## 5. 步驟三：其他三台——設定 IRF Port

重開後（第二台為例）：

```text
<2F-2> system-view
[2F-2] irf member 2 priority 31
[2F-2] interface range Ten-GigabitEthernet 2/0/49 to Ten-GigabitEthernet 2/0/50
[2F-2-if-range] shutdown
[2F-2-if-range] quit
[2F-2] irf-port 2/1
[2F-2-irf-port2/1] port group interface Ten-GigabitEthernet 2/0/49
[2F-2-irf-port2/1] quit
[2F-2] irf-port 2/2
[2F-2-irf-port2/2] port group interface Ten-GigabitEthernet 2/0/50
[2F-2-irf-port2/2] quit
[2F-2] interface range Ten-GigabitEthernet 2/0/49 to Ten-GigabitEthernet 2/0/50
[2F-2-if-range] undo shutdown
[2F-2-if-range] quit
[2F-2] irf-port-configuration active
[2F-2] save
```

第三台：`member 3`、`priority 30`、介面 `3/0/49～50`、`irf-port 3/1、3/2`。
第四台：`member 4`、`priority 29`、介面 `4/0/49～50`、`irf-port 4/1、4/2`。

> 原文第四台寫成 `irf member 3 priority 29`，應為 `irf member 4 priority 29`（筆誤）。

## 6. 步驟四：接線並確認

依第 2 節接好光纖後，在 2F-1（Master）執行：

```text
display irf
display current-configuration
```

**應該看到什麼**：`display irf` 列出 4 個成員，2F-1 是 Master；設定檔裡出現全部 8 個 IRF Port：

```text
irf-port 1/1
 port group interface Ten-GigabitEthernet1/0/49
irf-port 1/2
 port group interface Ten-GigabitEthernet1/0/50
irf-port 2/1
 port group interface Ten-GigabitEthernet2/0/49
...（3/1、3/2、4/1、4/2 同樣格式）
```

## 7. 常見問題

| 現象 | 怎麼辦 |
| --- | --- |
| 改了編號，介面名稱還是 1/0/xx | 沒有重開機 |
| IRF 一直合併不起來 | 接線是否 /1 接 /2；兩台的成員編號不能重複 |
| 成員一直重開 | 正常：優先權較低的成員加入時會重開，並套用 Master 的設定 |
| 原本的 VLAN 設定不見了 | IRF 成立後以 Master 設定為準；請先做 IRF 再做其他設定 |

## 8. 延伸閱讀

- [HPE 5700 核心與 5130 堆疊之間的 LACP](../hpe-5700-5130-lacp/)
- [HPE 5130 忘記密碼、回復預設與取消 IRF](../hpe-5130-password-reset/)
- [Blogger 原文](https://kbwangtw.blogspot.com/2018/07/hpe-switch-5130-irf.html)
