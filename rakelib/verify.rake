# frozen_string_literal: true

require 'fileutils'
require_relative 'lib/utils/infra'
require_relative 'lib/utils/shell'

desc 'Verify packages are accessible and GPG-signed in the deployed repos'
task :verify do
  Infra.setup_aws
  Infra.print_target(:apt_bucket, :yum_bucket)

  staged_rpms = Dir.glob(File.join(Infra::STAGING_DIR, 'yum', '**', '*.rpm'))
  staged_debs = Dir.glob(File.join(Infra::STAGING_DIR, 'apt', 'pool', '**', '*.deb'))
  staged_downloads = Dir.glob(File.join(Infra::STAGING_DIR, 'downloads', '**', '*.{dmg,msi}'))

  if staged_rpms.empty? && staged_debs.empty? && staged_downloads.empty?
    abort 'Nothing to verify (no packages in staging/).'.red
  end

  puts "Verifying #{Infra.project} #{Infra.version} (#{Infra.component})...".magenta

  verified = 0
  failed = 0

  staging_pool = File.join(Infra::STAGING_DIR, 'apt', 'pool')
  yum_staging = File.join(Infra::STAGING_DIR, 'yum')

  if Dir.exist?(staging_pool)
    codenames = Dir.glob(File.join(staging_pool, '**', '*.deb'))
                   .map { |deb| File.basename(deb)[/\+([a-z][\w.]+)_/, 1] }
                   .compact.uniq
    if codenames.any?
      puts 'Verifying apt repos...'.magenta
      container = Container.new(name: 'verify-apt', image: Infra::CONTAINER_TAG)
      begin
        container.start(command: 'sleep infinity', volumes: { Infra::REPO_ROOT => Infra::CONTAINER_WORK })
        container.exec('rm -f /etc/apt/sources.list && rm -rf /etc/apt/sources.list.d/*')
        container.exec("cp #{Infra::CONTAINER_WORK}/files/repo_packages/keys/openvox-keyring.gpg /usr/share/keyrings/openvox.gpg")

        codenames.each { |codename| verify_apt_codename(container, codename) ? verified += 1 : failed += 1 }
      ensure
        begin
          container.teardown
        rescue StandardError => e
          warn "WARNING: teardown also failed: #{e.message}".yellow
        end
      end
    end
  end

  if Dir.exist?(yum_staging)
    gpg_key_container_path = "#{Infra::CONTAINER_WORK}/files/repo_packages/keys/GPG-KEY-openvox.pub"
    all_repo_dirs = Dir.glob(File.join(yum_staging, '**', '*.rpm'))
                       .map { |rpm| File.dirname(rpm) }.uniq
    sles_repo_dirs, yum_repo_dirs = all_repo_dirs.partition { |dir| dir.include?('/sles/') }

    if yum_repo_dirs.any?
      puts 'Verifying yum repos...'.magenta
      yum_container = Container.new(name: 'verify-yum', image: 'almalinux:9')
      begin
        yum_container.start(command: 'sleep infinity', volumes: { Infra::REPO_ROOT => Infra::CONTAINER_WORK })
        yum_container.exec("rpm --import #{gpg_key_container_path}")

        yum_repo_dirs.each do |repo_dir|
          rel_path = repo_dir.sub("#{yum_staging}/", '')
          verify_yum_repo(yum_container, rel_path) ? verified += 1 : failed += 1
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
        sles_container.exec("rpm --import #{gpg_key_container_path}")

        sles_repo_dirs.each do |repo_dir|
          rel_path = repo_dir.sub("#{yum_staging}/", '')
          verify_zypper_repo(sles_container, rel_path) ? verified += 1 : failed += 1
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

def verify_apt_codename(container, codename)
  apt_url = Infra.apt_bucket.sub('s3://', "#{Infra::S3_ENDPOINT}/")
  sources_line = "deb [signed-by=/usr/share/keyrings/openvox.gpg] #{apt_url} #{codename} #{Infra.component}"
  container.exec("echo '#{sources_line}' > /etc/apt/sources.list.d/openvox.list")
  container.exec('apt-get clean && rm -rf /var/lib/apt/lists/*')
  container.exec('apt-get update')
  result = container.capture("apt-cache show #{Infra.project}", allowed_exit_codes: [0, 1])
  container.exec('rm -f /etc/apt/sources.list.d/openvox.list')

  if result.output.include?(Infra.version)
    puts "  apt: #{Infra.project} #{Infra.version} found in #{codename}".green
    true
  else
    puts "  apt: #{Infra.project} #{Infra.version} NOT found in #{codename}".red
    false
  end
rescue SystemExit
  container.exec('rm -f /etc/apt/sources.list.d/openvox.list', allowed_exit_codes: [0, 1])
  puts "  apt: verification failed for #{codename}".red
  false
end

def verify_yum_repo(container, rel_path)
  yum_url = Infra.yum_bucket.sub('s3://', "#{Infra::S3_ENDPOINT}/")
  repo_content = [
    '[openvox-verify]',
    'name=OpenVox Verify',
    "baseurl=#{yum_url}/#{rel_path}",
    'gpgcheck=1',
    "gpgkey=file://#{Infra::CONTAINER_WORK}/files/repo_packages/keys/GPG-KEY-openvox.pub",
    'enabled=1',
  ].join("\n")

  container.exec("printf '%s\\n' '#{repo_content}' > /etc/yum.repos.d/openvox-verify.repo")
  container.exec("dnf clean all --disablerepo='*' --enablerepo=openvox-verify")
  container.exec("dnf makecache --disablerepo='*' --enablerepo=openvox-verify")
  result = container.capture(
    "dnf info --disablerepo='*' --enablerepo=openvox-verify #{Infra.project}",
    allowed_exit_codes: [0, 1]
  )

  if result.output.include?(Infra.version)
    puts "  yum: #{Infra.project} #{Infra.version} found in #{rel_path}".green
    true
  else
    puts "  yum: #{Infra.project} #{Infra.version} NOT found in #{rel_path}".red
    false
  end
rescue SystemExit
  puts "  yum: verification failed for #{rel_path}".red
  false
end

def verify_zypper_repo(container, rel_path)
  container.exec('zypper removerepo openvox-verify', allowed_exit_codes: [0, 6])

  yum_url = Infra.yum_bucket.sub('s3://', "#{Infra::S3_ENDPOINT}/")
  repo_content = [
    '[openvox-verify]',
    'name=OpenVox Verify',
    "baseurl=#{yum_url}/#{rel_path}",
    'gpgcheck=1',
    "gpgkey=file://#{Infra::CONTAINER_WORK}/files/repo_packages/keys/GPG-KEY-openvox.pub",
    'enabled=1',
  ].join("\n")
  container.exec("printf '%s\\n' '#{repo_content}' > /etc/zypp/repos.d/openvox-verify.repo")

  container.exec('zypper refresh openvox-verify')
  result = container.capture(
    "zypper search --match-exact --details #{Infra.project}",
    allowed_exit_codes: [0, 104]
  )

  if result.exitcode == 104 || !result.output.include?(Infra.version)
    puts "  zypper: #{Infra.project} #{Infra.version} NOT found in #{rel_path}".red
    false
  else
    puts "  zypper: #{Infra.project} #{Infra.version} found in #{rel_path}".green
    true
  end
rescue SystemExit
  container.exec('zypper removerepo openvox-verify', allowed_exit_codes: [0, 6])
  puts "  zypper: verification failed for #{rel_path}".red
  false
end
