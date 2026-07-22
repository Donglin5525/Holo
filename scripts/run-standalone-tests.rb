#!/usr/bin/env ruby
# frozen_string_literal: true

require "fileutils"
require "json"
require "open3"
require "pathname"
require "shellwords"
require "tmpdir"
require "timeout"

repo_root = Pathname.new(__dir__).parent
manifest_path = repo_root.join("scripts/standalone-tests.json")
manifest = JSON.parse(File.read(manifest_path))
test_root = repo_root.join("Holo/Holo APP/Holo/HoloTests")
production_root = repo_root.join("Holo/Holo APP/Holo/Holo")
exclusions = manifest.fetch("exclude", {})

def relative(path, root)
  Pathname.new(path).relative_path_from(root).to_s
end

def declarations(content)
  content.scan(/\b(?:struct|class|enum|protocol|actor|typealias|extension)\s+([A-Za-z_][A-Za-z0-9_]*)/).flatten
end

def missing_symbols(output)
  patterns = [
    /cannot find (?:type )?'([^']+)' in scope/,
    /cannot find '([^']+)' in scope/,
    /cannot find operator '([^']+)' in scope/
  ]
  patterns.flat_map { |pattern| output.scan(pattern).flatten }.uniq
end

def documented_sources(content, repo_root, test_root)
  content.lines.first(40).map do |line|
    line.scan(/["']([^"']+\.swift)["']/).flatten.map do |candidate|
      paths = [repo_root.join(candidate), test_root.parent.join(candidate)]
      paths.find(&:file?)
    end.compact
  end.flatten.uniq
end

def capture_with_timeout(command, seconds: 60)
  stdout = String.new
  stderr = String.new
  status = nil
  Open3.popen3(*command) do |stdin, out, err, wait_thread|
    stdin.close
    out_reader = Thread.new { out.read }
    err_reader = Thread.new { err.read }
    begin
      Timeout.timeout(seconds) { status = wait_thread.value }
    rescue Timeout::Error
      Process.kill("TERM", wait_thread.pid)
      sleep 0.2
      Process.kill("KILL", wait_thread.pid) if wait_thread.alive?
      status = wait_thread.value
      stderr << "\n命令超过 #{seconds}s，已终止"
    ensure
      stdout << out_reader.value
      stderr << err_reader.value
    end
  end
  [stdout, stderr, status]
end

def expand_dependencies(paths, declaration_index)
  expanded = paths.dup
  2.times do
    identifiers = expanded.flat_map do |path|
      File.read(path).scan(/\b[A-Z][A-Za-z0-9_]+\b/)
    end.uniq
    additions = identifiers.flat_map do |identifier|
      candidates = declaration_index[identifier].uniq - expanded
      candidates.length == 1 ? candidates : []
    end.uniq
    break if additions.empty?
    expanded.concat(additions)
    expanded.uniq!
  end
  expanded
end

production_files = Dir.glob(production_root.join("**/*.swift")).sort.map { |path| Pathname.new(path) }
declaration_index = Hash.new { |hash, key| hash[key] = [] }
production_files.each do |path|
  next if path.to_s.include?("/Views/")
  declarations(File.read(path)).each { |name| declaration_index[name] << path }
end

all_swift_files = manifest.fetch("roots").flat_map do |root|
  Dir.glob(repo_root.join(root, "**/*.swift"))
end.sort.map { |path| Pathname.new(path) }

unknown_exclusions = exclusions.keys.reject { |path| repo_root.join(path).file? }
abort "manifest exclusion 指向不存在文件：\n#{unknown_exclusions.join("\n")}" unless unknown_exclusions.empty?

standalone_files = all_swift_files.reject do |path|
  content = File.read(path)
  content.include?("import XCTest") || content.include?("XCTestCase") ||
    content.include?("HOLO_XCTEST_BRIDGE") || exclusions.key?(relative(path, repo_root))
end
if ENV["TEST_FILTER"] && !ENV["TEST_FILTER"].empty?
  standalone_files.select! { |path| relative(path, test_root).include?(ENV["TEST_FILTER"]) }
  abort "TEST_FILTER 未匹配任何 standalone 测试" if standalone_files.empty?
end

failures = []
passed = 0
started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)

Dir.mktmpdir("holo-standalone-") do |temp_dir|
  module_cache = File.join(temp_dir, "module-cache")
  FileUtils.mkdir_p(module_cache)

  standalone_files.each_with_index do |test_path, index|
    content = File.read(test_path)
    label = relative(test_path, test_root)
    puts "[#{index + 1}/#{standalone_files.length}] #{label}"

    unless content.include?("@main")
      stdout, stderr, status = Open3.capture3(
        "swift", "-module-cache-path", module_cache, test_path.to_s, repo_root.to_s
      )
      if status.success?
        passed += 1
      else
        failures << [label, stdout + stderr]
      end
      next
    end

    stem = test_path.basename(".swift").to_s.sub(/StandaloneTests$/, "").sub(/Tests$/, "")
    sources = production_files.select { |path| path.basename(".swift").to_s == stem }
    sources.concat(documented_sources(content, repo_root, test_root))
    sources.uniq!
    sources = expand_dependencies(sources + [test_path], declaration_index) - [test_path]
    executable = File.join(temp_dir, "test-#{index}")
    last_output = ""
    completed = false

    12.times do |attempt|
      puts "  编译依赖 #{sources.length} 个（第 #{attempt + 1} 次）" if ENV["VERBOSE"] == "1"
      command = [
        "swiftc",
        "-module-cache-path", module_cache,
        "-parse-as-library",
        *sources.map(&:to_s),
        test_path.to_s,
        "-o", executable
      ]
      stdout, stderr, status = capture_with_timeout(command)
      last_output = stdout + stderr
      if status.success?
        run_stdout, run_stderr, run_status = Open3.capture3(executable)
        last_output = run_stdout + run_stderr
        if run_status.success?
          passed += 1
        else
          failures << [label, "运行失败：\n#{last_output}"]
        end
        completed = true
        break
      end

      additions = missing_symbols(last_output).flat_map { |symbol| declaration_index[symbol] }.uniq - sources
      if additions.empty?
        failures << [label, "编译依赖无法解析：\n#{last_output}"]
        completed = true
        break
      end
      sources = expand_dependencies(sources + additions, declaration_index)
    end
    failures << [label, "编译依赖解析超过 12 轮：\n#{last_output}"] unless completed
  end
end

elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at
puts "standalone：#{passed}/#{standalone_files.length} 通过（#{format("%.1f", elapsed)}s）"

if !failures.empty? || passed != standalone_files.length
  warn "\n失败 #{failures.length} 项："
  failures.each do |label, output|
    warn "\n=== #{label} ==="
    warn output.lines.last(80).join
  end
  exit 1
end

puts "standalone 测试全部通过"
