#!/usr/bin/env ruby
# frozen_string_literal: true

# 维护 AppWindow 的 Sparkle appcast.xml（仅中文一种文案，不做多语言）。
#
# 预检（校验 build 单调性与通道防呆，不写文件；CI 发版前 fail fast 用）：
#   ruby scripts/update-appcast.rb --check --version 0.8.0 --build 12
#   ruby scripts/update-appcast.rb --check --version 0.9.0-beta.1 --build 13 --channel beta
#
# 写入 item（同 build 已存在则整条替换，保证重跑幂等）：
#   ruby scripts/update-appcast.rb --version 0.8.0 --build 12 \
#     --minimum-system-version 14.0 --dmg-url https://… --ed-signature … \
#     --length 12345 --notes-file changelog.md [--appcast appcast.xml]
#
# beta 预发布（tag 形如 v0.9.0-beta.1；版本号含 -beta 与 --channel beta 必须成对出现）：
#   ruby scripts/update-appcast.rb --version 0.9.0-beta.1 --build 13 --channel beta \
#     --minimum-system-version 14.0 --dmg-url https://… --ed-signature … --length 12345
require "cgi"
require "optparse"
require "time"

FALLBACK_NOTE = "本次无用户可见变更"
ITEM_INDENT = "    "
# Sparkle 的 channel 是自由字符串，白名单避免通道名手滑写错；扩通道时在这里加并补对应防呆
CHANNEL_WHITELIST = ["beta"].freeze

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

def build_item(version:, build:, minimum:, dmg_url:, signature:, length:, description:, channel: nil)
  fields = [
    "<title>#{xml_escape("#{version}（构建 #{build}）")}</title>",
    "<pubDate>#{Time.now.utc.strftime('%a, %d %b %Y %H:%M:%S +0000')}</pubDate>",
    "<sparkle:version>#{xml_escape(build)}</sparkle:version>",
    "<sparkle:shortVersionString>#{xml_escape(version)}</sparkle:shortVersionString>",
    "<sparkle:minimumSystemVersion>#{xml_escape(minimum)}</sparkle:minimumSystemVersion>",
    # 只有 beta 条目带 channel；无标签条目对全量用户可见（Sparkle 语义）
    channel ? "<sparkle:channel>#{xml_escape(channel)}</sparkle:channel>" : nil,
    "<description><![CDATA[#{cdata_escape(description)}]]></description>",
    %(<enclosure url="#{xml_escape(dmg_url)}"),
    %(           type="application/octet-stream"),
    %(           sparkle:edSignature="#{xml_escape(signature)}"),
    %(           length="#{xml_escape(length)}" />)
  ].compact
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

def item_channel(item)
  item[%r{<sparkle:channel>\s*(.*?)\s*</sparkle:channel>}m, 1]
end

# appcast 里已有的最大 build；没有任何 item 时返回 nil
def max_existing_build(appcast)
  appcast.scan(%r{<sparkle:version>\s*(\d+)\s*</sparkle:version>}).flatten.map(&:to_i).max
end

# 版本基准：去掉 -beta 预发布后缀（0.9.0-beta.1 → 0.9.0）
def base_version(version)
  version.to_s.sub(/-beta.*\z/, "")
end

# 版本基准 → 三段数字数组；解析失败直接报错，宁可拦住也不做失真的比较
def version_segments!(version)
  segments = version.split(".")
  valid = segments.length == 3 && segments.all? { |segment| segment.match?(/\A\d+\z/) }
  fail!("无法解析版本号 #{version.inspect}：版本比较只支持 x.y.z 三段数字形式") unless valid

  segments.map(&:to_i)
end

# 每个 item 的（channel, version）；channel 为 nil 表示默认通道（对全量用户可见）
def channel_entries(appcast)
  appcast.scan(%r{[ \t]*<item>.*?</item>}m).map do |block|
    { channel: item_channel(block), version: item_short_version(block) }
  end
end

# 条目集合的最大版本基准（三段数字数组）；空集合返回 nil
def max_base_version(entries)
  entries.map { |entry| version_segments!(base_version(entry[:version])) }.max
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
    parser.on("--channel NAME") { |value| options[:channel] = value }
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

  # channel 对 --check 同样校验：CI 的 check 步骤要能提前拦住标错的通道
  if options[:channel]
    fail!("--channel 只允许字母、数字与 . _ -，收到 #{options[:channel].inspect}") unless options[:channel].match?(/\A[a-zA-Z0-9._-]+\z/)
    fail!("--channel 暂只支持 #{CHANNEL_WHITELIST.join('/')}，收到 #{options[:channel].inspect}") unless CHANNEL_WHITELIST.include?(options[:channel])
  end

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

# beta/稳定版防呆校验（--check 与写入路径共用；写入时紧随 check_monotonicity 执行）：
# 发布由 tag 触发，通道标错会让 beta 包推给全量用户、或让 beta 线被已发布稳定版挡住收不到更新
def check_channel_rules(appcast, version, channel)
  beta_channel = channel == "beta"
  beta_version = version.include?("-beta")

  if beta_version && !beta_channel
    fail!("版本 #{version} 含 -beta 但未传 --channel beta；beta 包必须显式标记通道，否则会推送给全量用户")
  end
  if !beta_version && beta_channel
    fail!("版本 #{version} 不含 -beta 却传了 --channel beta；稳定版不能标记为 beta 通道")
  end

  entries = channel_entries(appcast)

  if beta_channel
    base = base_version(version)
    base_segments = version_segments!(base)
    max_stable = max_base_version(entries.reject { |entry| entry[:channel] })
    if max_stable && (base_segments <=> max_stable) <= 0
      fail!("beta 基准 #{base} 未严格大于默认通道最大版本 #{max_stable.join('.')}；beta 必须基于高于已发布稳定版的版本号")
    end
    puts "通道检查通过：beta #{version}（基准 #{base}；默认通道最大版本：#{max_stable ? max_stable.join('.') : '无'}）"
  else
    max_beta = max_base_version(entries.select { |entry| entry[:channel] == "beta" })
    if max_beta && (version_segments!(version) <=> max_beta) < 0
      fail!("稳定版 #{version} 小于 beta 条目基准 #{max_beta.join('.')}；beta 线转正需不低于该基准（相等即放行）")
    end
    puts "通道检查通过：稳定版 #{version}（beta 最大基准：#{max_beta ? max_beta.join('.') : '无'}）"
  end
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
    description: "<ul>#{items.join}</ul>",
    channel: options[:channel]
  )

  existing = find_item(appcast, build)
  # 块形式替换，避免替换文本里的反斜杠被当成反向引用
  updated = existing ? appcast.sub(existing) { item } : insert_item(appcast, item)
  [updated, existing ? "替换" : "新增", items.length]
end

options = parse_options
appcast = File.read(options[:appcast])

# 写入前同样校验单调性与通道：CI 靠“先 check 后 write”，手工调用也不该能写回退的 build / 标错的通道
check_monotonicity(appcast, options[:version], options[:build].to_i)
check_channel_rules(appcast, options[:version], options[:channel])

if options[:check]
  # check 模式：结果已由上面两个校验函数输出
else
  updated, action, notes_count = write_item(appcast, options)
  File.write(options[:appcast], updated)
  puts "已#{action} build #{options[:build]}（#{options[:version]}），notes #{notes_count} 条 → #{options[:appcast]}"
end
