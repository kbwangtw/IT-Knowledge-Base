---
layout: default
title: "Node2Shell（CVE-2026-111497）與 LiteLLM 供應鏈攻擊：檢查環境有沒有中、怎麼修補"
date: 2026-10-24
categories: [Security, Node.js, PVE]
permalink: /docs/pve/node2shell-litellm-check/
last_modified_at: 2026-11-01
---
{% raw %}

# Node2Shell（CVE-2026-111497）與 LiteLLM 供應鏈攻擊：檢查環境有沒有中、怎麼修補

> **一句話**：10/21 公開的 Node.js Brotli 漏洞和 LiteLLM 1.107.0 惡意版本，從 node10 一次掃完所有 LXC：沒有任何一台裝 LiteLLM；有 Node.js 的三台裡，IPAM、ai（系統與 Hermes 自帶）已更新到 22.23.4，ProxCenter 和 Wazuh 是程式自帶的 Node.js，要等廠商出新版。

| 項目 | 內容 |
| --- | --- |
| 適合誰看 | 聽到 Node.js 或 Python 套件出事，想知道自己哪些主機受影響、怎麼判斷修補了沒有的人 |
| 環境 | PVE 三節點的 10 個 LXC（Debian 12／13、Ubuntu 22.04／24.04） |
| 日期 | 2026-10-24 |
| 結論 | ✅ 沒有 LiteLLM ✅ CT103 IPAM 22.23.3 → 22.23.4 ✅ CT113 ai 系統 20.20.2 → 22.23.4（NodeSource 換成 22.x）✅ CT113 Hermes 自帶 22.22.2 → 22.23.4 ⏳ CT110 ProxCenter 前端容器：10/24 是 v26.10.0；10/29 更新到 v1.4.12 後是 v26.12.0，**仍低於修補版 26.12.1**⏳ CT112 Wazuh Dashboard 自帶 Node 18／14 ⏳ PVE、PBS31、GCP 主機未掃 |

## 1. 先認識幾個名詞

| 名詞 | 白話解釋 |
| --- | --- |
| **Node2Shell（CVE-2026-111497）** | Node.js 內建的 Brotli 解壓縮有記憶體越界寫入；用 `fetch()`、Express 5、zlib 解壓縮**惡意資料**時會觸發，有人展示過遠端執行程式碼 |
| **Brotli** | 一種壓縮格式，網頁常用（`Content-Encoding: br`） |
| **LiteLLM** | 統一呼叫各家 AI 模型的 Python 套件，也可以當 Proxy 伺服器 |
| **供應鏈攻擊** | 攻擊者把惡意程式放進正式發佈的套件；**照常安裝就中毒** |
| **NodeSource** | 第三方的 Node.js 套件來源，網址裡的 `node_20.x`、`node_22.x` 決定主版本 |
| **程式自帶的 Node.js** | 有些軟體把 Node.js 一起打包（Wazuh Dashboard、Docker 映像檔、Hermes），**系統的 apt 更新修不到** |
| **dist-info** | Python 套件的安裝紀錄資料夾，名稱帶版本號，例如 `litellm-1.106.2.dist-info` |

| 項目 | 有問題 | 修補／安全的版本 |
| --- | --- | --- |
| Node.js | 22／24／26 的舊版；**20.x 以前、23.x、25.x 已停止支援，沒有修補** | **22.23.4、24.22.1、26.12.1** |
| LiteLLM 惡意版 | **1.107.0**（PyPI 和 Docker，10/21 發佈，會竊取帳密） | 1.106.2 或 10/21 以前的版本；裝過 1.107.0 要當作已被入侵 |
| LiteLLM CVE-2026-114612（權限提升）、CVE-2026-89032（快取隔離） | 只影響當成 **Proxy 伺服器**使用 | 1.100.4、1.101.3、1.102.2、1.103.1 以後 |

> 系統的 `libbrotli1` 是另一回事：Debian 已經出修補，10/24 PVE／PBS31 更新和 LXC 的自動安全更新會處理。這篇要找的是**Node.js 執行檔本身**。

## 2. 全貌

```text
從 node10 掃描所有 LXC：Node.js 執行檔（含程式自帶）、LiteLLM、Docker 容器
  ├─ 系統安裝的 Node.js ──▶ 小版本落後：apt 升級（CT103）
  │                      └▶ 主版本停止支援：換 NodeSource 來源（CT113）
  ├─ 程式自帶、可替換 ────▶ 只換執行檔，保留套件（CT113 Hermes）
  └─ 程式自帶、不能自己換 ─▶ 查廠商新版；先降低曝險（ProxCenter、Wazuh）
```

