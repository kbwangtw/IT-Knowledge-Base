---
layout: default
title: "Cisco 3850 改 Install 模式失敗開不了機：用隨身碟救回來"
date: 2022-02-16
categories: [Network, Cisco, Troubleshooting, Blogger 舊文]
permalink: /docs/blogger/network/cisco-3850-bundle-to-install-recovery/
last_modified_at: 2026-10-24
---

# Cisco 3850 改 Install 模式失敗開不了機：用隨身碟救回來

> **一句話**：Catalyst 3850 從 Bundle 模式轉 Install 模式時沒做完整，重開後停在 `switch:` 找不到開機檔；用 FAT32 隨身碟放韌體先開機，再在 Switch 上重新清檔、展開、指定 `packages.conf`，就順利以 Install 模式開機。

| 項目 | 內容 |
| --- | --- |
| 適合誰看 | 3850 開機停在 `switch:` 提示字元的人；想把 3850 從 Bundle 改成 Install 模式的人 |
| 環境 | Cisco Catalyst WS-C3850-24T；IOS XE 16.06.09（`cat3k_caa-universalk9.16.06.09.SPA.bin`，此版本下載不需 SA 合約帳號） |
| 日期 | 2022-02-16（原文發表於 Blogger，2026-10-24 改寫為新手版） |
| 結論 | ✅ 從隨身碟開機成功 ✅ 改成 Install 模式並正常開機 |

## 1. 先認識幾個名詞

| 名詞 | 白話解釋 |
| --- | --- |
| **IOS XE** | 3850 這類新款 Cisco 交換器的作業系統 |
| **Bundle 模式** | 直接用一個大 `.bin` 檔開機，開機時要先把整包解開，比較慢、比較吃記憶體 |
| **Install 模式** | 先把 `.bin` 展開成多個 `.pkg`，開機時讀 `packages.conf` 這份清單；Cisco 建議用這個模式 |
| **`packages.conf`** | Install 模式的開機清單，記錄要載入哪些 `.pkg` |
| **`switch:` 提示字元** | ROMMON（開機程式）畫面：系統沒載入，只能下少數救援指令 |
| **`flash:`／`usbflash0:`** | 交換器內建儲存空間／前面板 USB 隨身碟 |
| **Stack（堆疊）** | 多台交換器串成一台管理；`switch all` 表示對堆疊內每一台都執行 |

## 2. 發生了什麼事

```text
原本：Bundle 模式，16.06.09
   │  照官方文件改 Install 模式，但步驟沒做完整
   ▼
重開 → 找不到開機檔 → 停在 switch:
   │  本文的救援流程
   ▼
① USB 隨身碟開機 → ② 清掉舊套件 → ③ 複製 .bin 到 flash
→ ④ 展開成 .pkg → ⑤ 開機指向 packages.conf → ⑥ 重開確認 Install 模式
```

開不了機時，Console 會一直重複類似下面的訊息，重點是「找不到檔案」和最後要你設定 BOOT 變數：

```text
loading flash:packages.conf
Reading full image into memory....done
Copying 'cat3k_caa-base.SPA.03.07.05E.pkg' into the buffer
Failed to open file: no such file or directory
...
The system is unable to boot automatically. The
BOOT environment variable needs to be set to a
bootable image.
switch:
```

> 開不了機的原因很多，這只是其中一種：`packages.conf` 裡寫的 `.pkg` 不在 flash 上。

## 3. 步驟一：準備隨身碟

**做什麼**：把可開機的韌體放到隨身碟。

**怎麼做**：

1. 隨身碟格式化成 **FAT32**。
2. 從 Cisco 官網下載和原本相同版本的 `.bin`（本例 `cat3k_caa-universalk9.16.06.09.SPA.bin`），複製到隨身碟根目錄。
3. 把隨身碟插到交換器前面板的 USB 孔，電腦接上 Console 線。

## 4. 步驟二：從隨身碟開機

**做什麼**：在 `switch:` 畫面初始化儲存空間，指定從隨身碟開機。

**怎麼做**：

```text
switch: flash_init
switch: dir usbflash0:
switch: boot usbflash0:cat3k_caa-universalk9.16.06.09.SPA.bin
```

| 片段 | 意思 |
| --- | --- |
| `flash_init` | 初始化儲存裝置，之後才讀得到 flash 和隨身碟 |
| `dir usbflash0:` | 列出隨身碟內容，確認有看到 `.bin` |
| `boot usbflash0:<檔名>` | 這次從隨身碟上的檔案開機 |

**應該看到什麼**：`dir` 會列出那個 `.bin`，大小約 407 MB：

```text
Directory of usbflash0:/
4  -rw-  407542491  cat3k_caa-universalk9.16.06.09.SPA.bin
```

開機完成後，先確認版本和模式：

```text
Switch> enable
Switch# show version
```

最下面那張表的 `Mode` 欄位應該是 **`BUNDLE`**（因為是直接用 `.bin` 開機），版本是 16.6.9：

```text
Switch Ports Model          SW Version   SW Image                 Mode
------ ----- -----          ----------   ----------               ----
*    1 32    WS-C3850-24T   16.6.9       CAT3K_CAA-UNIVERSALK9    BUNDLE

Configuration register is 0x102
```

