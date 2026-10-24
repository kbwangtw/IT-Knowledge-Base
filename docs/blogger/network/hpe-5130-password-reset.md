---
layout: default
title: "HPE 5130 忘記密碼：從 Boot Menu 略過設定、重設密碼與取消 IRF"
date: 2018-07-20
categories: [Network, HPE, Troubleshooting, Blogger 舊文]
permalink: /docs/blogger/network/hpe-5130-password-reset/
last_modified_at: 2026-10-24
---

# HPE 5130 忘記密碼：從 Boot Menu 略過設定、重設密碼與取消 IRF

> **一句話**：開機時按 **Ctrl+D → Ctrl+B** 進 Extended Boot Menu，選 **7 略過目前設定**後重開，進系統刪掉或重設開機設定，再建立新的管理帳密與管理 IP；另附拆除 IRF 堆疊的步驟。

| 項目 | 內容 |
| --- | --- |
| 適合誰看 | 接手一台不知道密碼的 HPE 5130，或要把 IRF 堆疊拆回單台的人 |
| 環境 | HPE 5130（Comware）；Console 線 |
| 日期 | 2018-07-20（原文發表於 Blogger，2026-10-24 改寫為新手版） |
| 結論 | ✅ 不需密碼進入系統 ✅ 建立新管理帳號、管理 IP 與網頁管理 |

> ⚠️ 這個方法前提是設備的 **Password recovery capability 是 enabled**（Boot Menu 會顯示）。如果被關閉，只能選擇回復出廠（會清掉所有設定）。

## 1. 先認識幾個名詞

| 名詞 | 白話解釋 |
| --- | --- |
| **BASIC／Extended Boot Menu** | 開機時的救援選單，系統還沒載入 |
| **startup.cfg** | 開機設定檔（相當於 Cisco 的 startup-config） |
| **`system-view`** | 進入設定模式，提示字元從 `<HPE>` 變成 `[HPE]` |
| **local-user** | 交換器本機的登入帳號 |
| **Vlan-interface 1** | VLAN 1 的管理介面，設 IP 後可用網頁或 SSH 管理 |

## 2. 整體流程

```text
Console 連線 → 拔電重插
  → 出現提示時按 Ctrl+D（BASIC BOOT MENU）→ 再按 Ctrl+B（Extended Boot Menu）
  → 選 7（Skip current system configuration）→ Y → 選 0 重開
  → 不用密碼進系統 → 刪除或重設開機設定 → 重開
  → 建立新帳密、設管理 IP、開網頁管理 → save
```

## 3. 步驟一：進入 Extended Boot Menu

**怎麼做**：Console 連上後拔掉電源再插上，畫面出現：

```text
Press Ctrl+D to access BASIC BOOT MENU
Press Ctrl+T to start memory test
```

按 **Ctrl+D**，接著出現 `Press Ctrl-B to enter Extended Boot menu..` 時按 **Ctrl+B**。

**應該看到什麼**：先出現 `Password recovery capability is enabled.`，接著是選單：

```text
1. Download application file to flash
2. Select application file to boot
3. Display all files in flash
4. Delete file from flash
5. Restore to factory default configuration
6. Enter BootRom upgrade menu
7. Skip current system configuration
8. Reserved
9. Set switch startup mode
0. Reboot
```

## 4. 步驟二：略過目前設定開機

**怎麼做**：

| 輸入 | 意思 |
| --- | --- |
| `7` | Skip current system configuration：下次開機不讀現在的設定 |
| `Y` | 確認 |
| `0` | 回主選單後選 Reboot 重開機 |

**應該看到什麼**：開機後直接進入系統，不用輸入密碼。

## 5. 步驟三：處理舊的開機設定

二選一：

```text
<HPE> delete startup.cfg
```

或

```text
<HPE> reset saved-configuration main
```

| 指令 | 意思 |
| --- | --- |
| `delete startup.cfg` | 刪除開機設定檔，下次開機是空白設定 |
| `reset saved-configuration main` | 清除主要的開機設定 |

接著 `reboot` 重開，之後登入就不需要密碼了。

> ⚠️ 兩個指令都會讓舊設定（VLAN、IP 等）消失。想保留舊設定只改密碼的話，請先 `display saved-configuration` 把內容備份下來。

## 6. 步驟四：建立新的管理帳號

```text
<HPE> system-view
[HPE] local-user admin
[HPE-luser-manage-admin] password simple <新密碼>
[HPE-luser-manage-admin] service-type http ssh terminal
[HPE-luser-manage-admin] quit
[HPE] save
```

| 片段 | 意思 |
| --- | --- |
| `local-user admin` | 建立（或修改）名為 admin 的帳號；正式環境建議改用不好猜的帳號名稱 |
| `password simple <新密碼>` | 設定密碼（輸入明碼，系統會加密儲存） |
| `service-type http ssh terminal` | 允許這個帳號從網頁、SSH、Console 登入 |

## 7. 步驟五：設定管理 IP 並開啟網頁管理

```text
[HPE] interface Vlan-interface 1
[HPE-Vlan-interface1] ip address 192.0.2.1 255.255.255.0
[HPE-Vlan-interface1] quit
[HPE] ip http enable
[HPE] save
```

**應該看到什麼**：電腦設同網段 IP 後，瀏覽器開 `http://192.0.2.1` 可以看到登入頁，用新帳密登入。

> 原文範例 IP 已改為示範位址，請換成你的管理網段。

## 8. 附錄：拆除 IRF 堆疊

**做什麼**：兩台 IRF（Device A 為成員 1、Device B 為成員 2）拆回單台。

**Device A（Console 接 A）**：

```text
[IRF1] interface Ten-GigabitEthernet 1/1/2
[IRF1-Ten-GigabitEthernet1/1/2] shutdown
[IRF1-Ten-GigabitEthernet1/1/2] quit
[IRF1] undo irf-port 1/2
[IRF1] save
```

重開 Device A。

**Device B（Console 接 B）**：

```text
[IRF1] interface Ten-GigabitEthernet 2/1/1
[IRF1-Ten-GigabitEthernet2/1/1] shutdown
[IRF1-Ten-GigabitEthernet2/1/1] quit
[IRF1] undo irf-port 2/1
[IRF1] save
```

重開 Device B，最後拆掉模組上的 IRF 連接線。

| 片段 | 意思 |
| --- | --- |
| `shutdown` | 先關閉 IRF 用的實體 Port |
| `undo irf-port X/Y` | 刪除 IRF 邏輯 Port 設定 |

> 介面編號依你的實際接線（這個案例的 IRF 線接在擴充模組 `x/1/x` 上）。

## 9. 常見問題

| 現象 | 怎麼辦 |
| --- | --- |
| 按 Ctrl+D 沒反應 | 要在開機訊息出現的短短幾秒內按；終端機速率要正確 |
| 顯示 Password recovery capability is disabled | 無法略過設定，只能用選項 5 回復出廠 |
| 網頁打不開 | 檢查 `ip http enable`、管理 IP、帳號的 `service-type` 是否有 http |
| 拆 IRF 後兩台設定一樣 | 正常，拆開後各自重新設定 sysname 與 IP |

## 10. 延伸閱讀

- [HPE 5130 四台用 IRF 堆疊成一台](../hpe-5130-irf-stack/)
- [Blogger 原文](https://kbwangtw.blogspot.com/2018/07/hpe-5130.html)
