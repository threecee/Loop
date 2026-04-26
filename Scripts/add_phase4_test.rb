#!/usr/bin/env ruby
# add_phase4_test.rb
# B.3.a Phase 4 — Add Phase4_RemoteDataServicesManagerImportTest.swift
#                 to WatchApp ExtensionTests target Sources phase.

require 'xcodeproj'

PROJECT_PATH   = File.expand_path('../Loop.xcodeproj', __dir__)
TEST_TARGET    = 'WatchApp ExtensionTests'
FILE_PATH      = 'WatchApp ExtensionTests/Phase4_RemoteDataServicesManagerImportTest.swift'
FILE_NAME      = 'Phase4_RemoteDataServicesManagerImportTest.swift'

proj = Xcodeproj::Project.open(PROJECT_PATH)

test_target = proj.targets.find { |t| t.name == TEST_TARGET }
abort "ERROR: Target '#{TEST_TARGET}' not found" unless test_target
puts "Found target: #{test_target.name}"

# Find or create the file reference
file_ref = proj.files.find { |f| f.path&.include?(FILE_NAME) }

unless file_ref
  # Find the WatchApp ExtensionTests group
  tests_group = proj.main_group.find_subpath('WatchApp ExtensionTests', false)
  unless tests_group
    # Try recursive search
    tests_group = proj.main_group.groups.find { |g| g.name == 'WatchApp ExtensionTests' || g.path&.include?('WatchApp ExtensionTests') }
  end

  if tests_group
    file_ref = tests_group.new_reference(FILE_NAME)
    file_ref.source_tree = 'SOURCE_ROOT'
    file_ref.path = FILE_PATH
    puts "Created file reference: #{FILE_NAME}"
  else
    # Add to main group with relative path
    file_ref = proj.main_group.new_reference(FILE_PATH)
    file_ref.source_tree = 'SOURCE_ROOT'
    puts "Created file reference in main group: #{FILE_PATH}"
  end
else
  puts "File reference already exists: #{file_ref.path}"
end

# Add to Sources phase
sources_phase = test_target.source_build_phase
already_added = sources_phase.files.any? do |bf|
  bf.file_ref && (bf.file_ref.path&.include?(FILE_NAME) || bf.file_ref.uuid == file_ref.uuid)
end

if already_added
  puts "#{FILE_NAME} already in '#{TEST_TARGET}' Sources — skipping"
else
  sources_phase.add_file_reference(file_ref)
  puts "Added #{FILE_NAME} to '#{TEST_TARGET}' Sources phase"
end

proj.save
puts "\nProject saved: #{PROJECT_PATH}"
puts "\nSummary:"
puts "  - #{FILE_NAME} added to '#{TEST_TARGET}'"
