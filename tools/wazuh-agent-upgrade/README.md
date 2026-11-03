# wazuh-agent-upgrade

在 **Wazuh Manager 主機**上，用 Wazuh 內建的 `agent_upgrade`，依序升級指定的 Agent。一次一台，失敗就停。

不需要任何主機的 SSH 或密碼；腳本只在 Manager 本機執行，並寫一份記錄到 `~/wazuh-agent-upgrade-YYYYMMDD.log`（不含任何憑證）。

## 用法

```bash
# 預演：只列出會做什麼，不升級
./wazuh-upgrade-agents.sh 013 006

# 實際執行（一次一台，升完驗證才做下一台）
./wazuh-upgrade-agents.sh --run 013 006
```

## 保護機制

| 保護 | 說明 |
| --- | --- |
| 一次一台 | 升完確認「版本為目標版本且 Active」才做下一台，兩台之間間隔 `PAUSE` 秒 |
| 失敗就停 | 任何一台失敗、逾時、查不到版本，整批停止，後面的不會被動到 |
| 升級前檢查 | 該 Agent 必須是 Active、版本等於 `FROM_VERSION` |
| Manager 版本 | Manager 必須已是目標版本（Agent 版本不能高於 Manager） |
| Windows 略過 | 作業系統為 Windows 的一律略過，要先清除待重開機項目，手動處理 |
| `HARD_SKIP` | 清單內的 ID 一律不處理（預設 `014 015 016`：網域控制站與未確認系統的主機） |
| `CONFIRM_IDS` | 清單內的 ID 每台要人工輸入 `y`（預設 DNS、PVE 節點、備份伺服器） |

## 環境變數

`TARGET_VERSION`（預設 `v4.14.9`）、`FROM_VERSION`（`v4.14.8`）、`PACKAGE_TYPE`（`deb`）、`TIMEOUT`（300 秒）、`INTERVAL`（10 秒）、`PAUSE`（60 秒）、`HARD_SKIP`、`CONFIRM_IDS`、`LOG_FILE`。

## 測試狀態

邏輯先用模擬的 `agent_control` 與 `agent_upgrade` 測過（預演、成功、非 Active、版本不符、逾時、Windows 略過、人工確認、前一台失敗時不動後面的），再在真實的 Wazuh 環境先對一台 Linux Agent 試跑，成功後放開。

2026-11-02～03 實際用於 Wazuh 4.14.8 → 4.14.9：ai、AdGuard、Pihole、pbs31、三個 PVE 節點，每台約 1～1.5 分鐘，全部成功；Windows 主機（ca、DC02、DC01）由人工用 MSI 升級，不經過這支腳本。完整過程見 `docs/pve/wazuh-4-14-9-upgrade-sop.md` 第 8.7 節。
