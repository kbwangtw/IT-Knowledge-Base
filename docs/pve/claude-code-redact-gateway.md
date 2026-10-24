---
layout: default
title: "用 Claude Code 取代 Hermes：去識別化閘道與手機遙控"
date: 2026-10-24
categories: [AI, Security, PVE]
permalink: /docs/pve/claude-code-redact-gateway/
last_modified_at: 2026-10-24
---

{% raw %}
# 用 Claude Code 取代 Hermes：去識別化閘道與手機遙控

> **一句話**：原本的維運流程是「AI 給指令 → 人複製到節點 → 貼回輸出」。這篇把 Claude Code 裝在內網的 CT113，讓它自己透過一支去識別化閘道 `rx` 對節點下指令：真實 IP、網域、帳號只留在本機，送上雲的只有代稱；每個指令都要人按同意，手機也能遙控。用不到的 Hermes Agent 一併移除。

| 項目 | 內容 |
| --- | --- |
| 適合誰看 | 想讓 AI 幫忙操作伺服器，但不想把 IP、帳號、密碼送上雲的人 |
| 環境 | PVE 9.2.21 三節點；CT113（ai，Debian）；Claude Code 2.1.310（Pro 方案）；Claude 手機 App |
| 日期 | 2026-10-24 |
| 結論 | ✅ `rx` 閘道（遮蔽、封鎖高風險指令）✅ 一般帳號 `ops` 只能 sudo `rx`，讀不到對照表 ✅ Claude Code 照 SOP 完成唯讀健康檢查，人只按同意 ✅ Remote Control：手機下指令、推播同意 ✅ Hermes 移除（釋出約 1.5G）⏳ Hermes 的外部 token 撤銷 ⏳ 開機自動啟動、GitHub 推送 |

## 1. 先認識幾個名詞

| 名詞 | 白話解釋 |
| --- | --- |
| **Claude Code** | Anthropic 的命令列 AI 助手，能讀檔、執行指令、寫文件；修改前會先問人 |
| **Hermes Agent** | 另一套 AI agent，以 Telegram 等訊息平台為主，本案原本裝在 CT113 |
| **去識別化（redact）** | 把真實值換成代稱，例如 IP 換成 `<node10-IP>` |
| **對照表** | `/root/.redact-map`，記錄「代稱 ↔ 真實值」，只留在 CT113 |
| **`rx` 閘道** | 本案寫的小程式：指令裡的代稱換回真實值 → SSH 執行 → 輸出遮蔽後才交給 Claude Code |
| **Remote Control** | Claude Code 官方功能：用 claude.ai 或手機 App 操作內網那台機器上正在跑的 Claude Code |
| **tmux** | 讓程式在背景持續執行的工具；SSH 斷線也不會停 |
| **Channels** | Claude Code 的研究預覽功能，可接 Telegram、Discord；本案先不用 |

## 2. 為什麼這樣設計

先問三個問題，決定了做法：

| 問題 | 答案 | 影響 |
| --- | --- | --- |
| 想省掉的是什麼？ | 複製指令、貼回輸出這兩段 | AI 要能自己執行、自己讀結果 |
| Hermes 有在用嗎？ | 很少用，不知道它能做什麼；模型只是用 Ollama 測試 | 不必兩個 agent 並存 |
| 資料能上雲嗎？ | 帳號、密碼、金鑰、客戶名稱、IP **去識別化後**可以 | 中間要有一道去識別化，而且 AI 不能繞過 |

| 做法 | 評估 |
| --- | --- |
| **A. 只留 Claude Code（採用）** | 判斷和執行是同一個 AI，指令不會被轉手改寫；照知識庫的 `CLAUDE.md` 工作；修改前一律先問 |
| B. Hermes 當 Telegram 入口、Claude Code 做事 | 兩層 AI，指令可能被改寫，「每一步先問」較難做到 |
| C. 只留 Hermes，模型換成 Claude | Hermes 預設會自己執行到底，不會每步停下來問 |

