---
layout: default
title: "GCP 網站主機磁碟 100%：清 log 之後，又查出四個問題"
permalink: /docs/gcp/gce-disk-full-log-cleanup-2026-10-05/
date: 2026-10-05
categories: [GCP, Debian, Logging, Security, Cloudflare]
last_modified_at: 2026-10-20
---

# GCP 網站主機磁碟 100%：清 log 之後，又查出四個問題

> **一句話**：磁碟滿只是結果，要找的是「誰一直在寫」。這台主機的元兇是一行 PHP 警告 7 個月寫了 4.5G；順著查下去，又找到 Ops Agent 權限不足、主機憑證過期、防火牆全開、資料庫沒備份、網站自己做出爬蟲陷阱等問題，全部處理完並驗證。

| 項目 | 內容 |
| --- | --- |
| 適合誰看 | 雲端主機磁碟突然滿了、不知道從哪裡查起的人 |
| 環境 | GCE VM（15G 系統碟）、Debian 11、寶塔面板（Apache + PHP 7.4 + MariaDB）、Google Cloud Ops Agent 2.64.0；網站在 Cloudflare 後面 |
| 日期 | 2026-10-05 處理；10/14～10/15 回頭確認並補強 |
| 結論 | ✅ 磁碟 100% → 44%；✅ log 輪替與上限（10/20 改每小時檢查）；✅ 磁碟 80% 告警；✅ Ops Agent、憑證、防火牆、資料庫備份都已處理；✅ 爬蟲陷阱拆除、KindEditor 封鎖；⏳ 網站只能跑 PHP 7.4，外圍防護持續補強 |

> 文中的專案 ID、IP、網域與帳號都已替換成範例值（例如 `example.com`）。

## 1. 先認識幾個名詞

| 名詞 | 白話解釋 |
| --- | --- |
| **GCE** | Google Compute Engine，Google 雲端上的虛擬機 |
| **寶塔面板** | 中文的伺服器管理網頁，網站、PHP、資料庫都在這裡設定 |
| **Ops Agent** | 把 VM 的 log 和監控數據送到 Google Cloud 的程式 |
| **Service account／IAM** | VM 在 Google Cloud 上的「身分」和它被授予的權限 |
| **Access scope** | VM 層級的權限上限；和 IAM 是兩道門，都要開 |
| **logrotate** | 定期把 log 切檔、壓縮、刪掉舊的，避免無限長大 |
| **journald** | systemd 的系統日誌；可以設定最多用多少空間 |
| **稀疏檔（sparse file）** | 檔案中間有「空洞」，`ls` 顯示很大，實際佔用的磁碟空間（`du`）很小 |
| **Cloudflare Origin Certificate** | Cloudflare 發給主機用的憑證，只有 Cloudflare 信任，可用 15 年 |
| **爬蟲陷阱（crawler trap）** | 網站不斷產生新網址，讓爬蟲永遠抓不完 |
| **crash-consistent 快照** | 像直接拔電源那一瞬間的狀態；資料庫不一定一致 |

## 2. 結果先看

| 項目 | 處理前 | 處理後 | 驗證 |
| --- | --- | --- | --- |
| 磁碟使用率 | 100%（剩 102M） | 43%（剩 8.0G）；10/15 為 44% | ✅ |
| 網站 error log | 4.5G，同一行 PHP 警告 | 不再寫入 deprecated 訊息 | ✅ 2 分鐘內維持 0 bytes |
| 網站 log 輪替 | 無 | logrotate：每天、保留 14 份、200M 提早輪替 | ✅ 10/15 確認每天 00:00 正常輪替 |
| systemd journal | 873M | 上限 200M、保留 1 個月 | ✅ 96M |
| logrotate 頻率 | 每天一次 | 每小時檢查（`maxsize` 每小時生效） | ✅ 10/20 下一次為整點 |
| 磁碟告警 | 無 | Cloud Monitoring：任一分割區超過 80% 持續 5 分鐘寄信 | ✅ 10/20 建立，目前 44% |
| Ops Agent | 403，log 送不出去 | 補上 IAM 角色 | ✅ 10/14 Logs Explorer 搜得到測試訊息 |
| 主機 SSL 憑證 | Let's Encrypt，9/8 已過期 | Cloudflare Origin Certificate，到 2041 年 | ✅ Cloudflare 為「完整（嚴格）」 |
| 磁碟快照 | 以為沒有 | 早就有 `default-schedule-1`：每天一份、保留 14 天 | ✅ 14 份都是 READY |
| 資料庫備份 | 從來沒有 | 寶塔計畫任務：每天 14:00 UTC、保留 7 份 | ✅ 備份檔完整（9 個 table、Dump completed） |
| access log 暴增 | 每分鐘約 3,500 筆，爬蟲陷阱 | 連結拿掉 `time()`；Cloudflare 只質詢舊格式網址 | ✅ 每分鐘 7 筆，真人不被質詢 |
| KindEditor 上傳 API | 未登入可瀏覽、上傳 | Cloudflare 封鎖 `/cms/plugin/kindeditor/php/` | ✅ 回 403；未發現入侵跡象 |
| GCP 防火牆 | RDP、SSH、面板、80/443 全對全世界開放 | RDP 刪除；SSH、面板限定來源；80/443 只允許 Cloudflare | ✅ 直連逾時、經 Cloudflare 回 200；面板與 SSH 可登入 |

## 3. 步驟一：先看空間被誰吃掉

```bash
df -h /                                         # 根目錄用了多少
sudo du -sh /var/log/* | sort -h | tail -15     # /var/log 底下誰最大
sudo journalctl --disk-usage                    # systemd journal 佔多少
```

**看到的結果**：`/var/log` 加起來只有約 1.7G：

| 位置 | 大小 |
| --- | --- |
| /var/log/journal | 873M |
| /var/log/google-cloud-ops-agent | 790M |
| 其他 log | 約 20M |

但根目錄用了 14G。**log 只是一部分，另外 12G 在別處。** 先用 journal 救急，再往外找：

```bash
sudo journalctl --vacuum-size=100M                          # journal 縮到 100M
sudo du -xh --max-depth=1 / 2>/dev/null | sort -h | tail -15  # 根目錄第一層誰最大
```

