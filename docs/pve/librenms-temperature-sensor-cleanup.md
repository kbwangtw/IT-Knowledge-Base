---
layout: default
title: "LibreNMS 溫度告警誤報：LXC 重複感測器與門檻整理"
date: 2026-10-19
categories: [PVE, LibreNMS, Monitoring]
permalink: /docs/pve/librenms-temperature-sensor-cleanup/
last_modified_at: 2026-10-30
---

# LibreNMS 溫度告警誤報：LXC 重複感測器與門檻整理

> **一句話**：LibreNMS 的事件紀錄一直出現「Temperature above threshold」，查下來大多是誤報：10 台 LXC 容器把宿主機的溫度感測器重複回報了 109 次，加上自動產生的門檻太低（例如 CPU 20 °C）。停用容器的感測器、依硬體規格重設三台節點的門檻後，誤報就消失了；剩下 NAS tokyo16 是真的偏熱（設備擺得太密）。

| 項目 | 內容 |
| --- | --- |
| 適合誰看 | LibreNMS 一直跳溫度告警、或監控 PVE 上 LXC 的人 |
| 環境 | LibreNMS（CT 102，PHP 8.4、MariaDB）；PVE 三節點 node10～12（Win element M600：AMD Ryzen 9 8945HS、DDR5 64 GB、雙 NVMe、r8169 網卡）；Synology tokyo16、melayu17 |
| 日期 | 2026-10-19 |
| 結論 | ✅ 10 台 LXC 停用 sensors 模組、刪除 109 個重複感測器 ✅ node10～12 依元件重設門檻，全部低於門檻 ✅ 隔天確認：除 NAS 外溫度事件從 107 筆降到 0 ⏳ tokyo16 偏熱：10/20 起基準線降約 10 °C、搬動看不出效果，剩下每晚兩個排程尖峰，10/28 已重排備份相關工作（第 7-1 節） ✅ node12 NVMe 的 Sensor 2 是讀數卡住，不是過熱（第 8 節） |

## 1. 先認識幾個名詞

| 名詞 | 白話解釋 |
| --- | --- |
| **感測器（sensor）** | LibreNMS 透過 SNMP 讀到的溫度、電壓等讀數，存在資料庫的 `sensors` 表 |
| **門檻（sensor_limit）** | 超過就在事件紀錄寫一筆 `Temperature above threshold`。設備沒提供時，LibreNMS 會在 discovery 時自動算一個 |
| **discovery／polling** | discovery：找出設備有哪些感測器；polling：每 5 分鐘讀一次數值 |
| **模組（module）** | LibreNMS 把功能分成模組，`sensors` 就是負責感測器的那個，可以針對單一設備關掉 |
| **lm-sensors（`sensors` 指令）** | Linux 讀硬體溫度的工具；LibreNMS 看到的感測器名稱（`Tctl`、`nvme-pci-0100:Composite`）就是從這裡來的 |
| **Tctl** | AMD CPU 的溫度（k10temp 驅動） |
| **Composite** | NVMe SSD 的整體溫度；`Sensor 1/2/3` 是 SSD 內部各點（控制器、快閃晶片） |

## 2. 全貌

```text
node10（實體主機）的 CPU、NVMe、RAM、網卡溫度
  ├─ node10 自己的 SNMP 回報 ───────────────► LibreNMS「node10」✅ 保留，重設門檻
  └─ 同一台上的 LXC 共用 kernel，也讀得到 ──► LibreNMS「adguard」「graylog」… ❌ 重複，停用

自動門檻太低（Tctl 20 °C、NVMe 20 °C）──► 永遠「超過」──► 事件紀錄洗版

處理：① 盤點 → ② LXC 停用 sensors 並刪除 → ③ 對照每個感測器是什麼元件 → ④ 依硬體規格設門檻
```

## 3. 步驟一：盤點誰在報溫度（只讀取）

**做什麼**：先看過去 24 小時哪些設備、哪些感測器最常觸發。

```bash
ssh root@node10 "pct exec 102 -- mysql -t librenms -e \"SELECT d.hostname, s.sensor_descr, s.sensor_current, s.sensor_limit, COUNT(*) AS 次數 FROM eventlog e JOIN devices d ON d.device_id=e.device_id LEFT JOIN sensors s ON s.device_id=e.device_id AND s.sensor_class='temperature' AND s.sensor_current >= s.sensor_limit WHERE e.type='temperature' AND e.datetime > NOW() - INTERVAL 1 DAY GROUP BY d.hostname, s.sensor_descr, s.sensor_current, s.sensor_limit ORDER BY 次數 DESC LIMIT 10\"" < /dev/null
```

**看到的結果**（重點）：

| 設備 | 感測器 | 現在／門檻 | 24 小時次數 |
| --- | --- | --- | --- |
| tokyo16 | System | 66 / 61 | 56 |
| pihole | Sensor 1、Sensor 2 | 56.85 / 45、71.85 / 53.75 | 24 |
| adguard | Tctl、nvme Composite 等 4 個 | 例如 73.4 / 62、43.85 / **20** | 22 |
| node12 | Sensor 1、Sensor 2 | 57.85 / 52、71.85 / 49.85 | 15 |

pihole、adguard 是 LXC，卻有 CPU、NVMe 溫度，而且數值和宿主機一樣，懷疑是重複。

