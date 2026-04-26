#!/usr/bin/env ruby
# add_phase5_files.rb
# B.3.a Phase 5 — Add Driver/, Bootstrap/, BackgroundTasks/ source files
# to the WatchApp Extension target, plus the Phase 5 test file to the
# WatchApp ExtensionTests target.

require 'xcodeproj'

PROJECT_PATH = File.expand_path('../Loop.xcodeproj', __dir__)
WATCH_TARGET = 'WatchApp Extension'
TEST_TARGET  = 'WatchApp ExtensionTests'

# (group_path, file_path_relative_to_project_root)
SOURCE_FILES = [
  ['WatchApp Extension/Driver',          'WatchApp Extension/Driver/WatchAlgorithmDriver.swift'],
  ['WatchApp Extension/Bootstrap',       'WatchApp Extension/Bootstrap/WatchAlgorithmBootstrap.swift'],
  ['WatchApp Extension/Bootstrap',       'WatchApp Extension/Bootstrap/WatchRemoteCommandBootstrap.swift'],
  ['WatchApp Extension/BackgroundTasks', 'WatchApp Extension/BackgroundTasks/BackgroundPollScheduler.swift'],
]

TEST_FILES = [
  ['WatchApp ExtensionTests', 'WatchApp ExtensionTests/Phase5_BootstrapsTest.swift'],
]

proj = Xcodeproj::Project.open(PROJECT_PATH)

watch_target = proj.targets.find { |t| t.name == WATCH_TARGET }
abort "ERROR: target '#{WATCH_TARGET}' not found" unless watch_target

test_target = proj.targets.find { |t| t.name == TEST_TARGET }
abort "ERROR: target '#{TEST_TARGET}' not found" unless test_target

def find_or_create_group(proj, group_path)
  parts = group_path.split('/')
  current = proj.main_group
  parts.each do |part|
    child = current.children.find { |c| (c.name == part) || (c.path == part) || (c.display_name == part) }
    if child.nil?
      current = current.new_group(part, part)
    else
      current = child
    end
  end
  current
end

def add_to_target(proj, target, group_path, file_path)
  file_name = File.basename(file_path)
  group = find_or_create_group(proj, group_path)

  file_ref = proj.files.find { |f| f.path == file_path } ||
             group.children.find { |c| c.respond_to?(:path) && c.path == file_name }

  if file_ref.nil?
    file_ref = group.new_reference(File.join(File.dirname(__FILE__), '..', file_path))
    file_ref.path = file_name
    file_ref.source_tree = '<group>'
    puts "Created file ref: #{file_path}"
  else
    puts "File ref exists: #{file_path}"
  end

  sources = target.source_build_phase
  already = sources.files.any? { |bf| bf.file_ref && bf.file_ref.uuid == file_ref.uuid }
  if already
    puts "  already in '#{target.name}' Sources"
  else
    sources.add_file_reference(file_ref)
    puts "  added to '#{target.name}' Sources"
  end
end

SOURCE_FILES.each do |group_path, file_path|
  add_to_target(proj, watch_target, group_path, file_path)
end

TEST_FILES.each do |group_path, file_path|
  add_to_target(proj, test_target, group_path, file_path)
end

proj.save
puts "\nProject saved: #{PROJECT_PATH}"