`du` 顯示 `/www` 有 8.0G。`/www`、`/.Recycle_bin`、`/patch` 這組目錄是寶塔面板的典型結構。

## 4. 步驟二：Ops Agent 一直被拒絕，失敗訊息越寫越多

### 4-1 找出最多的錯誤

```bash
F=/var/log/google-cloud-ops-agent/subagents/logging-module.log
sudo grep -E "\[ ?(error|warn)\]" $F | cut -d']' -f2- | sort | uniq -c | sort -rn | head -10
```

最多的是：

```text
[ warn] [http_client] cannot increase buffer: current=4192 requested=36960 max=4192
[ warn] [output:stackdriver:stackdriver.1] http_do=-1
[ warn] [output:stackdriver:stackdriver.1] tag=ops-agent-fluent-bit error sending to Cloud Logging: {
```

錯誤內容是多行 JSON，grep 只抓到第一行的 `{`。用 `-A` 把後面幾行一起印出來：

```bash
sudo grep -A 15 "error sending to Cloud Logging" $F | tail -40
```

```text
"code": 403,
"message": "Permission 'logging.logEntries.create' denied on resource ...",
"reason": "IAM_PERMISSION_DENIED",
```

**這是惡性循環**：送 log 被拒絕 → 失敗訊息寫進 Agent 自己的 log → 這份 log 也要上傳 → 又失敗 → 再寫一筆。

### 4-2 scope 和 IAM 是兩道門

VM 要寫 Cloud Logging，兩道門都要開：

| 關卡 | 查法 | 本案 |
| --- | --- | --- |
| Access scope（VM 層級的上限） | metadata 的 scopes | 有 `logging.write` |
| IAM 角色（service account 的實際權限） | 錯誤訊息的 reason | 缺少，`IAM_PERMISSION_DENIED` |

```bash
curl -s -H "Metadata-Flavor: Google" \
  http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/email; echo
curl -s -H "Metadata-Flavor: Google" \
  http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/scopes; echo
```

這兩行向 VM 內建的 metadata 服務查詢「我是哪個 service account」「我的 scope 是什麼」。

新的 GCP 專案不一定會自動給預設 compute service account Editor 角色，所以要手動補。補完後的 IAM 清單也證實，這個 service account 原本沒有任何專案角色。

### 4-3 補 IAM 要在 Cloud Shell 做，不是在 VM 上

在 VM 上執行 `gcloud`，用的是 VM 自己的 service account，它沒有權限改 IAM，會出現 `ACCESS_TOKEN_SCOPE_INSUFFICIENT`。

> ⚠️ 錯誤訊息建議「更新 VM 的 access scopes」，**不要照做**：給 VM 改 IAM 的能力，網站一旦被入侵，整個專案就會被接管。

改用專案 Owner 帳號，在 **Cloud Shell** 執行：

```bash
gcloud projects add-iam-policy-binding <PROJECT_ID> \
  --member="serviceAccount:<PROJECT_NUMBER>-compute@developer.gserviceaccount.com" \
  --role="roles/logging.logWriter" --condition=None

gcloud projects add-iam-policy-binding <PROJECT_ID> \
  --member="serviceAccount:<PROJECT_NUMBER>-compute@developer.gserviceaccount.com" \
  --role="roles/monitoring.metricWriter" --condition=None
```

| 角色 | 用途 |
| --- | --- |
| `roles/logging.logWriter` | 只能寫 log |
| `roles/monitoring.metricWriter` | 只能寫監控數據 |

### 4-4 回到 VM 重啟並確認

```bash
sudo systemctl restart google-cloud-ops-agent
sudo tail -20 /var/log/google-cloud-ops-agent/subagents/logging-module.log
```

**應該看到**：只有 `[ info]` 的 worker started 與 inotify 訊息，沒有新的 warn。確認後清空舊 log：

```bash
sudo truncate -s 0 /var/log/google-cloud-ops-agent/subagents/logging-module.log
```

另外有 4 個 7 月產生的 buffer chunk 出現 `format check failed`，停止 Agent 後刪除：

```bash
sudo systemctl stop google-cloud-ops-agent
sudo find /var/lib/google-cloud-ops-agent/fluent-bit/buffers -name "<chunk 檔名樣式>" -ls
sudo find /var/lib/google-cloud-ops-agent/fluent-bit/buffers -name "<chunk 檔名樣式>" -delete
sudo systemctl start google-cloud-ops-agent
```

**端到端確認**（10/14）：送出 `logger "ops-agent-test-$(date +%s)"` 後，Logs Explorer 用 `ops-agent-test` 搜得到。同一筆訊息出現兩次，推測是 Debian 的 rsyslog 同時寫進 `/var/log/syslog` 和 `/var/log/messages`，Ops Agent 預設兩個都收（未確認，影響只是 log 量多一倍）。

## 5. 步驟三：真正的主因，4.5G 的 PHP 警告

```bash
sudo ls -lhS /www/wwwlogs | head -15     # 依大小排序
```

| 檔案 | 大小 |
| --- | --- |
| example.com-error_log | 4.5G |
| example.com-access_log | 2.0G |

網站本體只有 141M，log 是它的 45 倍。統計 error log 裡最常見的訊息（先去掉每行開頭的時間、pid、client 欄位）：

```bash
F=/www/wwwlogs/example.com-error_log
sudo tail -n 200000 $F | sed -E 's/^(\[[^]]*\] *)+//' | cut -c1-150 | sort | uniq -c | sort -rn | head -10
sudo head -1 $F | cut -c1-40     # 第一行的時間，看從哪天開始累積
```

| 次數（最後 20 萬行） | 內容 |
| --- | --- |
| 199,953（99.98%） | `PHP Deprecated: Methods with the same name as their class will not be constructors...; DB has a deprecated constructor` |
| 18 | `include(cms3/db/closedb.php): failed to open stream` |
| 數筆 | `(28)No space left on device`（9/27 磁碟寫滿） |

這份 log 從 3/3 開始累積，7 個月長到 4.5G。

### 5-1 這行警告是什麼意思

網站程式的 `DB` class 用的是 PHP 4 的寫法：用跟 class **同名**的 function 當 constructor（建立物件時自動執行的函式）。

```php
class DB {
    function DB() {        // 舊寫法：function 名稱和 class 相同
        // 連線資料庫...
    }
}
```

