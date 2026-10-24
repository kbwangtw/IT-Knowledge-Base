---
layout: default
title: "校園「動態網頁模組系統」常見問題：MySQL 停止、上傳失敗、無法新增"
date: 2011-02-25
categories: [Linux, Web, MySQL, PHP, Blogger 舊文]
permalink: /docs/blogger/linux/school-dynaweb-troubleshooting/
last_modified_at: 2026-10-24
---

# 校園「動態網頁模組系統」常見問題：MySQL 停止、上傳失敗、無法新增

> **一句話**：學校網站（School／DynaClass 班級網頁）的報修大多是三類問題：MySQL 服務停了、上傳資料夾權限不對、資料表欄位設定錯誤；分別重啟服務、調整資料夾權限、修正資料表即可。

| 項目 | 內容 |
| --- | --- |
| 適合誰看 | 維護學校 PHP + MySQL 網站的資訊人員 |
| 環境 | Linux + Apache + PHP + MySQL；動態網頁模組系統（學校網頁 School、班級網頁 DynaClass） |
| 日期 | 2011-02-25（由 Blogger 上 4 篇線上維修紀錄合併，2026-10-24 改寫為新手版） |
| 結論 | ✅ 4 件報修都已處理 |

## 1. 先認識幾個名詞

| 名詞 | 白話解釋 |
| --- | --- |
| **MySQL 服務** | 網站的資料庫；停了，網頁就讀不到資料 |
| **資料夾權限（例如 755、757）** | 三個數字分別代表擁有者、群組、其他人能不能讀（4）、寫（2）、執行（1） |
| **Apache 執行身分** | 網頁程式是用某個系統帳號（例如 `apache` 或 `www-data`）在寫檔，要讓**這個帳號**能寫入 |
| **auto_increment** | 資料表欄位自動產生遞增編號 |
| **config.inc.php** | 系統的設定檔 |

## 2. 問題總覽

| # | 報修現象 | 原因 | 處理 |
| --- | --- | --- | --- |
| 1 | 學校網頁顯示「未連接 MySQL，請確認 MySQL 是否已啟動」 | MySQL 服務停止 | 重啟 MySQL，下載 Log 查原因 |
| 2 | 班級網頁無法上傳照片、公告無法附加檔案 | 上傳資料夾沒有寫入權限 | 調整資料夾權限 |
| 3 | 無法新增檔案／資料夾、新增老師帳號失敗、校園植物網頁連不到 | 資料表欄位沒設 auto_increment、上傳資料夾權限、連結錯誤 | 修正資料表、權限、超連結 |
| 4 | 班級網站上傳壓縮照片失敗 | 設定檔未啟用系統的 zip／unzip，且路徑不對 | 修改 `config.inc.php` |

## 3. 問題一：未連接 MySQL

**怎麼做**：

```text
service mysqld status      # 確認是否停止
service mysqld start       # 啟動
```

**應該看到什麼**：服務狀態為 running，網頁恢復正常。

> 原作者處理後有先下載 MySQL Log 查停止原因，避免再發生（常見原因：磁碟滿、記憶體不足、異常關機）。

## 4. 問題二：照片與公告附件無法上傳

**原因**：網頁程式要寫入的資料夾沒有寫入權限。

| 功能 | 資料夾 |
| --- | --- |
| 班級網頁上傳 | `/var/www/html/DynaClass/data/users/<使用者帳號>/files/` |
| 學校公告附件 | `/var/www/html/School/pub` |

**原作者的做法**：把這兩個資料夾權限設為 `757`（其他人也可寫入）。

**建議做法**（較安全）：把擁有者改成 Apache 的執行帳號，權限維持 755：

```text
chown -R apache:apache /var/www/html/School/pub
chmod 755 /var/www/html/School/pub
```

| 片段 | 意思 |
| --- | --- |
| `chown -R apache:apache` | 擁有者改為 Apache 執行帳號（Debian／Ubuntu 是 `www-data`） |
| `chmod 755` | 擁有者可讀寫執行，其他人只能讀與執行 |

> `757`／`777` 讓任何帳號都能寫入，被入侵時容易被放入惡意檔案，不建議。

## 5. 問題三：無法新增檔案、資料夾或帳號

| 子問題 | 原因 | 處理 |
| --- | --- | --- |
| 目錄無法新增 | `file` 資料表的 `id` 欄位沒有設成 `auto_increment` | 用 phpMyAdmin 或 SQL 把 `id` 改成 auto_increment |
| 上傳出現「複製 Desert.jpg 檔案失敗」 | `/var/www/html/school/data/files/` 無法寫入 | 調整權限為 755（擁有者為 Apache 帳號） |
| 校園植物網頁連不到 | 超連結位址錯誤 | 修改連結 |

修正 auto_increment 的 SQL 範例（**先備份資料庫**）：

```text
ALTER TABLE file MODIFY id INT NOT NULL AUTO_INCREMENT;
```

> 欄位型態請依原本的定義，上面的 `INT` 只是範例。

## 6. 問題四：壓縮照片無法上傳

**原因**：系統預設不使用主機的 zip／unzip 指令，且預設路徑是 `/usr/local/bin`，這台主機的指令在 `/usr/bin`。

**怎麼做**：編輯 `/var/www/html/DynaClass/config.inc.php`（在系統開發者協助下修改）：

```text
$USE_UNIX_COMMAND = 1;               // 預設 0，改 1 使用系統指令
$UNZIP_COMMAND    = '/usr/bin/unzip'; // 預設 /usr/local/bin/unzip
$ZIP_COMMAND      = '/usr/bin/zip';   // 預設 /usr/local/bin/zip
```

> 用 `which zip unzip` 確認你主機上的實際路徑。

## 7. 常見問題

| 現象 | 怎麼辦 |
| --- | --- |
| 改了權限還是不能上傳 | 確認擁有者是 Apache 帳號；SELinux 開啟時還要設定網頁目錄的 SELinux 標籤 |
| MySQL 一直自己停 | 查 MySQL Log 與磁碟空間 |
| 找不到 zip 指令 | 先安裝 `zip`、`unzip` 套件 |

## 8. 延伸閱讀

- [新竹縣網頁寶典系統安裝在 Synology NAS：config.inc 設定](../campus-config-inc-synology/)
- Blogger 原文：[未連接 MySQL](https://kbwangtw.blogspot.com/2011/02/mysqlmysql.html)、[照片與附件無法上傳](https://kbwangtw.blogspot.com/2011/02/blog-post.html)、[無法新增檔案或資料夾](https://kbwangtw.blogspot.com/2011/02/blog-post_25.html)、[壓縮照片無法上傳](https://kbwangtw.blogspot.com/2011/02/blog-post_2380.html)
