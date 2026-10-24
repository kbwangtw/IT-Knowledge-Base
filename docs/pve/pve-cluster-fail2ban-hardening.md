---
layout: default
title: "PVE 一直被嘗試登入：怎麼確認 Fail2Ban 真的有擋？"
permalink: /docs/pve/pve-cluster-fail2ban-hardening/
date: 2026-09-14
categories: [PVE, Security, Fail2Ban, Network]
last_modified_at: 2026-10-24
---

# PVE 一直被嘗試登入：怎麼確認 Fail2Ban 真的有擋？

> **一句話**：Fail2Ban 顯示 running 不代表有擋到；要依序確認「登入失敗有記錄 → 來源被加入封鎖 → 封包真的命中規則」。後來查到根源是路由器把 8006 開到網際網路，改用 WireGuard 後，再替 `root@pam` 加上 TOTP、限縮 SSH 金鑰、關閉 SSH 密碼登入，並整理各裝置的金鑰與 `proxcenter` 帳號。

| 項目 | 內容 |
| --- | --- |
| 適合誰看 | PVE 管理頁面被外部嘗試登入、想確認防護有沒有用的人 |
| 環境 | PVE 9.2.18（9/14）；三台 node10～node12 |
| 日期 | 2026-09-14 首次記錄；10/12～10/24 補記 |
| 結論 | ✅ node10 確認遞增封鎖（1h → 2h）與 iptables 命中；✅ 8006 對外轉送已停用、改走 WireGuard；✅ `root@pam` 啟用 TOTP；✅ SSH 金鑰加上來源限制；✅ 10/22 三台 PVE 與 PBS31 關閉 SSH 密碼登入（第 12 節）；✅ 10/23～10/24 手機、家裡筆電改用金鑰，清掉壞掉的金鑰行，`proxcenter` 帳號加上來源 IP 限制（第 13 節）；⏳ 刪除 hermesagent token、舊的管理者筆電金鑰 |

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

### 11-5 密碼登入（10/22 已處理，見第 12 節）

`PermitRootLogin yes` 加上 `PasswordAuthentication yes`，代表知道 root 密碼就能從內網 SSH，而且不受 TOTP 保護。目前密碼登入來源都是人工（WinClient、VPN、家中兩台裝置）。關閉前要先讓這些裝置改用金鑰登入，另排時間處理。

## 12. 10/22：關閉 SSH 密碼登入（三台 PVE 與 PBS31）

**做什麼**：先讓手上的裝置改用金鑰登入，四台都測試成功後，才關掉密碼登入。全程保留已登入的視窗；萬一新連線進不去，PVE／PBS 網頁的 **Shell**（有 TOTP 保護）不走 SSH，一定進得去。

```text
產生金鑰（公司筆電）─▶ 公鑰加進 PVE（三台共用）和 PBS31 ─▶ 四台用金鑰登入測試
  ─▶ 查 30 天內的密碼登入來源 ─▶ 新增 sshd 設定檔 ─▶ 密碼被拒、金鑰可登入
```

### 12-1 產生金鑰（MobaXterm／PuTTY）

1. MobaXterm 選單 **Tools → MobaKeyGen**（就是 PuTTYgen）。不要在 MobaXterm 的本機終端機跑 `ssh-keygen`：它的家目錄重開就會清掉。
2. Type of key 選 **EdDSA／Ed25519** → **Generate**（移動滑鼠）。
3. Key comment 填裝置名稱（例如 `company-laptop-p51`），**一定設 passphrase**，存成 `.ppk`。
4. 複製上方「Public key for pasting into OpenSSH authorized_keys file」框裡的那一行（`ssh-ed25519 …`）。