**再列出全部**：PVE 上的 LXC 名稱，和 LibreNMS 每台設備的每個溫度感測器：

```bash
pvesh get /cluster/resources --type vm --output-format json | python3 -c '
import json,sys
print(", ".join(sorted(r.get("name","-") for r in json.load(sys.stdin) if r.get("type")=="lxc")))'

ssh root@node10 "pct exec 102 -- mysql -t librenms -e \"
SELECT d.device_id AS id, SUBSTRING_INDEX(d.hostname,'.',1) AS 設備, d.os,
       s.sensor_id AS sid, LEFT(s.sensor_descr,28) AS 感測器,
       ROUND(s.sensor_current,1) AS 現在, ROUND(s.sensor_limit,1) AS 門檻,
       IF(s.sensor_current >= s.sensor_limit,'超過','') AS 狀態
FROM sensors s JOIN devices d ON d.device_id = s.device_id
WHERE s.sensor_class = 'temperature'
ORDER BY d.hostname, s.sensor_descr\"" < /dev/null
```

| 片段 | 意思 |
| --- | --- |
| `pvesh get /cluster/resources` | 從 PVE 拿 LXC 名單；LibreNMS 不知道哪些是容器 |
| `SUBSTRING_INDEX(d.hostname,'.',1)` | 只顯示主機名稱第一段，好讀也不露出網域 |
| `d.os` | LibreNMS 認出的系統類型 |

**看到的結果**：

| 類別 | 設備（LibreNMS device_id） | 說明 |
| --- | --- | --- |
| LXC（10 台） | adguard(8)、pihole(9)、librenms(11)、wireguard(13)、graylog(17)、ai(18)、proxcenter(19)、ipam(20)、wazuh(21)、grafana(23) | 都被認成 `os = proxmox`，每台約 11 個溫度感測器，數值和所在節點相同（例如 pihole、wazuh 都有 node12 才有的 `nvme-pci-0600`、`Sensor 3`） |
| 實體主機 | node10(2)、node11(3)、node12(4) | 門檻很多不合理：三台 `Tctl` 門檻都是 **20**；`acpitz-acpi-0:temp1` 讀數 **0.0** |
| NAS | tokyo16、melayu17（`os = dsm`） | melayu17 系統 40 °C、硬碟 39 °C；tokyo16 硬碟 40～41 °C、**System 66 °C**（見第 7 節） |

## 4. 步驟二：10 台 LXC 停用 sensors，刪除重複感測器

**為什麼**：容器和宿主機共用 kernel，容器裡的 SNMP 也回報宿主機的硬體溫度；同一顆 CPU 被報好幾次，而且每台的自動門檻都不一樣。宿主機自己的感測器保留就夠了。只關模組不夠，已經存在的感測器還留在資料庫，所以也要刪掉。

**怎麼做**（node10；先備份）：

```bash
ssh root@node10 "pct exec 102 -- sh -c '
  IDS=\"8,9,11,13,17,18,19,20,21,23\"
  echo \"--- 1. 這 10 台各類感測器的數量（修改前）---\"
  mysql -t librenms -e \"SELECT sensor_class, COUNT(*) AS 數量 FROM sensors WHERE device_id IN (\$IDS) GROUP BY sensor_class\"
  echo \"--- 2. 備份 ---\"
  mysqldump --single-transaction librenms sensors devices_attribs | gzip > /root/sensors-before-lxcfix-20261019.sql.gz
  ls -lh /root/sensors-before-lxcfix-20261019.sql.gz
  echo \"--- 3. 停用 sensors 模組（輪詢與探索）---\"
  mysql librenms -e \"DELETE FROM devices_attribs WHERE device_id IN (\$IDS) AND attrib_type IN (\\\"poll_sensors\\\",\\\"discover_sensors\\\");
    INSERT INTO devices_attribs (device_id, attrib_type, attrib_value)
    SELECT device_id, t.a, \\\"0\\\" FROM devices JOIN (SELECT \\\"poll_sensors\\\" AS a UNION SELECT \\\"discover_sensors\\\") t WHERE device_id IN (\$IDS)\"
  echo \"--- 4. 刪除這 10 台的溫度感測器 ---\"
  mysql librenms -e \"DELETE FROM sensors WHERE device_id IN (\$IDS) AND sensor_class=\\\"temperature\\\"\"
  echo \"--- 5. 確認 ---\"
  mysql -t librenms -e \"SELECT device_id, attrib_type, attrib_value FROM devices_attribs WHERE device_id IN (\$IDS) AND attrib_type LIKE \\\"%_sensors\\\" ORDER BY device_id, attrib_type\"
  mysql -t librenms -e \"SELECT COUNT(*) AS 剩下的溫度感測器 FROM sensors WHERE device_id IN (\$IDS) AND sensor_class=\\\"temperature\\\"\"
'" < /dev/null
```

| 片段 | 意思 |
| --- | --- |
| `IDS=…` | 10 台 LXC 的 device_id（步驟一的表） |
| `devices_attribs` 的 `poll_sensors`／`discover_sensors` = `0` | 這台設備的 sensors 模組「輪詢」「探索」都關，之後不會再加回來 |
| `DELETE FROM sensors … temperature` | 刪掉已存在的重複感測器 |

