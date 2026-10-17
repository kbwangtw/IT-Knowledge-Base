---
layout: default
title: "PVE 9 登入一直跳「No valid subscription」：網路上的 sed 為什麼沒效？"
permalink: /docs/pve/pve9-subscription-nag-removal/
date: 2026-10-12
categories: [PVE, WebUI, APT, Ceph]
last_modified_at: 2026-10-17
---

# PVE 9 登入一直跳「No valid subscription」：網路上的 sed 為什麼沒效？

> **一句話**：這個提示是網頁前端 JavaScript 跳出來的，改一行就能取消；但網路上常見的 sed 在新版**比對不到、也不報錯**，所以一定要先 grep 確認目標存在，再修改，最後加上 APT hook 讓升級後自動重新套用。

| 項目 | 內容 |
| --- | --- |
| 適合誰看 | 沒買訂閱、每次登入 PVE／PBS 都被提示視窗打擾的人 |
| 環境 | pve-manager 9.2.21、proxmox-widget-toolkit 5.2.10、Ceph 20.2.4-pve5；PBS 4.2.8 |
| 日期 | 2026-10-12（PVE 三台）；2026-10-13（PBS31） |
| 結論 | ✅ 三台 PVE 與 PBS31 都不再跳出提示（無痕視窗驗證）；✅ APT hook 就位；✅ 三台 Repository 確認為 no-subscription，`apt-get update` 無警告 |

## 1. 先認識幾個名詞

| 名詞 | 白話解釋 |
| --- | --- |
| **proxmoxlib.js** | PVE／PBS 網頁介面共用的 JavaScript 檔，提示視窗就寫在這裡 |
| **proxmox-widget-toolkit** | 提供上面那個檔案的套件；升級時會覆蓋檔案 |
| **sed** | 用「比對 → 取代」方式修改文字檔的指令；比對不到時**不會報錯** |
| **grep** | 搜尋文字；`grep -c` 回傳符合的行數 |
| **pveproxy** | PVE 的網頁／API 服務；改完 JS 要重啟它 |
| **APT hook** | 每次 `apt` 安裝套件後自動執行的指令 |
| **heredoc（`<<'EOF'`）** | 一次把多行文字寫進檔案的 shell 寫法 |
| **deb822／`.sources`** | PVE 9 新的套件來源檔格式，取代舊的 `.list` |

## 2. 這個提示從哪裡來

它是 Web UI 前端 JavaScript 跳出的視窗，和 Cluster 設定無關。程式碼在：

```text
/usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js
```

> 這個檔案在 `/usr/share` 底下，不在 `/etc/pve`（pmxcfs）裡，所以**不會在 node 之間同步，每一台都要各改一次**。

負責跳出提示的是 `checked_command(orig_cmd)`。登入時和按 Updates 相關按鈕時，UI 會先呼叫它查訂閱狀態：

```text
if (res.data.status.toLowerCase() !== 'active') → 跳出 "No valid subscription"，按 OK 後才執行 orig_cmd()
else                                            → 直接執行 orig_cmd()
```

**處理方式**：讓這個 function 一進來就執行 `orig_cmd()` 並 `return`，等於永遠走 else 那條路。

## 3. 為什麼網路上的 sed 沒效

常見寫法比對的是 `function(orig_cmd) {`。在 node10 檢查：

```bash
JS=/usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js
grep -c "function(orig_cmd) {" $JS
```

結果是 `0`。改用名稱搜尋：

```bash
grep -n "checked_command" $JS
```

實際定義在第 614 行：

```text
614:        checked_command: function (orig_cmd) {
```

5.2.10 的 `function` 和 `(orig_cmd)` 之間**多了一個空格**。舊 pattern 比對不到，`sed` 不報錯、檔案也沒改。沒有先 grep，很容易誤以為已經改好。

**結構改變時**，用這兩個指令找判斷位置：

```bash
grep -n -B3 -A15 "No valid subscription" $JS
grep -n "status.toLowerCase" $JS
```

### 另一處 `status !== 'active'` 不用改

第 21546 行也有一處判斷，它不在 `checked_command` 裡：

```bash
sed -n '21500,21580p' $JS     # 印出第 21500～21580 行
```

它在 Repositories 頁面元件（`proxmoxNodeAPTRepositoriesGrid` 附近）的 `check_subscription` function：

```text
check_subscription: function () {
    ...
    Proxmox.Utils.API2Request({
        url: `/nodes/${me.nodename}/subscription`,
        ...
        success: function (response, opts) {
            const res = response.result;
            const subscription = !(
                !res ||
                !res.data ||
                res.data.status.toLowerCase() !== 'active'
            );
            vm.set('subscriptionActive', subscription);
            me.getController().updateState();
        },
```