| 檔案 | 處理 |
| --- | --- |
| 公鑰（`ssh-ed25519 …` 一行） | 可以公開，加到伺服器 |
| 私鑰（`.ppk`） | 只留在這台電腦；不要放在會同步到 OneDrive 的「桌面／文件」，例如存在 `C:\Users\<帳號>\.ssh\` |

公司筆電由公司 IT 管理、離職要交回，所以私鑰一定加 passphrase；註解寫清楚是哪台，日後刪掉那一行就能撤銷。

### 12-2 公鑰加進 PVE 與 PBS31

PVE（任一台執行，三台共用 `/etc/pve/priv/authorized_keys`）：

```bash
ls -l /root/.ssh/authorized_keys
cp -a /etc/pve/priv/authorized_keys /root/authorized_keys.bak-$(date +%Y%m%d)
wc -l /etc/pve/priv/authorized_keys
KEY='ssh-ed25519 AAAA…（公鑰）… company-laptop-p51'
F=/etc/pve/priv/authorized_keys
[ -n "$(tail -c1 $F)" ] && echo >> $F
grep -qF "$KEY" $F || echo "$KEY" >> $F
wc -l $F
tail -1 $F
for h in node11 node12; do echo "== $h"; ssh root@$h 'grep -c company-laptop-p51 /root/.ssh/authorized_keys'; done
```

| 片段 | 意思 |
| --- | --- |
| `ls -l` | 確認是指向 `/etc/pve/priv/authorized_keys` 的連結 |
| `cp -a … /root/…bak-日期` | 備份放 `/root`，不放 `/etc/pve` |
| `[ -n "$(tail -c1 $F)" ] && echo >> $F` | 最後一行沒換行就先補，避免新金鑰黏在上一把後面 |
| `grep -qF … \|\| echo …` | 還沒加過才加 |

看到的結果：連結正確；9 → 10 行；最後一行是新公鑰；node11、node12 各 `1`。

PBS31 不在叢集裡，要另外加（原本沒有任何公鑰）：

```bash
mkdir -p /root/.ssh && chmod 700 /root/.ssh
F=/root/.ssh/authorized_keys
touch $F && chmod 600 $F
cp -a $F $F.bak-$(date +%Y%m%d)
KEY='ssh-ed25519 AAAA…（公鑰）… company-laptop-p51'
[ -s $F ] && [ -n "$(tail -c1 $F)" ] && echo >> $F
grep -qF "$KEY" $F || echo "$KEY" >> $F
wc -l $F
```

`chmod 600` 很重要：權限太寬時 sshd 會拒絕使用這個檔案。看到的結果：0 → 1 行。

### 12-3 用金鑰登入測試

MobaXterm 每個 session：**Edit session → Basic SSH settings 勾 Specify username 填 `root` → Advanced SSH settings 勾 Use private key**，選 `.ppk`。PuTTY 在 **Connection → SSH → Auth → Credentials** 設定，再存 session。

伺服器端確認（不能只看能不能登入，要確認不是用密碼）：

```bash
journalctl -u ssh --since "10 min ago" --no-pager | grep Accepted
```

看到的結果：四台都是 `Accepted publickey for root from <VPN 位址> … ED25519 SHA256:<指紋>`，`found at /root/.ssh/authorized_keys:10`（新加的那一行）。同一秒有兩筆是 MobaXterm 另外開給 SFTP 瀏覽器的連線。

### 12-4 關閉前：30 天內誰用密碼登入（唯讀）

```bash
for h in node10 node11 node12; do
  echo "== $h"
  ssh root@$h 'journalctl -u ssh --since "30 days ago" --no-pager | grep "Accepted password" | grep -oP "from \K[0-9.]+" | sort | uniq -c'
