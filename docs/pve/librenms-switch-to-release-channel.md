---
layout: default
title: "LibreNMS 從 dev 版改回穩定版（release 通道）"
date: 2026-11-06
categories: [PVE, LibreNMS, Monitoring]
permalink: /docs/pve/librenms-switch-to-release-channel/
last_modified_at: 2026-11-06
---

# LibreNMS 從 dev 版改回穩定版（release 通道）

> **一句話**：LibreNMS 預設每天追 master 最新程式碼，所以版本號帶 `-dev`；想改成只追正式版，要把「更新通道」切到 release。但我們的 dev 版（26.11.0-dev）比最新正式版（26.10.2）還新，直接降版有資料庫不相容的風險，所以先切通道、暫停自動更新，等 26.11.0 發佈後再更新。

| 項目 | 內容 |
| --- | --- |
| 適合誰看 | 發現 LibreNMS 版本號帶 `-dev`、想改用穩定版的人 |
| 環境 | LibreNMS 跑在 PVE 的 LXC（CT 102，Debian）；安裝路徑 `/opt/librenms`；版本 26.11.0-dev（資料庫 migration 到 `2026_09_22_000001_add_expiration_index_to_cache_table`） |
| 日期 | 2026-11-06 |
| 結論 | ✅ 確認目前通道是 master（daily） ✅ 最新正式版是 26.10.2，比現在的 dev 舊，不降版 ✅ 已建 LXC snapshot、切到 release 通道並暫停自動更新 ⏳ 等 26.11.0 發佈後解除暫停、更新並驗收（第 7 節） |

## 1. 先認識幾個名詞

| 名詞 | 白話解釋 |
| --- | --- |
| **更新通道（update channel）** | LibreNMS 要追哪一條版本線：`master`（daily，每天追最新程式碼）或 `release`（monthly，只追正式版 tag） |
| **master／dev 版** | 開發中的最新程式碼，功能最新但可能有尚未發現的問題；版本號帶 `-dev` |
| **release／穩定版** | 每月打一次 tag（例如 `26.10.2`）的正式版 |
| **tag** | Git 裡的版本標記，像書籤，指向某一次提交 |
| **`daily.sh`** | LibreNMS 的更新腳本，系統每天用 cron 自動執行；它依通道決定要更新到哪裡 |
| **migration** | 升級時對資料庫結構做的修改。dev 版的 migration 可能比正式版還新，降版時舊程式看不懂新結構 |
| **snapshot** | Proxmox 對 LXC／VM 拍的還原點，出問題可以一鍵回到拍照當下 |
| **`lnms`** | LibreNMS 的命令列工具，**不能用 root 執行**，要用 `librenms` 使用者 |

## 2. 全貌

```text
master（daily）：每天追最新程式碼 ──→ 版本號 26.11.0-dev   ← 我們原本在這
        │
        │  切通道 + 暫停自動更新（本文做到這裡）
        ▼
release（monthly）：只追正式版 tag
        │
        │  等 26.11.0 發佈 → 解除暫停 → daily.sh → validate.php
        ▼
穩定版 26.11.0（版本號沒有 -dev）
```

## 3. 為什麼不直接降到 26.10.2？

| 比較 | 版本 |
| --- | --- |
| 最新正式版 | `26.10.2` |
| 我們現在 | `26.11.0-dev`（比 26.10.2 新） |

我們的資料庫已經套用過 dev 版才有的 migration。降回 26.10.2 時，舊程式可能看不懂新的資料庫結構（**推測**，未實測降版）。

另外，**不確定** `daily.sh` 在「目前版本比最新 tag 新」時會維持不動，還是會自動 checkout 回舊 tag。為了避免半夜被 cron 自動降版，切通道的同時要先暫停自動更新。

## 4. 動手前：建立還原點

在 PVE 節點（本例 node12，CT 102 所在的節點）上執行：

```bash
pct snapshot 102 before-switch
```

**應該看到什麼**：出現 `freeze guest filesystem` → `Creating snap: 100% complete...done.` → `thaw guest filesystem`。`freeze` 和 `thaw` 成對出現，代表檔案系統有正常凍結再解凍。

要還原時（容器要先停止）：

```bash
pct stop 102
pct rollback 102 before-switch
pct start 102
```

## 5. 動手做

### 5-1 進容器並切換成 librenms 使用者

```bash
pct enter 102
su - librenms
cd /opt/librenms
```

| 片段 | 意思 |
| --- | --- |
| `pct enter 102` | 從 PVE 節點進入 CT 102 的命令列（此時是 root） |
| `su - librenms` | 切換成 `librenms` 使用者；提示字元會變成 `librenms@…` |
| `cd /opt/librenms` | 進入 LibreNMS 安裝目錄 |

> 這個容器沒有安裝 `sudo`，所以用 `su`。若 `su` 回報該使用者沒有 shell，改用 `su -s /bin/bash librenms`。

