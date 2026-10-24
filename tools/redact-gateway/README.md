# redact-gateway

讓 Claude Code 在內網執行指令、但送上雲的輸出先去識別化的小閘道。說明與建置過程見
[用 Claude Code 取代 Hermes：去識別化閘道與手機遙控](https://kbwangtw.github.io/IT-Knowledge-Base/docs/pve/claude-code-redact-gateway/)。

| 檔案 | 用途 |
| --- | --- |
| `rx` | `rx <node10\|node11\|node12> '<指令>'`：指令裡的代稱換回真實值 → 擋高風險指令 → SSH 執行 → 輸出遮蔽後才印出；`rx --test < 檔案` 只測遮蔽 |
| `redact-map.example` | 對照表格式範例（真實的對照表放 `/root/.redact-map`，權限 600，**不要進版控**） |

安裝：放 `/usr/local/bin/rx`（755），由 root 執行；給跑 Claude Code 的一般帳號 `sudo` 只開放這一個程式。可連的主機寫在腳本開頭的 `HOSTS`。
