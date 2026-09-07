#!/usr/bin/env ruby
# frozen_string_literal: true

require "pathname"

repo_root = Pathname.new(__dir__).parent
tests_root = repo_root.join("Holo/Holo APP/Holo/HoloTests")
output_path = tests_root.join("Support/StandaloneExecutableBridgeTests.swift")

entries = []
Dir.glob(tests_root.join("**/*.swift")).sort.each do |absolute_path|
  path = Pathname.new(absolute_path)
  next if path == output_path

  content = File.read(path)
  next unless content.include?("@main")
  next if content.include?("import XCTest") && !content.include?("HOLO_XCTEST_BRIDGE")

  type_name = if content.include?("HOLO_XCTEST_BRIDGE")
                content[/#endif\n(?:(?:private|fileprivate|internal)\s+)?(?:struct|enum|class|actor)\s+([A-Za-z_][A-Za-z0-9_]*)/, 1]
              else
                content[/@main\s*\n(?:(?:private|fileprivate|internal)\s+)?(?:struct|enum|class|actor)\s+([A-Za-z_][A-Za-z0-9_]*)/, 1]
              end
  type_body = type_name && content.split(/(?:struct|enum|class|actor)\s+#{Regexp.escape(type_name)}\b/, 2).last
  signature = type_body&.lines&.find { |line| line.match?(/\bstatic func main\s*\(/) }
  abort "无法识别 bridge 类型或 main：#{path}" unless type_name && signature

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
