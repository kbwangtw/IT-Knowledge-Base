---
layout: default
title: "Cisco 3750X／3850 等交換器恢復原廠設定：知道密碼與忘記密碼兩種做法"
date: 2015-10-21
categories: [Network, Cisco, Troubleshooting, Blogger 舊文]
permalink: /docs/blogger/network/cisco-switch-factory-reset/
last_modified_at: 2026-10-24
---

# Cisco 3750X／3850 等交換器恢復原廠設定：知道密碼與忘記密碼兩種做法

> **一句話**：還能登入時用 `write erase` 清設定再 `reload`；忘記密碼時，按住 **Mode 鍵**開機進 `switch:`，`flash_init` 後刪掉 `config.text` 和 `vlan.dat`，再 `boot` 就是全新的交換器。

| 項目 | 內容 |
| --- | --- |
| 適合誰看 | 要把舊交換器清乾淨重新設定，或接手一台不知道密碼的交換器 |
| 環境 | Cisco Catalyst 3750X、3850；原文 `dir flash:` 的輸出來自 2960（`c2960-lanbasek9`），流程在這幾款相同 |
| 日期 | 2015-10-21（原文發表於 Blogger，2026-10-24 改寫為新手版） |
| 結論 | ✅ 兩種情境都能回到出廠狀態 |

> ⚠️ 這兩種做法都會**刪除所有設定和 VLAN**。開始前先 `show running-config` 存一份備份（如果還能登入）。

## 1. 先認識幾個名詞

| 名詞 | 白話解釋 |
| --- | --- |
| **NVRAM** | 存放開機設定（startup-config）的地方 |
| **`write erase`** | 清空 NVRAM 裡的開機設定 |
| **`config.text`** | flash 上的設定檔，就是開機設定的實體檔案 |
| **`vlan.dat`** | flash 上的 VLAN 資料庫；**不刪的話 VLAN 會留著** |
| **Mode 鍵** | 交換器前面板的小按鈕，開機時按住可進入救援畫面 |
| **`switch:`** | 開機程式的救援提示字元 |

## 2. 怎麼選

```text
還能登入 enable？
   ├─ 能 → 做法一：write erase + reload（第 3 節）
   └─ 不能（忘記密碼）→ 做法二：Mode 鍵 + 刪檔（第 4 節）
```

## 3. 做法一：還能登入時

```text
Switch> enable
Switch# write erase
Erasing the nvram filesystem will remove all configuration files! Continue? [confirm]   ← 按 y
[OK]
Erase of nvram: complete
Switch# reload
System configuration has been modified. Save? [yes/no]: no    ← 一定要回 no
Proceed with reload? [confirm]   ← 按 y
```

| 片段 | 意思 |
| --- | --- |
| `write erase`（可縮寫 `wr e`） | 清掉開機設定 |
| `Save? ... no` | **不要**把目前的設定存回去，否則等於白清 |

> `write erase` 不會刪 `vlan.dat`。要連 VLAN 一起清，重開前再執行 `delete flash:vlan.dat`。

## 4. 做法二：忘記密碼時

### 4-1 進入救援畫面

1. 拔掉電源線。
2. **按住 Mode 鍵**，同時插回電源。
3. 等到燈號出現綠燈橫向亮起、Console 畫面停在 password recovery 相關訊息與 `switch:` 時，放開 Mode 鍵。

### 4-2 初始化 flash 並查看檔案

```text
switch: flash_init
switch: dir flash:
```

**應該看到什麼**：`flash_init` 會跑一陣子檢查（原文約 11 秒）；`dir flash:` 列出 `config.text`、`vlan.dat`、`private-config.text` 與 IOS 資料夾等。

> 一定要先 `flash_init`，否則 `dir flash:` 讀不到。

### 4-3 刪除設定檔與 VLAN 資料庫

```text
switch: del flash:config.text
Are you sure you want to delete "flash:config.text" (y/n)?y
switch: del flash:vlan.dat
Are you sure you want to delete "flash:vlan.dat" (y/n)?y
```

### 4-4 開機

```text
switch: boot
```

**應該看到什麼**：交換器開機後出現初始設定精靈（`Would you like to enter the initial configuration dialog?`），表示已回到出廠狀態。

## 5. 常見問題

| 現象 | 怎麼辦 |
| --- | --- |
| 重開後設定還在 | 做法一 `Save?` 時回答了 yes；重做並回答 no |
| 設定清了，VLAN 還在 | 沒刪 `vlan.dat` |
| 按 Mode 鍵沒進 `switch:` | 要在插電**之前**就按住，並等燈號變化後才放 |
| `dir flash:` 出錯 | 先執行 `flash_init` |
| 3850 照做後開機異常 | 3850 用的是 IOS XE，可參考〈Cisco Catalyst 3850 恢復原廠設定（IOS XE）〉 |

## 6. 延伸閱讀

- [Cisco Catalyst 3850 恢復原廠設定（IOS XE 做法）](../cisco-catalyst-3850-factory-reset/)
- [Cisco 3850 改 Install 模式失敗：用隨身碟救回來](../cisco-3850-bundle-to-install-recovery/)
- [Blogger 原文](https://kbwangtw.blogspot.com/2015/10/cisco-3850.html)
