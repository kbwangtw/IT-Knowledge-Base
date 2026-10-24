---
layout: default
title: "在 Ubuntu Server 12.04 安裝 Moodle 2.7：換鏡像站、LAMP、PHP 升級"
date: 2014-10-20
categories: [Linux, Ubuntu, Moodle, LAMP, Blogger 舊文]
permalink: /docs/blogger/linux/moodle27-ubuntu1204/
last_modified_at: 2026-10-24
---

# 在 Ubuntu Server 12.04 安裝 Moodle 2.7：換鏡像站、LAMP、PHP 升級

> **一句話**：把 apt 來源換成台灣鏡像站、裝好 LAMP，用 PPA 把 PHP 從 5.3 升到 5.5 並加裝 curl、xmlrpc、intl，下載 Moodle 2.7 解壓到網站目錄、建立 moodledata，再用瀏覽器跑安裝精靈。

| 項目 | 內容 |
| --- | --- |
| 適合誰看 | 想自己架 Moodle 線上課程平台的人 |
| 環境 | Ubuntu Server 12.04 64 位元（預設安裝）；Moodle 2.7 |
| 日期 | 2014-10-20（原文發表於 Blogger，2026-10-24 改寫為新手版） |
| 結論 | ✅ 環境準備完成，可進入 Moodle 網頁安裝 |

> Ubuntu 12.04、PHP 5.x、Moodle 2.7 都已停止支援。新安裝請用目前的 Ubuntu LTS 與 Moodle 版本，流程概念相同。

## 1. 先認識幾個名詞

| 名詞 | 白話解釋 |
| --- | --- |
| **Moodle** | 免費開源的線上學習平台 |
| **LAMP** | Linux + Apache + MySQL + PHP，架網站的標準組合 |
| **sources.list** | apt 下載套件的來源清單 |
| **鏡像站** | 國內的套件下載點，比國外快 |
| **PPA** | 第三方套件來源，可裝到比系統預設更新的版本 |
| **moodledata** | Moodle 存放上傳檔案的資料夾，**不能**放在網站目錄底下 |

## 2. 整體流程

```text
① 切換 root → 備份並修改 sources.list（改用台灣鏡像站）→ update／upgrade
② 安裝 LAMP → 設定 Apache ServerName → 重啟
③ 加入 PPA，PHP 5.3 → 5.5；安裝 php5-curl、php5-xmlrpc、php5-intl → 重啟
④ 下載 Moodle 2.7 → 解壓到網站目錄 → 建立 moodledata → 設權限
⑤ 瀏覽器開 http://<伺服器 IP>/moodle 跑安裝精靈
```

## 3. 步驟一：換成台灣鏡像站並更新

```text
sudo -i
cp -a /etc/apt/sources.list /etc/apt/sources.list.bak
vi /etc/apt/sources.list
```

在 vi 裡一次把美國來源換成樹德科大的鏡像站：

```text
:1,$s/us.archive.ubuntu.com/ubuntu.stu.edu.tw/g
```

| 片段 | 意思 |
| --- | --- |
| `cp -a ... .bak` | 先備份，改壞可以還原 |
| `:1,$s/舊/新/g` | vi 的取代指令：第 1 行到最後一行，全部取代 |

```text
apt-get update
apt-get upgrade
```

> 原文第二個指令寫成 `source.list`（少一個 s），正確檔名是 `sources.list`。

## 4. 步驟二：安裝 LAMP

```text
apt-get install lamp-server^
vi /etc/apache2/conf.d/fqdn
```

在 `fqdn` 檔案中加入一行 `ServerName localhost`，存檔後：

```text
service apache2 restart
```

| 片段 | 意思 |
| --- | --- |
| `lamp-server^` | 結尾的 `^` 表示安裝整組 LAMP 套件 |
| `ServerName localhost` | 消除 Apache 啟動時「無法判斷主機名稱」的警告 |

## 5. 步驟三：升級 PHP 並安裝 Moodle 需要的模組

```text
apt-get install python-software-properties
add-apt-repository ppa:ondrej/php5
apt-get update
apt-get install php5
apt-get install php5-curl php5-xmlrpc php5-intl
service apache2 restart
```

| 套件 | Moodle 用來做什麼 |
| --- | --- |
| `php5-curl` | 連外下載、外掛更新 |
| `php5-xmlrpc` | 網路服務與外掛溝通 |
| `php5-intl` | 多國語系 |

## 6. 步驟四：下載 Moodle 並準備資料夾

```text
cd /var/www
wget https://download.moodle.org/stable27/moodle-2.7.tgz
tar zxvf moodle-2.7.tgz
cp -rf /var/www/moodle /var/www/html/moodle
mkdir /var/www/moodledata
chown -R www-data:www-data /var/www/moodledata
chown -R www-data /var/www/html/moodle
```

| 片段 | 意思 |
| --- | --- |
| `moodledata` 放在 `/var/www` 而非 `html` 底下 | 避免上傳的檔案能被直接從網址存取 |
| `chown www-data` | 讓 Apache 能寫入；網站目錄若不給寫入權，安裝時要手動把精靈產生的 `config.php` 存進 moodle 目錄 |

> 原文對 moodledata 使用 `chmod 777`（所有人可寫），**不安全**；這裡改成只把擁有者設為 `www-data`。

> 原文原本規劃先手動建資料庫，後來劃掉不採用；資料庫可以在安裝精靈中設定。

## 7. 步驟五：網頁安裝

**怎麼做**：瀏覽器開 `http://<伺服器 IP>/moodle`，依精靈選語言、確認路徑（資料目錄填 `/var/www/moodledata`）、填資料庫連線資訊，系統檢查通過後開始安裝。

## 8. 常見問題

| 現象 | 怎麼辦 |
| --- | --- |
| 精靈說缺少 PHP 擴充 | 安裝對應的 `php5-*` 套件並重啟 Apache |
| 無法寫入 config.php | 給 moodle 目錄寫入權，或手動建立 config.php |
| 資料目錄無法寫入 | `moodledata` 擁有者要是 `www-data` |
| `apt-get update` 很慢 | 確認已換成台灣鏡像站 |

## 9. 延伸閱讀

- [Moodle 官方安裝文件](https://docs.moodle.org/en/Installing_Moodle)
- [Blogger 原文](https://kbwangtw.blogspot.com/2014/10/install-moodle-271-on-ubuntu-server-1204.html)
