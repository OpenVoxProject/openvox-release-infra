# frozen_string_literal: true

require 'erb'
require 'fileutils'
require 'json'
require 'shellwords'
require_relative 'utils/infra'

module RepoPackages
  FILES_DIR     = File.join(Infra::REPO_ROOT, 'files', 'repo_packages')
  TEMPLATES_DIR = File.join(FILES_DIR, 'templates')
  KEYS_DIR      = File.join(FILES_DIR, 'keys')

  RPM_OUT        = File.join(Infra::STAGING_DIR, 'yum')
  DEB_OUT        = File.join(Infra::STAGING_DIR, 'apt')
  REPO_FILES_OUT = File.join(Infra::STAGING_DIR, 'yum', 'repo_files')
  LIST_FILES_OUT = File.join(Infra::STAGING_DIR, 'apt', 'list_files')
  BUILD_DIR      = File.join(Infra::STAGING_DIR, 'repo_packages_build')

  module_function

  # Detect if the given platform is an rpm or deb type. If we start
  # supporting new platform types, update this logic as needed.
  def infer_kind(platform)
    os = platform.split('-').first.gsub(/[\d.].*/, '')
    case os
    when 'debian', 'ubuntu' then 'deb'
    else 'rpm'
    end
  end

  def build_and_sign(container)
    FileUtils.rm_rf(Infra::STAGING_DIR)
    [RPM_OUT, DEB_OUT, REPO_FILES_OUT, LIST_FILES_OUT, BUILD_DIR].each { |dir| FileUtils.mkdir_p(dir) }

    # Load package definitions
    package_json_files = Dir.glob(File.join(FILES_DIR, '*.json'))
    abort 'No package JSON files found in files/repo_packages/'.red if package_json_files.empty?
    package_defs = package_json_files.map { |path| JSON.parse(File.read(path)) }

    platform_filter = ENV['PLATFORM']&.split(',')&.map(&:strip)&.reject(&:empty?)
    platform_filter.map! { |entry| normalize_platform(infer_kind(entry), entry) } if platform_filter

    package_defs.each do |package_def|
      puts "Building repo packages for #{package_def['package']}...".magenta
      package_def.fetch('platforms').each do |platform|
        next if platform_filter && !platform_filter.include?(platform)
        build_platform(container, package_def, infer_kind(platform), platform)
      end
    end

    rpms = Dir.glob(File.join(RPM_OUT, '*.rpm'))
    debs = Dir.glob(File.join(DEB_OUT, '*.deb'))
    config_files = Dir.glob(File.join(REPO_FILES_OUT, '*')) + Dir.glob(File.join(LIST_FILES_OUT, '*'))
    puts "Built #{pluralize(rpms.size, 'RPM')}, #{pluralize(debs.size, 'DEB')}, " \
         "#{pluralize(config_files.size, 'repo/list file')}".magenta
    abort 'No packages were built. Check the package JSON files.'.red if rpms.empty? && debs.empty?

    puts 'Signing RPMs...'.magenta unless rpms.empty?
    rpms.each { |rpm| Infra.sign_rpm(container, rpm) }

    puts 'Signing DEBs...'.magenta unless debs.empty?
    debs.each { |deb| Infra.sign_deb(container, deb) }

    puts 'Signing config files...'.magenta unless config_files.empty?
    config_files.each { |file| Infra.gpg_detach_sign(container, file) }

    FileUtils.rm_rf(BUILD_DIR)
    puts 'Build and sign complete.'.green
  end

  def upload
    abort 'No build output found. Run `bundle exec rake repo_packages:build` first.'.red unless Dir.exist?(Infra::STAGING_DIR)

    Infra.setup_aws
    uploaded = 0
    skipped = 0

    [
      [Dir.glob(File.join(RPM_OUT, '*.rpm')), Infra.yum_bucket],
      [Dir.glob(File.join(DEB_OUT, '*.deb')), Infra.apt_bucket],
      [Dir.glob(File.join(REPO_FILES_OUT, '{*.repo,*.repo.asc}')), "#{Infra.yum_bucket}/repo_files"],
      [Dir.glob(File.join(LIST_FILES_OUT, '{*.list,*.list.asc,*.pref,*.pref.asc}')), "#{Infra.apt_bucket}/list_files"],
    ].each do |files, destination|
      files.each do |local|
        remote = "#{destination}/#{File.basename(local)}"
        upload_artifact(local, remote) ? uploaded += 1 : skipped += 1
      end
    end

    puts "Upload complete: #{pluralize(uploaded, 'file')} uploaded, " \
         "#{pluralize(skipped, 'file')} skipped.".green
  end

  def add_platform
    component = Infra.component
    raw_list = Infra.require_env('PLATFORM').split(',').map(&:strip).reject(&:empty?)
    abort 'PLATFORM must not be empty.'.red if raw_list.empty?
    raw_list.each { |entry| Infra.validate_input('PLATFORM', entry) }

    package_json_path = File.join(FILES_DIR, "#{component}.json")
    abort "No definition file at #{package_json_path}".red unless File.exist?(package_json_path)
    data = JSON.parse(File.read(package_json_path))
    platforms = data.fetch('platforms')

    normalized_list = raw_list.map { |entry| normalize_platform(infer_kind(entry), entry) }.uniq

    added = []
    normalized_list.each do |normalized|
      if platforms.include?(normalized)
        puts "  #{normalized} already present, skipping".yellow
      else
        puts "  Adding #{normalized}".green
        platforms << normalized
        added << normalized
      end
    end

    abort 'All platforms already present. Nothing to add.'.red if added.empty?
    platforms.sort_by! { |plat| [plat[/\D+/], Gem::Version.new(plat[/[\d.]+/])] }
    File.write(package_json_path, JSON.pretty_generate(data) + "\n")

    label = added.size == 1 ? added.first : "#{added.size} platforms"
    Dir.chdir(Infra::REPO_ROOT) do
      Shell.run(['git', 'add', package_json_path])
      Shell.run(['git', 'commit', '-s', '-m',
                 "openvox-release packages: add #{label} to #{component}", '--', package_json_path])
    end
    puts 'Committed locally. Push manually when ready.'.green
  end

  # Normalizes to the format stored in JSON regardless of input format:
  #   rpm: <os>-<ver> (e.g. el-9, sles-15)
  #   deb: <os><ver>  (e.g. debian13, ubuntu24.04)
  # Accepts: el-9, el9, el-9-x86_64, debian14, debian-14, debian-14-amd64, etc.
  def normalize_platform(kind, platform)
    parts = platform.split('-')
    parts = parts[0..-2] if parts.size >= 3
    match = parts.join.match(/\A([a-z]+)([\d.]+)\z/)
    abort "Cannot parse platform: #{platform}".red unless match

    kind == 'deb' ? "#{match[1]}#{match[2]}" : "#{match[1]}-#{match[2]}"
  end

  def build_platform(container, package_def, kind, platform)
    deb = kind == 'deb'
    pkg_name = package_def['package']
    flat_platform = platform.tr('-', '')

    build_dir, config_file = stage_build_dir(package_def, kind, platform)

    output_dir = deb ? DEB_OUT : RPM_OUT
    output_ext = deb ? '.deb' : '.noarch.rpm'
    output_file = File.join(output_dir, "#{pkg_name}-#{platform}#{output_ext}")

    iteration = deb ? "#{package_def['release']}#{flat_platform}" : "#{package_def['release']}.#{flat_platform}"
    output_type = deb ? 'deb' : 'rpm'
    run_fpm(container, package_def, build_dir, output_file, output_type: output_type, iteration: iteration)

    if deb
      FileUtils.cp(config_file, File.join(LIST_FILES_OUT, "#{pkg_name}-#{flat_platform}.list"))
      install_file(File.join(TEMPLATES_DIR, 'apt.pref'), File.join(LIST_FILES_OUT, 'openvox-release.pref'))
    else
      FileUtils.cp(config_file, File.join(REPO_FILES_OUT, "#{pkg_name}-#{flat_platform}.repo"))
    end
  end

  def stage_build_dir(package_def, kind, platform)
    pkg_name = package_def['package']
    build_dir = File.join(BUILD_DIR, "#{pkg_name}-#{platform}")
    FileUtils.rm_rf(build_dir)

    if kind == 'deb'
      install_file(File.join(KEYS_DIR, 'openvox-keyring.gpg'),
        File.join(build_dir, 'etc', 'apt', 'keyrings', 'openvox-keyring.gpg'))
      list_path = File.join(build_dir, 'etc', 'apt', 'sources.list.d', "#{pkg_name}.list")
      config_file = install_template('apt.list.erb', list_path, package_def: package_def, codename: platform)
      install_file(File.join(TEMPLATES_DIR, 'apt.pref'),
        File.join(build_dir, 'etc', 'apt', 'preferences.d', 'openvox-release.pref'))
    else
      target_repo = package_def.fetch('target_repo')
      install_file(File.join(KEYS_DIR, 'GPG-KEY-openvox.pub'),
        File.join(build_dir, 'etc', 'pki', 'rpm-gpg', "GPG-KEY-openvox-#{target_repo}-release"))
      os_name, os_version = platform.split('-', 2)
      repo_subdir = os_name == 'sles' ? 'etc/zypp/repos.d' : 'etc/yum.repos.d'
      repo_path = File.join(build_dir, repo_subdir, "#{pkg_name}.repo")
      config_file = install_template('rpm.repo.erb', repo_path,
        package_def: package_def, os_name: os_name, os_version: os_version)
    end

    [build_dir, config_file]
  end

  def install_file(source, dest)
    FileUtils.mkdir_p(File.dirname(dest))
    FileUtils.cp(source, dest)
  end

  def install_template(template_name, dest, **template_vars)
    FileUtils.mkdir_p(File.dirname(dest))
    File.write(dest, render_template(template_name, **template_vars))
    dest
  end

  def render_template(template_name, package_def:, os_name: nil, os_version: nil, codename: nil)
    @template_cache ||= {}
    @template_cache[template_name] ||= ERB.new(File.read(File.join(TEMPLATES_DIR, template_name)), trim_mode: '-')

    target_repo = package_def.fetch('target_repo')
    major = target_repo.gsub(/\D/, '')
    yum_base = Infra.yum_release_package_base
    apt_base = Infra.apt_release_package_base

    @template_cache[template_name].result(binding)
  end

  def run_fpm(container, package_def, build_dir, output_file, output_type:, iteration:)
    args = [
      'fpm',
      '--input-type', 'dir',
      '--output-type', output_type,
      '--name', Shellwords.shellescape(package_def['package']),
      '--version', Shellwords.shellescape(package_def['version']),
      '--iteration', iteration,
      '--architecture', 'noarch',
      '--license', Shellwords.shellescape(package_def['license']),
      '--vendor', Shellwords.shellescape(package_def['vendor']),
      '--maintainer', Shellwords.shellescape(package_def['vendor']),
      '--url', Shellwords.shellescape(package_def['homepage']),
      '--description', Shellwords.shellescape(package_def['description']),
      '--category', Shellwords.shellescape('System Environment/Base'),
      '--chdir', Infra.container_path(build_dir),
      '--package', Infra.container_path(output_file)
    ]
    output_type == 'rpm' ? args.push('--rpm-digest', 'sha256') : args.push('--config-files', '/etc', '--deb-no-default-config-files')
    args << '.'

    container.exec(args.join(' '))
  end

  def upload_artifact(local, remote)
    unless ENV['FORCE_OVERWRITE'] == 'true'
      result = Shell.capture(
        ['aws', 's3', '--endpoint-url', Infra::S3_ENDPOINT, 'ls', remote],
        allowed_exit_codes: [0, 1, 255], print_command: false
      )
      if result.exitcode.zero? && !result.output.strip.empty?
        puts "  Skipping #{File.basename(local)} (already exists)".yellow
        return false
      end
    end
    Shell.run(['aws', 's3', '--endpoint-url', Infra::S3_ENDPOINT, 'cp', local, remote, '--no-progress'])
    true
  end
end
