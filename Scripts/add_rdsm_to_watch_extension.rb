#!/usr/bin/env ruby
# add_rdsm_to_watch_extension.rb
# B.3.a Phase 4 — Add RemoteDataServicesManager.swift to WatchApp Extension Sources
#
# RemoteDataServicesManager.swift has zero UIKit refs (imports only os.log,
# Foundation, LoopKit) so it is safe to compile on watchOS as-is.
# After this, Phase 5 can construct RemoteDataServicesManager from
# WatchRemoteCommandBootstrap.

require 'xcodeproj'

PROJECT_PATH          = File.expand_path('../Loop.xcodeproj', __dir__)
WATCH_EXT_TARGET_NAME = 'WatchApp Extension'
FILE_REF_UUID         = '432E73CA1D24B3D6009AD15D'  # RemoteDataServicesManager.swift

proj = Xcodeproj::Project.open(PROJECT_PATH)

watch_target = proj.targets.find { |t| t.name == WATCH_EXT_TARGET_NAME }
abort "ERROR: Target '#{WATCH_EXT_TARGET_NAME}' not found in #{PROJECT_PATH}" unless watch_target

puts "Found target: #{watch_target.name}"

# Resolve the existing file reference by path
file_ref = proj.files.find { |f| f.path == 'RemoteDataServicesManager.swift' }
abort "ERROR: Could not find file reference for RemoteDataServicesManager.swift" unless file_ref
abort "ERROR: UUID mismatch (expected #{FILE_REF_UUID}, got #{file_ref.uuid})" unless file_ref.uuid == FILE_REF_UUID

puts "Found file reference: #{file_ref.path} (#{FILE_REF_UUID})"

# Check if already in the WatchApp Extension Sources phase
sources_phase = watch_target.source_build_phase
already_added = sources_phase.files.any? do |bf|
  bf.file_ref && bf.file_ref.uuid == FILE_REF_UUID
end

if already_added
  puts "RemoteDataServicesManager.swift already in '#{WATCH_EXT_TARGET_NAME}' Sources — skipping"
else
  sources_phase.add_file_reference(file_ref)
  puts "Added RemoteDataServicesManager.swift to '#{WATCH_EXT_TARGET_NAME}' Sources phase"
end

proj.save
puts "\nProject saved: #{PROJECT_PATH}"
puts "\nSummary:"
puts "  - RemoteDataServicesManager.swift is now a member of '#{WATCH_EXT_TARGET_NAME}'"
puts "  - Zero UIKit gates needed (file imports only os.log, Foundation, LoopKit)"
puts "  - Phase 5 can now construct RemoteDataServicesManager from WatchRemoteCommandBootstrap"
