---
layout: default
title: "PHP2Shell（CVE-2026-109618、109619）：檢查環境有沒有中、怎麼修補"
date: 2026-10-23
categories: [Security, PHP, PVE, GCP]
permalink: /docs/pve/php2shell-check/
last_modified_at: 2026-10-24
---

# PHP2Shell（CVE-2026-109618、109619）：檢查環境有沒有中、怎麼修補

> **一句話**：10/21 公開的兩個 PHP 嚴重漏洞，在網站程式執行前就能觸發、已有實際攻擊。這篇從 node10 一次掃完所有 LXC，只有 LibreNMS 有 PHP，已更新到修補版；對外的 GCP 網站主機是 PHP 7.4（官方沒有修補版），先檢查沒有入侵跡象、套用暫時防護，升級到 8.2 以上待辦。

| 項目 | 內容 |
| --- | --- |
| 適合誰看 | 聽到 PHP 漏洞，想知道自己哪些主機受影響、怎麼判斷修補了沒有的人 |
| 環境 | PVE 三節點的 10 個 LXC（Debian 12／13、Ubuntu 22.04／24.04）；GCP 網站主機（寶塔面板 10.0.2、PHP 7.4） |
| 日期 | 2026-10-23 |
| 結論 | ✅ LXC 只有 LibreNMS 有 PHP，8.4.26 → 8.4.27-1~deb13u1，`validate.php` 全部 OK ✅ GCP 主機沒有入侵跡象 ✅ GCP 暫時防護（關閉 session upload progress）已在 PHP-FPM 生效 ⏸️ GCP 網站升級到 PHP 8.2 以上（10/24 決定暫緩） ⏳ Synology 官方公告 |

## 1. 先認識幾個名詞

| 名詞 | 白話解釋 |
| --- | --- |
| **CVE-2026-109618** | 記憶體不足時處理被中斷，請求資料只初始化了一半 |
| **CVE-2026-109619** | 前一個請求留下的內部狀態沒清掉，同一個工作程序處理下一個請求時被誤用 |
| **PHP-FPM／mod_php／php-cgi** | 讓網站伺服器執行 PHP 的方式；**會處理網頁請求的才是高風險**。只有命令列（CLI）的 PHP 推測風險較低（資料沒有明確說明） |
| **changelog** | 套件的修改紀錄；Debian／Ubuntu 修補時常保留原本的版本號，**看 changelog 有沒有提到 CVE 編號**才準 |
| **stable-security** | Debian 的安全性更新套件庫 |
| **session upload progress** | PHP 顯示「上傳進度」的功能，一般網站很少用；PHP 官方建議的暫時防護是把它關掉 |
| **寶塔面板** | 網站主機管理面板；PHP 裝在 `/www/server/php/<版本>/`，不是 Debian 套件 |

| 官方修補版 | 8.5.12、8.4.27、8.3.36、8.2.35 |
| --- | --- |
| 沒有官方修補 | 7.4、8.0、8.1（只有原始碼的回補），7.3 以前完全沒有 |

## 2. 全貌

```text
列出可能有 PHP 的主機
  ├─ 10 個 LXC ── node10 一次掃描（changelog 有沒有 CVE、有沒有 FPM）
  │                 └─ LibreNMS：未修補 → 快照 → 只升級 php8.4-* → 重啟 FPM → validate
  ├─ GCP 網站主機（對外，最優先）── PHP 7.4 + FPM
  │                 └─ 先查入侵跡象 → 暫時防護 → ⏳ 升級到 8.2 以上
  ├─ PVE、PBS、Windows VM ── 沒有 PHP
  └─ Synology NAS ── ⏳ 看官方公告
```

## 3. 步驟一：一次掃描所有 LXC（只讀取）

在 node10 執行（`pct exec` 只能操作本機的容器，所以 SSH 到三台各跑一次）：