## 3. 步驟一：一次掃描所有 LXC（只讀取）

**做什麼**：不只看 `apt`，還要用 `find` 找出**所有** `node` 執行檔，包含程式自帶的；同時找 LiteLLM 的安裝紀錄和 Docker 容器。

**怎麼做**（在 node10）：

```bash
for h in node10 node11 node12; do
  ssh -o BatchMode=yes root@$h bash -s <<'EOS'
for id in $(pct list | awk 'NR>1 && $2=="running"{print $1}'); do
  r=$(timeout 120 pct exec $id -- sh -c '
    for b in $(find /usr /opt /root /home /srv /var/lib -xdev -type f \( -name node -o -name nodejs \) -perm -u+x 2>/dev/null); do
      v=$($b -v 2>/dev/null) && echo "  Node.js $v  $b"
    done
    for d in $(find /usr /opt /root /home /srv /var/lib -xdev -type d -name "litellm-*.dist-info" 2>/dev/null); do
      echo "  LiteLLM $(basename $d .dist-info | cut -d- -f2)  $(dirname $d)"
    done
    command -v docker >/dev/null && docker ps --format "{{.Names}} {{.Image}}" 2>/dev/null | sed "s/^/  docker: /"
  ' 2>/dev/null)
  name=$(pct config $id | awk '/^hostname:/{print $2}')
  if [ -n "$r" ]; then echo "== $(hostname) CT$id ($name)"; echo "$r"; else echo "-- $(hostname) CT$id ($name): none"; fi
done
EOS
done
```

| 片段 | 意思 |
| --- | --- |
| `find … -name node -o -name nodejs` | 找出所有 Node.js 執行檔，包括 `/usr/share/wazuh-dashboard/node/bin/node` 這種自帶的 |
| `$b -v` | 問每個執行檔的版本 |
| `litellm-*.dist-info` | 有沒有裝 LiteLLM、哪一版 |
| `docker ps` | 容器裡又跑 Docker 的（例如 ProxCenter），列出容器名稱和映像檔 |
| `-xdev` | 不跨到其他磁碟，避免掃到掛進來的 NAS |
| `timeout 120` | 單一容器最多 2 分鐘 |

**看到的結果**：

| CT | 找到 | 判讀 |
| --- | --- | --- |
| 103 IPAM | Node.js v22.23.3 `/usr/bin/node` | 🔴 差一版 |
| 110 ProxCenter | 4 個 Docker 容器（orchestrator、frontend、weasyprint、postgres），`find` 沒掃到 Node | ❓ 要進容器查 |
| 113 ai | v20.20.2 `/usr/bin/node`、v22.22.2 `/root/.hermes/node/bin/node` | 🔴 20.x 停止支援；Hermes 自帶的也落後 |
| 112 Wazuh | v18.19.0、v14.21.3（`/usr/share/wazuh-dashboard/node/…`） | 🔴 都已停止支援，廠商自帶 |
| 100、101、102、105、109、114 | none | ✅ |
| 全部 | **沒有任何 LiteLLM** | ✅ |

## 4. 步驟二：查清楚每一處（只讀取）

```bash
pct exec 103 -- sh -c 'apt-cache policy nodejs | head -4; ps -eo pid,user,args | grep -E "[n]ode " | cut -c1-120'
pct exec 113 -- sh -c 'apt-cache policy nodejs | head -4; ls /etc/apt/sources.list.d/; ps -eo pid,user,args | grep -E "[n]ode " | cut -c1-120'
pct exec 110 -- sh -c 'for c in $(docker ps --format "{{.Names}}"); do echo -n "$c: "; docker exec $c sh -c "node -v 2>/dev/null || echo no-node"; done'
ssh root@node11 "pct exec 112 -- sh -c 'dpkg -l wazuh-dashboard | awk \"/^ii/{print \\\$2, \\\$3}\"; ss -tlnp | grep -E \":443|:5601\"'"
```

