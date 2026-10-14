---
layout: default
title: "GCP 網站主機磁碟 100%：清 log 之後，又查出四個問題"
permalink: /docs/gcp/gce-disk-full-log-cleanup-2026-10-05/
date: 2026-10-05
categories: [GCP, Debian, Logging, Security, Cloudflare]
last_modified_at: 2026-10-14
---

# GCP 網站主機磁碟 100%：清 log 之後，又查出四個問題

一台 GCP 上的網站主機根目錄滿到 100%。原本只想清 log，結果一路查出四件事：PHP 每個請求都寫一行警告、Ops Agent 送不出 log 而越寫越多、主機上的 SSL 憑證已經過期將近一個月，還有防火牆對全世界開放。

**磁碟滿只是結果，要找的是「誰一直在寫」。清掉不查原因，幾個月後又會再滿。**

> 紀錄日期：2026-10-05。環境：GCE VM（15G 系統碟）、Debian 11、寶塔面板（Apache + PHP 7.4 + MariaDB）、Google Cloud Ops Agent 2.64.0，網站放在 Cloudflare 後面。文中的專案 ID、IP、網域與帳號都已替換成範例值。

## 結果先看

| 項目 | 處理前 | 處理後 | 驗證 |
| --- | --- | --- | --- |
| 磁碟使用率 | 100%（剩 102M） | 43%（剩 8.0G） | 已確認 |
| 網站 error log | 4.5G，同一行 PHP 警告 | 不再寫入 deprecated 訊息 | 已確認 2 分鐘內維持 0 bytes |
| 網站 log 輪替 | 無 | logrotate：每天、保留 14 份、200M 提早輪替 | 模擬執行無錯誤；首次實際輪替待隔天確認 |
| systemd journal | 873M | 上限 200M、保留 1 個月 | 已確認 96M |
| Ops Agent | 403，log 送不出去 | 補上 IAM 角色 | 重啟後 log 只有 info；Logs Explorer 測試訊息待確認 |
| 主機 SSL 憑證 | Let's Encrypt，9/8 已過期 | Cloudflare Origin Certificate，到 2041 年 | 已確認；10/14 確認 Cloudflare 為「完整（嚴格）」 |
| 磁碟快照 | 以為沒有 | 早就有 `default-schedule-1`：每天一份、保留 14 天 | 已確認 14 份快照都是 READY |
| 資料庫備份 | 從來沒有 | 寶塔計畫任務：每天 14:00 UTC、保留 7 份 | 已確認備份檔完整（9 個 table、Dump completed） |
| access log 暴增 | 每分鐘約 3,500 筆，爬蟲陷阱 | 連結拿掉 `time()`；Cloudflare 只質詢舊格式網址 | 已確認每分鐘 7 筆，真人不被質詢 |
| KindEditor 上傳 API | 未登入可瀏覽、上傳 | Cloudflare 封鎖 `/cms/plugin/kindeditor/php/` | 已確認回 403；未發現入侵跡象 |
| GCP 防火牆 | RDP、SSH、面板、80/443 全部對全世界開放 | RDP 刪除；SSH、面板限定來源；80/443 只允許 Cloudflare | 直連逾時、經 Cloudflare 回 200；10/14 確認面板與新 SSH 連線可登入 |

## 1. 先看空間被誰吃掉

