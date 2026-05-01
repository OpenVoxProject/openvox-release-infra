# frozen_string_literal: true

require 'fileutils'
require_relative 'lib/utils/infra'

desc 'Verify packages are accessible and GPG-signed in the deployed repos'
task :verify do
  Infra.setup_aws

  project = Infra.project
  version = Infra.version
  component = Infra.component

  apt_url = Infra.apt_bucket.sub('s3://', "#{Infra::S3_ENDPOINT}/")
  yum_url = Infra.yum_bucket.sub('s3://', "#{Infra::S3_ENDPOINT}/")
  gpg_key_file = File.join(Infra::REPO_ROOT, 'openvox-gpg.key')

  verified = 0
  failed = 0

  staging_dists = File.join(Infra::STAGING_DIR, 'apt', 'dists')
  yum_staging = File.join(Infra::STAGING_DIR, 'yum')
  needs_gpg = Dir.exist?(staging_dists) || Dir.exist?(yum_staging)

  if needs_gpg
    Infra.require_env('GPG_PRIVATE_KEY_B64')

    container = Infra.start_container
    begin
      Infra.import_gpg_key(container)
      container.exec("gpg --export --armor '#{Infra::GPG_KEY_ID}' > #{Infra::CONTAINER_WORK}/openvox-gpg.key")

      if Dir.exist?(staging_dists)
        codenames = Dir.children(staging_dists).select { |child| File.directory?(File.join(staging_dists, child)) }
        if codenames.any?
          puts 'Verifying apt repos...'.magenta
          container.exec('rm -f /etc/apt/sources.list && rm -rf /etc/apt/sources.list.d/*')
          container.exec("gpg --export '#{Infra::GPG_KEY_ID}' > /usr/share/keyrings/openvox.gpg")

          codenames.each do |codename|
            if verify_apt_codename(container, project, version, component, apt_url, codename)
              verified += 1
            else
              failed += 1
            end
          end
        end
      end
    ensure
      begin
        container.teardown
      rescue StandardError => e
        warn "WARNING: teardown also failed: #{e.message}".yellow
      end
    end

    if Dir.exist?(yum_staging)
      all_repo_dirs = Dir.glob(File.join(yum_staging, '**', 'repodata')).map { |path| File.dirname(path) }
      sles_repo_dirs, yum_repo_dirs = all_repo_dirs.partition { |dir| dir.include?('/sles/') }

      if yum_repo_dirs.any?
        puts 'Verifying yum repos...'.magenta
        yum_container = Container.new(name: 'verify-yum', image: 'almalinux:9')
        begin
          yum_container.start(command: 'sleep infinity', volumes: { Infra::REPO_ROOT => Infra::CONTAINER_WORK })
          yum_container.exec("rpm --import #{Infra::CONTAINER_WORK}/openvox-gpg.key")

          yum_repo_dirs.each do |repo_dir|
            rel_path = repo_dir.sub("#{yum_staging}/", '')
            repo_url = "#{yum_url}/#{rel_path}"
            if verify_yum_repo(yum_container, project, version, repo_url, rel_path)
              verified += 1
            else
              failed += 1
            end
          end
        ensure
          begin
            yum_container.teardown
          rescue StandardError => e
            warn "WARNING: teardown also failed: #{e.message}".yellow
          end
        end
      end

      if sles_repo_dirs.any?
        puts 'Verifying zypper repos...'.magenta
        sles_container = Container.new(name: 'verify-sles', image: 'registry.suse.com/suse/sle15:15.5')
        begin
          sles_container.start(command: 'sleep infinity', volumes: { Infra::REPO_ROOT => Infra::CONTAINER_WORK })
          sles_container.exec('rm -f /etc/zypp/repos.d/*.repo /etc/zypp/services.d/*.service')
          sles_container.exec("rpm --import #{Infra::CONTAINER_WORK}/openvox-gpg.key")

          sles_repo_dirs.each do |repo_dir|
            rel_path = repo_dir.sub("#{yum_staging}/", '')
            repo_url = "#{yum_url}/#{rel_path}"
            if verify_zypper_repo(sles_container, project, version, repo_url, rel_path)
              verified += 1
            else
              failed += 1
            end
          end
        ensure
          begin
            sles_container.teardown
          rescue StandardError => e
            warn "WARNING: teardown also failed: #{e.message}".yellow
          end
        end
      end
    end

    FileUtils.rm_f(gpg_key_file)
  end

  downloads = Dir.glob(File.join(Infra::STAGING_DIR, 'downloads', '**', '*.{dmg,msi}'))
  if downloads.any?
    puts 'Verifying downloads...'.magenta
    downloads.each do |pkg|
      rel_path = pkg.sub("#{Infra::STAGING_DIR}/downloads/", '')
      s3_path = "#{Infra.downloads_bucket}/#{rel_path}"
      result = Shell.capture("#{Infra.s3_cmd} ls #{s3_path}", allowed_exit_codes: [0, 1])
      if result.exitcode.zero?
        puts "  download: #{File.basename(pkg)} found on S3".green
        verified += 1
      else
        puts "  download: #{File.basename(pkg)} NOT FOUND at #{s3_path}".red
        failed += 1
      end
    end
  end

  if verified.zero? && failed.zero?
    puts 'Nothing to verify (staging/ empty or missing).'.yellow
  elsif failed.positive?
    abort "Verification failed: #{verified} passed, #{failed} failed.".red
  else
    puts "Verification passed: #{verified} checks.".green
  end
