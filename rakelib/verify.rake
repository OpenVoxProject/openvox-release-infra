# frozen_string_literal: true

require 'shellwords'
require 'zlib'
require_relative 'lib/utils/infra'
require_relative 'lib/utils/platform'
require_relative 'lib/utils/shell'

GPG_KEY_PATH_IN_CONTAINER = "#{Infra::CONTAINER_WORK}/files/repo_packages/keys/GPG-KEY-openvox.pub".freeze

desc 'Verify packages currently staged for release are accessible and GPG-signed in the deployed repos'
task :verify do
  Infra.setup_aws
  Infra.print_target(:apt_bucket, :yum_bucket)

  staged_debs = Dir.glob(File.join(Infra::STAGING_DIR, 'apt', 'pool', '**', '*.deb'))
  staged_rpms = Dir.glob(File.join(Infra::STAGING_DIR, 'yum', '**', '*.rpm'))
  downloads = Dir.glob(File.join(Infra::STAGING_DIR, 'downloads', '**', '*.{dmg,msi}'))
  abort 'Nothing to verify (no packages in staging/).'.red if staged_debs.empty? && staged_rpms.empty? && downloads.empty?

  # arch:all debs are replicated into every binary-<arch>/Packages in the deployed repo
  # (apt has no shared binary-all index), so expand each one into one verification per
  # arch the dist supports. Per-arch debs map to a single entry. When the dist has an
  # upstream codename alias (e.g. trixie for debian13), verify both forms.
  apt_entries = staged_debs.flat_map do |deb|
    platform = Platform.from_deb(deb) or abort "Cannot parse deb filename: #{deb}".red
    dists = [platform.dist, Platform.codename_for(platform.dist)].compact.uniq
    apt_verify_arches(platform).flat_map do |arch|
      dists.map { |dist| [dist, Infra.component, arch, deb] }
    end
  end
  apt = apt_entries.group_by { |dist, comp, arch, _| [dist, comp, arch] }
                   .map { |key, rows| [*key, rows.map { |_, _, _, deb| deb_name_version(deb) }] }

  yum_staging = File.join(Infra::STAGING_DIR, 'yum')
  rpm = staged_rpms.group_by { |path| File.dirname(path).sub("#{yum_staging}/", '') }
                   .map { |rel_path, paths| [rel_path, paths.map { |path| rpm_name_version(path) }] }
                   .sort

  failures = run_verification(apt: apt, rpm: rpm) + verify_downloads(downloads)
  report_summary(failures, total: total_expected(apt, rpm) + downloads.length)
end

desc 'Verify every package referenced in state/ metadata is actually visible in the deployed repos.'
task :verify_all do
  Infra.setup_aws
  Infra.print_target(:apt_bucket, :yum_bucket)

  apt_base = File.join(Infra::STATE_DIR, 'apt', 'dists')
  apt_rows = Dir.glob(File.join(apt_base, '*', '*', 'binary-*', 'Packages')).map do |packages_file|
    parts = packages_file.sub("#{apt_base}/", '').split('/')
    [parts[0], parts[1], parts[2].sub('binary-', ''), parse_apt_packages(packages_file)]
  end
  apt = apt_rows.sort_by { |dist, comp, arch, _| [dist, comp, arch] }

  yum_base = File.join(Infra::STATE_DIR, 'yum')
  rpm = Dir.glob(File.join(yum_base, '**', 'repodata', '*primary.xml.gz'))
           .map { |primary| [File.dirname(primary, 2).sub("#{yum_base}/", ''), parse_yum_packages(primary)] }
           .sort

  abort "Nothing to verify (no metadata under #{Infra::STATE_DIR}).".red if apt.empty? && rpm.empty?

  failures = run_verification(apt: apt, rpm: rpm)
  report_summary(failures, total: total_expected(apt, rpm))
end

