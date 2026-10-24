---
layout: default
title: "Cisco Nexus 3548 忘記 admin 密碼：用 Ctrl+L 進 Loader 重設"
date: 2021-11-08
categories: [Network, Cisco, Nexus, Troubleshooting, Blogger 舊文]
permalink: /docs/blogger/network/cisco-nexus-3548-password-recovery/
last_modified_at: 2026-10-24
---

# Cisco Nexus 3548 忘記 admin 密碼：用 Ctrl+L 進 Loader 重設

> **一句話**：網路上常見的 `Ctrl+]` 在 NX-OS 9.2.2 試不出來；改在開機提示時按 **Ctrl+L** 進 Loader，以 recovery 模式開機後用 `admin-password` 設新密碼，再 `load-nxos` 正常開機登入。

| 項目 | 內容 |
| --- | --- |
| 適合誰看 | Nexus 交換器 admin 密碼遺失、需要用 Console 重設的人 |
| 環境 | Cisco Nexus 3548 系列（原文型號寫作 C3848P-10GX-V01，推測為 N3K-C3548P-10GX）；NX-OS 9.2.2 |
| 日期 | 2021-11-08（原文發表於 Blogger，2026-10-24 改寫為新手版） |
| 結論 | ✅ 以新密碼登入成功；設定檔保留 |

## 1. 先認識幾個名詞

| 名詞 | 白話解釋 |
| --- | --- |
| **NX-OS** | Nexus 系列交換器的作業系統（和一般 Catalyst 的 IOS 不同） |
| **Loader** | 開機程式的命令列（`loader>`），系統還沒載入，只能下少數指令 |
| **Recovery mode** | 只載入基本系統、不檢查密碼的開機模式，提示字元是 `switch(boot)#` |
| **Console** | 用 Console 線直接連設備的序列埠，忘記密碼時唯一的入口 |

## 2. 整體流程

```text
重開機 → 提示時按 Ctrl+L → loader>
  → cmdline recoverymode=1 → dir 找 .bin → boot nxos.9.2.2.bin
  → switch(boot)# → conf t → admin-password <新密碼> → exit
  → load-nxos → 用新密碼登入
```

## 3. 步驟一：進入 Loader 模式

**做什麼**：讓交換器停在開機程式。

**怎麼做**：電腦用 Console 線連上交換器（PuTTY 等終端機軟體），重開交換器電源。畫面出現「Press ctrl L to go to loader prompt in 2 secs」時，**2 秒內按 Ctrl+L**。

**應該看到什麼**：提示字元變成 `loader>`。

> 原作者實測網路上常見的 `Ctrl+]` 無效，推測是 NX-OS 版本較新的關係（未確認）。

## 4. 步驟二：設定 Recovery 模式並開機

```text
loader> cmdline recoverymode=1
loader> dir
loader> boot nxos.9.2.2.bin
```

| 片段 | 意思 |
| --- | --- |
| `cmdline recoverymode=1` | 下次開機進入 recovery 模式 |
| `dir` | 列出開機磁碟內容，找出副檔名為 `.bin` 的 NX-OS 映像檔名 |
| `boot nxos.9.2.2.bin` | 用這個映像檔開機；檔名換成你 `dir` 看到的 |

![Loader 模式下輸入 cmdline recoverymode=1 與 dir（原作者截圖）]({{ '/docs/blogger/network/images/nexus-3548-loader-recoverymode.png' | relative_url }})

**應該看到什麼**：系統載入一陣子後，停在 `switch(boot)#`。

## 5. 步驟三：設定新的 admin 密碼

```text
switch(boot)# configure terminal
switch(boot)(config)# admin-password <新密碼>
switch(boot)(config)# exit
```

| 片段 | 意思 |
| --- | --- |
| `admin-password <新密碼>` | 把 admin 帳號的密碼改掉；NX-OS 預設會檢查密碼強度，太簡單會被拒絕 |

**應該看到什麼**：出現一行 WARNING，說明之後 Console 登入會改用本機驗證，屬正常訊息。

## 6. 步驟四：正常開機並登入

```text
switch(boot)# load-nxos
```

**應該看到什麼**：系統繼續完整開機，出現登入提示；用 `admin` 和剛剛設的新密碼登入成功。

## 7. 常見問題

| 現象 | 怎麼辦 |
| --- | --- |
| 按 `Ctrl+]` 沒反應 | 本版本請改按 **Ctrl+L**，而且要在提示出現的 2 秒內 |
| `boot` 說找不到檔案 | 檔名要和 `dir` 列出的完全一致 |
| 新密碼被拒絕 | 密碼強度不足；加入大小寫、數字和符號 |
| 登入後設定都不見了 | 這個流程不會刪設定；若有異常，確認是否誤做了清除設定的指令 |

## 8. 待辦

- [ ] 重設後把新密碼存進公司的密碼管理系統

## 9. 延伸閱讀

- [Cisco Nexus 3000 系列文件總覽](https://www.cisco.com/c/en/us/support/switches/nexus-3000-series-switches/series.html)
- [Blogger 原文](https://kbwangtw.blogspot.com/2021/11/cisco-nexus-3548-x.html)