PHP 7 把它標成 deprecated。每個請求都會建立一次 DB 物件，所以**每個請求都寫一行**。

> **PHP 8 已經移除這種寫法。** 到了 PHP 8，`DB()` 只是一個普通 function，不會在建立物件時執行，資料庫就不會連線。所以修好程式之前，不能直接升級 PHP 8。

### 5-2 先止血：不記錄 deprecated

原本設定是 `E_ALL & ~E_NOTICE`。要**保留原有的排除項目**再加上 deprecated；如果整行換成 `E_ALL & ~E_DEPRECATED`，等於把 notice 重新打開，舊程式的 notice 可能又把 log 灌滿。

```bash
INI=/www/server/php/74/etc/php.ini
sudo cp $INI $INI.bak-$(date +%F)
sudo sed -i 's/^error_reporting = E_ALL & ~E_NOTICE$/error_reporting = E_ALL \& ~E_NOTICE \& ~E_DEPRECATED \& ~E_STRICT/' $INI
sudo grep -n "^error_reporting" $INI
sudo /etc/init.d/php-fpm-74 reload
```

| 片段 | 意思 |
| --- | --- |
| `~E_NOTICE` | 不記錄 notice（原本就有） |
| `~E_DEPRECATED` | 不記錄「已過時」警告（新增） |
| `\&` | sed 裡 `&` 有特殊意義，要加 `\` 才是字面的 `&` |
| `reload` | 讓 PHP-FPM 重新讀設定，不中斷服務 |

這只是**不記錄**，程式本身還沒改。

### 5-3 留樣本再清空

> Apache 還開著這兩個檔案，要用 `truncate`（清空內容），**不能用 `rm`**。用 `rm` 的話檔名消失了，空間卻不會釋放。

```bash
E=/www/wwwlogs/example.com-error_log
A=/www/wwwlogs/example.com-access_log

sudo tail -n 1000 $E | gzip | sudo tee /root/error_log-sample-$(date +%F).gz > /dev/null
sudo truncate -s 0 $E

sudo tail -n 200000 $A | gzip | sudo tee /root/access_log-recent-$(date +%F).gz > /dev/null
sudo truncate -s 0 $A

df -h /
```

**看到的結果**：使用率從 89% 降到 43%。2 分鐘後再看，error log 仍是 0 bytes，access log 恢復寫入，網站回 200。

## 6. 步驟四：防止再滿（logrotate 與 journald）

### 6-1 logrotate

先確認寶塔沒有自己的「切割日誌」排程，避免兩套輪替互相干擾：

```bash
sudo crontab -l 2>/dev/null | grep -iE "log|cut"
```

本案只有一個排程，內容是 SSL 續簽（見第 7 節），不衝突。建立 `/etc/logrotate.d/wwwlogs`：

```bash
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

sudo logrotate -d /etc/logrotate.d/wwwlogs     # -d：模擬，不真的執行
```

| 參數 | 作用 |
| --- | --- |
| `su www www` | 目錄擁有者是 www，用它的身分輪替 |
| `daily` + `rotate 14` | 每天一次，保留 14 份 |
| `maxsize 200M` | 不到一天但超過 200M 也會輪替（只在 logrotate 執行時檢查） |
| `compress` + `delaycompress` | 舊檔壓縮，但最新一份先不壓 |
| `copytruncate` | 先複製再清空，Apache 不必 reload；複製的瞬間可能漏幾行 |

模擬結果沒有 error。輸出的 `log has already been rotated` 是因為 logrotate 第一次看到檔案時，把當天記成上次輪替日，第一次實際輪替會在隔天。

### 6-2 journald 上限

```bash
sudo mkdir -p /etc/systemd/journald.conf.d
sudo tee /etc/systemd/journald.conf.d/size.conf > /dev/null <<'EOF'
[Journal]
SystemMaxUse=200M
MaxRetentionSec=1month
EOF
sudo systemctl restart systemd-journald
journalctl --disk-usage
```

用 drop-in 檔（`journald.conf.d/` 底下）設定，不改主設定檔，升級時不會被覆蓋。

### 6-3 logrotate 改成每小時檢查（10/20）

`maxsize 200M` 只在 logrotate 執行時才檢查，而 `logrotate.timer` 預設每天 00:00 UTC 才跑一次；如果哪天又有新的錯誤狂寫，一天內可能長到好幾 GB。改成每小時跑，`daily` 的檔案仍是一天輪替一次，只是每小時多檢查一次大小：

```bash
sudo mkdir -p /etc/systemd/system/logrotate.timer.d
sudo tee /etc/systemd/system/logrotate.timer.d/hourly.conf > /dev/null <<'EOF'
[Timer]
OnCalendar=
OnCalendar=hourly
AccuracySec=1m
EOF
sudo systemctl daemon-reload
sudo systemctl restart logrotate.timer
systemctl list-timers logrotate.timer --all | head -3
```

| 片段 | 意思 |
| --- | --- |
| `logrotate.timer.d/hourly.conf` | drop-in 檔，不改原檔，升級不會被覆蓋 |
| `OnCalendar=`（空白） | 先清掉原本的每日設定，否則會疊加 |
| `OnCalendar=hourly` | 每小時整點執行 |

**看到的結果**：`NEXT` 從隔天 00:00 變成下一個整點（01:00 UTC）。

### 6-4 磁碟使用率告警（10/20）

上面都是「不讓它滿」，這一步是「快滿時一定有人知道」：這台主機不在內網 Graylog 的監控範圍，沒有告警的話要等網站掛掉才會發現。Ops Agent 已經在送監控數據（4-4），直接用 Cloud Monitoring 建立告警。在 Cloud Shell 執行（信箱用 `read` 輸入，單獨貼上）：

```bash
read -p "收告警的 Email：" MAILTO
```

```bash
CH=$(gcloud beta monitoring channels create \
  --display-name="告警信箱" --type=email \
  --channel-labels=email_address="$MAILTO" \
  --format="value(name)")
echo "通知管道：$CH"

