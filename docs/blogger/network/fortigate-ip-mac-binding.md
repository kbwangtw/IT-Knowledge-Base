---
layout: default
title: "FortiGate IP/MAC 綁定（摘要與原文連結）"
date: 2021-09-02
categories: [Network, Fortinet, Firewall, Blogger 舊文, 轉貼摘要]
permalink: /docs/blogger/network/fortigate-ip-mac-binding/
last_modified_at: 2026-10-30
---

# FortiGate IP/MAC 綁定（摘要與原文連結）

> **一句話**：IP/MAC 綁定讓 FortiGate 檢查「這個 IP 是不是由指定的那張網卡送出」，對不上就擋；通常搭配 DHCP 保留位址一起設定。

| 項目 | 內容 |
| --- | --- |
| 適合誰看 | 想限制內網只有登記過的電腦才能上網的人 |
| 性質 | **轉貼摘要**：原文為他人撰寫，這裡用自己的話整理重點與指令（2026-10-30 補上指令，原文未註明 FortiOS 版本） |
| 日期 | 2021-09-02（原轉貼於 Blogger，2026-10-24 改為摘要） |

## 1. 先認識幾個名詞

| 名詞 | 白話解釋 |
| --- | --- |
| **MAC 位址** | 網卡出廠時的硬體編號 |
| **IP/MAC 綁定（Binding）** | 把 IP 和 MAC 配成一對，防火牆只放行配對正確的封包 |
| **DHCP 保留位址（Reserved address）** | 讓 DHCP 永遠發同一個 IP 給同一張網卡 |

## 2. 重點整理

```text
① DHCP 保留位址（固定 IP 的設備可略過）
② 建 IP/MAC 綁定表
③ 開啟防火牆的綁定檢查（出外網、連防火牆本身、未登記主機要不要擋）
④ 在內網介面啟用 IP/MAC 檢查
```

- 四件事都在 FortiOS CLI 完成；第 ④ 步沒做，前面設了也不會檢查。
- 第 ④ 步的介面名稱要依實際接線（例如 `internal` 或 `internal1`）。

## 3. 指令（依原文整理）

以下 IP、MAC、名稱都是範例，請換成自己的設備。

### ① DHCP 保留位址

做什麼：讓這台電腦每次都從 DHCP 拿到同一個 IP。原文建議就算不做綁定，也先做這步，寫防火牆 Policy 時比較好指定對象。

```text
config system dhcp reserved-address
    edit <設備名稱>
        set ip 192.0.2.100
        set mac <MAC 位址>
    next
end
```

### ② IP/MAC 綁定表

做什麼：登記「哪個 IP 配哪張網卡」。`edit` 後面用數字編號。

```text
config firewall ipmacbinding table
    edit 1
        set ip 192.0.2.100
        set mac <MAC 位址>
        set name <設備名稱>
        set status enable
    next
end
```

### ③ 開啟綁定檢查

```text
config firewall ipmacbinding setting
    set bindthroughfw enable
    set bindtofw enable
    set undefinedhost block
end
```

| 片段 | 意思 |
| --- | --- |
| `bindthroughfw enable` | 檢查「穿過防火牆」的連線（例如上外網） |
| `bindtofw enable` | 檢查「連到防火牆本身」的連線（例如管理介面、ping 防火牆） |
| `undefinedhost block` | 綁定表裡沒登記的主機一律擋掉 |

### ④ 在內網介面啟用

```text
config system interface
    edit internal
        set ipmac enable
    next
end
```

應該看到什麼：已登記的電腦照常上網；把某台電腦的 IP 手動改成別人的，或拿一台沒登記的電腦接上，就連不出去。（原文沒有附驗證畫面，這是依設定推論的預期結果。）

## 4. 原文提醒的注意事項（摘要）

| 注意事項 | 說明 |
| --- | --- |
| 改 IP 時機 | 最好等使用者關機後再改，讓設備重新拿 IP；不能停機就要小心 IP 衝突 |
| DHCP 範圍 | 有保留表，陌生電腦仍可能從 DHCP 拿到 IP，要控制發放範圍 |
| 同網段伺服器 | 綁定只管經過防火牆的流量；同網段的伺服器，使用者自己設 IP 仍連得到 |

## 5. 常見問題

| 現象 | 怎麼辦 |
| --- | --- |
| 前三步都設了，還是沒有擋 | 檢查第 ④ 步：介面名稱是不是實際接內網的那一個 |
| 新電腦接上就上不了網 | 這是 `undefinedhost block` 的效果；先在 ② 綁定表登記 |
| `set undefinedhost block` 打了沒報錯，但設定沒寫進去 | 原文留言區有人（2025 年）回報這個狀況，作者沒有回覆，**未確認**原因；推測和 FortiOS 版本差異有關，請以該版本的官方 CLI 參考為準 |
| 想解除綁定 | 原文沒有說明。推測把第 ④ 步改成 `set ipmac disable` 即可停止檢查（**未實測**） |

## 6. 延伸閱讀

- [原文（Ivan IT' Notes，他人撰寫）](http://it-ivan.blogspot.com/2011/08/fortigate-ipmac.html)
- [Fortinet 文件庫](https://docs.fortinet.com/)
- [Blogger 轉貼頁](https://kbwangtw.blogspot.com/2021/09/fortigate-ipmac.html)