**看到的結果**：修改前只有 `temperature 109`；備份 5.4 KB；10 台各有 `discover_sensors 0`、`poll_sensors 0`（共 20 行）；`剩下的溫度感測器 0`。

**到網頁確認**：裝置 → 打開任一台容器（例如 pihole）→ 右上角齒輪 → **模組**，Filter 輸入 `sensors`：DISCOVERY、POLLING 都是關閉，標示黃色 **Device override**（`Use default (on)` 是恢復預設的連結）。上方的 `Overrides only (1)` 把同一模組的探索與輪詢算成 1 個。

**還原**：`zcat /root/sensors-before-lxcfix-20261019.sql.gz | mysql librenms`（在 CT 102 內）（這次的備份已於 2026-10-20 刪除）；也可以在網頁點 `Use default` 恢復模組，感測器會在下次 discovery 時加回來。

## 5. 步驟三：對照每個感測器是什麼元件（只讀取）

**做什麼**：在三台節點跑 `sensors`，順便看 NVMe 型號，把 LibreNMS 的名稱對到實際元件，也拿到廠商自己的門檻（括號裡的 `high`／`crit`）。

```bash
for n in node10 node11 node12; do
  echo "=================== $n ==================="
  ssh -o BatchMode=yes root@$n 'sensors 2>/dev/null | grep -vE "^$|^Adapter" ; echo "--- NVMe 型號 ---"; for d in /sys/class/nvme/nvme*; do echo "$(basename $d) $(cat $d/address 2>/dev/null) $(cat $d/model 2>/dev/null | xargs)"; done'
done
```

**看到的結果**：

| LibreNMS 名稱 | lm-sensors 晶片 | 元件 | 硬體門檻 | 目前讀數 |
| --- | --- | --- | --- | --- |
| `Tctl` | k10temp-pci-00c3 | AMD CPU | 未提供 | 41～58 °C |
| `nvme-pci-0100:Composite`、`Composite` | nvme-pci-0100／0600 | NVMe SSD 整體 | high 74.8～99.8（依型號） | 33～54 °C |
| `…Sensor 1/2/3` | nvme 內部 | NVMe 控制器／快閃 | 未提供（`65261.8` = 未定義） | node12 `Sensor 2` **71.8 °C** |
| `spd5118-i2c-0-50/51:temp1` | spd5118 | DDR5 記憶體 | high 55、crit 85 | 46～54 °C（node11、node12 已顯示 `ALARM (HIGH)`） |
| `r8169_0_200/300:…:temp1` | r8169 | 2.5G 網卡 | high 120 | 59～66.5 °C |
| `temp1`（沒有前綴） | mt7921_phy0 | Wi-Fi 網卡 | 未提供 | 38～46 °C |
| `acpitz-acpi-0:temp1` | acpitz | 主機板 ACPI | — | 0.0（無效） |

NVMe 型號：每台 06:00 是 512 GB 系統碟、01:00 是 2 TB 資料碟（node10 BIWIN NV7200、node11 Lexar THOR PRO、node12 KINGSTON SNV3S；2 TB 碟的 high 分別是 89.8、99.8、74.8）。

判讀：node12 的 71.8 °C 是 2 TB 碟的內部感測器，同一顆的 Composite 只有 42.9 °C，推測是控制器本來就比較熱；DDR5 的 high 55 是模組的保守值，離 crit 85 還遠。

## 6. 步驟四：依元件設定合理門檻

| 元件 | 門檻 | 理由 |
| --- | --- | --- |
| CPU（`Tctl`） | 85 | Ryzen 約 95 °C 才降頻，留 10 度 |
| NVMe 整體（`Composite`） | 70 | 三顆 2 TB 碟最低的 high 是 74.8，取保守統一值 |
| NVMe 內部（`Sensor 1/2/3`） | 85 | 控制器本來就熱，node12 的 71.8 不誤報 |
| DDR5（`spd5118`） | 75 | 介於模組 high 55（太保守）與 crit 85 |
| 網卡（`r8169`） | 95 | 硬體 high 120 |
| Wi-Fi（`temp1`） | 85 | 未使用，給合理值 |
| ACPI（`acpitz`） | 不動 | 讀數 0，不會觸發 |

```bash
ssh root@node10 "pct exec 102 -- sh -c '
  mysqldump --single-transaction librenms sensors | gzip > /root/sensors-before-limits-20261019.sql.gz
  ls -lh /root/sensors-before-limits-20261019.sql.gz
  mysql librenms -e \"UPDATE sensors SET sensor_limit = CASE
      WHEN sensor_descr = \\\"Tctl\\\"            THEN 85
      WHEN sensor_descr LIKE \\\"%Composite\\\"   THEN 70
      WHEN sensor_descr LIKE \\\"%Sensor %\\\"    THEN 85
      WHEN sensor_descr LIKE \\\"spd5118%\\\"     THEN 75
      WHEN sensor_descr LIKE \\\"r8169%\\\"       THEN 95
      WHEN sensor_descr = \\\"temp1\\\"           THEN 85
      ELSE sensor_limit END,
    sensor_custom = \\\"Yes\\\"
    WHERE device_id IN (2,3,4) AND sensor_class = \\\"temperature\\\" AND sensor_descr NOT LIKE \\\"acpitz%\\\"\"
  mysql -t librenms -e \"SELECT SUBSTRING_INDEX(d.hostname,\\\".\\\",1) AS 設備, LEFT(s.sensor_descr,28) AS 感測器,
      ROUND(s.sensor_current,1) AS 現在, ROUND(s.sensor_limit,1) AS 門檻, s.sensor_custom AS 自訂,
      IF(s.sensor_current >= s.sensor_limit,\\\"超過\\\",\\\"\\\") AS 狀態
    FROM sensors s JOIN devices d ON d.device_id=s.device_id
    WHERE s.device_id IN (2,3,4) AND s.sensor_class=\\\"temperature\\\" ORDER BY d.hostname, s.sensor_descr\"
'" < /dev/null
```

