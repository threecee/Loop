#!/usr/bin/env ruby
# encoding: utf-8
# frozen_string_literal: false
# add_loopalgorithmcore_target.rb
#
# Adds LoopAlgorithmCore (iOS) and LoopAlgorithmCore-watchOS framework targets
# to Loop.xcodeproj, mirroring the LoopCore / LoopCore-watchOS pattern exactly.
#
# Usage:
#   GEM_PATH=~/.gem/ruby/2.6.0 ruby -I ~/.gem/ruby/2.6.0/gems/xcodeproj-1.27.0/lib \
#     add_loopalgorithmcore_target.rb
#
# Idempotent: exits early if LoopAlgorithmCore target already exists.

require 'xcodeproj'
require 'pathname'

PROJECT_PATH = File.expand_path('~/dev/LoopWorkspace/Loop/Loop.xcodeproj')
FRAMEWORK_NAME = 'LoopAlgorithmCore'
WATCHOS_TARGET_NAME = 'LoopAlgorithmCore-watchOS'
BUNDLE_ID_IOS    = 'com.loopkit.LoopAlgorithmCore'
BUNDLE_ID_WATCHOS = 'com.loopkit.LoopAlgorithmCore'
STUB_SWIFT_PATH  = 'LoopAlgorithmCore/LoopAlgorithmCore.swift'
INFO_PLIST_PATH  = 'LoopAlgorithmCore/Info.plist'

project = Xcodeproj::Project.open(PROJECT_PATH)

# ── Idempotency check ──────────────────────────────────────────────────────────
if project.targets.any? { |t| t.name == FRAMEWORK_NAME }
  puts "Target '#{FRAMEWORK_NAME}' already exists. Nothing to do."
  exit 0
end

# ── Helper: find existing target by name ──────────────────────────────────────
def find_target(project, name)
  t = project.targets.find { |x| x.name == name }
  raise "Cannot find target '#{name}'" unless t
  t
end

loop_ios_target    = find_target(project, 'Loop')
watch_ext_target   = find_target(project, 'WatchApp Extension')

# ── Helper: find or create a file reference ───────────────────────────────────
def find_or_create_file_ref(project, path)
  existing = project.files.find { |f| f.path == path }
  return existing if existing
  project.new_file(path)
end

# ── 1. Add the source file + Info.plist to the project's file references ──────
swift_ref  = find_or_create_file_ref(project, STUB_SWIFT_PATH)
plist_ref  = find_or_create_file_ref(project, INFO_PLIST_PATH)

# ── 2. Create LoopAlgorithmCore (iOS) framework target ────────────────────────
ios_target = project.new_target(
  :framework,
  FRAMEWORK_NAME,
  :ios,
  '17.0',          # deployment target; matches project minimum
  project.products_group
)

# Configure build settings for iOS target (mirror LoopCore iOS settings)
ios_common_settings = {
  'APPLICATION_EXTENSION_API_ONLY' => 'YES',
  'CLANG_ENABLE_OBJC_WEAK'         => 'YES',
  'DEFINES_MODULE'                 => 'YES',
  'DYLIB_INSTALL_NAME_BASE'        => '@rpath',
  'INFOPLIST_FILE'                 => INFO_PLIST_PATH,
  'INSTALL_PATH'                   => '$(LOCAL_LIBRARY_DIR)/Frameworks',
  'LD_RUNPATH_SEARCH_PATHS'        => ['$(inherited)', '@executable_path/Frameworks', '@loader_path/Frameworks'],
  'PRODUCT_BUNDLE_IDENTIFIER'      => BUNDLE_ID_IOS,
  'PRODUCT_NAME'                   => '$(TARGET_NAME:c99extidentifier)',
  'SKIP_INSTALL'                   => 'YES',
  'SUPPORTED_PLATFORMS'            => 'iphoneos iphonesimulator',
  'SUPPORTS_MACCATALYST'           => 'NO',
  'SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD' => 'NO',
  'SUPPORTS_XR_DESIGNED_FOR_IPHONE_IPAD'  => 'NO',
  'SWIFT_EMIT_LOC_STRINGS'         => 'YES',
  'SWIFT_INSTALL_OBJC_HEADER'      => 'NO',
  'TARGETED_DEVICE_FAMILY'         => '1,2',
}

ios_target.build_configurations.each do |config|
  ios_common_settings.each { |k, v| config.build_settings[k] = v }
end

# Add the Swift stub to Sources build phase
ios_sources_phase = ios_target.source_build_phase
ios_sources_phase.add_file_reference(swift_ref)

# ── 3. Create LoopAlgorithmCore-watchOS framework target ─────────────────────
watch_target = project.new_target(
  :framework,
  WATCHOS_TARGET_NAME,
  :watchos,
  '10.0',           # deployment target; matches project minimum
  project.products_group
)

