# frozen_string_literal: true

require 'fileutils'
require_relative 'lib/utils/infra'

desc 'Sync test buckets from production (with --delete) and clear local state'
task :reset_test do
  Infra.setup_aws
  abort 'This task targets test buckets. Do not run with PRODUCTION=true.'.red if Infra.production?

  unless ENV['CONFIRM_RESET']
    puts "This will overwrite test buckets with production contents (using --delete):\n" \
         "  #{Infra.yum_bucket}\n  #{Infra.apt_bucket}\n  #{Infra.downloads_bucket}".red
    puts 'Repo setup packages and config files in the test buckets will be preserved.'.yellow
    puts 'Local state/ and staging/ directories will be cleared.'.red
    print 'Type "yes" to confirm: '
    abort 'Aborted.'.yellow unless $stdin.gets&.chomp == 'yes'
  end

  puts 'Syncing yum from production...'.magenta
  Shell.run("#{Infra.s3_sync} --delete s3://openvox-yum/ #{Infra.yum_bucket}/ " \
            "--exclude 'openvox*-release-*' --exclude 'repo_files/*' --exclude 'index.html'")

  puts 'Syncing apt from production...'.magenta
  Shell.run("#{Infra.s3_sync} --delete s3://openvox-apt/ #{Infra.apt_bucket}/ " \
            "--exclude 'openvox*-release-*' --exclude 'list_files/*' --exclude 'index.html'")

  puts 'Syncing downloads from production...'.magenta
  Shell.run("#{Infra.s3_sync} --delete s3://openvox-artifacts/downloads/ #{Infra.downloads_bucket}/")

  FileUtils.rm_rf(Infra::STATE_DIR)
  FileUtils.rm_rf(Infra::STAGING_DIR)
  FileUtils.mkdir_p(Infra::STATE_DIR)

  puts 'Reset complete.'.green
end