```text
手機（Claude App）／ MobaXterm
   │  說要做什麼、按同意
   ▼
CT113：Claude Code（ops 帳號，tmux 內持續執行，Remote Control）
   │  讀知識庫 SOP → 規劃指令 → 每個 rx 都先問人
   ▼
sudo /usr/local/bin/rx（root）
   │  ① 代稱 → 真實值  ② 高風險指令直接拒絕
   ▼
SSH 到 node10／11／12（CT113 的 root@ai 金鑰，已有 from= 來源限制）
   ▼
   ③ 輸出：真實值 → 代稱；密碼類整段遮掉；沒列到的 IP → <IP>
   ▼
Claude Code 只看得到遮蔽後的結果
```

**關鍵是權限隔離**：Claude Code 用一般帳號 `ops` 執行，讀不到對照表、也沒有 SSH 金鑰，唯一能碰節點的路是 `sudo rx`。不是靠「叫 AI 不要直接 SSH」，而是系統權限上就做不到。

## 3. 步驟一：停用 Hermes

```bash
pct exec 113 -- bash -c '
  systemctl disable --now hermes-gateway
  echo "gateway: $(systemctl is-active hermes-gateway) / $(systemctl is-enabled hermes-gateway)"
  ps -eo pid,args | grep -i "[h]ermes" || echo "none"
  crontab -l 2>/dev/null | grep -i hermes || echo "none"
'
pct exec 113 -- bash -c 'systemctl reset-failed hermes-gateway; systemctl --failed --no-legend | wc -l'
```

看到的結果：`failed / disabled`。服務被停時沒有正常結束，systemd 標成 failed；用 `reset-failed` 清掉，failed unit 回到 0，免得之後的健康檢查一直算到它。沒有殘留程序、沒有 crontab。

## 4. 步驟二：建立對照表

### 4-1 IP 自動產生（畫面只顯示代稱）

在 node10 用 DNS 和 corosync 設定產生，**真實值不出現在畫面上**：

```bash
umask 077; OUT=/root/redact-map.draft
{
  echo "# 類型 | 代稱 | 真實值"
  for n in node10 node11 node12 pbs31 tokyo16 melayu17 adguard pihole librenms ipam graylog wireguard proxcenter wazuh ai grafana dc01 dc02 ca winclient ubclient; do
    ip=$(getent ahostsv4 $n | awk 'NR==1{print $1}')
    [ -n "$ip" ] && echo "ip | <$n-IP> | $ip" || echo "#MISSING $n" >&2
  done
  awk '/name:/{n=$2} /ring0_addr:/{print "ip | <" n "-cluster-IP> | " $2}' /etc/pve/corosync.conf
} > $OUT
grep '^ip' $OUT | cut -d'|' -f2 | tr '\n' ' '; echo
pct push 113 $OUT /root/.redact-map --perms 600
shred -u $OUT
```

| 片段 | 意思 |
| --- | --- |
| `umask 077` | 建出來的檔案只有 root 能讀 |
| `getent ahostsv4` | 用 DNS 查 IPv4 |
| `ring0_addr` | 叢集網段的 IP |
| `cut -d'\|' -f2` | 畫面只顯示第 2 欄（代稱） |
| `pct push … --perms 600`、`shred -u` | 搬進 CT113，覆寫刪除 node10 上的草稿 |

看到的結果：22 筆（19 台主機 + 3 個叢集 IP）；`winclient`、`ubclient` 查不到（用戶端 VM），沒關係，沒列到的 IP 會自動遮成 `<IP>`。

### 4-2 手動補上查不到的

