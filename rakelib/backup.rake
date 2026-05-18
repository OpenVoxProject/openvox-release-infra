# frozen_string_literal: true

require_relative 'lib/utils/infra'
require_relative 'lib/utils/shell'

desc 'Backup current S3 repos to GCS'
task :backup do
  Infra.setup_aws
  Infra.setup_gcloud
  Infra.print_target(:apt_bucket, :yum_bucket, :downloads_bucket, :gcs_bucket)

  [Infra.apt_bucket, Infra.yum_bucket, Infra.downloads_bucket].each do |bucket|
    result = Shell.capture([*Infra.s3_cmd, 'ls', "#{bucket}/"], allowed_exit_codes: [0, 1], silent: true)
    next if result.exitcode.zero? && !result.output.strip.empty?

    warn result.output unless result.output.strip.empty?
    abort "S3 source #{bucket}/ appears empty or inaccessible (exit #{result.exitcode}). Refusing to back up to avoid destroying GCS state.".red
  end

  puts 'Backing up apt repo to GCS...'.magenta
  Shell.run(['gcloud', 'storage', 'rsync', '--recursive', '--delete-unmatched-destination-objects',
             "#{Infra.apt_bucket}/", "#{Infra.gcs_bucket}/apt/"])

  puts 'Backing up yum repo to GCS...'.magenta
  Shell.run(['gcloud', 'storage', 'rsync', '--recursive', '--delete-unmatched-destination-objects',
             "#{Infra.yum_bucket}/", "#{Infra.gcs_bucket}/yum/"])

  puts 'Backing up downloads to GCS...'.magenta
  Shell.run(['gcloud', 'storage', 'rsync', '--recursive', '--delete-unmatched-destination-objects',
             "#{Infra.downloads_bucket}/", "#{Infra.gcs_bucket}/downloads/"])

  puts 'Backup complete.'.green
end
