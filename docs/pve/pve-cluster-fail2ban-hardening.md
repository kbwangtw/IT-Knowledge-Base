---
layout: default
title: "PVE 一直被嘗試登入：怎麼確認 Fail2Ban 真的有擋？"
permalink: /docs/pve/pve-cluster-fail2ban-hardening/
date: 2026-09-14
categories: [PVE, Security, Fail2Ban, Network]
last_modified_at: 2026-10-17
---

# PVE 一直被嘗試登入：怎麼確認 Fail2Ban 真的有擋？

> **一句話**：Fail2Ban 顯示 running 不代表有擋到；要依序確認「登入失敗有記錄 → 來源被加入封鎖 → 封包真的命中規則」。後來查到根源是路由器把 8006 開到網際網路，改用 WireGuard 後，再替 `root@pam` 加上 TOTP、限縮 SSH 金鑰。

| 項目 | 內容 |
| --- | --- |
| 適合誰看 | PVE 管理頁面被外部嘗試登入、想確認防護有沒有用的人 |
| 環境 | PVE 9.2.18（9/14）；三台 node10～node12 |
| 日期 | 2026-09-14 首次記錄；10/12～10/15 補記 |
| 結論 | ✅ node10 確認遞增封鎖（1h → 2h）與 iptables 命中；✅ 8006 對外轉送已停用、改走 WireGuard；✅ `root@pam` 啟用 TOTP；✅ SSH 金鑰加上來源限制；⏳ 刪除 hermesagent token、關閉 SSH 密碼登入 |

> 完整的封鎖與封包證據來自 node10；三台設定相同，但不擴大解讀成三台都各自驗證過。

## 1. 先認識幾個名詞

| 名詞 | 白話解釋 |
| --- | --- |
| **Fail2Ban** | 讀登入失敗日誌，失敗太多次就把來源 IP 加進防火牆封鎖 |
| **jail** | Fail2Ban 裡「一組判斷與封鎖規則」，不是 VM 或容器；本案有 `proxmox` 和 `sshd` 兩組 |
| **maxretry／findtime／bantime** | 失敗幾次／在多長時間內／封鎖多久 |
| **iptables** | Linux 的防火牆規則；Fail2Ban 透過它真正擋封包 |
| **PVE Firewall** | PVE 自己的防火牆，和 Fail2Ban 是兩回事 |
| **port forward（轉送）** | 路由器把外部某個埠轉到內網主機，等於把服務開到網際網路 |
| **TOTP** | 手機 App 產生、每 30 秒換一次的驗證碼（兩步驟驗證） |
| **API token** | 給程式用的登入憑證，不經過 TOTP |
| **authorized_keys** | 允許用哪些 SSH 金鑰登入 root 的清單 |

## 2. Fail2Ban 怎麼擋

```text
有人在 8006 打錯密碼
  → pvedaemon 寫進 systemd 日誌
  → Fail2Ban 的 proxmox jail 讀到，計算次數
  → 達到門檻，把來源 IP 加進 iptables 的 f2b-proxmox 規則
  → 之後這個 IP 的封包被 REJECT
```

SSH 的登入失敗由另一組 `sshd` jail 處理。

## 3. 步驟一：確認現在真正生效的設定

**做什麼**：看「正在執行」的值，不只看設定檔。

```bash
systemctl status fail2ban --no-pager
fail2ban-client status
fail2ban-client status proxmox
fail2ban-client status sshd
fail2ban-client get proxmox maxretry
fail2ban-client get proxmox findtime
fail2ban-client get proxmox bantime
fail2ban-client get proxmox ignoreip
fail2ban-client get proxmox actions
```

再查設定是從哪個檔案來的：

```bash
grep -Rni 'proxmox' /etc/fail2ban
ls -lah /etc/fail2ban/jail.d/
fail2ban-client -d | grep -i -A20 -B5 proxmox
```

> 只看某個檔案不夠，其他設定檔可能覆蓋它。`fail2ban-client -d` 會印出合併後的最終設定，要和檔案內容對起來。

## 4. 步驟二：只調整 proxmox 這組規則

**怎麼做**：在 `/etc/fail2ban/jail.d/proxmox.local` 加入：

```ini
[proxmox]
maxretry = 3
findtime = 2d
bantime = 1h
bantime.increment = true
bantime.factor = 1
bantime.maxtime = 7d
```

