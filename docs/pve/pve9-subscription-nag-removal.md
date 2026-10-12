---
layout: default
title: "PVE 9 登入一直跳「No valid subscription」：網路上的 sed 為什麼沒效？"
permalink: /docs/pve/pve9-subscription-nag-removal/
date: 2026-10-12
categories: [PVE, WebUI, APT]
last_modified_at: 2026-10-12
---

# PVE 9 登入一直跳「No valid subscription」：網路上的 sed 為什麼沒效？

沒有購買訂閱的 PVE，每次登入 Web UI，或按下「Updates → Refresh」時，都會跳出「No valid subscription」視窗。本次在三台 PVE 9 上取消了這個提示，並加上 APT hook，讓套件升級後自動重新套用。

**網路上常見的 sed 指令，在 proxmox-widget-toolkit 5.2.10 比對不到任何內容；它不會報錯，但什麼也沒改。先 grep 確認目標存在，再修改。**

> 紀錄日期：2026-10-12；pve-manager 9.2.21、proxmox-widget-toolkit 5.2.10、Ceph 20.2.4-pve5。node10、node11、node12 三台的檔案修改與 APT hook 已在終端機驗證；三台的瀏覽器登入驗證待補記。Repository 改成 no-subscription 不在本文範圍。

## 這個提示從哪裡來？

它是 Web UI 前端 JavaScript 跳出的視窗，跟 Cluster 設定無關。程式碼位於：

~~~
/usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js
~~~

這個檔案在 `/usr/share` 底下，不在 `/etc/pve`（pmxcfs）裡，所以**不會在 node 之間同步，每一台都要各改一次**。

負責跳出提示的是 `checked_command(orig_cmd)`。登入時和按下 Updates 相關按鈕時，UI 會先呼叫它查訂閱狀態：

~~~
if (res.data.status.toLowerCase() !== 'active') → 跳出 "No valid subscription"，按 OK 後才執行 orig_cmd()
else                                            → 直接執行 orig_cmd()
~~~

處理方式是讓這個 function 一進來就執行 `orig_cmd()` 並 `return`，等同於永遠走 else 那條路。

## 為什麼網路上的 sed 沒效？

常見寫法比對的是 `function(orig_cmd) {`。本次在 node10 檢查：

~~~bash
JS=/usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js
grep -c "function(orig_cmd) {" $JS
~~~

結果是 `0`。改用名稱搜尋：

~~~bash
grep -n "checked_command" $JS
~~~

實際定義在第 614 行：