cat > /tmp/disk-alert.json <<EOF
{
  "displayName": "GCE 磁碟超過 80%",
  "combiner": "OR",
  "conditions": [{
    "displayName": "磁碟使用率 > 80%（持續 5 分鐘）",
    "conditionThreshold": {
      "filter": "resource.type = \"gce_instance\" AND metric.type = \"agent.googleapis.com/disk/percent_used\" AND metric.labels.state = \"used\"",
      "comparison": "COMPARISON_GT",
      "thresholdValue": 80,
      "duration": "300s",
      "aggregations": [{"alignmentPeriod": "300s", "perSeriesAligner": "ALIGN_MEAN"}],
      "trigger": {"count": 1}
    }
  }],
  "notificationChannels": ["$CH"]
}
EOF
gcloud alpha monitoring policies create --policy-from-file=/tmp/disk-alert.json --format="value(name,displayName)"
```

| 片段 | 意思 |
| --- | --- |
| `channels create --type=email` | 建立 Email 通知管道，ID 存進 `CH` |
| `agent.googleapis.com/disk/percent_used`、`state = "used"` | Ops Agent 回報的磁碟已使用百分比 |
| `> 80`、`duration 300s` | 超過 80% 持續 5 分鐘才告警，避免瞬間波動 |
| 沒有限定裝置 | Ops Agent 的裝置名稱格式（`sda1` 或 `/dev/sda1`）未確認，寫錯就永遠不會觸發；不限定時任何分割區超過 80% 都會通知，更保險 |
| `<<EOF`（沒加引號） | 讓 `$CH` 換成實際的通知管道 ID |

**看到的結果**：`projects/<專案>/alertPolicies/<ID>  GCE 磁碟超過 80%`。目前 44%，不會觸發；也可以在 Console 搜尋 `Alerting` 看到這個 policy。Console 操作的路徑是 Alerting → **+ CREATE POLICY** → Select a metric（關掉 **Active** 開關才找得到）→ VM Instance › Disk › Disk utilization → filter `state = used` → Above threshold 80 → 通知管道選 Email。

> Cloud Monitoring 告警可能產生少量費用，以 Console 顯示為準。

### 6-5 10/20 健康檢查

```bash
df -h /
sudo find / -xdev -type f -size +100M -exec ls -lh {} + 2>/dev/null | awk '{print $5, $9}' | sort -h
sudo du -sh /www/wwwlogs /www/server/panel/logs /www/server/data /var/log 2>/dev/null
journalctl --disk-usage
```

**看到的結果**：使用率 44%（和 10/15 相同）；網站 log 99M、寶塔面板 log 5.9M、journal 161M；MySQL 的 `ib_logfile0`（128M）是固定大小的 InnoDB redo log，正常。另有一個 Ops Agent 在 10/5 失敗期間留下的舊檔 `/var/log/google-cloud-ops-agent/subagents/logging-module-2026-10-05T…log`，`ls` 顯示 390M，但 `du` 只佔 216K（稀疏檔，中間是空洞），已刪除；`df` 不變。

## 7. 順便查出：主機憑證已過期，續簽卻每天「Successful」

寶塔唯一的排程是 Let's Encrypt 續簽，執行紀錄每天都寫 `Successful`，內容卻是：

```text
存在泛域名，只能用dns验证方式续签！
未绑定dns-api，跳过域名：*.example.com!
域名全部未绑定dns-api，无法使用dns验证续签！
★[2026-10-04 17:30:02] Successful
```

萬用字元憑證只能用 DNS 驗證，沒有設定 DNS API 就每天跳過。**`Successful` 只代表腳本跑完**，不代表有續簽。

```bash
echo | openssl s_client -connect 127.0.0.1:443 -servername example.com 2>/dev/null \
  | openssl x509 -noout -subject -issuer -dates
```

這行直接連本機 443，印出實際使用中憑證的主旨、簽發者和有效期限。

憑證 6/10 申請、9/8 到期，已過期將近一個月。網站還能開，是因為 Cloudflare 的加密模式是「完整」：

| Cloudflare 模式 | 主機憑證過期時 |
| --- | --- |
| 完整（Full） | 仍可連線，但 Cloudflare 不驗證主機身分 |
| 完整（嚴格）（Full strict） | 顯示 526 錯誤 |

### 7-1 改用 Cloudflare Origin Certificate

網站兩筆 A 紀錄都是橘色雲朵（已代理），MX、TXT 是僅 DNS，所以換成只有 Cloudflare 信任的 Origin Certificate 不會影響訪客。

1. Cloudflare：SSL/TLS → 原始伺服器 → 建立憑證（RSA 2048、15 年、PEM）。
2. 寶塔：網站 → 設定 → SSL → 貼上私密金鑰與憑證 → 保存。**私密金鑰只顯示一次**，直接從 Cloudflare 複製到寶塔，不經過聊天、記事本或文件。
3. VM 上用上面的 `openssl` 指令確認：issuer 是 CloudFlare Origin SSL Certificate Authority，notAfter 是 2041 年。
4. Cloudflare 加密模式改成「完整（嚴格）」，連測幾次網站回 200。
5. 寶塔的續簽排程改為停用。

**驗證**（10/14）：Cloudflare 概觀頁顯示「完整（嚴格）」（curl 回 200 在「完整」模式下也會成立，不能當證據），續簽任務已停用。

### 7-2 「一律使用 HTTPS」原本就開著

當初從「24 小時有 474 個明文 HTTP 請求」推論它沒開，這個推論不成立：開啟後，訪客的 `http://` 請求一樣會先到 Cloudflare，只是每個都回 301。**光看請求數分不出來，要看回應**：

```bash
curl -sI http://example.com | head -1                                   # HTTP/1.1 301 Moved Permanently
curl -sI "http://example.com/product.php?pid=2" | grep -i "^location"   # https://example.com/product.php?pid=2
```

HSTS 先不開：瀏覽器會記住好幾個月，HTTPS 一旦出問題就無法從伺服器端救回。

## 8. 步驟五：防火牆只開必要的來源

**原本的 GCP 防火牆**：

| 規則 | 來源 | 問題 |
| --- | --- | --- |
| default-allow-rdp（3389） | 0.0.0.0/0 | Linux 用不到 |
| default-allow-ssh（22） | 0.0.0.0/0 | btmp 有 1.6M 的失敗登入 |
| 寶塔面板（自訂 port） | 0.0.0.0/0 | 管理後台對外 |
| default-allow-http/https | 0.0.0.0/0 | 知道主機 IP 就能繞過 Cloudflare |

