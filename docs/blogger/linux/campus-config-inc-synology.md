---
layout: default
title: "新竹縣網頁寶典系統（Campus）安裝在 Synology NAS：config.inc 設定"
date: 2011-04-21
categories: [Linux, Web, PHP, Synology, Blogger 舊文]
permalink: /docs/blogger/linux/campus-config-inc-synology/
last_modified_at: 2026-10-24
---

# 新竹縣網頁寶典系統（Campus）安裝在 Synology NAS：config.inc 設定

> **一句話**：網頁寶典系統的安裝方式和 School、DynaClass 差不多，裝在 Synology NAS 上時，`config.inc` 要特別改資料庫帳密、網址與 NAS 的實體路徑（`/volume1/web/...`）；驗證碼在 NAS 上一直無法顯示，最後先關閉 CAPTCHA。

| 項目 | 內容 |
| --- | --- |
| 適合誰看 | 要把 PHP 校園系統裝在 Synology NAS 的人 |
| 環境 | Synology NAS（Web Station + MySQL）；網頁寶典系統（Campus） |
| 日期 | 2011-04-21（原文發表於 Blogger，2026-10-24 改寫為新手版） |
| 結論 | ✅ 安裝完成 ⏳ 驗證碼（CAPTCHA）未解決，暫時關閉 |

## 1. 先認識幾個名詞

| 名詞 | 白話解釋 |
| --- | --- |
| **Web Station** | Synology 的網站伺服器功能，網站檔案放在 `/volume1/web/` |
| **config.inc** | 系統設定檔，資料庫、網址、路徑都在這裡設定 |
| **CAPTCHA（驗證碼）** | 登入時要輸入的圖形驗證碼，防止機器人 |

## 2. config.inc 要改的地方

| 設定 | 說明 | 範例 |
| --- | --- | --- |
| `$DB_HOSTNAME` | 資料庫主機；Apache 與 MySQL 在同一台就填 localhost | `'localhost'` |
| `$USE_DB` | 資料庫名稱（先用 phpMyAdmin 建好空資料庫） | `'campus'` |
| `$DB_USERNAME` | 資料庫帳號，**不要用 root**，另建專用帳號 | `'<資料庫帳號>'` |
| `$DB_PASSWD` | 資料庫密碼 | `'<資料庫密碼>'` |
| `$INSTALL_PASSWD` | 第一次安裝用的密碼，**安裝完務必更換** | `'<安裝密碼>'` |
| `$SELF_URL` | 系統網址 | `'http://<IP 或網域>/campus/'` |
| `$SELF_PLACE` | 系統在 NAS 上的實體路徑 | `'/volume1/web/campus/'` |
| `$USE_CAPTCHA` | 是否使用驗證碼 | `0`（關閉） |

> 設定檔註明：系統管理者帳密預設為 `admin`，建立好資料庫並執行 `install.php` 後**一定要立刻修改**。

## 3. 驗證碼無法顯示

**現象**：不論 NAS 怎麼設定，登入頁的驗證碼都不出現。

**處理**：依系統開發者建議，先把 `$USE_CAPTCHA` 設為 `0` 關閉驗證碼。

> 推測原因是 NAS 的 PHP 缺少繪圖模組（GD），未確認。關閉驗證碼會降低防暴力破解能力，建議另外限制登入來源或改用強密碼。

## 4. 常見問題

| 現象 | 怎麼辦 |
| --- | --- |
| 網頁開起來找不到檔案 | `$SELF_PLACE` 路徑要是 NAS 的 `/volume1/web/...`，並以 `/` 結尾 |
| 連不上資料庫 | 確認 NAS 的 MySQL（MariaDB）已啟用、帳密與資料庫名稱正確 |
| 驗證碼空白 | 確認 PHP 有啟用 GD 擴充；或暫時關閉 CAPTCHA |

## 5. 延伸閱讀

- [校園「動態網頁模組系統」常見問題](../school-dynaweb-troubleshooting/)
- [Blogger 原文](https://kbwangtw.blogspot.com/2011/04/configinc.html)
