#!/usr/bin/env ruby
# 檢查 Jekyll 建置結果裡，有沒有「產生了卻沒有任何頁面載入」的 .css。
# 用法：ruby tools/check-unused-css/check.rb <_site 目錄> <baseurl>
#   例：ruby tools/check-unused-css/check.rb _site /IT-Knowledge-Base
# 全部都有被引用 → exit 0；有孤立的 .css → 列出檔名並 exit 1。

require "pathname"

site = Pathname.new(ARGV.fetch(0, "_site")).expand_path
baseurl = ARGV.fetch(1, "").chomp("/")
abort "找不到建置目錄：#{site}（先執行 jekyll build）" unless site.directory?

# 把頁面裡的網址換成 _site 底下的實際檔案路徑；外部網址回傳 nil。
def resolve(url, from_dir, site, baseurl)
  url = url.split(/[?#]/, 2).first.to_s
  return nil if url.empty? || url.match?(%r{\A([a-z][a-z0-9+.-]*:|//)}i)

  if url.start_with?("/")
    url = url.delete_prefix(baseurl) if !baseurl.empty? && url.start_with?("#{baseurl}/")
    (site + url.delete_prefix("/")).cleanpath
  else
    (from_dir + url).cleanpath
  end
end

css_files = Dir.glob(site.join("**", "*.css").to_s).map { |f| Pathname.new(f).cleanpath }
referenced = []

# HTML：<link ... href="…css">
Dir.glob(site.join("**", "*.html").to_s).each do |html|
  dir = Pathname.new(html).dirname
  File.read(html, encoding: "UTF-8").scan(/<link\b[^>]*>/i) do |tag|
    href = tag[/\bhref\s*=\s*["']([^"']+)["']/i, 1]
    path = href && resolve(href, dir, site, baseurl)
    referenced << path if path
  end
end

# CSS：@import "…" 或 @import url(…)
css_files.each do |css|
  File.read(css, encoding: "UTF-8").scan(/@import\s+(?:url\()?\s*["']?([^"')\s;]+)/i) do |(href)|
    path = resolve(href, css.dirname, site, baseurl)
    referenced << path if path
  end
end

unused = css_files - referenced
if unused.empty?
  puts "OK：#{css_files.size} 個 .css 都有頁面載入。"
  exit 0
end

puts "以下 .css 有被建置出來，但沒有任何頁面或 CSS 載入（樣式不會生效）："
unused.sort.each { |p| puts "  - #{p.relative_path_from(site)}" }
puts "全站樣式請寫在 assets/main.scss（minima 只載入 assets/main.css）；不用的檔案請刪除。"
exit 1
