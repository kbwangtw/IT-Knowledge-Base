---
layout: default
title: "GCP 網站主機磁碟 100%：清 log 之後，又查出四個問題"
permalink: /docs/gcp/gce-disk-full-log-cleanup-2026-10-05/
date: 2026-10-05
categories: [GCP, Debian, Logging, Security, Cloudflare]
last_modified_at: 2026-10-05
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
| 主機 SSL 憑證 | Let's Encrypt，9/8 已過期 | Cloudflare Origin Certificate，到 2041 年 | 已確認；Cloudflare「完整（嚴格）」模式待確認 |
| GCP 防火牆 | RDP、SSH、面板、80/443 全部對全世界開放 | RDP 刪除；SSH、面板限定來源；80/443 只允許 Cloudflare | 直連逾時、經 Cloudflare 回 200；面板與新 SSH 連線待確認 |

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

## 排查時踩到的坑

這幾個是指令本身的陷阱，結果看起來合理，其實是錯的：

| 情況 | 原因 | 正確做法 |
| --- | --- | --- |
| `sudo ls /www/wwwlogs/*.log` 顯示找不到檔案 | `*` 由自己的 shell 先展開，一般使用者讀不到該目錄 | `sudo sh -c 'ls /www/wwwlogs/*.log'` |
| `curl ... \| head; echo $?` 永遠是 0 | `$?` 是管線最後一個指令（head）的結束碼 | 不接管線，改用 `curl -sS -o /dev/null -w "%{http_code}"` |
| grep 多行 JSON 只抓到 `"reason"` 那行，看不到時間 | 只有第一行有時間戳記 | grep 有時間戳記的那行，例如 `error sending to Cloud Logging` |
| awk 比對 `$2 >= "05:29"` 找重啟後的錯誤 | 只比時間沒比日期，前幾天的訊息也會算進去 | 先清空 log 再觀察，或同時比對日期 |
| 以為 Apache 假死而重啟 | 被上面兩個錯誤結果誤導 | 先用不會騙人的指令確認，再動服務 |

## 還沒做完的事

| 優先 | 項目 |
| --- | --- |
| 高 | 隔天確認 logrotate 第一次輪替、磁碟維持在 43% 左右 |
| 中 | GCP Monitoring 設定磁碟使用率超過 80% 寄信 |
| 中 | 修正 `DB` 的 constructor（改成 `__construct()`，保留 `DB()` 呼叫它），為 PHP 8 做準備 |
| 中 | 更新寶塔面板（續簽腳本還在用 Python 3.7） |
| 中 | 規劃 Debian 11、PHP 7.4 升級；兩者都已停止官方安全更新 |
| 低 | 7/7 有一次沒有 shutdown 紀錄的開機，原因未查明 |
| 低 | DMARC 目前是 `p=none`，DNS 上也沒看到 DKIM |
| 低 | 專案只有一個 Owner，建議加一個備援管理者 |

## 本次結論

磁碟滿的主因是一行 PHP deprecated 警告，7 個月寫了 4.5G。止血後加上 logrotate 與 journald 上限，使用率從 100% 降到 43%。過程中另外修好 Ops Agent 的 IAM 權限、換掉過期的主機憑證，並把防火牆收斂到必要來源。上面標示「待確認」的項目，還要補上證據才能結案。

- [Ops Agent 疑難排解](https://cloud.google.com/stackdriver/docs/solutions/agents/ops-agent/troubleshoot-run-ingestion)
- [Compute Engine 存取範圍與 IAM](https://cloud.google.com/compute/docs/access/service-accounts#accesscopesiam)
- [IAP TCP 轉送的防火牆設定](https://cloud.google.com/iap/docs/using-tcp-forwarding#create-firewall-rule)
- [Cloudflare Origin CA 憑證](https://developers.cloudflare.com/ssl/origin-configuration/origin-ca/)
- [Cloudflare IP 範圍](https://www.cloudflare.com/ips/)
- [PHP 8.0 移除舊式 constructor](https://www.php.net/manual/en/migration80.incompatible.php)
- [logrotate(8)](https://manpages.debian.org/logrotate)、[journald.conf(5)](https://www.freedesktop.org/software/systemd/man/latest/journald.conf.html)