```bash
for h in node10 node11 node12; do
  ssh -o BatchMode=yes root@$h bash -s <<'EOS'
for id in $(pct list | awk 'NR>1 && $2=="running"{print $1}'); do
  r=$(pct exec $id -- sh -c '
    for f in /usr/share/doc/php*-common/changelog.Debian.gz; do
      [ -f "$f" ] || continue
      p=$(basename $(dirname $f))
      echo "  $p $(dpkg-query -W -f="\${Version}" $p 2>/dev/null) 修補紀錄=$(zgrep -c CVE-2026-109618 $f)"
    done
    for s in /usr/sbin/php-fpm* /usr/bin/php-cgi* /usr/lib/apache2/modules/libphp*; do [ -e "$s" ] && echo "  網頁元件：$s"; done
    command -v php >/dev/null && echo "  php -v：$(php -v | head -1)"
  ' 2>/dev/null)
  if [ -n "$r" ]; then echo "== $(hostname) CT$id"; echo "$r"; else echo "-- $(hostname) CT$id 沒有 PHP"; fi
done
EOS
done
```

| 片段 | 意思 |
| --- | --- |
| `zgrep -c CVE-2026-109618 …changelog.Debian.gz` | 1 以上＝已修補，0＝還沒 |
| `php-fpm`、`php-cgi`、`libphp` | 有沒有處理網頁請求的元件 |
| `php -v` | 沒有 changelog 時（第三方套件庫、原始碼安裝）改用版本號對照官方修補版 |

**看到的結果**：10 個容器只有 CT 102（LibreNMS）有 PHP：`php8.4-common 8.4.26-1~deb13u1`、`修補紀錄=0`、有 `/usr/sbin/php-fpm8.4` → **未修補、高風險**（只在內網，但內網與 VPN 的裝置都能在登入前攻擊；LibreNMS 存著所有設備的 SNMP 帳密）。

## 4. 步驟二：更新 LibreNMS 的 PHP

在 CT 102 所在節點執行。先看有沒有修補版：

```bash
pct exec 102 -- apt-get update -qq
pct exec 102 -- apt-cache policy php8.4-fpm | head -4
pct exec 102 -- sh -c 'apt list --upgradable 2>/dev/null | grep -E "^php"'
```

看到的結果：Candidate `8.4.27-1~deb13u1`（`stable-security`），13 個 `php8.4-*` 可升級。

```bash
pct snapshot 102 pre-php2shell --description "Before PHP2Shell fix (php8.4)"
pct exec 102 -- sh -c 'DEBIAN_FRONTEND=noninteractive apt-get -y -o Dpkg::Options::=--force-confold install --only-upgrade "php8.4-*"'
pct exec 102 -- systemctl restart php8.4-fpm
pct exec 102 -- systemctl is-active php8.4-fpm
pct exec 102 -- sh -c 'zgrep -c CVE-2026-109618 /usr/share/doc/php8.4-common/changelog.Debian.gz; php -v | head -1'
pct exec 102 -- su - librenms -s /bin/bash -c "cd /opt/librenms && ./validate.php" | tail -15
```

| 片段 | 意思 |
| --- | --- |
| `--only-upgrade "php8.4-*"` | 只升級已裝的 PHP 套件，縮小變動範圍（另外 17 個非 PHP 套件之後再更新） |
| `--force-confold` | 保留現有 `php.ini` |
| `restart php8.4-fpm` | 一定要重啟，否則還在用記憶體裡的舊程式；網頁只中斷幾秒，poller 不受影響 |

**看到的結果**：`13 upgraded`、`active`、修補紀錄 `1`、`PHP 8.4.27 (built: Oct 21 2026)`；`validate.php` 資料庫、時間、poller、RRD、SNMP 全部 `[OK]`。

還原：`pct rollback 102 pre-php2shell` 再 `pct start 102`。

## 5. 步驟三：GCP 網站主機（對外，最優先）

寶塔面板的 PHP 不是 Debian 套件，直接看每個版本：

```bash
for p in /www/server/php/*/bin/php; do echo "$p：$($p -v | head -1)"; done
ps aux | grep -E "php-fpm: master" | grep -v grep
```