| 片段 | 意思 |
| --- | --- |
| `CASE WHEN … THEN …` | 依名稱判斷元件，套用對應門檻 |
| `sensor_custom = "Yes"` | 標成手動設定，discovery 不會改回自動值（推測和網頁手動改門檻效果相同） |
| `device_id IN (2,3,4)` | 只改 node10～12 |

**看到的結果**：三台共 36 個感測器，除了 3 個 `acpitz` 以外「自訂」都是 `Yes`，**狀態欄全部空白**。例如 node10 `Tctl 57.5 / 85`、node11 `nvme-pci-0100:Composite 53.8 / 70`、node12 `Sensor 2 71.8 / 85`。

**還原**：`zcat /root/sensors-before-limits-20261019.sql.gz | mysql librenms`（在 CT 102 內）（這次的備份已於 2026-10-20 刪除）；之後要改門檻，直接在網頁 Health → Temperature 修改。

### 6-1 隔天確認：誤報消失了

**怎麼做**（2026-10-20 早上，只讀取）：以門檻調整的 10/19 16:35 為分界，統計每台設備前後的溫度事件數。

```bash
ssh root@node10 "pct exec 102 -- mysql -t librenms -e \"
SELECT SUBSTRING_INDEX(d.hostname,'.',1) AS 設備,
       SUM(e.datetime <  '2026-10-19 16:35:00') AS 調整前24小時,
       SUM(e.datetime >= '2026-10-19 16:35:00') AS 調整後,
       MAX(e.datetime) AS 最後一次
FROM eventlog e JOIN devices d ON d.device_id = e.device_id
WHERE e.type = 'temperature' AND e.datetime > '2026-10-18 16:35:00'
GROUP BY d.hostname ORDER BY 調整後 DESC, 調整前24小時 DESC\"" < /dev/null
```

**看到的結果**：

| 設備 | 調整前 24 小時 | 調整後（到 10/20 早上） |
| --- | --- | --- |
| node10、node11、node12 | 10、11、15 | **0** |
| pihole、adguard、wazuh | 24、22、18 | **0** |
| 其他 7 台 LXC（librenms、graylog、ai、wireguard、ipam、grafana、proxcenter） | 各 1 | **0** |
| tokyo16（NAS，見第 7 節） | 56 | 7 |

除了 NAS 以外，溫度事件從調整前 24 小時的 107 筆降到 0。tokyo16 是真的偏熱，見第 7 節。

## 7. tokyo16 的系統溫度：設備擺得太密

**判斷**：tokyo16 的硬碟只有 40～41 °C，但系統（主機板）溫度白天常超過門檻 61 °C；同樣是 Synology 的 melayu17 只有 40 °C。原因是**機櫃裡設備擺放過於密集，冷熱空氣無法對流**，熱氣排不出去。這是真的偏熱，不是誤報，所以門檻 61 °C 不動。

**搬動前的基準**（2026-10-20 早上，只讀取）：

```bash
pct exec 102 -- mysql -t librenms -e "
SELECT ROUND(s.sensor_current,1) AS 現在溫度, s.sensor_limit AS 門檻
FROM sensors s JOIN devices d ON d.device_id=s.device_id
WHERE SUBSTRING_INDEX(d.hostname,'.',1)='tokyo16' AND s.sensor_descr='System' AND s.sensor_class='temperature';
SELECT DATE(datetime) AS 日期, COUNT(*) AS 溫度事件
FROM eventlog e JOIN devices d ON d.device_id=e.device_id
WHERE SUBSTRING_INDEX(d.hostname,'.',1)='tokyo16' AND e.type='temperature'
  AND e.datetime > NOW() - INTERVAL 14 DAY GROUP BY DATE(datetime);"
```

| 片段 | 意思 |
| --- | --- |
| `pct exec 102` | 在 CT 102 所在的節點（目前 node10）執行；在別台就用 `ssh root@<節點> "…" < /dev/null` |
| `sensor_class='temperature'` | 只看溫度；tokyo16 另有一個同名的 `System` 狀態感測器（值 1、沒有門檻），不加會一起列出 |
| 第二段 | 每天觸發幾次溫度事件 |

**看到的結果**：

| 項目 | 搬動前 |
| --- | --- |
| 系統溫度 | 10/20 早上 50 °C；10/19 白天 66 °C |
| 每天溫度事件 | 10/13～10/19 分別是 40、52、48、53、56、59、40 次（10/20 早上 4 次；原先以為是「機房較涼、只過半天」，後來證實是誤判，見 7-1） |
| 參考：melayu17 | 系統 40 °C |

