---
layout: default
title: "PVE 單節點故障演練：拔掉一台的電源，量 Ceph、HA 與告警鏈"
date: 2026-11-02
categories: [PVE, HA, Ceph, Graylog]
permalink: /docs/pve/pve-single-node-failure-drill/
last_modified_at: 2026-11-02
---

# PVE 單節點故障演練：拔掉一台的電源，量 Ceph、HA 與告警鏈

> **一句話**：三台 PVE 叢集到現在只做過「計畫性」的重開，沒有真的讓一台突然消失過。這篇是演練計畫：直接拔掉 node10 的電源，實測 Ceph 讀寫卡住幾秒、HA 多久把服務在別台拉起來、告警信多久寄到；**目前尚未演練**，實測欄位留空，演練後補上。

| 項目 | 內容 |
| --- | --- |
| 適合誰看 | 有 PVE＋Ceph 三節點叢集，想知道「一台突然掛掉時到底會怎樣」的人 |
| 環境 | PVE 9.2.x 三節點（node10～12，Win element M600 迷你主機，**沒有 IPMI**）；Ceph 20.2.4，每台 1 顆 OSD；HA 資源 13 個；Graylog 告警＋節點外部檢查 |
| 演練日期 | **未定**（建議平日 10:00～12:00，避開 21:00～03:00 備份、08:00～08:30 心跳與備份檢查） |
| 演練方式 | 斷電（長按電源鍵），演練節點 node10 |
| 結論 | ✅ 計畫與量測腳本完成 ✅ 事前準備：HA 已分散（[HA 文件](https://kbwangtw.github.io/IT-Knowledge-Base/docs/pve/pve-ha-placement-policy/) 13-1 節）、osd.1 重開驗證完成 ⏳ 實際演練 ⏳ 填入實測數字 |

**這篇怎麼讀**：第 2～4 節說明會發生什麼、為什麼這樣選；第 5～11 節是演練當天照著做的步驟；第 12 節是記錄表，演練時邊做邊填。

## 1. 先認識幾個名詞

| 名詞 | 白話解釋 |
| --- | --- |
| **quorum** | 叢集「過半數」的投票。三台要至少兩台在，才能繼續管理叢集 |
| **fencing** | 確認失聯的節點真的停了，才在別台啟動它的服務，避免同一顆磁碟被兩邊同時寫 |
| **watchdog** | 每台節點上的計時器；節點失去 quorum 又沒按時回報時，它會把自己強制重開 |
| **HA recovery** | HA 確認節點故障後，把它的服務在其他節點重新啟動 |
| **OSD down／out** | down = 叢集發現這顆硬碟沒回應；out = 叢集決定不再把資料放它身上（預設 down 10 分鐘後才 out） |
| **PG peering** | OSD 狀態變了之後，同一份資料的幾個副本互相確認「誰是最新的」；這段時間那份資料的讀寫會等一下 |
| **MON 選舉** | 三個 MON 之中有一個是 leader；leader 掛了，剩下的會重新選一個 |
| **mgr failover** | active 的 mgr 掛了，standby 的接手 |
| **UDP syslog** | 日誌送給 Graylog 的方式：只送不確認；Graylog 沒在收時，那段日誌就遺失 |
| **路徑 A／C** | Graylog 告警（經過 Graylog）／節點外部檢查直接用 postfix 寄信（不經過 Graylog），見 [Graylog 告警（二）](https://kbwangtw.github.io/IT-Knowledge-Base/docs/pve/graylog-alerts-monitoring/)第 2 節 |

## 2. 全貌：拔電後預期會發生什麼

以下時間都是依官方文件的預設值**推估**，就是這次要實測的東西：

```text
T0        拔掉 node10 電源
T0+數秒   MON：node10 原本是 leader → node11、node12 重新選舉
          mgr：node10 原本是 active → standby 接手
T0+約20秒 OSD：osd.0 心跳逾時，被標成 down
          → 主副本在 osd.0 上的資料，讀寫在這之前會卡住；peering 完成後恢復
T0+約1分  HA：node10 的 LRM 不再回報，CRM 開始等待 fencing
T0+約2～3分 HA：確認 node10 已停，Graylog、ai、Grafana、DC01 在 node11／node12 重新啟動
T0+約4～6分 Graylog 恢復收日誌 → 之後的「節點離線」訊息才收得到 → 第一封【PVE Node 狀態離線】
T0+10分   Ceph：osd.0 被標成 out；三台各一顆 OSD，沒有地方補第三份副本，PG 維持 degraded
─── 觀察完畢，按電源開機 ───
開機後    node10 回到 quorum、osd.0 up＋in、PG 回到 active+clean、HEALTH_OK
          HA 服務「不會」自動搬回 node10（CRS static），要手動搬
```

## 3. 為什麼選「斷電」、為什麼選 node10

### 3-1 三種失聯方式

node10～12 都有兩個網路埠：`vmbr0`（管理／服務網）和 `Cluster`（corosync 與 Ceph 複製）。**Ceph 的 `public_network` 在 vmbr0、`cluster_network` 在 Cluster**；corosync 只有一條 link（link0，在 Cluster）。所以三種「失聯」的結果很不一樣（依官方文件機制推估，未實測）：

| 方式 | corosync | Ceph | HA | 適合當第一次演練嗎 |
| --- | --- | --- | --- | --- |
| **斷電（本次）** | 失聯 | MON、OSD 一起消失 | 2～3 分鐘後在別台重啟服務 | ✅ 結果最乾淨，Ceph 卡頓、HA 恢復、告警鏈都量得到 |
| 拔 Cluster 線 | 失聯 → 約 1 分鐘後 watchdog 強制重開 | 複製網斷、public 還通，osd 可能**反覆上下線（flapping）** | 被 fence 後在別台重啟 | ❌ 能驗證 fencing，但數字混亂；排第二次 |
| 拔 vmbr0 線 | **還在** | 這台的 MON 掉出 quorum、OSD 被標 down | ⚠️ **什麼都不做**：節點還在叢集裡，HA 以為服務都正常 | ❌ 不是演練，是已知盲點（見第 13 節待辦） |

正常關機也不行：Shutdown Policy 是 `migrate`，關機前 HA 會先把服務搬走，那是維護不是故障。

### 3-2 為什麼是 node10

演練當下的 HA 分布（2026-11-01 13-1 節重新分散後，演練前要再確認）：

| 節點 | HA 資源 |
| --- | --- |
| **node10** | **Graylog(105)**、ai(113)、Grafana(114)、DC01(vm:106) |
| node11 | AdGuard(100)、IPAM(103)、ProxCenter(110)、Wazuh(112)、CA(vm:111) |
| node12 | Pi-hole(101)、LibreNMS(102)、WireGuard(109)、DC02(vm:107) |

- **Graylog 在 node10**：Graylog 跟著節點一起消失，才能驗證告警鏈最弱的情況（第 4 節）。
- **node10 是 MON leader、mgr active**（11/01 查到；演練前再確認）：順便量 MON 選舉與 mgr 接手。
- **WireGuard 不在 node10**：VPN 不受影響。不過拔電、開機都要人在現場，操作仍建議在內網。
- node10 沒有非 HA 的 VM；node11 的 VM 104、108 不受影響。

## 4. 告警鏈的預期：Graylog 自己也在 node10

| 告警 | 走哪條路 | 預期（**推測**） | 理由 |
| --- | --- | --- | --- |
| PVE Corosync 成員離線 | 路徑 A | ❌ **多半收不到** | `Members left:` 只在 T0 寫一次，那時 Graylog 正跟著 node10 消失，UDP 日誌遺失 |
| Ceph 健康警告 | 路徑 A | ❌ T0 附近的收不到；之後 Graylog 恢復時若 Ceph 又寫了新的 `Health check failed:`（例如 osd.0 被標 out），可能會收到 | 同上 |
| PVE Node 狀態離線 | 路徑 A（node11、node12 每分鐘送 `PVE_NODE_OFFLINE`） | ✅ 晚到，約 T0+4～6 分 | 要等 Graylog 在別台開好，之後送的才收得到 |
| 【Graylog 異常】 | 路徑 C（node11、node12 每 5 分鐘檢查） | ⚠️ 0～2 封 | Graylog 停機約 4～5 分鐘；檢查剛好碰到才會寄，兩台各寄一封。恢復時再各寄【已恢復】 |
| 【NAS 連不上】 | 路徑 C | ✅ **不應該寄** | NAS 沒事；用來確認 node11、node12 的檢查腳本在 node10 消失時沒有誤報 |
| PVE 自己的 fencing 通知 | PVE 通知系統 → postfix | ⚠️ 未確認會不會寄 | PVE 有 fencing 通知事件，本環境沒測過 |

**這次演練最重要的發現之一，就是確認上表哪幾格猜錯了。**

## 5. 演練前一週：準備

- [ ] **排日期**：平日 10:00～12:00；當天沒有更新、沒有其他維護。
- [ ] **通知使用者**：DC01 會重啟約 3～5 分鐘（DC02 在 node12，AD 不中斷）；Lab Ops（ai）會斷線；Grafana 戰情中心會中斷幾分鐘。
- [ ] **現場救援準備**：node10 旁邊可以接**螢幕和鍵盤**。M600 沒有 IPMI，開機後若 SSH 進不去，只能從本機主控台登入。
- [ ] **記得 root 密碼**：10/22 起 SSH 只能用金鑰，但本機主控台登入不經過 sshd，還是用密碼（[Fail2Ban 文件](https://kbwangtw.github.io/IT-Knowledge-Base/docs/pve/pve-cluster-fail2ban-hardening/)第 12 節）。
- [ ] **帶 TOTP 裝置**：node11、node12 的 PVE 網頁 Shell 是 SSH 以外的備援路線。
- [ ] **在內網用演練當天的那台電腦**，以金鑰登入 node10、node11、node12 各一次，伺服器端 `journalctl -u ssh --since "10 min ago" | grep Accepted` 確認是 `publickey`。
- [ ] **手機開好 Gmail**，演練時記錄每封告警信的收信時間。

> ⚠️ **SSH 的風險**：三台的 `/root/.ssh/authorized_keys` 是指向 `/etc/pve/priv/authorized_keys` 的連結。node10 開機後如果 `pve-cluster`（pmxcfs）沒起來，`/etc/pve` 是空的，**金鑰登入會失敗、密碼又已關閉**；node10 自己的網頁也需要 pmxcfs。這時只剩本機主控台。

## 6. 步驟一：演練前檢查（T0 前 30 分鐘，node11）

**做什麼**：確認叢集完全健康，並記下演練前的狀態。**所有量測都在 node11 上做**，因為 node10 會被拔電。

**怎麼做**（在 node11，只讀取）：

```bash
D=/root/drill-$(date +%Y%m%d); mkdir -p $D; cd $D
{
  date '+%F %T'
  pvecm status | grep -E 'Quorate|Total votes|0x'
  ha-manager status
  ha-manager rules config
  ceph -s
  ceph pg stat
  ceph quorum_status -f json | python3 -c 'import json,sys; d=json.load(sys.stdin); print("MON leader:", d["quorum_leader_name"])'
  ceph mgr stat
  ceph fs status | head -15
  ceph osd pool ls detail | grep -E '^pool' | awk '{print $3, $5, $6, $7, $8}'
  ceph config get mon mon_osd_down_out_interval
  grep -A6 '^rbd: VM_Pool' /etc/pve/storage.cfg | grep -E 'rbd:|pool'
} 2>&1 | tee before.txt
for n in node10 node11 node12; do
  echo -n "$n 備份程序數："; ssh root@$n 'ps aux | grep -c "[v]zdump"' < /dev/null
done
for n in node11 node12; do
  echo "== $n"; ssh root@$n 'systemctl list-timers --no-pager | grep -E "graylog-health|nas-reach|pve-node-monitor"; cat /var/lib/graylog-health/status' < /dev/null
done
```

| 片段 | 意思 |
| --- | --- |
| `D=/root/drill-日期` | 這次演練的所有紀錄都放這個資料夾 |
| `{ … } 2>&1 \| tee before.txt` | 整段輸出同時顯示在畫面上、也存成檔案 |
| `quorum_leader_name` | 目前哪一台是 MON leader |
| `ceph mgr stat` | 目前哪一台是 active mgr |
| `ceph fs status` | CephFS 的 active MDS 在哪一台；在 node10 的話，演練時也會看到 MDS 接手 |
| `ceph osd pool ls detail` | 每個 pool 的 `size`／`min_size`；應該都是 3／2，兩台在就能繼續讀寫 |
| `mon_osd_down_out_interval` | down 多久後標成 out，預設 600 秒 |
| `grep -A6 '^rbd: VM_Pool'` | 找出 PVE 的 VM_Pool 對應的 **Ceph pool 名稱**（`pool` 那一行），第 7 節要用 |
| `list-timers` | 確認 node11、node12 的三支外部檢查都有排程 |
| `cat /var/lib/graylog-health/status` | Graylog 外部檢查目前的狀態，應為 `OK` |

**應該看到**：

- [ ] `Quorate: Yes`、3 票
- [ ] 13 個 HA 資源都是 `started`，分布和第 3-2 節一致（不一致就先照 [HA 文件](https://kbwangtw.github.io/IT-Knowledge-Base/docs/pve/pve-ha-placement-policy/) 13-1 節搬好）
- [ ] DNS、DC 兩條規則 `in use`
- [ ] `HEALTH_OK`；97 個 PG 都是 `active+clean`（`scrubbing+deep` 也可以）
- [ ] 每個 pool `size 3`、`min_size 2`
- [ ] 三台備份程序數都是 0
- [ ] node11、node12 三支檢查都有排程，Graylog 狀態 `OK`

**任何一項不符就不要演練**，先處理既有問題。另外記下 MON leader、active mgr、active MDS 在哪台，填進第 12 節。

## 7. 步驟二：開好四個量測視窗（node11，tmux）

**做什麼**：在 node11 開一個 tmux，四個視窗各記錄一件事，每一行都帶時間。拔電前全部開好、確認有在跑。

```bash
tmux new -s drill
```

tmux 開新視窗：`Ctrl-b` 再按 `c`；切換視窗：`Ctrl-b` 再按 `0`～`3`；SSH 斷線後 `tmux attach -t drill` 接回。

### 7-1 視窗 0：HA 狀態（有變化才記）

```bash
D=/root/drill-$(date +%Y%m%d); prev=""
while true; do
  cur=$(ha-manager status 2>&1 | sed -E 's/, [A-Z][a-z]{2} [A-Z][a-z]{2} +[0-9]+ [0-9:]+ [0-9]{4}//')
  if [ "$cur" != "$prev" ]; then
    { echo "=== $(date '+%F %T')"; echo "$cur"; } | tee -a $D/ha.log
    prev=$cur
  fi
  sleep 2
done
```

| 片段 | 意思 |
| --- | --- |
| `sed -E 's/, 星期 月 日 時間 年//'` | 去掉 `master`、`lrm` 那幾行每隔幾秒就更新的時間，否則每次都會被當成「有變化」 |
| `[ "$cur" != "$prev" ]` | 每 2 秒查一次，**有變化才記**，紀錄不會太長 |
| `tee -a` | 畫面上看得到，也附加到 `ha.log` |

**應該看到**：一開始印一次完整狀態，之後靜止不動，直到 T0。

### 7-2 視窗 1：Ceph 事件

```bash
D=/root/drill-$(date +%Y%m%d)
ceph -w 2>&1 | tee -a $D/ceph-w.log
```

`ceph -w` 會持續印出叢集事件（每行自帶時間），例如 `osd.0 ... failed`、`mon.node10 ... calling monitor election`、`Health check failed`。

### 7-3 視窗 2：Ceph 讀寫卡住幾秒

**做什麼**：建一個 1 GiB 的測試磁碟，用 `rbd bench` 持續寫小資料，每秒印一次寫了幾筆。T0 之後**哪幾秒寫不進去**，就是 Ceph I/O 卡住的時間。

```bash
D=/root/drill-$(date +%Y%m%d)
POOL=<第 6 節查到的 Ceph pool 名稱>
rbd create $POOL/drill-iotest --size 1G
rbd bench --io-type write --io-size 4K --io-threads 1 --io-pattern rand --io-total 100G $POOL/drill-iotest 2>&1 |
  while IFS= read -r l; do echo "$(date '+%T') $l"; done | tee -a $D/rbd-bench.log
```

| 片段 | 意思 |
| --- | --- |
| `rbd create … --size 1G` | 建一個 1 GiB 的測試磁碟（不屬於任何 VM），演練後刪除 |
| `--io-size 4K --io-threads 1` | 一次寫一筆 4 KB，同時只有一筆，負載很輕 |
| `--io-pattern rand` | 隨機位置寫入，會分散到很多 PG，其中約三分之一的主副本在 osd.0 |
| `--io-total 100G` | 總量設很大，讓它一直跑；演練結束按 `Ctrl-C` 停 |
| `while IFS= read -r l; do echo "$(date '+%T') $l"; done` | 每收到一行就在前面加上當下時間，方便對照 T0 |

**應該看到**：每秒一行 `SEC OPS OPS/SEC BYTES/SEC`，`OPS/SEC` 穩定（數百筆左右）。T0 之後如果某幾秒**沒有新的一行**或 `OPS/SEC` 掉到接近 0，就是卡住。

### 7-4 視窗 3：node10 上的服務什麼時候回來

**做什麼**：每 5 秒從 node11 檢查一次 node10 上四個服務，看它們何時在別台恢復。IP 用演練當下 `pct config`／`qm config` 查到的值填入（服務搬家 IP 不變）。

```bash
D=/root/drill-$(date +%Y%m%d)
GL=<Graylog IP>; GF=<Grafana IP>; DC=<DC01 IP>; AI=<ai IP>
while true; do
  gl=$(curl -s -m 3 http://$GL:9000/api/system/lbstatus); gl=${gl:-DOWN}
  gf=$(curl -s -m 3 -o /dev/null -w '%{http_code}' http://$GF:3000/api/health)
  dc=$(timeout 3 bash -c "</dev/tcp/$DC/389" 2>/dev/null && echo up || echo down)
  ai=$(ping -c1 -W1 $AI >/dev/null 2>&1 && echo up || echo down)
  echo "$(date '+%T') graylog=$gl grafana=$gf dc01_ldap=$dc ai=$ai"
  sleep 5
done | tee -a $D/svc.log
```

| 片段 | 意思 |
| --- | --- |
| `curl … lbstatus` | Graylog 健康端點，正常是 `ALIVE`；沒回應記成 `DOWN` |
| `-w '%{http_code}'` | Grafana 健康檢查的 HTTP 狀態碼，正常是 `200`，沒回應是 `000` |
| `</dev/tcp/$DC/389` | bash 內建的 TCP 連線測試：DC01 的 LDAP 389 埠能不能連 |
| `ping -c1 -W1` | ai 容器有沒有回應 |

**應該看到**：每 5 秒一行，四項都是 `ALIVE`／`200`／`up`／`up`。

## 8. 步驟三：拔電（T0）

**做什麼**：讓 node10 突然消失，並準確記下時間。

1. 四個視窗都在跑，畫面上的數字都正常。
2. 在 node11 另開一個 SSH（或 tmux 第 5 個視窗），準備好這一行，**先不要按 Enter**：

   ```bash
   echo "T0 $(date '+%F %T') node10 斷電" >> /root/drill-$(date +%Y%m%d)/marks.log
   ```

3. 一手按 Enter、一手**長按 node10 電源鍵 4～5 秒**直到燈熄。（接了 UPS，所以是按電源鍵，不是拔 UPS 的插頭。）
4. 開始計時，**接下來 15 分鐘不要碰 node10**，讓 osd.0 被標成 out（第 2 節的 T0+10 分）。

## 9. 步驟四：觀察（T0～T0+15 分）

**做什麼**：盯著四個視窗和手機，把關鍵時間記到第 12 節的表裡。不用手動下任何修復指令。

| 看哪裡 | 看什麼 | 記下 |
| --- | --- | --- |
| 視窗 2（rbd bench） | 從哪一秒開始沒有新行或 `OPS/SEC` 接近 0、哪一秒恢復 | I/O 卡住的秒數 |
| 視窗 1（ceph -w） | `mon.node10` 離開、新 leader；`osd.0` 被標 down 的時間；10 分鐘後 `osd.0` 被標 out | 各事件時間 |
| 視窗 0（HA） | node10 的 `lrm` 變成 `old timestamp`／`unknown`；服務出現 `fence`、`recovery`；最後在哪台 `started` | 每個服務重新 `started` 的時間與節點 |
| 視窗 3（服務） | 四個服務各在幾點恢復 `ALIVE`／`200`／`up` | 使用者感受到的中斷時間 |
| 手機 | 每封告警信的主旨、寄件主機、收信時間 | 對照第 4 節的預期 |

**預期**：

- Ceph 狀態 `HEALTH_WARN`：`1 osds down`、`1/3 mons down`、PG `degraded`／`undersized`。**這是正常的**，兩台在、`min_size 2`，讀寫會繼續。
- HA 會遵守規則：DC01 不能去 node12（DC02 在那），所以應該落在 node11。
- 中途在 node11 下 `ceph` 指令偶爾卡幾秒，是 MON 在選舉，等一下就好。

## 10. 步驟五：開機、等叢集恢復

**做什麼**：讓 node10 回來，量 Ceph 回到 `HEALTH_OK` 要多久。

1. 記下時間，按 node10 電源鍵開機：

   ```bash
   echo "T1 $(date '+%F %T') node10 開機" >> /root/drill-$(date +%Y%m%d)/marks.log
   ```

2. 在 node11 等它回來（只讀取）：

   ```bash
   watch -n 5 'pvecm status | grep -E "Quorate|Total votes"; ceph -s | grep -E "health|mon:|osd:|pgs:"; ceph pg stat'
   ```

   | 片段 | 意思 |
   | --- | --- |
   | `watch -n 5 '…'` | 每 5 秒重跑一次，畫面原地更新；`Ctrl-C` 離開 |
   | `Total votes` | 回到 3 代表 node10 已重新加入 corosync |

3. 確認 node10 能登入（內網電腦 SSH，或在 node11 `ssh root@node10 hostname`）。**進不去就改用本機主控台**，看 `systemctl status pve-cluster`。

**應該看到**（依序）：

- [ ] `Total votes: 3`、`Quorate: Yes`
- [ ] `mon: 3 daemons, quorum node10,node11,node12`
- [ ] `osd: 3 osds: 3 up, 3 in`（osd.0 被標 out 過，開機後會自動標回 in）
- [ ] PG 從 `degraded`／`recovering` 回到 97 個 `active+clean`
- [ ] `HEALTH_OK`
- [ ] `ha-manager status` 中 `lrm node10` 是 `active`；服務**仍在 node11／node12**（CRS static 不會自動搬回）

## 11. 步驟六：收尾

### 11-1 停止量測、刪除測試磁碟

1. 視窗 0～3 依序按 `Ctrl-C`。
2. 刪除測試磁碟並確認：

   ```bash
   POOL=<同第 7-3 節>
   rbd rm $POOL/drill-iotest
   rbd ls $POOL | grep -c drill-iotest      # 應為 0
   ```

### 11-2 把服務搬回演練前的位置

用 HA 文件 13-1 節的 `mig` 函式，改成可以搬 VM（參數改成完整的 `ct:`／`vm:` 名稱）：

```bash
mig() {
  sid=$1; target=$2; t0=$(date +%s)
  echo "$(date '+%F %T') 開始：$sid → $target"
  ha-manager migrate $sid $target || { echo "⚠️ migrate 指令失敗"; return 1; }
  for i in $(seq 1 100); do
    sleep 3
    if ha-manager status | grep -q "$sid ($target, started)"; then
      echo "✅ $(date '+%F %T') $sid 已在 $target 啟動，耗時 $(( $(date +%s) - t0 )) 秒"; return 0
    fi
  done
  echo "⚠️ $sid 5 分鐘內沒有完成，目前狀態："; ha-manager status | grep "$sid"; return 1
}
mig ct:114 node10     # Grafana
mig vm:106 node10     # DC01：VM 會線上遷移，不用關機
mig ct:105 node10     # Graylog：漏收 1～3 分鐘日誌
mig ct:113 node10     # ai（Lab Ops）：最後搬，會斷線
```

一次貼一行，看到 ✅ 再貼下一行。搬完用 `ha-manager status | grep -E '^service' | sort -t'(' -k2` 對照第 3-2 節的分布。

Lab Ops 重開後若顯示 `Session creation failed`，見[叢集關機與開機](https://kbwangtw.github.io/IT-Knowledge-Base/docs/pve/pve-cluster-full-shutdown/)第 10 節：只對 `claude` 那個程序 `kill <PID>`。

### 11-3 從紀錄整理出數字

```bash
cd /root/drill-$(date +%Y%m%d)
cat marks.log
grep -nE 'mon\.node10|election|osd\.0|Health check|HEALTH_OK' ceph-w.log | head -40
awk '{ split($1,t,":"); s=t[1]*3600+t[2]*60+t[3]; if (p && s-p>2) print "空白", s-p, "秒：", prev, "→", $1; p=s; prev=$1 }' rbd-bench.log
grep -E '^===|node10|fence|recovery' ha.log | head -60
grep -vE 'graylog=ALIVE grafana=200 dc01_ldap=up ai=up' svc.log | head -60
```

| 片段 | 意思 |
| --- | --- |
| `grep … ceph-w.log` | 挑出 MON 選舉、osd.0、健康狀態變化的事件 |
| `awk '{ split($1,t,":") … }'` | 把每行開頭的時間換成秒數，找出**相鄰兩行差超過 2 秒**的地方，就是 I/O 卡住的區間 |
| `grep … ha.log` | HA 狀態變化的時間點 |
| `grep -v '…全部正常…' svc.log` | 只列出「有服務不正常」的那幾行，第一行與最後一行就是中斷的起點與終點 |

最後把 `/root/drill-日期/` 打包留存（只在節點上，不放進 Git），數字填進第 12 節。

## 12. 記錄表（演練時填）

**演練前狀態**：

| 項目 | 值 |
| --- | --- |
| 演練日期 | （待填） |
| MON leader／active mgr／active MDS | （待填） |
| HA 分布 | （待填，應同第 3-2 節） |
| T0（斷電）／T1（開機） | （待填） |

**Ceph**：

| 項目 | 預期（推測） | 實測 |
| --- | --- | --- |
| MON 選出新 leader | T0+數秒 | （待填） |
| mgr 接手 | T0+數秒～數十秒 | （待填） |
| osd.0 被標 down | T0+約 20～30 秒 | （待填） |
| rbd bench 寫不進去的秒數 | 十幾到數十秒 | （待填） |
| osd.0 被標 out | T0+約 10 分 | （待填） |
| 開機後回到 `HEALTH_OK` | 數分鐘 | （待填） |

**HA**（下指令時間都以 T0 為準）：

| 服務 | 原本 | 預期去哪 | 實際去哪 | `started` 時間 | 服務真的可用（視窗 3） |
| --- | --- | --- | --- | --- | --- |
| Graylog(105) | node10 | node11 或 node12 | | | |
| ai(113) | node10 | node11 或 node12 | | | |
| Grafana(114) | node10 | node11 或 node12 | | | |
| DC01(vm:106) | node10 | **node11**（DC 規則） | | | |

**告警信**：

| 告警 | 預期（第 4 節） | 收到幾封 | 收信時間 | 寄件主機 |
| --- | --- | --- | --- | --- |
| PVE Corosync 成員離線 | 收不到 | | | |
| Ceph 健康警告 | T0 附近收不到 | | | |
| PVE Node 狀態離線 | T0+4～6 分 | | | |
| 【Graylog 異常】／【已恢復】 | 0～2 封 | | | |
| 【NAS 連不上】 | 不應該寄 | | | |
| PVE fencing 通知 | 未確認 | | | |
| 其他 | — | | | |

**收尾**：

| 項目 | 結果 |
| --- | --- |
| 測試磁碟 `drill-iotest` 已刪除 | （待填） |
| 服務搬回原位、各自耗時 | （待填） |
| 當晚備份、隔天 08:30【備份檢查】 | （待填） |

## 13. 常見問題

| 現象 | 怎麼辦 |
| --- | --- |
| node10 開機後 SSH 進不去（金鑰被拒） | `/etc/pve` 可能沒掛起來，`authorized_keys` 連結指向不存在的檔案；接螢幕鍵盤用 root 密碼登入，看 `systemctl status pve-cluster corosync` |
| 拔電後在 node11 下 `ceph` 指令卡住幾秒 | MON 正在重新選 leader；等一下，不要重複下指令或 Ctrl-C 後狂按 |
| `ceph -s` 顯示 `HEALTH_WARN`、PG degraded | 一台不在時的正常狀態；`min_size 2`，讀寫照常 |
| 視窗 2 沒有任何輸出 | 先不接後面的 `while` 迴圈，單獨跑 `rbd bench` 看有沒有在寫；有的話是輸出被緩衝，改用 `stdbuf -oL rbd bench …` |
| HA 服務停在 `fence` 很久 | HA 在等確認 node10 真的停了；斷電的情況下應該幾分鐘內進入 `recovery`。超過 10 分鐘把 `ha.log` 和 `journalctl -u pve-ha-crm` 留下來 |
| 開機後有 HA 服務進入 `error` | 見 [PVE 更新重開後 HA 服務卡在 error](https://kbwangtw.github.io/IT-Knowledge-Base/docs/pve/pve-ha-service-error-after-reboot/) |
| 開機後服務沒有回到 node10 | 正常，CRS static 不會自動搬回；照第 11-2 節手動搬 |
| Graylog 裡演練那段時間的日誌有缺口 | UDP syslog 在 Graylog 停機時遺失，屬預期；本來就是這次要確認的盲點 |
| 開機後 Lab Ops 顯示 `Session creation failed` | 見第 11-2 節 |

## 14. 待辦

- [ ] 決定演練日期，前一週完成第 5 節準備
- [ ] 執行演練，填入第 12 節，更新「一句話」與總覽結論
- [ ] 把結果回寫 [HA 文件](https://kbwangtw.github.io/IT-Knowledge-Base/docs/pve/pve-ha-placement-policy/)第 15 節、[Graylog 告警（二）](https://kbwangtw.github.io/IT-Knowledge-Base/docs/pve/graylog-alerts-monitoring/)第 11 節
- [ ] 依第 4 節實際收到的信，評估要不要補告警（例如 Graylog 停機期間遺失的 corosync／Ceph 事件）
- [ ] 第二次演練：拔 Cluster 線，驗證 fencing（第 3-1 節）
- [ ] 評估 vmbr0 斷線的偵測方式：節點還在 corosync 裡，HA 和 `pve-node-monitor.sh` 都不會反應（第 3-1 節）
- [ ] corosync 增加第二條 link：已列在[內網橫向感染評估](https://kbwangtw.github.io/IT-Knowledge-Base/docs/network/internal-network-lateral-movement-assessment/)待辦

## 15. 延伸閱讀

- [PVE HA 放置策略](https://kbwangtw.github.io/IT-Knowledge-Base/docs/pve/pve-ha-placement-policy/)：13-1 節是演練前的 HA 分布與 `mig` 函式
- [Graylog 告警與監控（二）](https://kbwangtw.github.io/IT-Knowledge-Base/docs/pve/graylog-alerts-monitoring/)：三條寄信路徑、節點監控腳本、Graylog 外部檢查
- [PVE 重開後 Ceph 又故障：修正 BlueStore 裡的 OSD 金鑰](https://kbwangtw.github.io/IT-Knowledge-Base/docs/pve/ceph-bluestore-osd-key-recovery-2026-09-22/)：更新／重開機檢查清單
- [叢集關機與開機](https://kbwangtw.github.io/IT-Knowledge-Base/docs/pve/pve-cluster-full-shutdown/)：整叢集計畫性關機的做法（和本篇的「突然消失」相對）
- [Proxmox VE：HA 的 fencing](https://pve.proxmox.com/pve-docs/chapter-ha-manager.html#ha_manager_fencing)
- [Proxmox VE：Corosync 備援 link](https://pve.proxmox.com/pve-docs/chapter-pvecm.html#pvecm_redundancy)
- [Ceph：Monitor／OSD 心跳與 down／out 設定](https://docs.ceph.com/en/latest/rados/configuration/mon-osd-interaction/)
- [Ceph：rbd bench](https://docs.ceph.com/en/latest/man/8/rbd/)
