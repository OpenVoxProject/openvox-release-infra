# frozen_string_literal: true

class Platform
  attr_reader :os, :version, :arch

  def initialize(os:, version:, arch: nil)
    @os = os
    @version = version
    @arch = arch
  end

  # Parse from a deb filename like: openvox-agent_8.12.1-1+debian13_amd64.deb
  def self.from_deb(filename)
    match = File.basename(filename).match(/\+([a-z]+)([\d.]+)_(\w+)\.deb$/)
    return nil unless match

    new(os: match[1], version: match[2], arch: match[3])
  end

  # Parse from an rpm filename like: openvox-agent-8.12.1-1.el9.x86_64.rpm
  def self.from_rpm(filename)
    match = File.basename(filename).match(/\.(\D+?)(\d[\d.]*)\.(\w+)\.rpm$/)
    return nil unless match

    dist_tag = match[1]
    new(os: dist_tag == 'fc' ? 'fedora' : dist_tag, version: match[2], arch: match[3])
  end

  # Parse from a user-input platform string like: el-9-x86_64, debian-13-amd64, fedora-40-x86_64
  def self.from_filter(filter)
    parts = filter.split('-', 3)
    return nil unless parts.size == 3

    new(os: parts[0], version: parts[1], arch: parts[2])
  end

  # The codename used in apt repos (e.g. "debian13", "ubuntu24.04")
  def codename
    "#{os}#{version}"
  end

  # The dist tag used in rpm filenames (e.g. "el" stays "el", "fedora" becomes "fc")
  def dist_tag
    os == 'fedora' ? 'fc' : os
  end

  def kind
    case os
    when 'debian', 'ubuntu' then 'deb'
    when 'macos' then 'dmg'
    when 'windows' then 'msi'
    else 'rpm'
    end
  end

  # Generate S3 include glob patterns for fetching packages
  def s3_globs
    case kind
    when 'dmg'
      ["*#{arch}*.dmg"]
    when 'msi'
      ['*.msi']
    when 'deb'
      ["*+#{os}#{version}_#{arch}.deb", "*+#{os}#{version}_all.deb"]
    else
      ["*.#{dist_tag}#{version}.#{arch}.rpm", "*.#{dist_tag}#{version}.noarch.rpm"]
    end
  end

  # Normalized string form for storage in JSON platform lists.
  # deb: "debian13", "ubuntu24.04"
  # rpm: "el-9", "sles-15"
  def normalized
    kind == 'deb' ? "#{os}#{version}" : "#{os}-#{version}"
  end
end
