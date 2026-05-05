# frozen_string_literal: true

# One-time migration fixes. Remove this file after production migration is complete.

require 'fileutils'
require_relative 'lib/repo/yum'
require_relative 'lib/utils/infra'

namespace :fix do
  desc 'Remove non-src RPMs from yum src/ directories and regenerate their metadata'
  task :src_dirs do
    Infra.setup_aws
    Infra.require_env('GPG_PRIVATE_KEY_B64')

    container = Infra.start_container
    begin
      Infra.import_gpg_key(container)

      state_yum = File.join(Infra::STATE_DIR, 'yum')
      src_dirs = Dir.glob(File.join(state_yum, '**/src'))

      if src_dirs.empty?
        puts 'No src/ directories found in state/.'.yellow
        next
      end

      src_dirs.each do |src_dir|
        rel_path = src_dir.sub("#{state_yum}/", '')
        non_src_rpms = Dir.glob(File.join(src_dir, '*.rpm')).reject { |rpm| rpm.end_with?('.src.rpm') }

        if non_src_rpms.empty?
          puts "#{rel_path}: clean".cyan
          next
        end

        puts "#{rel_path}: removing #{non_src_rpms.size} non-src RPMs".magenta
        non_src_rpms.each do |rpm|
          puts "  #{File.basename(rpm)}".yellow
          File.delete(rpm)
        end

        # Regenerate repodata for the cleaned src dir
        container_src = Infra.container_path(src_dir)
        container.exec("createrepo_c --general-compress-type=gz --simple-md-filenames --no-database #{container_src}")

        repomd = File.join(src_dir, 'repodata', 'repomd.xml')
        container.exec("rm -f #{Infra.container_path(repomd)}.asc")
        Infra.gpg_detach_sign(container, repomd)
      end
    ensure
      container&.teardown
    end

    Infra.commit_state('Fix: remove non-src RPMs from src/ directories')
    puts 'Done. Run `bundle exec rake deploy` to push changes to S3.'.green
  end

  desc 'Add missing openvox-agent 8.12.1 packages to metadata'
  task :agent_8_12_1 do
    platforms = %w[
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
    ]

    ENV['PROJECT'] = 'openvox-agent'
    ENV['VERSION'] = '8.12.1'
    ENV['PLATFORMS'] = platforms.join(',')

    Rake::Task[:release].invoke
  end
end