# Dispatch each non-empty repo type to its verifier inside the appropriate
# container. Returns the accumulated [String] failures.
def run_verification(apt:, rpm:)
  yum, zypper = rpm.partition { |rel_path, _| !rel_path.include?('/sles/') }
  failures = []

  unless apt.empty?
    failures += with_verify_container(
      name: 'verify-apt', image: Infra::CONTAINER_TAG,
      setup: [
        'rm -f /etc/apt/sources.list && rm -rf /etc/apt/sources.list.d/*',
        "cp #{Infra::CONTAINER_WORK}/files/repo_packages/keys/openvox-keyring.gpg /usr/share/keyrings/openvox.gpg",
      ]
    ) { |container| verify_apt_repos(container, apt) }
  end

  unless yum.empty?
    failures += with_verify_container(
      name: 'verify-yum', image: 'almalinux:9',
      setup: ["rpm --import #{GPG_KEY_PATH_IN_CONTAINER}"]
    ) { |container| verify_yum_repos(container, yum) }
  end

  unless zypper.empty?
    failures += with_verify_container(
      name: 'verify-zypper', image: 'registry.suse.com/suse/sle15:15.5',
      setup: [
        'rm -f /etc/zypp/repos.d/*.repo /etc/zypp/services.d/*.service',
        "rpm --import #{GPG_KEY_PATH_IN_CONTAINER}",
      ]
    ) { |container| verify_zypper_repos(container, zypper) }
  end

  failures
end

def total_expected(apt, rpm)
  apt.sum { |row| row.last.length } + rpm.sum { |row| row.last.length }
end

# Per-package S3 ls check for dmg/msi downloads is verify only.
# Returns [String] failures.
def verify_downloads(downloads)
  return [] if downloads.empty?

  puts 'Verifying downloads...'.magenta
  downloads.filter_map do |pkg|
    rel_path = pkg.sub("#{Infra::STAGING_DIR}/downloads/", '')
    s3_path = "#{Infra.downloads_bucket}/#{rel_path}"
    result = Shell.capture([*Infra.s3_cmd, 'ls', s3_path], allowed_exit_codes: [0, 1])
    if result.exitcode.zero?
      puts "  downloads: #{rel_path} found on S3".green
      next
    end

    failure = "downloads #{rel_path}: NOT FOUND at #{s3_path}"
    puts "  #{failure}".red
    failure
  end
end

def report_summary(failures, total:)
  if failures.empty?
    puts "Verification passed: all #{total} checks succeeded.".green
  else
    abort "Verification failed: #{failures.length} of #{total} checks failed.".red
  end
end

# ---------------------------------------------------------------------------
# Filename and metadata parsers
# ---------------------------------------------------------------------------

# Parse the name and version out of a staged .deb filename
# (e.g., "openvox-agent_8.27.0-1+debian12_arm64.deb").
def deb_name_version(path)
  parts = File.basename(path, '.deb').split('_')
  abort "Cannot parse deb filename: #{path}".red unless parts.length == 3

  { name: parts[0], version: parts[1] }
end

# Arches to verify a staged deb against. Arch-specific debs verify against their
# own arch. arch:all debs are replicated into every binary-<arch>/Packages by
# prepare, so they must be verified through every arch the dist supports in state.
def apt_verify_arches(platform)
  return [platform.arch] unless platform.arch == 'all'

  comp_dir = File.join(Infra::STATE_DIR, 'apt', 'dists', platform.dist, Infra.component)
  abort "Cannot expand arch:all deb for #{platform.dist}/#{Infra.component}: no state metadata at #{comp_dir}.".red unless Dir.exist?(comp_dir)

  arches = Dir.children(comp_dir).filter_map do |child|
    child.sub('binary-', '') if child.start_with?('binary-') && File.directory?(File.join(comp_dir, child))
  end
  abort "No binary-<arch> directories under #{comp_dir}; cannot expand arch:all deb.".red if arches.empty?

  arches
end

# Parse the name and version out of a staged .rpm filename
# (e.g., "openvox-agent-8.27.0-1.el9.x86_64.rpm"). RPM names may contain
# dashes, but versions and releases never do, so split NVR from the right.
def rpm_name_version(path)
  basename = File.basename(path, '.rpm')
  match = basename.match(/\A(.+)-([^-]+)-([^-]+)\.[^.]+\z/)
  abort "Cannot parse rpm filename: #{path}".red unless match

  { name: match[1], version: "#{match[2]}-#{match[3]}" }
end

# Yield [name, version] for each Package/Version stanza in `lines` (any object
# that responds to each_line: a File, a String, etc.). Shared between
# parse_apt_packages (state metadata) and parse_apt_cache_show (pkg-mgr output).
def each_rfc822_pkg_version(lines)
  name = nil
  version = nil
  lines.each_line do |line|
    if (match = line.match(/^Package:\s*(\S+)/))
      name = match[1]
    elsif (match = line.match(/^Version:\s*(\S+)/))
      version = match[1]
    elsif line.strip.empty?
      yield(name, version) if name && version
      name = version = nil
    end
  end
  yield(name, version) if name && version
