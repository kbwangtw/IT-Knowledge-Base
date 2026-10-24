---
layout: default
title: "Lenovo TS150 加 NVS315 顯示卡安裝 Windows Server 2016 藍屏：換插槽就能裝"
date: 2019-05-03
categories: [Hardware, Lenovo, Server, Windows, Troubleshooting, Blogger 舊文]
permalink: /docs/blogger/hardware/lenovo-ts150-windows2016/
last_modified_at: 2026-10-24
---

# Lenovo TS150 加 NVS315 顯示卡安裝 Windows Server 2016 藍屏：換插槽就能裝

> **一句話**：ThinkServer TS150（70UB）插著 NVIDIA NVS315 顯示卡安裝 Windows Server 2016 或 Windows 10（1607）時會藍屏；把顯示卡從 **Slot 1 移到 Slot 3** 就能安裝，裝好並更新到 KB3213986 之後可以再移回 Slot 1。

| 項目 | 內容 |
| --- | --- |
| 適合誰看 | Lenovo ThinkServer 加裝 NVS315 後安裝 Windows 就藍屏的人 |
| 環境 | Lenovo ThinkServer TS150（機型 70UB）＋ NVIDIA NVS315；Windows Server 2016／Windows 10 Build 14393 |
| 日期 | 2019-05-03（原文發表於 Blogger，2026-10-24 改寫為新手版） |
| 結論 | ✅ 顯示卡改插 Slot 3 後可安裝作業系統 |

## 1. 先認識幾個名詞

| 名詞 | 白話解釋 |
| --- | --- |
| **藍屏（Stop error）** | Windows 遇到嚴重錯誤時的藍色畫面 |
| **WHEA** | Windows 硬體錯誤架構；藍屏代碼有 WHEA 通常和硬體或驅動有關 |
| **CPU PCIe Slot／PCH PCIe Slot** | 直接連到 CPU 的插槽／連到主機板晶片組的插槽 |
| **KB3213986** | 微軟 2017-01-10 發布的累積更新（OS Build 14393.693），修正這個問題 |

## 2. 症狀

安裝到 Windows 標誌出現時藍屏，停止代碼 **WHEA_UNCORRECTABLE_ERROR**。

![安裝時藍屏：WHEA UNCORRECTABLE ERROR（原作者照片）]({{ '/docs/blogger/hardware/images/ts150-nvs315-bsod-whea.jpg' | relative_url }})

## 3. 原因與解法（Lenovo 官方文件重點）

以下為 Lenovo 支援文件 HT503170 的重點整理：

| 項目 | 重點 |
| --- | --- |
| 原因 | Windows Server 2016 RS1／Windows 10 1607 改變了 CPU 的某個暫存器設定，單處理器伺服器把 NVS315 插在 CPU 直連插槽時會出錯 |
| 受影響機型 | ThinkServer RS140、RS160、TS140、TS150、TS440、TS450、TS460 |
| 暫時做法 | 顯示卡改插 **Slot 3**（或晶片組 PCH 的插槽），即可正常安裝；Windows Server 2012、Windows 10 1511 不會發生 |
| 根本解法 | 安裝 **KB3213986**（或直接線上更新到最新），之後顯示卡可以移回 Slot 1 |
| 注意 | 插在 Slot 3 可能讓顯示卡效能變差 |

## 4. 步驟

```text
① 關機，把 NVS315 從 Slot 1 移到 Slot 3
② 安裝 Windows Server 2016 → 完成
③ Windows Update 更新到 KB3213986（14393.693）或更新版本
④ 關機，視需要把顯示卡移回 Slot 1 → 開機正常
```

## 5. 常見問題

| 現象 | 怎麼辦 |
| --- | --- |
| 移到 Slot 3 還是藍屏 | 先拔掉顯示卡用內建顯示安裝，裝完更新後再插回 |
| 已經裝好系統，插上顯示卡就藍屏 | 先拔卡開機、安裝更新，再插回 |
| 不確定更新有沒有裝 | 執行 `winver`，版本要 ≥ 14393.693 |

## 6. 延伸閱讀

- [Lenovo 支援文件 HT503170（英文）](https://datacentersupport.lenovo.com/tw/en/solutions/ht503170)
- [Microsoft：KB3213986（OS Build 14393.693）](https://support.microsoft.com/en-us/help/4009938/january-10-2017-kb3213986-os-build-14393-693)
- [用隨身碟安裝 Windows Server 2016 出現 0x80070026](../hp-ml10-windows2016-install-wim-0x80070026/)
- [Blogger 原文](https://kbwangtw.blogspot.com/2019/05/lenovo-thinkserver-ts150windwos-2016.html)
