#!/usr/bin/env ruby
# encoding: utf-8
# add_import_test.rb
#
# Adds LoopAlgorithmCoreImportTest.swift to WatchApp ExtensionTests target
# and links LoopAlgorithmCore-watchOS.framework to the test target so the
# import resolves.

require 'xcodeproj'

PROJECT_PATH = File.expand_path('~/dev/LoopWorkspace/Loop/Loop.xcodeproj')
TEST_FILE_PATH = 'WatchApp ExtensionTests/LoopAlgorithmCoreImportTest.swift'

project = Xcodeproj::Project.open(PROJECT_PATH)

# Find test target
test_target = project.targets.find { |t| t.name == 'WatchApp ExtensionTests' }
raise 'Cannot find WatchApp ExtensionTests target' unless test_target

# Find LoopAlgorithmCore-watchOS product reference
lac_watch_target = project.targets.find { |t| t.name == 'LoopAlgorithmCore-watchOS' }
raise 'Cannot find LoopAlgorithmCore-watchOS target' unless lac_watch_target
lac_watch_fw_ref = lac_watch_target.product_reference

# Check if already added
already_in_sources = test_target.source_build_phase.files.any? { |f|
  f.file_ref&.path&.include?('LoopAlgorithmCoreImportTest')
}

if already_in_sources
  puts 'LoopAlgorithmCoreImportTest already in test target sources.'
else
  # Add the test file reference
  test_file_ref = project.new_file(TEST_FILE_PATH)
  test_file_ref.move(project.main_group.children.find { |g|
    g.respond_to?(:path) && g.path == 'WatchApp ExtensionTests'
  } || project.main_group)

  # Add to test target sources
  test_target.source_build_phase.add_file_reference(test_file_ref)
  puts "Added #{TEST_FILE_PATH} to WatchApp ExtensionTests sources"
end

# Add LoopAlgorithmCore-watchOS to test target's frameworks phase (for import resolution)
already_linked = test_target.frameworks_build_phase.files.any? { |f|
  f.file_ref == lac_watch_fw_ref
}

if already_linked
  puts 'LoopAlgorithmCore-watchOS already linked to test target.'
else
  test_target.frameworks_build_phase.add_file_reference(lac_watch_fw_ref)
  puts 'Added LoopAlgorithmCore-watchOS.framework to WatchApp ExtensionTests frameworks'
end

project.save
puts 'Done!'