~~~
614:        checked_command: function (orig_cmd) {
~~~

5.2.10 的 `function` 和 `(orig_cmd)` 之間**多了一個空格**。舊 pattern 比對不到，`sed` 不會報錯，檔案也沒有被修改。如果沒有先 grep，很容易誤以為已經改好。

結構改變時，可以用下面兩個指令找出判斷位置：

~~~bash
grep -n -B3 -A15 "No valid subscription" $JS
grep -n "status.toLowerCase" $JS
~~~

> 本次另外看到第 21546 行也有一處 `status !== 'active'` 判斷，它不在 `checked_command` 裡。只 patch 第 614 行後，登入彈窗的處理已完成；該處用途尚未確認。

## 1. 修改前先確認版本與目標

~~~bash
pveversion -v | grep -E "pve-manager|proxmox-widget-toolkit|ceph"
grep -c "checked_command: function (orig_cmd) {" $JS
~~~

- 結果是 `1`：結構和本文相同，繼續下一步。
- 結果是 `0`：版本結構不同，**先不要修改**，改用上一節的 grep 找出新寫法。

## 2. 備份並 patch

~~~bash
JS=/usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js
cp -n $JS ${JS}.orig
sed -i 's/^\(\s*checked_command: function (orig_cmd) {\)$/\1 orig_cmd(); return;/' $JS
~~~

- `cp -n`：已經有備份時就不會覆蓋，重複執行也不會蓋掉最早的原檔。
- `sed` 只比對 `checked_command: function (orig_cmd) {` 這**完整的一行**，第 20801、21062 行那些呼叫 `checked_command` 的地方不會被動到。
- 只在 `{` 後面加上 `orig_cmd(); return;`，原本的程式碼一行都不刪，只是變成執行不到。

## 3. 驗證並重啟 pveproxy

~~~bash
grep -n "checked_command: function" $JS
systemctl restart pveproxy.service
systemctl is-active pveproxy.service
~~~

node10 實際輸出：

~~~
614:        checked_command: function (orig_cmd) { orig_cmd(); return;
~~~

重啟 pveproxy 只影響 Web UI 和 API 連線，大約中斷幾秒，不影響 VM、CT 和 Ceph；正在使用的 noVNC console 可能會斷線，重新連線即可。

瀏覽器按 **Ctrl+Shift+R** 或使用無痕視窗，確認登入後不再跳出提示，點「Node → Updates → Refresh」也會直接執行。

## 4. 套件升級後自動重新套用

`apt` 升級 `proxmox-widget-toolkit` 時會覆蓋 `proxmoxlib.js`，提示會再出現。本次改用獨立 script 加上 APT hook，避免把整段指令塞進 hook 時要處理多層引號跳脫。

~~~bash
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
~~~

- `<<'EOF'` 的單引號讓 `$JS` 寫入檔案時不會被展開，留到 script 執行時才展開。
- script 有兩道保護：已經 patch 過就跳過；找不到目標也跳過。未來版本改了寫法時，它不會改壞檔案，只是提示會再出現。
- hook 的 `|| true` 讓 script 失敗時不會連帶中斷 `apt`。

驗證：

~~~bash
ls -l /usr/local/sbin/pve-nonag.sh
/usr/local/sbin/pve-nonag.sh && echo "OK: 已 patch 過，正確跳過"
apt-config dump | grep -i post-invoke
~~~

node10 實際結果：script 權限 `-rwxr-xr-x`，執行後印出 `OK: 已 patch 過，正確跳過`，`apt-config` 列出 `DPkg::Post-Invoke:: "/usr/local/sbin/pve-nonag.sh || true";`。同一段輸出裡的 `DPkg::Post-Invoke "";` 是清單標頭，屬於正常現象。

> 踩雷紀錄：第一次執行驗證指令時出現 `No such file or directory`，原因是還沒執行建立檔案的 heredoc。貼上 heredoc 後如果終端機停在 `>` 不動，代表結尾的 `EOF` 沒有被正確讀到，按 Ctrl+C 取消後重新貼上。

## 5. 套用到其他 node

先用 `pvecm nodes` 確認 node 名稱。本 Cluster 是 node10（已完成）、node11、node12。

先只讀取、不修改，確認版本和結構與 node10 一致：

~~~bash
for n in node11 node12; do
  echo "===== $n ====="
  ssh root@$n 'pveversion -v | grep proxmox-widget-toolkit; grep -c "checked_command: function (orig_cmd) {" /usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js'
done
~~~

兩台都回 `proxmox-widget-toolkit: 5.2.10` 和 `1` 之後，再從 node10 推送：

~~~bash
JS=/usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js
for n in node11 node12; do
  echo "===== $n ====="
  ssh root@$n "cp -n $JS ${JS}.orig" && \
  scp /usr/local/sbin/pve-nonag.sh root@$n:/usr/local/sbin/ && \
  scp /etc/apt/apt.conf.d/99-pve-nonag root@$n:/etc/apt/apt.conf.d/ && \
  ssh root@$n "/usr/local/sbin/pve-nonag.sh; grep -n 'checked_command: function' $JS; systemctl is-active pveproxy"
done
~~~

`&&` 讓前一步成功才執行下一步，例如 SSH 連不上時就不會繼續 scp。

本次結果：

| Node | widget-toolkit | 第 614 行 | pveproxy | APT hook |
| --- | --- | --- | --- | --- |
| node10 | 5.2.10 | `{ orig_cmd(); return;` | 已重啟 | 已確認 |
| node11 | 5.2.10 | `{ orig_cmd(); return;` | active | 已確認 |
| node12 | 5.2.10 | `{ orig_cmd(); return;` | active | 已確認 |

最後一次核對三台 hook：

~~~bash
for n in node10 node11 node12; do echo "== $n =="; ssh root@$n 'cat /etc/apt/apt.conf.d/99-pve-nonag'; done
~~~

## 怎麼還原？

| 項目 | 位置 | 還原方式 |
| --- | --- | --- |
| JS 原始備份 | `proxmoxlib.js.orig` | `cp ${JS}.orig $JS && systemctl restart pveproxy` |
| patch script | `/usr/local/sbin/pve-nonag.sh` | `rm` |
| APT hook | `/etc/apt/apt.conf.d/99-pve-nonag` | `rm` |

`.orig` 是 5.2.10 的版本。套件升級後，新版 JS 會覆蓋舊檔，這時不要用舊的 `.orig` 還原。要完整還原時，先刪除 hook 和 script，再執行：

~~~bash
apt install --reinstall proxmox-widget-toolkit
systemctl restart pveproxy.service
~~~

## 風險與限制

- 這不是官方支援的做法。PVE 採 AGPLv3，自行修改前端在授權上沒有問題，但正式環境仍可評估購買訂閱，以取得官方支援與 enterprise repo。
- 下一個大版本如果又改了寫法，script 會安全跳過，提示會再出現。屆時用第 1 節的 grep 重新檢查。
- 請不要直接套用網路上沒寫明適用版本的 sed。改錯 JS 可能讓 Web UI 變成白畫面；發生時用 `.orig` 或 reinstall 還原。
- 取消提示不會改變 Repository 設定。沒有訂閱時，enterprise repo 仍會在 `apt update` 時回 401，需要另外改成 no-subscription repo。本 Cluster 已在 Ceph 20（Tentacle），Ceph repo 不能照抄網路上 `ceph-squid` 的範例。

## 本次結論

三台的 `proxmoxlib.js` 已經 patch，APT hook 已就位，之後升級會自動重新套用。待補：三台瀏覽器登入驗證的紀錄、第 21546 行判斷的用途，以及 Repository 改成 no-subscription 的設定與驗證。

- [Proxmox VE Package Repositories](https://pve.proxmox.com/wiki/Package_Repositories)
- [Proxmox VE 訂閱方案](https://www.proxmox.com/en/proxmox-virtual-environment/pricing)