done
```

| 來源 | 次數與時間 | 判讀 |
| --- | --- | --- |
| `<VPN 位址>` | node10 35 次 | 公司筆電等 VPN 裝置，已改金鑰 |
| `<裝置 A>` | 9/30 三台，每次同一秒兩筆 | MobaXterm 手動登入 |
| `<裝置 B>` | 9/26～9/27，每次同一秒兩筆 | MobaXterm 手動登入 |
| `<PBS31 位址>` | 10/20 08:04 一次 | PBS31 上手動 ssh；30 天只一次，不是排程 |

全部是人工登入，**關掉密碼不會讓自動化程式失敗**（節點互連、Hermes、ProxCenter 本來就用金鑰）。

### 12-5 新增 sshd 設定檔

不改原本的 `sshd_config`，另外新增設定檔，還原時刪掉即可。先在 node10 做：

```bash
grep -nE '^\s*(Include|PasswordAuthentication|PermitRootLogin|KbdInteractiveAuthentication|Match)' /etc/ssh/sshd_config
cat > /etc/ssh/sshd_config.d/10-key-only.conf <<'EOF'
# 2026-10-22 只允許金鑰登入（還原：刪除本檔後 systemctl reload ssh）
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin prohibit-password
EOF
sshd -t && echo "CONFIG-OK"
sshd -T | grep -E '^(passwordauthentication|kbdinteractiveauthentication|permitrootlogin) '
systemctl reload ssh
```

| 片段 | 意思 |
| --- | --- |
| `PasswordAuthentication no` | 不接受密碼 |
| `KbdInteractiveAuthentication no` | 也關掉鍵盤互動式（另一種輸密碼的方式） |
| `PermitRootLogin prohibit-password` | root 只能用金鑰；`sshd -T` 顯示為舊名稱 `without-password` |
| `sshd -t` | 設定沒錯才印 `CONFIG-OK`，沒有就不要 reload |
| `systemctl reload ssh` | 套用，不中斷已登入的連線 |

**為什麼原本的 `yes` 不用改**：`Include /etc/ssh/sshd_config.d/*.conf` 在第 12 行，比第 33 行的 `PermitRootLogin yes`、第 57 行的 `PasswordAuthentication yes` 先讀到；sshd 同一個設定**只採用第一次讀到的值**。

測試密碼被拒（`StrictHostKeyChecking=no`、`UserKnownHostsFile=/dev/null` 是為了不在 `known_hosts` 多留一筆 localhost）：

```bash
ssh -o PubkeyAuthentication=no -o PreferredAuthentications=password -o BatchMode=no -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@localhost
```

node11、node12 從 node10 用 `for h in node11 node12; do ssh root@$h '…'; done` 執行同一段，`sshd -t` 失敗就刪掉新檔並停止；PBS31 在本機執行同一段（它的 `sshd_config` 沒寫 `PasswordAuthentication`，預設是允許）。

**看到的結果**：

| 主機 | Include 位置 | 生效值 | 密碼測試 | 金鑰登入 |
| --- | --- | --- | --- | --- |
| node10 | 第 12 行 | `without-password`／`no`／`no` | `Permission denied (publickey)` | ✅ |
| node11 | 第 12 行 | 同上 | 同上 | ✅ |
| node12 | 第 12 行 | 同上 | 同上 | ✅ |
| PBS31 | 第 12 行 | 同上 | 同上 | ✅ |

- MobaXterm 在第一次輸入 passphrase 後，同一次執行中連其他主機不用再輸入（MobAgent 沒有啟用，確切機制未確認）。離開座位要鎖螢幕、不用時關掉 MobaXterm。
- 確認沒有代理轉送：在登入的伺服器上 `echo "SSH_AUTH_SOCK=[$SSH_AUTH_SOCK]"`，結果是 `[]`。

**還原**（任一台）：`rm /etc/ssh/sshd_config.d/10-key-only.conf && systemctl reload ssh`。

## 13. 10/23～10/24：整理各裝置金鑰與 `proxcenter` 帳號

**做什麼**：10/22 關掉密碼登入後，手機和家裡的筆電也要有自己的金鑰。加金鑰時順便盤點，發現兩件事：root 共用檔裡有 3 行從來不能用的壞金鑰；ProxCenter 另外有一個 **`proxcenter` 帳號**，它的金鑰**沒有來源限制**，而且有免密碼 sudo。

```text
手機／家裡筆電產生金鑰 ─▶ 先檢查格式再寫入 PVE、PBS31 ─▶ 盤點時發現壞行 ─▶ 確認沒用過才刪
  ─▶ 盤點所有帳號 ─▶ 發現 proxcenter 帳號 ─▶ 三台加上 from= 限制 ─▶ ProxCenter 功能正常
```

### 13-1 一台裝置一把金鑰

| 裝置 | 金鑰註解 | 產生方式 | node10～12 | PBS31 |
| --- | --- | --- | --- | --- |
| 公司筆電 | `company-laptop-p51` | MobaKeyGen（10/22） | ✅ | ✅ |
| 家裡的筆電 | `home-laptop-probook` | MobaKeyGen | ✅ | ✅ |
| 手機 | `iphone12-termius` | Termius → Vault → Keychain → Generate Key（ED25519） | ✅ | ✅ 公鑰已加 |

**為什麼不把公司筆電的私鑰匯入手機**：遺失手機時要刪掉那把公鑰，公司筆電會一起失效；而且私鑰從 Windows 傳到 iPhone，常見做法（iCloud、Email、通訊軟體）都會經過雲端。各裝置自己產生，私鑰從頭到尾不離開裝置，紀錄裡也分得出是誰登入。

| 設定 | 建議 |
| --- | --- |
| Termius 的雲端同步 | **不要開**，否則私鑰會上傳 |
| Termius 的 Save passphrase | 開的話一定要加 Face ID 鎖 |
| 公鑰怎麼傳到電腦 | 公鑰可以公開，Email／LINE 都可以；只有私鑰不能外傳 |

### 13-2 先檢查格式，再寫入

這次踩到兩次「看起來加進去了，其實格式不對」（見 13-3），所以加公鑰改成兩段：

```bash
F=/etc/pve/priv/authorized_keys          # PBS31 改成 /root/.ssh/authorized_keys
NEW='ssh-ed25519 AAAA…（公鑰）… iphone12-termius'
printf '%s\n' "$NEW" | ssh-keygen -lf -
```

看到 `256 SHA256:… iphone12-termius (ED25519)` 才繼續；看到 `(stdin) is not a public key file` 就是公鑰被截斷或斷行，**不要寫入**。

```bash
cp -a $F /root/authorized_keys.bak-$(date +%Y%m%d-%H%M)
[ -n "$(tail -c1 $F)" ] && echo >> $F
grep -qF "$NEW" $F || echo "$NEW" >> $F
wc -l $F
ssh-keygen -lf $F | awk '{print $3, $4}'
```

| 片段 | 意思 |
| --- | --- |
| `printf … \| ssh-keygen -lf -` | 只檢查這一行是不是合法的公鑰，不寫入任何東西 |
| `cp -a … /root/…` | 備份放 `/root`。**不要** `cp -a $F $F.bak-…`，那會把備份建在叢集共用的 `/etc/pve/priv/` 裡 |
| `ssh-keygen -lf $F` | 列出指紋和註解，確認新金鑰在清單裡 |

PBS31 的公鑰不用再從手機複製：在 node10 用 `grep -E " (home-laptop-probook|iphone12-termius)$" /etc/pve/priv/authorized_keys` 印出來，**從終端機直接複製文字**（不要從截圖抄，`l`／`I`、`0`／`O` 很容易看錯），貼到 PBS31 的網頁 Shell。

### 13-3 盤點：行數和金鑰數對不上

```bash
F=/etc/pve/priv/authorized_keys
echo "== 金鑰數量：$(grep -cE '^(from=|ssh-|ecdsa-)' $F)"
ssh-keygen -lf $F
n=0; while IFS= read -r l; do n=$((n+1)); r=$(printf '%s\n' "$l" | ssh-keygen -lf - 2>/dev/null | awk '{print $3, $4}'); echo "$n: ${r:-❌ 格式錯誤：$(printf '%s' "$l" | cut -c1-50)…}"; done < $F
```

| 片段 | 意思 |
| --- | --- |
| `grep -cE '^(from=\|ssh-\|ecdsa-)'` | 看起來像金鑰的行數 |
| `ssh-keygen -lf $F` | 真正讀得懂的金鑰；**壞掉的行會被直接略過，不會報錯** |
| `while read …` | 逐行檢查，讀不懂的行顯示開頭 50 個字 |

**看到的結果**：11 行像金鑰，`ssh-keygen` 只認得 8 把。

| 發現 | 原因 | 處理 |
| --- | --- | --- |
| 第 1～3 行 `ssh-rsa`（長度 733～737，4096 位元） | 內容損壞，`is not a public key file`；10/22 之前就存在 | 確認沒用過後刪除（見下方） |
| 手機的金鑰註解是 `Generated By …`，下一行單獨一個 `iphone-termius` | 貼上時被斷成兩行。金鑰本體完整，所以手機能登入 | `sed` 刪掉多出來的那行，註解改成 `iphone12-termius` |
| 家裡筆電舊金鑰 `compy-laptop-Probook` | passphrase 忘記，私鑰無法使用 | 換成新的 `home-laptop-probook`（先刪舊行再加新行，行數不變） |

**刪除前確認沒用過**：正常登入時，`journalctl` 會記錄 `found at <檔案>:<行號>`。

```bash
for h in node10 node11 node12; do echo -n "$h used lines 1-3: "; ssh root@$h "journalctl -u ssh --since '60 days ago' --no-pager | grep -cE 'authorized_keys:[123]\$'"; done
journalctl -u ssh --since '60 days ago' --no-pager | grep -E 'authorized_keys:[123]$' | grep -oE 'SHA256:[^ ]+ found at [^ ]+' | sort | uniq -c
```

node10 出現 516 次，先不刪；第二行查出來全部是 **`/home/proxcenter/.ssh/authorized_keys:2`**，最後一次是 10/12 16:22（ProxCenter 滾動更新的時間），root 共用檔的第 1～3 行是 **0 次**，才刪除：

```bash
cp -a $F /root/authorized_keys.bak-$(date +%Y%m%d-%H%M)
sed '1,3d' $F > /root/ak.new
wc -l $F /root/ak.new                                  # 11 → 8
ssh-keygen -lf /root/ak.new | awk '{print $3, $4}'     # root@node10／11／12 都要在
cat /root/ak.new > $F && rm /root/ak.new
for h in node11 node12; do echo -n "$h: "; ssh -o BatchMode=yes -o ConnectTimeout=5 root@$h hostname; done
```

**整理後**：root 共用檔 9 把金鑰，全部讀得懂。

| 金鑰 | 用途 | 來源限制 |
| --- | --- | --- |
| `root@node10`／`11`／`12` | 節點互連 | — |
| `root@ai` | Hermes Agent | ✅ |
| `root@ProxCenter` | ProxCenter | ✅ |
| `company-laptop-p51`、`home-laptop-probook`、`iphone12-termius` | 三台人工登入的裝置 | — |
| 舊的管理者筆電金鑰（註解為 `<網域>\<帳號>@<主機名>`） | 公司筆電以前用 Windows `ssh-keygen` 產生的舊金鑰 | —（待刪） |

### 13-4 盤點所有帳號：發現 `proxcenter`

10/15、10/22 都只看了 root。這次把 `/home/*` 也列進來：

```bash
for h in node10 node11 node12; do
  echo "===== $h"
  ssh root@$h '
    for f in /root/.ssh/authorized_keys /home/*/.ssh/authorized_keys; do
      [ -f "$f" ] || continue
      echo "-- $f"
      ssh-keygen -lf "$f" 2>/dev/null | awk "{print \"   \", \$3, \$4}"
      grep -c "^from=" "$f" | sed "s/^/    有 from= 限制的行數：/"
    done
    for u in $(ls /home); do echo "-- sudo 權限（$u）：$(sudo -l -U $u 2>/dev/null | grep -E "NOPASSWD|ALL" | head -2 | tr "\n" " ")"; done
  '
