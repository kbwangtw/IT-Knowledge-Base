---
layout: default
title: "把 ESXi 上的 Windows＋SQL Server 虛擬機搬到獨立 PVE（二）：踩雷與效能診斷"
date: 2026-11-07
categories: [PVE, VMware, 遷移, 效能]
permalink: /docs/pve/esxi-vm-to-pve-troubleshooting/
last_modified_at: 2026-11-07
---

# 把 ESXi 上的 Windows＋SQL Server 虛擬機搬到獨立 PVE（二）：踩雷與效能診斷

> **一句話**：同一趟遷移碰到的六個坑：ESXi 網卡協商成 100 Mbps 讓複製慢了約 8 倍、中轉資料夾放錯碟、RAID 5 的寫入快取故障讓寫入只剩 1.5 MiB/s、PVE 把 VMDK 資料檔當成磁碟、開機碟改 VirtIO SCSI 失敗、VMware Tools 移除不掉；每一項都記下「怎麼發現、怎麼確認、怎麼處理」與當時的數字，**其中兩項（VirtIO SCSI 開機失敗的真正原因、RAID 快取的修復）還沒有結案**。

| 項目 | 內容 |
| --- | --- |
| 適合誰看 | 照[上篇](https://kbwangtw.github.io/IT-Knowledge-Base/docs/pve/esxi-vm-to-pve-nfs-relay-sop/)做遷移時遇到問題的人；想知道「速度慢」「寫入卡死」該從哪裡查起的人 |
| 環境 | 同上篇：來源是獨立 ESXi、目標是 PVE 9.2.25 單機（node221），HP Smart Array P420i 控制器，兩組 3 顆 10K SAS 硬碟的 RAID 5 |
| 日期 | 2026-11-07 |
| 結論 | ✅ 網路問題（換線）、系統碟太小、PVE 掃描 VMDK、VMware Tools 都已處理<br>✅ 寫入積壓的資料最終全部寫完，殘留的 LV 已清除（`local-lvm` 回到搬移前的使用率）<br>⏳ RAID 控制器的寫入快取故障**尚未修復**，SQL 的實際負載表現待上班日觀察<br>⏳ 開機碟改 VirtIO SCSI 失敗，**原因沒有查出來**，退回 SATA 運作正常<br>⏳ `sda` 那組磁碟已通電約 9.8 年，要排汰換 |

## 1. 先認識幾個名詞

| 名詞 | 白話解釋 |
| --- | --- |
| **自動協商（auto-negotiation）** | 網卡和交換器接上線後，會互相談定要用 10／100／1000 Mbps 哪一檔。談不攏時會「降速」成雙方都能用的最高檔 |
| **CDP** | Cisco 交換器會告訴相連的設備「我是誰、你接在我的哪個埠」的協定。ESXi 能讀到它 |
| **RAID 5** | 用 3 顆以上磁碟存資料，其中一份是「同位檢查」，壞一顆資料還在。**缺點是小量寫入很慢**：一次小寫入要「讀舊資料、讀舊同位檢查、寫新資料、寫新同位檢查」，變成 4 次磁碟動作（這是 RAID 5 的一般原理） |
| **寫入快取（write cache／FBWC）** | RAID 控制器上的一小塊記憶體：把零碎的寫入先收下來、湊成整條再寫出去，大幅減輕 RAID 5 的負擔。**快取模組或它的電容／電池壞掉時，控制器會自動停用寫入快取**（為了斷電時不遺失資料）。停用只影響速度，不影響資料安全 |
| **LVM-thin** | PVE 的一種儲存：虛擬磁碟用多少配多少，由「精簡配置池」統一管理。池滿了會連累池裡的所有 VM |
| **Writeback／Dirty** | Linux 把要寫進磁碟的資料先放在記憶體：`Dirty` 是還沒送出的，`Writeback` 是已經送出、正在寫的。可在 `/proc/meminfo` 看到 |
| **PSI（`/proc/pressure/io`）** | Linux 回報「程序有多少比例的時間在等 I/O」的指標。`some` 是至少一個程序在等，`full` 是全部都在等。數字越高越塞 |
| **WinRE（Windows 修復環境）** | Windows 開機失敗幾次之後自動進入的修復畫面，用的是一個精簡版的 Windows（WinPE），內建的驅動不多 |
| **VirtIO** | 專為虛擬機設計的虛擬硬體（磁碟、網卡）。效能好，但 Windows 要先有 virtio-win 驅動 |
| **MSI 錯誤 1603** | Windows Installer 的通用失敗代碼，意思是「安裝／解除安裝過程中發生嚴重錯誤」，原因要看記錄檔 |

## 2. 先看這張症狀對照表

| 你看到的現象 | 最可能的原因 | 看第幾節 |
| --- | --- | --- |
| 複製速度只有 10 MiB/s 左右，任何做法都一樣慢 | 網卡協商成 100 Mbps | 3 |
| PVE Task viewer 的 Duration 顯示 17 小時，但明明沒那麼久 | 那是「從開始到現在」，不是實際耗時 | 3-1 |
| NFS 複製到一半停住，檔案只有幾百 MB | 中轉資料夾所在的磁碟太小 | 4 |
| 搬到 `local-lvm` 慢到幾乎不動、`I/O pressure` 高達 70 | RAID 5 沒有寫入快取＋LVM-thin 的零碎寫入 | 5 |
| `Ctrl+C` 之後 `lvremove … in use`，`qemu-img` 變成 `<defunct>` | 還有大量資料在排隊寫入磁碟 | 5-4 |
| `qm set --scsi5 …` 出現 `invalid VMDK image descriptor` | PVE 把 VMDK 的資料檔（`-flat`）當成一顆磁碟 | 6 |
| 磁碟改 VirtIO SCSI 後進 Windows 修復環境，`list vol` 沒有任何磁碟 | 修復環境沒有 VirtIO 驅動（開機失敗的真正原因未查出） | 7 |
| `sc qc vioscsi` 說「指定的服務並不是已安裝的服務」 | 驅動在驅動程式庫，但還沒有對應的硬體讓它載入 | 7-2 |
| 每次登入都跳 `VMware Tools unrecoverable error` | VMware Tools 在 KVM 上找不到 VMware 專屬介面 | 8 |
| 解除安裝 VMware Tools 一直回 `1603` | 解除安裝程式本身失敗；用 Microsoft 的疑難排解員處理 | 8-3 |
| 遠端桌面連不進來，但 3389 在聽 | 防火牆規則停用 | [上篇 13-2](https://kbwangtw.github.io/IT-Knowledge-Base/docs/pve/esxi-vm-to-pve-nfs-relay-sop/) |

## 3. 坑一：速度只有 10 MiB/s，原來是網卡協商成 100 Mbps

### 3-1 怎麼發現

**第一個徵兆：** 用 PVE 內建的 ESXi 匯入精靈搬一台 100 GB 的測試機，Task viewer 顯示：

| 欄位 | 顯示 |
| --- | --- |
| Status | `stopped: OK` |
| Start Time | `2026-11-06 15:13:30` |
| End Time | `-` |
| **Duration** | **`17h 57m 29.1s`** |

`End Time` 是空的，`Duration` 其實是「從開始時間到你打開這個畫面」的經過時間（推測：15:13:30 ＋ 17 小時 57 分 ≈ 畫面截圖的時間），**不是實際耗時**。真正的耗時要從 task 清單取開始與結束的時間戳記：

```bash
pvesh get /nodes/<節點>/tasks --vmid <VMID> --typefilter qmcreate --output-format json-pretty
date -d @<starttime>
date -d @<endtime>
```

這次的 `starttime` 是 1793949210、`endtime` 是 1793958813，相差 9,603 秒，也就是 **2 小時 40 分 03 秒**：

```text
100 GiB × 1024 ÷ 9,603 秒 ≈ 10.7 MiB/s（約 85 Mbps）
```

同樣速度推算，700 GB 要 18 小時 40 分。

另外一次 task 的結果是 `received interrupt`，只花 206 秒就結束，那是有人中途手動停掉的一次，不算進耗時，但整體的牆鐘時間會因此變長。

**第二個徵兆：** 改用 NFS 中轉，C 碟複製的進度數字：

| 時間（UTC） | 進度 | 換算 |
| --- | --- | --- |
| 02:05:01 | 開始 | — |
| 02:06:44 | 10%（前段全零區，幾乎瞬間走完） | — |
| 02:15:09 | 13%（10% → 13% 約 8 分鐘） | 3% ＝ 6 GiB ÷ 約 481 秒 ≈ **12.8 MiB/s** |
| 02:31:02 | 17%（13% → 17% 約 16 分鐘） | 約 **8.6 MiB/s**，推算還要約 5 個半小時 |

匯入精靈與 NFS 中轉兩條**完全不同的路徑**，速度卻都是 10 MiB/s 上下，**這就是「瓶頸在兩條路共同經過的地方」的線索**（網路、交換器或某顆磁碟）。

### 3-2 一層一層查

**ESXi 端：**

```bash
esxcli network nic list
esxcli network nic get -n vmnic0
```

| 看到 | 判讀 |
| --- | --- |
| `vmnic0`、`vmnic1`：`Link Status: Up`、**`Speed: 100`**、`Duplex: Full`；描述是 `Broadcom NetXtreme BCM5719 Gigabit Ethernet` | 網卡是 Gigabit，**實際卻只談到 100** |
| `Auto Negotiation: true`、`Advertised Link Modes` 含 `1000BaseT/Full` | ESXi 有宣告「我可以跑 1000」，所以不是網卡被固定成 100；問題在對端（交換器埠）或網路線 |

**問對端是誰：**

```bash
vim-cmd hostsvc/net/query_networkhint --pnic-name=vmnic0
```

交換器有送 CDP 的話，會看到 `hardwarePlatform = "cisco WS-C2960G-48TC-L"` 與 `portId = "GigabitEthernet0/11"`：型號與接哪一個埠都直接告訴你（FQDN 與管理 IP 也會出現，記錄文件時要遮掉）。

**交換器端（Cisco）：**

```text
show interfaces GigabitEthernet0/11 status
show running-config interface GigabitEthernet0/11
show interfaces GigabitEthernet0/11 | include error|CRC|collision|runts|giants
```

| 看到 | 判讀 |
| --- | --- |
| `Duplex a-full`、**`Speed a-100`** | `a-` 開頭表示是**自動協商的結果**，不是手動設定；協商出 100 |
| `running-config` 只有 `description`，沒有任何 `speed`／`duplex` 設定 | 交換器埠沒有被固定速度 |
| `1 input errors, 1 CRC` 其餘為 0 | 錯誤極少，不像是持續出錯 |
| 型號 2960G-48TC-L 的埠是 `10/100/1000BaseTX` | 硬體本身支援 1000 |

**PVE 端：**

```bash
ethtool nic4 | grep -i -E 'speed|duplex|link detected'
```

`Speed: 10000Mb/s`（PVE 的網卡是 10G），所以瓶頸只在 ESXi 那一端。

### 3-3 原因與處理

兩端都支援 1000、也沒有被固定速度、錯誤計數又很少，最符合的原因是**網路線或接頭**（推測）：1000BASE-T 需要 4 對線都良好，100BASE-TX 只用 2 對；只要其中 2 對斷芯或接觸不良，就會安靜地降速到 100，而且不會產生錯誤。處理方式是**到機房換一條確定良好的 Cat5e／Cat6 短線（或重新接線）**，一次只動一條，因為 `vmnic0`、`vmnic1` 是同一個 vSwitch 的兩條上行，管理網路也走這裡；事先最好備好 iLO 遠端主控台。

> 本次是人在機房處理的，處理後交換器顯示 `a-1000`；**實際動作（換線、換埠或重新插拔）沒有詳細記錄**，「是線材問題」是依症狀的推測，沒有用測線儀驗證。

```bash
esxcli network nic list
```

處理後 `vmnic0`、`vmnic1` 都顯示 `Speed: 1000`，交換器顯示 `a-1000`。

### 3-4 結果

| | 換線前 | 換線後 |
| --- | --- | --- |
| C 碟（約 150 GB 實際資料） | 約 8.6～12.8 MiB/s，預估 5.5 小時（17% 時中止） | **29 分 19 秒**，約 87 MiB/s |
| D 碟（約 499 GB 實際資料） | — | **1 小時 19 分 25 秒**，約 107 MiB/s（接近 1 Gbps 上限） |

> **教訓**：**複製前先看 `esxcli network nic list` 的 `Speed`。** 一個 `100` 就可以讓整趟遷移多花將近一整天，而且所有工具都會「正常」運作，只是很慢。

## 4. 坑二：中轉資料夾放在 PVE 的系統碟

**現象：** 第一次複製，ESXi 顯示進度在跑，PVE 上的 `ls -lah` 顯示資料檔 200G，但 `du` 只有 **405 MB**，之後進度就停住。

**原因：** 資料夾建在 `/export/migrate`，位於 PVE 的**系統碟**（`/dev/mapper/pve-root`，94 GB，可用 82 GB）。C 碟的實際資料約 150 GB，系統碟根本放不下（`ls` 的 200G 是稀疏檔的**虛擬大小**，實際佔用要看 `du`）。

**確認：**

```bash
findmnt -T /export/migrate
df -h /
```

`findmnt` 的 `SOURCE` 若是 `pve-root`，就是放在系統碟上。這次直接用 `ls -lah` ＋ `du -sh` ＋ `findmnt` 就看出來了。

**處理：**

1. ESXi：`esxcli storage nfs remove --volume-name=pve-nfs`（先確認沒有 `vmkfstools` 在跑）。
2. PVE：移除 `/etc/exports` 那行、`exportfs -ra`、`rm -rf /export/migrate`，`df -h /` 確認回到原本用量。
3. 改放在 `VM_Store`（`/mnt/pve/VM_Store/migrate`）。

> **教訓**：建中轉資料夾前先 `findmnt -T <路徑>` 與 `df -h`；**不要把大檔放在系統碟**，系統碟寫滿 PVE 本身會出問題。`ls` 顯示的大小對稀疏檔沒意義，看 `du`。

## 5. 坑三：搬到 local-lvm 慢到停擺，原來是 RAID 5 沒有寫入快取

### 5-1 背景

為了讓 `VM_Store` 有空間可以把 D 碟轉成 qcow2，想把 C 碟（約 150 GB）搬到另一組 RAID 的 `local-lvm`：

```bash
qm disk move 102 sata0 local-lvm
```

### 5-2 現象與數字

| 時間 | 搬移視窗進度 | 新 LV 實際寫入 | 備註 |
| --- | --- | --- | --- |
| 開始後約 2 分鐘 | 1%～2% | `Data% 0.08`（約 0.16 GiB） | 前段全零區被略過 |
| 約 40 分鐘 | 9%（18 GiB） | `Data% 1.81`（約 3.6 GiB） | **實際寫入約 1.5 MiB/s** |
| 關掉 PBS VM 之後 | 沒有改善 | — | 排除「別的 VM 在搶磁碟」 |

按這個速度，150 GB 的實際資料要約 **29 小時**，中止。

### 5-3 一層一層查

**I/O 壓力與吞吐量：**

```bash
cat /proc/pressure/io
vmstat 5 3
```

| 看到 | 判讀 |
| --- | --- |
| `some avg10=72.02`、`full avg10=72.00` | 約 7 成的時間，程序都卡在等 I/O，而且 `full` 也很高：整個系統都被拖慢 |
| `vmstat`：`bi` 約 1.3～1.7 MB/s、`b`＝3、`wa`＝12 | **吞吐量很低，卻有程序被 I/O 卡住**：這不是頻寬滿了（頻寬滿的話吞吐量會很高），而是每次 I/O 的**延遲**很大 |

**是誰卡住：**

```bash
ps -eo pid,stat,wchan:24,cmd | awk '$2 ~ /^D/'
```

只有一個：`[kworker/u96:0+dm-thin]`，等待 `rq_qos_wait`。`dm-thin` 是 LVM-thin 的核心層，`rq_qos_wait` 是核心的寫入節流機制在等底層磁碟回應。**也就是寫進 `local-lvm` 這條路很慢。**

**有沒有磁碟錯誤：**

```bash
dmesg -T | grep -i -E 'error|reset|timeout|offline|blk_update_request|sd[a-b]'
```

只有開機時的辨識訊息，沒有 I/O error、timeout、reset。**但看到兩顆邏輯磁碟都顯示 `Write cache: disabled, read cache: disabled`**。這行是作業系統看到的狀態，不能單憑它判斷控制器快取被關，但值得進一步查。

**是什麼控制器、什麼 RAID 級別、什麼磁碟：**

```bash
lspci | grep -i -E 'raid|smart array'
lsmod | grep -E 'hpsa|smartpqi'
for d in /sys/block/sd?/device; do echo "== $d"; cat $d/raid_level 2>/dev/null; done
dmesg -T | grep -i hpsa | tail -30
```

| 看到 | 判讀 |
| --- | --- |
| `Smart Array Gen8 Controllers`、驅動 `hpsa` | HP Smart Array P420i |
| `sda`、`sdb` 的 `raid_level` 都是 `RAID 5` | 兩組都是 RAID 5 |
| `dmesg`：3 顆 `EG0300FCSPH`（300 GB）、3 顆 `EG000600JWJNP`（600 GB），邏輯磁碟 `RAID-5` ×2 | 300 GB×3 ≈ 600 GB（`sda`）、600 GB×3 ≈ 1.2 TB（`sdb`），與容量吻合，所以是各 3 顆磁碟的 RAID 5（容量推算，未用管理工具確認） |

沒有 `ssacli`（HPE 的管理工具）時，上面這些加上 iLO 的 Storage 頁面就夠了。實體磁碟的健康度可以用 `smartctl` 透過控制器讀：

```bash
for i in 0 1 2 3 4 5; do echo "== cciss,$i"; smartctl -H -d cciss,$i /dev/sda 2>&1 | tail -4; done
for i in 0 1 2 3 4 5; do echo "== cciss,$i"; smartctl -a -d cciss,$i /dev/sda 2>&1 | grep -i -E 'power on|grown|uncorrected|^read:|^write:'; done
```

| 結果 | 判讀 |
| --- | --- |
| 6 顆都是 `SMART Health Status: OK` | 沒有被判定故障 |
| 通電時數：300 GB 那 3 顆約 **86,000 小時（約 9.8 年）**；600 GB 那 3 顆約 4,345 小時（約 181 天） | **`sda` 那組磁碟非常老**；`sdb` 那組是半年前換的 |
| 「未更正錯誤」全是 0；一顆有 1 個重新配置的壞軌；舊磁碟有少量「延遲更正」 | 沒有讀不回來的資料，但老化跡象要追蹤 |

### 5-4 原因（推測，未確認）

| 因素 | 說明 |
| --- | --- |
| RAID 控制器的寫入快取被停用（使用者回報 P420i 的快取因故障被關掉） | 最主要的因素 |
| RAID 5 的小量寫入懲罰 | 沒有快取湊成整條，每次小寫入都要走完 4 次磁碟動作 |
| LVM-thin 的寫入型態 | 精簡配置池一次配置小區塊，寫入零碎 |
| 10K SAS 硬碟的隨機寫入能力有限 | 估算：每顆約 100～150 IOPS，3 顆 RAID 5 無快取，小量寫入約 100 次／秒，以 64 KiB 計理論上限約 6.5 MiB/s（一般規格推算，非實測），再加上池本身的開銷，掉到 1.5 MiB/s 並不意外 |
| 同一段 ESXi → `VM_Store` 的 500 GB 連續寫入卻能到 107 MiB/s | 大塊、連續的寫入可以整條寫，不吃小寫入的虧（推測） |

**`sdb` 與 `sda` 是同一個控制器**，所以這個限制同樣適用於 `VM_Store`，只是大塊連續寫入撐得住；**SQL Server 的交易記錄是零碎的同步寫入，在沒有寫入快取的 RAID 5 上會明顯吃虧**，這是上線後要盯的重點。

### 5-5 中止之後的收拾（這段最容易慌）

在搬移視窗按 `Ctrl+C`，看到：

```text
lvremove 'pve/vm-102-disk-0' error:   Logical volume pve/vm-102-disk-0 in use.
storage migration failed: copy failed: … qemu-img convert … failed: interrupted by signal
```

| 現象 | 說明 |
| --- | --- |
| `qm config 102` 沒變 | 搬移失敗不會動到原本的磁碟設定，舊的 C 完全沒事 |
| `lvs` 還有 `vm-102-disk-0`，`Attr` 是 `Vwi-aotz--`（`o` ＝開啟中） | 殘留的半成品 |
| `ps aux \| grep qemu-img` 看到 `Zl [qemu-img] <defunct>`（殭屍） | 主程序已結束，還有執行緒卡在核心裡 |
| `ps -eLo pid,tid,stat,wchan:28,cmd` 看到 `Dl folio_wait_bit_common` | 那個執行緒在等頁面寫回完成 |
| `grep -E 'Dirty\|Writeback:' /proc/meminfo`：`Writeback: 9961184 kB`（約 9.5 GiB） | **搬移視窗的 `transferred 18 GiB` 只是「讀出去、丟進作業系統快取」的量，真正落到磁碟的才 3.7 GiB，其餘還在排隊寫入** |

**處理：什麼都不要硬來，等它寫完。** 量排空速度（兩個時間點的差）：

```bash
watch -n 30 "date; grep -E 'Dirty|Writeback:' /proc/meminfo"
```

這次 15:32 時 `Writeback` 是 9,892,200 kB，比前一次只少約 67 MiB，當時粗估要好幾個小時。後來**隔了約兩三個小時再回頭看**（中間沒有再量，排空的實際速度沒有記錄），`Writeback` 已經是 0 kB、`/proc/pressure/io` 全部 `0.00`、`vmstat` 的 `b` 為 0。這時才清殘留：

```bash
qm config 102 | grep -E 'local-lvm|unused'      # 要沒有輸出，確認沒有 VM 引用它
pvesm free local-lvm:vm-102-disk-0
lvs
```

`lvs` 只剩 `vm-200-disk-0`，池的 `Data%` 回到搬移前的 7.47。

| 不要做 | 原因 |
| --- | --- |
| `sync` | 會等所有積壓寫完而卡住 |
| `kill -9` 殭屍 | 殭屍已經結束，殺不掉；卡住的執行緒殺了也沒有用 |
| 重開 PVE 主機 | 關機會等積壓；硬重置有風險 |

### 5-6 結論與後續

| 項目 | 結論 |
| --- | --- |
| 這次的搬移 | 取消。C 碟留在 `VM_Store`，D 碟直接掛 VMDK（上篇第 9 節），不需要靠搬 C 來騰空間 |
| 寫入 `sda` | 修好快取之前不要再對它做大量寫入；`sda` 同時是 PVE 的系統碟，積壓會拖慢 PVE 本身 |
| 不建議的「快速解法」 | 啟用無電池寫入快取（NBWC）或開啟實體磁碟寫入快取：斷電時快取資料會遺失，對資料庫風險很高，除非有 UPS 與完整備份；本次沒有實測這些設定 |
| 該做的 | 到 iLO 確認是快取模組還是電容／電池故障並更換；規劃汰換 `sda` 那 3 顆近 10 年的磁碟（PVE 在這組上，壞掉整台節點停擺） |

## 6. 坑四：PVE 把 VMDK 的資料檔當成一顆磁碟

**現象：** 建立 VMDK 描述檔與資料檔、掛上去之後，要再新增一顆暫時磁碟：

```bash
qm set 102 --scsi5 VM_Store:1
```

出現：

```text
qemu-img: Could not open '/mnt/pve/VM_Store/images/102/<VM>-D-flat.vmdk': invalid VMDK image descriptor
```

`qm config` 裡有 `scsihw` 已被改掉，**卻沒有 `scsi5`**。

**原因：** PVE 在替新磁碟挑名字之前，會掃描 `images/<VMID>/` 底下**所有 `.raw`、`.qcow2`、`.vmdk` 結尾的檔案**，逐一用 `qemu-img info` 檢查。`<VM>-D-flat.vmdk` 是**資料檔，不是描述檔**，檢查必然失敗。**PVE 不要求檔名一定是 `vm-<VMID>-` 開頭。**

**為什麼危險：** 如果這時執行 `qm rescan`，PVE 可能把資料檔當成「未使用的磁碟」（`unusedN`）加進設定；之後有人移除這個 `unused` 項目時，PVE 會連資料檔本身一起刪掉。

**處理：把資料檔的副檔名改掉**（QEMU 只看描述檔裡寫的名稱，不在乎副檔名），VM 要先關機：

```bash
qm list                                              # 確認 stopped
mv /mnt/pve/VM_Store/images/102/<VM>-D-flat.vmdk /mnt/pve/VM_Store/images/102/<VM>-D.flat
sed -i 's/"<VM>-D-flat.vmdk"/"<VM>-D.flat"/' /mnt/pve/VM_Store/images/102/vm-102-disk-2.vmdk
grep -a -n 'RW' /mnt/pve/VM_Store/images/102/vm-102-disk-2.vmdk
qemu-img info /mnt/pve/VM_Store/images/102/vm-102-disk-2.vmdk
pvesm list VM_Store --vmid 102
```

| 看到 | 判讀 |
| --- | --- |
| `grep -a`：`RW 1048576000 VMFS "<VM>-D.flat"` | 描述檔已指向新檔名（不加 `-a` 會顯示 `binary file matches`，因為描述檔結尾有空位元組） |
| `qemu-img info`：`file format: vmdk`、`virtual size: 500 GiB`，extent 的 filename 是 `…/<VM>-D.flat` | QEMU 依描述檔找到資料檔 |
| `pvesm list`：只列出 `disk-0.qcow2`、`disk-1.qcow2`、`disk-2.vmdk`，沒有錯誤 | PVE 不再掃到資料檔 |

之後 `qm set 102 --scsi5 VM_Store:1` 成功。這個做法**資料沒有被改動**，只是改檔名與描述檔，隨時可以改回去。

> **注意**：VM 運作過之後，QEMU 會自動更新描述檔裡的 `CID` 欄位，檔案大小也可能從約 554 bytes 變成約 1 KB，這是 VMDK 的正常行為，不是損壞。日後移除這顆磁碟時，PVE 只會處理描述檔，`<VM>-D.flat` 可能殘留，要手動確認清理。

## 7. 坑五：開機碟改 VirtIO SCSI，Windows 進了修復環境

### 7-1 現象

把兩顆磁碟的匯流排從 SATA 改成 VirtIO SCSI（Hardware → Detach → 對 Unused Disk 選 SCSI），開機後 Console 進到 Windows 的**「進階選項」**（系統還原、啟動修復、命令提示字元…）。進命令提示字元：

```bat
diskpart
list vol
```

顯示 **`沒有磁碟區`**。

| 判讀 | 說明 |
| --- | --- |
| 為什麼看不到任何磁碟 | 修復環境（WinPE）只內建一般常見的儲存驅動，**沒有 VirtIO SCSI 驅動**，看不到掛在上面的 C、D。這是預期，**不代表磁碟壞了** |
| 能走到修復環境代表什麼 | UEFI 找得到開機磁碟、開機管理程式也載入了；失敗發生在 Windows 核心載入階段 |
| 為什麼不能在這裡讀 `SrtTrail.txt` | 沒有驅動就看不到磁碟，要先掛 virtio-win ISO 用 `drvload` 載入驅動（**本次沒有做**） |

### 7-2 事前的驗證，哪裡沒做夠

換之前其實做過驗證，但**不夠**：

```bat
sc qc vioscsi
```

```text
[SC] OpenService 無法 1060：指定的服務並不是已安裝的服務。
```

```bat
pnputil /enum-drivers | findstr /i "vioscsi viostor netkvm vioser balloon"
```

驅動程式庫裡有 `vioscsi.inf`、`viostor.inf`、`netkvm.inf`、`vioser.inf`、`balloon.inf`。也就是說驅動**放進去了，但沒有對應的硬體，所以沒有建立成服務**。這時直接換開機碟會失敗。

**讓 Windows 載入驅動的做法：** VM 關機，加一顆暫時的 1 GB VirtIO SCSI 磁碟，開機：

```bash
qm set 102 --scsihw virtio-scsi-single --scsi5 VM_Store:1
qm config 102
```

進 Windows 後：

| 看什麼 | 看到 |
| --- | --- |
| 裝置管理員 → 存放控制器 | `Red Hat VirtIO SCSI pass-through controller` |
| `sc qc vioscsi` | `START_TYPE : 0 BOOT_START`、`BINARY_PATH_NAME : \SystemRoot\System32\drivers\vioscsi.sys` |

驅動確實載入、也設成了開機啟動，**但實際改開機碟後還是失敗**。所以這一步是必要條件，不是充分條件。

### 7-3 移除暫時磁碟，並留意「卸下」與「刪除」

網頁介面：Hardware → 選那顆 `scsi5` → **Detach**，再對出現的 `Unused Disk` → **Remove**。用指令的話要小心：

| 指令 | 效果（依本次經驗與 PVE 的行為，使用前請先 `qm config` 確認） |
| --- | --- |
| `qm set 102 --delete scsi5` | 只是**卸下**，磁碟變成 `unused0`，檔案還在 |
| `qm set 102 --delete unused0` | **真的刪檔，無法還原** |

兩個指令長得很像，手誤的代價很高：**刪 `unusedN` 前務必先 `qm config 102` 確認那是 1 GB 的暫時磁碟**，絕對不能指到 C 或 D。

### 7-4 還有一個連帶的小坑：開機順序變成空的

卸下 `sata0` 之後，`qm config` 裡 `boot:` 變成**空白**（原本的 `order=sata0` 隨磁碟消失）。改成 VirtIO 之後要明確寫上：

```bash
qm set 102 --boot order=scsi0
```

（我們當時沒有一次改好，所以有一段時間是空的。）

### 7-5 退回 SATA

PVE（VM 先關機）：

1. Hardware → 選 `Hard Disk (scsi0)` → **Detach**。
2. 對 `Unused Disk` 按兩下 → Bus/Device 選 **SATA 0** → Add。
3. Options → Boot Order → `sata0` 打勾放第一。

指令版：

```bash
qm stop 102
qm set 102 --delete scsi0
qm config 102                        # 確認 unused0 指向 vm-102-disk-1.qcow2
qm set 102 --sata0 VM_Store:102/vm-102-disk-1.qcow2
qm set 102 --boot order=sata0
```

退回後 Windows 正常開機，資料完全沒有受影響。

### 7-6 結論

| 項目 | 狀態 |
| --- | --- |
| 開機碟用 VirtIO SCSI | ❌ 失敗，**原因沒有查出來** |
| 資料碟（D）單獨用 VirtIO SCSI 是否可行 | 未驗證（我們是兩顆一起改、一起退回） |
| 目前做法 | 兩顆都用 SATA，運作穩定；真正拖慢效能的是 RAID 5 沒有寫入快取，VirtIO 換不換差別有限 |
| 之後若想再試 | 一次只改一顆；先試 D 碟；開機碟要掛 virtio-win ISO，在修復環境用 `drvload` 載入驅動讀 `SrtTrail.txt` 找原因 |

## 8. 坑六：VMware Tools 在 KVM 上報錯，而且移除不掉

> 這個問題另外有一篇專門的 SOP：[VMware 搬到 PVE 後，Windows VM 開機跳出 VMware Tools 錯誤：移除失敗（1603）的處理](https://kbwangtw.github.io/IT-Knowledge-Base/docs/pve/pve-vm-remove-vmware-tools-after-migration/)，包含從 log 找失敗點、清到檔案與驅動的完整步驟。本節是這趟遷移當下的做法與結果，兩篇的取捨差異見 8-5。

### 8-1 現象

每次登入都跳出視窗：

```text
VMware Tools unrecoverable error: (host-xxxx)
Exception 0xc0000096 has occurred.
```

同時系統記錄有 7011（服務逾時）。**這是預期的**：VMware Tools 的服務在啟動時會呼叫 VMware 專屬的介面，KVM 上沒有，所以出錯。這個例外代碼我印象中是「特權指令」（推測）。**不影響 SQL 與資料。**

### 8-2 先止血（不需要重開機，可逆）

```powershell
Get-Service -DisplayName '*VMware*' | Format-Table Name,DisplayName,Status,StartType
Get-Service -DisplayName '*VMware*' | ForEach-Object { Stop-Service $_.Name -Force -ErrorAction SilentlyContinue; Set-Service $_.Name -StartupType Disabled }
Get-ItemProperty HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run | Format-List
```

這次看到四個服務：`VGAuthService`、`vm3dservice`、`VMTools`、`vmvss`；開機自動執行的 `Run` 裡有一項 `VMware User Process`（`vmtoolsd.exe -n vmusr`），**這才是登入時跳視窗的來源**。移除它（先把原本的值記下來，要還原時用 `New-ItemProperty` 加回去）：

```powershell
Get-Process vmtoolsd -ErrorAction SilentlyContinue | Stop-Process -Force
Remove-ItemProperty -Path HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run -Name 'VMware User Process'
```

`Run` 清單只剩 `SecurityHealth`（Windows 安全性圖示，不要動）。

### 8-3 正式移除：先按標準做法，失敗再用疑難排解員

先找產品代碼，用 `/x`（解除安裝）、不要用登錄檔裡那個 `/I`（那是修改）：

```powershell
Get-ItemProperty HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\* | Where-Object { $_.DisplayName -like 'VMware Tools*' } | Format-List DisplayName,UninstallString,PSChildName
$p = Start-Process msiexec.exe -ArgumentList '/x {ProductCode} /l*v C:\vmtools-uninstall.log /norestart REBOOT=ReallySuppress' -Wait -PassThru
$p.ExitCode
```

（`{ProductCode}` 換成上面查到的 `PSChildName`。）

| 結果 | 判讀 |
| --- | --- |
| `0`、`3010` | 成功（`3010` 要重開機才完全生效） |
| **`1603`** | 失敗。**本次即使先把服務停掉、程序殺掉，重試仍是 `1603`**，不是檔案被占用造成的，原因要看記錄檔（`Select-String -Path C:\vmtools-uninstall.log -Pattern 'Return value 3' -Context 20,2`）；這次沒有深究原因 |

最後用 **Microsoft 的「Program Install and Uninstall troubleshooter」**（疑難排解員，需自行從 Microsoft 官網取得）移除成功。結果：

| 項目 | 狀態 |
| --- | --- |
| 「程式和功能」裡的 VMware Tools | 消失 ✅ |
| 四個服務 | **登錄還在**，`Stopped`／`Disabled` |
| 驅動 | `vmci`（Running／Boot）、`vsock`（Running／Boot）、`VMMemCtl`（Running／Auto）、`vmmouse`（Running／Manual）還在，`vm3dmp` 系列為 `Stopped`／`Manual` |

### 8-4 清掉服務登錄（先備份、可還原）

⚠ **要用 `sc.exe`，不是 `sc`**：PowerShell 裡的 `sc` 是 `Set-Content` 的別名。

```powershell
New-Item -ItemType Directory C:\vmware-backup -Force | Out-Null
foreach ($s in 'VGAuthService','vm3dservice','VMTools','vmvss') { reg export "HKLM\SYSTEM\CurrentControlSet\Services\$s" "C:\vmware-backup\$s.reg" /y }
foreach ($s in 'VGAuthService','vm3dservice','VMTools','vmvss') { sc.exe delete $s }
```

每個都回 `[SC] DeleteService 成功`。要還原就 `reg import C:\vmware-backup\<名稱>.reg`（重開機後生效）。重開機後：

```powershell
Get-Service -DisplayName '*VMware*' -ErrorAction SilentlyContinue | Format-Table Name,Status,StartType
```

沒有輸出、登入後沒有彈窗、系統記錄沒有新的 Error。

### 8-5 殘留的驅動：先不要動

`vmci`、`vsock` 是**開機啟動**的驅動，在 KVM 上沒有對應的硬體，載入了也沒有作用（推測，沒有逐一驗證）。

**要不要連資料夾與驅動一起清掉，是取捨：**

| 做法 | 說明 |
| --- | --- |
| 本次的做法（保守） | 服務登錄清掉、驅動與 `C:\Program Files\VMware` 先留著，穩定一兩週再處理；`C:\Program Files\VMware` 建議先改名成 `VMware.old` 觀察，不要直接刪 |
| 更徹底的做法 | 另一篇 SOP [VMware 搬到 PVE 後，Windows VM 開機跳出 VMware Tools 錯誤：移除失敗（1603）的處理](https://kbwangtw.github.io/IT-Knowledge-Base/docs/pve/pve-vm-remove-vmware-tools-after-migration/)在另一台 VM 上連安裝資料夾與 `vmmouse` 驅動都刪掉，並驗證重開機後正常。它動手前先做 snapshot，我們這台的磁碟是 VMDK，**PVE 不支援快照**，所以沒有採用 |
| 兩者的差別 | 那台 VM 只殘留一個滑鼠驅動；這台還多了 `vmci`、`vsock` 這兩個**開機啟動**的驅動，清不乾淨可能留下開機問題，所以先不動 |

真的要清驅動時，選在不上班時間，用 `pnputil /enum-drivers` 找出 VMware 的驅動套件，再用 `pnputil /delete-driver <oemNN.inf> /uninstall` 處理，並先確認可以還原（例如先備份整台 VM）。

## 9. 其他小坑

| 現象 | 原因與處理 |
| --- | --- |
| VNC 主控台不能複製貼上 | PVE 的 noVNC 背後是 QEMU 內建的 VNC，不同步剪貼簿（要靠 SPICE 加 Guest 內的代理）。指令改成一行手打；打出怪字元時到 VM → Options → Keyboard Layout 改成實際的鍵盤配置；接上網路後改用遠端桌面 |
| 在錯的節點貼了指令 | **兩台 PVE 各有一個 VMID 102**（一台是搬進來的 VM、一台是別的 VM），貼指令前看提示字元（`root@node221` 或 `root@node220`）。幸好另一台沒有 `VM_Store` 這個儲存，指令被拒絕；若兩台日後併成叢集，VMID 不能重複 |
| `vim-cmd vmsvc/power.getstate <Vmid>` 出現 `syntax error: unexpected newline` | `<` `>` 是 shell 的特殊字元，要換成實際數字（先 `vim-cmd vmsvc/getallvms` 查） |
| ESXi 上 `findmnt` 找不到 | ESXi 的 shell 是 busybox，沒有這個指令，在 PVE 上執行 |
| NFS 資料夾裡出現 `.lck-xxxx` | ESXi 開檔時產生的 NFS 鎖定檔，複製結束、ESXi 卸載後自然消失，不是殘留 |
| `df` 顯示 1.1T，但可用不到 1.2T | 先看實際的 `Avail`，不要照硬碟標示容量算 |
| 在 Windows 裡刪檔讓 D 碟用量降到 19 GB，VMDK 還是 500 GB | 刪檔不會讓 thick VMDK 縮小；要縮小得在 Windows 內把空白區填零再回收，或在 PVE 內建新的小磁碟把資料搬過去（本次未做） |
| 驗證時用 DHCP 拿到的 IP | 租約到期可能換 IP，客戶端靠 DNS 名稱連線會連不到；正式機一定要用靜態 IP，並重新登錄 DNS（`ipconfig /registerdns`） |
| 掛光碟機之後，`boot:` 變成 `order=sata0;ide2` | PVE 自動把光碟機加進開機順序，退出光碟後改回 `order=sata0` |

## 10. 待辦

- [ ] 更換 P420i 的寫入快取模組或電容／電池（到 iLO 確認是哪一項），並與廠商確認韌體版本（本次讀到 `8.00`）
- [ ] 規劃汰換 `sda` 那 3 顆通電約 9.8 年的磁碟（PVE 本身在這組上）；先備份 PVE 設定檔
- [ ] 上班日用 `typeperf` 量實際的磁碟延遲，評估 RAID 5 無寫入快取下的使用者感受；長期評估資料庫放在 SSD 或 RAID 10
- [ ] 開機碟 VirtIO SCSI 失敗的原因：掛 virtio-win ISO，在修復環境 `drvload` 載入驅動後讀 `SrtTrail.txt`；先試 D 碟單獨使用 VirtIO
- [ ] 解除安裝 VMware Tools 失敗（1603）的根本原因：沒有看記錄檔；目前已用疑難排解員移除
- [ ] 殘留驅動（`vmci`、`vsock`、`VMMemCtl`、`vmmouse`）、`C:\Program Files\VMware`、`C:\vmware-backup`：穩定一兩週後整理
- [ ] 網路 100 Mbps 的實際瑕疵（哪一條線、哪一對）沒有量測；如果有換下來的線，可拿去測線儀確認，並順手檢查另一條上行線與配線盤

## 11. 延伸閱讀

- 本知識庫：[把 ESXi 上的 Windows＋SQL Server 虛擬機搬到獨立 PVE（一）：NFS 中轉、掛上磁碟與開機驗證](https://kbwangtw.github.io/IT-Knowledge-Base/docs/pve/esxi-vm-to-pve-nfs-relay-sop/)
- 本知識庫：[Ceph 出現 BlueStore 慢操作告警：硬碟壞了嗎？](https://kbwangtw.github.io/IT-Knowledge-Base/docs/pve/ceph-bluestore-slow-op-backup-schedule/)：另一個「慢」的案例，含 SMART、碟溫、寫入量的看法
- 本知識庫：[VMware 搬到 PVE 後，Windows VM 開機跳出 VMware Tools 錯誤：移除失敗（1603）的處理](https://kbwangtw.github.io/IT-Knowledge-Base/docs/pve/pve-vm-remove-vmware-tools-after-migration/)：第 8 節的完整版（含 log 分析、刪檔與刪驅動）
- [Linux PSI（Pressure Stall Information）文件](https://docs.kernel.org/accounting/psi.html)：`/proc/pressure/io` 各欄位的意思
- [Proxmox VE：Windows VirtIO Drivers](https://pve.proxmox.com/wiki/Windows_VirtIO_Drivers)
- [Proxmox VE：Qcow2／VMDK 與儲存格式](https://pve.proxmox.com/wiki/Storage)