修改前先確認專案只有這一台 VM，因為 `default-*` 規則會套用到整個 VPC：

```bash
gcloud compute instances list --format="table(name,zone.basename(),status,tags.items.list())"
```

**依風險由低到高修改，每一步都驗證。**

> ⚠️ SSH 一定要保留 `35.235.240.0/20`：從 Console 開的瀏覽器 SSH 是從 Google IAP 這個網段連進來的，拿掉會把自己鎖在外面。

```bash
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
```

第 2 步的 `paste -sd, -` 把 Cloudflare 的 IP 清單（一行一個）接成逗號分隔的一行。

**驗證**：

```bash
curl -sS -o /dev/null -m 8 -w "direct HTTP=%{http_code}\n" -k https://<VM外部IP>; echo "exit=$?"
curl -sS -o /dev/null -m 10 -w "via CF HTTP=%{http_code}\n" https://example.com
```

**看到的結果**：直連 `exit=28`（逾時），經 Cloudflare `HTTP=200`。10/14 確認面板從管理者電腦可登入，新開的瀏覽器 SSH 視窗也可登入。

Cloudflare 的 IP 清單偶爾會更新；網站若突然出現 522，重新執行第 2 步。

## 9. 備份：快照早就有，資料庫卻從沒備份（10/14）

### 9-1 確認快照排程和實際快照

原本以為沒有備份，查了才發現建立 VM 時，Console 已經自動建立並套用 `default-schedule-1`。但「有排程」不等於「有備份」（第 7 節的續簽排程就是反例），所以規則和實際快照都要看。在 Cloud Shell 執行：

```bash
gcloud compute resource-policies describe default-schedule-1 --region=<REGION> \
  --format="yaml(snapshotSchedulePolicy)"
gcloud compute snapshots list --filter="sourceDisk~<DISK>" \
  --format="table(name,status,storageBytes,creationTimestamp)" --sort-by=~creationTimestamp
```

| 項目 | 結果 | 判斷 |
| --- | --- | --- |
| `maxRetentionDays` | 14 | 被入侵好幾天才發現，也還有乾淨的版本 |
| `onSourceDiskDelete` | `KEEP_AUTO_SNAPSHOTS` | VM 是「刪除執行個體時刪除磁碟」，這項保證快照不會跟著消失 |
| `guestFlush` | false | crash-consistent，等同那個瞬間直接拔電源 |
| 實際快照 | 9/30 到 10/13 每天一份，全部 `READY` | ✅ |
| 實際拍攝時間 | 每天 14:20 UTC（台灣 22:20） | 名稱裡的時間戳記和 `creationTimestamp` 一致 |

- 快照是增量的：最舊一份約 3.3 GB，其他每天 0.1 到 0.5 GB；10/5 清 log 那天約 0.9 GB，合理。
- 10/12 也有約 0.9 GB：區間內修改過的檔案只有約 20 MB，`systemctl list-timers` 顯示每週一執行的 `fstrim.timer` 在 10/12 00:47 UTC 跑過（10/5 也是週一），推測是 fstrim 讓快照多算了區塊；10/20 用 10/19 的快照驗證，見下方。
- **一顆磁碟同時只能套一個快照排程**，不要再另外建立。

**10/20 驗證：週一的快照為什麼比較大**

fstrim 是把「已刪除檔案佔用的區塊」告訴磁碟的指令；GCP 的增量快照會把這些被通知過的區塊也算成「有變動」。10/19 也是週一，拿它來驗證。

在 Cloud Shell 列出最近的快照（`.date(…, tz=UTC)` 用 UTC 顯示，Cloud Shell 預設是美國太平洋時間，會顯示成 07:20）：

```bash
gcloud compute snapshots list --filter="sourceDisk~<DISK>" \
  --format="table(creationTimestamp.date('%Y-%m-%d %H:%M', tz=UTC):label=拍攝時間UTC,status,storageBytes.size(units_out=M):label=MB)" \
  --sort-by=~creationTimestamp --limit=15
```

在主機上看 fstrim 每次執行的紀錄：

```bash
systemctl list-timers fstrim.timer --all
journalctl -u fstrim.service --since "2026-10-05" --no-pager | grep -E "Started|trimmed"
```

**看到的結果**（快照日期依排序推算，全部 `READY`）：

| 日期 | 快照大小 | 當天 00:xx UTC 的 fstrim（`/`） |
| --- | --- | --- |
| 10/5（週一） | 約 0.9 GB | 592.6 MiB；當天另外清了大量 log |
| 10/6～10/11 | 114～148 MB（10/6 未取得） | — |
| 10/12（週一） | **894.9 MB** | **8.5 GiB** |
| 10/13～10/18 | 117.6～208.8 MB | — |
| 10/19（週一） | **479.1 MB** | **8 GiB** |

**結論**：

- ✅ 只有執行 fstrim 的週一，快照會明顯變大（平常日約 120～200 MB）；推測成立，屬正常現象，不用處理。快照只保留 14 天，多出來的空間有限。
- fstrim 回報的數字（8.5 GiB、8 GiB）**和快照大小不成比例**：它回報的是被通知的空閒區塊總量，不是實際變動的資料量；週一的快照實際多出多少，還和那一週刪了多少檔案有關（10/5 清 log 後的那一週較多）。這部分是推測，未再細查。
- fstrim 每週一約 00:00～00:50 UTC 執行（10/19 是 00:01），快照在 14:20 UTC，所以同一天的快照就會包含它的影響。


### 9-2 補上資料庫備份

快照是 crash-consistent，對資料庫不保證一致，所以另外查寶塔的資料庫備份。`/www/backup/database/mysql/all_backup` 從 3/2 建立後就是空的：**資料庫從來沒有備份過**。

在寶塔「計畫任務」新增：

| 欄位 | 設定 | 原因 |
| --- | --- | --- |
| 任務類型 | 備份資料庫，MySQL，所有 | |
| 執行週期 | 每天 14:00 | 伺服器是 UTC；比快照早 20 分鐘，每份快照裡都有一份一致的資料庫備份 |
| 備份到 | 伺服器磁碟，`/www/backup` | 不傳到第三方雲端 |
| 保留最新 | 7 份 | |
| 進程鎖 | 開啟 | 上一次還沒跑完時不會重複執行 |

