# check-unused-css

檢查 Jekyll 建置結果（`_site/`）裡，有沒有產生了 `.css` 卻沒有任何頁面載入。由 `.github/workflows/check-site.yml` 在每個 PR 與 `main` push 時自動執行。

會有這個檢查，是因為 #184 把 CSS 修正寫進 `assets/css/style.scss`，但 minima 主題的 `<head>` 只載入 `assets/main.css`（由 `assets/main.scss` 產生），修正完全沒生效，也沒有任何警告。

| 項目 | 說明 |
| --- | --- |
| 檢查範圍 | `_site/` 底下所有 `.css` |
| 算「有載入」 | 任何 `.html` 的 `<link href="…">`，或其他 `.css` 的 `@import` 指到它（絕對路徑、含 baseurl、相對路徑都算） |
| 結果 | 全部有載入 → exit 0；有孤立檔案 → 列出檔名、exit 1，CI 變紅 |
| 不檢查 | 頁面內嵌的 `<style>`、`.css` 裡個別規則有沒有用到 |

本機執行：

```bash
gem install jekyll minima kramdown-parser-gfm
```

```bash
ruby $(gem contents jekyll | grep 'exe/jekyll$') build --baseurl /IT-Knowledge-Base
```

```bash
ruby tools/check-unused-css/check.rb _site /IT-Knowledge-Base
```
