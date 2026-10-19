---
layout: default
title: "一次檢查並統一所有 LXC 的時區"
date: 2026-10-19
categories: [PVE, LXC]
permalink: /docs/pve/pve-lxc-timezone/
last_modified_at: 2026-10-19
---

# 一次檢查並統一所有 LXC 的時區

> **一句話**：PVE 節點是台灣時間，但 10 台 LXC 裡有 7 台還是 UTC，容器裡的日誌、排程都差 8 小時。這篇從 node10 一次查完全部容器，先確認排程不會因此撞上備份時段，再統一改成 Asia/Taipei，最後處理 LibreNMS 的 PHP 與 MariaDB。

| 項目 | 內容 |
| --- | --- |
| 適合誰看 | 容器裡的時間和節點差 8 小時、想一次檢查所有 LXC 的人 |
| 環境 | PVE 9.2 三節點（node10～12）；10 台 LXC（Debian／Ubuntu） |
| 日期 | 2026-10-19 |
| 結論 | ✅ 10 台 LXC 都是 Asia/Taipei、`+0800` ✅ LibreNMS 的 PHP 與 MariaDB 時間一致 ⏳ MariaDB 重啟後的 poller 恢復狀態待確認 ⏳ Graylog 下次重啟才完全套用 |

## 1. 先認識幾個名詞

| 名詞 | 白話解釋 |
| --- | --- |
| **時間** | 時鐘本身。LXC 容器**和宿主機共用同一個 kernel 時鐘**，不會自己跑快跑慢，只要節點的 NTP 正常，容器的時間就正確 |
| **時區** | 同一個時間要「顯示成幾點」。**每個容器各自設定**，存在容器裡的 `/etc/localtime` |
| **UTC** | 世界標準時間；台灣時間 = UTC + 8 小時 |
| **`/etc/localtime`** | 指向時區檔的連結，系統和大部分程式看這個 |
| **`/etc/timezone`** | 舊式的時區文字檔（Debian／Ubuntu）；有些程式（例如 Java）會優先讀它 |
| **cron／systemd timer** | 排程工具；寫的是「容器時區的幾點」，所以改時區會讓固定時間的排程移位 |
| **`pct exec`** | 在 PVE 節點上對某個容器執行指令；只能在容器所在的節點上用 |

## 2. 全貌

```text
node10／node11／node12（Asia/Taipei，NTP 同步）
  │ 共用同一個時鐘
  ├─ CT 100 AdGuard    UTC → Asia/Taipei
  ├─ CT 101 Pihole     UTC → Asia/Taipei
  ├─ CT 102 librenms   UTC → Asia/Taipei ＋ PHP 時區 ＋ MariaDB 重啟
  ├─ CT 103 IPAM       UTC → Asia/Taipei
  ├─ CT 105 Graylog    UTC → Asia/Taipei（Java 下次重啟才套用）
  ├─ CT 110 ProxCenter UTC → Asia/Taipei
  ├─ CT 113 ai         UTC → Asia/Taipei
  └─ CT 109、112、114  原本就是 Asia/Taipei

步驟：① 盤點時區 → ② 盤點固定時間的排程 → ③ 改時區 → ④ LibreNMS 的 PHP 與 MariaDB → ⑤ 再檢查
```

## 3. 步驟一：一次查所有 LXC 的時區（只讀取）

**做什麼**：從 node10 取得叢集所有容器清單，逐台進去看時區和目前時間；順便看三台節點本身的時區與 NTP。

**怎麼做**（node10，存成腳本方便以後再查）：

