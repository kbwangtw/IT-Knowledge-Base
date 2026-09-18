---
layout: default
title: "PBS 更新後，怎麼確認備份還能用？"
date: 2026-09-11
categories: [PVE, PBS, ProxCenter, DR]
permalink: /docs/pve/ProxCenter-PBS-Update-and-DR-Validation-SOP/
last_modified_at: 2026-09-18
---

# PBS 更新後，怎麼確認備份還能用？

這篇記錄 ProxCenter 1.4.9 搭配 PBS 4.2.5 的一次維護。更新已完成，PBS 重開後可正常提供服務，PVE 也能讀到備份清單。另一段 CT110 還原成 CT210 的紀錄，則用來說明如何檢查備份裡的系統能不能開起來。

兩件事要分開看：**更新成功，不代表已重新測過所有備份；備份顯示 Verify OK，也不等於應用程式已成功還原。**

> 紀錄日期：2026-09-11；白話整理：2026-09-18。以下版本、位址與結果都是本案例資料。位址和 ID 是對照用，操作前請換成自己的環境。

<a id="environment"></a>
## 先認識本次環境

| 元件 | 本次用途 |
| --- | --- |
| ProxCenter 1.4.9／CT110 | 管理介面，原管理位址為 192.168.10.30 |
| PBS31／PBS 4.2.5 | 備份伺服器，管理網與資料網各有一張網卡 |
| Tokyo16 | PBS datastore；資料來自 CIFS 掛載 /mnt/tokyo16 |
| PVE node12 | 還原演練的目標節點 |
| CT210／VM_Pool | 新的測試容器與儲存位置 |
| 192.168.10.210:3000 | 測試容器的網頁入口 |

PBS31 管理位址是 192.168.10.31，資料位址是 172.16.10.31。CIFS 來源為 //172.16.10.16/PBS_BK_Folder。**資料夾存在不代表網路磁碟已掛上**，必須查實際掛載來源。

<a id="evidence"></a>
## 本次到底確認了哪些事？

| 項目 | 已有證據 | 還不能推論 |
| --- | --- | --- |
| PBS 更新 | 9 個套件更新、1 個新增、0 個移除 | 其他版本也會得到同樣結果 |
| 重開後服務 | kernel 已換、沒有 failed unit、PBS 服務正常 | 所有外部工作都已逐筆測完 |
| 備份清單 | PVE 可讀；UI 顯示 141 份快照，61 VM／80 CT | 更新後重新驗證了全部 141 份 |
| Verify | 畫面顯示 141／141 已驗證 | 每一份都已開機還原 |
| CT210 演練 | 四個 Docker 容器 healthy，網頁入口可用 | 所有正式業務功能都完成驗收 |

<a id="precheck"></a>
## 更新前：先確認「能停、能回來、找得到資料」

先等備份、還原、驗證等工作結束，保留管理主控台，備份 PBS 設定並保護其中的憑證。檢查 /boot 與根磁碟空間，也確認 CIFS 現在真的掛載成功。本次沒有順便移除舊 kernel 或升級 ZFS pool 格式。

在 **PBS31** 查：

~~~bash
proxmox-backup-manager versions
uname -r
systemctl --failed --no-pager
systemctl status proxmox-backup proxmox-backup-proxy --no-pager
ip -br addr
ip route
findmnt --mountpoint /mnt/tokyo16
df -h / /boot /mnt/tokyo16
dpkg --audit
apt-mark showhold
~~~

在 **PVE 節點** 查：

~~~bash
pvesm status --storage PBS31
pvesm list PBS31
~~~

清單可讀是「連得上、列得出」的證據；還原能力要靠後面的演練確認。

<a id="token"></a>
## 遇到 403：這是權限問題，不是套件壞掉

本次 ProxCenter 更新套件清單時出現：

~~~text
PBS 403 /nodes/localhost/apt/update: permission check failed
~~~

處理時重新建立 API token、設定使用者與 token 在 / 的 Admin ACL，並重新填入 ProxCenter 憑證，之後功能恢復。

由於同時改了多個地方，**無法只歸因於其中一個設定**。這是本案採用的高權限解法，不是已驗證的最小權限配置。若要縮小權限，應依實際 API 操作另行測試。

<a id="update"></a>
## 更新：先看預計會改什麼，再安裝

本案例使用 Debian Trixie、security、updates 與 pbs-no-subscription 來源，停用 enterprise 來源。這是當時的訂閱與環境選擇，不代表所有 PBS 都應照改。

先核對來源與模擬更新：

~~~bash
grep -R -n -E '^(deb |Types:|URIs:|Suites:|Components:|Enabled:|Signed-By:)' /etc/apt/sources.list /etc/apt/sources.list.d/
apt-cache policy
apt update
apt list --upgradable
apt -s dist-upgrade
~~~

確認清單沒有不預期的移除或相依性問題，才在 PBS31 執行：

~~~bash
apt dist-upgrade
~~~

本次結果：

| 元件 | 更新前 | 更新後 |
| --- | --- | --- |
| kernel | 7.0.14-12-pve | 7.0.14-16-pve |
| ZFS | 2.4.3-pve1 | 2.4.4-pve1 |
| firmware 套件 | 3.18-5 | 3.18-6 |

在本次 ProxCenter 1.4.9 流程中，刷新更新清單不等於安裝更新，實際安裝是在 PBS shell 完成。不要把這個版本的 UI 行為當成所有未來版本的限制。