## 5. 步驟三：清掉 flash 上的舊套件

**做什麼**：把 flash 上殘留、對不起來的 `.pkg` 和舊的 `packages.conf` 刪掉，避免下次又讀錯。

**怎麼做**：

```text
Switch# request platform software package clean switch all file flash:
```

| 片段 | 意思 |
| --- | --- |
| `request platform software package clean` | 清除目前沒在使用的套件檔 |
| `switch all` | 堆疊裡每一台都做 |
| `file flash:` | 清理的位置是內建 flash |

**應該看到什麼**：先列出要刪除的檔案，問你 `[y/n]`，輸入 `y` 後逐一刪除，最後出現 `SUCCESS: Files deleted.`。本例刪掉的是：

```text
/flash/cat3k_caa-guestshell.16.06.09.SPA.pkg
/flash/cat3k_caa-rpbase.16.06.09.SPA.pkg
/flash/cat3k_caa-rpcore.16.06.09.SPA.pkg
/flash/cat3k_caa-srdriver.16.06.09.SPA.pkg
/flash/cat3k_caa-universalk9.16.06.09.SPA.conf
/flash/cat3k_caa-webui.16.06.09.SPA.pkg
/flash/packages.conf
```

> ⚠️ 這一步會刪檔，執行前確認你**現在是從隨身碟開機**（上一步的 `show version`），不是從 flash。

## 6. 步驟四：把韌體複製到 flash

**怎麼做**：

```text
Switch# copy usbflash0:cat3k_caa-universalk9.16.06.09.SPA.bin flash:
Destination filename [cat3k_caa-universalk9.16.06.09.SPA.bin]?   ← 直接按 Enter
Switch# dir flash:
```

**應該看到什麼**：複製完成會顯示 `407542491 bytes copied in 61.886 secs`（本例約 1 分鐘）；`dir flash:` 清單中出現這個 `.bin`。

## 7. 步驟五：展開成 Install 模式的套件

**做什麼**：把 `.bin` 拆成 `.pkg`，並自動產生新的 `packages.conf`。

**怎麼做**：

```text
Switch# request platform software package expand switch all file flash:cat3k_caa-universalk9.16.06.09.SPA.bin auto-copy
```

| 片段 | 意思 |
| --- | --- |
| `package expand` | 把 `.bin` 展開成 `.pkg` 和 `packages.conf` |
| `switch all` | 堆疊裡每一台都展開 |
| `auto-copy` | 自動把 `.bin` 複製到堆疊中其他台，不用一台一台拷 |

**應該看到什麼**：約 1 分鐘後出現 `SUCCESS: Finished expanding all-in-one software package.`。

## 8. 步驟六：開機改讀 packages.conf

**怎麼做**：

```text
Switch# configure terminal
Switch(config)# no boot system
Switch(config)# boot system flash:packages.conf
Switch(config)# end
Switch# write memory
Switch# show boot
```

| 片段 | 意思 |
| --- | --- |
| `no boot system` | 清掉原本的開機設定（原本可能指向舊檔） |
| `boot system flash:packages.conf` | 以後從 flash 上的 `packages.conf` 開機，也就是 Install 模式 |
| `write memory` | 存檔，沒存的話重開就沒了 |

**應該看到什麼**：`show boot` 的現在值和下次開機值都是 `flash:packages.conf`：

```text
Current Boot Variables:
BOOT variable = flash:packages.conf;
Boot Variables on next reload:
BOOT variable = flash:packages.conf;
```

> 想再確認一次：可以把 `flash:packages.conf` 複製到隨身碟，在電腦上用記事本打開，看裡面列的 `.pkg` 是不是 16.06.09 版。

## 9. 步驟七：拔掉隨身碟，重開確認

```text
Switch# reload
（開機完成後）
Switch# show version
```

**應該看到什麼**：版本仍是 16.6.9，`Mode` 欄位變成 **`INSTALL`**：

```text
*    1 32    WS-C3850-24T   16.6.9       CAT3K_CAA-UNIVERSALK9    INSTALL
```

## 10. 常見問題

| 現象 | 怎麼辦 |
| --- | --- |
| `dir usbflash0:` 看不到檔案 | 先執行 `flash_init`；確認隨身碟是 FAT32、檔案放在根目錄 |
| 重開後又停在 `switch:` | 用 `show boot` 確認是否指向 `flash:packages.conf`，並確認 `write memory` 有存 |
| `packages.conf` 裡寫的是別的版本 | 代表展開的不是目前這個 `.bin`；重做步驟三～五 |
| 照官方文件做也開不起來 | 原作者當時也遇到；先用本文「隨身碟開機 → 重新展開」的方式救回，再對照官方文件逐步檢查 |

## 11. 待辦

- [ ] 堆疊有多台時，確認每一台 `show version` 都是 `INSTALL`

## 12. 延伸閱讀

- [Cisco Catalyst 3850 IOS XE 16.6 Release Notes（含 Bundle／Install 模式說明）](https://www.cisco.com/c/en/us/td/docs/switches/lan/catalyst3850/software/release/16-6/release_notes/ol-16-6-3850.html)
- [Blogger 原文](https://kbwangtw.blogspot.com/2022/02/cisco-3850-recovery.html)