| CT | 結果 | 處理方式 |
| --- | --- | --- |
| 103 IPAM | NodeSource，Installed 22.23.3、**Candidate 22.23.4**；沒有 Node 程式在執行 | apt 升級 |
| 113 ai | NodeSource `node_20.x`，Candidate 也是 20.20.2（**不會再有修補**）；沒有 Node 程式在執行 | 換成 `node_22.x` |
| 110 ProxCenter | 只有 `proxcenter-frontend` 有 Node：**v26.10.0** | 看有沒有新映像檔 |
| 112 Wazuh | `wazuh-dashboard 4.14.8-1`，`node` 監聽 `0.0.0.0:443` | 等廠商 |

> **為什麼自動安全更新沒修 CT103？** unattended-upgrades 只設定收 Debian／Ubuntu 官方的安全性更新，NodeSource 是第三方來源，不在範圍內，要手動更新。

## 5. 步驟三：CT103 小版本升級

```bash
pct snapshot 103 pre-node22234 --description "before nodejs 22.23.4"
pct exec 103 -- sh -c 'apt-get update -qq && apt-get install -y --only-upgrade nodejs >/dev/null && node -v'
pct exec 103 -- systemctl --failed --no-legend | wc -l
```

| 片段 | 意思 |
| --- | --- |
| `pct snapshot` | 先拍快照 |
| `--only-upgrade nodejs` | 只升級 nodejs，不動其他套件 |

**看到的結果**：`v22.23.4`、failed 0、needrestart 顯示沒有服務需要重啟；IPAM 網頁登入、查詢正常。

## 6. 步驟四：CT113 系統 Node.js 換主版本（20 → 22）

**先看設定**：

```bash
pct exec 113 -- sh -c 'cat /etc/apt/sources.list.d/nodesource.sources; npm ls -g --depth=0 2>/dev/null; ls /root/node_modules | head; ls /root/*.js'
```

`URIs: https://deb.nodesource.com/node_20.x`；全域只有 `corepack`、`npm`；`/root/node_modules` 是 `pptxgenjs`、`jszip` 等純 JavaScript 套件，給 `/root/generate_pptx.js` 用（`generate_pptx.js` 已於 2026-10-30 刪除，`/root/node_modules` 是它的相依套件；2026-11-01 已清理：先用 `grep -rl pptxgenjs /root` 確認沒有 JavaScript 檔引用它，再 `rm -r /root/node_modules`，`package.json` 與 `package-lock.json` 保留，要還原時 `npm ci`）。

**換來源並升級**：

```bash
pct snapshot 113 pre-node22 --description "before nodesource 20.x -> 22.x"
pct exec 113 -- sh -c '
  F=/etc/apt/sources.list.d/nodesource.sources
  cp -a $F /root/nodesource.sources.bak
  sed -i "s#/node_20.x#/node_22.x#" $F
  grep URIs $F
  apt-get update -qq && apt-get install -y nodejs >/dev/null
  echo "node $(node -v), npm $(npm -v)"
  cd /root && node -e "require(\"pptxgenjs\"); require(\"jszip\"); console.log(\"modules OK\")"
'
```

| 片段 | 意思 |
| --- | --- |
| `cp -a … /root/…bak` | 備份放 `/root`，**不要**放在 `sources.list.d/`，否則 apt 會讀到它 |
| `sed … node_20.x → node_22.x` | 改成 22.x 的來源 |
| `node -e "require(…)"` | 確認腳本用的模組在 Node 22 下載得進來，不實際產生檔案 |

**看到的結果**：`node_22.x`、`node v22.23.4`、`modules OK`。

## 7. 步驟五：CT113 Hermes 自帶的 Node.js（只換執行檔）

**先查結構**：

```bash
pct exec 113 -- bash -lc '
  ls ~/.hermes/node/lib/node_modules
  ls ~/.local/bin; readlink -f ~/.local/bin/node
  /usr/local/bin/hermes --version
  systemctl list-units --all --no-legend | grep -i hermes
'
```

| 發現 | 意思 |
| --- | --- |
| `~/.hermes/node/lib/node_modules` 有 `@anthropic-ai/claude-code`（2.1.185）、`corepack`、`npm` | 整個資料夾換掉會讓這些套件壞掉 |
| `~/.local/bin/node` → `/root/.hermes/node/bin/node` | root 登入時 `~/.local/bin` 排在 `/usr/bin` 前面，**手動打 `node` 用的是 Hermes 自帶的那個** |
| Hermes Agent v0.20.5（2026.8.19），以 `hermes-gateway.service` 常駐 | gateway 是 Python；Node 只在用到瀏覽器工具、Claude Code 時啟動 |