done
```

| 帳號 | 金鑰 | 來源限制 | sudo |
| --- | --- | --- | --- |
| root（三台共用） | 見 13-3 | 2 行 | — |
| **`proxcenter`**（三台各一份） | 1 把 `proxcenter`（ED25519，三台指紋相同） | **0 行** | **NOPASSWD**：`ovs-ofctl`、`ovs-vsctl`、`ip`、`cat`、`curl`、`echo`、`mkdir`、`qemu-img`、`rbd`、`rm`、`stat`、`tail`、`timeout`、`pvesm` |

用 root 身分執行 `cat`、`rm`、`curl` 就能讀、刪、覆蓋任何檔案，所以**這個帳號實際上等於 root**。這組權限推測是 ProxCenter 的功能需要（OVS、Ceph、儲存），不隨便刪減；先補上和 root 那把 ProxCenter 金鑰一樣的來源限制。

### 13-5 `proxcenter` 加上來源 IP 限制

**① 確認 ProxCenter 的 IP（唯讀）**：

```bash
PCIP=$(grep "root@ProxCenter" /etc/pve/priv/authorized_keys | grep -oP 'from="\K[^"]+'); echo "ProxCenter IP：[$PCIP]"
ha-manager status | grep 'ct:110'
timeout 10 ssh root@<CT 110 所在節點> "pct exec 110 -- hostname -I"
```

看到的結果：root 檔案裡的限制和 CT 110 的 IP 相同；但 CT 110 有**兩張網卡**（`<ProxCenter IP 1>`、`<ProxCenter IP 2>`），另外兩個 `172.17`／`172.18` 是 Docker 內部網路，往外連時會轉成 CT 110 自己的 IP，不用列。

**② 查 `proxcenter` 最近從哪個 IP 登入（唯讀）**：

```bash
for h in node10 node11 node12; do echo "== $h"; timeout 15 ssh root@$h "journalctl --since '-7 days' --no-pager | grep -ci 'proxcenter'"; done
```

三台都是 0：最近一次使用是 10/12 的滾動更新，**看不出它會從哪張網卡連**。所以兩個 IP 都允許，兩個都是 ProxCenter 自己的，不會放寬安全性。

**③ 三台加上限制**：

```bash
PCIP="<ProxCenter IP 1>,<ProxCenter IP 2>"
for h in node10 node11 node12; do
  echo "== $h"
  timeout 15 ssh root@$h "
    F=/home/proxcenter/.ssh/authorized_keys
    cp -a \$F \$F.bak-\$(date +%Y%m%d-%H%M)
    grep -q '^from=' \$F || sed -i 's/^ssh-ed25519 /from=\"$PCIP\",no-port-forwarding,no-agent-forwarding,no-X11-forwarding ssh-ed25519 /' \$F
    grep -c '^from=' \$F
    cut -c1-90 \$F
  "
