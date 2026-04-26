#!/usr/bin/env ruby
# encoding: utf-8
# frozen_string_literal: false
# add_runner_to_loopalgorithmcore.rb
#
# Adds LoopAlgorithmRunner.swift + LoopAlgorithmRunnerDelegate.swift to both
# LoopAlgorithmCore (iOS) and LoopAlgorithmCore-watchOS framework targets.
# Phase 2.D of B.3.a — see:
#   docs/superpowers/specs/2026-04-26-b3a-watch-self-driving-design.md
#   docs/research/2026-04-26-loopalgorithmcore-extraction.md
#
# Idempotent: skips files already in either target's source phase.
#
# Usage:
#   GEM_PATH=~/.gem/ruby/2.6.0 ruby -I ~/.gem/ruby/2.6.0/gems/xcodeproj-1.27.0/lib \
#     scripts/add_runner_to_loopalgorithmcore.rb

require 'xcodeproj'

PROJECT_PATH = File.expand_path('~/dev/LoopWorkspace/Loop/Loop.xcodeproj')
FILES = [
  'LoopAlgorithmCore/LoopAlgorithmRunnerDelegate.swift',
  'LoopAlgorithmCore/LoopAlgorithmRunner.swift'
]
TARGETS = ['LoopAlgorithmCore', 'LoopAlgorithmCore-watchOS']

project = Xcodeproj::Project.open(PROJECT_PATH)

# Find or create the LoopAlgorithmCore group so the new files have a navigator home.
main_group = project.main_group
lac_group = main_group.children.find { |c|
  c.respond_to?(:path) && c.path == 'LoopAlgorithmCore' && c.class == Xcodeproj::Project::Object::PBXGroup
}
raise 'Cannot find LoopAlgorithmCore group in project navigator' unless lac_group

def find_or_create_file_ref(project, group, path)
  existing = project.files.find { |f| f.path == path }
  return existing if existing
  group.new_file(File.basename(path))
end

# Re-parent into the group if a file ref already exists at top level.
file_refs = FILES.map do |relpath|
  basename = File.basename(relpath)
  existing = project.files.find { |f| f.path == relpath || f.path == basename }
  if existing
    if existing.parent != lac_group
      existing.move(lac_group)
    end
    existing
  else
    ref = lac_group.new_file(basename)
    ref
  end
end

TARGETS.each do |target_name|
  target = project.targets.find { |t| t.name == target_name }
  raise "Cannot find target '#{target_name}'" unless target

  src_phase = target.source_build_phase
  file_refs.each do |ref|
    already_added = src_phase.files.any? { |bf| bf.file_ref == ref }
    if already_added
      puts "  [skip] #{ref.path} already in #{target_name} sources"
    else
      src_phase.add_file_reference(ref)
      puts "  [add ] #{ref.path} -> #{target_name} sources"
    end
  end
end

project.save
puts 'Done!'