### 5-2 看目前通道與最新正式版

```bash
lnms config:get update_channel
git fetch --tags
git tag --list '2[0-9].*' --sort=-v:refname | head -5
```

| 片段 | 意思 |
| --- | --- |
| `lnms config:get update_channel` | 查目前的更新通道 |
| `git fetch --tags` | 從 GitHub 抓最新的 tag 清單 |
| `--list '2[0-9].*'` | 只列出 `26.x.x` 這種新式版本號，濾掉 2016 年的舊 tag |
| `--sort=-v:refname` | 由新到舊排序 |

**實測看到的結果**：

```text
master
26.10.2
26.10.1
26.10.0
26.9.1.1
26.9.1
```

第一行 `master` 就是 daily 通道；最新正式版是 `26.10.2`。

### 5-3 切到 release 通道並暫停自動更新

```bash
lnms config:set update_channel release
lnms config:set update false
```

| 片段 | 意思 |
| --- | --- |
| `update_channel release` | 之後只追正式版 tag，不追 master |
| `update false` | 暫時停用 `daily.sh` 的自動更新，避免被自動降版 |

也可以在網頁操作通道：右上角齒輪 → 設定 → 系統 → 更新 → 更新通道。

### 5-4 確認設定生效

```bash
lnms config:get update_channel
lnms config:get update
```

**應該看到什麼**（實測）：

```text
release
false
```

到這裡版本仍是 `26.11.0-dev`，程式碼沒有任何變動；差別只是之後不會再追 master。

## 6. 常見問題

| 現象 | 怎麼辦 |
| --- | --- |
| `sudo: command not found` | 容器沒裝 `sudo`，改用 `su - librenms`（5-1） |
| `Error: lnms must not run as root` | 用 root 跑了 `lnms`。先 `su - librenms` 再執行 |
| `fatal: detected dubious ownership in repository at '/opt/librenms'` | 用 root 操作了 `librenms` 擁有的 git 目錄。**不要**照提示加 `safe.directory`（那只是讓 root 繞過檢查，之後 root 動到檔案可能弄亂擁有者）。換成 `librenms` 使用者即可 |
| `su: Authentication failure` | `librenms` 使用者的密碼不對。可以先在 root 下用 `passwd librenms` 重設，或直接用 root 執行 `su -s /bin/bash librenms`（root 切換使用者不需要密碼） |
| `git tag` 最上面是 `20160828`、`201609` 這種舊 tag | 版本排序把「20160828」當成比「26」大的數字。加上 `--list '2[0-9].*'` 濾掉（5-2） |
| 想知道是不是 dev 版 | 網頁首頁「版本」欄位帶 `-dev` 就是；或在 `/opt/librenms` 下執行 `./validate.php` |

## 7. 待辦

- [ ] 每隔幾天檢查 26.11.0 是否發佈：

  ```bash
  cd /opt/librenms
  git fetch --tags
  git tag --list '2[0-9].*' --sort=-v:refname | head -3
  ```

- [ ] 出現 `26.11.0` 後，先在 PVE 節點建新 snapshot：

  ```bash
  pct snapshot 102 before-2611
  ```

- [ ] 在 `librenms` 使用者下解除暫停、更新並驗收：

  ```bash
  cd /opt/librenms
  lnms config:set update true
  ./daily.sh
  ./validate.php
  ```

  `validate.php` 全部 OK、網頁版本號沒有 `-dev`，就算完成。若出現資料庫錯誤，用 snapshot 還原。
- [ ] 確認更新成功、觀察數日沒問題後，刪除不需要的 snapshot：`pct delsnapshot 102 before-switch`
- [ ] 完成後把本文的結論改成 ✅，並移除這份待辦（已結案的文章可省略待辦）

## 8. 風險與注意事項

- **26.11.0 發佈時，我們的 dev commit 可能比它還新**：切過去等於輕微降版。通常差異很小，`validate.php` 會告訴你資料庫有沒有問題（**推測**，未實測）。
- **暫停自動更新期間收不到安全性修補**：空窗期不要太長，也不要把 LibreNMS 直接暴露到網際網路。
- **不想等的替代做法**（未實測）：另開一個容器，全新安裝 26.10.2，再重新匯入設備；舊容器先保留。
- 首頁「是否同意傳送匿名報告給 LibreNMS」目前是 OFF，維持 OFF 即可。

## 9. 延伸閱讀

- [LibreNMS 官方文件：Updating](https://docs.librenms.org/General/Updating/)：更新通道與 `daily.sh` 的說明
- 本知識庫：[LibreNMS 溫度告警誤報：LXC 重複感測器與門檻整理](https://kbwangtw.github.io/IT-Knowledge-Base/docs/pve/librenms-temperature-sensor-cleanup/)：同一台 LibreNMS（CT 102）的另一篇維運紀錄
