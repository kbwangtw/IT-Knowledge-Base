---
layout: default
title: jt-ipam 導入紀錄
last_modified_at: 2026-10-07
---

# jt-ipam 導入紀錄

本文件依 jt-ipam 官方 Adoption Roadmap 整理本環境的實際導入進度。公開文件不記錄密碼、Token Secret、私鑰或完整憑證。

## 導入狀態

| 階段 | 內容 | 狀態 |
| --- | --- | --- |
| Phase 0 | 安裝、安全與基本環境 | 部分完成 |
| Phase 1 | IP / Subnet 規劃 | 基本架構完成 |
| Phase 2 | Discovery / Scan | 已完成並持續運作 |
| Phase 3 | 外部系統整合 | Proxmox VE、LibreNMS 已完成 |
| Phase 4 | 機房、機櫃與設備 | 建檔中，U 位待實機確認 |
| Phase 5 | 維運、自動化 | 待進行 |

## 已完成項目

jt-ipam v0.6.19 部署於 Proxmox VE 的 Debian 13 LXC，並以 HTTPS 提供 Web 服務。已建立 ITBH-Network，納管主要 LAN 與 PVE Cluster Network；現場目前沒有 VLAN，因此不建立虛構 VLAN 資料。

本機 Scan Agent 已啟用 ICMP、ARP L2 與 Reverse PTR 探索，能找到 LAN 上的主機並取得部分 hostname 與 MAC，用來和人工維護資料比對。

Proxmox VE 已使用獨立唯讀 API 帳號與 Token 整合三節點 Cluster。初次同步曾遇到 HTTP 401，經直接驗證 PVE API 並重新保存認證資訊後恢復正常。實測 PVE API 版本為 9.2.20 / release 9.2。PVE 的 VM / CT 資料主要呈現在 Virtualization 視角，不應因一般 Device 清單沒有同步出相同資料就判定整合失敗。

LibreNMS 已完成 API 整合，Device、ARP、鄰居與 online status 等資料可供 jt-ipam 比對。相同 VM / CT 可能同時出現在 Virtualization 與 Device，前者代表虛擬化資產，後者代表監控視角，不應只因名稱相同就刪除。

## 機房與機櫃

已建立 Location `ITBH Server Room` 與 12U `Rack-01`。預計納管三台 PVE 主機、兩台 Synology NAS、兩台交換器與兩片層板。

目前刻意不先填最終 U 位。非標準 rackmount 設備會放在層板上，必須等機櫃到貨後依實際尺寸、層板位置、散熱與線材空間決定。層板 U 位應視為設備底部支撐位置，而不是設備頂部。

## 下一步

1. 完成 jt-ipam 設定與資料備份／還原驗證。
2. 清理 IP、Device、Virtualization 三個視角的 stale data。
3. 建立固定 IP、保留 IP 與動態 Client 的管理規則。
4. 機櫃到貨後補 Rack U、設備與層板位置。
5. 再評估告警、異常偵測、IP 申請與其他自動化。

## 導入原則

目前已把 Scan Agent 的網路實際狀態、Proxmox VE 的虛擬化資產與 LibreNMS 的監控資料串起來。下一階段優先確保資料可信、來源可追蹤，再擴大自動建立與自動化。

## 參考資料

- [jt-ipam Adoption Roadmap](https://jasoncheng7115.github.io/jt-ipam/adoption.html)
- [jt-ipam GitHub](https://github.com/jasoncheng7115/jt-ipam)
- [jt-ipam Documentation](https://jasoncheng7115.github.io/jt-ipam/)