end

def parse_apt_packages(packages_file)
  packages = []
  File.open(packages_file) do |file|
    each_rfc822_pkg_version(file) { |name, version| packages << { name: name, version: version } }
  end
  packages
end

def parse_yum_packages(primary_xml_gz)
  content = Zlib::GzipReader.open(primary_xml_gz, &:read)
  packages = []
  content.scan(%r{<package[^>]*>(.*?)</package>}m).each do |captures|
    block = captures.first
    name = block[%r{<name>([^<]+)</name>}, 1]
    version_tag = block[%r{<version\b[^/]*/>}]
    next unless name && version_tag

    epoch = version_tag[/\bepoch="([^"]*)"/, 1]
    ver = version_tag[/\bver="([^"]*)"/, 1]
    rel = version_tag[/\brel="([^"]*)"/, 1]
    next unless ver && rel

    version = epoch.to_i.zero? ? "#{ver}-#{rel}" : "#{epoch}:#{ver}-#{rel}"
    packages << { name: name, version: version }
  end
  packages
end

# ---------------------------------------------------------------------------
# Per-repo verifiers (each returns [String] failures for the whole batch)
# ---------------------------------------------------------------------------

def verify_apt_repos(container, repos)
  puts "Verifying #{repos.length} apt repos...".magenta
  apt_url = Infra.apt_bucket.sub('s3://', "#{Infra::S3_ENDPOINT}/")
  repos.flat_map do |dist, component, arch, packages|
    label = "#{dist}/#{component}/#{arch}"
    sources_line = "deb [signed-by=/usr/share/keyrings/openvox.gpg arch=#{arch}] #{apt_url} #{dist} #{component}"
    container.exec("printf '%s\\n' #{Shellwords.shellescape(sources_line)} > /etc/apt/sources.list.d/openvox.list")
    container.exec('apt-get clean && rm -rf /var/lib/apt/lists/*')
    container.exec('apt-get update')
    names = packages.map { |pkg| Shellwords.shellescape(pkg[:name]) }.uniq.join(' ')
    result = container.capture("apt-cache show #{names}", allowed_exit_codes: [0, 100])

    report_pkg_results('apt', label, packages, parse_apt_cache_show(result.output))
  rescue SystemExit
    record_repo_error('apt', label, packages)
  ensure
    container.exec('rm -f /etc/apt/sources.list.d/openvox.list', allowed_exit_codes: [0, 1])
  end
end

def verify_yum_repos(container, repos)
  puts "Verifying #{repos.length} yum repos...".magenta
  repos.flat_map do |rel_path, packages|
    # The container runs x86_64, so --forcearch is required for dnf to query metadata
    # in aarch64/ppc64le repos and to key its cache to the same arch on every dnf call.
    # src rpms are arch-agnostic, so we skip --forcearch for src dirs.
    arch = rel_path.split('/').last
    dnf = arch == 'src' ? 'dnf' : "dnf --forcearch=#{arch}"
    write_rpm_repo_file(container, '/etc/yum.repos.d/openvox-verify.repo', rel_path)
    container.exec("#{dnf} clean all --disablerepo='*' --enablerepo=openvox-verify")
    container.exec("#{dnf} makecache --disablerepo='*' --enablerepo=openvox-verify")
    names = packages.map { |pkg| Shellwords.shellescape(pkg[:name]) }.uniq.join(' ')
    # dnf info / dnf list each show only the "best" version per name. dnf
    # repoquery returns every version by default; --queryformat sidesteps the
    # column-wrap that breaks dnf list when stdout is piped.
    query_format = '%{name} %{evr}\n' # rubocop:disable Style/FormatStringToken
    result = container.capture(
      "#{dnf} --quiet --disablerepo='*' --enablerepo=openvox-verify repoquery " \
      "--queryformat=#{Shellwords.shellescape(query_format)} #{names}",
      allowed_exit_codes: [0, 1]
    )

    report_pkg_results('yum', rel_path, packages, parse_dnf_repoquery(result.output))
  rescue SystemExit
    record_repo_error('yum', rel_path, packages)
  end
end

