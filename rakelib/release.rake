# frozen_string_literal: true

require 'fileutils'
require_relative 'lib/repo/apt'
require_relative 'lib/repo/yum'
require_relative 'lib/repo/macos'
require_relative 'lib/repo/windows'
require_relative 'lib/utils/infra'

def s3_includes(filters)
  patterns = %w[*.rpm *.deb *.dmg *.msi]

  if filters
    patterns = []
    filters.each do |filter|
      os, ver, arch = filter.split('-', 3)
      unless os && ver && arch
        puts "Skipping malformed platform filter '#{filter}' (expected os-ver-arch, e.g. el-9-x86_64)".yellow
        next
      end

      [os, ver, arch].each { |part| Infra.validate_input("PLATFORMS component '#{part}'", part) }

      case os
      when 'macos'
        patterns << "*#{arch}*.dmg"
      when 'windows'
        patterns << '*.msi'
      else
        dist_tag = os == 'fedora' ? 'fc' : os
        patterns << "*.#{dist_tag}#{ver}.#{arch}.rpm"
        patterns << "*.#{dist_tag}#{ver}.noarch.rpm"
        patterns << "*+#{os}#{ver}_#{arch}.deb"
        patterns << "*+#{os}#{ver}_all.deb"
      end
    end
    abort "No valid platform filters in PLATFORMS: #{filters.join(', ')}".red if patterns.empty?
  end

  patterns.map { |p| "--include '#{p}'" }.join(' ')
end

def fetch_packages
  source = "s3://#{Infra::ARTIFACTS_BUCKET}/#{Infra.project}/#{Infra.version}/"
  filters = ENV['PLATFORMS']&.split(',')&.map(&:strip)

  types = %w[rpm deb dmg msi]
  types.each { |dir| FileUtils.mkdir_p(File.join(Infra::PACKAGES_DIR, dir)) }

  Shell.run("#{Infra.s3_cmd} sync #{source} #{Infra::PACKAGES_DIR}/ --exclude '*' #{s3_includes(filters)}")

  types.each do |type|
    Dir.glob(File.join(Infra::PACKAGES_DIR, "*.#{type}")).each do |pkg|
      FileUtils.mv(pkg, File.join(Infra::PACKAGES_DIR, type))
    end
  end

  counts = types.to_h { |type| [type.to_sym, Dir.glob(File.join(Infra::PACKAGES_DIR, type, "*.#{type}")).size] }
  puts "Downloaded: #{pluralize(counts[:rpm], 'RPM')}, #{pluralize(counts[:deb], 'DEB')}, " \
       "#{pluralize(counts[:dmg], 'DMG')}, #{pluralize(counts[:msi], 'MSI')}".magenta
  abort "No packages found at #{source} for the given platform filters.".red if counts.values.sum.zero?
  counts
end

desc 'Download, sign, and prepare repo metadata'
task :release do
  Infra.setup_aws

  FileUtils.rm_rf(Infra::PACKAGES_DIR)
  FileUtils.rm_rf(Infra::STAGING_DIR)
  FileUtils.mkdir_p(Infra::PACKAGES_DIR)
  FileUtils.mkdir_p(Infra::STAGING_DIR)

  puts "Releasing #{Infra.project} #{Infra.version} to #{Infra.component}".magenta

  counts = fetch_packages
  sign_rpm = counts[:rpm].positive?
  sign_deb = counts[:deb].positive?
  sign_dmg = counts[:dmg].positive?
  sign_msi = counts[:msi].positive?

  # Env var validation
  if sign_dmg && !RUBY_PLATFORM.include?('darwin')
    puts 'MacOS packages must be signed on a MacOS host. Signing of these packages will be skipped.'.yellow
    sign_dmg = false
  end
  Infra.require_env(%w[SM_API_KEY SM_HOST SM_CLIENT_CERT_B64 SM_CLIENT_CERT_PASSWORD CERT_ALIAS]) if sign_msi
  Infra.require_env('GPG_PRIVATE_KEY_B64') if sign_rpm || sign_deb

  # Sign packages, prepare packages and repo metadata in staging/, then
  # move updated metadata to state/ for commit.
  container = Infra.start_container if sign_rpm || sign_deb || sign_msi
  begin
    Infra.import_gpg_key(container) if sign_rpm || sign_deb

    if sign_rpm
      yum = Yum.new(container)
      yum.sign
      yum.prepare
      Yum.update_state
    end

    if sign_deb
      apt = Apt.new(container)
      apt.sign
      apt.prepare
      Apt.update_state
    end

    if sign_msi
      windows = Windows.new(container)
      windows.sign
      windows.prepare
    end
  ensure
    container&.teardown
  end

  if sign_dmg
    begin
      Infra.setup_macos_signing
      MacOS.sign
      MacOS.prepare
    ensure
      Infra.teardown_macos_signing
    end
  end

  Infra.commit_state("Release: #{Infra.project} #{Infra.version} (#{Infra.component})")
  puts 'Release complete. Run `rake deploy` to push to S3.'.green
end
