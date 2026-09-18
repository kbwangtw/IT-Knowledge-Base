---
layout: default
title: "ProxCenter 逐台更新 PVE：三個卡關點怎麼排除？"
date: 2026-08-26
categories: [PVE, ProxCenter, Ceph]
last_modified_at: 2026-09-18
---

# ProxCenter 逐台更新 PVE：三個卡關點怎麼排除？

這次更新被三件不同的事擋住：套件來源檢查讀到備份檔、SSH 連到錯的網段，以及自動流程要求的 sudo 權限與測試項目不同。分開處理後，node12 成功進入套件更新與健康檢查階段。

**本文的成功證據到 node12 為止，沒有完整三台更新、重開與驗收紀錄。**

> 實測日期：2026-08-26。這是當時版本的排查紀錄；設定中的 IP、帳號與 VMID 是案例值。

## 「逐台更新」是什麼意思？

一次只維護一台，讓其他主機繼續工作。這要求剩下的主機、儲存與網路能承受工作負載，不能只把三台排成順序就直接開始。

本次三台有 quorum，Ceph 為 HEALTH_OK、OSD 3 up／3 in，HA／LRM 正常。更新前先確認：

~~~bash
pvecm status
ceph -s
ha-manager status
pveversion -v
~~~

## 當時使用的更新設定

| 設定 | 本次選擇 |
| --- | --- |
| 順序 | node12 → node11 → node10 |
| 搬移非 HA VM | 開啟 |
| 關閉使用本機儲存的 VM | 關閉 |
| 必要時自動重開 | 開啟 |
| 維護期間設定 Ceph noout | 開啟 |
| 發生錯誤即中止 | 開啟 |
| 每台之間人工批准 | 開啟 |
| 最少健康節點 | 2 |
| 等待 Ceph HEALTH_OK | 開啟 |

這些是本案設定，不是所有三節點環境的標準答案。尤其「略過本機儲存 VM」不代表它在主機重開時仍會運作，必須另外安排停機。

## 卡關一：APT 正常，檢查器卻說來源有問題

APT 更新本身正常，但 ProxCenter 的檢查仍回報 Repository Issues。本案發現來源目錄裡有 .BAK 備份檔，檢查器也把它們算進去。

先只移出 node10 的兩個備份檔，錯誤從 6 個變成 4 個；處理其他節點後降為 0。這個前後對照，才是定位問題的依據。

~~~bash
apt-cache policy
grep -Rni 'enterprise.proxmox.com' /etc/apt/ 2>/dev/null
ls -la /etc/apt/sources.list.d/
~~~

處理時先確認哪些是備份檔，再移到來源目錄以外並保留原檔，不要把正常使用中的來源刪掉。套件來源應依自己的訂閱與版本設定，不能為了讓檢查變綠就任意切換。

## 卡關二：SSH 測試成功，更新工作卻連不到

單獨測試 SSH 成功；真正更新時卻連到 172.16.10.12:22 而 timeout。原來更新流程自動選了 Corosync 所在網段，和測試時的管理網不同。

本次把 SSH 目的地明確指定為：

~~~text
node10 → 192.168.10.10
node11 → 192.168.10.11
node12 → 192.168.10.12
~~~

**要比的是同一個目的 IP、帳號與驗證方式。** 一個按鈕測試成功，不能證明另一段流程使用的連線也相同。

可從節點日誌核對實際登入：

~~~bash
journalctl --since "10 minutes ago" | grep -Ei 'sshd|proxcenter'
~~~

## 卡關三：可以執行部分管理命令，仍被判定沒有免密碼 sudo

原本允許部分命令，apt、ceph、ha-manager 的個別測試可用，但流程的 sudo -n true 測試仍要求密碼。

~~~bash
visudo -c -f /etc/sudoers.d/proxcenter
sudo -u proxcenter sudo -n -l
sudo -u proxcenter sudo -n true
~~~

本案最後採用：

~~~text
proxcenter ALL=(ALL) NOPASSWD: ALL
~~~

之後測試回傳 0，id 顯示 root，流程得以往下走。這個設定讓帳號取得等同 root 的能力，**是本次採用的權限取捨，不是已驗證的最小權限解法**。若要縮小權限，需依該版本實際執行的完整命令另測。

查看 reboot 的 sudo 權限可以用清單模式；不要為了測試權限直接執行重開：

~~~bash
sudo -u proxcenter sudo -n -l /usr/sbin/reboot
~~~

## VM 被略過，是錯誤嗎？

當時 VM100、VM105 使用本機儲存，因此被略過；VM107 成功搬到 node11。這符合「不關閉本機儲存 VM」的設定，卻也表示它們需要另外安排維護。

第一次工作還曾設定 noout、嘗試維護模式、搬移 VM，然後才在套件更新的 SSH 階段失敗。失敗不代表前面完全沒改變，重試前要重新查：

~~~bash
pvecm status
ceph -s
ha-manager status
ceph osd dump | grep flags
~~~

noout 是維護旗標，不是永久設定。收尾時依實際維護狀態確認是否應解除；不能看到它就盲目清掉，也不能忘記檢查。

## 最後看到了什麼？

修正後，node12 日誌進入以下階段：

~~~text
Enabling maintenance mode
Waiting for HA migrations
Migrating non-HA VMs
Running apt update && apt full-upgrade
Verifying node health
~~~

這支持「原來的三個阻礙已排除，node12 更新流程能往下走」。要宣告整個叢集更新完成，仍需每台的版本、重開後狀態、VM／HA、Ceph 和維護旗標紀錄。

## 下次可直接沿用的檢查順序

1. 先確認 quorum、Ceph、HA 與工作負載容量。
2. 看套件來源的實際有效設定，區分備份檔。
3. 核對更新流程真正使用的 SSH IP。
4. 以同一帳號測試非互動 sudo。
5. 先安排本機儲存 VM，再批准維護。
6. 每台完成後驗證健康狀態；失敗就停下來查，別直接處理下一台。