**看到的結果**：只有 `PHP 7.4.33`，PHP-FPM 執行中 → **官方沒有修補版**、7.4 本身 2022 年底就停止支援、對網際網路開放。

### 5-1 先檢查有沒有被入侵（只讀取，要用 root）

一開始用一般帳號跑，`find` 沒有權限、錯誤又被 `2>/dev/null` 隱藏，結果「沒有輸出」不代表沒有。先 `sudo -i`：

```bash
echo "== 網站 PHP 檔總數"; find /www/wwwroot -type f -name "*.php" | wc -l
echo "== 10/19 之後新增或修改的 PHP 檔"; find /www/wwwroot -type f -name "*.php" -newermt "2026-10-19" | head -30
echo "== root 的排程"; crontab -l
echo "== 所有使用者的排程檔"; ls -la /var/spool/cron/crontabs/
echo "== 暫存目錄"; ls -la /tmp /var/tmp /dev/shm | grep -vE "^total|^d" | head -20
echo "== 最耗 CPU 的程式"; ps aux --sort=-%cpu | head -8
```

| 項目 | 結果 | 判讀 |
| --- | --- | --- |
| PHP 檔總數 | 114 | 讀得到網站資料夾，檢查有效 |
| 10/19 之後的 PHP 檔 | 沒有 | 沒有被植入新檔 |
| 排程 | 只有 root 一個寶塔排程（`/www/server/cron/…`，每天 14:00） | `www` 帳號沒有排程 |
| 暫存目錄 | `.panelTask.pl`、`bt.pl`、`php-cgi-74.sock`、`sess_…` | 寶塔面板、PHP、MySQL 的正常檔案 |
| CPU | 寶塔 BT-Task、Google 監控代理、MariaDB | 沒有挖礦之類的程式 |

**沒有入侵跡象**。若看到不認得的新 PHP 檔、`www` 的排程、從陌生網址 `curl`／`wget`，就先停手保留證據。

### 5-2 暫時防護：關閉 session upload progress（root）

```bash
F=/www/server/php/74/etc/php.ini
cp -a $F $F.bak-$(date +%Y%m%d)
sed -i 's/^\s*;\?\s*session.upload_progress.enabled\s*=.*/session.upload_progress.enabled = Off/' $F
grep -n "session.upload_progress.enabled" $F
/etc/init.d/php-fpm-74 reload
/www/server/php/74/sbin/php-fpm -i 2>/dev/null | grep "session.upload_progress.enabled"
curl -s -o /dev/null -w "網站回應：%{http_code}\n" http://127.0.0.1/
```

| 片段 | 意思 |
| --- | --- |
| `sed -i …` | 把第 1512 行 `;session.upload_progress.enabled = On`（註解＝使用預設 On）改成 `Off` |
| `/etc/init.d/php-fpm-74 reload` | 寶塔的 PHP 7.4 服務；一般帳號執行會 `Operation not permitted` 但最後仍印 `done`，要看有沒有錯誤 |
| `php-fpm -i` | **PHP-FPM 實際讀到的值**；不要用 `php -i` |

**看到的結果**：`1512:session.upload_progress.enabled = Off`、`php-fpm -i` 為 `Off => Off`、網站回應 `200`。

**踩到的雷**：`php -i` 一直顯示 `On`，因為寶塔讓命令列 PHP 讀 `php-cli.ini`（`php --ini` 的 `Loaded Configuration File`），PHP-FPM 讀 `php.ini`；網站走 PHP-FPM，所以防護已生效。

這只是**降低風險**，不保證擋住兩個漏洞；更新是唯一完整的解法。

還原：`cp -a /www/server/php/74/etc/php.ini.bak-20261023 /www/server/php/74/etc/php.ini && /etc/init.d/php-fpm-74 reload`。

### 5-3 根本解決：升級到 PHP 8.2 以上（⏸️ 10/24 決定暫緩）

