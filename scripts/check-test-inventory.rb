#!/usr/bin/env ruby
# frozen_string_literal: true

require "pathname"
require "json"
require "set"

repo_root = Pathname.new(__dir__).parent
project_file = repo_root.join("Holo/Holo APP/Holo/Holo.xcodeproj/project.pbxproj")
tests_path = repo_root.join("Holo/Holo APP/Holo/HoloTests")
standalone_manifest = JSON.parse(File.read(repo_root.join("scripts/standalone-tests.json")))
standalone_exclusions = standalone_manifest.fetch("exclude", {})

project = File.read(project_file)
sources_block = project[/6246BF929F91C28DF1408636 \/\* Sources \*\/ = \{.*?\n\t\t\};/m]
abort "无法定位 HoloTests Sources build phase" unless sources_block

source_names = sources_block.scan(/\/\* ([^*]+\.swift) in Sources \*\//).flatten.to_set
swift_files = Dir.glob(tests_path.join("**/*.swift")).sort

xctest_files = []
bridged_files = []
standalone_files = []
support_files = []
invalid_files = []

swift_files.each do |absolute_path|
  path = Pathname.new(absolute_path)
  content = File.read(path)
  relative = path.relative_path_from(repo_root).to_s
  name = path.basename.to_s
  is_xctest = content.include?("import XCTest") || content.include?("XCTestCase")
  is_bridged = content.include?("HOLO_XCTEST_BRIDGE")
  in_target = source_names.include?(name)
  is_excluded = standalone_exclusions.key?(relative)

  if is_xctest
    if is_excluded
      support_files << relative
      reason = standalone_exclusions[relative].to_s.strip
      invalid_files << "support exclusion 缺少原因：#{relative}" if reason.empty?
      invalid_files << "XCTest support 未加入 HoloTests Target：#{relative}" unless in_target
      next
    end
    if is_bridged
      bridged_files << relative
      invalid_files << "桥接测试未加入 HoloTests Target：#{relative}" unless in_target
      next
    end
    xctest_files << relative
    invalid_files << "XCTest 未加入 HoloTests Target：#{relative}" unless in_target
    next
  end

  standalone_files << relative unless is_excluded
  invalid_files << "非 XCTest 被加入 HoloTests Target：#{relative}" if in_target

  if is_excluded
    reason = standalone_exclusions[relative].to_s.strip
    invalid_files << "standalone exclusion 缺少原因：#{relative}" if reason.empty?
    next
  end

  next if content.include?("@main")
  next if content.match?(/^\s*(?:let|var|func|print|expect)\b/)

  invalid_files << "standalone 测试缺少可执行入口：#{relative}"
end

puts "Native XCTest：#{xctest_files.length}"
puts "Bridged standalone @main：#{bridged_files.length}"
puts "Standalone/脚本：#{standalone_files.length}"
puts "Support exclusion：#{support_files.length}"

standalone_exclusions.each_key do |relative|
  invalid_files << "standalone exclusion 文件不存在：#{relative}" unless repo_root.join(relative).file?
end

unless invalid_files.empty?
  warn invalid_files.join("\n")
  warn "运行 ruby scripts/sync-xctest-target.rb 修复 XCTest Target 清单。"
  exit 1
end

puts "测试清单检查通过"