它只把訂閱狀態存進 `subscriptionActive`，再更新「Node → Updates → Repositories」頁面上的狀態文字（例如提醒 no-subscription repo 不建議用在正式環境）。這裡沒有 `Ext.Msg.show`，**不會跳視窗**；只有 API 呼叫失敗時才會出現 `Ext.Msg.alert`，和訂閱無關。所以**不需要修改**，那段提醒文字是正常的。

## 4. 步驟一：修改前確認版本與目標

```bash
pveversion -v | grep -E "pve-manager|proxmox-widget-toolkit|ceph"
grep -c "checked_command: function (orig_cmd) {" $JS
```

| 結果 | 怎麼辦 |
| --- | --- |
| `1` | 結構和本文相同，繼續下一步 |
| `0` | 版本結構不同，**先不要改**，用第 3 節的 grep 找新寫法 |

## 5. 步驟二：備份並 patch

```bash
JS=/usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js
cp -n $JS ${JS}.orig
sed -i 's/^\(\s*checked_command: function (orig_cmd) {\)$/\1 orig_cmd(); return;/' $JS
```

| 片段 | 意思 |
| --- | --- |
| `cp -n` | 已經有備份就**不覆蓋**，重複執行也不會蓋掉最早的原檔 |
| `sed -i` | 直接修改檔案 |
| `^…$` | 只比對**完整的一行** `checked_command: function (orig_cmd) {`；第 20801、21062 行那些呼叫 `checked_command` 的地方不會被動到 |
| `\1 orig_cmd(); return;` | 保留原本那行（`\1`），在 `{` 後面加上 `orig_cmd(); return;` |

原本的程式碼一行都沒刪，只是變成執行不到。

## 6. 步驟三：驗證並重啟 pveproxy

```bash
grep -n "checked_command: function" $JS
systemctl restart pveproxy.service
systemctl is-active pveproxy.service
```

**應該看到**（node10 實際輸出）：

```text
614:        checked_command: function (orig_cmd) { orig_cmd(); return;
```

- 重啟 pveproxy 只影響 Web UI 和 API 連線，中斷幾秒，**不影響 VM、CT 和 Ceph**；正在用的 noVNC console 可能斷線，重連即可。
- 瀏覽器按 **Ctrl+Shift+R** 或用無痕視窗，確認登入後不再跳提示，點「Node → Updates → Refresh」也會直接執行。

本次三台都用各自的 IP 以無痕視窗登入，確認不再跳出提示。

## 7. 步驟四：套件升級後自動重新套用

**為什麼**：`apt` 升級 `proxmox-widget-toolkit` 時會覆蓋 `proxmoxlib.js`，提示會再出現。改用獨立 script 加上 APT hook，避免把整段指令塞進 hook 時要處理多層引號。

```bash
cat > /usr/local/sbin/pve-nonag.sh <<'EOF'
#!/bin/sh
JS=/usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js
# 已經 patch 過就跳過（idempotent）
grep -q "checked_command: function (orig_cmd) { orig_cmd(); return;" "$JS" && exit 0
# 找得到目標才 patch，避免新版結構改變時亂改
grep -q "checked_command: function (orig_cmd) {$" "$JS" || exit 0
sed -i 's/^\(\s*checked_command: function (orig_cmd) {\)$/\1 orig_cmd(); return;/' "$JS"
systemctl restart pveproxy.service
EOF
chmod +x /usr/local/sbin/pve-nonag.sh

echo 'DPkg::Post-Invoke { "/usr/local/sbin/pve-nonag.sh || true"; };' > /etc/apt/apt.conf.d/99-pve-nonag
```

**這段在做什麼**：

- `<<'EOF'` 的單引號讓 `$JS` 寫入檔案時**不展開**，留到 script 執行時才展開。
- script 有兩道保護：**已經 patch 過就跳過**；**找不到目標也跳過**。未來版本改了寫法時不會改壞檔案，只是提示會再出現。
- hook 的 `|| true` 讓 script 失敗時不會連帶中斷 `apt`。

**驗證**：

```bash
ls -l /usr/local/sbin/pve-nonag.sh
/usr/local/sbin/pve-nonag.sh && echo "OK: 已 patch 過，正確跳過"
apt-config dump | grep -i post-invoke
```

**應該看到**（node10）：script 權限 `-rwxr-xr-x`；執行後印出 `OK: 已 patch 過，正確跳過`；`apt-config` 列出 `DPkg::Post-Invoke:: "/usr/local/sbin/pve-nonag.sh || true";`。同一段輸出裡的 `DPkg::Post-Invoke "";` 是清單標頭，正常。

## 8. 步驟五：套用到其他 node

先用 `pvecm nodes` 確認 node 名稱。本 Cluster 是 node10（已完成）、node11、node12。

**先只讀取**，確認版本和結構與 node10 一致：

