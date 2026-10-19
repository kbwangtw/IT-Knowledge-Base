# Graylog 告警與監控（三）：中文告警信與摘要

> **一句話**：Graylog 預設的告警信是英文、把整筆欄位倒出來，看不出是哪台出問題。這篇用 API 把 13 個通知換成同一份中文範本，再把每個告警的「摘要」改成一眼看懂的寫法，例如「node10 的 vzstart 失敗（VM／CT 999）」。

| 項目 | 內容 |
| --- | --- |
| 適合誰看 | 想把 Graylog 告警信改成中文、或想讓信裡直接寫出「哪台、什麼事」的人 |
| 前兩篇 | [（一）收集、分類與寄信設定](https://kbwangtw.github.io/IT-Knowledge-Base/docs/pve/proxmox-graylog-syslog-pipeline-sop/)、[（二）告警清單、監控腳本](https://kbwangtw.github.io/IT-Knowledge-Base/docs/pve/graylog-alerts-monitoring/) |
| 環境 | Graylog 7.1.9（CT 105）；從 node10 用 REST API 操作 |
| 日期 | 2026-10-19 |
| 結論 | ✅ 13 個通知改用中文純文字＋HTML 範本 ✅ 主旨統一 ✅ 摘要依告警類型改寫；5 個「有就觸發」的告警改成每筆 ⏳ 部分告警的新摘要等自然觸發確認 |

## 1. 先認識幾個名詞

| 名詞 | 白話解釋 |
| --- | --- |
| **Notification** | 告警觸發後「怎麼通知」：收件人、主旨、內文範本。每個 Event Definition 綁一個 |
| **Body Template／HTML Body Template** | 內文的純文字版和網頁版。Gmail 優先顯示 HTML 版，**只改純文字版看到的還是英文** |
| **Backlog** | 信裡附上的原始日誌（下篇 3-2 的 Backlog 欄位決定最多幾筆） |
| `${…}` | 範本變數，寄信時換成實際內容；`${foreach backlog message}…${end}` 是「每筆日誌重複一次」 |

```text
13 個 Event Definition ──各綁一個──▶ 13 個 Notification ──▶ 同一份中文範本（純文字 + HTML）──▶ Gmail
```

## 2. 全貌

```text
① 盤點 13 個 Notification ─▶ ② 寫入中文範本與工具 ─▶ ③ 先改一個測試 ─▶ ④ 套用全部 ─▶ ⑤ 統一主旨
⑥ 摘要：PVE 任務失敗改成結構化 ─▶ ⑦ 其他告警的摘要 ─▶ ⑧ 「有就觸發」改成每筆
```

| 信裡的位置 | 由誰決定 | 在哪一節 |
| --- | --- | --- |
| 主旨 | Notification 的 Subject | 第 7 節 |
| 標題、說明、時間、等級、相關日誌 | Notification 的 Body／HTML Body Template（13 個共用） | 第 3～6 節 |
| 摘要 | 每個 Event Definition 的 Event Summary Template | 第 8～10 節 |

## 3. 第一步：盤點（只讀取）

用 admin 帳號讀 Notification 和 Event Definition，看各有幾個、誰綁誰、範本是不是預設的。下篇第 5 節的唯讀帳號 `pve-monitor` 是 Reader，推測讀不到 Notification，所以這裡用 admin（密碼用 `read -rsp` 輸入，單獨貼上）：

```bash
read -rsp "Graylog admin 密碼：" GLPW; echo
```

```bash
cat > /root/gl-notif-inventory.py <<'EOF2'
import json, os, sys, base64, urllib.request
url = os.environ["GL_URL"].rstrip("/")
auth = base64.b64encode(("admin:" + os.environ["GLPW"]).encode()).decode()
def get(path):
    req = urllib.request.Request(url + path, headers={"Authorization": "Basic " + auth, "Accept": "application/json"})
    return json.load(urllib.request.urlopen(req, timeout=15))
n = get("/api/events/notifications?per_page=100")["notifications"]
d = get("/api/events/definitions?per_page=100")["event_definitions"]
use = {}
for e in d:
    for x in e.get("notifications") or []:
        use.setdefault(x["notification_id"], []).append(e["title"])
print("Notification 數量：", len(n))
for x in n:
    c = x["config"]
    print("==", x["title"], "| type:", c.get("type"))
    print("   subject:", c.get("subject"))
    print("   收件人數:", len(c.get("email_recipients") or []), "| time_zone:", c.get("time_zone"))
    print("   body 長度:", len(c.get("body_template") or ""), "| html 長度:", len(c.get("html_body_template") or ""))
    print("   body 開頭:", (c.get("body_template") or "")[:60].replace("\n", "⏎"))
    print("   被這些告警使用:", "、".join(use.get(x["id"], [])) or "（沒有）")
EOF2
. /root/.graylog-monitor.conf
GL_URL="$GL_URL" GLPW="$GLPW" python3 /root/gl-notif-inventory.py
```

| 片段 | 意思 |
| --- | --- |
| `. /root/.graylog-monitor.conf` | 讀入下篇第 5 節設定檔裡的 `GL_URL` |
| `收件人數` | 只顯示數量，不印出信箱 |
| `body 開頭` | 前 60 字，判斷是不是預設範本 |

**看到的結果**：

| 發現 | 代表什麼 |
| --- | --- |
| 13 個 Notification，每個告警各一個、沒有共用 | 改一個不會影響別的告警 |
| 13 個 body 都是 1210 字、html 都是 2315 字，開頭 `--- [Event Definition] ---` | 全部是預設範本，可以共用同一份中文範本 |
| 主旨大多已是中文（如 `【Ceph 告警】${event_definition_title}`） | 主旨保留不動 |
| 「PVE 服務異常通知」time_zone 是 UTC | 信裡時間差 8 小時，一起改成 Asia/Taipei |
| 「VPN 異常通知」主旨是 `【VPN 告警 】: …` | 多了空格與冒號，一起整理 |

## 4. 第二步：寫入範本與工具（還不會改 Graylog）

```bash
mkdir -p /root/gl-tpl && chmod 700 /root/gl-tpl

cat > /root/gl-tpl/body.txt <<'EOF2'
${event_definition_title}
========================================
說明：${event_definition_description}
時間：${event.timestamp}
等級：${event.priority}（1 低／2 中／3 高）
摘要：${event.message}

相關日誌
----------------------------------------
${if backlog}${foreach backlog message}
[${message.timestamp}] ${message.source}${if message.fields.src_host}（${message.fields.src_host}）${end}
${message.message}
${end}${else}這次沒有附上原始日誌（Message Backlog 為 0，或是測試通知）。
${end}
----------------------------------------
此信由 Graylog 自動寄出。
EOF2

cat > /root/gl-tpl/body.html <<'EOF2'
<div style="font-family:sans-serif;font-size:14px;max-width:760px">
<div style="background:#1f3a5f;color:#fff;padding:10px 12px;font-size:16px;font-weight:bold">${event_definition_title}</div>
<table style="border-collapse:collapse;width:100%;margin:8px 0">
<tr><td style="padding:4px 12px;color:#666;width:4em">說明</td><td style="padding:4px 12px">${event_definition_description}</td></tr>
<tr><td style="padding:4px 12px;color:#666">時間</td><td style="padding:4px 12px">${event.timestamp}</td></tr>
<tr><td style="padding:4px 12px;color:#666">等級</td><td style="padding:4px 12px">${event.priority}（1 低／2 中／3 高）</td></tr>
<tr><td style="padding:4px 12px;color:#666">摘要</td><td style="padding:4px 12px">${event.message}</td></tr>
</table>
<div style="font-weight:bold;margin:14px 0 6px">相關日誌</div>
${if backlog}<table style="border-collapse:collapse;width:100%;font-size:13px">
<tr style="background:#eee"><th align="left" style="padding:4px 8px">時間</th><th align="left" style="padding:4px 8px">主機</th><th align="left" style="padding:4px 8px">內容</th></tr>
${foreach backlog message}<tr style="border-top:1px solid #ddd"><td style="padding:4px 8px;white-space:nowrap;vertical-align:top">${message.timestamp}</td><td style="padding:4px 8px;white-space:nowrap;vertical-align:top">${message.source}${if message.fields.src_host}<br>${message.fields.src_host}${end}</td><td style="padding:4px 8px;font-family:monospace">${message.message}</td></tr>
${end}</table>${else}<p>這次沒有附上原始日誌（Message Backlog 為 0，或是測試通知）。</p>${end}
<p style="color:#888;font-size:12px;margin-top:16px">此信由 Graylog 自動寄出。</p>
</div>
EOF2

cat > /root/gl-tpl/notif.py <<'EOF2'
import json, os, sys, base64, urllib.request
url = os.environ["GL_URL"].rstrip("/")
auth = base64.b64encode(("admin:" + os.environ["GLPW"]).encode()).decode()
H = {"Authorization": "Basic " + auth, "Accept": "application/json",
     "Content-Type": "application/json", "X-Requested-By": "cli"}
def call(method, path, data=None):
    body = None if data is None else json.dumps(data).encode()
    req = urllib.request.Request(url + path, method=method, headers=H, data=body)
    with urllib.request.urlopen(req, timeout=15) as r:
        b = r.read()
        return json.loads(b) if b else None
mode, arg = sys.argv[1], sys.argv[2]
if mode == "backup":
    ns = call("GET", "/api/events/notifications?per_page=100")["notifications"]
    os.umask(0o077)
    json.dump(ns, open(arg, "w"), ensure_ascii=False, indent=1)
    print("已備份", len(ns), "個 →", arg)
elif mode == "apply":
    body = open("/root/gl-tpl/body.txt").read()
    html = open("/root/gl-tpl/body.html").read()
    done = 0
    for n in call("GET", "/api/events/notifications?per_page=100")["notifications"]:
        if arg != "ALL" and n["title"] != arg:
            continue
        c = n["config"]
        c["body_template"], c["html_body_template"], c["time_zone"] = body, html, "Asia/Taipei"
        if c.get("subject", "").startswith("【VPN 告警 】"):
            c["subject"] = "【VPN 告警】${event_definition_title}"
        call("PUT", "/api/events/notifications/" + n["id"], n)
        print("已更新：", n["title"]); done += 1
    print("共更新", done, "個")
elif mode == "restore":
    who = sys.argv[3]
    for n in json.load(open(arg)):
        if who != "ALL" and n["title"] != who:
            continue
        call("PUT", "/api/events/notifications/" + n["id"], n)
        print("已還原：", n["title"])
EOF2
```

| 片段 | 意思 |
| --- | --- |
| `<<'EOF2'`（有引號） | `${…}` 原封不動寫進檔案，不被 bash 當成變數 |
| `${if message.fields.src_host}` | 有 jt-ipam 補上的主機名稱（上篇第 6 節）才顯示 |
| `backup／apply／restore` | 備份全部、套用範本（指定名稱或 `ALL`）、從備份還原 |
| `X-Requested-By` | Graylog 規定修改類 API 要帶這個標頭 |

## 5. 第三步：備份，先改一個測試

```bash
export GL_URL GLPW
BK=/root/gl-notifications-backup-$(date +%Y%m%d-%H%M).json
python3 /root/gl-tpl/notif.py backup "$BK"
python3 /root/gl-tpl/notif.py apply "每日健康回報通知"
logger -t graylog-heartbeat "GRAYLOG_DAILY_HEARTBEAT host=$(hostname) test=zh-template"
```

拿「每日健康回報通知」測試：用 `logger` 就能安全觸發（下篇第 5 節），會帶出真的 backlog。當天 08:00 那封的 60 分鐘 Grace 已過，所以會再寄一封。

**看到的結果**：`已備份 13 個`、`共更新 1 個`；幾分鐘內收到中文的【每日健康回報】，HTML 表格顯示時間 `2026-10-19T14:29:00.000+08:00`、等級 `1`、主機 node10 與完整原始訊息。

## 6. 第四步：套用到全部

```bash
python3 /root/gl-tpl/notif.py apply ALL
GL_URL="$GL_URL" GLPW="$GLPW" python3 /root/gl-notif-inventory.py | grep -E '^==|time_zone|body 長度|subject'
unset GLPW
```

**看到的結果**：`共更新 13 個`；13 個都是 `time_zone: Asia/Taipei`、`body 長度: 507 | html 長度: 1596`（Python 算的是字元數；`ls -l` 顯示的 615／1704 是位元組數，中文一個字佔 3 位元組），VPN 主旨變成 `【VPN 告警】${event_definition_title}`。

**還原**（全部或指定一個；先重新 `read -rsp` 輸入密碼並 `export GLPW`）：

```bash
python3 /root/gl-tpl/notif.py restore /root/gl-notifications-backup-<日期時間>.json ALL
```

> 備份檔含收件人信箱，只有 root 能讀；觀察一週沒問題再刪。

## 7. 第五步：統一主旨

13 個主旨裡只有兩個還是 `【Graylog 警報】…`，看不出類別。改成和其他一樣的「【類別 告警】告警名稱」：

| Notification | 原本 | 改成 |
| --- | --- | --- |
| PVE 任務失敗通知 | `【Graylog 警報】${event_definition_title}` | `【PVE 任務告警】${event_definition_title}` |
| PVE 服務異常通知 | `【Graylog 警報】${event_definition_title}` | `【PVE 服務告警】${event_definition_title}` |

```bash
cat > /root/gl-tpl/subject.py <<'EOF2'
import json, os, sys, base64, urllib.request
url = os.environ["GL_URL"].rstrip("/")
auth = base64.b64encode(("admin:" + os.environ["GLPW"]).encode()).decode()
H = {"Authorization": "Basic " + auth, "Accept": "application/json",
     "Content-Type": "application/json", "X-Requested-By": "cli"}
def call(method, path, data=None):
    body = None if data is None else json.dumps(data).encode()
    req = urllib.request.Request(url + path, method=method, headers=H, data=body)
    with urllib.request.urlopen(req, timeout=15) as r:
        b = r.read()
        return json.loads(b) if b else None
NEW = {"PVE 任務失敗通知": "【PVE 任務告警】${event_definition_title}",
       "PVE 服務異常通知": "【PVE 服務告警】${event_definition_title}"}
for n in call("GET", "/api/events/notifications?per_page=100")["notifications"]:
    if n["title"] in NEW:
        old = n["config"]["subject"]
        n["config"]["subject"] = NEW[n["title"]]
        call("PUT", "/api/events/notifications/" + n["id"], n)
        print("已更新：", n["title"], "|", old, "→", NEW[n["title"]])
EOF2
export GL_URL GLPW
python3 /root/gl-tpl/notif.py backup /root/gl-notifications-backup-$(date +%Y%m%d-%H%M).json
python3 /root/gl-tpl/subject.py
GL_URL="$GL_URL" GLPW="$GLPW" python3 /root/gl-notif-inventory.py | grep -E '^==|subject'
unset GLPW
```

**看到的結果**：`已更新：` 兩行（舊 → 新），盤點後 13 個主旨都不再出現 `【Graylog 警報】`。主旨只影響之後的信件標題，沒有另外觸發測試信，等這兩個告警自然觸發時確認。

## 8. 第六步：「PVE 任務失敗」的摘要改成一眼看懂

中文範本裡的「摘要」（`${event.message}`）是告警的 **Event Summary Template** 組出來的。「PVE 任務失敗警報」原本是 `PVE 任務失敗：${source.message}`，從來沒有驗證過。

**① 看目前的設定（只讀取）**：

```bash
cat > /root/gl-tpl/eventdef.py <<'EOF2'
import json, os, sys, base64, urllib.request
url = os.environ["GL_URL"].rstrip("/")
auth = base64.b64encode(("admin:" + os.environ["GLPW"]).encode()).decode()
req = urllib.request.Request(url + "/api/events/definitions?per_page=100",
      headers={"Authorization": "Basic " + auth, "Accept": "application/json"})
for e in json.load(urllib.request.urlopen(req, timeout=15))["event_definitions"]:
    if e["title"] != sys.argv[1]:
        continue
    def walk(o, path=""):
        if isinstance(o, dict):
            for k, v in o.items(): walk(v, path + "." + k)
        elif isinstance(o, list):
            for i, v in enumerate(o): walk(v, path + "[%d]" % i)
        elif isinstance(o, str) and ("${" in o or "summary" in path.lower() or "template" in path.lower()):
            print(path, "=", o)
    walk(e)
    print("field_spec =", json.dumps(e.get("field_spec"), ensure_ascii=False))
    print("backlog =", (e.get("notification_settings") or {}).get("backlog_size"),
          "| grace(min) =", ((e.get("notification_settings") or {}).get("grace_period_ms") or 0) // 60000)
EOF2
python3 /root/gl-tpl/eventdef.py "PVE 任務失敗警報"
```

看到的結果：`.event_summary_template = PVE 任務失敗：${source.message}`、`field_spec = {}`、`backlog = 5 | grace(min) = 5`。

**② 用合成訊息驗證原本的寫法**（VM 999 不存在，不會動到任何機器）：

```bash
logger -p daemon.warning "end task UPID:node10:TEST:TEST:TEST:vzstart:999:root@pam: GRAYLOG-SUMMARY-TEMPLATE-TEST"
```

看到的結果：Graylog 收到這筆，欄位有 `pve_event_type=task_failed`、`pve_task_name=vzstart`、`pve_task_node=node10`、`pve_vmid=999`；約 5 分鐘後收到【PVE 任務告警】PVE 任務失敗警報，摘要是 `PVE 任務失敗：node10 root: end task UPID:node10:TEST:TEST:TEST:vzstart:999:root@pam: GRAYLOG-SUMMARY-TEMPLATE-TEST`。**`${source.message}` 可以用**，但和下面「相關日誌」重複，重點埋在長字串裡。

**③ 改成結構化摘要**：用 ② 確認存在的欄位，VM 編號用 `${if}` 有才顯示（`aptupdate` 這類任務沒有 VM）：

```bash
cat > /root/gl-tpl/summary.py <<'EOF2'
import json, os, sys, base64, urllib.request
url = os.environ["GL_URL"].rstrip("/")
auth = base64.b64encode(("admin:" + os.environ["GLPW"]).encode()).decode()
H = {"Authorization": "Basic " + auth, "Accept": "application/json",
     "Content-Type": "application/json", "X-Requested-By": "cli"}
def call(method, path, data=None):
    body = None if data is None else json.dumps(data).encode()
    req = urllib.request.Request(url + path, method=method, headers=H, data=body)
    with urllib.request.urlopen(req, timeout=15) as r:
        b = r.read()
        return json.loads(b) if b else None
title, new = sys.argv[1], sys.argv[2]
for e in call("GET", "/api/events/definitions?per_page=100")["event_definitions"]:
    if e["title"] == title:
        os.umask(0o077)
        json.dump(e, open("/root/gl-eventdef-backup-%s.json" % e["id"], "w"), ensure_ascii=False, indent=1)
        print("舊：", e.get("event_summary_template"))
        e["event_summary_template"] = new
        call("PUT", "/api/events/definitions/" + e["id"] + "?schedule=true", e)
        print("新：", call("GET", "/api/events/definitions/" + e["id"]).get("event_summary_template"))
EOF2
python3 /root/gl-tpl/summary.py "PVE 任務失敗警報" '${source.pve_task_node} 的 ${source.pve_task_name} 失敗${if source.pve_vmid}（VM／CT ${source.pve_vmid}）${end}'
```

| 片段 | 意思 |
| --- | --- |
| `gl-eventdef-backup-<id>.json` | 改之前把整份告警設定備份起來 |
| 單引號 `'${source…}'` | 不讓 bash 把 `${…}` 當成自己的變數 |
| `?schedule=true` | 更新後讓告警繼續排程 |
| `${if source.pve_vmid}…${end}` | 有 VM／CT 編號才顯示括號那段 |

看到的結果：`舊： PVE 任務失敗：${source.message}`、`新： ${source.pve_task_node} 的 ${source.pve_task_name} 失敗${if source.pve_vmid}（VM／CT ${source.pve_vmid}）${end}`。

**④ 再測一次**：等上一封的 Grace（5 分鐘）過了才送，否則會被擋下：

```bash
logger -p daemon.warning "end task UPID:node10:TEST:TEST:TEST:vzstart:999:root@pam: GRAYLOG-SUMMARY-TEMPLATE-TEST-2"
```

看到的結果：摘要是 **`node10 的 vzstart 失敗（VM／CT 999）`**。欄位變數 `${source.欄位名}` 和 `${if}` 在 Summary Template 裡都能用。

**還原**：`python3 /root/gl-tpl/summary.py "PVE 任務失敗警報" 'PVE 任務失敗：${source.message}'`。

## 9. 第七步：其他告警的摘要

第六步確認 `${source.欄位}` 可以用之後，先盤點全部告警的摘要（只讀取）：

```bash
cat > /root/gl-tpl/summary-list.py <<'EOF2'
import json, os, base64, urllib.request
url = os.environ["GL_URL"].rstrip("/")
auth = base64.b64encode(("admin:" + os.environ["GLPW"]).encode()).decode()
req = urllib.request.Request(url + "/api/events/definitions?per_page=100",
      headers={"Authorization": "Basic " + auth, "Accept": "application/json"})
for e in sorted(json.load(urllib.request.urlopen(req, timeout=15))["event_definitions"], key=lambda x: x["title"]):
    c = e.get("config") or {}
    print("==", e["title"])
    print("   摘要:", e.get("event_summary_template") or "（空白：信裡會顯示說明）")
    print("   分組:", c.get("group_by") or "（無）", "| 查詢:", (c.get("query") or "")[:90])
EOF2
python3 /root/gl-tpl/summary-list.py
```

**看到的結果**：Ceph、Corosync、Node 離線、儲存 ×3、WireGuard 是空白；多次驗證失敗、DSM 登入失敗、DSM 管理員登入是固定文字；PVE 服務異常是 `PVE 服務異常：${source}`（`${source}` 是整筆訊息，不是欄位，寫法不對）。

**批次修改工具**：讀一個「告警名稱 → 新摘要」的 JSON，改之前把全部告警備份成一個檔案：

```bash
cat > /root/gl-tpl/summary-bulk.py <<'EOF2'
import json, os, sys, base64, urllib.request, time
url = os.environ["GL_URL"].rstrip("/")
auth = base64.b64encode(("admin:" + os.environ["GLPW"]).encode()).decode()
H = {"Authorization": "Basic " + auth, "Accept": "application/json",
     "Content-Type": "application/json", "X-Requested-By": "cli"}
def call(method, path, data=None):
    body = None if data is None else json.dumps(data).encode()
    req = urllib.request.Request(url + path, method=method, headers=H, data=body)
    with urllib.request.urlopen(req, timeout=15) as r:
        b = r.read()
        return json.loads(b) if b else None
NEW = json.load(open(sys.argv[1]))
defs = call("GET", "/api/events/definitions?per_page=100")["event_definitions"]
os.umask(0o077)
bk = "/root/gl-eventdefs-backup-%s.json" % time.strftime("%Y%m%d-%H%M")
json.dump(defs, open(bk, "w"), ensure_ascii=False, indent=1)
print("已備份", len(defs), "個 →", bk)
for e in defs:
    if e["title"] in NEW:
        e["event_summary_template"] = NEW[e["title"]]
        call("PUT", "/api/events/definitions/" + e["id"] + "?schedule=true", e)
        print("已更新：", e["title"], "→", call("GET", "/api/events/definitions/" + e["id"])["event_summary_template"])
EOF2
```

**踩到的雷：「有就觸發」的告警抓不到原始欄位**。第一次把 9 個告警都改成 `…${source.message}`，用假的 Ceph 訊息測試（`logger -t ceph-mon "Health check failed: GRAYLOG-SUMMARY-TEST (TEST_ONLY)"`），摘要卻是 `Ceph 健康警告：Ceph 健康警告: count()=1.0`。原因是 下篇 3-2 清單裡「有就觸發」的告警，底層是先**計數**（`count() > 0`）再產生事件，事件沒有對應到某一筆日誌，`${source.message}` 拿到的是計數結果。原始日誌仍完整列在信裡的「相關日誌」。

| 告警類型（下篇 3-2「分組、門檻」欄） | 例子 | `${source.欄位}` |
| --- | --- | --- |
| 每筆 | PVE 任務失敗、Node 離線、服務異常、DSM 管理員登入、WireGuard | ✅ 可用 |
| 有就觸發、≥ N 次（彙總） | 每日健康回報、多次驗證失敗、DSM 登入失敗（Ceph、Corosync、儲存 ×3 在第八步改成每筆） | ❌ 只會得到 `count()=…`，改用固定說明文字 |

**最後的設定**（兩次 `summary-bulk.py`，JSON 用 `<<'EOF'` 寫入）：

| 告警 | 摘要 |
| --- | --- |
| PVE Node 狀態離線 | `節點離線或監控異常：${source.message}` |
| PVE 服務異常 | `${source.source} 服務異常：${source.message}` |
| Synology DSM 管理員登入 | `DSM 管理員登入：${source.message}` |
| WireGuard VPN 異常 | `WireGuard 異常：${source.message}` |
| Ceph 健康警告 | `Ceph 健康檢查失敗，詳細內容請看下方「相關日誌」` |
| PVE Corosync 成員離線 | `有節點離開 PVE 叢集，請看下方「相關日誌」是哪一台回報` |
| PVE 儲存空間嚴重 | `儲存空間超過 90%，請看下方「相關日誌」是哪一台、哪個儲存` |
| PVE 儲存空間警告 | `儲存空間超過 80%，請看下方「相關日誌」是哪一台、哪個儲存` |
| PVE 儲存設備離線 | `共用儲存狀態異常，請看下方「相關日誌」是哪一台、哪個儲存` |

> 上表 Ceph、Corosync、儲存 ×3 的固定文字只用到 17:09，之後改成每筆並帶出原始訊息，見第八步。
| 多次驗證失敗、DSM 登入失敗、每日健康回報 | 維持原本的固定文字 |

「每筆」類型的四個沒有另外製造事件測試（和 PVE 任務失敗同一種機制），等自然觸發時確認：

| 告警 | 自然觸發 | 結果 |
| --- | --- | --- |
| Synology DSM 管理員登入 | 2026-10-19 16:39 | ✅ 摘要是 `DSM 管理員登入：tokyo16 Connection: User [<NAS 管理員帳號>] from [<IP>] signed in to [DSM] successfully via [OTP].`；「相關日誌」的主機欄同時顯示 `tokyo16` 和 jt-ipam 查到的來源主機名稱（`${message.fields.src_host}`，第 4 節），一眼看出是從哪台登入 |
| PVE Node 狀態離線、PVE 服務異常、WireGuard VPN 異常 | ⏳ 尚未觸發 | |

**還原**：備份在 `/root/gl-eventdefs-backup-<時間>.json`（每次執行各一份），把其中的設定逐一 `PUT` 回 `/api/events/definitions/<id>?schedule=true` 即可。

## 10. 第八步：Ceph、Corosync、儲存 ×3 改成「每筆」

這 5 個告警的門檻都是 `count() > 0`，也就是「有一筆就算」，和「每筆」的觸發時機一樣。改成每筆後摘要就能帶出原始訊息；寄信頻率仍由 Grace 控制（Ceph、Corosync、儲存嚴重、儲存離線 5 分鐘，儲存警告 24 小時），**不會多寄信**，只是事件數量變多（每筆日誌一個事件）。

**① 比對兩種類型實際差在哪**（只讀取；拿已知是每筆的「PVE 任務失敗警報」當範本）：

```bash
cat > /root/gl-tpl/eventdef-compare.py <<'EOF2'
import json, os, base64, urllib.request
url = os.environ["GL_URL"].rstrip("/")
auth = base64.b64encode(("admin:" + os.environ["GLPW"]).encode()).decode()
req = urllib.request.Request(url + "/api/events/definitions?per_page=100",
      headers={"Authorization": "Basic " + auth, "Accept": "application/json"})
want = ["PVE 任務失敗警報", "Ceph 健康警告", "PVE Corosync 成員離線",
        "PVE 儲存空間嚴重", "PVE 儲存空間警告", "PVE 儲存設備離線"]
for e in json.load(urllib.request.urlopen(req, timeout=15))["event_definitions"]:
    if e["title"] not in want:
        continue
    c = e["config"]
    print("==", e["title"])
    for k in ("type", "series", "conditions", "group_by", "event_limit", "search_within_ms", "execute_every_ms"):
        print("   %-17s %s" % (k, json.dumps(c.get(k), ensure_ascii=False)))
    n = e.get("notification_settings") or {}
    print("   %-17s grace=%s 分, backlog=%s" % ("notification", (n.get("grace_period_ms") or 0)//60000, n.get("backlog_size")))
EOF2
python3 /root/gl-tpl/eventdef-compare.py
```

**看到的結果**：兩種都是 `aggregation-v1`，`group_by []`、`event_limit 100`、每 5 分鐘查 5 分鐘，只差兩個欄位：

| 欄位 | 彙總（5 個） | 每筆（PVE 任務失敗） |
| --- | --- | --- |
| `series` | `[{"type": "count", "id": "count-", "field": null}]` | `[]` |
| `conditions` | `count- > 0` | `{"expression": null}` |

**② 轉換**（先備份全部告警，再改這兩個欄位和摘要）：

```bash
cat > /root/gl-tpl/to-filter.py <<'EOF2'
import json, os, sys, base64, urllib.request, time
url = os.environ["GL_URL"].rstrip("/")
auth = base64.b64encode(("admin:" + os.environ["GLPW"]).encode()).decode()
H = {"Authorization": "Basic " + auth, "Accept": "application/json",
     "Content-Type": "application/json", "X-Requested-By": "cli"}
def call(method, path, data=None):
    body = None if data is None else json.dumps(data).encode()
    req = urllib.request.Request(url + path, method=method, headers=H, data=body)
    with urllib.request.urlopen(req, timeout=15) as r:
        b = r.read()
        return json.loads(b) if b else None
NEW = json.load(open(sys.argv[1]))
defs = call("GET", "/api/events/definitions?per_page=100")["event_definitions"]
os.umask(0o077)
bk = "/root/gl-eventdefs-backup-%s.json" % time.strftime("%Y%m%d-%H%M")
json.dump(defs, open(bk, "w"), ensure_ascii=False, indent=1)
print("已備份", len(defs), "個 →", bk)
for e in defs:
    if e["title"] in NEW:
        e["config"]["series"] = []
        e["config"]["conditions"] = {"expression": None}
        e["event_summary_template"] = NEW[e["title"]]
        call("PUT", "/api/events/definitions/" + e["id"] + "?schedule=true", e)
        n = call("GET", "/api/events/definitions/" + e["id"])
        print("已轉換：", e["title"], "| series =", n["config"]["series"], "| 摘要 =", n["event_summary_template"])
EOF2

cat > /root/gl-tpl/to-filter.json <<'EOF2'
{
 "Ceph 健康警告": "Ceph 健康警告：${source.message}",
 "PVE Corosync 成員離線": "${source.source} 回報叢集成員離線：${source.message}",
 "PVE 儲存空間嚴重": "儲存空間嚴重：${source.message}",
 "PVE 儲存空間警告": "儲存空間警告：${source.message}",
 "PVE 儲存設備離線": "儲存設備離線：${source.message}"
}
EOF2
python3 /root/gl-tpl/to-filter.py /root/gl-tpl/to-filter.json
```

| 片段 | 意思 |
| --- | --- |
| `series = []` | 拿掉計數 |
| `conditions = {"expression": None}` | 拿掉 `> 0`；Python 的 `None` 存成 JSON 的 `null` |
| `?schedule=true` | 改完繼續排程（server.log 可能出現 `re-scheduling job trigger`，屬正常，見第 11 節） |

**看到的結果**：`已備份 14 個`；5 行 `已轉換：… | series = [] | 摘要 = …`。

**③ 用假訊息測試 4 個**（儲存警告不測：Grace 24 小時，會擋掉之後真的警告）：

```bash
logger -t ceph-mon "Health check failed: GRAYLOG-FILTER-TEST (TEST_ONLY)"
logger -t corosync "[QUORUM] Members left: GRAYLOG-FILTER-TEST (TEST_ONLY)"
logger -t pve-storage-monitor "STORAGE_CRITICAL host=node10 storage=TEST_ONLY type=filesystem usage=99% threshold=90%"
logger -t pve-storage-monitor "STORAGE_UNAVAILABLE host=node10 storage=TEST_ONLY type=shared status=TEST_ONLY"
```

**看到的結果**：Graylog 17:09:42 收到 4 筆；4 封信的摘要都帶出原始訊息，不再是 `count()=1.0`：

| 信 | 摘要 |
| --- | --- |
| 【Ceph 告警】Ceph 健康警告 | `Ceph 健康警告：node10 ceph-mon: Health check failed: GRAYLOG-FILTER-TEST (TEST_ONLY)` |
| 【PVE Cluster 告警】PVE Corosync 成員離線 | `node10 回報叢集成員離線：node10 corosync: [QUORUM] Members left: GRAYLOG-FILTER-TEST (TEST_ONLY)` |
| 【PVE Storage 嚴重】PVE 儲存空間嚴重 | `儲存空間嚴重：node10 pve-storage-monitor: STORAGE_CRITICAL host=node10 storage=TEST_ONLY type=filesystem usage=99% threshold=90%` |
| 【PVE Storage 離線】PVE 儲存設備離線 | `儲存設備離線：node10 pve-storage-monitor: STORAGE_UNAVAILABLE host=node10 storage=TEST_ONLY type=shared status=TEST_ONLY` |

**還原**：把 `/root/gl-eventdefs-backup-20261019-1709.json` 裡的設定逐一 `PUT` 回 `/api/events/definitions/<id>?schedule=true`。

## 11. 常見問題

| 現象 | 原因 | 怎麼辦 |
| --- | --- | --- |
| 收到【PVE 任務告警】，摘要寫「node10 的 vzstart 失敗（VM／CT 999）」 | 這是第 8 節的結構化摘要：哪個節點、什麼任務、哪台 VM／CT | 完整錯誤在「相關日誌」那一行；到該節點 **Tasks** 看同一筆任務的日誌 |
| 摘要出現 `count()=1.0` | 「有就觸發」的告警是彙總事件，`${source.…}` 拿不到原始日誌 | 門檻是「有一筆就算」的告警，改成每筆（`series` 清空、`conditions` 設為 `{"expression": null}`，第 10 節）；≥ N 次的告警只能用固定說明文字 |
| 用 API 更新告警後，server.log 出現 `ERROR [EventProcessorExecutionJob] The end of the timerange to process is in the future, re-scheduling job trigger …` | `?schedule=true` 重新排程時，觸發時間比現在早一點，Graylog 發現範圍還沒走完，就自動延後重跑 | 自動修正的通知，告警不受影響；10/19 兩次批次修改（15:36、15:43）各出現 5 筆。到 Alerts → Event Definitions 確認都是 Enabled 即可 |
| 信裡時間寫 `2026-10-19T15:36:40.000+08:00`，要不要再加 8 小時？ | 不用。`+08:00` 是**時區標記**（ISO 8601 格式），表示這已經是 UTC+8 的台灣時間；同一瞬間的 UTC 會寫成 `07:36:40.000Z` | 直接讀 `T` 後面的時間即可。決定維持這個格式，不另外改成 `yyyy-MM-dd HH:mm:ss`（改格式是否會把時區轉回 UTC 未確認） |

## 12. 待辦

| 項目 | 說明 |
| --- | --- |
| 「儲存空間警告」的新摘要 | 第八步沒有用假訊息測（Grace 24 小時會擋掉真的警告），自然觸發時確認摘要是 `儲存空間警告：… STORAGE_WARNING host=…` |
| 「每筆」告警的新摘要 | DSM 管理員登入已確認（10/19）；Node 離線、服務異常、WireGuard 自然觸發時，確認摘要顯示正常 |

## 13. 延伸閱讀

- [把 PVE、PBS 與 NAS 的日誌集中到 Graylog（一）](https://kbwangtw.github.io/IT-Knowledge-Base/docs/pve/proxmox-graylog-syslog-pipeline-sop/)：第 9 節 Graylog 寄 Gmail 的設定
- [Graylog 告警與監控（二）](https://kbwangtw.github.io/IT-Knowledge-Base/docs/pve/graylog-alerts-monitoring/)：全部告警清單（3-2）、告警的類型與門檻
- [把 PVE／PBS 通知改成繁體中文](https://kbwangtw.github.io/IT-Knowledge-Base/docs/pve/proxmox-zh-tw-notification/)：PVE／PBS 自己寄的通知信（另一套機制）
- [Graylog 官方文件：Alerts and Notifications](https://go2docs.graylog.org/current/interacting_with_your_log_data/alerts.html)
