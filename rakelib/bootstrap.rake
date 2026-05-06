# frozen_string_literal: true

require 'fileutils'
require_relative 'lib/repo/apt'
require_relative 'lib/repo/yum'
require_relative 'lib/utils/infra'
require_relative 'lib/utils/shell'

desc 'Bootstrap state/ and test buckets from production (runs metadata then packages)'
task bootstrap: %w[bootstrap:metadata bootstrap:packages]

namespace :bootstrap do
  desc 'Download production metadata, reformat, store in state/, and deploy to test buckets'
  task :metadata do
    Infra.setup_aws
    Infra.print_target(:apt_bucket, :yum_bucket)
    Infra.env('GPG_PRIVATE_KEY_B64', required: true)
    abort 'Bootstrap targets test buckets. Do not run with PRODUCTION=true.'.red if Infra.production?

    Infra.force_remove(Infra::STAGING_DIR)
    FileUtils.mkdir_p(Infra::STAGING_DIR)

    tmp_download = File.join(Infra::REPO_ROOT, 'tmp_bootstrap')
    FileUtils.rm_rf(tmp_download)
    FileUtils.mkdir_p(tmp_download)

    container = Infra.start_container
    begin
      Infra.import_gpg_key(container)
      bootstrap_yum_metadata(container, tmp_download)
      bootstrap_apt_metadata(container, tmp_download)
    ensure
      begin
        Infra.teardown_with_chown(container)
      rescue StandardError => e
        warn "WARNING: teardown also failed: #{e.message}".yellow
      end
      FileUtils.rm_rf(tmp_download)
    end

    Infra.commit_state('Bootstrap from current production repos')

    # Deploy reformatted metadata to test buckets
    puts 'Deploying metadata to test buckets...'.magenta
    state_yum = File.join(Infra::STATE_DIR, 'yum')
    Shell.run([*Infra.s3_sync, "#{state_yum}/", "#{Infra.yum_bucket}/", '--exclude', '*.rpm']) if Dir.exist?(state_yum)

    state_dists = File.join(Infra::STATE_DIR, 'apt', 'dists')
    Shell.run([*Infra.s3_sync, "#{state_dists}/", "#{Infra.apt_bucket}/dists/"]) if Dir.exist?(state_dists)

    puts 'Metadata bootstrap complete.'.green
  end

  desc 'Copy packages from production S3 buckets to test bucket locations'
  task :packages do
    Infra.setup_aws
    abort 'Bootstrap targets test buckets. Do not run with PRODUCTION=true.'.red if Infra.production?

    puts 'Syncing packages from production to test buckets...'.magenta

    puts 'Syncing yum packages...'.magenta
    Shell.run([*Infra.s3_sync, "#{Infra::YUM_PRODUCTION_BUCKET}/", "#{Infra.yum_bucket}/",
               '--exclude', '*/repodata/*', '--exclude', 'openvox*-release-*',
               '--exclude', 'repo_files/*', '--exclude', 'index.html'])

    puts 'Syncing apt packages and GPG key...'.magenta
    Shell.run([*Infra.s3_sync, "#{Infra::APT_PRODUCTION_BUCKET}/", "#{Infra.apt_bucket}/",
               '--exclude', 'dists/*', '--exclude', 'openvox*-release-*',
               '--exclude', 'list_files/*', '--exclude', 'index.html'])

    puts 'Syncing downloads...'.magenta
    Shell.run([*Infra.s3_sync, "#{Infra::DOWNLOADS_PRODUCTION_BUCKET}/", "#{Infra.downloads_bucket}/"])

    puts 'Package sync complete.'.green
  end
end

def bootstrap_yum_metadata(container, tmp_download)
  yum_download = File.join(tmp_download, 'yum')
  FileUtils.mkdir_p(yum_download)

  staging_yum = File.join(Infra::STAGING_DIR, 'yum')
  FileUtils.rm_rf(staging_yum)
  FileUtils.mkdir_p(staging_yum)

  puts 'Downloading yum repodata from S3...'.magenta
  Shell.run([*Infra.s3_sync, "#{Infra::YUM_PRODUCTION_BUCKET}/", "#{yum_download}/", '--exclude', '*', '--include', '*/repodata/*'])

  Dir.glob(File.join(yum_download, '**', 'repodata')).each do |old_repodata_dir|
    arch_dir = File.dirname(old_repodata_dir)
    rel_path = arch_dir.sub("#{yum_download}/", '')
    puts "Reformatting yum metadata: #{rel_path}".magenta

    staging_arch = File.join(staging_yum, rel_path)
    FileUtils.mkdir_p(staging_arch)

    container_old = Infra.container_path(arch_dir)
    container_out = Infra.container_path(staging_arch)
    container.exec(
      'mergerepo_c --omit-baseurl --all --simple-md-filenames --no-database ' \
      "--compress-type gz --repo #{container_old} -o #{container_out}"
    )

    repomd = File.join(staging_arch, 'repodata', 'repomd.xml')
    Infra.gpg_detach_sign(container, repomd)
  end

  Yum.update_state
  puts "yum bootstrap complete: #{Dir.glob(File.join(Infra::STATE_DIR, 'yum', '**', 'repomd.xml')).size} repos.".green
end

def bootstrap_apt_metadata(container, tmp_download)
  apt_download = File.join(tmp_download, 'apt')
  FileUtils.mkdir_p(apt_download)

  puts 'Downloading apt dists from S3...'.magenta
  Shell.run([*Infra.s3_sync, "#{Infra::APT_PRODUCTION_BUCKET}/dists/", "#{apt_download}/dists/"])

  # The Packages files from reprepro are in standard format and can be reused
  # directly. We just need to regenerate Release/InRelease/Release.gpg with our
  # signing and field conventions.
  #
  # rebuild_indexes operates on STAGING_DIR, so we work in staging then copy
  # the result to state/ (same flow as a normal release).
  staging_dists = File.join(Infra::STAGING_DIR, 'apt', 'dists')
  FileUtils.rm_rf(staging_dists)
  FileUtils.mkdir_p(staging_dists)

  dist_dirs = Dir.glob(File.join(apt_download, 'dists', '*')).select { |path| File.directory?(path) }
  dist_dirs.each do |dist_dir|
    dist = File.basename(dist_dir)
    puts "Reformatting apt metadata: #{dist}".magenta

    staging_dist = File.join(staging_dists, dist)
    FileUtils.mkdir_p(staging_dist)

    # Copy Packages files into staging (these are format-compatible)
    Dir.glob(File.join(dist_dir, '**', 'binary-*')).each do |binary_dir|
      rel = binary_dir.sub("#{dist_dir}/", '')
      dest = File.join(staging_dist, rel)
      FileUtils.mkdir_p(dest)

      packages_file = File.join(binary_dir, 'Packages')
      FileUtils.cp(packages_file, dest) if File.exist?(packages_file)
    end

    # Regenerate Packages.gz, Release, InRelease, Release.gpg
    apt = Apt.new(container)
    apt.rebuild_indexes(dist)
  end

  Apt.update_state
  puts "apt bootstrap complete: #{dist_dirs.size} dists.".green
end
