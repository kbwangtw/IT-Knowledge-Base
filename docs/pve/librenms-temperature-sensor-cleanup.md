---
layout: default
title: "LibreNMS 溫度告警誤報：LXC 重複感測器與門檻整理"
date: 2026-10-19
categories: [PVE, LibreNMS, Monitoring]
permalink: /docs/pve/librenms-temperature-sensor-cleanup/
last_modified_at: 2026-10-19
---

# LibreNMS 溫度告警誤報：LXC 重複感測器與門檻整理

> **一句話**：LibreNMS 的事件紀錄一直出現「Temperature above threshold」，查下來大多是誤報：10 台 LXC 容器把宿主機的溫度感測器重複回報了 109 次，加上自動產生的門檻太低（例如 CPU 20 °C）。停用容器的感測器、依硬體規格重設三台節點的門檻後，只剩 NAS tokyo16 的系統溫度值得追。

| 項目 | 內容 |
| --- | --- |
| 適合誰看 | LibreNMS 一直跳溫度告警、或監控 PVE 上 LXC 的人 |
| 環境 | LibreNMS（CT 102，PHP 8.4、MariaDB）；PVE 三節點 node10～12（AMD Ryzen、DDR5、雙 NVMe、r8169 網卡）；Synology tokyo16、melayu17 |
| 日期 | 2026-10-19 |
| 結論 | ✅ 10 台 LXC 停用 sensors 模組、刪除 109 個重複感測器 ✅ node10～12 依元件重設門檻，全部低於門檻 ⏳ tokyo16 System 66 °C（門檻 61）待查散熱 |

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

處理：① 盤點 → ② LXC 停用 sensors 並刪除 → ③ 對照每個感測器是什麼元件 → ④ 依硬體規格設門檻 → ⑤ NAS 另外看散熱
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
| NAS | tokyo16、melayu17（`os = dsm`） | melayu17 系統 40 °C、硬碟 39 °C；tokyo16 硬碟 40～41 °C，**System 66 °C** |

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

**還原**：`zcat /root/sensors-before-lxcfix-20261019.sql.gz | mysql librenms`（在 CT 102 內），或在網頁點 `Use default`。

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

**還原**：`zcat /root/sensors-before-limits-20261019.sql.gz | mysql librenms`（在 CT 102 內）。

## 7. 步驟五：NAS tokyo16 的系統溫度（待查）

tokyo16 的 System 66 °C 超過門檻 61，24 小時觸發 56 次；同型用途的 melayu17 只有 40 °C，硬碟溫度兩台都正常（39～41 °C）。這是唯一可能是真的偏熱的項目，門檻先不動，先看散熱：

- DSM → 控制台 → 硬體與電源 → **風扇模式**：是否在「安靜模式」，可改「冷卻模式」
- NAS 周圍通風、機櫃或機房溫度、風扇有沒有積灰
- DSM → 資訊中心 看系統溫度是否和 LibreNMS 一致

## 8. 常見問題

| 現象 | 怎麼辦 |
| --- | --- |
| LXC 容器在 LibreNMS 有 CPU、NVMe 溫度 | 容器共用宿主機 kernel，讀到的是宿主機硬體；對容器停用 sensors 模組並刪除已存在的感測器（步驟二） |
| 門檻是 20 °C 之類明顯不合理的值 | 設備沒提供門檻時，LibreNMS 自動產生；依 `sensors` 括號裡的硬體門檻或元件規格重設，並標 `sensor_custom = Yes`（步驟四） |
| 只關了模組，舊感測器還在、還在報 | 關模組不會刪除已存在的資料；刪除 `sensors` 表裡那台的紀錄 |
| 不知道 `Sensor 2`、`temp1` 是什麼 | 在節點跑 `sensors`，看它在哪個晶片底下（`nvme-pci-…`、`mt7921_phy0`…）（步驟三） |
| `sensors` 顯示 `ALARM (HIGH)` | 是硬體模組自己的門檻（例如 DDR5 high 55）；對照 `crit` 判斷是否真的危險 |
| `acpitz-acpi-0:temp1` 一直是 0.0 | 這個 ACPI 感測器沒有讀數，可以不管 |

## 9. 待辦

- [ ] tokyo16：DSM 風扇模式、通風檢查；確認後再決定 System 門檻（目前 61）
- [ ] 觀察一天，確認 LibreNMS 事件紀錄不再出現 LXC 與 node10～12 的 `Temperature above threshold`
- [ ] 以後新增 LXC 到 LibreNMS 時，加入後就關掉 sensors 模組
- [ ] node12 的 2 TB NVMe（KINGSTON SNV3S）內部感測器 71.8 °C：觀察是否持續上升
- [ ] 約一週後刪除 CT 102 的 `/root/sensors-before-lxcfix-20261019.sql.gz`、`/root/sensors-before-limits-20261019.sql.gz`

## 10. 延伸閱讀

- [一次檢查並統一所有 LXC 的時區](https://kbwangtw.github.io/IT-Knowledge-Base/docs/pve/pve-lxc-timezone/)：這次是在修正 LibreNMS 舊事件紀錄時發現溫度事件的
- [用 Grafana 建立戰情中心（二）：接上 LibreNMS](https://kbwangtw.github.io/IT-Knowledge-Base/docs/pve/grafana-war-room-librenms/)
- [LibreNMS 官方文件：Health Information（Sensors）](https://docs.librenms.org/Support/Health-Information/)
- [lm-sensors](https://github.com/lm-sensors/lm-sensors)
