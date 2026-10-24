---
layout: default
title: "Palo Alto PA-200 第一次安裝：上網、GlobalProtect SSL VPN 與 FTP 對外"
date: 2016-09-06
categories: [Network, Palo Alto, VPN, Firewall, Blogger 舊文]
permalink: /docs/blogger/network/paloalto-pa200-globalprotect/
last_modified_at: 2026-10-24
---

# Palo Alto PA-200 第一次安裝：上網、GlobalProtect SSL VPN 與 FTP 對外

> **一句話**：原作者第一次安裝 PA-200，完成內部上網、GlobalProtect（SSL VPN）遠端連線、外部存取內部 FTP 三件事；詳細步驟當時寫在 Word 檔並分享為 PDF，原始截圖已刪除。

| 項目 | 內容 |
| --- | --- |
| 適合誰看 | 第一次接觸 Palo Alto 防火牆的人 |
| 環境 | Palo Alto PA-200 |
| 日期 | 2016-09-06（原文發表於 Blogger，2026-10-24 改寫為新手版） |
| 結論 | ✅ Internet 正常 ✅ GlobalProtect 可用 ✅ 外部可存取內部 FTP ⏳ PDF 內容尚未搬入 |

## 1. 先認識幾個名詞

| 名詞 | 白話解釋 |
| --- | --- |
| **PA-200** | Palo Alto 的入門款次世代防火牆（已停產） |
| **GlobalProtect** | Palo Alto 的 SSL VPN，使用者在外面用它連回公司 |
| **Zone（區域）** | Palo Alto 用區域（如 trust、untrust）來寫政策，而不是只看介面 |
| **NAT + Security Policy** | 讓外部連到內部伺服器，兩種規則都要設 |

## 2. 完成的項目

```text
內部電腦 ──trust──▶ PA-200 ──untrust──▶ Internet         ✅ 上網
遠端使用者 ──GlobalProtect（SSL VPN）──▶ PA-200 ──▶ 內網   ✅ VPN
外部 ──untrust──▶ PA-200（NAT）──▶ 內部 FTP Server         ✅ 對外服務
```

## 3. 設定文件

原作者的完整步驟在當年分享的 PDF 中（Blogger 原文的短網址連結），本站尚未收錄。

> 原作者註明：第一次安裝這個產品，有些觀念不確定是否正確，但以上三項功能都已實測可用。

## 4. 待辦

- [ ] 從原 PDF 整理步驟，補成新手版（需要原作者提供 PDF 檔）

## 5. 延伸閱讀

- [Palo Alto Networks 官方文件](https://docs.paloaltonetworks.com/)
- [Blogger 原文（含 PDF 連結）](https://kbwangtw.blogspot.com/2016/09/paloalto-pa-200.html)