done
```

| 片段 | 意思 |
| --- | --- |
| `PCIP="…,…"` | 多個來源用逗號分開，中間不能有空白 |
| `cp -a … .bak-日期時間` | 每台先備份（這是一般目錄，備份放旁邊沒問題） |
| `grep -q '^from=' \|\| sed …` | 還沒有限制才加，重複執行也不會加兩次 |
| `cut -c1-90` | 只看每行開頭，確認選項加對了，不把公鑰整行印出來 |

**看到的結果**：node11、node12 各 `1`；**node10 是 `2`**。

**④ node10 多出來的一行**：`ssh-keygen` 在三台都只認得 1 把（指紋相同），node10 卻有 2 行。用 `awk` 拆開每行看長度和公鑰頭尾：

```bash
awk '{k=$0; sub(/^from="[^"]*",[^ ]* /,"",k); split(k,a," "); print "第"NR"行 | 長度:"length($0)" | 類型:"a[1]" | 公鑰開頭:"substr(a[2],1,12)"… 結尾:"substr(a[2],length(a[2])-5)" | 註解:"a[3]}' /home/proxcenter/.ssh/authorized_keys
```

| 行 | 長度 | 公鑰 | 判斷 |
| --- | --- | --- | --- |
| 1 | 128 | 內容就是 `AAAA...` 這幾個字，註解 `proxcenter@node10` | 範例佔位字，推測是照安裝說明貼範例時留下的，從來沒有作用 |
| 2 | 182 | 完整的 ED25519 公鑰 | 真正在用的那把，所以紀錄指向 `:2` |

```bash
F=/home/proxcenter/.ssh/authorized_keys
sed -i '/ssh-ed25519 AAAA\.\.\. /d' $F
grep -c '^from=' $F                              # 1
ssh-keygen -lf $F | awk '{print $2, $3}'
```

`\.` 代表真正的句點，所以只會刪掉公鑰剛好是 `AAAA...` 的那一行。

**⑤ 驗證**：ProxCenter 網頁上三個節點都在線，網路、儲存頁面正常。

| 項目 | 結果 |
| --- | --- |
| 金鑰 | 三台各 1 把，指紋相同 |
| 來源限制 | 只允許 CT 110 的兩個 IP；關閉 port／agent／X11 forwarding |
| 還原 | `for h in node10 node11 node12; do ssh root@$h 'F=/home/proxcenter/.ssh/authorized_keys; cp -a $(ls -t $F.bak-* \| head -1) $F'; done` |

> ⚠️ 來源限制只能防「金鑰被偷到別台用」。**CT 110 本身被入侵時擋不住**，因為這個帳號的 sudo 等於 root。要再縮小，得先查 ProxCenter 實際需要哪些指令（見待辦）。

## 14. 常見問題

| 現象 | 怎麼辦 |
| --- | --- |
| `fail2ban` 是 running，不知道有沒有擋 | 看 `fail2ban.log` 的 Ban 紀錄，再看 `iptables -L f2b-proxmox -n -v` 的計數 |
| 改了設定檔沒生效 | 用 `fail2ban-client -d` 看合併後的值，可能被其他檔案覆蓋 |
| `bantime` 一直顯示 3600 | 那是基礎值；遞增結果看 log 的 `Increase Ban` |
| PVE Firewall service running | 再看 `pve-firewall status` 和 `cluster.fw` 的 `enable` |
| 一直有外部 IP 嘗試登入 | 查路由器有沒有轉送 8006；改用 VPN |
| 啟用 TOTP 後被鎖住 | SSH 登入節點，`pveum user tfa delete`；或用復原碼 |
| 改 authorized_keys 後節點互連失敗 | 立刻用備份還原 |
| 關掉密碼後，某台裝置 SSH 出現 `Permission denied (publickey)` | 這台還沒換金鑰：用 PVE／PBS 網頁的 Shell 把它的公鑰加進去（第 12 節） |
| MobaXterm 連線先問 `login as:` | session 沒勾 Specify username；Edit session 填 `root` |
| 金鑰登入卻還是要輸入 root 密碼 | session 沒設定私鑰；用 `journalctl -u ssh … \| grep Accepted` 看是 `publickey` 還是 `password` |
| `ssh-keygen -lf` 列出的金鑰比檔案行數少 | 有壞掉的行被略過：用 13-3 的逐行檢查找出來，確認 `journalctl` 沒用過再刪 |
| 貼完公鑰還是不能登入，或註解變成 `Generated By` | 公鑰被斷成兩行。先用 `printf '%s\n' "$NEW" \| ssh-keygen -lf -` 檢查再寫入（13-2） |
| 指令貼上後沒反應、像卡住 | 多半是新視窗沒設定 `F`，`grep` 在等鍵盤輸入；按 Ctrl+C，連同 `F=` 那行一起重貼 |
| `/etc/pve/priv/` 出現 `authorized_keys.bak-*` | 在叢集共用目錄做了備份：`rm -i /etc/pve/priv/authorized_keys.bak-*`，備份改放 `/root` |
| 盤點只看 root，漏掉其他帳號 | 一起檢查 `/home/*/.ssh/authorized_keys` 和 `sudo -l -U <帳號>`（13-4） |

## 15. 待辦

- [ ] 約 10/29 刪除已停用的 `hermesagent` token
- [x] 各裝置改用金鑰後，關閉 SSH 密碼登入（2026-10-22，第 12 節）
- [x] 家裡的筆電、手機改用金鑰（2026-10-24，第 13 節）
- [ ] WinClient、家裡的桌機要用 SSH 時再換金鑰（先用網頁 Shell 加公鑰）
- [ ] 刪除舊的管理者筆電金鑰（Windows `ssh-keygen` 產生的那把；公司筆電已改用 `company-laptop-p51`；刪前確認 MobaXterm 用的是新的 `.ppk`）
- [ ] 確認 node10 的 `/etc/pve/priv/authorized_keys.bak-*` 已刪除
- [ ] 手機的 Termius 新增 PBS31 的 Host 並測試
- [ ] 查 ProxCenter 官方文件，評估縮小 `proxcenter` 的 NOPASSWD sudo 清單
- [ ] 確認 ProxCenter 正常幾天後，刪除三台的 `/home/proxcenter/.ssh/authorized_keys.bak-*` 與 node10 的 `/root/authorized_keys.bak-20261024-*`
- [ ] 確認幾天正常後，`shred -u` 刪除 node10 的 `/root/authorized_keys.bak-20261022` 和 PBS31 的 `/root/.ssh/authorized_keys.bak-20261022`
- [x] ~~（可選）Hermes 改用只能執行唯讀指令的帳號~~：2026-10-20 決定不做（目前沒有需求；SSH 金鑰已加 `from=` 來源限制）

## 16. 延伸閱讀

- [不再把 PVE 8006 開到網際網路：改用 WireGuard 連回家](https://kbwangtw.github.io/IT-Knowledge-Base/docs/pve/wireguard-remote-access-replace-8006/)
- [Fail2Ban 1.1.0 設定參考](https://github.com/fail2ban/fail2ban/blob/1.1.0/config/jail.conf)
- [Proxmox Firewall 文件](https://pve.proxmox.com/pve-docs/chapter-pve-firewall.html)
- [Proxmox VE：User Management（TFA）](https://pve.proxmox.com/pve-docs/chapter-pveum.html)
