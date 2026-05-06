# frozen_string_literal: true

require 'fileutils'
require_relative 'lib/utils/infra'
require_relative 'lib/utils/shell'

desc 'Sync test buckets from production (with --delete) and clear local state'
task :reset_test do
  Infra.setup_aws
  Infra.print_target(:apt_bucket, :yum_bucket, :downloads_bucket)
  abort 'This task targets test buckets. Do not run with PRODUCTION=true.'.red if Infra.production?

  unless Infra.env('CONFIRM_RESET') == 'true'
    puts "This will overwrite test buckets with production contents (using --delete):\n" \
         "  #{Infra.yum_bucket}\n  #{Infra.apt_bucket}\n  #{Infra.downloads_bucket}".red
    puts 'Repo setup packages and config files in the test buckets will be preserved.'.yellow
    puts 'Local staging/ directory will be cleared.'.yellow
    print 'Type "yes" to confirm: '
    abort 'Aborted.'.yellow unless $stdin.gets&.chomp == 'yes'
  end

  puts 'Syncing yum from production...'.magenta
  Shell.run([*Infra.s3_sync, '--delete', "#{Infra::YUM_PRODUCTION_BUCKET}/", "#{Infra.yum_bucket}/",
             '--exclude', 'openvox*-release-*', '--exclude', 'repo_files/*', '--exclude', 'index.html'])

  puts 'Syncing apt from production...'.magenta
  Shell.run([*Infra.s3_sync, '--delete', "#{Infra::APT_PRODUCTION_BUCKET}/", "#{Infra.apt_bucket}/",
             '--exclude', 'openvox*-release-*', '--exclude', 'list_files/*', '--exclude', 'index.html'])

  puts 'Syncing downloads from production...'.magenta
  Shell.run([*Infra.s3_sync, '--delete', "#{Infra::DOWNLOADS_PRODUCTION_BUCKET}/", "#{Infra.downloads_bucket}/"])

  FileUtils.rm_rf(Infra::STAGING_DIR)

  puts 'Reset complete.'.green
end
