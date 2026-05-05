# frozen_string_literal: true

require 'shellwords'
require_relative 'lib/utils/infra'
require_relative 'lib/utils/shell'

desc 'Restore S3 repos from GCS backup'
task :restore do
  Infra.setup_aws
  Infra.setup_gcloud
  Infra.print_target(:apt_bucket, :yum_bucket, :downloads_bucket, :gcs_bucket)
  target = Infra.env('TARGET', required: true)
  abort "TARGET must be apt, yum, downloads, or all (got: #{target})".red unless %w[apt yum downloads all].include?(target)

  source_bucket = Infra.env('GCS_SOURCE', default: Infra.gcs_bucket)
  targets = target == 'all' ? %w[apt yum downloads] : [target]

  destination_buckets = {
    'apt' => Infra.apt_bucket,
    'yum' => Infra.yum_bucket,
    'downloads' => Infra.downloads_bucket,
  }

  puts '*** WARNING: This is a destructive operation. ***'.red
  puts "This will overwrite the selected #{Infra.production? ? 'production' : 'test'} repo(s) (#{target}) with the GCS backup.".red
  puts "Source: #{source_bucket}".yellow
  puts 'Destination:'.yellow
  targets.each { |name| puts "  #{destination_buckets[name]}".yellow }

  unless Infra.env('CONFIRM_RESTORE') == 'true'
    if $stdin.tty?
      print 'Type "restore" to confirm: '.red
      answer = $stdin.gets&.chomp
      abort 'Aborted.'.yellow unless answer == 'restore'
    else
      abort 'CONFIRM_RESTORE must be set in non-interactive mode.'.red
    end
  end

  if targets.include?('apt')
    puts 'Restoring apt repo from GCS...'.magenta
    Shell.run("gcloud storage rsync --recursive --delete-unmatched-destination-objects #{source_bucket}/apt/ #{Infra.apt_bucket}/")
  end

  if targets.include?('yum')
    puts 'Restoring yum repo from GCS...'.magenta
    Shell.run("gcloud storage rsync --recursive --delete-unmatched-destination-objects #{source_bucket}/yum/ #{Infra.yum_bucket}/")
  end

  if targets.include?('downloads')
    puts 'Restoring downloads from GCS...'.magenta
    Shell.run("gcloud storage rsync --recursive --delete-unmatched-destination-objects #{source_bucket}/downloads/ #{Infra.downloads_bucket}/")
  end

  puts 'Restore complete.'.green
end

namespace :restore do
  desc 'Roll back GCS backup bucket to a point in time using soft-delete recovery'
  task :gcs do
    Infra.setup_gcloud
    Infra.print_target(:gcs_bucket)
    timestamp = Shellwords.shellescape(Infra.env('TIMESTAMP', required: true))
    bucket = Infra.env('GCS_SOURCE', default: Infra.gcs_bucket)

    puts '*** WARNING: This is a destructive operation. ***'.red
    puts "This will roll back #{bucket} to #{timestamp} by restoring soft-deleted objects.".red

    unless Infra.env('CONFIRM_RESTORE') == 'true'
      if $stdin.tty?
        print 'Type "restore" to confirm: '.red
        answer = $stdin.gets&.chomp
        abort 'Aborted.'.yellow unless answer == 'restore'
      else
        abort 'CONFIRM_RESTORE must be set in non-interactive mode.'.red
      end
    end

    puts "Rolling back #{bucket} to #{timestamp}...".magenta
    result = Shell.capture(
      "gcloud storage restore '#{bucket}/**' --async --allow-overwrite " \
      "--created-before-time=#{timestamp} --deleted-after-time=#{timestamp}",
      silent: false
    )

    operation = result.output[%r{projects/\S+}]
    abort 'Could not parse operation name from gcloud output.'.red unless operation

    puts "Waiting for operation to complete: #{operation}".cyan
    loop do
      status = Shell.capture(
        "gcloud storage operations describe '#{operation}' --format='value(done)'",
        print_command: false
      )
      if status.output.strip.casecmp('true').zero?
        puts 'GCS restore complete.'.green
        break
      end
      sleep 10
    end

    puts <<~MSG.green
      GCS restore complete. Next steps:
        1. bundle exec rake restore                - sync recovered GCS state to S3
        2. COMMIT=<sha> bundle exec rake rollback  - roll back state/ to the matching commit
        3. bundle exec rake cleanup                - remove orphaned packages from S3

        This assumes the rollback commit matches the state of the GCS backup at that time. If you're unsure,
        run `bundle exec rake deploy` before cleanup.
    MSG
  end
end