end

def verify_apt_codename(container, project, version, component, apt_url, codename)
  sources_line = "deb [signed-by=/usr/share/keyrings/openvox.gpg] #{apt_url} #{codename} #{component}"
  container.exec("echo '#{sources_line}' > /etc/apt/sources.list.d/openvox.list")
  container.exec('apt-get clean && rm -rf /var/lib/apt/lists/*')
  container.exec('apt-get update')
  result = container.capture("apt-cache show #{project}", allowed_exit_codes: [0, 1])
  container.exec('rm -f /etc/apt/sources.list.d/openvox.list')

  if result.output.include?(version)
    puts "  apt: #{project} #{version} found in #{codename}".green
    true
  else
    puts "  apt: #{project} #{version} NOT found in #{codename}".red
    false
  end
rescue SystemExit
  container.exec('rm -f /etc/apt/sources.list.d/openvox.list', allowed_exit_codes: [0, 1])
  puts "  apt: verification failed for #{codename}".red
  false
end

def verify_yum_repo(container, project, version, repo_url, rel_path)
  repo_content = [
    '[openvox-verify]',
    'name=OpenVox Verify',
    "baseurl=#{repo_url}",
    'gpgcheck=1',
    "gpgkey=file://#{Infra::CONTAINER_WORK}/openvox-gpg.key",
    'enabled=1',
  ].join("\n")

  container.exec("printf '%s\\n' '#{repo_content}' > /etc/yum.repos.d/openvox-verify.repo")
  container.exec("dnf clean all --disablerepo='*' --enablerepo=openvox-verify")
  container.exec("dnf makecache --disablerepo='*' --enablerepo=openvox-verify")
  result = container.capture(
    "dnf info --disablerepo='*' --enablerepo=openvox-verify #{project}",
    allowed_exit_codes: [0, 1]
  )

  if result.output.include?(version)
    puts "  yum: #{project} #{version} found in #{rel_path}".green
    true
  else
    puts "  yum: #{project} #{version} NOT found in #{rel_path}".red
    false
  end
rescue SystemExit
  puts "  yum: verification failed for #{rel_path}".red
  false
end

def verify_zypper_repo(container, project, version, repo_url, rel_path)
  container.exec('zypper removerepo openvox-verify', allowed_exit_codes: [0, 6])

  repo_content = [
    '[openvox-verify]',
    'name=OpenVox Verify',
    "baseurl=#{repo_url}",
    'gpgcheck=1',
    "gpgkey=file://#{Infra::CONTAINER_WORK}/openvox-gpg.key",
    'enabled=1',
  ].join("\n")
  container.exec("printf '%s\\n' '#{repo_content}' > /etc/zypp/repos.d/openvox-verify.repo")

  container.exec('zypper refresh openvox-verify')
  result = container.capture(
    "zypper search --match-exact --details #{project}",
    allowed_exit_codes: [0, 104]
  )

  if result.exitcode == 104 || !result.output.include?(version)
    puts "  zypper: #{project} #{version} NOT found in #{rel_path}".red
    false
  else
    puts "  zypper: #{project} #{version} found in #{rel_path}".green
    true
  end
rescue SystemExit
  container.exec('zypper removerepo openvox-verify', allowed_exit_codes: [0, 6])
  puts "  zypper: verification failed for #{rel_path}".red
  false
end
