---
layout: default
title: "FortiGate 110C 讓特定內部電腦用另一個公開 IP 上網（IP Pool）"
date: 2011-04-15
categories: [Network, Fortinet, NAT, Firewall, Blogger 舊文]
permalink: /docs/blogger/network/fortigate-110c-ip-pool-outbound/
last_modified_at: 2026-10-24
---

# FortiGate 110C 讓特定內部電腦用另一個公開 IP 上網（IP Pool）

> **一句話**：先在 IP Pool 建好公司擁有的其他公開 IP，再為那台電腦建立一條專屬的 internal → wan 政策並勾選 **Dynamic IP Pool**，而且這條政策要排在一般上網政策的**前面**。

| 項目 | 內容 |
| --- | --- |
| 適合誰看 | 公司有多個公開 IP，想讓某台電腦（例如要被對方白名單的主機）固定用某個 IP 出去的人 |
| 環境 | FortiGate 110C（FortiOS 4.x） |
| 日期 | 2011-04-15（原文發表於 Blogger，2026-10-24 改寫為新手版） |
| 結論 | ✅ 指定電腦以另一個公開 IP 對外連線 |

## 1. 先認識幾個名詞

| 名詞 | 白話解釋 |
| --- | --- |
| **NAT（來源位址轉換）** | 內網電腦上網時，防火牆把來源 IP 換成公開 IP |
| **IP Pool** | 一組可以拿來做 NAT 的公開 IP |
| **Dynamic IP Pool** | 政策裡的選項：這條政策的流量改用 IP Pool 的 IP 出去，而不是 WAN 介面 IP |
| **政策順序** | 防火牆由上往下比對，比中第一條就停 |

## 2. 流程

```text
① Firewall → Virtual IP → IP Pool：建立公開 IP（每個要用的都建）
② Firewall → Policy：新增 internal → wan 政策
     來源 = 那台電腦、NAT 打勾、Dynamic IP Pool 打勾、選 IP Pool
③ 把這條政策移到一般上網政策的上方
```

## 3. 步驟一：建立 IP Pool

**怎麼做**：**Firewall → Virtual IP → IP Pool → Create New**，把要使用的公開 IP（例如 `<公開 IP 2>`）建立成 IP Pool。

## 4. 步驟二：建立專屬政策

**怎麼做**：**Firewall → Policy**，新增（或編輯）一條 internal → wan 的政策：

| 欄位 | 設定 |
| --- | --- |
| Source | 那台電腦的位址物件 |
| Destination | all |
| Action | ACCEPT |
| NAT | 勾選 |
| **Dynamic IP Pool** | **勾選**，選擇步驟一建立的 IP Pool |

## 5. 步驟三：調整政策順序

**怎麼做**：把這條政策拖到一般「全部內網上網」政策的**上面**。

**為什麼**：如果一般政策在前面，那台電腦的流量會先被它比中，還是用 WAN 介面的 IP 出去。

## 6. 步驟四：確認

**應該看到什麼**：在那台電腦上開「查詢我的 IP」類網站，顯示的是 IP Pool 裡的公開 IP；其他電腦顯示的仍是原本的 WAN IP。

## 7. 常見問題

| 現象 | 怎麼辦 |
| --- | --- |
| 還是用原本的 IP 出去 | 政策順序不對，或 Dynamic IP Pool 沒勾 |
| 勾了之後完全上不了網 | ISP 沒有把該公開 IP 路由給你，或 IP Pool 打錯 |

## 8. 延伸閱讀

- [Fortinet 文件庫](https://docs.fortinet.com/)
- [Blogger 原文](https://kbwangtw.blogspot.com/2011/04/fortigate-110cip.html)