Hermes 官方文件只說 `hermes update` 會更新程式和相依套件，**沒寫會不會更新自帶的 Node**。漏洞在 Node 執行檔本身，同樣是 v22，所以只替換 `bin/node`：

```bash
pct exec 113 -- bash -lc '
set -e
V=v22.23.4; T=node-$V-linux-x64.tar.xz; D=/root/node-dl
mkdir -p $D && cd $D
curl -fsSLO https://nodejs.org/dist/$V/$T
curl -fsSLO https://nodejs.org/dist/$V/SHASUMS256.txt
grep " $T\$" SHASUMS256.txt | sha256sum -c -
tar -xJf $T node-$V-linux-x64/bin/node
N=~/.hermes/node/bin/node
cp -a $N $N.bak-v22.22.2
install -m 755 node-$V-linux-x64/bin/node $N
echo "hermes node: $($N -v)   login-shell node: $(node -v)"
'
```

| 片段 | 意思 |
| --- | --- |
| `curl … nodejs.org/dist/…` | 從 Node.js 官方網站下載 |
| `sha256sum -c` | 比對官方公布的 SHA256；不一致就停止（`set -e`），不會替換 |
| `tar … bin/node` | 只解開 `node` 執行檔 |
| `cp -a … .bak-v22.22.2` | 舊執行檔改名備份 |

**看到的結果**：`node-v22.23.4-linux-x64.tar.xz: OK`、`hermes node: v22.23.4   login-shell node: v22.23.4`。

還原：`mv ~/.hermes/node/bin/node.bak-v22.22.2 ~/.hermes/node/bin/node`。

> 以後執行 `hermes update`，自帶的 Node 可能被換回 Hermes 固定的版本（未確認），每次更新後要再看一次 `~/.hermes/node/bin/node -v`。

## 8. 步驟六：只能等廠商的兩處

### 8-1 ProxCenter：先只下載新映像檔比對

```bash
pct exec 110 -- sh -c '
  W=$(docker inspect proxcenter-frontend --format "{{index .Config.Labels \"com.docker.compose.project.working_dir\"}}")
  echo "compose: $W"
  echo "current: $(docker inspect proxcenter-frontend --format "{{.Image}}" | cut -c8-19)"
  cd "$W" && docker compose pull -q frontend
  echo "latest:  $(docker image inspect ghcr.io/adminsyspro/proxcenter-frontend:latest --format "{{.Id}}" | cut -c8-19)"
  echo "latest node: $(docker run --rm --entrypoint node ghcr.io/adminsyspro/proxcenter-frontend:latest -v)"
'
```

| 片段 | 意思 |
| --- | --- |
| `working_dir` 標籤 | 找出 `docker-compose.yml` 的位置（本案 `/opt/proxcenter`） |
| `docker compose pull -q frontend` | **只下載**，不重啟容器 |
| `docker run --rm --entrypoint node … -v` | 用新映像檔開暫時容器問版本，問完就刪 |

**看到的結果**：有新映像檔（`e231971ce488` → `9fd230eff246`），但裡面是 **v26.12.0**，仍比 26.12.1 舊，要等下一版。

> pull 之後本機的 `latest` 已指向新版；這次沒有重啟，執行中的還是舊版。

> ⚠️ **不要在只 pull 了 frontend 之後就 `docker compose up -d`**（本文原本寫「下次 `up -d` 就會換成它」，這樣做不妥）。那只會換前端，orchestrator、weasyprint、postgres 仍是舊的，變成新舊混搭；ProxCenter **企業版**要重跑官方安裝腳本帶 token 才會一起更新。