手動執行一次後，寶塔日誌只有「開始備份」，沒有結束訊息，所以**直接驗證檔案**：

```bash
sudo find /www/backup/database -type f -mmin -30 -ls     # 30 分鐘內產生的備份檔
F=<備份檔路徑>
sudo gzip -t $F && echo "gzip OK"                         # 壓縮檔完整嗎
sudo zcat $F | grep -c "CREATE TABLE"                     # 有幾個資料表
sudo zcat $F | tail -3                                    # 結尾有沒有 Dump completed
sudo sh -c 'ls /www/server/data/<DB>/*.frm | wc -l'       # 實際資料表數量
```

| 檢查 | 結果 |
| --- | --- |
| 壓縮檔 | 18 KB，`gzip OK` |
| 解壓後 | 約 100 KB |
| `CREATE TABLE` 數量 | 9，和 `.frm` 檔數量相同 |
| 結尾 | `-- Dump completed` |

`/www/server/data` 有 219 MB，但網站資料庫本身只有 724 KB，其餘是 MariaDB 自己的檔案，所以 18 KB 的備份是完整的。

## 10. access log 每天翻倍：網站自己做出的爬蟲陷阱（10/14）

### 10-1 現象

清完 log 後，磁碟 9 天內從 43% 升到 48%。logrotate 正常，問題出在 access log 本身：

| 日期 | 檔案 | 大小 |
| --- | --- | --- |
| 10/6 | `.8.gz` | 350K |
| 10/10 | `.4.gz` | 3.2M |
| 10/12 | `.2.gz` | 13M |
| 10/13 | `.1`（未壓縮） | 571M |
| 10/14 | 目前的 log | 1.5 小時就 67M |

`maxsize 200M` 只在 logrotate 每天執行時檢查，擋不住一天之內暴增的流量。

### 10-2 誰在打

```bash
L=/www/wwwlogs/example.com-access_log
sudo awk -F'"' '{print $6}' $L | sort | uniq -c | sort -rn | head -10     # 最多的 User-Agent
sudo awk '{print $7}' $L | cut -c1-80 | sort | uniq -c | sort -rn | head -10  # 最多的網址
```

- 1.5 小時內 31 萬筆（每秒約 59 筆）。
- User-Agent 幾乎全是「Mac OS X 10_15_7 + Chrome 116 到 146」。
- 網址都是 `/product.php?<10 位數字>&pid=<1-9>`，每個網址只出現約 2 次。
- 來源 IP 全是 Cloudflare（Apache 沒有設定 `mod_remoteip`）。
- Cloudflare 分析：24 小時 292 萬個請求，幾乎全部 Served by Origin，快取完全沒命中。

### 10-3 那串數字是網站自己產生的

```bash
sudo grep -rn "product.php?" /www/wwwroot/example.com --include=*.php | head
```

```php
href="product.php?' . time() . '&pid=' . $main_sn[$i] . '"
```

選單（每一頁都有）和產品列表產生連結時，都在網址裡放了 `time()`（當下的 Unix 時間戳記）。每抓一頁就冒出 9 個從沒出現過的網址，爬蟲跟著抓，網址就無限增加，形成**爬蟲陷阱**。這也解釋了為什麼流量一階一階翻倍、快取永遠不會命中。

> 一開始以為正常網址是 `product.php?pid=4`，差點寫出「不是 `pid=` 開頭就擋」的規則；查了正常日期（10/6）的 log，才發現正常連結本來就帶數字，那條規則會擋到真人。**寫規則前先看正常時期的 log。**

### 10-4 先止血：Cloudflare 自訂規則

網路安全 → 安全性規則 → 自訂規則：

```text
(http.request.uri.path eq "/product.php" and not cf.client.bot)
```

動作：**受控的質詢（Managed Challenge）**。`not cf.client.bot` 會放行 Google 這類 Cloudflare 驗證過的搜尋引擎機器人。真人通過一次質詢後，30 分鐘內不會再被質詢。

**驗證**：

```bash
a=$(sudo wc -l $L | cut -d' ' -f1); sleep 60; b=$(sudo wc -l $L | cut -d' ' -f1); echo "每分鐘 $((b-a)) 筆"
sudo tail -n 3000 $L | grep "product.php" | awk '{print substr($4,14,5)}' | uniq -c | tail -15
```

| 時間（UTC） | `product.php` 每分鐘 |
| --- | --- |
| 部署前 | 約 3,500 |
| 01:46（規則傳播中） | 2,019 |
| 01:50 之後 | 4 到 12 |

無痕視窗開產品頁正常。Cloudflare 圖表上 Served by Origin 降到接近 0，Mitigated 每分鐘 4,000 到 5,000 筆：**爬蟲沒停，只是被擋在 Cloudflare 那一層**。

### 10-5 拆掉陷阱：連結拿掉 `time()`

改之前先確認那串數字沒被程式用到：`product.php` 本身沒有讀 `$_GET`，它 include 的 `product/*.php` 用的是 `$main_sn = $_GET['pid'];`，整個網站也沒用到 `QUERY_STRING`，所以拿掉不影響功能。

```bash
S=/www/wwwroot/example.com
F="$S/menu/menu_list.php $S/product/small_main_img.php"

# 備份放在網站目錄外面：.bak 不會被當成 PHP 執行，Apache 會直接送出原始碼
B=/root/site-backup-$(date +%F)
sudo mkdir -p $B && sudo cp -a --parents $F $B/

# 先預覽（-n + p），確認後才用 -i 寫入
sudo sed -n "s/product\.php?' \. time() \. '&pid=/product.php?pid=/p" $F
sudo sed -i "s/product\.php?' \. time() \. '&pid=/product.php?pid=/" $F

sudo grep -n "product.php?" $F
for f in $F; do sudo /www/server/php/74/bin/php -l $f; done     # PHP 語法檢查
ls -l $F
```

**看到的結果**：兩個檔案語法檢查都通過，擁有者仍是 `www`，大小各少 15 bytes，剛好是 `' . time() . '&` 的長度。瀏覽器上的連結變成 `product.php?pid=2`，頁面正常。

