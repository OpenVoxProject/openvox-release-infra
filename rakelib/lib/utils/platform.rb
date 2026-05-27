# frozen_string_literal: true

require 'csv'
require 'net/http'
require 'uri'

class Platform
  # Upstream Debian distro-info-data ships /usr/share/distro-info/{debian,ubuntu}.csv
  # on every Debian/Ubuntu host. We fetch the same files from salsa to avoid
  # hand-maintaining a codename table. Source of truth:
  # https://salsa.debian.org/debian/distro-info-data
  DISTRO_INFO_BASE_URL = 'https://salsa.debian.org/debian/distro-info-data/-/raw/main'
  APT_OS_NAMES = %w[debian ubuntu].freeze

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

  # The dist identifier used in apt repos (e.g. "debian13", "ubuntu24.04").
  # This is the directory name under dists/ and the value of the Codename field in Release files.
  def dist
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

  # Returns the upstream Debian/Ubuntu codename (the "series" column from
  # distro-info-data) for a canonical apt dist. Used to generate codename
  # aliases for apt repos (e.g. "trixie" alongside "debian13").
  # Returns nil for non-apt dists, unknown versions, or when the CSV
  # cannot be fetched.
  def self.codename_for(dist)
    match = dist.match(/\A(#{APT_OS_NAMES.join('|')})([\d.]+)\z/)
    return nil unless match

    table = distro_info_table(match[1])
    table && table[match[2]]
  end

  # True if the dist string is in canonical apt-dist form (e.g. debian13,
  # ubuntu24.04). Used to distinguish canonical dirs from codename alias
  # dirs when iterating state/apt/dists/.
  def self.canonical_apt_dist?(dist)
    dist.match?(/\A(#{APT_OS_NAMES.join('|')})[\d.]+\z/)
  end

  # Fetches and parses the upstream distro-info-data CSV for the given OS.
  # Cached at class level so a single rake invocation hits the network at
  # most once per OS. Returns a {version => series} hash, or nil on failure.
  def self.distro_info_table(os)
    @distro_info_tables ||= {}
    return @distro_info_tables[os] if @distro_info_tables.key?(os)

    @distro_info_tables[os] = fetch_distro_info_table(os)
  end

  # Internal. Performs the actual HTTP fetch and parse.
  def self.fetch_distro_info_table(os)
    url = "#{DISTRO_INFO_BASE_URL}/#{os}.csv"
    response = Net::HTTP.get_response(URI(url))
    unless response.is_a?(Net::HTTPSuccess)
      warn "Could not fetch #{url}: HTTP #{response.code} #{response.message}. " \
           'Codename aliases will be skipped for this run.'
      return nil
    end

    table = {}
    CSV.parse(response.body, headers: true) do |row|
      # Ubuntu LTS rows have version like "24.04 LTS"; strip the suffix.
      version = row['version']&.sub(/ LTS\z/, '')
      series = row['series']
      next if version.nil? || version.empty? || series.nil? || series.empty?

      table[version] = series
    end
    table
  rescue StandardError => e
    warn "Could not fetch #{url}: #{e.class}: #{e.message}. " \
         'Codename aliases will be skipped for this run.'
    nil
  end
end
