---
layout: default
title: "FortiGate 只允許指定外網 IP ping 到 WAN：local-in-policy"
date: 2020-08-28
categories: [Network, Fortinet, Firewall, Blogger 舊文]
permalink: /docs/blogger/network/fortigate-local-in-policy-ping/
last_modified_at: 2026-10-24
---

# FortiGate 只允許指定外網 IP ping 到 WAN：local-in-policy

> **一句話**：一般防火牆政策管不到「連到防火牆本身」的流量；要限制誰能 ping WAN，得用 CLI 的 `local-in-policy`：先放行指定來源，再拒絕其他所有 ICMP，**順序不能反**。

| 項目 | 內容 |
| --- | --- |
| 適合誰看 | 想讓外網只有特定 IP（例如監控主機、管理者）能 ping 防火牆的人 |
| 環境 | FortiGate（原文為 FortiOS 6.x 時期），介面 `wan1` |
| 日期 | 2020-08-28（原文發表於 Blogger，2026-10-24 改寫為新手版） |
| 結論 | ✅ 實測可行；**圖形介面做不到，要用 CLI** |

## 1. 先認識幾個名詞

| 名詞 | 白話解釋 |
| --- | --- |
| **local-in-policy** | 專門管「目的地是防火牆自己」的流量規則，例如 ping WAN、連管理介面 |
| **一般防火牆政策** | 管「穿過」防火牆的流量（內網上網、外網進內部伺服器） |
| **位址物件** | 在防火牆上替某個 IP 取名字，政策裡用名字引用 |
| **ALL_ICMP** | 內建服務物件，代表所有 ICMP（ping 用的協定） |

## 2. 流程

```text
① GUI 建立位址物件（允許 ping 的外網 IP）
② CLI 建立 local-in-policy：
     規則 1：wan1、來源 = 該物件、ICMP → accept
     規則 2：wan1、來源 = all、ICMP → deny
```

## 3. 步驟一：建立位址物件

**怎麼做**：**Policy & Objects → Addresses → Create New**，類型 Subnet，輸入允許的外網 IP（例如 `198.51.100.10/32`），名稱自訂（原文用 `KB_NB`）。

## 4. 步驟二：用 CLI 建立規則

**怎麼做**：開啟防火牆 CLI（GUI 右上角的 CLI Console，或 SSH），依序輸入：

```text
config firewall local-in-policy
    edit 1
        set intf wan1
        set srcaddr "KB_NB"
        set dstaddr "all"
        set action accept
        set service ALL_ICMP
        set schedule always
    next
    edit 2
        set intf wan1
        set srcaddr "all"
        set dstaddr "all"
        set action deny
        set service ALL_ICMP
        set schedule always
    next
end
```

| 片段 | 意思 |
| --- | --- |
| `set intf wan1` | 套用在 wan1 介面 |
| `set srcaddr "KB_NB"` | 來源是剛剛建的位址物件（換成你的名稱） |
| `set action accept／deny` | 放行／拒絕 |
| `set service ALL_ICMP` | 只管 ping 這類 ICMP，其他服務不受影響 |
| 規則 1 在前、規則 2 在後 | 由上往下比對；**先放行、再拒絕**，反過來會全部被擋 |

## 5. 步驟三：確認

| 測試 | 應該看到的結果 |
| --- | --- |
| 從允許的 IP ping WAN | 有回應 |
| 從其他外網 IP ping WAN | 逾時 |
| `show firewall local-in-policy` | 列出 1、2 兩條，順序正確 |

## 6. 常見問題

| 現象 | 怎麼辦 |
| --- | --- |
| GUI 找不到這個設定 | 正常，原作者實測要用 CLI；新版可在 Feature Visibility 開啟「Local In Policy」檢視 |
| 允許的 IP 也 ping 不到 | 規則順序反了；或 wan1 介面本身沒開 PING 管理存取 |
| 管理介面也連不上了 | 規則 2 的 service 不要誤設成 ALL，只擋 ICMP |

## 7. 延伸閱讀

- [Fortinet 文件庫：Local-in policy](https://docs.fortinet.com/)
- [FortiGate 60D 兩廠 Site-to-Site VPN](../fortinet-60d-site-to-site-vpn/)
- [Blogger 原文](https://kbwangtw.blogspot.com/2020/08/ippingfortigatewan.html)
