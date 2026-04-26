#!/usr/bin/env ruby
# add_nightscout_deps_to_watch.rb
# B.3.a Phase 5 — Phase 3's static link of NightscoutServiceKit into the
# WatchApp Extension is incomplete: the Swift module interface of
# NightscoutServiceKit transitively imports Base32 (via OneTimePassword's
# OTPManager.swift). When the WatchApp Extension actually `import`s
# NightscoutServiceKit (Phase 5's WatchRemoteCommandBootstrap), Xcode's
# explicit-module build walks the module graph and demands Base32.
#
# This script adds the four SwiftPM products NightscoutServiceKit pulls
# in (Base32, OneTimePassword, NightscoutKit, Swift-JWT) to the
# WatchApp Extension target.

require 'xcodeproj'

PROJECT_PATH = File.expand_path('../Loop.xcodeproj', __dir__)
WATCH_TARGET = 'WatchApp Extension'

# Just Base32 — it's the only transitive dep that the explicit-modules build
# traces from NightscoutServiceKit's swiftmodule. OneTimePassword/NightscoutKit/
# Swift-JWT are referenced but their interfaces don't propagate up to the
# WatchApp Extension's module graph. If a future build surfaces additional
# missing modules, add them here in the same shape.
DEPS = [
  ['https://github.com/mattrubin/Base32.git', :branch, '1.1.2+spm', 'Base32'],
]

proj = Xcodeproj::Project.open(PROJECT_PATH)
target = proj.targets.find { |t| t.name == WATCH_TARGET }
abort "ERROR: target '#{WATCH_TARGET}' not found" unless target

DEPS.each do |url, req_kind, req_value, product_name|
  # Reuse an existing remote-package ref if one is already declared, otherwise create.
  pkg_ref = proj.root_object.package_references.find do |pkg|
    pkg.respond_to?(:repositoryURL) && pkg.repositoryURL == url
  end

  unless pkg_ref
    pkg_ref = proj.new(Xcodeproj::Project::Object::XCRemoteSwiftPackageReference)
    pkg_ref.repositoryURL = url
    pkg_ref.requirement = case req_kind
                          when :upToNextMajorVersion
                            { 'kind' => 'upToNextMajorVersion', 'minimumVersion' => req_value }
                          when :branch
                            { 'kind' => 'branch', 'branch' => req_value }
                          else
                            raise "unsupported req kind: #{req_kind}"
                          end
    proj.root_object.package_references << pkg_ref
    puts "Added remote package reference: #{url}"
  else
    puts "Remote package reference already present: #{url}"
  end

  # Find or create the product dependency on the WatchApp Extension target.
  prod_dep = target.package_product_dependencies.find { |d| d.product_name == product_name }
  unless prod_dep
    prod_dep = proj.new(Xcodeproj::Project::Object::XCSwiftPackageProductDependency)
    prod_dep.package = pkg_ref
    prod_dep.product_name = product_name
    target.package_product_dependencies << prod_dep
    puts "  Added product dep: #{product_name} on '#{WATCH_TARGET}'"
  else
    puts "  Product dep already present: #{product_name}"
  end

  # Add to Frameworks build phase.
  fw_phase = target.frameworks_build_phase
  already_in_fw = fw_phase.files.any? { |bf| bf.product_ref == prod_dep }
  unless already_in_fw
    bf = proj.new(Xcodeproj::Project::Object::PBXBuildFile)
    bf.product_ref = prod_dep
    fw_phase.files << bf
    puts "  Added #{product_name} to '#{WATCH_TARGET}' Frameworks build phase"
  else
    puts "  #{product_name} already in Frameworks phase"
  end
end

proj.save
puts "\nProject saved: #{PROJECT_PATH}"
