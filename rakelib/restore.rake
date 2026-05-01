# frozen_string_literal: true

require_relative 'lib/utils/infra'

desc 'Restore S3 repos from GCS backup'
task :restore do
  Infra.setup_aws
  Infra.setup_gcloud
  target = Infra.require_env('TARGET')
  abort "TARGET must be apt, yum, downloads, or all (got: #{target})".red unless %w[apt yum downloads all].include?(target)

  puts '*** WARNING: This is a destructive operation. ***'.red
  puts "This will overwrite the #{Infra.production? ? 'PRODUCTION' : 'test'} #{target} repo(s) with the GCS backup.".red
  puts "Source: #{Infra.gcs_bucket}".yellow
  puts "Destination: #{target == 'all' ? 'all S3 buckets' : target}".yellow

  unless ENV['CONFIRM_RESTORE']
    if $stdin.tty?
      print 'Type "restore" to confirm: '.red
      answer = $stdin.gets&.chomp
      abort 'Aborted.'.yellow unless answer == 'restore'
    else
      abort 'CONFIRM_RESTORE must be set in non-interactive mode.'.red
    end
  end

  if %w[apt all].include?(target)
    puts 'Restoring apt repo from GCS...'.magenta
    Shell.run("gcloud storage rsync --recursive --delete-unmatched-destination-objects #{Infra.gcs_bucket}/apt/ #{Infra.apt_bucket}/")
  end

  if %w[yum all].include?(target)
    puts 'Restoring yum repo from GCS...'.magenta
    Shell.run("gcloud storage rsync --recursive --delete-unmatched-destination-objects #{Infra.gcs_bucket}/yum/ #{Infra.yum_bucket}/")
  end

  if %w[downloads all].include?(target)
    puts 'Restoring downloads from GCS...'.magenta
    Shell.run("gcloud storage rsync --recursive --delete-unmatched-destination-objects #{Infra.gcs_bucket}/downloads/ #{Infra.downloads_bucket}/")
  end

  puts 'Restore complete.'.green
end
