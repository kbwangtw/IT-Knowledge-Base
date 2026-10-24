---
layout: default
title: "Cisco Catalyst 3850 恢復原廠設定（IOS XE 做法）"
date: 2024-12-11
categories: [Network, Cisco, Troubleshooting, Blogger 舊文]
permalink: /docs/blogger/network/cisco-catalyst-3850-factory-reset/
last_modified_at: 2026-10-24
---

# Cisco Catalyst 3850 恢復原廠設定（IOS XE 做法）

> **一句話**：3850 按住 Mode 鍵開機進 `switch:`，設定 `SWITCH_IGNORE_STARTUP_CFG=1` 先略過舊設定開機，進系統後執行 `factory-reset config` 和 `factory-reset boot-vars`，再重開就是出廠狀態。

| 項目 | 內容 |
| --- | --- |
| 適合誰看 | 要把 3850（IOS XE）清回出廠、或接手不知道密碼的 3850 |
| 環境 | Cisco Catalyst 3850，IOS XE；Console 線＋終端機軟體（PuTTY、SecureCRT） |
| 日期 | 2024-12-11（原文發表於 Blogger，2026-10-24 改寫為新手版） |
| 結論 | ✅ 回到出廠設定，可重新做基本設定 |

> ⚠️ 會清除所有設定。3750X、2960 這類舊款（IOS）請看〈Cisco 3750X／3850 等交換器恢復原廠設定〉。

## 1. 先認識幾個名詞

| 名詞 | 白話解釋 |
| --- | --- |
| **IOS XE** | 3850 用的作業系統，比舊款 IOS 多了一些指令，例如 `factory-reset` |
| **Mode 鍵** | 前面板的按鈕，開機時按住可進入 `switch:` 救援畫面 |
| **`SWITCH_IGNORE_STARTUP_CFG=1`** | 開機程式的變數：這次開機**不讀**舊設定（等於繞過舊密碼） |
| **boot-vars** | 開機相關變數（例如從哪個檔案開機） |

## 2. 整體流程

```text
拔電 → 按住 Mode 鍵插電 → 燈號閃爍後放開 → switch:
  → flash_init → SWITCH_IGNORE_STARTUP_CFG=1 → boot
  → 進入系統（沒有舊設定）→ enable
  → factory-reset config → factory-reset boot-vars
  → 重開 → 出廠狀態，重新設定
```

## 3. 步驟一：進入 switch: 救援畫面

1. 電腦用 Console 線連上 3850，開啟終端機。
2. 拔掉交換器電源線。
3. **按住 Mode 鍵**再插上電源，一直按到前面板的 LED 開始閃爍才放開。

**應該看到什麼**：Console 停在 `switch:` 提示字元。

## 4. 步驟二：略過舊設定開機

```text
switch: flash_init
switch: SWITCH_IGNORE_STARTUP_CFG=1
switch: boot
```

| 片段 | 意思 |
| --- | --- |
| `flash_init` | 初始化 flash，才能讀寫上面的檔案 |
| `SWITCH_IGNORE_STARTUP_CFG=1` | 這次開機不載入舊設定 |
| `boot` | 繼續開機 |

## 5. 步驟三：清除設定與開機變數

開機後進入特權模式：

```text
Switch> enable
Switch# factory-reset config
Switch# factory-reset boot-vars
```

| 片段 | 意思 |
| --- | --- |
| `factory-reset config` | 清除設定檔 |
| `factory-reset boot-vars` | 清除開機變數，包含剛才設的 `SWITCH_IGNORE_STARTUP_CFG` |

> 原文寫「再輸入 boot 完成重設」；實務上這兩個指令執行後交換器會重新啟動，若停在 `switch:` 再輸入 `boot` 即可。

## 6. 步驟四：重新設定

**應該看到什麼**：開機後出現初始設定精靈，或是沒有任何設定的 `Switch>`。

接著做基本設定：主機名稱、管理 IP、enable 密碼、使用者帳號。

> 原文提到可用預設帳號密碼（常見為 `admin`）登入；但 IOS XE 出廠一般沒有預設帳密，會直接進設定精靈或 `Switch>`。**以實際畫面為準（未確認）**。

## 7. 常見問題

| 現象 | 怎麼辦 |
| --- | --- |
| 沒進到 `switch:` | 要在插電前按住 Mode 鍵，等 LED 閃爍後才放開 |
| `factory-reset` 指令不存在 | IOS XE 版本太舊；改用 `write erase` + `delete flash:vlan.dat` + `reload` |
| 重開後還是讀到舊設定 | `factory-reset boot-vars` 沒做；或在 `switch:` 用 `SWITCH_IGNORE_STARTUP_CFG=0` 改回 |

## 8. 延伸閱讀

- [Cisco 3750X／3850 等交換器恢復原廠設定：知道密碼與忘記密碼兩種做法](../cisco-switch-factory-reset/)
- [Cisco 3850 改 Install 模式失敗：用隨身碟救回來](../cisco-3850-bundle-to-install-recovery/)
- [Blogger 原文](https://kbwangtw.blogspot.com/2024/12/cisco-catalyst-3850.html)