**2026-10-29 更新結果**：ProxCenter 由 1.4.11 更新到 v1.4.12（做法見 [ProxCenter 企業版更新與擴容](https://kbwangtw.github.io/IT-Knowledge-Base/docs/pve/proxcenter-enterprise-update/)），更新後 `docker exec proxcenter-frontend node -v` 仍是 **v26.12.0**，**低於 26.12.1**。v1.4.12 的更新紀錄沒有提到 Node.js 升級，且發布時間（10/19）早於漏洞公告，Node 待辦**不能打勾**。

### 8-2 Wazuh Dashboard

Wazuh Dashboard 建立在 OpenSearch Dashboards 上，Node.js 版本由 OpenSearch 專案決定；Wazuh 社群**不建議自己替換 Node.js**，可能造成相容性問題。所以只能等 Wazuh 新版。曝險方面，Dashboard 監聽 `0.0.0.0:443`，只在內網；可以另外用 PVE 防火牆限制 443 只允許管理網／VPN（agent 用的 1514、1515、55000 不受影響）。

## 9. 常見問題

| 現象 | 怎麼辦 |
| --- | --- |
| `apt` 說已是最新，掃描卻找到舊 Node | 那是程式自帶的（Wazuh、Docker、Hermes），apt 管不到 |
| `apt-cache policy` 的 Candidate 和 Installed 一樣舊 | 該主版本已停止支援（例如 NodeSource 20.x），要換主版本來源 |
| `pct exec … command -v hermes` 找不到 | `pct exec` 不是登入 shell，沒讀 `~/.local/bin`；用 `bash -lc` 或寫完整路徑 |
| 系統 Node 升級了，手動打 `node -v` 還是舊版 | `~/.local/bin/node` 可能指向程式自帶的 Node，用 `readlink -f $(command -v node)` 看實際路徑 |
| `find` 沒掃到 Docker 容器裡的 Node | 用 `docker exec <容器> node -v` 逐一問 |
| 想知道某個 Node 有沒有在用 | `ps -eo pid,user,args \| grep "[n]ode "`；沒在跑的風險較低 |
| 第三方來源的套件沒被自動更新 | unattended-upgrades 只收官方安全來源，NodeSource 要手動 |
| `echo "!!! …"` 輸出亂掉 | 雙引號裡的 `!!` 會被 bash 展開成上一個指令，改用單引號或拿掉 `!` |

## 10. 待辦

- [x] 觀察幾天正常後刪除快照：`pct delsnapshot 103 pre-node22234`、`pct delsnapshot 113 pre-node22`（2026-10-29 已刪）
- [x] 清掉 CT113 的 `/root/node_modules`（2026-11-01，7.9 MB，只含 `pptxgenjs` 與它的相依套件；`package.json`、`package-lock.json` 保留）
- [ ] 刪除 CT113 的 `/root/node-dl`、`/root/nodesource.sources.bak`（`~/.hermes` 已隨 Hermes 移除）
- [x] ~~每次 `hermes update` 後確認自帶的 Node~~：同日 Hermes 已移除，見 [用 Claude Code 取代 Hermes](https://kbwangtw.github.io/IT-Knowledge-Base/docs/pve/claude-code-redact-gateway/)
- [ ] 追蹤 ProxCenter 新版（frontend 的 Node ≥ 26.12.1）後更新；10/29 的 v1.4.12 仍是 26.12.0，已排 11/05 檢查有沒有新版
- [ ] 追蹤 Wazuh 新版；評估 PVE 防火牆限制 CT112 的 443
- [ ] PVE 三台、PBS31、GCP 網站主機的 Node.js 檢查（推測 PVE／PBS 沒有）

## 11. 延伸閱讀

- [Rescana：Node2Shell 修補版本](https://www.rescana.com/post/nodejs-cve-2026-111497-node2shell-brotli-rce-october-2026)
- [Aikido：Node2Shell 與停止支援的版本](https://www.aikido.dev/blog/node2shell-nodejs-brotli-rce-cve-2026-111497)
- [LiteLLM 官方：10/21 v1.107.0 遭入侵事件](https://docs.litellm.ai/blog/security-incident-oct-21-2026)
- [SOCRadar：LiteLLM 供應鏈攻擊](https://socradar.io/blog/litellm-supply-chain-attack-pypi-docker/)
- [Hermes Agent 官方文件：Updating](https://hermes-agent.nousresearch.com/docs/getting-started/updating)
- [Wazuh 社群：Updating Node.js](https://groups.google.com/g/wazuh/c/PnEAUz4rJoE)
- [PHP2Shell：檢查環境有沒有中](https://kbwangtw.github.io/IT-Knowledge-Base/docs/pve/php2shell-check/)：同一週的另一個漏洞
- [ProxCenter 逐台更新 PVE](https://kbwangtw.github.io/IT-Knowledge-Base/docs/pve/proxcenter-ceph-rolling-update/)：同日的 PVE 更新（含系統 `libbrotli1`）
{% endraw %}