| 設定 | 意思 |
| --- | --- |
| `maxretry = 3` | 失敗 3 次就封鎖 |
| `findtime = 2d` | 在 48 小時內累計 |
| `bantime = 1h` | 第一次封鎖 1 小時 |
| `bantime.increment = true` | 同一個來源再犯，封鎖時間加長 |
| `bantime.maxtime = 7d` | 最長封鎖 7 天 |

- 這份片段依賴原本已存在的 jail、filter 和 action，不是新主機的完整安裝設定。
- 放在 `[proxmox]` 而不是 `[DEFAULT]`，避免不小心改到 SSH 等其他 jail。

## 5. 步驟三：語法通過再套用

```bash
fail2ban-client -t                                                     # 檢查語法
fail2ban-client -d | grep -E "'proxmox'.*(maxretry|findtime|bantime)"  # 看合併後的值
```

測試成功後，才在維護時段重啟並核對：

```bash
systemctl restart fail2ban
fail2ban-client status proxmox
fail2ban-client status sshd
fail2ban-client get proxmox maxretry
fail2ban-client get proxmox findtime
fail2ban-client get proxmox bantime
```

**看到的結果**：maxretry 3、findtime 172800 秒（= 2 天）、bantime 3600 秒（= 1 小時）。bantime 顯示的是**基礎值**，不代表某個來源沒被加長封鎖。

## 6. 步驟四：用實際紀錄確認「1 小時變 2 小時」

本次某個外部來源（以下以 `<攻擊來源 IP>` 代稱）的紀錄：

```text
Ban <攻擊來源 IP>
incr 1h to 2h
Increase Ban <攻擊來源 IP> (2 # 2h -> 2026-09-14 12:14:30)
```

事件約在 10:14:31 發生，封鎖延長到 12:14:30，證明 **1h → 2h 的遞增有作用**。沒有實測到全部遞增階段或 7 天上限。

查指定來源的紀錄：

```bash
grep -F '<攻擊來源 IP>' /var/log/fail2ban.log | tail -20
fail2ban-client get proxmox banip --with-time
```

這個 IP 只是觀察到的來源，不代表已識別背後的人或組織。

## 7. 步驟五：封包有沒有真的進入規則

**做什麼**：最後一關，看 iptables 計數器有沒有增加。

```bash
iptables -L f2b-proxmox -n -v --line-numbers   # -v 會顯示封包數與位元組數
iptables -S INPUT | grep -F f2b-proxmox        # 哪些流量會導向這條規則
iptables -S f2b-proxmox
```

**看到的結果**：INPUT 的 TCP 80、443、8006 導向 `f2b-proxmox`，指定來源命中 REJECT，計數為 **16 個封包、916 bytes**。

- 這組規則只涵蓋指定埠與 INPUT 路徑，**不能**說所有埠或轉送給 VM 的流量都被封鎖。
- 三台的 Fail2Ban 設定和本機 SQLite 紀錄**不會**因為是 PVE 叢集就自動同步。

### PVE Firewall 有 running，為什麼不能說已啟用？

```bash
systemctl status pve-firewall --no-pager
pve-firewall status
cat /etc/pve/firewall/cluster.fw
cat /etc/pve/nodes/node10/host.fw
ss -lntp | grep ':8006'
```

當時 service 在執行，但狀態是 `disabled/running`，cluster `enable=0`、host `enable=1`。所以**服務存活 ≠ 整套 PVE Firewall 已啟用**。8006 監聽在所有本機介面，也不能單獨證明外網直通。

## 8. 10/12～10/13：找到入口，改用 WireGuard

**入口查清了**：路由器上有一條 **TCP 8006 轉送**，當初為了從外面管理 PVE 而設定。也就是 PVE 管理介面直接對網際網路開放；Fail2Ban 只能在猜錯幾次後封鎖，**擋不了不需要密碼的漏洞攻擊**。

**改善方式**：改用 cluster 裡的 WireGuard 容器。數據機只轉送 UDP 51820，iPhone 和筆電先連 VPN，再用內網 IP 開 PVE。

- 10/12 完成 VPN 設定與外部連線測試。
- 10/13 在數據機停用 8006 轉送，關掉 Wi-Fi 從外部確認 8006 已連不上。（10/12 曾誤記為已刪除，當天 16:19 和 20:36 仍有外部 IP 登入失敗。）
- 停用後 10/13 12:00～10/14 三台都沒有外部登入嘗試。