### 10-6 收緊規則：真人不再被質詢

```text
(http.request.uri.path eq "/product.php" and not starts_with(http.request.uri.query, "pid=") and not cf.client.bot)
```

只有**舊格式**（不是 `pid=` 開頭）的網址才質詢：

| 測試（每次開新的無痕視窗） | 結果 |
| --- | --- |
| 從選單點產品 | 直接進入 |
| 手動輸入舊格式 `product.php?123&pid=2` | 出現質詢 |
| 點 Products 主選單 | 直接進入 |
| 主機每分鐘請求數 | 7 筆（處理前約 3,500） |

規則上線後約擋下 8.4 萬次請求，通過質詢的比例（CSR）為 0%，代表被擋下的都是機器人。**爬蟲確定不再來之前，這條規則不能停用。**

### 10-7 隔天確認（10/15）

```bash
df -h /
sudo sh -c 'ls -lh --time-style=long-iso /www/wwwlogs/' | grep example.com
```

| 項目 | 結果 |
| --- | --- |
| 磁碟使用率 | 48% → 44%（已用 6.1G，剩 7.8G） |
| 10/13 的 access log | 571M 壓縮後 36M |
| 10/14 的 access log | 85M，幾乎都是 01:45 UTC 規則生效前寫的 |
| 10/15 的 access log | 2 小時 275K，約每天 3M，回到 10/6 以前的水準 |
| logrotate | 每天 00:00 輪替，保留份數與壓縮都正常 |

## 11. KindEditor：上傳 API 不用登入就能用（10/14）

### 11-1 先查有沒有被用過（全部唯讀）

查爬蟲時順便搜尋讀取 `$_GET` 的程式，看到 CMS 附帶的 KindEditor 編輯器：`cms/plugin/kindeditor/php/upload_json.php` 和 `file_manager_json.php`。KindEditor 官方範例的 PHP 不檢查登入，舊版也有公開的上傳繞過手法。

```bash
S=/www/wwwroot/example.com
K=$S/cms/plugin/kindeditor/php
sudo sh -c 'zgrep -h "kindeditor" /www/wwwlogs/example.com-access_log*'          # log 裡有沒有人用過
sudo zgrep -c "kindeditor" /root/access_log-recent-2026-10-05.gz
sudo grep -n "session\|login" $K/upload_json.php $K/file_manager_json.php         # 有沒有檢查登入
curl -s https://example.com/cms/plugin/kindeditor/php/file_manager_json.php | head -c 300
sudo find $S -type f \( -name "*.php" -o -name "*.phtml" -o -name "*.php5" \) -mtime -90 -ls   # 90 天內新增/修改的 PHP
sudo find $S -type d -name attached -exec sh -c 'find "$1" -name "*.php*" -ls' _ {} \;         # 上傳目錄裡有沒有 PHP
```

| 檢查 | 結果 |
| --- | --- |
| log（10/5 以後與 10/5 的樣本） | 沒有存取紀錄 |
| 程式是否檢查登入 | 沒有 |
| 未登入打開檔案管理 | HTTP 200，回傳上傳目錄的 JSON 清單 |
| 90 天內新增或修改的 PHP | 只有第 10 節改的兩個檔案 |
| 上傳目錄裡的 PHP | 沒有 |

**結論**：沒有被入侵的跡象，但任何人都能瀏覽和上傳。

### 11-2 用 Cloudflare 封鎖

Apache 看不到訪客真實 IP，沒辦法只放行管理者；前台圖片放在 `/cms/main_category/images/`，也不能擋整個 `/cms/`。後台很少上傳圖片、管理者 IP 也不固定，所以直接封鎖整個目錄：

```text
(starts_with(http.request.uri.path, "/cms/plugin/kindeditor/php/"))
```

動作選**「封鎖」，不是質詢**：一般訪客用不到這個目錄，而人工攻擊可以通過質詢。

| 驗證 | 結果 |
| --- | --- |
| `file_manager_json.php`、`upload_json.php` | 都是 HTTP 403 |
| 主機 log 裡的 kindeditor | 維持部署前的 2 筆，部署後的請求沒有到達主機 |

需要上傳圖片時，到 Cloudflare 把 `kindeditor-block` 改成「已停用」，用完立刻改回「使用中」。10/15 已通知會用後台的同事。

## 12. 寶塔面板：其實已是最新 LTS（10/15）

10/5 看到續簽腳本用 Python 3.7，推測面板很久沒更新。更新前先記錄現況，並手動拍一份快照（手動快照不會自動刪除）：

```bash
sudo /www/server/panel/pyenv/bin/python3 --version     # Python 3.7.9
gcloud compute snapshots create <DISK>-before-bt-update-$(date +%Y%m%d) \
  --source-disk=<DISK> --source-disk-zone=<ZONE> --storage-location=<REGION>
```

面板右上角「更新」顯示「當前已經是最新版本」：穩定版 10.0.2-LTS，發佈於 2025/12/11。**Python 3.7 是這個 LTS 自己內建的**，不是沒更新造成的。

寶塔官網另有「穩定版 12.0.0」，面板內的「更新」只檢查同一條版本線，不會提供 10 → 12 的跨大版本升級。**決定維持 10.x LTS，不升級**：

- 跨兩個大版本，介面、設定檔與內建元件的變動可能比較大。
- 12.0.0 對 Debian 11、PHP 7.4 管理、現有 Apache 設定的相容性未查證。
- 網站能否運作取決於 Apache、PHP、資料庫，不是面板版本；升級好處有限，出錯代價高。

要升的話，先用快照複製一台測試 VM，在上面升級並驗證網站、計畫任務與 PHP 7.4，再決定正式機。

