---
layout: default
title: "PVE 一直被嘗試登入：怎麼確認 Fail2Ban 真的有擋？"
permalink: /docs/pve/pve-cluster-fail2ban-hardening/
date: 2026-09-14
categories: [PVE, Security, Fail2Ban, Network]
last_modified_at: 2026-09-18
---

# PVE 一直被嘗試登入：怎麼確認 Fail2Ban 真的有擋？

本次先確認登入失敗有被記錄，再確認 Fail2Ban 把來源加入封鎖，最後查看封包是否真的命中規則。node10 的證據顯示，重複來源的封鎖時間由 1 小時增加到 2 小時，iptables 規則也有封包計數。

**服務顯示 running，只代表程式在執行；要知道有沒有擋到，還得看規則與封包。**

> 紀錄日期：2026-09-14；PVE 9.2.18。三台已配置，但完整封鎖與封包證據來自 node10，不能擴大成三台都有同樣驗證結果。

## Fail2Ban 在做什麼？

它讀登入失敗日誌，符合門檻時把來源加入防火牆規則。本案 proxmox jail 讀 pvedaemon 的 systemd 日誌；SSH 由另一個 sshd jail 處理。

這裡的 jail 可以理解成「一組判斷與封鎖規則」，不是 VM 或容器。

## 1. 先確認現在真正生效的設定

~~~bash
systemctl status fail2ban --no-pager
fail2ban-client status
fail2ban-client status proxmox
fail2ban-client status sshd
fail2ban-client get proxmox maxretry
fail2ban-client get proxmox findtime
fail2ban-client get proxmox bantime
fail2ban-client get proxmox ignoreip
fail2ban-client get proxmox actions
~~~

再查設定來源：

~~~bash
grep -Rni 'proxmox' /etc/fail2ban
ls -lah /etc/fail2ban/jail.d/
fail2ban-client -d | grep -i -A20 -B5 proxmox
~~~

只看某個檔案不夠，因為其他設定可能覆蓋它。要把檔案內容和正在執行的值對起來。

## 2. 只調整 proxmox 這組規則

本次在 /etc/fail2ban/jail.d/proxmox.local 加入：

~~~ini
[proxmox]
maxretry = 3
findtime = 2d
bantime = 1h
bantime.increment = true
bantime.factor = 1
bantime.maxtime = 7d
~~~

白話是：以 48 小時為觀察範圍，基礎門檻為 3 次失敗、基礎封鎖 1 小時；有重複封鎖紀錄時延長，設定上限為 7 天。

這份片段依賴原本已存在的 jail、filter 與 action，不是全新主機的完整安裝設定。放在 [proxmox] 而非 [DEFAULT]，可避免無意間改到 SSH 等其他 jail。

## 3. 語法通過，再套用與核對

~~~bash
fail2ban-client -t
fail2ban-client -d | grep -E "'proxmox'.*(maxretry|findtime|bantime)"
~~~

確認測試成功後，才於維護操作中重啟：

~~~bash
systemctl restart fail2ban
fail2ban-client status proxmox
fail2ban-client status sshd
fail2ban-client get proxmox maxretry
fail2ban-client get proxmox findtime
fail2ban-client get proxmox bantime
~~~

本次執行值為 maxretry 3、findtime 172800 秒、bantime 3600 秒。最後一項仍顯示基礎 1 小時，不代表某個來源沒有被加長封鎖。

## 4. 用實際紀錄確認「1 小時變 2 小時」

本次來源 77.90.185.226 的紀錄出現：

~~~text
Ban 77.90.185.226
incr 1h to 2h
Increase Ban 77.90.185.226 (2 # 2h -> 2026-09-14 12:14:30)
~~~

事件約在 10:14:31 發生，延長到 12:14:30。這證明本次 1h → 2h 有作用，沒有實測到全部遞增階段或 7 天上限。

可查看指定來源的時間紀錄：

~~~bash
grep -F '77.90.185.226' /var/log/fail2ban.log | tail -20
fail2ban-client get proxmox banip --with-time
~~~

這個 IP 是案例中的觀察來源，不代表已識別背後的人或組織。

## 5. 最後一關：封包有沒有真的進入規則？

~~~bash
iptables -L f2b-proxmox -n -v --line-numbers
iptables -S INPUT | grep -F f2b-proxmox
iptables -S f2b-proxmox
~~~

本次 INPUT 的 TCP 80、443、8006 導向 f2b-proxmox，指定來源命中 REJECT，計數為 16 個封包、916 bytes。

這組規則涵蓋的是指定埠與 INPUT 路徑，不能宣稱所有埠或轉送給 VM 的流量都被同樣封鎖。三節點的 Fail2Ban 設定與本機 SQLite 紀錄也不會因為是 PVE 叢集就自動同步。

## PVE Firewall 有 running，為什麼仍不能說已啟用？

本案同時檢查：

~~~bash
systemctl status pve-firewall --no-pager
pve-firewall status
cat /etc/pve/firewall/cluster.fw
cat /etc/pve/nodes/node10/host.fw
ss -lntp | grep ':8006'
~~~

當時 service 在執行，但 firewall 狀態為 disabled/running，cluster enable=0，host enable=1。因此不能把服務存活解讀成整套 PVE Firewall 已啟用。

8006 監聽在所有本機介面，也不能單獨證明外網直通。node10 有外部登入嘗試和封包命中證據，但上游究竟是 NAT、port forward 或 proxy，當時尚未查清；其他兩台的外部暴露範圍也未確認。

## 接下來該補哪些事？

先查清管理入口，再規劃來源限制或 VPN。若要啟用 PVE Firewall，需先保留主控台與管理連線，盤點 Corosync、Ceph、備份和管理所需流量，再逐台測試。本文沒有執行這一步。

ignoreip 只放必要且確認可信的管理來源。遇到誤封，先核對來源與日誌，再解除那一筆；不要為了讓管理方便，把整個大網段放行。

## 本次結論

已確認 node10 的遞增封鎖與 iptables 命中，三台配置已處理。尚未完成的是上游入口追查、三台逐一封包驗證，以及 PVE Firewall 的完整啟用計畫。

- [Fail2Ban 1.1.0 設定參考](https://github.com/fail2ban/fail2ban/blob/1.1.0/config/jail.conf)
- [Proxmox Firewall 文件](https://pve.proxmox.com/pve-docs/chapter-pve-firewall.html)