**處理**：2026-10-24～25 週末調整設備擺放位置。

| 調整時注意 | 說明 |
| --- | --- |
| 進出風方向一致 | Synology 多半前進風、後出風；相鄰設備的排氣口不要對著別台的進風口 |
| 背後留空間 | 出風口後面最好留 10 cm 以上 |
| 不要堆疊 | 下面那台的熱氣會直接被上面那台吸進去 |
| 遠離熱源 | 避開 PVE 節點、UPS、交換器的排氣口 |

**搬完後怎麼判斷**（隔至少一個白天，用上面同一段查詢）：

| 看到 | 結論 |
| --- | --- |
| 整天低於 61 °C、搬完後溫度事件 0 次 | ✅ 改善 |
| 事件減少到每天個位數 | 有改善；再看 DSM → 控制台 → 硬體與電源 → 風扇模式 |
| 和以前差不多 | 對流仍不足或有其他熱源 |

### 7-1. 搬動後的實測：搬動沒有效果，尖峰對得上備份排程（2026-10-28）

**做什麼**：用同一段查詢，比較 10/24～25 搬動前後的溫度事件數，再看 LibreNMS 的 30 天與 48 小時曲線。

**每天溫度事件數**（tokyo16，數字取自 LibreNMS 事件紀錄）：

| 日期 | 事件數 | 日期 | 事件數 |
| --- | --- | --- | --- |
| 10/08 | 51 | 10/19 | 40 |
| 10/09 | 61 | 10/20 | 6 |
| 10/10 | 51 | 10/21 | 5 |
| 10/11 | 53 | 10/22 | 2 |
| 10/12 | 49 | 10/23 | 6 |
| 10/13 | 56 | 10/24 | 3 |
| 10/14 | 52 | 10/25 | 4 |
| 10/15 | 48 | 10/26 | 3 |
| 10/16 | 53 | 10/27 | 3 |
| 10/17 | 56 | 10/28 | 4 |
| 10/18 | 59 | | |

2026-10-28 當下：tokyo16 系統溫度 53.0 °C（門檻 61），melayu17 40.0 °C（門檻 60）。

**看到的結果**：

| 觀察 | 結論 |
| --- | --- |
| 10/19 以前每天 40～60 次，10/20 起降到每天 2～6 次 | 降低發生在 **搬動之前**（10/19 晚到 10/20），不是搬動的功勞 |
| 30 天曲線：基準線從約 60 °C 降到約 50 °C，尖峰從約 79 °C 降到約 65～72 °C | 降的是「平常」的溫度 |
| 10/24～25 搬動後、10/23 加裝 10G 網卡後，曲線都沒有再出現階梯 | 搬動與 10G 網卡都**看不出可量測的效果** |
| 48 小時曲線：每晚兩個尖峰，分別在約 00:00～01:00 與 02:10～03:10，最高 72.2 °C；48 小時平均 51.3 °C、最低 46.0 °C | 尖峰時間對得上 PBS GC（00:00）與 Verify、NAS 複寫（02:00～03:11） |

> **推測，未確認**：基準線在 10/20 下降的原因。已知 tokyo16 的 DSM 風扇模式是**靜音模式**；除此之外沒有找到其他線索。尖峰由 GC、Verify、複寫造成也是依時間對照的推論，尚未用 DSM 資源監控驗證。

**怎麼辦**（2026-10-28 決定）：不調整門檻（61 °C），改成把備份相關工作重排，同時符合「先驗證、再複製」的資料安全順序：

| 工作 | 原本 | 調整後 | 說明 |
| --- | --- | --- | --- |
| PVE 備份寫入 | 21:00～22:30 | 不變 | |
| PBS Verify | 02:00～03:04 | **22:45 起**（約 1 小時） | 緊接備份，檢查剛寫入的資料 |
| PBS GC | 00:00～00:08 | **00:30** | 等 Verify 跑完，兩者不重疊 |
| NAS 複寫到 melayu17 | 02:00～03:11 | 不變 | 複製的是已驗證過的資料 |

```text
21:00 PVE 備份 → 22:45 Verify → 00:30 GC → 02:00 NAS 複寫
（先寫入 → 先驗證 → 再清空間 → 最後複製出去）
```

| 為什麼這樣排 | 說明 |
| --- | --- |
| 資料安全 | 複寫排在 Verify 之前，來源若有壞掉的 chunk 會被一起複製；先驗證再複製可降低這個風險 |
| 溫度 | 三個工作各自獨立、互不重疊；缺點是 21:00～00:40 連續約 3.5 小時有負載，要用曲線觀察 |
| Verify 排在備份後 | PVE 備份是三個工作：node10 21:00、node11 21:30、node12 22:00。Verify log 顯示最晚一份快照 22:03:48 才開始，所以最晚的備份約 22:07 結束；備份通知信（總執行時間）算出實際結束：node10 21:12、node11 21:36、node12 **22:07:48**，22:45 有約 37 分鐘緩衝（第 7-2 節） |
| GC 要在 Prune 之後 | PBS 的 Prune Jobs 是空的；Prune 由 PVE 備份工作的保留設定（`keep-daily=7,keep-last=3`）在備份後順便執行，所以一定在 GC 之前，不用另外排 |

