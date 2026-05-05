# frozen_string_literal: true

require_relative 'lib/utils/infra'

desc 'Restore S3 repos from GCS backup'
task :restore do
  Infra.setup_aws
  Infra.setup_gcloud
  target = Infra.require_env('TARGET')
  abort "TARGET must be apt, yum, downloads, or all (got: #{target})".red unless %w[apt yum downloads all].include?(target)

  source_bucket = ENV.fetch('GCS_SOURCE', Infra.gcs_bucket)
  targets = target == 'all' ? %w[apt yum downloads] : [target]

  destination_buckets = {
    'apt' => Infra.apt_bucket,
    'yum' => Infra.yum_bucket,
    'downloads' => Infra.downloads_bucket
  }

  puts '*** WARNING: This is a destructive operation. ***'.red
  puts "This will overwrite the #{Infra.production? ? 'PRODUCTION' : 'test'} #{target} repo(s) with the GCS backup.".red
  puts "Source: #{source_bucket}".yellow
  puts 'Destination:'.yellow
  targets.each { |name| puts "  #{destination_buckets[name]}".yellow }

  unless ENV['CONFIRM_RESTORE']
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
