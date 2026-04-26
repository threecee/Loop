#!/usr/bin/env ruby
# encoding: utf-8
# frozen_string_literal: false
# relocate_store_protocols_to_loopalgorithmcore.rb
#
# Phase 2.D follow-up: relocate the five Loop-iOS-only types that
# LoopAlgorithmRunner needs to LoopAlgorithmCore — the runner can't reference
# Loop-iOS-target types.
#
# Files moved (already git mv'd; this script just rewrites project memberships):
#   Loop/Managers/Store Protocols/CarbStoreProtocol.swift   -> LoopAlgorithmCore/
#   Loop/Managers/Store Protocols/DoseStoreProtocol.swift   -> LoopAlgorithmCore/
#   Loop/Managers/Store Protocols/GlucoseStoreProtocol.swift -> LoopAlgorithmCore/
#   Loop/Managers/Store Protocols/DosingDecisionStoreProtocol.swift -> LoopAlgorithmCore/
#   Loop/Models/BolusDosingDecision.swift                   -> LoopAlgorithmCore/
#
# Project surgery:
#   - rewrite each file_ref's path to the new LoopAlgorithmCore/ location
#   - re-parent each file_ref into the LoopAlgorithmCore navigator group
#   - keep the file in Loop iOS Sources phase ONLY if it isn't already covered
#     by `import LoopAlgorithmCore` — for these protocols, REMOVE from Loop
#     iOS sources (they're now visible via the LAC import); REMOVE from
#     LoopTests sources too if present
#   - ADD to LoopAlgorithmCore (iOS) + LoopAlgorithmCore-watchOS Sources phases
#
# Idempotent.
#
# Usage:
#   GEM_PATH=~/.gem/ruby/2.6.0 ruby -I ~/.gem/ruby/2.6.0/gems/xcodeproj-1.27.0/lib \
#     scripts/relocate_store_protocols_to_loopalgorithmcore.rb

require 'xcodeproj'

PROJECT_PATH = File.expand_path('~/dev/LoopWorkspace/Loop/Loop.xcodeproj')
RELOCATIONS = {
  # old project-relative path => new project-relative path
  'Loop/Managers/Store Protocols/CarbStoreProtocol.swift'           => 'LoopAlgorithmCore/CarbStoreProtocol.swift',
  'Loop/Managers/Store Protocols/DoseStoreProtocol.swift'           => 'LoopAlgorithmCore/DoseStoreProtocol.swift',
  'Loop/Managers/Store Protocols/GlucoseStoreProtocol.swift'        => 'LoopAlgorithmCore/GlucoseStoreProtocol.swift',
  'Loop/Managers/Store Protocols/DosingDecisionStoreProtocol.swift' => 'LoopAlgorithmCore/DosingDecisionStoreProtocol.swift',
  'Loop/Models/BolusDosingDecision.swift'                            => 'LoopAlgorithmCore/BolusDosingDecision.swift'
}
LAC_TARGETS = ['LoopAlgorithmCore', 'LoopAlgorithmCore-watchOS']
DROP_FROM_TARGETS = ['Loop', 'LoopTests', 'WatchApp Extension']

project = Xcodeproj::Project.open(PROJECT_PATH)

main_group = project.main_group
lac_group = main_group.children.find { |c|
  c.respond_to?(:path) && c.path == 'LoopAlgorithmCore' && c.class == Xcodeproj::Project::Object::PBXGroup
}
raise 'Cannot find LoopAlgorithmCore group' unless lac_group

# Build (filename => new project path) map for quick lookup of file_refs by basename.
basename_to_new_path = RELOCATIONS.each_with_object({}) { |(_, np), m| m[File.basename(np)] = np }

# Walk all file_refs once; rewrite path + re-parent for any of the relocated files.
project.files.each do |f|
  next unless f.path
  basename = File.basename(f.path)
  next unless basename_to_new_path.key?(basename)

  new_path = basename_to_new_path[basename]
  if f.path != new_path && f.path != basename
    puts "  [path]  #{f.path} -> #{new_path}"
    f.path = new_path
  end

  # Move into LAC group if not already there
  if f.parent != lac_group
    puts "  [group] re-parenting #{basename} into LoopAlgorithmCore group"
    f.move(lac_group)
  end
end

# For each relocated file, update target memberships:
#  - REMOVE from Loop / LoopTests / WatchApp Extension
#  - ADD to both LAC targets (idempotently)
RELOCATIONS.each_value do |new_path|
  basename = File.basename(new_path)
  ref = project.files.find { |f| f.path == new_path || f.path == basename }
  unless ref
    puts "  [warn] No file_ref for #{basename}; skipping target updates"
    next
  end

  # Drop from iOS / test targets
  DROP_FROM_TARGETS.each do |tname|
    target = project.targets.find { |t| t.name == tname }
    next unless target
    src_phase = target.source_build_phase
    bf = src_phase.files.find { |bf| bf.file_ref == ref }
    if bf
      src_phase.remove_build_file(bf)
      puts "  [drop]  #{basename} <- #{tname}"
    end
  end

  # Add to both LAC targets (idempotent)
  LAC_TARGETS.each do |tname|
    target = project.targets.find { |t| t.name == tname }
    raise "Cannot find target '#{tname}'" unless target
    src_phase = target.source_build_phase
    already_added = src_phase.files.any? { |bf| bf.file_ref == ref }
    if already_added
      puts "  [skip]  #{basename} already in #{tname}"
    else
      src_phase.add_file_reference(ref)
      puts "  [add ]  #{basename} -> #{tname}"
    end
  end
end

project.save
puts 'Done!'