> 2026-10-28 白天還改過一次「Verify 改 04:00」，同一天決定改成上表的排法，因為 04:00 會讓複寫排在 Verify 之前。

**PBS 現況與 10/28 Verify 實測**（只讀取，來自 PBS 的 Verify Jobs、Prune & GC Jobs 畫面與 10/28 02:00 的 Verify log）：

| 項目 | 看到 | 意思 |
| --- | --- | --- |
| Skip Verified | Yes | 只驗新快照，舊的顯示 `SKIPPED (recently verified)` |
| Re-Verify After | 15 Days | 保留設定只留約 7 天，快照活不到 15 天，實際上每份快照只驗一次；不建議改小，改成 7 天會讓每晚 Verify 約加倍 |
| 10/28 Verify | 02:00～03:07，1 小時 7 分，`TASK OK`，0 errors | 15 個 group（10 個 CT、5 個 VM）各驗 1 份新快照 |
| 驗證量與速度 | 約 142 GiB，平均約 36 MiB/s；log 寫 `using 1 read and 4 verify thread(s)` | 只有 1 條讀取執行緒，瓶頸比較像單執行緒讀 CIFS，不是 10G 網路（推測） |
| 時間分布 | 5 台 VM 約 54 分鐘（vm/108 16.1、vm/111 10.1、vm/106 9.8、vm/107 9.5、vm/104 8.4），10 個 CT 合計約 13 分鐘 | 03:00 左右的尖峰對得上 vm/108、vm/111 這段（時間對應，同時段 NAS 複寫也在跑，不能證明因果） |
| GC | 排程 daily（00:00），上次 00:06:49、耗時 6m49s、OK；清除 30.17 GB、待清除 39.37 GB | 預計改 00:30 |

> 這份 log 是裝 10G 網卡**之後**的數據，沒有裝網卡前的 Verify log 可以比較。

**改完後怎麼判斷**（觀察 2～3 個夜晚，用第 7 節同一段查詢加 LibreNMS 48 小時圖）：

| 看到 | 結論 |
| --- | --- |
| 00:00～03:10 的尖峰消失或低於 61 °C，事件數降到 0～1 次 | ✅ 排程錯開有效 |
| 22:45～00:40 出現新的尖峰 | 負載只是搬到別的時段；考慮拉開 Verify 與 GC 的間隔，或把風扇模式改為「酷涼」 |
| Verify 或 GC 在 PBS → Tasks 顯示失敗 | 先回復原排程，再查原因（可能是備份還沒結束就開始 Verify） |

**風扇模式**：現在是靜音模式，重負載時溫度容易衝高。**一次只改一個變數**，先觀察排程重排的效果，再決定要不要改成「酷涼」（風扇聲變大，要看 tokyo16 放的位置能否接受）。

### 7-2. 2026-10-29 補充：新排程第一晚、備份結束時間與干擾因素

**新排程第一晚（10/28）**：Verify 在 22:45 開始，**23:50:10 結束、耗時約 1 小時 5 分、OK**，和預估的 23:52 幾乎一樣。

**備份實際結束時間**（用備份通知信的總執行時間算，並用最後一份快照的「開始時間 ＋ 耗時」交叉驗證，兩種算法吻合）：

| 備份工作 | 開始 | 總執行時間 | 結束 |
| --- | --- | --- | --- |
| node10（21:00） | 21:00:01 | 12m 16s | 約 21:12:17 |
| node11（21:30） | 21:30:01 | 6m 36s | 約 21:36:37 |
| node12（22:00） | 22:00:04 | 7m 44s | 約 22:07:48 |

**GC 通知信**（10/29 凌晨）：成功，回收 54.098 GiB、22,825 個區塊，損壞區塊 0，等待移除 0 B；索引檔案數 **270**。

270 剛好等於「10 個 CT × 10 份 × 2 個索引＋4 台 VM × 10 份 × 1＋VM 111 × 10 份 × 3」，代表**每個 group 仍是 10 份快照**，和 `keep-daily=7` 對不上。但 PBS 的 Prune 任務 30 天有 450 筆（436 成功、14 警告），所以 Prune 有在跑，為什麼是 10 份**未確認**。

