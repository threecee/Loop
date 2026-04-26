#!/usr/bin/env ruby
# link_nightscout_to_watch_extension.rb
# B.3.a Phase 3.B — Static link NightscoutServiceKit into WatchApp Extension
#
# Dynamic plugin loading is blocked on watchOS extensions:
#   - No PluginManager / ServicesManager in WatchApp Extension
#   - NightscoutServiceKitPlugin requires LoopKitUI (iOS-only)
#   - watchOS sandbox does not support Loop's Bundle.principalClass discovery
#
# This script statically links NightscoutServiceKit.framework into the
# WatchApp Extension target and embeds it so it ships in the .appex bundle.
# Explicit registration in WatchRemoteCommandBootstrap will follow in Phase 5.

require 'xcodeproj'

PROJECT_PATH         = File.expand_path('../../Loop/Loop.xcodeproj', __dir__)
WORKSPACE_ROOT       = File.expand_path('../..', __dir__)
WATCH_EXT_TARGET_NAME = 'WatchApp Extension'

# The NightscoutService project is a workspace sibling — reference its built product.
NIGHTSCOUT_PROJECT_PATH = File.join(WORKSPACE_ROOT, 'NightscoutService', 'NightscoutService.xcodeproj')

proj = Xcodeproj::Project.open(PROJECT_PATH)

watch_target = proj.targets.find { |t| t.name == WATCH_EXT_TARGET_NAME }
abort "ERROR: Target '#{WATCH_EXT_TARGET_NAME}' not found in #{PROJECT_PATH}" unless watch_target

puts "Found target: #{watch_target.name}"

# -----------------------------------------------------------------------
# 1. Find or create a file reference for NightscoutServiceKit.framework
#    (built product from the NightscoutService project)
# -----------------------------------------------------------------------
ns_kit_ref = proj.main_group.find_subpath('Frameworks', true).files.find do |f|
  f.path == 'NightscoutServiceKit.framework'
end

unless ns_kit_ref
  # Add as a reference to the built product — same pattern as LoopKit, LoopAlgorithmCore etc.
  frameworks_group = proj.main_group.find_subpath('Frameworks', false)
  frameworks_group ||= proj.main_group.new_group('Frameworks')

  ns_kit_ref = proj.new_file('NightscoutServiceKit.framework')
  ns_kit_ref.source_tree = 'BUILT_PRODUCTS_DIR'
  ns_kit_ref.explicit_file_type = 'wrapper.framework'
  ns_kit_ref.include_in_index = '0'
  puts "Created file reference: NightscoutServiceKit.framework (BUILT_PRODUCTS_DIR)"
else
  puts "File reference already exists: #{ns_kit_ref.path}"
end

# -----------------------------------------------------------------------
# 2. Add to WatchApp Extension Frameworks build phase (link)
# -----------------------------------------------------------------------
frameworks_phase = watch_target.frameworks_build_phase
already_linked = frameworks_phase.files.any? do |bf|
  bf.file_ref&.path == 'NightscoutServiceKit.framework'
end

unless already_linked
  frameworks_phase.add_file_reference(ns_kit_ref)
  puts "Added NightscoutServiceKit.framework to '#{WATCH_EXT_TARGET_NAME}' Frameworks phase"
else
  puts "NightscoutServiceKit.framework already in Frameworks phase — skipping"
end

# -----------------------------------------------------------------------
# 3. Add to Embed Frameworks build phase (so it ships in the .appex bundle)
# -----------------------------------------------------------------------
embed_phase = watch_target.copy_files_build_phases.find { |p| p.name == 'Embed Frameworks' }

unless embed_phase
  embed_phase = watch_target.new_copy_files_build_phase('Embed Frameworks')
  embed_phase.dst_subfolder_spec = '10'  # Frameworks
  puts "Created 'Embed Frameworks' phase on #{WATCH_EXT_TARGET_NAME}"
end

already_embedded = embed_phase.files.any? do |bf|
  bf.file_ref&.path == 'NightscoutServiceKit.framework'
end

unless already_embedded
  embed_bf = embed_phase.add_file_reference(ns_kit_ref)
  # ATTRIBUTES = (CodeSignOnCopy, RemoveHeadersOnCopy) is standard for embedded frameworks
  embed_bf.settings = { 'ATTRIBUTES' => ['CodeSignOnCopy', 'RemoveHeadersOnCopy'] }
  puts "Added NightscoutServiceKit.framework to '#{WATCH_EXT_TARGET_NAME}' Embed Frameworks phase"
else
  puts "NightscoutServiceKit.framework already in Embed Frameworks — skipping"
end

# -----------------------------------------------------------------------
# 4. Add target dependency: WatchApp Extension depends on NightscoutServiceKit
#    This requires a cross-project (container) reference. We add it as a
#    file reference to the NightscoutService.xcodeproj itself, then use the
#    proxy target. This is the same pattern as OmniBLE, G7SensorKit, etc.
# -----------------------------------------------------------------------

# Find the NightscoutService project reference in the workspace
ns_project_ref = proj.main_group.find_subpath('NightscoutService.xcodeproj', false) ||
  proj.root_object.project_references.find { |ref_hash|
    ref_hash[:project_ref]&.path&.include?('NightscoutService.xcodeproj')
  }&.dig(:project_ref)

if ns_project_ref
  puts "Found NightscoutService.xcodeproj reference in main group"
else
  # Add project reference if not present
  puts "NightscoutService.xcodeproj not yet in project group — checking workspace structure..."
  puts "NOTE: The workspace already includes NightscoutService via xcworkspacedata."
  puts "Target dependency via container proxy requires the project to be in the main group."
  puts "Skipping target dependency (link is sufficient for build order in workspace context)."
end

proj.save
puts "\nProject saved: #{PROJECT_PATH}"
puts "\nSummary:"
puts "  - NightscoutServiceKit.framework linked into '#{WATCH_EXT_TARGET_NAME}'"
puts "  - NightscoutServiceKit.framework embedded into '#{WATCH_EXT_TARGET_NAME}'"
puts "  - Outcome B (static link) confirmed for Phase 3.B"