| 步驟 | 內容 | 網站影響 |
| --- | --- | --- |
| 1 | GCP 磁碟快照，或寶塔的網站與資料庫備份 | 無 |
| 2 | 寶塔另外安裝 PHP 8.3／8.4（和 7.4 並存） | 無 |
| 3 | 網站切換到新版，逐頁測試 | 幾秒 |
| 4 | 有問題就在面板切回 7.4 | 幾秒 |
| 5 | 確認沒問題後停用、移除 7.4 | 無 |

開始前要先確認：主機上有幾個網站、各用什麼程式；軟體商店能不能裝 8.3／8.4；網站可以暫停多久測試。

**10/24 決定暫緩，短期內不執行**。在那之前要知道：

| 項目 | 說明 |
| --- | --- |
| 目前的防護 | 只有 5-2 的暫時防護（關閉 session upload progress），**不保證**擋住兩個漏洞 |
| PHP 7.4 本身 | 2022 年底停止支援，之後的其他 PHP 漏洞也不會有修補 |
| 寶塔面板更新 PHP 時 | 可能覆蓋 `php.ini`，更新後用 `php-fpm -i` 確認 `session.upload_progress.enabled` 還是 `Off` |
| 建議的觀察 | 不定期重跑 5-1 的入侵檢查（新增的 PHP 檔、排程、可疑程式） |

## 6. 常見問題

| 現象 | 怎麼辦 |
| --- | --- |
| Ubuntu 修補後 `php -v` 版本沒變 | Ubuntu／Debian 保留原版本號；看 changelog 有沒有 CVE 編號 |
| `find` 沒有輸出就以為沒有可疑檔案 | 一般帳號可能沒權限、錯誤被 `2>/dev/null` 吃掉；先 `sudo -i`，再用檔案總數確認讀得到 |
| 修改 `php.ini` 出現 `Permission denied` | 寶塔的檔案屬於 root，要 `sudo -i` 後再做 |
| 改了 `php.ini`，`php -i` 還是舊值 | 命令列讀 `php-cli.ini`；用 `php-fpm -i` 看網站實際的值 |
| apt 顯示還有其他套件「not upgraded」 | 只升級 PHP 是為了縮小變動範圍，其他套件另外安排 |

## 7. 待辦

- [ ] ⏸️ GCP 網站升級到 PHP 8.2 以上（5-3，10/24 決定暫緩）
- [ ] GCP 主機不定期重跑 5-1 的入侵檢查，並確認暫時防護仍是 `Off`
- [ ] 查 Synology 是否發佈 PHP2Shell 相關公告（DSM、Web Station 的 PHP 套件）
- [ ] LibreNMS 觀察一兩天正常後 `pct delsnapshot 102 pre-php2shell`；另外 17 個非 PHP 套件找時間更新

## 8. 延伸閱讀

- [Tenable：PHP2Shell FAQ](https://www.tenable.com/blog/php2shell-cve-2026-109618-cve-2026-109619-frequently-asked-questions-about-critical-php-remote)
- [Datadog Security Labs：偵測、分析與修補](https://securitylabs.datadoghq.com/articles/php2shell-critical-vulnerabilities-in-php/)
- [watchTowr：已有實際攻擊](https://watchtowr.com/intelligence/php-remote-code-execution-php2shell/)
- [Help Net Security：修補版本](https://www.helpnetsecurity.com/2026/10/21/php2shell-php-vulnerabilities-patched-cve-2026-109618-cve-2026-109619/)
- [computingforgeeks：檢查方式](https://computingforgeeks.com/php2shell-cve-2026-109618-check-patch/)
- [GCP 網站主機磁碟 100%](https://kbwangtw.github.io/IT-Knowledge-Base/docs/gcp/gce-disk-full-log-cleanup-2026-10-05/)：同一台主機
- [Wazuh 維運（二）](https://kbwangtw.github.io/IT-Knowledge-Base/docs/pve/wazuh-lxc-ubuntu2204-operations/)：弱點偵測