**安全修補的疑慮**：官方[更新日誌](https://docs.bt.cn/update-log/)只列正式版（11.x、13.x，最新 2026-09-21 的 13.1.0），沒有 10.x LTS 和 12.0.0 的條目。正式版在 10.0.2-LTS 之後有幾項面板本身的安全修補，無法確認 LTS 是否也有：

| 版本 | 日期 | 安全相關內容 |
| --- | --- | --- |
| 11.4.0 | 2025-12-16 | 修復 CVE-2025-12914 |
| 11.8.0 | 2026-06-09 | 修復多處介面權限校驗、路徑校驗等安全風險；SSL 設定、匯入包、檔案寫入等場景的安全校驗 |

這些都是面板介面本身的漏洞，必須先連得到面板才能利用。這台的面板只對管理者 IP 開放（第 8 節），是最主要的防線，所以**防火牆限制不能放寬**。短期維持 LTS，但把「面板兩步驟驗證」和「用測試 VM 評估升級到 12.0.0」提高到中優先。

## 13. 排查時踩到的坑

這幾個是指令本身的陷阱，結果看起來合理，其實是錯的：

| 情況 | 原因 | 正確做法 |
| --- | --- | --- |
| `sudo ls /www/wwwlogs/*.log` 顯示找不到檔案 | `*` 由自己的 shell 先展開，一般使用者讀不到該目錄 | `sudo sh -c 'ls /www/wwwlogs/*.log'` |
| `sudo wc -l < $L` 顯示 Permission denied | `<` 由自己的 shell 先開檔，sudo 還沒執行 | `sudo wc -l $L`；`*`、`<`、`>`、`\|` 都是 sudo **之前**處理的 |
| `curl ... \| head; echo $?` 永遠是 0 | `$?` 是管線最後一個指令（head）的結束碼 | 不接管線，改用 `curl -sS -o /dev/null -w "%{http_code}"` |
| grep 多行 JSON 只抓到 `"reason"` 那行，看不到時間 | 只有第一行有時間戳記 | grep 有時間戳記的那行，例如 `error sending to Cloud Logging` |
| awk 比對 `$2 >= "05:29"` 找重啟後的錯誤 | 只比時間沒比日期，前幾天的訊息也會算進去 | 先清空 log 再觀察，或同時比對日期 |
| 看到明文 HTTP 請求就以為沒開「一律使用 HTTPS」 | 開啟後請求一樣會到 Cloudflare，只是回 301 | 用 `curl -sI http://...` 看狀態碼 |
| 以為 Apache 假死而重啟 | 被上面幾個錯誤結果誤導 | 先用不會騙人的指令確認，再動服務 |
| 用 `rm` 刪 log，空間沒釋放 | 檔案還被 Apache 開著 | 用 `truncate -s 0` |
| 寶塔排程每天 `Successful`，憑證卻過期 | `Successful` 只代表腳本跑完 | 直接用 `openssl` 看憑證到期日 |

## 14. 待辦

> 這個網站**只能在 PHP 7.4 執行**，升級 PHP 不是選項。PHP 7.4 已停止官方安全更新，所以重點是「在 7.4 上把外圍防護做緊」。

| 優先 | 項目 |
| --- | --- |
| 中 | 檢查 `$_GET['pid']`、`$_GET['news']`、`$_GET['n']` 是否直接放進 SQL（SQL injection） |
| 中 | 修正 `DB` 的 constructor（改成 `__construct()`，保留 `DB()` 呼叫它）；改完就不必再關掉 `E_DEPRECATED` |
| 中 | 寶塔資料庫備份設定「失敗時通知」（要先設定通知管道） |
| 中 | 外圍防護：Cloudflare WAF managed rules；`php.ini` 的 `disable_functions` 停用 `exec`、`system` 等（先確認網站沒用到）；寶塔開啟 `open_basedir` |
| 中 | 寶塔面板開啟兩步驟驗證（動態口令） |
| 中 | 查 CVE-2025-12914 是否影響 10.0.2-LTS；若影響且 LTS 沒修補，用測試 VM 評估升級 |
| 中 | 用快照建測試 VM，評估升級到 12.0.0 穩定版（驗證網站、計畫任務、PHP 7.4） |
| 中 | 作業系統與 PHP 分開處理：寶塔的 PHP 自行編譯在 `/www/server/php/74`，不依賴 Debian 套件；Debian 11 升級前先拍快照，並確認寶塔支援新版本 |
| 低 | 同一筆 syslog 在 Cloud Logging 出現兩次，確認是否為重複收集 |
| 低 | 寶塔 LTS 內建 Python 3.7.9，等 LTS 新版換掉；可開啟「有更新時提醒我」 |
| 低 | 評估長期方案：PHP 7.4 改放 container、主機升級作業系統；或購買 PHP 7.4 付費延長支援；或改寫網站 |
| 低 | 設定 Cloudflare Authenticated Origin Pulls（防火牆只認 Cloudflare IP，別人透過自己的 Cloudflare 帳號仍可連到主機） |
| 低 | `product.php` 遇到舊格式網址時 301 導回 `?pid=N`，讓搜尋引擎更快換新網址 |
| 低 | 評估用 Cloudflare Access（email 驗證碼）保護 KindEditor，取代手動停用規則 |
| 低 | 爬蟲停止後，再評估 Cloudflare 規則是否保留 |
| 低 | Apache 設定 `mod_remoteip`，log 才看得到訪客真實 IP |
| 低 | 演練一次「從快照建磁碟並換上 VM」的還原流程 |
| 低 | Shielded VM 的安全啟動目前停用；開啟要關機，並確認 kernel module 相容 |
| 低 | 7/7 有一次沒有 shutdown 紀錄的開機，原因未查明 |
| 低 | DMARC 目前是 `p=none`，DNS 上也沒看到 DKIM |
| 低 | 專案只有一個 Owner，建議加一個備援管理者 |

## 15. 延伸閱讀

- [Ops Agent 疑難排解](https://cloud.google.com/stackdriver/docs/solutions/agents/ops-agent/troubleshoot-run-ingestion)
- [Compute Engine 存取範圍與 IAM](https://cloud.google.com/compute/docs/access/service-accounts#accesscopesiam)
- [IAP TCP 轉送的防火牆設定](https://cloud.google.com/iap/docs/using-tcp-forwarding#create-firewall-rule)
- [Cloudflare Origin CA 憑證](https://developers.cloudflare.com/ssl/origin-configuration/origin-ca/)
- [Cloudflare IP 範圍](https://www.cloudflare.com/ips/)
- [PHP 8.0 移除舊式 constructor](https://www.php.net/manual/en/migration80.incompatible.php)
- [logrotate(8)](https://manpages.debian.org/logrotate)、[journald.conf(5)](https://www.freedesktop.org/software/systemd/man/latest/journald.conf.html)
