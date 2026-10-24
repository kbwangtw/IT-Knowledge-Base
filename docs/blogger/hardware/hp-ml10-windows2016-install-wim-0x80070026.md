---
layout: default
title: "用隨身碟安裝 Windows Server 2016 出現 0x80070026：install.wim 超過 4 GB"
date: 2017-05-23
categories: [Hardware, HPE, Windows, Troubleshooting, Blogger 舊文]
permalink: /docs/blogger/hardware/hp-ml10-windows2016-install-wim-0x80070026/
last_modified_at: 2026-10-24
---

# 用隨身碟安裝 Windows Server 2016 出現 0x80070026：install.wim 超過 4 GB

> **一句話**：隨身碟是 FAT32，單一檔案不能超過 4 GB，4 GB 多的 `install.wim` 被截成約 700 MB，安裝時就報 0x80070026；把隨身碟轉成 **NTFS**，再把 ISO 裡完整的 `sources\install.wim` 複製過去即可。

| 項目 | 內容 |
| --- | --- |
| 適合誰看 | 用 UltraISO 等工具做 Windows 開機隨身碟，安裝時說找不到 install.wim 的人 |
| 環境 | HP ProLiant ML10；Windows Server 2016 ISO；UltraISO |
| 日期 | 2017-05-23（原文發表於 Blogger，2026-10-24 改寫為新手版） |
| 結論 | ✅ 改 NTFS 並放入完整 install.wim 後安裝成功 |

## 1. 先認識幾個名詞

| 名詞 | 白話解釋 |
| --- | --- |
| **install.wim** | Windows 安裝檔的主體映像，位於 ISO 的 `sources` 資料夾 |
| **FAT32** | 隨身碟常見格式，**單一檔案上限 4 GB** |
| **NTFS** | Windows 的檔案系統，沒有 4 GB 的限制 |
| **`convert`** | Windows 內建指令，可把 FAT32 直接轉成 NTFS，不會刪資料 |

## 2. 發生了什麼事

```text
官網下載 Windows 2016 ISO → UltraISO 做開機隨身碟（FAT32）
  → install.wim 原本 4 GB 多，寫進 FAT32 只剩約 700 MB（被截斷）
  → 開機安裝 → 「找不到 install.wim」錯誤碼 0x80070026
```

![安裝程式顯示無法開啟 install.wim，錯誤碼 0x80070026（原作者照片）]({{ '/docs/blogger/hardware/images/ml10-win2016-0x80070026.jpg' | relative_url }})

## 3. 步驟一：把隨身碟轉成 NTFS

**怎麼做**：以**系統管理員身分**開啟命令提示字元，輸入：

```text
convert S: /fs:ntfs
```

| 片段 | 意思 |
| --- | --- |
| `S:` | 隨身碟的磁碟代號，**換成你自己的**，打錯會轉到別顆碟 |
| `/fs:ntfs` | 轉成 NTFS 格式 |

**應該看到什麼**：顯示轉換完成，隨身碟裡原有的檔案還在。

## 4. 步驟二：放入完整的 install.wim

**怎麼做**：用 UltraISO（或 Windows 內建的「掛接」）打開 Windows 2016 ISO，把 `sources\install.wim` 複製到隨身碟的 `sources` 資料夾，覆蓋原本被截斷的檔案。

**應該看到什麼**：隨身碟上的 `install.wim` 大小和 ISO 裡一樣（4 GB 多）；重新開機安裝不再出錯。

## 5. 常見問題

| 現象 | 怎麼辦 |
| --- | --- |
| 轉 NTFS 後開不了機 | 部分 UEFI 機器只認 FAT32 開機；改用 Rufus 製作，或用 `dism /Split-Image` 把 install.wim 切成多個 .swm 檔，維持 FAT32 |
| 複製時說檔案太大 | 隨身碟還是 FAT32，確認轉換成功 |
| 不確定是不是這個原因 | 比對隨身碟和 ISO 中 install.wim 的大小 |

## 6. 延伸閱讀

- [HP ML10 Gen9：Intel RST 建 RAID 1 並安裝 Windows 2012](../hp-ml10-gen9-rst-raid-windows2012/)
- [Lenovo TS150 安裝 Windows Server 2016](../lenovo-ts150-windows2016/)
- [Blogger 原文](https://kbwangtw.blogspot.com/2017/05/hp-ml10-windows-2016-0x80070026.html)