範本見 [tools/redact-gateway/redact-map.example](https://github.com/kbwangtw/IT-Knowledge-Base/blob/main/tools/redact-gateway/redact-map.example)。範本行先加 `#`，填好真實值再刪 `#`：

| 類型 | 本案補的 |
| --- | --- |
| `domain` | 內部 AD 網域（沒有對外網域） |
| `ip` | 公網 IP（自動遮蔽也會遮，但列名稱比較好認）、DNS 查不到的內網主機 |
| `word` | NAS、PBS 帳號、Windows 網域名稱、個人帳號 |
| `text` | 叢集名稱、CA 名稱（`certutil -CAInfo name`）、公司名稱 |

**檢查只看數字**：

```bash
pct exec 113 -- bash -c 'F=/root/.redact-map; ls -l $F; for t in ip domain word text; do echo "$t: $(grep -cE "^$t *\|" $F)"; done; echo "格式錯誤的行: $(grep -vE "^(#|$)" $F | awk -F"|" "NF!=3" | wc -l)"'
```

本案最後 ip 27、domain 1、word 3、text 3，格式錯誤 0。過程中兩件事：

- 檢查「還留著範本示範值」的行抓到 1 筆，實際帳號剛好和示範值同名，是誤判。
- PBS 帳號一開始填了 `root`，結果所有輸出裡的 `root`（`/root`、`root@node10`）都被遮成 `<PBS帳號>`。**通用字不要放進對照表**，改成註解保留說明。

> 密碼、token、私鑰**不寫進對照表**：`rx` 用規則直接整段遮掉，不需要知道真實值。SNMP v2c 的 community 也屬於這類。

## 5. 步驟三：`rx` 閘道

程式見 [tools/redact-gateway/rx](https://github.com/kbwangtw/IT-Knowledge-Base/blob/main/tools/redact-gateway/rx)（Python 3，約 100 行）。

| 功能 | 做法 |
| --- | --- |
| 可連的主機 | 只有 `node10`、`node11`、`node12`；**PBS31 不開放**（備份伺服器不給其他主機 root 權限）；LXC 透過 `pct exec` |
| 代稱換回真實值 | 指令裡寫 `<node10-IP>`，執行前換成真的 |
| 封鎖 | `rm -rf /`、`reboot`、`shutdown／poweroff／halt`、`mkfs`、`dd of=/dev/`、`pvecm delnode`、`ceph osd purge／destroy`、`wipefs` 等直接拒絕，回傳 3 |
| 遮蔽秘密 | 私鑰區塊、`password=／token:／secret` 之類的值、SNMP community、PVE API token、`Authorization` 標頭、密碼雜湊、公鑰本體 |
| 遮蔽識別資訊 | 對照表的值（長的先換）；網域含子網域；帳號比對完整單字；剩下的 IPv4 → `<IP>`（`127.x`、`255.x` 保留）；IPv6、MAC 位址；日誌時間 `12:34:56` 不會被誤遮 |
| 紀錄 | 每個指令（真實內容）記在 CT113 的 `/var/log/rx.log`，只有 root 能讀 |

**安裝**：在 node10 用 `cat > /root/rx <<'EOF' … EOF` 建檔（引號包住 `EOF`，內容原樣寫入），再推進 CT113：

```bash
pct push 113 /root/rx /usr/local/bin/rx --perms 755 && rm /root/rx
pct exec 113 -- bash -c 'python3 -m py_compile /usr/local/bin/rx && echo COMPILE-OK'
```

**給 CT113 正確的主機金鑰**：最可靠的是從各節點**本機**讀出 SSH 服務實際使用的主機公鑰，透過 node10 本來就驗證過的叢集連線取得（比 `ssh-keyscan` 的「第一次看到就相信」安全）：

```bash
pct exec 113 -- bash -c 'F=/root/.ssh/known_hosts; touch $F; chmod 600 $F; [ -n "$(tail -c1 $F)" ] && echo >> $F; true'
for n in node10 node11 node12; do echo "$n $(ssh root@$n 'cut -d" " -f1,2 /etc/ssh/ssh_host_ed25519_key.pub')"; done | pct exec 113 -- bash -c 'cat >> /root/.ssh/known_hosts'
```

**測試**：

```bash
pct exec 113 -- /usr/local/bin/rx node10 'hostname -f; ip -br addr | head -6; head -6 /etc/hosts'
pct exec 113 -- /usr/local/bin/rx node10 'reboot'; echo "exit=$?"
```

看到的結果：

```text
node10.<網域>
lo               UNKNOWN        127.0.0.1/8 <IPv6>/128
vmbr0            UP             <node10-IP>/24 <IPv6>/64
Cluster          UP             <node10-cluster-IP>/24 <IPv6>/64
<node11-IP> node11.<網域> node11
rx：已封鎖高風險指令（規則 \breboot\b），請由管理者手動執行
exit=3
```

判讀需要的資訊（網卡名稱、狀態、`/24`、`127.0.0.1`）都留著，真實值全部換成代稱。

## 6. 步驟四：`ops` 帳號，讓 Claude Code 只能走閘道

```bash
pct exec 113 -- bash -c '
  id ops 2>/dev/null || useradd -m -s /bin/bash ops
  echo "ops ALL=(root) NOPASSWD: /usr/local/bin/rx" > /etc/sudoers.d/ops-rx
  chmod 440 /etc/sudoers.d/ops-rx
  visudo -cf /etc/sudoers.d/ops-rx
  sudo -l -U ops | sed -n "/may run/,\$p"
  su - ops -c "cat /root/.redact-map >/dev/null 2>&1 && echo YES-危險 || echo no（正確）"
'
```

| 片段 | 意思 |
| --- | --- |
| `/etc/sudoers.d/ops-rx` | `ops` 只能 sudo 這一個程式 |
| `visudo -cf` | 檢查語法；sudoers 寫錯會讓 sudo 壞掉 |
| `cat /root/.redact-map` 測試 | 確認讀不到對照表 |

看到的結果：`parsed OK`、`(root) NOPASSWD: /usr/local/bin/rx`、`no（正確）`。

## 7. 步驟五：安裝、設定 Claude Code

**安裝**（官方安裝程式，不需要 Node.js，裝在 `ops` 底下，和 root 分開）：

```bash
pct exec 113 -- su - ops -c 'curl -fsSL https://claude.ai/install.sh | bash'
pct exec 113 -- su - ops -c '~/.local/bin/claude --version; which -a claude'
pct exec 113 -- su - ops -c 'grep -q "\.local/bin" ~/.bashrc || echo "export PATH=\"\$HOME/.local/bin:\$PATH\"" >> ~/.bashrc'
```

看到的結果：`2.1.310 (Claude Code)`、`/home/ops/.local/bin/claude`。

**登入**（要互動畫面）：`pct enter 113` → `su - ops` → `claude` → 主題照預設 → **Claude account with subscription** → 網址貼到筆電瀏覽器授權 → 代碼貼回。

**clone 知識庫**（目前只讀，不能推送）：

```bash
pct exec 113 -- su - ops -c 'git clone -q https://github.com/kbwangtw/IT-Knowledge-Base.git'
```

**權限設定** `~/.claude/settings.json`：

```json
{
  "permissions": {
    "defaultMode": "default",
    "allow": ["Bash(git status:*)", "Bash(git diff:*)", "Bash(git log:*)", "Bash(ls:*)", "Bash(grep:*)", "Bash(wc:*)"],
    "ask":   ["Bash(sudo /usr/local/bin/rx:*)", "Bash(git commit:*)", "Bash(git push:*)"],
    "deny":  ["Bash(ssh:*)", "Bash(scp:*)", "Bash(rsync:*)", "Bash(sudo -i:*)", "Bash(sudo su:*)", "Bash(rm -rf:*)", "Read(/root/**)"]
  }
}
```

| 分類 | 意思 |
| --- | --- |
| allow | 只讀知識庫的本機指令，自動放行 |
| ask | **所有 `rx`**（連唯讀的也問）、commit、push |
| deny | 直接 SSH、切成 root、`rm -rf`、讀 `/root`：第二道防線（系統權限上本來就做不到） |

**工作守則** `~/.claude/CLAUDE.md`（和知識庫的 `CLAUDE.md` 一起被讀取）：

```text
- 對節點下指令一律用：sudo /usr/local/bin/rx <node10|node11|node12> '<指令>'
- LXC：sudo /usr/local/bin/rx <節點> 'pct exec <CTID> -- <指令>'
- 輸出中的 <node10-IP>、<網域>、<IP>、<SECRET> 是代稱；指令裡可以直接寫代稱
- 不要嘗試直接 ssh、讀取 /root、或繞過 rx；被 rx 擋下時告訴使用者要手動執行什麼
- 動手前先照 SOP 做唯讀檢查，說明要做什麼、為什麼、怎麼還原；修改前先快照或備份
- 一次一步，結果不如預期就停下來回報；寫文件時保留代稱
```

第一次啟動時會問要不要把預設改成 **auto mode**（由 Claude 自己判斷哪些指令可以直接跑），選 **No, keep manual mode**：剛開始要看過每個指令。

## 8. 步驟六：驗收

```bash
pct enter 113
su - ops
cd ~/IT-Knowledge-Base     # 讀得到知識庫的 CLAUDE.md
claude
```

任務：

```text
請照 docs/pve/proxcenter-ceph-rolling-update.md 第 12-1 節的「更新前檢查」，對 node10～node12 做一次唯讀健康檢查：quorum、Ceph、HA 服務、各節點的 kernel 和可更新套件數。用表格回報結果。這次不要修改任何東西。
```

| 觀察 | 結果 |
| --- | --- |
| 每個指令 | 都是 `sudo /usr/local/bin/rx node1X "…"`，跳出 `Permission rule Bash(sudo /usr/local/bin/rx:*) requires confirmation` |
| 第一次被拒絕三次（操作失誤） | 它停下來說明原因並問怎麼做，**沒有試圖繞過** |
| node11、node12 `Host key verification failed` | 它**沒有自己清掉 known_hosts**，提醒可能是中間人攻擊，先問人（原因見常見問題） |
| 結果 | 三台 7.0.14-25-pve、pve-manager 9.2.21、可更新 0；HA 13 個 started；還注意到 ct:110 的位置和 SOP 記錄不同，並說對了原因 |
| 人做了什麼 | **只按同意，沒有複製貼上任何指令** |

## 9. 步驟七：Remote Control（手機遙控）

| 項目 | 說明 |
| --- | --- |
| 方案 | Pro、Max、Team、Enterprise；API key 不支援 |
| 運作 | Claude Code 照樣在 CT113 執行，手機只是遙控畫面 |
| 前提 | `claude` 要一直開著：放在 **tmux** 裡 |
| 資料 | 對話紀錄存在 Anthropic（內容已遮蔽） |

```bash
pct exec 113 -- bash -c 'command -v tmux >/dev/null || apt-get install -y tmux'
# 互動畫面：
pct enter 113
su - ops
tmux new -s claude
cd ~/IT-Knowledge-Base
claude --remote-control "Lab Ops"
```

1. 第一次問 **Enable Remote Control?** → 同意。
2. `/config` → 開 **Push when actions required**（需要同意時手機跳通知）。
3. `/remote-control` 顯示網址和 QR code → 手機掃描打開 Claude App（或 App → Code → **Lab Ops**）。
4. 離開 tmux：**Ctrl + B**，放開，再按 **D**，看到 `[detached (from session claude)]`。回來：`tmux attach -t claude`。

測試：手機輸入「請用 rx 查一下 node11 的 Ceph 狀態（ceph -s），只要唯讀」→ 手機跳出同意 → `HEALTH_OK`。

> Telegram 也做得到（Channels：`/plugin install telegram@claude-plugins-official`、`claude --channels plugin:telegram@claude-plugins-official`），但是研究預覽、要裝 Bun，而且 `rx` 要同意時能不能從 Telegram 回覆要看外掛支援（未確認）。先用 Remote Control。

## 10. 步驟八：移除 Hermes

**盤點**（只看名稱，不看值）：

| 項目 | 位置 |
| --- | --- |
| 啟動腳本 | `/usr/local/bin/hermes`（147 bytes，執行 `/usr/local/lib/hermes-agent/venv/bin/python …`） |
| 程式本體 | `/usr/local/lib/hermes-agent/` |
| 資料 | `/root/.hermes/`（1.2G） |
| uv 與它的 Python | `/root/.local/share/uv`（321M），只裝了 Hermes 的瀏覽器工具 `browser-use` |
| 其他 | 服務檔、`~/.local/bin` 的連結、`.bashrc`／`.profile` 的 `. "$HOME/.local/bin/env"` |
| 外部憑證（`.env` 只看等號左邊） | `TELEGRAM_BOT_TOKEN`、`OLLAMA_API_KEY` |

```bash
pct snapshot 113 pre-hermes-removal --description "before removing Hermes Agent"
pct exec 113 -- bash -c '
  set -e
  rm -f /etc/systemd/system/hermes-gateway.service; systemctl daemon-reload
  rm -f /usr/local/bin/hermes
  rm -rf /usr/local/lib/hermes-agent /root/.hermes /root/.local/share/uv /root/.cache/uv
  rm -f /root/.local/bin/{node,npm,npx,python3.11,uv,uvx,env,env.fish}
  sed -i "/\.local\/bin\/env/d" /root/.bashrc /root/.profile
'
```

看到的結果：`hermes` 已移除、`~/.local/bin` 0 個、系統 Node v22.23.4 不受影響、failed 0、根目錄 16G／61G；`ops` 的 Claude Code 2.1.310 不受影響。

> 刪檔案不等於 token 失效：快照、PBS 備份裡都還有。要到 Telegram（@BotFather）和 ollama.com 撤銷（見待辦）。

## 11. 常見問題

| 現象 | 怎麼辦 |
| --- | --- |
| `pct exec 113 -- rx …`：`Failed to exec "rx"` | `pct exec` 的 PATH 沒有 `/usr/local/bin`，寫完整路徑 `/usr/local/bin/rx` |
| 指令最後 `\| rx --test` 出現 `No such file` | 管線放在 `pct exec` 外面，變成在 node10 執行；要放進 `bash -c '…'` 裡面 |
| `Host key verification failed`（只有部分節點） | CT113 沒有那台的主機金鑰。`/etc/pve/priv/known_hosts` 推測只有部分節點；改從各節點讀 `/etc/ssh/ssh_host_ed25519_key.pub` |
| 剛寫入的 known_hosts 第一筆無效、第二筆有效 | 檔案最後一行沒換行，新內容黏到上一行；寫入前先 `[ -n "$(tail -c1 $F)" ] && echo >> $F` |
| 輸出裡 `/root` 變成 `<PBS帳號>` | 對照表放了 `root` 這種通用字；改成註解 |
| `systemctl` 顯示服務 `failed`，但其實是自己停掉的 | `systemctl reset-failed <服務>` |
| 安裝程式說 `~/.local/bin is not in your PATH`，`which` 卻找得到 | `su -` 讀 `.profile`，資料夾存在時才加進 PATH；照提示加進 `.bashrc` 保險 |
| Claude Code 說被拒絕三次 | 選項直接按數字鍵 `1`，不要按 Esc |
| 畫面一直提示 `N MCP servers need authentication` | 帳號的 connector 同步過來；這台不需要，不要授權 |
| 關掉 MobaXterm 後手機連不上 | Claude Code 沒在 tmux 裡；重開 `tmux new -s claude` → `claude --remote-control "Lab Ops"` |
| 額度用得快 | 和其他 Claude 對話共用 Pro 額度；例行檢查用 `/model` 切到 Sonnet |

## 12. 待辦

- [ ] 開啟 claude.ai 的 **Require trusted devices**（只有驗證過的裝置能操作 Remote Control）
- [ ] 撤銷 Hermes 的 Telegram 機器人（@BotFather → Delete Bot）與 Ollama key；刪除 PVE 的 `hermesagent` token
- [ ] CT113 開機後自動啟動 tmux + Claude Code（systemd）
- [ ] 給 `ops` 一把只能寫這個 repo 的金鑰，讓它自己寫文件、送 PR
- [ ] 用幾天後，把常用唯讀指令（例如 `ceph -s`、`ha-manager status`）加進 allow
- [ ] 幾天後刪除 CT113 快照 `pre-node22`、`pre-hermes-removal`；決定 `/root/generate_pptx.js` 是否保留
- [ ] 清掉 CT113 `known_hosts` 裡那一行黏壞的記錄

## 13. 延伸閱讀

- [Claude Code 官方文件：Remote Control](https://code.claude.com/docs/en/remote-control.md)
- [Claude Code 官方文件：Channels（Telegram、Discord）](https://code.claude.com/docs/en/channels)
- [Claude Code 官方文件：權限模式](https://code.claude.com/docs/en/permission-modes)
- [tools/redact-gateway](https://github.com/kbwangtw/IT-Knowledge-Base/tree/main/tools/redact-gateway)：`rx` 與對照表範例
- [Node2Shell 與 LiteLLM：檢查環境有沒有中](https://kbwangtw.github.io/IT-Knowledge-Base/docs/pve/node2shell-litellm-check/)：同日 CT113 的 Node.js 更新
- [PVE 一直被嘗試登入：怎麼確認 Fail2Ban 真的有擋？](https://kbwangtw.github.io/IT-Knowledge-Base/docs/pve/pve-cluster-fail2ban-hardening/)：`root@ai` 金鑰的 `from=` 限制
{% endraw %}