```bash
for n in node11 node12; do
  echo "===== $n ====="
  ssh root@$n 'pveversion -v | grep proxmox-widget-toolkit; grep -c "checked_command: function (orig_cmd) {" /usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js'
done
```

兩台都回 `proxmox-widget-toolkit: 5.2.10` 和 `1` 之後，再從 node10 推送：

```bash
JS=/usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js
for n in node11 node12; do
  echo "===== $n ====="
  ssh root@$n "cp -n $JS ${JS}.orig" && \
  scp /usr/local/sbin/pve-nonag.sh root@$n:/usr/local/sbin/ && \
  scp /etc/apt/apt.conf.d/99-pve-nonag root@$n:/etc/apt/apt.conf.d/ && \
  ssh root@$n "/usr/local/sbin/pve-nonag.sh; grep -n 'checked_command: function' $JS; systemctl is-active pveproxy"
done
```

`&&` 讓前一步成功才執行下一步，例如 SSH 連不上就不會繼續 scp。

**本次結果**：

| Node | widget-toolkit | 第 614 行 | pveproxy | APT hook |
| --- | --- | --- | --- | --- |
| node10 | 5.2.10 | `{ orig_cmd(); return;` | 已重啟 | 已確認 |
| node11 | 5.2.10 | `{ orig_cmd(); return;` | active | 已確認 |
| node12 | 5.2.10 | `{ orig_cmd(); return;` | active | 已確認 |

最後核對三台 hook：

```bash
for n in node10 node11 node12; do echo "== $n =="; ssh root@$n 'cat /etc/apt/apt.conf.d/99-pve-nonag'; done
```

## 9. 步驟六：確認 Repository 是 no-subscription

**為什麼**：取消提示只處理 Web UI，**不會改變 apt 來源**。沒有訂閱時，如果 enterprise repo 還在，`apt update` 會回 401。PVE 9 用 deb822 格式的 `.sources` 檔，先檢查三台：

```bash
for n in node10 node11 node12; do
  echo "===== $n ====="
  ssh root@$n 'ls /etc/apt/sources.list.d/; grep -v "^#" /etc/apt/sources.list.d/*.list 2>/dev/null; grep -H -E "^(URIs|Suites|Components|Enabled)" /etc/apt/sources.list.d/*.sources'
done
```

**看到的結果**：三台內容一致，已經是 no-subscription，不需要修改：

| 檔案 | URIs | Suites | Components |
| --- | --- | --- | --- |
| `ceph.sources` | `http://download.proxmox.com/debian/ceph-tentacle` | trixie | no-subscription |
| `debian.sources` | `http://deb.debian.org/debian/`、`http://security.debian.org/debian-security/` | trixie、trixie-updates、trixie-security | main contrib non-free-firmware |
| `proxmox.sources` | `http://download.proxmox.com/debian/pve` | trixie | pve-no-subscription |

- 沒有 `pve-enterprise.sources`，也沒有任何 `Enabled: no`。
- Ceph 來源是 `ceph-tentacle`，對應 Ceph 20.2.4。網路上很多 PVE 9 範例寫的是 `ceph-squid`（Ceph 19），**不能照抄**。
- 目錄裡還有一個舊格式的 `pve-no-subscription.list`，但有效內容 0 行（只剩註解和空行），不會和 `proxmox.sources` 重複。

**最後確認**：

```bash
for n in node10 node11 node12; do
  echo "===== $n ====="
  ssh root@$n 'grep -v "^#" /etc/apt/sources.list.d/pve-no-subscription.list | grep -c .; grep -h -E "^(URIs|Components)" /etc/apt/sources.list.d/*.sources; apt-get update 2>&1 | grep -E "^(W|E):" || echo "apt update: 無警告/錯誤"'
done
```