```bash
cat > /root/check-ct-tz.sh <<'EOF'
#!/bin/bash
# 列出叢集所有 LXC 的時區與目前時間（只讀取）
echo "===== 節點本身 ====="
for n in node10 node11 node12; do
  ssh -o BatchMode=yes -o ConnectTimeout=5 root@$n \
    'printf "%-8s TZ=%-16s %s  NTP同步=%s\n" "$(hostname)" "$(timedatectl show -p Timezone --value)" "$(date "+%F %T %z")" "$(timedatectl show -p NTPSynchronized --value)"'
done

echo
echo "===== LXC 容器 ====="
printf "%-6s %-8s %-20s %-18s %s\n" "CTID" "節點" "名稱" "時區" "容器內時間"
pvesh get /cluster/resources --type vm --output-format json | python3 -c '
import json,sys
for r in sorted(json.load(sys.stdin), key=lambda x: x["vmid"]):
    if r.get("type") == "lxc":
        print(r["vmid"], r["node"], r.get("name","-"), r.get("status","-"))
' | while read -r id node name status; do
  if [ "$status" != "running" ]; then
    printf "%-6s %-8s %-20s %s\n" "$id" "$node" "$name" "（未執行，略過）"
    continue
  fi
  out=$(ssh -o BatchMode=yes -o ConnectTimeout=5 root@$node "pct exec $id -- sh -c '
    tz=\$(cat /etc/timezone 2>/dev/null || readlink /etc/localtime 2>/dev/null | sed \"s|.*/zoneinfo/||\")
    echo \"\${tz:-（未設定，等於UTC）}|\$(date \"+%F %T %z\")\"'" 2>&1 < /dev/null)
  printf "%-6s %-8s %-20s %-18s %s\n" "$id" "$node" "$name" "${out%%|*}" "${out#*|}"
done
EOF
chmod 700 /root/check-ct-tz.sh
/root/check-ct-tz.sh
```

| 片段 | 意思 |
| --- | --- |
| `pvesh get /cluster/resources --type vm` | 從叢集取得所有 VM／CT 和它們在哪個節點，不用自己記 |
| `r.get("type") == "lxc"` | 只挑容器 |
| `ssh root@$node "pct exec …"` | `pct exec` 只能在容器所在的節點執行，所以先 SSH 過去（叢集節點之間本來就有 root 金鑰互信） |
| `cat /etc/timezone \|\| readlink /etc/localtime` | 兩種時區設定都試 |
| `date "+%F %T %z"` | `%z` 印出 `+0800` 或 `+0000` |
| `< /dev/null` | 不讓 ssh 吃掉迴圈的輸入；不加的話只會跑第一個容器 |

**看到的結果**（改之前）：

| 範圍 | 結果 |
| --- | --- |
| node10～12 | 都是 `Asia/Taipei`、`+0800`、`NTP同步=yes` |
| CT 109 wireguard、112 wazuh、114 grafana | `Asia/Taipei`、`+0800` |
| CT 100、101、102、103、105、110、113 | `Etc/UTC`、`+0000`（例如節點 15:46 時容器顯示 07:46） |

## 4. 步驟二：先盤點固定時間的排程（只讀取）

**為什麼要先做**：cron 和 systemd timer 是照**容器的時區**算時間。改成台灣時間後，固定時間的排程會**提早 8 小時**執行（例如 `0 2 * * *` 從台灣 10:00 變成 02:00），可能撞上 21:00～03:00 的 PVE／PBS 備份時段。每 N 分鐘一次的排程不受影響。

**怎麼做**（node10）：

```bash
cat > /root/check-ct-sched.sh <<'EOF'
#!/bin/bash
# 列出指定 LXC 裡「固定時間」的 cron 與 systemd timer（只讀取）
for id in 100 101 102 103 105 110 113; do
  node=$(pvesh get /cluster/resources --type vm --output-format json | python3 -c "import json,sys; print([r['node'] for r in json.load(sys.stdin) if r['vmid']==$id][0])")
  echo "=================== CT $id（$node）==================="
  ssh -o BatchMode=yes root@$node "pct exec $id -- sh -c '
    echo \"--- cron（排除每 N 分鐘、每小時的）---\"
    for f in /etc/crontab /etc/cron.d/* /var/spool/cron/crontabs/*; do
      [ -f \"\$f\" ] || continue
      grep -vE \"^\s*(#|\$|[A-Z_]+=)\" \"\$f\" | awk -v f=\"\$f\" \"\\\$2 ~ /^[0-9,]+\\\$/ {print f\\\": \\\"\\\$0}\"
    done
    echo \"--- systemd timer（OnCalendar）---\"
    command -v systemctl >/dev/null && systemctl list-timers --all --no-pager 2>/dev/null | grep -vE \"^\$|timers listed\" | head -20
  '" < /dev/null
done
EOF
chmod 700 /root/check-ct-sched.sh
/root/check-ct-sched.sh
```

