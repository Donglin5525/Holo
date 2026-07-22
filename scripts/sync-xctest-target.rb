#!/usr/bin/env ruby
# frozen_string_literal: true

require "pathname"
require "xcodeproj"

repo_root = Pathname.new(__dir__).parent
project_path = repo_root.join("Holo/Holo APP/Holo/Holo.xcodeproj")
tests_path = repo_root.join("Holo/Holo APP/Holo/HoloTests")

project = Xcodeproj::Project.open(project_path.to_s)
target = project.targets.find { |candidate| candidate.name == "HoloTests" }
abort "找不到 HoloTests target" unless target

tests_group = project.main_group.children.find { |child| child.display_name == "HoloTests" }
abort "找不到 HoloTests group" unless tests_group

xctest_files = Dir.glob(tests_path.join("**/*.swift")).select do |path|
  content = File.read(path)
  content.include?("import XCTest") || content.include?("XCTestCase")
end.sort

added_references = []
added_sources = []

xctest_files.each do |absolute_path|
  path = Pathname.new(absolute_path)
  relative = path.relative_path_from(tests_path)
  group_path = relative.dirname.to_s
  group = if group_path == "."
            tests_group
          else
            group_path.split("/").reduce(tests_group) do |parent, component|
              child = parent.children.find do |candidate|
                candidate.isa == "PBXGroup" && candidate.display_name == component
              end
              child ||= parent.new_group(component, component)
              if child.path.nil?
                child.path = component
                child.name = nil
              end
              child
            end
          end

  reference = project.files.find do |candidate|
    candidate.real_path.cleanpath == path.cleanpath
  end
  unless reference
    reference = group.new_file(relative.basename.to_s)
    added_references << relative.to_s
  end

  next if target.source_build_phase.files_references.include?(reference)

  target.source_build_phase.add_file_reference(reference, true)
  added_sources << relative.to_s
end

project.save

puts "XCTest 文件：#{xctest_files.length}"
puts "新增文件引用：#{added_references.length}"
puts "新增 Target Sources：#{added_sources.length}"
added_sources.each { |path| puts "  + #{path}" }