<a id="postcheck"></a>
## 重開後：從主機一路查到 PVE

安裝結束先確認套件狀態、新 kernel 與 initrd 都存在；重開屬維護操作，需先確認工作已停止並有主控台可用。

~~~bash
dpkg --audit
ls -l /boot/vmlinuz-7.0.14-16-pve /boot/initrd.img-7.0.14-16-pve
~~~

重開後在 PBS31 重新核對：

~~~bash
uname -r
systemctl --failed --no-pager
systemctl status proxmox-backup proxmox-backup-proxy --no-pager
findmnt --mountpoint /mnt/tokyo16
df -h /mnt/tokyo16
ip -br addr
ip route
~~~

本次確認 kernel 為 7.0.14-16-pve、failed unit 為 0、雙網卡正常，CIFS 自動掛回；容量顯示約 2.7T，使用 703G，可用 2.0T。PVE 的 PBS31 active，清單可讀，ProxCenter 顯示沒有待更新套件。

PBS UI 的容量採另一種顯示方式：使用 702.16 GiB、可用 1.92 TiB、總量 2.61 TiB。不要只因顯示單位不同就判定容量遺失。

<a id="restore"></a>
## 還原演練：把 CT110 還原成另一台 CT210

這段是既有還原紀錄，不能當成「這次更新後又完整重做一次」的證據。

### 第一步：對齊 PBS 的連線地址

曾出現：

~~~text
No PVE storage on node node12 maps to PBS datastore Tokyo16
~~~

PVE 指向 PBS 資料網，ProxCenter 卻使用管理網地址。本次替 ProxCenter 增加 172.16.10.30/24 網卡、不新增預設閘道，並把 PBS endpoint 對齊到 172.16.10.31:8007 後恢復。

這證明調整後可運作；尚未由程式碼確認產品的比對演算法。遇到相同訊息時，仍要核對節點、datastore、storage 設定與連線，不能只看名稱相同。

### 第二步：先還原，暫時不要自動開機

| 選項 | 本次值 | 原因 |
| --- | --- | --- |
| 新 VMID | 210 | 不覆蓋正式 CT110 |
| 目標 | node12／VM_Pool | 建立獨立測試副本 |
| Unique MAC | ON | 避免複製相同網卡位址 |
| Start after restore | OFF | 先處理 IP 與自動工作 |
| Override name | OFF | 本版本開啟時出現 LXC schema 400 |

當時的錯誤是 name property is not defined in schema。關閉 Override name 後成功，但未取得完整 request payload，不能把它描述成已定位的原始碼缺陷。

### 第三步：所有網卡都查完，才啟動

~~~bash
pct status 210
pct config 210
~~~

測試副本改用 192.168.10.210。若有第二張靜態 IP 網卡，也要避免與正式機重複。修改時保留原有 bridge、VLAN、MTU 與其他必要欄位；不要用一條簡化指令蓋掉整份網路設定。

ProxCenter 副本還會帶著正式 API token 與排程。**新 IP 不等於完全隔離**；啟動前應安排隔離或停用會操作正式環境的自動工作。

### 第四步：確認系統和程式都起來

確認隔離安排完成後才啟動 CT210。容器內檢查：

~~~bash
ip -br addr
ip route
systemctl --failed --no-pager
docker ps
docker ps -a
ss -lntp
~~~

本次 proxcenter-orchestrator、frontend、weasyprint、postgres 四個容器皆 healthy。網頁用 3000 埠：

~~~bash
curl -I http://192.168.10.210:3000
~~~

這些結果支持系統開機與基本網頁服務恢復；業務操作、資料內容及新備份仍需另測。

<a id="recovery"></a>
## 出問題時，在哪裡停下來？

| 現象 | 先查什麼 |
| --- | --- |
| 403 | 使用者、token、ACL 與實際憑證 |
| CIFS 未掛上 | 掛載來源、網路與認證；不要讓資料寫進空掛載目錄 |
| PBS active 但還原失敗 | 指定快照、還原工作日誌與目標 storage |
| CT210 開不起來 | 容器狀態、設定與啟動日誌 |
| 容器正常但網頁不通 | Docker 狀態、實際監聽埠與網路隔離規則 |

回復方案必須另外準備。從舊 kernel 開機只涵蓋 kernel，不能宣稱整個 PBS、套件與 ZFS 都已回到更新前。本文沒有完成整套回復演練，也沒有量到完整 RTO／RPO。

<a id="acceptance"></a>
## 每次維護要留下的結案資料

記錄更新前後版本、重開時間、掛載來源、PBS 服務、PVE storage 狀態與工作日誌。還原演練另外記錄快照時間、還原開始與完成時間、開機時間、應用程式驗收結果。

演練完成後應關閉或隔離測試副本，確認不再操作正式資源；這是收尾要求，不代表本紀錄已提供關機完成證據。

## 延伸閱讀

- [LXC 還原的完整案例](https://kbwangtw.github.io/IT-Knowledge-Base/docs/pve/proxcenter-pbs-restore-dr-runbook/)
- [Ubuntu VM 還原與時間判讀](https://kbwangtw.github.io/IT-Knowledge-Base/docs/pve/ubuntu-vm112-pbs-disaster-recovery/)
- [PBS 套件來源](https://pbs.proxmox.com/docs/installation.html#package-repositories)
- [PBS 使用者管理](https://pbs.proxmox.com/docs/user-management.html)
- [PBS API](https://pbs.proxmox.com/docs/api-viewer/index.html)
