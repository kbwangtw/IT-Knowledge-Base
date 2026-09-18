---
layout: default
title: "把 PVE／PBS 通知改成繁體中文"
date: 2026-09-01
categories: [PVE, PBS, Notification]
last_modified_at: 2026-09-18
---

# 把 PVE／PBS 通知改成繁體中文

這個專案用自訂通知模板，讓備份等通知改成繁體中文。它處理的是通知內容；收件人、通知條件與寄送管道仍由原本的通知設定管理。

> 紀錄日期：2026-09-01。PVE 9.2.11 已測過安裝、中文備份信、移除還原及重新安裝；PBS 4.2.5 的模板已準備，但當時尚未完成相同的安裝生命週期實測。

## 先看自己適用哪一種

| 產品 | 本紀錄的驗證程度 |
| --- | --- |
| PVE 9.2.11 | 安裝 → 中文 vzdump 郵件 → 移除並還原 → 清理 state → 再安裝，已確認 |
| PBS 4.2.5 | 模板已提供，完整安裝與移除流程仍待測 |
| 其他版本 | 需先核對模板相容性，不沿用「已驗證」結論 |

原始專案：[proxmox-zh-tw-notification](https://github.com/kbwangtw/proxmox-zh-tw-notification)。

## 模板放哪裡？

| 產品 | 自訂模板目錄 |
| --- | --- |
| PVE | /etc/pve/notification-templates/default/ |
| PBS | /etc/proxmox-backup/notification-templates/default/ |

本方案使用自訂模板位置，不直接修改 /usr/share 裡的套件檔案。本次流程不需要為了套用文字模板重啟服務；驗證時應觸發一封新通知。

## 安裝前，先保留原有設定

使用 root，確認原始專案與腳本內容。下列指令會下載 main 分支腳本並立即執行，內容可能隨專案更新；正式維護若需要可追溯版本，應先保存並審閱確定的版本。

PVE 叢集先確認 quorum 和 /etc/pve 可寫：

~~~bash
pvecm status
mount | grep /etc/pve
~~~

PVE 的模板目錄是叢集共享設定，正常有 quorum 時只需安裝一次，再於各節點核對。不必三台重複覆寫。

## 安裝方式

PVE：

~~~bash
curl -fsSL https://raw.githubusercontent.com/kbwangtw/proxmox-zh-tw-notification/main/install.sh | bash -s -- --pve
~~~

PBS（本紀錄仍待完整實測）：

~~~bash
curl -fsSL https://raw.githubusercontent.com/kbwangtw/proxmox-zh-tw-notification/main/install.sh | bash -s -- --pbs
~~~

腳本也提供 --auto 自動判斷與 --all 模式；未指定時使用自動模式。知道產品種類時，明確指定比較容易檢查操作範圍。

## 備份目錄和安裝紀錄有什麼不同？

| 位置 | 用途 |
| --- | --- |
| /var/backups/proxmox-zh-tw-notification/&lt;產品&gt;-&lt;UTC時間戳&gt;/ | 保留每次操作相關備份 |
| /var/lib/proxmox-zh-tw-notification/&lt;產品&gt;/original/ | 記住首次安裝前的原始狀態 |

重新安裝不應把「第一次安裝前的狀態」覆蓋成已翻譯版本，否則移除時就無法回復原貌。移除流程會處理受管理的模板並還原原始狀態；備份另行保留。

不要把 state 目錄當成暫存檔隨手清掉。若缺少安裝紀錄，先核對備份與實際檔案，再決定如何人工還原。

## 怎麼確認真的生效？

PVE 可先查看模板檔：

~~~bash
find /etc/pve/notification-templates/default -maxdepth 1 -type f -name '*.hbs' -print
~~~

PBS 對應查：

~~~bash
find /etc/proxmox-backup/notification-templates/default -maxdepth 1 -type f -name '*.hbs' -print
~~~

接著觸發模板涵蓋的實際通知，例如 PVE 備份完成信，檢查中文內容、變數與收件結果。通用「測試通知」不一定會用到 vzdump 模板，不能只靠它判斷備份信翻譯成功。

## 想改回原本內容

PVE：

~~~bash
curl -fsSL https://raw.githubusercontent.com/kbwangtw/proxmox-zh-tw-notification/main/uninstall.sh | bash -s -- --pve
~~~

PBS：

~~~bash
curl -fsSL https://raw.githubusercontent.com/kbwangtw/proxmox-zh-tw-notification/main/uninstall.sh | bash -s -- --pbs
~~~

移除後重新核對模板與實際通知。PBS 指令在這裡保留作為專案使用方式，不表示本紀錄已測過成功移除。

## 常見問題

| 現象 | 先查什麼 |
| --- | --- |
| /etc/pve 不能寫 | quorum、pve-cluster 與 pmxcfs 狀態 |
| chmod 或保留權限複製失敗 | /etc/pve 的權限由 pmxcfs 管理，不是一般磁碟目錄 |
| 安裝後還是英文 | 是否為新通知、模板種類是否涵蓋、檔案放在哪個產品目錄 |
| 自動判斷找不到產品 | 確認主機產品後指定 --pve 或 --pbs |
| 移除找不到 state | 先查首次安裝紀錄與備份，不把缺檔當成已還原 |

本專案在 PVE 寫入共享模板時使用一般內容複製；PBS 一般檔案系統的權限處理不同，不能把兩邊的檔案操作方式混用。