~~~bash
df -h /
sudo du -sh /var/log/* | sort -h | tail -15
sudo journalctl --disk-usage
~~~

當時 `/var/log` 加起來只有約 1.7G：

| 位置 | 大小 |
| --- | --- |
| /var/log/journal | 873M |
| /var/log/google-cloud-ops-agent | 790M |
| 其他 log | 約 20M |

但根目錄用了 14G。**log 只是一部分，另外 12G 在別處。**先用 journal 救急，再往外找：

~~~bash
sudo journalctl --vacuum-size=100M
sudo du -xh --max-depth=1 / 2>/dev/null | sort -h | tail -15
~~~

`du` 的結果顯示 `/www` 有 8.0G。`/www`、`/.Recycle_bin`、`/patch` 這組目錄是寶塔面板的典型結構。

## 2. Ops Agent：一直被拒絕，失敗訊息越寫越多

先看 Ops Agent 的 log 裡哪一種錯誤最多：

~~~bash
F=/var/log/google-cloud-ops-agent/subagents/logging-module.log
sudo grep -E "\[ ?(error|warn)\]" $F | cut -d']' -f2- | sort | uniq -c | sort -rn | head -10
~~~

最多的是：

~~~text
[ warn] [http_client] cannot increase buffer: current=4192 requested=36960 max=4192
[ warn] [output:stackdriver:stackdriver.1] http_do=-1
[ warn] [output:stackdriver:stackdriver.1] tag=ops-agent-fluent-bit error sending to Cloud Logging: {
~~~

錯誤內容是多行 JSON，grep 只抓到第一行的 `{`。要用 `-A` 把後面幾行一起印出來，才看得到真正的原因：

~~~bash
sudo grep -A 15 "error sending to Cloud Logging" $F | tail -40
~~~

~~~text
"code": 403,
"message": "Permission 'logging.logEntries.create' denied on resource ...",
"reason": "IAM_PERMISSION_DENIED",
~~~

這是一個惡性循環：送 log 被拒絕 → 失敗訊息寫進 Agent 自己的 log → 這份 log 也要上傳 → 又失敗 → 再寫一筆。

### scope 和 IAM 是兩道門

VM 要寫 Cloud Logging，兩道門都要開：

| 關卡 | 查法 | 本案 |
| --- | --- | --- |
| Access scope（VM 層級的上限） | metadata 的 scopes | 有 `logging.write` |
| IAM 角色（service account 的實際權限） | 錯誤訊息的 reason | 缺少，`IAM_PERMISSION_DENIED` |

~~~bash
curl -s -H "Metadata-Flavor: Google" \
  http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/email; echo
curl -s -H "Metadata-Flavor: Google" \
  http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/scopes; echo
~~~

新的 GCP 專案不一定會自動給預設 compute service account Editor 角色，所以要手動補。補完後的 IAM 清單也證實，這個 service account 原本沒有任何專案角色。

### 補 IAM 要在 Cloud Shell 做，不是在 VM 上

在 VM 上執行 `gcloud`，用的是 VM 自己的 service account，它沒有權限改 IAM，會出現 `ACCESS_TOKEN_SCOPE_INSUFFICIENT`。錯誤訊息建議「更新 VM 的 access scopes」，**不要照做**：給 VM 改 IAM 的能力，網站一旦被入侵，整個專案就會被接管。

改用專案 Owner 帳號，在 Cloud Shell 執行：

~~~bash
gcloud projects add-iam-policy-binding <PROJECT_ID> \
  --member="serviceAccount:<PROJECT_NUMBER>-compute@developer.gserviceaccount.com" \
  --role="roles/logging.logWriter" --condition=None

gcloud projects add-iam-policy-binding <PROJECT_ID> \
  --member="serviceAccount:<PROJECT_NUMBER>-compute@developer.gserviceaccount.com" \
  --role="roles/monitoring.metricWriter" --condition=None
~~~

回到 VM 重啟並確認：

~~~bash
sudo systemctl restart google-cloud-ops-agent
sudo tail -20 /var/log/google-cloud-ops-agent/subagents/logging-module.log
~~~

重啟後只有 `[ info]` 的 worker started 與 inotify 訊息，沒有新的 warn。確認後清空舊 log：

~~~bash
sudo truncate -s 0 /var/log/google-cloud-ops-agent/subagents/logging-module.log
~~~

另外有 4 個 7 月產生的 buffer chunk 出現 `format check failed`，停止 Agent 後刪除：

~~~bash
sudo systemctl stop google-cloud-ops-agent
sudo find /var/lib/google-cloud-ops-agent/fluent-bit/buffers -name "<chunk 檔名樣式>" -ls
sudo find /var/lib/google-cloud-ops-agent/fluent-bit/buffers -name "<chunk 檔名樣式>" -delete
sudo systemctl start google-cloud-ops-agent
~~~

**待確認**：用 `logger "ops-agent-test-$(date +%s)"` 送一筆測試訊息，到 Logs Explorer 搜得到，才算端到端完成。

## 3. 真正的主因：4.5G 的 PHP 警告

~~~bash
sudo ls -lhS /www/wwwlogs | head -15
~~~

| 檔案 | 大小 |
| --- | --- |
| example.com-error_log | 4.5G |
| example.com-access_log | 2.0G |

網站本體只有 141M，log 是它的 45 倍。統計 error log 裡最常見的訊息（先去掉每行開頭的時間、pid、client 欄位）：

~~~bash
F=/www/wwwlogs/example.com-error_log
sudo tail -n 200000 $F | sed -E 's/^(\[[^]]*\] *)+//' | cut -c1-150 | sort | uniq -c | sort -rn | head -10
sudo head -1 $F | cut -c1-40
~~~

| 次數（最後 20 萬行） | 內容 |
| --- | --- |
| 199,953（99.98%） | `PHP Deprecated: Methods with the same name as their class will not be constructors...; DB has a deprecated constructor` |
| 18 | `include(cms3/db/closedb.php): failed to open stream` |
| 數筆 | `(28)No space left on device`（9/27 磁碟寫滿） |

這份 log 從 3/3 開始累積，7 個月長到 4.5G。

### 這行警告是什麼意思？

網站程式的 `DB` class 用的是 PHP 4 的寫法：用跟 class 同名的 function 當 constructor。

~~~php
class DB {
    function DB() {        // 舊寫法：function 名稱和 class 相同
        // 連線資料庫...
    }
}
~~~

PHP 7 把它標成 deprecated。每個請求都會建立一次 DB 物件，所以每個請求都寫一行。

**PHP 8 已經移除這種寫法。**到了 PHP 8，`DB()` 只是一個普通 function，不會在建立物件時執行，資料庫就不會連線。所以這台在修好程式之前，不能直接升級 PHP 8。

### 先止血：不記錄 deprecated

原本的設定是 `E_ALL & ~E_NOTICE`。要**保留原有的排除項目**再加上 deprecated；如果整行換成 `E_ALL & ~E_DEPRECATED`，等於把 notice 重新打開，舊程式的 notice 可能又把 log 灌滿。

~~~bash
INI=/www/server/php/74/etc/php.ini
sudo cp $INI $INI.bak-$(date +%F)
sudo sed -i 's/^error_reporting = E_ALL & ~E_NOTICE$/error_reporting = E_ALL \& ~E_NOTICE \& ~E_DEPRECATED \& ~E_STRICT/' $INI
sudo grep -n "^error_reporting" $INI
sudo /etc/init.d/php-fpm-74 reload
~~~

這只是不記錄，程式本身還沒改。

### 留樣本再清空

Apache 還開著這兩個檔案，要用 `truncate`，不能用 `rm`；用 `rm` 的話檔名消失了，空間卻不會釋放。

~~~bash
E=/www/wwwlogs/example.com-error_log
A=/www/wwwlogs/example.com-access_log

sudo tail -n 1000 $E | gzip | sudo tee /root/error_log-sample-$(date +%F).gz > /dev/null
sudo truncate -s 0 $E

sudo tail -n 200000 $A | gzip | sudo tee /root/access_log-recent-$(date +%F).gz > /dev/null
sudo truncate -s 0 $A

df -h /
~~~

使用率從 89% 降到 43%。2 分鐘後再看，error log 仍是 0 bytes，access log 恢復寫入，網站回 200。

## 4. 防止再滿：logrotate 與 journald

先確認寶塔沒有自己的「切割日誌」排程，避免兩套輪替互相干擾：

~~~bash
sudo crontab -l 2>/dev/null | grep -iE "log|cut"
~~~

本案只有一個排程，內容是 SSL 續簽（見下一節），不衝突。建立 `/etc/logrotate.d/wwwlogs`：

~~~bash
sudo tee /etc/logrotate.d/wwwlogs > /dev/null <<'EOF'
/www/wwwlogs/*.log /www/wwwlogs/*_log {
    su www www
    daily
    rotate 14
    maxsize 200M
    compress
    delaycompress
    missingok
    notifempty
    copytruncate
}
EOF

sudo logrotate -d /etc/logrotate.d/wwwlogs
~~~

| 參數 | 作用 |
| --- | --- |
| `su www www` | 目錄擁有者是 www，用它的身分輪替 |
| `daily` + `rotate 14` | 每天一次，保留 14 份 |
| `maxsize 200M` | 不到一天但超過 200M 也會輪替 |
| `copytruncate` | 先複製再清空，Apache 不必 reload；複製的瞬間可能漏幾行 |

模擬結果沒有 error。輸出的 `log has already been rotated` 是因為 logrotate 第一次看到檔案時，把當天記成上次輪替日，第一次實際輪替會在隔天。`maxsize` 也是在 logrotate 執行時才檢查，Debian 預設一天一次。

journald 用 drop-in 設定上限：

~~~bash
sudo mkdir -p /etc/systemd/journald.conf.d
sudo tee /etc/systemd/journald.conf.d/size.conf > /dev/null <<'EOF'
[Journal]
SystemMaxUse=200M
MaxRetentionSec=1month
EOF
sudo systemctl restart systemd-journald
journalctl --disk-usage
~~~

## 5. 順便查出：主機憑證已過期，續簽每天「Successful」

寶塔唯一的排程是 Let's Encrypt 續簽，執行紀錄每天都寫 `Successful`，內容卻是：

~~~text
存在泛域名，只能用dns验证方式续签！
未绑定dns-api，跳过域名：*.example.com!
域名全部未绑定dns-api，无法使用dns验证续签！
★[2026-10-04 17:30:02] Successful
~~~

萬用字元憑證只能用 DNS 驗證，沒有設定 DNS API 就每天跳過。`Successful` 只代表腳本跑完。

~~~bash
echo | openssl s_client -connect 127.0.0.1:443 -servername example.com 2>/dev/null \
  | openssl x509 -noout -subject -issuer -dates
~~~

憑證 6/10 申請、9/8 到期，已經過期將近一個月。網站還能開，是因為 Cloudflare 的加密模式是「完整」，有加密但不檢查主機憑證：

| Cloudflare 模式 | 主機憑證過期時 |
| --- | --- |
| 完整（Full） | 仍可連線，但 Cloudflare 不驗證主機身分 |
| 完整（嚴格）（Full strict） | 顯示 526 錯誤 |

### 改用 Cloudflare Origin Certificate

網站兩筆 A 紀錄都是橘色雲朵（已代理），MX、TXT 是僅 DNS，換成只有 Cloudflare 信任的 Origin Certificate 不會影響訪客。

1. Cloudflare：SSL/TLS → 原始伺服器 → 建立憑證（RSA 2048、15 年、PEM）。
2. 寶塔：網站 → 設定 → SSL → 貼上私密金鑰與憑證 → 保存。私密金鑰只顯示一次，直接從 Cloudflare 複製到寶塔，不經過聊天、記事本或文件。
3. VM 上用上面的 `openssl` 指令確認：issuer 是 CloudFlare Origin SSL Certificate Authority，notAfter 是 2041 年。
4. Cloudflare 加密模式改成「完整（嚴格）」，連測幾次網站回 200。

**待確認**：Cloudflare 概觀頁顯示「完整（嚴格）」（curl 回 200 在「完整」模式下也會成立，不能當證據）；寶塔續簽排程改為停用；開啟「一律使用 HTTPS」（當時 24 小時內有 474 個明文 HTTP 請求）。

> 10/14：「完整（嚴格）」已在 Cloudflare 概觀頁確認，續簽任務已停用。「一律使用 HTTPS」其實原本就已開啟：
>
> ~~~bash
> curl -sI http://example.com | head -1                                   # HTTP/1.1 301 Moved Permanently
> curl -sI "http://example.com/product.php?pid=2" | grep -i "^location"   # https://example.com/product.php?pid=2
> ~~~
>
> 當初從「24 小時有 474 個明文 HTTP 請求」推論它沒開，這個推論不成立：開關打開時，訪客的 `http://` 請求一樣會先到 Cloudflare，只是每個都回 301。光看請求數分不出來，要看回應。HSTS 先不開：瀏覽器會記住好幾個月，HTTPS 一旦出問題就無法從伺服器端救回。

## 6. 防火牆：只開必要的來源

原本的 GCP 防火牆：

| 規則 | 來源 | 問題 |
| --- | --- | --- |
| default-allow-rdp（3389） | 0.0.0.0/0 | Linux 用不到 |
| default-allow-ssh（22） | 0.0.0.0/0 | btmp 有 1.6M 的失敗登入 |
| 寶塔面板（自訂 port） | 0.0.0.0/0 | 管理後台對外，而且面板很久沒更新 |
| default-allow-http/https | 0.0.0.0/0 | 知道主機 IP 就能繞過 Cloudflare |

修改前先確認專案只有這一台 VM，因為 `default-*` 規則會套用到整個 VPC：

~~~bash
gcloud compute instances list --format="table(name,zone.basename(),status,tags.items.list())"
~~~

依風險由低到高修改，每一步都驗證。SSH 一定要保留 `35.235.240.0/20`：從 Console 開的瀏覽器 SSH 是從 Google IAP 這個網段連進來的，拿掉會把自己鎖在外面。

~~~bash
# 1. 刪除 RDP
gcloud compute firewall-rules delete default-allow-rdp --quiet

# 2. 80/443 只允許 Cloudflare（先確認 $CF 不是空的）
CF=$(curl -s https://www.cloudflare.com/ips-v4 | paste -sd, -)
echo "$CF"
gcloud compute firewall-rules update default-allow-http  --source-ranges="$CF"
gcloud compute firewall-rules update default-allow-https --source-ranges="$CF"

# 3. 面板只允許管理者 IP
gcloud compute firewall-rules update <面板規則名稱> --source-ranges=<管理者IP>/32

# 4. SSH 只允許管理者 IP 和 IAP
gcloud compute firewall-rules update default-allow-ssh \
  --source-ranges=<管理者IP>/32,35.235.240.0/20
~~~

驗證：

~~~bash
curl -sS -o /dev/null -m 8 -w "direct HTTP=%{http_code}\n" -k https://<VM外部IP>; echo "exit=$?"
curl -sS -o /dev/null -m 10 -w "via CF HTTP=%{http_code}\n" https://example.com
~~~

直連 `exit=28`（逾時），經 Cloudflare `HTTP=200`。

**待確認**：從管理者電腦登入面板；另開新的瀏覽器 SSH 視窗登入。Cloudflare 的 IP 清單偶爾會更新，網站若突然出現 522，重新執行第 2 步。

> 10/14：面板從管理者電腦可登入，新開的瀏覽器 SSH 視窗可登入。

## 7. 備份：快照排程早就有了（2026-10-14 補記）

原本以為這台沒有備份，查了才發現建立 VM 時，Console 已經自動建立並套用了 `default-schedule-1`。不過「有排程」不等於「有備份」（第 5 節的續簽排程就是反例），所以排程規則和實際產生的快照都要確認。以下指令都在 Cloud Shell 執行：

~~~bash
gcloud compute resource-policies describe default-schedule-1 --region=<REGION> \
  --format="yaml(snapshotSchedulePolicy)"
gcloud compute snapshots list --filter="sourceDisk~<DISK>" \
  --format="table(name,status,storageBytes,creationTimestamp)" --sort-by=~creationTimestamp
~~~

| 項目 | 結果 | 判斷 |
| --- | --- | --- |
| `maxRetentionDays` | 14 | 被入侵好幾天才發現，也還有乾淨的版本 |
| `onSourceDiskDelete` | `KEEP_AUTO_SNAPSHOTS` | VM 設定是「刪除執行個體時刪除磁碟」，這項可以保證快照不會跟著消失 |
| `guestFlush` | false | crash-consistent，等同在那個瞬間直接拔電源 |
| 實際快照 | 9/30 到 10/13 每天一份，全部 `READY` | 已確認 |
| 實際拍攝時間 | 每天 14:20 UTC（台灣 22:20） | 名稱裡的時間戳記和 `creationTimestamp` 一致 |

快照是增量的：最舊的一份約 3.3 GB，其他每天 0.1 到 0.5 GB。10/5 清 log 那天約 0.9 GB，屬於合理範圍。**10/12 也有約 0.9 GB，原因還沒查。**

一顆磁碟同時只能套一個快照排程，所以不要再另外建立排程。

### 10/12 的 0.9 GB：每週一的 fstrim

查快照區間（10/11 14:20 到 10/12 14:20 UTC）內修改過的檔案，加總只有約 20 MB，網站目錄沒有變動，也沒有套件更新。`systemctl list-timers` 顯示 `fstrim.timer` 在 10/12 00:47 UTC 執行過；它每週一執行，10/5 也是週一。推測是 fstrim 讓快照多算了區塊，待 10/19 的快照驗證。

### 資料庫備份：目錄是空的

快照是 crash-consistent，對資料庫不保證一致，所以另外查了寶塔的資料庫備份。`/www/backup/database/mysql/all_backup` 從 3/2 建立後就是空的：**資料庫從來沒有備份過**。

在寶塔「計畫任務」新增一個任務：

| 欄位 | 設定 | 原因 |
| --- | --- | --- |
| 任務類型 | 備份資料庫，MySQL，所有 | |
| 執行週期 | 每天 14:00 | 伺服器是 UTC。比快照早 20 分鐘，每份快照裡都會有一份一致的資料庫備份 |
| 備份到 | 伺服器磁碟，`/www/backup` | 不傳到第三方雲端 |
| 保留最新 | 7 份 | |
| 進程鎖 | 開啟 | 上一次還沒跑完時不會重複執行 |

手動執行一次後，寶塔日誌只有「開始備份」，沒有結束訊息，所以要直接驗證檔案：

~~~bash
sudo find /www/backup/database -type f -mmin -30 -ls
F=<備份檔路徑>
sudo gzip -t $F && echo "gzip OK"
sudo zcat $F | grep -c "CREATE TABLE"
sudo zcat $F | tail -3
sudo sh -c 'ls /www/server/data/<DB>/*.frm | wc -l'
~~~

| 檢查 | 結果 |
| --- | --- |
| 壓縮檔 | 18 KB，`gzip OK` |
| 解壓後 | 約 100 KB |
| `CREATE TABLE` 數量 | 9，與 `.frm` 檔數量相同 |
| 結尾 | `-- Dump completed` |

`/www/server/data` 有 219 MB，但網站資料庫本身只有 724 KB，其餘是 MariaDB 自己的檔案，所以 18 KB 的備份是完整的。

## 8. access log 每天翻倍：網站自己做出的爬蟲陷阱（2026-10-14 補記）

清完 log 後，磁碟使用率 9 天內從 43% 升到 48%。logrotate 正常，問題出在 access log 本身：

| 日期 | 檔案 | 大小 |
| --- | --- | --- |
| 10/6 | `.8.gz` | 350K |
| 10/10 | `.4.gz` | 3.2M |
| 10/12 | `.2.gz` | 13M |
| 10/13 | `.1`（未壓縮） | 571M |
| 10/14 | 目前的 log | 1.5 小時就 67M |

`maxsize 200M` 只在 logrotate 每天執行時檢查，擋不住一天之內暴增的流量。

### 誰在打

~~~bash
L=/www/wwwlogs/example.com-access_log
sudo awk -F'"' '{print $6}' $L | sort | uniq -c | sort -rn | head -10
sudo awk '{print $7}' $L | cut -c1-80 | sort | uniq -c | sort -rn | head -10
~~~

1.5 小時內有 31 萬筆（每秒約 59 筆），User-Agent 幾乎全是「Mac OS X 10_15_7 + Chrome 116 到 146」，網址都是 `/product.php?<10 位數字>&pid=<1-9>`，而且每個網址只出現約 2 次。來源 IP 全是 Cloudflare，因為 Apache 沒有設定 `mod_remoteip`。Cloudflare 的分析顯示，24 小時內有 292 萬個請求，幾乎全部 Served by Origin，快取完全沒有命中。

### 那串數字是網站自己產生的

~~~bash
sudo grep -rn "product.php?" /www/wwwroot/example.com --include=*.php | head
~~~

~~~php
href="product.php?' . time() . '&pid=' . $main_sn[$i] . '"
~~~

選單（每一頁都有）和產品列表在產生連結時，都在網址裡放了 `time()`，也就是當下的 Unix 時間戳記。每抓一頁就會冒出 9 個從沒出現過的網址，爬蟲跟著抓，網址就無限增加，形成**爬蟲陷阱（crawler trap）**。這也解釋了為什麼流量是一階一階翻倍，以及為什麼快取永遠不會命中。

一開始以為正常的網址是 `product.php?pid=4`，差點寫出「不是 `pid=` 開頭就擋」的規則；查了正常日期（10/6）的 log，才發現正常連結本來就帶著數字，那條規則會擋到真人。

### 先止血：Cloudflare 自訂規則

網路安全 → 安全性規則 → 自訂規則：

~~~text
(http.request.uri.path eq "/product.php" and not cf.client.bot)
~~~

動作：受控的質詢（Managed Challenge）。`not cf.client.bot` 會放行 Google 這類 Cloudflare 驗證過的搜尋引擎機器人。真人通過一次質詢後，30 分鐘內不會再被質詢。

驗證（`<` 重新導向要寫成 `sudo wc -l $L`，原因見最後的「坑」表格）：

~~~bash
a=$(sudo wc -l $L | cut -d' ' -f1); sleep 60; b=$(sudo wc -l $L | cut -d' ' -f1); echo "每分鐘 $((b-a)) 筆"
sudo tail -n 3000 $L | grep "product.php" | awk '{print substr($4,14,5)}' | uniq -c | tail -15
~~~

| 時間（UTC） | `product.php` 每分鐘 |
| --- | --- |
| 部署前 | 約 3,500 |
| 01:46（規則傳播中） | 2,019 |
| 01:50 之後 | 4 到 12 |

無痕視窗開產品頁正常。Cloudflare 圖表上，Served by Origin 降到接近 0，Mitigated 每分鐘 4,000 到 5,000 筆：爬蟲沒有停，只是被擋在 Cloudflare 那一層。**這條規則在拆掉陷阱、而且爬蟲確定不再來之前，都不能停用。**

### 拆掉陷阱：連結拿掉 `time()`

改之前要先確認那串數字沒有被程式用到。`product.php` 本身沒有讀 `$_GET`，它 include 的 `product/*.php` 用的是 `$main_sn = $_GET['pid'];`，整個網站也沒有用到 `QUERY_STRING`，所以拿掉不影響功能。

~~~bash
S=/www/wwwroot/example.com
F="$S/menu/menu_list.php $S/product/small_main_img.php"

# 備份放在網站目錄外面：.bak 不會被當成 PHP 執行，Apache 會直接送出原始碼
B=/root/site-backup-$(date +%F)
sudo mkdir -p $B && sudo cp -a --parents $F $B/

# 先預覽（-n + p），確認後才用 -i 寫入
sudo sed -n "s/product\.php?' \. time() \. '&pid=/product.php?pid=/p" $F
sudo sed -i "s/product\.php?' \. time() \. '&pid=/product.php?pid=/" $F

sudo grep -n "product.php?" $F
for f in $F; do sudo /www/server/php/74/bin/php -l $f; done
ls -l $F
~~~

兩個檔案語法檢查都通過，擁有者仍是 `www`，大小各少 15 bytes，剛好是 `' . time() . '&` 的長度。瀏覽器上的連結變成 `product.php?pid=2`，頁面正常。

### 收緊規則：真人不再被質詢

~~~text
(http.request.uri.path eq "/product.php" and not starts_with(http.request.uri.query, "pid=") and not cf.client.bot)
~~~

| 測試（每次開新的無痕視窗） | 結果 |
| --- | --- |
| 從選單點產品 | 直接進入 |
| 手動輸入舊格式 `product.php?123&pid=2` | 出現質詢 |
| 點 Products 主選單 | 直接進入 |
| 主機每分鐘請求數 | 7 筆（處理前約 3,500） |

規則上線後約擋下 8.4 萬次請求，通過質詢的比例（CSR）為 0%，代表被擋下的都是機器人。

## 9. KindEditor：上傳 API 不用登入就能用（2026-10-14 補記）

查爬蟲時順便搜尋了讀取 `$_GET` 的程式，看到 CMS 裡附帶的 KindEditor 編輯器：`cms/plugin/kindeditor/php/upload_json.php` 和 `file_manager_json.php`。KindEditor 官方範例的 PHP 不檢查登入，舊版也有公開的上傳繞過手法。

先查有沒有被用過、有沒有被植入東西（全部唯讀）：

~~~bash
S=/www/wwwroot/example.com
K=$S/cms/plugin/kindeditor/php
sudo sh -c 'zgrep -h "kindeditor" /www/wwwlogs/example.com-access_log*'
sudo zgrep -c "kindeditor" /root/access_log-recent-2026-10-05.gz
sudo grep -n "session\|login" $K/upload_json.php $K/file_manager_json.php
curl -s https://example.com/cms/plugin/kindeditor/php/file_manager_json.php | head -c 300
sudo find $S -type f \( -name "*.php" -o -name "*.phtml" -o -name "*.php5" \) -mtime -90 -ls
sudo find $S -type d -name attached -exec sh -c 'find "$1" -name "*.php*" -ls' _ {} \;
~~~

| 檢查 | 結果 |
| --- | --- |
| log（10/5 以後與 10/5 的樣本） | 沒有存取紀錄 |
| 程式是否檢查登入 | 沒有 |
| 未登入打開檔案管理 | HTTP 200，回傳上傳目錄的 JSON 清單 |
| 90 天內新增或修改的 PHP | 只有第 8 節改的兩個檔案 |
| 上傳目錄裡的 PHP | 沒有 |

結論：沒有被入侵的跡象，但任何人都能瀏覽和上傳。

### 用 Cloudflare 封鎖

Apache 看不到訪客真實 IP，沒辦法只放行管理者；前台圖片放在 `/cms/main_category/images/`，也不能擋整個 `/cms/`。後台很少上傳圖片、管理者 IP 也不固定，所以直接封鎖整個目錄：

~~~text
(starts_with(http.request.uri.path, "/cms/plugin/kindeditor/php/"))
~~~

動作選「封鎖」，不是質詢：一般訪客用不到這個目錄，而人工攻擊可以通過質詢。

| 驗證 | 結果 |
| --- | --- |
| `file_manager_json.php`、`upload_json.php` | 都是 HTTP 403 |
| 主機 log 裡的 kindeditor | 維持部署前的 2 筆，部署後的請求沒有到達主機 |

需要上傳圖片時，到 Cloudflare 把 `kindeditor-block` 改成「已停用」，用完立刻改回「使用中」。

## 排查時踩到的坑

這幾個是指令本身的陷阱，結果看起來合理，其實是錯的：

| 情況 | 原因 | 正確做法 |
| --- | --- | --- |
| `sudo ls /www/wwwlogs/*.log` 顯示找不到檔案 | `*` 由自己的 shell 先展開，一般使用者讀不到該目錄 | `sudo sh -c 'ls /www/wwwlogs/*.log'` |
| `curl ... \| head; echo $?` 永遠是 0 | `$?` 是管線最後一個指令（head）的結束碼 | 不接管線，改用 `curl -sS -o /dev/null -w "%{http_code}"` |
| grep 多行 JSON 只抓到 `"reason"` 那行，看不到時間 | 只有第一行有時間戳記 | grep 有時間戳記的那行，例如 `error sending to Cloud Logging` |
| awk 比對 `$2 >= "05:29"` 找重啟後的錯誤 | 只比時間沒比日期，前幾天的訊息也會算進去 | 先清空 log 再觀察，或同時比對日期 |
| `sudo wc -l < $L` 顯示 Permission denied | `<` 由自己的 shell 先開檔，sudo 還沒執行 | `sudo wc -l $L`；`*`、`<`、`>`、`\|` 都是 sudo 之前處理的 |
| 看到有明文 HTTP 請求，就以為沒開「一律使用 HTTPS」 | 開啟後請求一樣會到 Cloudflare，只是回 301 | 用 `curl -sI http://...` 看狀態碼 |
| 以為 Apache 假死而重啟 | 被上面兩個錯誤結果誤導 | 先用不會騙人的指令確認，再動服務 |

## 還沒做完的事

> 2026-10-14 補記：這個網站**只能在 PHP 7.4 執行**，升級 PHP 不是選項。PHP 7.4 已停止官方安全更新，所以重點從「規劃升級」改為「在 7.4 上把外圍防護做緊」。

| 優先 | 項目 |
| --- | --- |
| 高 | 隔天確認 logrotate 第一次輪替、磁碟維持在 43% 左右 |
| 中 | 最後一個待確認：Logs Explorer 搜得到 Ops Agent 測試訊息 |
| 中 | 通知會用 CMS 後台的人：編輯器上傳已關閉，需要時聯絡管理者暫時開啟 |
| 中 | 檢查 `$_GET['pid']`、`$_GET['news']`、`$_GET['n']` 是否直接放進 SQL（SQL injection） |
| 中 | GCP Monitoring 設定磁碟使用率超過 80% 寄信 |
| 中 | 修正 `DB` 的 constructor（改成 `__construct()`，保留 `DB()` 呼叫它）。7.4 可以正常執行，改完就不必再關掉 `E_DEPRECATED` |
| 中 | 寶塔資料庫備份設定「失敗時通知」（要先設定通知管道） |
| 中 | 寶塔面板顯示 Python 3.7 的 deprecation 警告，與更新寶塔面板一起處理 |
| 低 | 10/19 的快照若也接近 0.9 GB，確認是 fstrim 造成 |
| 中 | 外圍防護：Cloudflare WAF managed rules；`php.ini` 的 `disable_functions` 停用 `exec`、`system` 等（先確認網站沒用到）；寶塔開啟 `open_basedir` |
| 中 | 更新寶塔面板（續簽腳本還在用 Python 3.7）；不要因為 PHP 卡住而一起延後 |
| 中 | 作業系統與 PHP 分開處理：寶塔的 PHP 自行編譯在 `/www/server/php/74`，不依賴 Debian 套件。Debian 11 升級前先拍 snapshot，並確認寶塔支援新版本 |
| 低 | 評估長期方案：PHP 7.4 改放 container、主機升級作業系統；或購買 PHP 7.4 付費延長支援；或改寫網站 |
| 低 | 設定 Cloudflare Authenticated Origin Pulls：防火牆只認 Cloudflare IP，別人透過自己的 Cloudflare 帳號或 Workers 仍可連到主機 |
| 低 | `product.php` 遇到舊格式網址時 301 導回 `?pid=N`，讓搜尋引擎更快換成新網址 |
| 低 | 評估用 Cloudflare Access（email 驗證碼）保護 KindEditor，取代「需要時手動停用規則」 |
| 低 | 爬蟲停止後，再評估 Cloudflare 規則是否保留 |
| 低 | Apache 設定 `mod_remoteip`，log 才看得到訪客真實 IP |
| 低 | 找時間演練一次「從快照建磁碟並換上 VM」的還原流程 |
| 低 | Shielded VM 的安全啟動目前停用；開啟要關機，並確認 kernel module 相容 |
| 低 | 7/7 有一次沒有 shutdown 紀錄的開機，原因未查明 |
| 低 | DMARC 目前是 `p=none`，DNS 上也沒看到 DKIM |
| 低 | 專案只有一個 Owner，建議加一個備援管理者 |

## 本次結論

磁碟滿的主因是一行 PHP deprecated 警告，7 個月寫了 4.5G。止血後加上 logrotate 與 journald 上限，使用率從 100% 降到 43%。過程中另外修好 Ops Agent 的 IAM 權限、換掉過期的主機憑證，並把防火牆收斂到必要來源。

10/14 回頭確認時，又處理了三件事：資料庫原本完全沒有備份，已改為每天備份並和磁碟快照接上；網站連結裡的 `time()` 做出爬蟲陷阱，access log 每天翻倍，拆掉陷阱並用 Cloudflare 規則擋下後，主機請求從每分鐘約 3,500 筆降到 7 筆；KindEditor 上傳 API 不用登入就能用，已在 Cloudflare 封鎖，沒有發現入侵跡象。網站只能跑 PHP 7.4，所以外圍防護與備份比升級更重要。剩下的「待確認」只有 Ops Agent 測試訊息。

- [Ops Agent 疑難排解](https://cloud.google.com/stackdriver/docs/solutions/agents/ops-agent/troubleshoot-run-ingestion)
- [Compute Engine 存取範圍與 IAM](https://cloud.google.com/compute/docs/access/service-accounts#accesscopesiam)
- [IAP TCP 轉送的防火牆設定](https://cloud.google.com/iap/docs/using-tcp-forwarding#create-firewall-rule)
- [Cloudflare Origin CA 憑證](https://developers.cloudflare.com/ssl/origin-configuration/origin-ca/)
- [Cloudflare IP 範圍](https://www.cloudflare.com/ips/)
- [PHP 8.0 移除舊式 constructor](https://www.php.net/manual/en/migration80.incompatible.php)
- [logrotate(8)](https://manpages.debian.org/logrotate)、[journald.conf(5)](https://www.freedesktop.org/software/systemd/man/latest/journald.conf.html)