過程見 [不再把 PVE 8006 開到網際網路：改用 WireGuard 連回家](https://kbwangtw.github.io/IT-Knowledge-Base/docs/pve/wireguard-remote-access-replace-8006/)。

## 9. 10/15：重新評估後續項目

管理入口改走 WireGuard（WGDashboard 也已啟用 2FA）、8006 不再對外後：

| 項目 | 決定 | 理由 |
| --- | --- | --- |
| 三台逐一封包驗證 | **取消** | 原本是要確認外部暴力登入有被擋；外部來源已消失，node10 已驗證，三台設定相同 |
| Fail2Ban | **保留運作** | 對內網的誤試或異常登入仍有保護 |
| PVE Firewall | **長期可選** | 防的是內網威脅（VM 被入侵當跳板、內網掃描）；設錯可能鎖住管理連線或擋到 Corosync／Ceph，目前效益不足以抵過風險。內網人員或設備增加、或有稽核需求時再評估 |
| `root@pam` 啟用 TOTP | **10/15 已完成**（第 10 節） | VPN 是 split tunnel，VPN 用戶端可直達 8006；用戶端被入侵時多一道驗證 |

- 日後要啟用 PVE Firewall，先保留主控台與管理連線，盤點 Corosync、Ceph、備份和管理需要的流量，再逐台測試。
- `ignoreip` 只放必要且確認可信的管理來源。遇到誤封，先核對來源與日誌再解除那一筆；**不要**為了方便把整個大網段放行。

## 10. 10/15：`root@pam` 啟用 TOTP 與 token 清理

### 10-1 啟用後會影響誰

| 登入方式 | 啟用 TOTP 後 |
| --- | --- |
| Web UI 以 `root@pam` 登入 | 要輸入驗證碼 |
| 程式以 `root@pam` **帳號密碼**取得 ticket | **會失敗**（唯一要先排查的風險） |
| API token（ProxCenter、jt-ipam 等） | 不受影響 |
| SSH、節點本機 `qm`／`pct`／`pvesh` | 不受影響 |

### 10-2 事前排查：有沒有程式用 `root@pam` 密碼登入（唯讀）

```bash
pveum user tfa list
pveum user token list root@pam
for n in node10 node11 node12; do
  echo "== $n"
  ssh root@$n 'zcat -f /var/log/pveproxy/access.log* 2>/dev/null | grep "POST /api2/json/access/ticket" | awk "{print \$1}" | sort | uniq -c | sort -rn | head -10'
done
```

**這段在做什麼**：到三台讀 pveproxy 的存取紀錄（含壓縮過的舊檔，`zcat -f`），找出「用帳密取得登入 ticket」的請求，統計是哪些 IP。

**本次結果**：

- 帳密登入的內網來源只有三個：ct:109（VPN 用戶端經 NAT）、WinClient、家中裝置（1 次），都是人工操作。外部 IP 都是 10/13 停用轉送前的紀錄。
- 最近 30 分鐘的 API 呼叫：ProxCenter、jt-ipam 都用 API token；Web UI session 來自 ct:109（VPN）。
- 結論：**沒有程式用 `root@pam` 帳密登入，可以啟用。**

### 10-3 清理 `root@pam` 底下的 token

兩個 token 都是 `privsep = 0`（權限和 `root@pam` 相同），而且 token 不經過 TOTP，啟用後會成為「權限最大、防護最弱」的入口：

| token | 用途 | 使用紀錄 | 處理 |
| --- | --- | --- | --- |
| `pdm-admin-pdm` | Proxmox Datacenter Manager 自動建立，已不再使用 | — | 刪除 |
| `hermesagent` | Hermes Agent（AI 機器人） | 三台 access.log 都是 0；實際讓 Hermes 檢查三台後仍是 0 | 先停用，觀察約兩週後刪除 |

```bash
pveum user token remove root@pam pdm-admin-pdm
pveum user token modify root@pam hermesagent --expire 1     # 停用；要恢復改回 --expire 0
pveum user token list root@pam
```

`--expire 1` 是把到期時間設成 1970 年的第 1 秒，等於立即過期。

**意外發現**：讓 Hermes 實際檢查時，三台的 SSH 紀錄出現來自 Hermes 主機的 root 登入（另一把 RSA 金鑰）。**Hermes 是用 SSH root 金鑰操作節點，不是用 API token**。SSH 不受 PVE TOTP 管轄，AI 機器人又可能受提示注入或誤判影響，所以另外處理（第 11 節）。

### 10-4 新增 TOTP 與復原碼

1. Web UI **Datacenter → Permissions → Two Factor → Add → TOTP**：User `root@pam`、填描述、手機 App 掃 QR code、輸入驗證碼。
2. 再 **Add → Recovery Keys**（User `root@pam`）：復原碼**只顯示一次**，抄在紙上保存，**不存雲端**。
3. 原頁面**不要登出**，另開無痕視窗用 `root`／Linux PAM 登入，確認會要求驗證碼。

設定存在 `/etc/pve/priv/tfa.cfg`，由 cluster 同步，三台一起生效。

```bash
pveum user tfa list root@pam
tail -500 /var/log/pveproxy/access.log | awk '$3 ~ /token/ {print $3, $9}' | sort | uniq -c   # token 呼叫與 HTTP 狀態碼
```

**本次結果**：`totp` 和 `recovery` 各一筆；無痕視窗登入要求驗證碼並成功；ProxCenter token 啟用後 412 次呼叫全部是 200。jt-ipam 呼叫頻率較低，沒出現在同一段紀錄，沒有另外確認。

### 10-5 被鎖住時

SSH 不受影響，登入任一節點移除 TOTP 即可（也可以在登入畫面用復原碼）：

```bash
pveum user tfa list root@pam
pveum user tfa delete root@pam --id <TOTP 那一筆的 id>
```

## 11. 10/15：限縮 SSH root 金鑰

**為什麼**：PVE 的 TOTP 管不到 SSH。

**要先知道**：三台的 `/root/.ssh/authorized_keys` 都是指向 `/etc/pve/priv/authorized_keys` 的 symlink，由 cluster 同步，**改一次三台生效**。同一個檔案也有節點互連用的金鑰，所以**只能動目標那幾行，改前先備份**。

### 11-1 盤點（唯讀）

```bash
for n in node10 node11 node12; do echo -n "$n: "; ssh root@$n 'readlink -f /root/.ssh/authorized_keys'; done
ssh-keygen -lf /etc/pve/priv/authorized_keys | awk '{print $2, $3}'
sshd -T | grep -iE "^(permitrootlogin|passwordauthentication)"
# 各金鑰（指紋前 4 碼）與密碼登入的使用次數
for n in node10 node11 node12; do
  echo "== $n"
  for fp in <指紋前4碼> ...; do
    echo -n "  $fp: "; ssh root@$n "journalctl -u ssh -u sshd --since '30 days ago' --no-pager | grep 'Accepted publickey' | grep -c 'SHA256:$fp'"
  done
  ssh root@$n "journalctl -u ssh -u sshd --since '30 days ago' --no-pager | grep 'Accepted password' | awk '{print \$9, \$11}' | sort | uniq -c"
done
```

| 指令 | 在查什麼 |
| --- | --- |
| `readlink -f` | 確認三台都指向同一個共享檔 |
| `ssh-keygen -lf` | 列出每把金鑰的指紋和註解，不顯示金鑰本體 |
| `sshd -T` | SSH 正在使用的設定（是否允許 root、是否允許密碼） |
| `grep 'Accepted publickey'` | 每把金鑰最近 30 天登入過幾次 |

| 金鑰 | 用途 | 使用紀錄（journal 保留到 2～7 月） | 處理 |
| --- | --- | --- | --- |
| 管理者筆電（ED25519） | 人工登入 | 0 | 保留 |
| `root@node10／11／12` | 節點互連 | — | **不動** |
| `root@ai`（第一把） | Hermes Agent | 只有今天測試時出現 | 加 `from="<Hermes IP>"` 等限制 |
| `root@ai`（第二把） | 不明，多半是舊的 | 0 | **刪除** |
| `root@ProxCenter` | ProxCenter | 0（10/12 滾動更新也沒用到） | 保守起見不刪，加 `from="<ProxCenter IP>"` 限制 |

### 11-2 限制的寫法

在該行最前面加上選項：

```text
from="<來源 IP>",no-port-forwarding,no-agent-forwarding,no-X11-forwarding ssh-rsa AAAA... root@ai
```

| 選項 | 作用 |
| --- | --- |
| `from="<來源 IP>"` | 只接受從這個 IP 登入；金鑰外流到別台也用不了 |
| `no-port-forwarding` 等三項 | 關閉通道轉送等用不到的功能，不影響下指令 |

### 11-3 修改方式

**原則**：用指紋找出目標行 → 確認**只找到一行、該行還沒有選項** → 產生新檔 → 比對「行數、變動行數、節點金鑰都還在」→ 全部通過才寫回；任何一項不符就停止。

```bash
cp -a /etc/pve/priv/authorized_keys /root/authorized_keys.bak-YYYYMMDD; chmod 600 /root/authorized_keys.bak-YYYYMMDD
# 找行：fp=$(printf '%s\n' "$line" | ssh-keygen -lf - 2>/dev/null | awk '{print $2}' || true)
# 改行：awk -v L=<行號> 'NR==L{$0="from=\"<IP>\",no-port-forwarding,no-agent-forwarding,no-X11-forwarding " $0}1'
# 刪行：awk -v D=<行號> 'NR==D{next}1'
cat <新檔> > /etc/pve/priv/authorized_keys      # 用 cat 寫回，保留 pmxcfs 上的檔案
```

**兩個要注意的地方**：

- 逐行算指紋時，註解和空行會讓 `ssh-keygen` 回傳錯誤；在 `set -e` 下要加 `|| true`，否則腳本會中途停止（停止時不會修改檔案）。
- 備份要在**第一次**修改前建立，之後重跑指令時**不要再覆蓋**這份備份，否則會變成修改後的版本。

### 11-4 驗證

```bash
ssh-keygen -lf /etc/pve/priv/authorized_keys | awk '{print $2, $3}'
grep -c "^from=" /etc/pve/priv/authorized_keys
for h in node11 node12; do ssh -o BatchMode=yes -o ConnectTimeout=5 root@$h hostname; done
# 讓 Hermes 檢查一次三台後
for n in node10 node11 node12; do ssh root@$n 'journalctl -u ssh -u sshd --since "10 min ago" --no-pager | grep Accepted | grep -c "<Hermes IP>"'; done
```

**本次結果**：剩 6 把金鑰（第二把 `root@ai` 已移除）、2 行有 `from=`；節點互連正常；Hermes 修改後三台都能登入。

- 如果互連失敗，立刻 `cat <備份> > /etc/pve/priv/authorized_keys` 還原。
- 確認正常後用 `shred -u` 刪除備份（覆寫後再刪，不留痕跡）。

### 11-5 尚未處理：密碼登入

`PermitRootLogin yes` 加上 `PasswordAuthentication yes`，代表知道 root 密碼就能從內網 SSH，而且不受 TOTP 保護。目前密碼登入來源都是人工（WinClient、VPN、家中兩台裝置）。關閉前要先讓這些裝置改用金鑰登入，另排時間處理。

## 12. 常見問題

| 現象 | 怎麼辦 |
| --- | --- |
| `fail2ban` 是 running，不知道有沒有擋 | 看 `fail2ban.log` 的 Ban 紀錄，再看 `iptables -L f2b-proxmox -n -v` 的計數 |
| 改了設定檔沒生效 | 用 `fail2ban-client -d` 看合併後的值，可能被其他檔案覆蓋 |
| `bantime` 一直顯示 3600 | 那是基礎值；遞增結果看 log 的 `Increase Ban` |
| PVE Firewall service running | 再看 `pve-firewall status` 和 `cluster.fw` 的 `enable` |
| 一直有外部 IP 嘗試登入 | 查路由器有沒有轉送 8006；改用 VPN |
| 啟用 TOTP 後被鎖住 | SSH 登入節點，`pveum user tfa delete`；或用復原碼 |
| 改 authorized_keys 後節點互連失敗 | 立刻用備份還原 |

## 13. 待辦

- [ ] 約 10/29 刪除已停用的 `hermesagent` token
- [ ] 各裝置改用金鑰後，關閉 SSH 密碼登入
- [ ] （可選）Hermes 改用只能執行唯讀指令的帳號

## 14. 延伸閱讀

- [不再把 PVE 8006 開到網際網路：改用 WireGuard 連回家](https://kbwangtw.github.io/IT-Knowledge-Base/docs/pve/wireguard-remote-access-replace-8006/)
- [Fail2Ban 1.1.0 設定參考](https://github.com/fail2ban/fail2ban/blob/1.1.0/config/jail.conf)
- [Proxmox Firewall 文件](https://pve.proxmox.com/pve-docs/chapter-pve-firewall.html)
- [Proxmox VE：User Management（TFA）](https://pve.proxmox.com/pve-docs/chapter-pveum.html)
