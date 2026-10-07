#!/usr/bin/env ruby
# frozen_string_literal: true

require "pathname"
require "set"

repo_root = Pathname.new(__dir__).parent
tests_root = repo_root.join("Holo/Holo APP/Holo/HoloTests")
output_path = tests_root.join("Support/StandaloneExecutableBridgeTests.swift")

# 只桥接真正挂在 HoloTests target 里的文件：pbxproj 不含的 @main 套件是
# 「仅 swiftc 脚本运行」形态，桥进去会让 XCTest 构建找不到符号。
pbxproj = File.read(repo_root.join("Holo/Holo APP/Holo/Holo.xcodeproj/project.pbxproj"))

# 已提交但从未进桥的文件（历史上仅脚本运行形态）不自动收编——桥接须由作者显式登记
#（在 scripts/xctest-bridge-allowlist.txt 加一行文件名），避免把 WIP 套件带进共享测试门。
existing_bridge = if output_path.exist?
                   File.read(output_path)[/final class StandaloneExecutableBridgeTests.*\z/m].to_s
                 else
                   ""
                 end
tracked = `git -C "#{repo_root}" ls-files "Holo/Holo APP/Holo/HoloTests"`.split("\n").to_set
allowlist_path = repo_root.join("scripts/xctest-bridge-allowlist.txt")
allowlist = allowlist_path.exist? ? File.read(allowlist_path).lines.map(&:strip).reject(&:empty?) : []

entries = []
Dir.glob(tests_root.join("**/*.swift")).sort.each do |absolute_path|
  path = Pathname.new(absolute_path)
  next if path == output_path

  content = File.read(path)
  next unless content.include?("@main")
  next if content.include?("import XCTest") && !content.include?("HOLO_XCTEST_BRIDGE")

  unless pbxproj.include?("path = #{path.basename}")
    warn "⚠️ 跳过未挂载进 HoloTests target 的 @main 文件（仅脚本运行形态）：#{path}"
    next
  end

  relative = path.relative_path_from(repo_root).to_s
  already_bridged = existing_bridge.include?(path.basename.to_s)
  is_tracked = tracked.include?(relative)
  unless already_bridged || !is_tracked || allowlist.include?(path.basename.to_s)
    warn "⚠️ 跳过已提交但从未进桥的 @main 文件（历史脚本运行形态，登记请加 allowlist）：#{path}"
    next
  end

  # 两种合法启动器形态通吃：
  #   A 头部：#if HOLO_XCTEST_BRIDGE ... #else @main ... HoloStandaloneLauncher { ... SuiteName.main() } #endif
  #   B 尾部：#if !HOLO_XCTEST_BRIDGE @main ... HoloStandaloneLauncher { ... SuiteName.main() } #endif
  # 统一从启动器体内的「套件名.main()」提取类型，与启动器所在位置无关。
  type_name = content[/HoloStandaloneLauncher\b.*?([A-Za-z_][A-Za-z0-9_]*)\.main\(\)/m, 1]
  type_name ||= if content.include?("HOLO_XCTEST_BRIDGE")
                  content[/#endif\n(?:(?:private|fileprivate|internal)\s+)?(?:struct|enum|class|actor)\s+([A-Za-z_][A-Za-z0-9_]*)/, 1]
                else
                  content[/@main\s*\n(?:(?:private|fileprivate|internal)\s+)?(?:struct|enum|class|actor)\s+([A-Za-z_][A-Za-z0-9_]*)/, 1]
                end
  type_body = type_name && content.split(/(?:struct|enum|class|actor)\s+#{Regexp.escape(type_name)}\b/, 2).last
  signature = type_body&.lines&.find { |line| line.match?(/\bstatic func main\s*\(/) }
  # 无法识别的 @main 文件跳过并显式告警，不阻断其余套件再生
  # （在途文件可能使用非头部启动器形态；被跳过者不会进 XCTest 桥，作者会看到警告）
  unless type_name && signature
    warn "⚠️ 跳过无法识别的 @main 文件（未桥接）：#{path}"
    next
  end

  invocation = []
  invocation << "try" if signature.include?("throws")
  invocation << "await" if signature.include?("async")
  invocation << "#{type_name}.main()"
  bridge = <<~SWIFT.chomp
    #if HOLO_XCTEST_BRIDGE
    import XCTest
    @testable import Holo
    #else
    @main
    private struct HoloStandaloneLauncher {
        static func main() async throws {
            #{invocation.join(" ")}
        }
    }
    #endif
  SWIFT
  if content.include?("HOLO_XCTEST_BRIDGE")
    content = content.sub(/#if HOLO_XCTEST_BRIDGE\nimport XCTest\n@testable import Holo\n#else\n@main\n#endif/, bridge)
  else
    content = content.sub(/^@main\s*$/, bridge)
  end
  content = content.sub(
    /(#endif\n)(?:private|fileprivate)\s+((?:struct|enum|class|actor)\s+#{Regexp.escape(type_name)}\b)/,
    "\\1\\2"
  )
  File.write(path, content)

  entries << {
    type: type_name,
    async: signature.include?("async"),
    throws: signature.include?("throws"),
    label: path.relative_path_from(tests_root).to_s
  }
end

methods = entries.each_with_index.map do |entry, index|
  invocation = []
  invocation << "try" if entry[:throws]
  invocation << "await" if entry[:async]
  invocation << "#{entry[:type]}.main()"
  <<~SWIFT
        func test_#{format("%03d", index + 1)}_#{entry[:type]}() async throws {
            // 来源：#{entry[:label]}
            #{invocation.join(" ")}
        }
  SWIFT
end.join("\n")

generated = <<~SWIFT
  // 此文件由 scripts/generate-standalone-xctest-bridge.rb 生成，请勿手改。
  import XCTest
  @testable import Holo

  final class StandaloneExecutableBridgeTests: XCTestCase {
  #{methods.rstrip}
  }
SWIFT

File.write(output_path, generated)
puts "已桥接 #{entries.length} 个 standalone @main 测试"
