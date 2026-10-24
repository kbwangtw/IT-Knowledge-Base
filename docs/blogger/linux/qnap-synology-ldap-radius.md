---
layout: default
title: "不架 AD 也能統一帳密：QNAP 當 LDAP 伺服器、Synology 加入並提供 RADIUS"
date: 2017-09-15
categories: [NAS, LDAP, RADIUS, Blogger 舊文]
permalink: /docs/blogger/linux/qnap-synology-ldap-radius/
last_modified_at: 2026-10-24
---

# 不架 AD 也能統一帳密：QNAP 當 LDAP 伺服器、Synology 加入並提供 RADIUS

> **一句話**：小公司有兩台不同廠牌的 NAS、帳密各管各的；用 QNAP 內建的 LDAP 伺服器當唯一帳號來源，Synology 以 LDAP 用戶端加入（**加密選 SSL/TLS**、用 LDAP 管理者的 Bind DN 驗證），再用 Synology 的 RADIUS 透過 LDAP 驗證，連無線網路也能用同一組帳密。

| 項目 | 內容 |
| --- | --- |
| 適合誰看 | 沒有 Windows AD、想讓多台 NAS 與 Wi-Fi 共用帳密的小企業與工作室 |
| 環境 | QNAP NAS（LDAP 伺服器）、Synology NAS（LDAP 用戶端 + RADIUS 伺服器） |
| 日期 | 2017-09-15（原文發表於 Blogger，2026-10-24 改寫為新手版） |
| 結論 | ✅ Synology 加入 QNAP LDAP 成功（狀態：已連線）⏳ QNAP 加入 Synology 的方向未測試 |

## 1. 先認識幾個名詞

| 名詞 | 白話解釋 |
| --- | --- |
| **LDAP** | 集中存放帳號密碼的目錄服務，其他設備來這裡查帳密 |
| **Base DN** | 目錄的根，像 AD 的網域名稱；`abc.corp` 寫成 `dc=abc,dc=corp` |
| **Bind DN** | 用戶端連 LDAP 時用的管理者身分，例如 `cn=admin,dc=abc,dc=corp` |
| **RADIUS** | 網路設備（Wi-Fi、VPN）用來驗證使用者帳密的協定 |
| **SSL/TLS** | 加密連線；這裡不選會加入失敗 |

## 2. 為什麼這樣分工

```text
              QNAP：LDAP 伺服器（唯一帳號來源）
                    ▲              ▲
       LDAP 用戶端 │              │ LDAP 驗證
              Synology NAS ── RADIUS 伺服器
                                   ▲
                    無線 AP（WPA2-Enterprise）
```

| 選擇 | 原因 |
| --- | --- |
| LDAP 放在 QNAP | 原作者選擇把帳號建在 QNAP |
| RADIUS 用 Synology | QNAP 的 RADIUS **不支援 LDAP**，得另外建帳號；Synology 的支援，所以用它 |

## 3. 步驟一：在 QNAP 啟用 LDAP 伺服器

**怎麼做**：依 QNAP 官方文件啟用 LDAP 伺服器，設定網域名稱（例如 `abc.corp`）與 LDAP 管理者密碼，在 LDAP 中建立使用者。

**應該看到什麼**：LDAP 伺服器頁顯示 Root DN、使用者 base DN、群組 base DN：

![QNAP LDAP 伺服器設定完成（原作者截圖，網域已遮蔽）]({{ '/docs/blogger/linux/images/qnap-ldap-server.png' | relative_url }})

| 欄位 | 範例 |
| --- | --- |
| Root DN | `cn=admin,dc=abc,dc=corp` |
| 使用者 base DN | `ou=people,dc=abc,dc=corp` |
| 群組 base DN | `ou=group,dc=abc,dc=corp` |

## 4. 步驟二：Synology 加入 LDAP

**怎麼做**：Synology **控制台 → 網域／LDAP → LDAP** → 啟用 LDAP 用戶端：

| 欄位 | 填什麼 |
| --- | --- |
| LDAP 伺服器位址 | **QNAP 的 IP**（`<QNAP IP>`） |
| 加密 | **SSL/TLS**（不選會加入失敗） |
| Base DN | `dc=abc,dc=corp` |

按套用後會要求驗證：

| 欄位 | 填什麼 |
| --- | --- |
| Bind DN | `cn=admin,dc=abc,dc=corp` |
| 密碼 | **在 QNAP 建立 LDAP 時設定的管理者密碼**（不是兩台 NAS 本機的帳密） |

**應該看到什麼**：連線狀態顯示 **已連線**。

## 5. 步驟三：Synology 啟用 RADIUS

**怎麼做**：安裝並開啟 Synology 的 **RADIUS Server** 套件，在驗證來源中勾選 **LDAP**；再到無線 AP 設定 WPA2-Enterprise，RADIUS 伺服器指向 Synology。

**應該看到什麼**：使用者用 LDAP 裡的帳密就能連上 Wi-Fi，也能登入兩台 NAS。

## 6. 常見問題

| 現象 | 怎麼辦 |
| --- | --- |
| Synology 加入 LDAP 失敗 | 加密改 SSL/TLS；Bind DN 格式要正確 |
| 驗證帳密錯誤 | 用的是 LDAP 管理者密碼，不是 NAS 本機 admin 的密碼 |
| Wi-Fi 驗證不過 | RADIUS 驗證來源要勾 LDAP；AP 與 RADIUS 的共用密鑰要一致 |
| 想反過來讓 QNAP 加入 Synology | 原作者未測試 |

## 7. 延伸閱讀

- [QNAP 官方網站（LDAP 伺服器說明）](https://www.qnap.com/)
- [Synology 知識中心：LDAP 用戶端與 RADIUS Server](https://kb.synology.com/)
- [Blogger 原文](https://kbwangtw.blogspot.com/2017/09/qnap-synology-ldap-service-radius.html)