| 片段 | 意思 |
| --- | --- |
| `/etc/crontab /etc/cron.d/* /var/spool/cron/crontabs/*` | 系統與各使用者的 cron 都看 |
| `$2 ~ /^[0-9,]+$/` | 只挑「小時」欄位是固定數字的排程 |
| `systemctl list-timers --all` | systemd timer 的下次／上次執行時間 |

**看到的結果與評估**：

| 容器 | 服務自己的排程 | 改之前（台灣時間） | 改之後 | 評估 |
| --- | --- | --- | --- | --- |
| 101 Pihole | `pihole updateGravity`（每週日） | 週日 11:20 | 週日 03:20 | ✅ 備份時段剛結束 |
| 101 Pihole | `pihole flush`（每天） | 08:00 | 00:00 | ✅ 紀錄在午夜切開更合理 |
| 102 librenms | `/opt/librenms/daily.sh` | 08:19 | 00:19 | ⚠️ 落在備份時段內；是輕量維護，推測影響小，先不改（見待辦） |
| 103 IPAM | `jt-ipam-backup.timer` | 11:31 | 03:31 | ✅ 備份時段之後 |
| 103 IPAM | geoip／recog／oui 更新 | 白天 | 凌晨 04～05 點 | ✅ |
| 全部 | `cron.daily`、`logrotate`、`apt-daily-upgrade`、`e2scrub` 等系統內建 | 下午 | 清晨／凌晨 | ✅ |

結論：沒有會造成問題的衝突。

## 5. 步驟三：7 台一次改成 Asia/Taipei

**怎麼做**（node10）：

```bash
for id in 100 101 102 103 105 110 113; do
  node=$(pvesh get /cluster/resources --type vm --output-format json | python3 -c "import json,sys; print([r['node'] for r in json.load(sys.stdin) if r['vmid']==$id][0])")
  echo "== CT $id（$node）"
  ssh -o BatchMode=yes root@$node "pct exec $id -- sh -c '
    if command -v timedatectl >/dev/null && timedatectl set-timezone Asia/Taipei 2>/dev/null; then :; else
      ln -sf /usr/share/zoneinfo/Asia/Taipei /etc/localtime && echo Asia/Taipei > /etc/timezone; fi
    (systemctl restart cron 2>/dev/null || systemctl restart crond 2>/dev/null || true)
    echo \"時區=\$(cat /etc/timezone 2>/dev/null)  時間=\$(date \"+%F %T %z\")\"'" < /dev/null
done
```

| 片段 | 意思 |
| --- | --- |
| `timedatectl set-timezone Asia/Taipei` | 標準做法；改 `/etc/localtime`，systemd timer 會自動照新時區重算 |
| `ln -sf …` | 沒有 timedatectl 時的備用做法 |
| `systemctl restart cron` | cron 只在啟動時讀時區，要重啟才會照新時區排程 |

這一步**不重啟服務本身**，服務不中斷；已在執行的程式要等下次重啟才完全套用。

**看到的結果**：7 台時間都變成 `+0800`。其中 105、113 的 `時區=` 還顯示 `Etc/UTC`：`timedatectl` 只改了 `/etc/localtime`，舊式的 `/etc/timezone` 沒跟著改（其他 5 台沒有這個檔案，顯示空白）。Java 在 Debian／Ubuntu 上會優先讀 `/etc/timezone`（推測，依 OpenJDK 行為），Graylog 是 Java，所以一起修正：

