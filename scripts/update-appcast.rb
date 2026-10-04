#!/usr/bin/env ruby
# frozen_string_literal: true

# 维护 AppWindow 的 Sparkle appcast.xml（仅中文一种文案，不做多语言）。
#
# 预检（只校验 build 单调性，不写文件；CI 发版前 fail fast 用）：
#   ruby scripts/update-appcast.rb --check --version 0.8.0 --build 12
#
# 写入 item（同 build 已存在则整条替换，保证重跑幂等）：
#   ruby scripts/update-appcast.rb --version 0.8.0 --build 12 \
#     --minimum-system-version 14.0 --dmg-url https://… --ed-signature … \
#     --length 12345 --notes-file changelog.md [--appcast appcast.xml]
require "cgi"
require "optparse"
require "time"

FALLBACK_NOTE = "本次无用户可见变更"
ITEM_INDENT = "    "

def fail!(message)
  warn "错误：#{message}"
  exit 1
end

def xml_escape(value)
  CGI.escapeHTML(value.to_s)
end

# 防御性转义：描述先经 xml_escape，`]]>` 实际不会出现，保留以防未来绕过转义
def cdata_escape(html)
  html.gsub("]]>", "]]]]><![CDATA[>")
end

# notes 逐行转 <li>：`- ` 前缀可选，非空行都算一条；一条都没有时回退固定说明
def notes_items(lines)
  items = lines.map(&:strip).reject(&:empty?).map do |line|
    "<li>#{xml_escape(line.sub(/\A-\s+/, ''))}</li>"
  end
  items.empty? ? ["<li>#{FALLBACK_NOTE}</li>"] : items
end

def load_notes_items(path)
  return ["<li>#{FALLBACK_NOTE}</li>"] unless path && File.file?(path)

  notes_items(File.readlines(path, chomp: true))
end

def build_item(version:, build:, minimum:, dmg_url:, signature:, length:, description:)
  fields = [
    "<title>#{xml_escape("#{version}（构建 #{build}）")}</title>",
    "<pubDate>#{Time.now.utc.strftime('%a, %d %b %Y %H:%M:%S +0000')}</pubDate>",
    "<sparkle:version>#{xml_escape(build)}</sparkle:version>",
    "<sparkle:shortVersionString>#{xml_escape(version)}</sparkle:shortVersionString>",
    "<sparkle:minimumSystemVersion>#{xml_escape(minimum)}</sparkle:minimumSystemVersion>",
    "<description><![CDATA[#{cdata_escape(description)}]]></description>",
    %(<enclosure url="#{xml_escape(dmg_url)}"),
    %(           type="application/octet-stream"),
    %(           sparkle:edSignature="#{xml_escape(signature)}"),
    %(           length="#{xml_escape(length)}" />)
  ]
  ["#{ITEM_INDENT}<item>", *fields.map { |field| "#{ITEM_INDENT}  #{field}" }, "#{ITEM_INDENT}</item>"].join("\n")
end

# 已存在的同 build item（含缩进），没有则返回 nil
def find_item(appcast, build)
  appcast.scan(%r{[ \t]*<item>.*?</item>}m).find do |block|
    block.match?(%r{<sparkle:version>\s*#{Regexp.escape(build.to_s)}\s*</sparkle:version>})
  end
end

def item_short_version(item)
  item[%r{<sparkle:shortVersionString>\s*(.*?)\s*</sparkle:shortVersionString>}m, 1]
end

# appcast 里已有的最大 build；没有任何 item 时返回 nil
def max_existing_build(appcast)
  appcast.scan(%r{<sparkle:version>\s*(\d+)\s*</sparkle:version>}).flatten.map(&:to_i).max
end

# 新 item 插到第一个 <item> 之前；没有 item 则插到 </channel> 之前
def insert_item(appcast, item)
  first_item = appcast.match(/^[ \t]*<item\b/m)
  return appcast.dup.insert(first_item.begin(0), "#{item}\n") if first_item

  channel_end = appcast.rindex("</channel>")
  fail!("appcast 中找不到 </channel>") unless channel_end

  closing_indent = appcast[0...channel_end][/[ \t]*\z/]
  updated = appcast.dup
  updated[channel_end - closing_indent.length, closing_indent.length] = "#{item}\n#{closing_indent}"
  updated
end

def parse_options
  options = {}
  OptionParser.new do |parser|
    parser.banner = "用法: ruby scripts/update-appcast.rb --version V --build N [--check] [选项]"
    parser.on("--version V") { |value| options[:version] = value }
    parser.on("--build N") { |value| options[:build] = value }
    parser.on("--minimum-system-version V") { |value| options[:minimum] = value }
    parser.on("--dmg-url URL") { |value| options[:dmg_url] = value }
    parser.on("--ed-signature SIG") { |value| options[:signature] = value }
    parser.on("--length N") { |value| options[:length] = value }
    parser.on("--notes-file PATH") { |value| options[:notes_file] = value }
    parser.on("--appcast PATH") { |value| options[:appcast] = value }
    parser.on("--check") { options[:check] = true }
  end.parse!

  options[:appcast] ||= File.expand_path("../appcast.xml", __dir__)
  fail!("--version 不能为空") if options[:version].to_s.empty?
  fail!("--build 必须是纯数字") unless options[:build].to_s.match?(/\A\d+\z/)
  fail!("appcast 文件不存在：#{options[:appcast]}") unless File.file?(options[:appcast])

  unless options[:check]
    fail!("--minimum-system-version 不能为空") if options[:minimum].to_s.empty?
    fail!("--dmg-url 必须使用 https") unless options[:dmg_url].to_s.start_with?("https://")
    fail!("--ed-signature 不能为空") if options[:signature].to_s.empty?
    fail!("--length 必须是纯数字") unless options[:length].to_s.match?(/\A\d+\z/)
  end

  options
end

def check_monotonicity(appcast, version, build)
  max = max_existing_build(appcast)
  if max.nil? || build > max
    puts "单调性检查通过：build #{build}（appcast 当前最大：#{max || '无'}）"
    return
  end

  if build == max
    item = find_item(appcast, build)
    stored = item && item_short_version(item)
    if stored == version
      puts "单调性检查通过：build #{build} 已存在且版本一致（幂等重跑）"
      return
    end
    fail!("build #{build} 已存在但版本是 #{stored.inspect}，与本次 #{version} 不一致")
  end

  fail!("build #{build} 不大于 appcast 当前最大 build #{max}；build 号必须严格递增")
end

def write_item(appcast, options)
  build = options[:build].to_i
  items = load_notes_items(options[:notes_file])
  item = build_item(
    version: options[:version],
    build: build,
    minimum: options[:minimum],
    dmg_url: options[:dmg_url],
    signature: options[:signature],
    length: options[:length],
    description: "<ul>#{items.join}</ul>"
  )

  existing = find_item(appcast, build)
  # 块形式替换，避免替换文本里的反斜杠被当成反向引用
  updated = existing ? appcast.sub(existing) { item } : insert_item(appcast, item)
  [updated, existing ? "替换" : "新增", items.length]
end

options = parse_options
appcast = File.read(options[:appcast])

# 写入前同样校验单调性：CI 靠“先 check 后 write”，手工调用也不该能写回退的 build
check_monotonicity(appcast, options[:version], options[:build].to_i)

if options[:check]
  # check 模式在 check_monotonicity 里已输出结果
else
  updated, action, notes_count = write_item(appcast, options)
  File.write(options[:appcast], updated)
  puts "已#{action} build #{options[:build]}（#{options[:version]}），notes #{notes_count} 条 → #{options[:appcast]}"
end
