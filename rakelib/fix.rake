# frozen_string_literal: true

# One-time migration fixes. Remove this file after production migration is complete.

require 'fileutils'
require 'zlib'
require_relative 'lib/repo/yum'
require_relative 'lib/utils/infra'
require_relative 'lib/utils/shell'

desc 'Run one-time migration fixes, deploy, and clean up'
task :fix do
  abort 'Fix targets test buckets. Do not run with PRODUCTION=true.'.red if Infra.production?

  # Somehow, the release for this version missed adding the package
  # in some of the platform repos' metadata, even though the packages
  # are there. So resign the packages and add them properly.
  puts '--- Fix: Add missing openvox-agent 8.12.1 packages ---'.magenta
  ENV['PROJECT'] = 'openvox-agent'
  ENV['VERSION'] = '8.12.1'
  ENV['PLATFORMS'] = %w[
    debian-10-amd64
    debian-11-amd64
    debian-11-arm64
    debian-12-amd64
    debian-12-arm64
    ubuntu-18.04-amd64
    ubuntu-18.04-arm64
    ubuntu-20.04-amd64
    ubuntu-20.04-arm64
    ubuntu-22.04-amd64
    ubuntu-22.04-arm64
    ubuntu-24.04-amd64
    ubuntu-24.04-arm64
    fedora-36-x86_64
    fedora-40-x86_64
    fedora-40-aarch64
  ].join(',')

  # This will not commit since we are not running with production.
  # Release automatically runs setup_aws, print_target and creates
  # a clean staging dir so we don't have to do it for the next fix.
  Rake::Task[:release].invoke

  puts 'Missing openvox-agent 8.12.1 packages fixed.'.green

  # The current production repos have noarch packages (openvox-server, openvoxdb, etc.)
  # incorrectly included in src/ directories. Download the actual
  # .src.rpm files from S3, regenerate clean repodata from those alone, and
  # update both state/ and staging/. Reuses staging/ from the fix above.
  puts '--- Fix: Remove non-src RPMs from src/ directories and metadata ---'.magenta

  yum_state = File.join(Infra::STATE_DIR, 'yum')
  abort 'No state/yum/ directory found. Run bootstrap first.'.red unless Dir.exist?(yum_state)

  state_src_dirs = Dir.glob(File.join(yum_state, '**/src'))
  abort 'No src/ directories found in state/yum/. State appears empty or malformed.'.red if state_src_dirs.empty?
  yum_staging = File.join(Infra::STAGING_DIR, 'yum')
  dirty_rel_paths = []

  state_src_dirs.each do |src_dir|
    rel_path = src_dir.sub("#{yum_state}/", '')
    primary_gz = File.join(src_dir, 'repodata', 'primary.xml.gz')
    next unless File.exist?(primary_gz)

    xml = Zlib::GzipReader.open(primary_gz, &:read)
    non_src_hrefs = xml.scan(/<location href="([^"]+)"/).flatten.reject { |href| href.end_with?('.src.rpm') }

    if non_src_hrefs.empty?
      puts "#{rel_path}: clean".cyan
      next
    end

    puts "#{rel_path}: #{non_src_hrefs.size} non-src RPMs in metadata".magenta
    non_src_hrefs.each { |href| puts "  #{href}".yellow }
    dirty_rel_paths << rel_path

    staging_src = File.join(yum_staging, rel_path)
    FileUtils.mkdir_p(staging_src)
    s3_path = "#{Infra.yum_bucket}/#{rel_path}/"
    Shell.run([*Infra.s3_sync, s3_path, "#{staging_src}/", '--exclude', '*', '--include', '*.src.rpm'])
    downloaded = Dir.glob(File.join(staging_src, '*.src.rpm'))
    abort "No .src.rpm files downloaded from #{s3_path} when repo metadata shows that they should exist.".red if downloaded.empty?
  end

  if dirty_rel_paths.any?
    container = Infra.start_container
    begin
      Infra.import_gpg_key(container)

      dirty_rel_paths.each do |rel_path|
        staging_src = File.join(yum_staging, rel_path)
        container_src = Infra.container_path(staging_src)

        # Remove stale repodata copied from state/, then regenerate and sign.
        container.exec("rm -rf #{container_src}/repodata")
        container.exec("createrepo_c --general-compress-type=gz --simple-md-filenames --no-database #{container_src}")
        repomd = File.join(staging_src, 'repodata', 'repomd.xml')
        container.exec("rm -f #{Infra.container_path(repomd)}.asc")
        Infra.gpg_detach_sign(container, repomd)

        # Remove src RPMs from staging so deploy doesn't re-upload them
        Dir.glob(File.join(staging_src, '*.src.rpm')).each { |rpm| File.delete(rpm) }

        # Copy clean repodata back to state/
        state_repodata = File.join(yum_state, rel_path, 'repodata')
        FileUtils.rm_rf(state_repodata)
        FileUtils.cp_r(File.join(staging_src, 'repodata'), state_repodata)
      end
    ensure
      Infra.teardown_with_chown(container)
    end

    puts 'Non-src RPMs removed from src repositories'.green
  else
    puts 'All src/ directories are clean.'.green
  end

  Infra.commit_state('Fix: Add missing 8.12.1 packages and clean src/ repodata')

  puts 'Deploying changes'.magenta

  ENV['FORCE_OVERWRITE'] = 'true'
  Rake::Task[:deploy].invoke

  ENV['CONFIRM_CLEANUP'] = 'true'
  Rake::Task[:cleanup].invoke
end