```bash
for id in 105 113; do
  ssh root@node10 "pct exec $id -- sh -c 'echo Asia/Taipei > /etc/timezone; echo \"CT $id：\$(cat /etc/timezone)\"'" < /dev/null
done
```

看到的結果：`CT 105：Asia/Taipei`、`CT 113：Asia/Taipei`。

## 6. 步驟四：LibreNMS 的 PHP 與 MariaDB

**為什麼**：LibreNMS 要求系統、PHP、資料庫三者時區一致。檢查發現 `php.ini 沒有設定 date.timezone`（PHP 會預設 UTC）。

```bash
ssh root@node10 "pct exec 102 -- sh -c 'grep -H \"^date.timezone\" /etc/php/*/*/php.ini 2>/dev/null || echo \"php.ini 沒有設定 date.timezone\"'" < /dev/null
```

**① PHP 改成 Asia/Taipei**（fpm 給網頁用、cli 給排程用，兩份都改；重啟 php-fpm 時網頁中斷幾秒）：

```bash
ssh root@node10 "pct exec 102 -- sh -c '
  for f in /etc/php/*/fpm/php.ini /etc/php/*/cli/php.ini; do
    [ -f \"\$f\" ] || continue
    cp -a \"\$f\" \"\$f.bak-20261019\"
    sed -i \"s|^;\\?date.timezone *=.*|date.timezone = Asia/Taipei|\" \"\$f\"
    grep -H \"^date.timezone\" \"\$f\"
  done
  systemctl restart \$(systemctl list-units --type=service --no-legend | awk \"/php.*fpm/ {print \\\$1}\")
  su - librenms -s /bin/bash -c \"cd /opt/librenms && ./validate.php\" 2>&1 | grep -iE \"time|zone|FAIL|WARN\"
'" < /dev/null
```

看到的結果：兩份 `php.ini` 都是 `date.timezone = Asia/Taipei`（PHP 8.4），但 `validate.php` 回報：

```text
[FAIL]  Time between this server and the mysql database is off
 Mysql time 2026-10-19 07:54:55
 PHP time 2026-10-19 15:54:55
```

**② 重啟 MariaDB**：MariaDB 只在啟動時讀一次系統時區，要重啟才會變成台灣時間（停約 10～30 秒，LibreNMS 網頁暫時打不開；RRD 圖表用 epoch，不受影響）：

```bash
ssh root@node10 "pct exec 102 -- sh -c '
  systemctl restart mariadb && sleep 3
  systemctl is-active mariadb
  mysql -N -e \"SELECT NOW(), @@system_time_zone, @@time_zone\"
  su - librenms -s /bin/bash -c \"cd /opt/librenms && ./validate.php\" 2>&1 | grep -iE \"time|zone|FAIL|WARN\" || echo \"validate：沒有時區相關的問題\"
'" < /dev/null
```

| 片段 | 意思 |
| --- | --- |
| `@@system_time_zone` | MariaDB 啟動時讀到的系統時區，應為 `CST`（台北） |
| `@@time_zone` | 連線用的時區，`SYSTEM` 表示跟著系統 |

看到的結果：`active`、`2026-10-19 15:55:54  CST  SYSTEM`、`[OK] MySQL and PHP time match`。同時出現 `[FAIL] The poller is not running. No poller ran in the last 300 seconds.` 和 `[FAIL] No active python wrapper pollers found`；推測是重啟 MariaDB 時剛好打斷那一輪輪詢，恢復狀態列在待辦。

## 7. 步驟五：再檢查一次

```bash
/root/check-ct-tz.sh
```

**看到的結果**：