**30 天任務摘要裡的失敗**：Verify 失敗 1、GC 失敗 1，點進去是 **10/19 測試中文通知時在 `zhtest`（測試用 datastore）故意製造的失敗**，不是正式的 Tokyo16（見[中文通知文件](https://kbwangtw.github.io/IT-Knowledge-Base/docs/pve/proxmox-zh-tw-notification/)）；Tokyo16 的 Backups 438 次、Verify、GC 在 30 天內沒有失敗。

**Re-Verify After**：原本 15 天；10/29 曾改成 7 天，又在當晚 22:45 前改回 15 天。快照約活 10 天，15 天大於壽命，等於不重驗；Verify 每晚驗最新那份快照，會把它引用的 chunk 幾乎全部重讀一遍（例如 vm/108 每晚約 37 GiB），所以還在使用的資料其實每天都在被檢查。這是依 Verify log 的推論，沒有實測。想再加一層保障，觀察完再考慮改成 9 天（每份快照在被刪前多驗一次）。

> **干擾因素（10/29）**：上午 PBS 更新並重開（kernel -26）；09:21～約 14:00 PVE 三台由 ProxCenter 分兩輪更新、逐台重開，VM 104、107、111 搬到 node11。**10/29 晚上的曲線不能直接和前幾晚比**；VM 被搬移後 dirty bitmap 可能重置，當晚備份可能比平常久（推測，未實測）。細節見 [PBS 更新 SOP 第 12 節](https://kbwangtw.github.io/IT-Knowledge-Base/docs/pve/ProxCenter-PBS-Update-and-DR-Validation-SOP/) 與 [ProxCenter 更新第 13 節](https://kbwangtw.github.io/IT-Knowledge-Base/docs/pve/proxcenter-ceph-rolling-update/)。

### 7-3. 2026-10-30：新排程兩晚的實測，02:00～03:10 的尖峰消失，最高溫沒降

**做什麼**：用 LibreNMS tokyo16 System 溫度圖（2026-10-28 00:00 起、約 2.5 天，解析度足以看夜間尖峰），比較新排程（備份 21:00、Verify 22:45、GC 00:30、複寫 02:00）的前後。下表的溫度是**從曲線讀的近似值**。

| 時段 | 排程 | 圖上看到 |
| --- | --- | --- |
| 10/28 凌晨（舊排程） | 00:00 GC、02:00～03:10 Verify＋複寫 | 開頭約 72 °C 的尖峰；02:00～03:00 約 67～68 °C |
| 10/28 晚（新排程第一晚） | 備份、Verify | 21:00～22:15 約 66～72 °C；23:00～00:00 一群約 70 °C |
| 10/29 00:30 | GC | 約 70 °C 的尖峰 |
| **10/29 凌晨 01:00～03:10** | **只剩複寫** | **落回基準線，尖峰約 58～60 °C 以下** |
| 10/29 晚（第二晚） | 同上 | 22:00～23:00 一群約 66 °C；**最高約 72.8 °C 出現在 10/30 00:26 前後（GC 開始）** |
| 10/30 凌晨 01:00～03:10 | 只剩複寫 | 同樣落回基準線 |

圖例：Now 49.3 °C、Avg 51.4 °C、Min 46.0 °C、Max 72.8 °C。

**結論**：

| 問題 | 結論 |
| --- | --- |
| 02:00～03:10 的尖峰 | ✅ **消失**：以前 Verify 加複寫那段最高 72.2 °C，現在複寫單獨跑只到約 60 °C 以下，**證實 Verify 是那段的熱源** |
| 整體最高溫 | ❌ **沒有降**：72.8 °C 對 72.2 °C |
| 平均溫度 | ❌ 51.4 °C，和上一次 48 小時圖的 51.3 °C 幾乎一樣 |
| 熱量去哪了 | 搬到 21:00～00:30；備份、Verify、GC **各自單獨跑也會衝到約 66～72 °C** |

「錯開之後尖峰會變低」這個假設**沒有被證實**；證實的是「錯開把重疊拆掉，但每個工作單獨就夠熱」，所以尖峰高度沒降，只是移到別的時段。熱源的對應（GC 更新大量 chunk 的存取時間、Verify 持續讀約 142 GiB、備份寫入）依時間對照推論，**沒有用 DSM 資源監控驗證**。

> 10/29 白天有 PBS 與 PVE 更新、VM 搬移，**第二晚的曲線不能和前幾晚完全等同比較**；這兩晚也只是兩個樣本。

**風扇模式**：使用者決定**維持靜音，不改**（2026-10-30）。若日後仍想降低尖峰，其餘的槓桿是調整告警門檻（61 °C），但**DS723+ 系統溫度的官方上限我沒有查證**，調之前要先查規格。

## 8. node12 NVMe 的 Sensor 2：讀數卡住，不是過熱（2026-10-21）

**做什麼**：node12 的 2 TB NVMe（KINGSTON SNV3S）內部 `Sensor 2` 一直是 72 °C 左右，是三台最高的，確認是不是越來越熱。

**怎麼做①：看硬碟自己記錄的 SMART**（在 node10 執行，唯讀；用 PCI 位置找出 2 TB 碟，重開後 `/dev/nvmeX` 編號可能會變）：

```bash
ssh root@node12 '
for d in /sys/class/nvme/nvme*; do [ "$(cat $d/address)" = "0000:01:00.0" ] && dev=/dev/$(basename $d); done
echo "== 裝置：$dev"
smartctl -A $dev | grep -iE "temperature|warning|critical|percentage used|data units written|media"
'
```

| 項目 | 數值 |
| --- | --- |
| Critical Warning | `0x00` |
| Temperature（整體） | 38 °C |
| Sensor 1／2／3 | 47／**72**／38 °C |
| Warning／Critical Comp. Temperature Time | **0／0**（從出廠到現在，超過警告／危險溫度的累計分鐘數） |
| Percentage Used | 3% |
| Data Units Written | 17.0 TB |
| Media and Data Integrity Errors | 0 |

**怎麼做②：看 LibreNMS 一個月的圖**（Devices → node12 → Health → Temperature → Sensor 2 → 1 個月）：

```text
9/22～9/26：約 43～55 °C，有正常的上下起伏
9/26      ：突然跳到 69 °C
9/30 起   ：72 °C，一條水平直線，一個月幾乎沒有變動
```

**判讀**：

- 真實溫度一定會隨負載起伏（備份時段、白天晚上）；Sensor 2 從 9/30 起是**一條水平線**，整體溫度同時只有 38 °C。推測是這顆碟的韌體回報固定值（讀數卡住），**不是真實溫度**。
- 硬碟判斷過熱用的是整體溫度，**累計過熱 0 分鐘**，壽命 3%、沒有資料錯誤，碟本身健康。
- 跳變的原因（9/26 前後發生了什麼）未確認。
- 處理：不用動。Sensor 2 的 LibreNMS 門檻 85 °C 維持，不會誤報；判斷這顆碟的溫度看 `Composite` 和 SMART。下次 node12 重開後（例如單節點故障演練）再看一次 Sensor 2，若變回有起伏的數值，就更能確定是韌體卡住。

## 9. 常見問題

| 現象 | 怎麼辦 |
| --- | --- |
| LXC 容器在 LibreNMS 有 CPU、NVMe 溫度 | 容器共用宿主機 kernel，讀到的是宿主機硬體；對容器停用 sensors 模組並刪除已存在的感測器（步驟二） |
| 門檻是 20 °C 之類明顯不合理的值 | 設備沒提供門檻時，LibreNMS 自動產生；依 `sensors` 括號裡的硬體門檻或元件規格重設，並標 `sensor_custom = Yes`（步驟四） |
| 只關了模組，舊感測器還在、還在報 | 關模組不會刪除已存在的資料；刪除 `sensors` 表裡那台的紀錄 |
| 不知道 `Sensor 2`、`temp1` 是什麼 | 在節點跑 `sensors`，看它在哪個晶片底下（`nvme-pci-…`、`mt7921_phy0`…）（步驟三） |
| `sensors` 顯示 `ALARM (HIGH)` | 是硬體模組自己的門檻（例如 DDR5 high 55）；對照 `crit` 判斷是否真的危險 |
| `acpitz-acpi-0:temp1` 一直是 0.0 | 這個 ACPI 感測器沒有讀數，可以不管 |
| 某個感測器一直是同一個數字（圖是水平直線） | 可能是讀數卡住；對照同一顆元件的其他感測器和 SMART 的過熱累計時間判斷（第 8 節） |

## 10. 待辦

- [x] 觀察到隔天早上，LXC 與 node10～12 都沒有再出現 `Temperature above threshold`（見 6-1）
- [x] tokyo16：10/24～25 調整擺放位置，10/26～28 比較搬動前後：看不出效果（第 7-1 節）
- [x] tokyo16：確認 Skip Verified 已開（Yes）、Prune 由 PVE 備份工作處理（一定在 GC 之前）、備份最晚約 22:07 結束（第 7-1、7-2 節）
- [x] tokyo16：PBS Verify Job 改為 22:45、GC 改為 00:30（複寫維持 02:00），觀察 10/28、10/29 兩晚的曲線（第 7-3 節）
- [ ] 查 10/29、10/30 的每天溫度事件數（第 7 節的查詢），確認超過 61 °C 的次數有沒有下降
- [ ] （選做）PVE 備份保留設定是 `keep-daily=7`，但每組仍有 10 份快照；Prune 每天都有跑（30 天 436 次成功、14 次警告），原因未確認：看 Storage 層級的保留設定、Prune 警告內容
- [ ] 查 PBS「最長工作」裡約 1 小時 17 分的 8 筆 GC 是哪幾天（10/28 的 GC 只花 6 分 49 秒），對照 10/20 基準線下降
- [ ] 10/31 判讀時，把 10/29 的 PBS 與 PVE 更新、節點重開、VM 搬移算進干擾因素
- [x] DSM 風扇模式：使用者決定維持靜音，不改（2026-10-30）
- [ ] 評估是否調整 tokyo16 的告警門檻（先查 DS723+ 系統溫度的官方規格，現在沒有查證）
- [ ] 以後新增 LXC 到 LibreNMS 時，加入後就關掉 sensors 模組
- [x] node12 的 2 TB NVMe（KINGSTON SNV3S）內部感測器 71.8 °C：10/21 確認是讀數卡住、碟本身健康（第 8 節）
- [ ] node12 下次重開後，看 Sensor 2 是否恢復起伏（可和單節點故障演練一起做）
- [x] 刪除 CT 102 的 `/root/sensors-before-lxcfix-20261019.sql.gz`、`/root/sensors-before-limits-20261019.sql.gz`（2026-10-20）

## 11. 延伸閱讀

- [一次檢查並統一所有 LXC 的時區](https://kbwangtw.github.io/IT-Knowledge-Base/docs/pve/pve-lxc-timezone/)：這次是在修正 LibreNMS 舊事件紀錄時發現溫度事件的
- [用 Grafana 建立戰情中心（二）：接上 LibreNMS](https://kbwangtw.github.io/IT-Knowledge-Base/docs/pve/grafana-war-room-librenms/)
- [LibreNMS 官方文件：Health Information（Sensors）](https://docs.librenms.org/Support/Health-Information/)
- [lm-sensors](https://github.com/lm-sensors/lm-sensors)
