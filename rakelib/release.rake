# frozen_string_literal: true

require 'fileutils'
require_relative 'lib/repo/apt'
require_relative 'lib/repo/macos'
require_relative 'lib/repo/windows'
require_relative 'lib/repo/yum'
require_relative 'lib/utils/infra'
require_relative 'lib/utils/platform'
require_relative 'lib/utils/shell'

def s3_includes(filters)
  patterns = %w[*.rpm *.deb *.dmg *.msi]

  if filters
    patterns = []
    filters.each do |filter|
      platform = Platform.from_filter(filter)
      abort "Malformed platform filter '#{filter}' (expected os-ver-arch, e.g. el-9-x86_64)".red unless platform

      [platform.os, platform.version, platform.arch].each { |part| Infra.validate_input("PLATFORMS component '#{part}'", part) }
      patterns.concat(platform.s3_globs)
    end
  end

  patterns.flat_map { |pattern| ['--include', pattern] }
end

def fetch_packages
  source = "s3://#{Infra::ARTIFACTS_BUCKET}/#{Infra.project}/#{Infra.version}/"
  filters = Infra.env('PLATFORMS')&.split(',')&.map(&:strip)&.reject(&:empty?)

  types = %w[rpm deb dmg msi]
  types.each { |dir| FileUtils.mkdir_p(File.join(Infra::PACKAGES_DIR, dir)) }

  Shell.run([*Infra.s3_sync, source, "#{Infra::PACKAGES_DIR}/", '--exclude', '*', *s3_includes(filters)])

  types.each do |type|
    Dir.glob(File.join(Infra::PACKAGES_DIR, "*.#{type}")).each do |pkg|
      FileUtils.mv(pkg, File.join(Infra::PACKAGES_DIR, type))
    end
  end

  counts = types.to_h { |type| [type.to_sym, Dir.glob(File.join(Infra::PACKAGES_DIR, type, "*.#{type}")).size] }
  puts "Downloaded: #{pluralize(counts[:rpm], 'RPM')}, #{pluralize(counts[:deb], 'DEB')}, " \
       "#{pluralize(counts[:dmg], 'DMG')}, #{pluralize(counts[:msi], 'MSI')}".magenta
  puts "No packages found at #{source} for the given platform filters.".yellow if counts.values.sum.zero?
  counts
end

# Windows and macOS packages are staged under downloads/<os>/<component>/
def downloads_version_dirs
  Dir.glob(File.join(Infra::STAGING_DIR, 'downloads', '*', Infra.component)).select { |dir| File.directory?(dir) }
end

def write_version_files(dirs)
  (dirs + downloads_version_dirs).uniq.each do |dir|
    File.write(File.join(dir, "VERSION-#{Infra.project}"), "#{Infra.version}\n")
  end
end

desc 'Download, sign, and prepare repo metadata'
task :release do
  Infra.setup_aws
  Infra.print_target(:apt_bucket, :yum_bucket, :downloads_bucket)

  Infra.force_remove(Infra::PACKAGES_DIR)
  Infra.force_remove(Infra::STAGING_DIR)
  FileUtils.mkdir_p(Infra::PACKAGES_DIR)
  FileUtils.mkdir_p(Infra::STAGING_DIR)

  puts "Releasing #{Infra.project} #{Infra.version} to #{Infra.component}".magenta

  counts = fetch_packages
  if counts.values.sum.zero?
    puts 'Nothing to release'.yellow
    next
  end
  sign_rpm = counts[:rpm].positive?
  sign_deb = counts[:deb].positive?
  sign_dmg = counts[:dmg].positive?
  sign_msi = counts[:msi].positive?

  # Env var validation
  if sign_dmg && !RUBY_PLATFORM.include?('darwin')
    puts 'MacOS packages must be signed on a MacOS host. Signing of these packages will be skipped.'.yellow
    sign_dmg = false
  end
  Infra.env('GPG_PRIVATE_KEY_B64', required: true) if sign_rpm || sign_deb

  # Sign packages, prepare packages and repo metadata in staging/, then
  # move updated metadata to state/ for commit.
  version_dirs = []
  container_env_vars = []
  container_env_vars << 'GPG_PRIVATE_KEY_B64' if sign_rpm || sign_deb
  container_env_vars.concat(Windows::ENV_VARS) if sign_msi
  container = Infra.start_container(env_vars: container_env_vars) if sign_rpm || sign_deb || sign_msi
  begin
    Infra.import_gpg_key(container) if sign_rpm || sign_deb

    if sign_rpm
      yum = Yum.new(container)
      yum.sign
      yum.prepare
      Yum.update_state
      version_dirs.concat(yum.affected_dirs)
    end

    if sign_deb
      apt = Apt.new(container)
      apt.sign
      apt.prepare
      Apt.update_state
      version_dirs.concat(apt.affected_dirs)
    end

    if sign_msi
      windows = Windows.new(container)
      windows.setup_signing
      windows.sign
      windows.prepare
    end
  ensure
    Infra.teardown_with_chown(container)
  end

  if sign_dmg
    begin
      MacOS.setup_signing
      MacOS.sign
      MacOS.prepare
    ensure
      MacOS.teardown_signing
    end
  end

  write_version_files(version_dirs) if Infra.create_version_file?

  Infra.commit_state("Release: #{Infra.project} #{Infra.version} (#{Infra.component})") if Infra.production?
  puts 'Release complete. Run `bundle exec rake deploy` to push to S3.'.green
end