| CT | 名稱 | 時區 | 時間 |
| --- | --- | --- | --- |
| 100 | AdGuard | Asia/Taipei | `+0800` |
| 101 | Pihole | Asia/Taipei | `+0800` |
| 102 | librenms | Asia/Taipei | `+0800` |
| 103 | IPAM | Asia/Taipei | `+0800` |
| 105 | Graylog | Asia/Taipei（修正 `/etc/timezone` 後） | `+0800` |
| 109 | wireguard | Asia/Taipei | `+0800` |
| 110 | ProxCenter | Asia/Taipei | `+0800` |
| 112 | wazuh | Asia/Taipei | `+0800` |
| 113 | ai | Asia/Taipei（修正 `/etc/timezone` 後） | `+0800` |
| 114 | grafana | Asia/Taipei | `+0800` |

## 8. 常見問題

| 現象 | 怎麼辦 |
| --- | --- |
| 時間已經是 `+0800`，但 `/etc/timezone` 還寫 `Etc/UTC` | `timedatectl` 只改 `/etc/localtime`；`echo Asia/Taipei > /etc/timezone`，Java 程式才會讀到新時區 |
| `while read` 迴圈裡用 ssh，只跑了第一台 | ssh 會吃掉迴圈的標準輸入；ssh 指令後面加 `< /dev/null` |
| LibreNMS `validate.php`：`Time between this server and the mysql database is off` | MariaDB 還在用舊時區；`systemctl restart mariadb` |
| LibreNMS 時間差 8 小時，`php.ini` 沒有 `date.timezone` | PHP 預設 UTC；fpm 和 cli 兩份 `php.ini` 都設 `date.timezone = Asia/Taipei`，重啟 php-fpm |
| 改時區後，排程的執行時間變了 | 固定時間的 cron／timer 照新時區算，會提早 8 小時；改之前先用步驟二盤點 |
| 改了時區，服務的 log 還是 UTC | 已在執行的程式要重啟才會套用新時區 |
| 容器的時間（不是時區）不對 | 容器共用節點的時鐘，去查節點的 NTP：`timedatectl show -p NTPSynchronized --value` |

## 9. 待辦

- [ ] 確認 LibreNMS poller 在 MariaDB 重啟後已恢復：`pollers` 表的 `last_polled` 有 16:00 之後的時間，`validate.php` 沒有 poller FAIL
- [ ] CT 105 Graylog 下次重啟 `graylog-server`（或重開容器）時，確認 Graylog 自己的 log 時間是台灣時間；重啟會漏收幾十秒 UDP 日誌，排在套件更新時順便做
- [ ] LibreNMS `daily.sh` 現在在 00:19（備份時段內）執行；需要時把 `/etc/cron.d/librenms` 的小時欄位 `0` 改成 `5`（移到 05:19）
- [ ] 確認 LibreNMS 改時區前寫入的舊事件紀錄顯示時間是否差 8 小時（未確認；若資料庫欄位是 DATETIME，舊紀錄會以 UTC 數字顯示）
- [ ] 以後新建 LXC 時，建好就設 `timedatectl set-timezone Asia/Taipei`；定期用 `/root/check-ct-tz.sh` 檢查
- [ ] 約一週後刪除 `/etc/php/8.4/*/php.ini.bak-20261019`

## 10. 延伸閱讀

- [把 PVE、PBS 與 NAS 的日誌集中到 Graylog（一）](https://kbwangtw.github.io/IT-Knowledge-Base/docs/pve/proxmox-graylog-syslog-pipeline-sop/)：11-1 Graylog 顯示時區（和容器系統時區是兩回事）
- [Graylog 告警與監控（二）](https://kbwangtw.github.io/IT-Knowledge-Base/docs/pve/graylog-alerts-monitoring/)：告警信裡的 `+08:00` 是時區標記（第 10 節）
- [Ceph 出現 BlueStore 慢操作告警](https://kbwangtw.github.io/IT-Knowledge-Base/docs/pve/ceph-bluestore-slow-op-backup-schedule/)：PVE／PBS 備份時段
- [LibreNMS 官方安裝文件](https://docs.librenms.org/Installation/Install-LibreNMS/)：PHP `date.timezone` 與系統時區要一致
- [systemd timedatectl](https://www.freedesktop.org/software/systemd/man/latest/timedatectl.html)
