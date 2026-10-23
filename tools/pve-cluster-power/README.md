# pve-cluster-power

整個 PVE 叢集（三節點、Ceph、HA）安全關機與開機的兩支腳本。說明與實際使用紀錄見
[整個 PVE 叢集安全關機與開機](https://kbwangtw.github.io/IT-Knowledge-Base/docs/pve/pve-cluster-full-shutdown/)。

| 檔案 | 用途 |
| --- | --- |
| `cluster-shutdown.sh` | `--dry-run` 只檢查；正式執行要輸入 `SHUTDOWN`。停 HA 服務 → 關非 HA 的 VM／CT → Ceph 旗標 → 停 HA 監看 → 關另外兩台，最後關自己 |
| `cluster-startup.sh` | 三台開機後在任一台執行：等 quorum → 解除 Ceph 旗標 → 等 HEALTH_OK → 啟動關機前在跑的服務 |

節點名稱寫在腳本開頭的 `NODES`（node10 node11 node12），其他環境要先修改。放在 `/usr/local/sbin/`，三台都放一份。