def verify_zypper_repos(container, repos)
  puts "Verifying #{repos.length} zypper repos...".magenta
  repos.flat_map do |rel_path, packages|
    arch = rel_path.split('/').last
    zypp_env = "ZYPP_CONF=/tmp/zypp-#{arch}.conf"
    container.exec("printf '[main]\\narch = #{arch}\\n' > /tmp/zypp-#{arch}.conf")
    container.exec("#{zypp_env} zypper removerepo openvox-verify", allowed_exit_codes: [0, 6])
    write_rpm_repo_file(container, '/etc/zypp/repos.d/openvox-verify.repo', rel_path)
    container.exec("#{zypp_env} zypper refresh openvox-verify")
    names = packages.map { |pkg| Shellwords.shellescape(pkg[:name]) }.uniq.join(' ')
    # `zypper info` only shows the best version per name. `search --match-exact
    # --details` lists every version across every repo in a pipe-delimited table.
    result = container.capture(
      "#{zypp_env} zypper search --match-exact --details #{names}",
      allowed_exit_codes: [0, 104]
    )

    report_pkg_results('zypper', rel_path, packages, parse_zypper_search(result.output))
  rescue SystemExit
    record_repo_error('zypper', rel_path, packages)
  end
end

# ---------------------------------------------------------------------------
# Shared verify helpers
# ---------------------------------------------------------------------------

def write_rpm_repo_file(container, dest, rel_path)
  yum_url = Infra.yum_bucket.sub('s3://', "#{Infra::S3_ENDPOINT}/")
  repo_content = [
    '[openvox-verify]',
    'name=OpenVox Verify',
    "baseurl=#{yum_url}/#{rel_path}",
    'gpgcheck=1',
    "gpgkey=file://#{GPG_KEY_PATH_IN_CONTAINER}",
    'enabled=1',
  ].join("\n")
  container.exec("printf '%s\\n' #{Shellwords.shellescape(repo_content)} > #{dest}")
end

# Print per-package found/NOT found lines. Returns [String] failures for the
# packages that were missing.
def report_pkg_results(type, label, expected, actual)
  expected.filter_map do |pkg|
    if actual.include?([pkg[:name], pkg[:version]])
      puts "  #{type}: #{pkg[:name]} #{pkg[:version]} found in #{label}".green
      nil
    else
      puts "  #{type}: #{pkg[:name]} #{pkg[:version]} NOT found in #{label}".red
      "#{type} #{label}: #{pkg[:name]} #{pkg[:version]}"
    end
  end
end

# Print whole-repo error line. Returns [String] failures (every expected
# package, marked as a repo error).
def record_repo_error(type, label, packages)
  puts "  #{type}: verification failed for #{label}".red
  packages.map { |pkg| "#{type} #{label}: #{pkg[:name]} #{pkg[:version]} (repo error)" }
end

# ---------------------------------------------------------------------------
# Package-manager output parsers
# ---------------------------------------------------------------------------

def parse_apt_cache_show(output)
  result = Set.new
  each_rfc822_pkg_version(output) { |name, version| result << [name, version] }
  result
end

def parse_dnf_repoquery(output)
  result = Set.new
  output.each_line do |line|
    if (match = line.strip.match(/^(\S+)\s+(\S+)$/))
      result << [match[1], match[2]]
    end
  end
  result
end

# Pipe-delimited table:
#   S | Name          | Type    | Version        | Arch    | Repository
#   --+---------------+---------+----------------+---------+---------------
#     | openvox-agent | package | 8.0.0-1.sles15 | x86_64  | openvox-verify
# Locate Name/Version columns from the header row rather than hardcoded index.
def parse_zypper_search(output)
  result = Set.new
  name_idx = nil
  version_idx = nil
  header_len = nil
  output.each_line do |line|
    line = line.strip
    next if line.empty? || line.match?(/^[-+]+$/) || !line.include?('|')

    cells = line.split('|').map(&:strip)
    if name_idx.nil?
      next unless cells.include?('Name') && cells.include?('Version')

      name_idx = cells.index('Name')
      version_idx = cells.index('Version')
      header_len = cells.length
      next
    end
    next unless cells.length == header_len

    name = cells[name_idx]
    version = cells[version_idx]
    result << [name, version] unless name.empty? || version.empty?
  end
  result
end

# ---------------------------------------------------------------------------
# Container
# ---------------------------------------------------------------------------

# Start a fresh container, run the per-type setup commands, yield it, and
# always teardown. Returns whatever the block returns.
def with_verify_container(name:, image:, setup:)
  container = Container.new(name: name, image: image)
  begin
    container.start(command: 'sleep infinity', volumes: { Infra::REPO_ROOT => Infra::CONTAINER_WORK })
    setup.each { |cmd| container.exec(cmd) }
    yield container
  ensure
    container.teardown
  end
end
