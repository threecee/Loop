#!/usr/bin/env ruby
# add_nightscout_smoke_test.rb
# B.3.a Phase 3.B — add NightscoutServiceLoadingTest.swift to WatchApp ExtensionTests target
# and ensure NightscoutServiceKit.framework is linked into the test target.

require 'xcodeproj'

PROJECT_PATH      = File.expand_path('../../Loop/Loop.xcodeproj', __dir__)
TEST_TARGET_NAME  = 'WatchApp ExtensionTests'
TEST_FILE_PATH    = 'WatchApp ExtensionTests/NightscoutServiceLoadingTest.swift'

proj = Xcodeproj::Project.open(PROJECT_PATH)

test_target = proj.targets.find { |t| t.name == TEST_TARGET_NAME }
abort "ERROR: Target '#{TEST_TARGET_NAME}' not found" unless test_target

puts "Found target: #{test_target.name}"

# -----------------------------------------------------------------------
# 1. Find or create the file reference for the new test file
# -----------------------------------------------------------------------
test_file_ref = proj.main_group.find_subpath('WatchApp ExtensionTests', false)&.files&.find { |f|
  f.path == TEST_FILE_PATH || f.name == 'NightscoutServiceLoadingTest.swift'
}

unless test_file_ref
  # Get or create the WatchApp ExtensionTests group
  watch_tests_group = proj.main_group.find_subpath('WatchApp ExtensionTests', false)
  unless watch_tests_group
    watch_tests_group = proj.main_group.new_group('WatchApp ExtensionTests', 'WatchApp ExtensionTests')
    puts "Created group: WatchApp ExtensionTests"
  end

  test_file_ref = watch_tests_group.new_file(TEST_FILE_PATH)
  test_file_ref.name = 'NightscoutServiceLoadingTest.swift'
  test_file_ref.source_tree = 'SOURCE_ROOT'
  puts "Created file reference: #{TEST_FILE_PATH}"
else
  puts "File reference already exists: #{test_file_ref.path || test_file_ref.name}"
end

# -----------------------------------------------------------------------
# 2. Add the file to the Sources build phase of WatchApp ExtensionTests
# -----------------------------------------------------------------------
sources_phase = test_target.source_build_phase
already_added = sources_phase.files.any? { |bf| bf.file_ref == test_file_ref }

unless already_added
  sources_phase.add_file_reference(test_file_ref)
  puts "Added NightscoutServiceLoadingTest.swift to #{TEST_TARGET_NAME} Sources phase"
else
  puts "NightscoutServiceLoadingTest.swift already in Sources phase — skipping"
end

# -----------------------------------------------------------------------
# 3. Add NightscoutServiceKit.framework to the test target's Frameworks phase
#    (find the existing ref created by link_nightscout_to_watch_extension.rb)
# -----------------------------------------------------------------------
ns_kit_ref = nil
proj.main_group.recursive_children.each do |child|
  if child.respond_to?(:path) && child.path == 'NightscoutServiceKit.framework'
    ns_kit_ref = child
    break
  end
end

if ns_kit_ref
  frameworks_phase = test_target.frameworks_build_phase
  already_linked = frameworks_phase.files.any? { |bf| bf.file_ref == ns_kit_ref }
  unless already_linked
    frameworks_phase.add_file_reference(ns_kit_ref)
    puts "Added NightscoutServiceKit.framework to #{TEST_TARGET_NAME} Frameworks phase"
  else
    puts "NightscoutServiceKit.framework already in test Frameworks phase — skipping"
  end
else
  puts "WARN: NightscoutServiceKit.framework file ref not found — run link_nightscout_to_watch_extension.rb first"
end

proj.save
puts "\nProject saved: #{PROJECT_PATH}"
puts "Done. NightscoutServiceLoadingTest.swift added to #{TEST_TARGET_NAME}"