三台都回 `0` 和 `apt update: 無警告/錯誤`。`apt-get update` 只更新套件清單，不會安裝或升級任何東西；實際升級照 [ProxCenter 逐台更新](https://kbwangtw.github.io/IT-Knowledge-Base/docs/pve/proxcenter-ceph-rolling-update/) 的流程逐台進行。

舊 `.list` 檔可以保留。想整理目錄時改名停用即可，**不要直接刪除**（apt 只讀 `.list` 和 `.sources` 副檔名）。本次沒有執行：

```bash
mv /etc/apt/sources.list.d/pve-no-subscription.list /etc/apt/sources.list.d/pve-no-subscription.list.disabled
```

## 10. PBS 也適用（2026-10-13）

PBS 的提示來自同一個套件、同一個檔案，做法相同，只有要重啟的服務和 hook 名稱不同。

**先在 PBS31 確認版本與目標**：

```bash
proxmox-backup-manager versions
dpkg -l proxmox-widget-toolkit | awk '/^ii/ {print $2, $3}'
JS=/usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js
grep -c "checked_command: function (orig_cmd) {" $JS
grep -n "checked_command" $JS | head -3
```

本次 PBS 4.2.8、widget-toolkit 5.2.10，目標同樣在第 614 行，`grep -c` 為 1，和 PVE 完全一致。

**備份、patch、重啟**：

```bash
cp -n $JS ${JS}.orig
sed -i 's/^\(\s*checked_command: function (orig_cmd) {\)$/\1 orig_cmd(); return;/' $JS
grep -n "checked_command: function" $JS
systemctl restart proxmox-backup-proxy
systemctl is-active proxmox-backup-proxy
```

APT hook 改用 `/usr/local/sbin/pbs-nonag.sh` 和 `/etc/apt/apt.conf.d/99-pbs-nonag`，內容和 PVE 版相同，只把最後的 `systemctl restart pveproxy.service` 換成 `systemctl restart proxmox-backup-proxy`。

| 項目 | PVE | PBS |
| --- | --- | --- |
| 修改的檔案 | `proxmoxlib.js` 第 614 行 | 同一個檔案、同一行 |
| 重啟服務 | `pveproxy` | `proxmox-backup-proxy` |
| hook | `pve-nonag.sh`、`99-pve-nonag` | `pbs-nonag.sh`、`99-pbs-nonag` |
| 套件來源 | 沒有 enterprise 設定檔，用 `pve-no-subscription` | enterprise 設定檔保留但 `Enabled: false`，用 `pbs-no-subscription` |

兩種來源寫法都正確；`apt-get update` 沒有警告或錯誤。修改後無痕視窗登入不再出現提示；當天 PBS31 更新 kernel 並重開後再次確認，提示仍未出現。

> ⚠️ **重啟 `proxmox-backup-proxy` 會中斷正在進行的備份、GC 或 Verify。** 本環境每晚 21:00～22:30 接收備份、00:00 起 GC、02:00 起 Verify，這些時段不要重啟服務，也不要升級 PBS 套件（APT hook 在 widget-toolkit 升級時會自動重啟服務）。

## 11. 怎麼還原

| 項目 | 位置 | 還原方式 |
| --- | --- | --- |
| JS 原始備份 | `proxmoxlib.js.orig` | `cp ${JS}.orig $JS && systemctl restart pveproxy` |
| patch script | `/usr/local/sbin/pve-nonag.sh` | `rm` |
| APT hook | `/etc/apt/apt.conf.d/99-pve-nonag` | `rm` |

`.orig` 是 5.2.10 的版本。套件升級後，新版 JS 會覆蓋舊檔，這時**不要**用舊的 `.orig` 還原。要完整還原時，先刪除 hook 和 script，再執行：

```bash
apt install --reinstall proxmox-widget-toolkit
systemctl restart pveproxy.service
```

## 12. 常見問題

| 現象 | 怎麼辦 |
| --- | --- |
| sed 執行了，提示還在 | 先 `grep -c` 確認目標存在；5.2.10 的 `function` 後面多一個空格 |
| 改完瀏覽器還是跳提示 | 按 Ctrl+Shift+R 或用無痕視窗，避開快取 |
| 驗證指令出現 `No such file or directory` | 還沒執行建立檔案的 heredoc，先貼上 `cat > … <<'EOF'` 那段 |
| 貼完 heredoc 終端機停在 `>` 不動 | 結尾的 `EOF` 沒被正確讀到；Ctrl+C 取消後重新貼上 |
| 升級後提示又出現 | 新版寫法可能變了，script 安全跳過；用第 3 節的 grep 重新檢查 |
| Web UI 變白畫面 | JS 改壞了；用 `.orig` 或 `apt install --reinstall` 還原 |
| Repositories 頁面還有提醒文字 | 正常，那是狀態顯示，不是提示視窗 |

## 13. 風險與限制

- 這不是官方支援的做法。PVE 採 AGPLv3，自行修改前端在授權上沒有問題，但正式環境仍可評估購買訂閱，以取得官方支援與 enterprise repo。
- 下一個大版本如果改了寫法，script 會安全跳過，提示會再出現；屆時用第 4 節的 grep 重新檢查。
- 不要直接套用網路上沒寫明適用版本的 sed。改錯 JS 可能讓 Web UI 變白畫面。
- 取消提示不會改變 Repository 設定，兩件事要分開確認（第 9 節）。no-subscription repo 的套件比 enterprise 新、測試較少，Ceph 節點升級前要照既有流程逐台處理。

## 14. 延伸閱讀

- [Proxmox VE Package Repositories](https://pve.proxmox.com/wiki/Package_Repositories)
- [Proxmox VE 訂閱方案](https://www.proxmox.com/en/proxmox-virtual-environment/pricing)
- [ProxCenter 逐台更新 PVE](https://kbwangtw.github.io/IT-Knowledge-Base/docs/pve/proxcenter-ceph-rolling-update/)