watch_common_settings = {
  'APPLICATION_EXTENSION_API_ONLY' => 'YES',
  'CLANG_ENABLE_OBJC_WEAK'         => 'YES',
  'DEFINES_MODULE'                 => 'YES',
  'DYLIB_INSTALL_NAME_BASE'        => '@rpath',
  'FRAMEWORK_SEARCH_PATHS'         => '',
  'INFOPLIST_FILE'                 => INFO_PLIST_PATH,
  'INSTALL_PATH'                   => '$(LOCAL_LIBRARY_DIR)/Frameworks',
  'LD_NO_PIE'                      => 'NO',
  'LD_RUNPATH_SEARCH_PATHS'        => ['$(inherited)', '@executable_path/Frameworks', '@loader_path/Frameworks'],
  'PRODUCT_BUNDLE_IDENTIFIER'      => BUNDLE_ID_WATCHOS,
  'PRODUCT_NAME'                   => FRAMEWORK_NAME,
  'SDKROOT'                        => 'watchos',
  'SKIP_INSTALL'                   => 'YES',
  'SWIFT_EMIT_LOC_STRINGS'         => 'YES',
  'SWIFT_INSTALL_OBJC_HEADER'      => 'NO',
  'TARGETED_DEVICE_FAMILY'         => '4',
}

watch_target.build_configurations.each do |config|
  watch_common_settings.each { |k, v| config.build_settings[k] = v }
end

# Add Swift stub to watchOS Sources phase
watch_sources_phase = watch_target.source_build_phase
watch_sources_phase.add_file_reference(swift_ref)

# ── 4. Add LoopAlgorithmCore (iOS) to Loop iOS target ─────────────────────────
# 4a. Link: add ios_target.product_reference to Loop's Frameworks build phase
ios_fw_ref = ios_target.product_reference   # LoopAlgorithmCore.framework (iOS product)
loop_fw_phase = loop_ios_target.frameworks_build_phase
loop_fw_phase.add_file_reference(ios_fw_ref)

# 4b. Embed: add to Loop iOS's "Embed Frameworks" copy-files phase
loop_embed_phase = loop_ios_target.copy_files_build_phases.find { |p| p.name == 'Embed Frameworks' }
unless loop_embed_phase
  raise "Cannot find 'Embed Frameworks' phase on Loop iOS target"
end
embed_build_file = project.new(Xcodeproj::Project::Object::PBXBuildFile)
embed_build_file.file_ref = ios_fw_ref
embed_build_file.settings = { 'ATTRIBUTES' => ['CodeSignOnCopy', 'RemoveHeadersOnCopy'] }
loop_embed_phase.files << embed_build_file

# 4c. Add target dependency so Loop iOS builds LoopAlgorithmCore first
loop_ios_target.add_dependency(ios_target)

# ── 5. Add LoopAlgorithmCore-watchOS to WatchApp Extension target ─────────────
watch_fw_ref = watch_target.product_reference  # LoopAlgorithmCore.framework (watchOS product)
ext_fw_phase = watch_ext_target.frameworks_build_phase
ext_fw_phase.add_file_reference(watch_fw_ref)

# 5b. Embed: add to WatchApp Extension's "Embed Frameworks" copy-files phase
ext_embed_phase = watch_ext_target.copy_files_build_phases.find { |p| p.name == 'Embed Frameworks' }
unless ext_embed_phase
  raise "Cannot find 'Embed Frameworks' phase on WatchApp Extension target"
end
ext_embed_build_file = project.new(Xcodeproj::Project::Object::PBXBuildFile)
ext_embed_build_file.file_ref = watch_fw_ref
ext_embed_build_file.settings = { 'ATTRIBUTES' => ['CodeSignOnCopy', 'RemoveHeadersOnCopy'] }
ext_embed_phase.files << ext_embed_build_file

# 5c. Add target dependency so WatchApp Extension builds LoopAlgorithmCore-watchOS first
watch_ext_target.add_dependency(watch_target)

# ── 6. Add LoopAlgorithmCore group to main project navigator group ─────────────
main_group = project.main_group
# Find the existing LoopCore group to insert after it
loopcore_group_ref = main_group.children.find { |c| c.respond_to?(:path) && c.path == 'LoopCore' && c.class == Xcodeproj::Project::Object::PBXGroup }

# Create group for LoopAlgorithmCore
lac_group = main_group.new_group('LoopAlgorithmCore', 'LoopAlgorithmCore')
lac_group.source_tree = '<group>'

# Add the files to this group (re-parent; xcodeproj handles moving)
# The files were auto-added to main_group — move them into lac_group
[swift_ref, plist_ref].each do |ref|
  ref.move(lac_group)
end

# ── 7. Save ───────────────────────────────────────────────────────────────────
project.save
puts "Done! Added targets '#{FRAMEWORK_NAME}' (iOS) and '#{WATCHOS_TARGET_NAME}' (watchOS)."
puts "  - '#{FRAMEWORK_NAME}' linked+embedded in Loop iOS target"
puts "  - '#{WATCHOS_TARGET_NAME}' linked+embedded in WatchApp Extension target"
