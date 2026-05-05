# frozen_string_literal: true

require_relative 'lib/utils/infra'
require_relative 'lib/utils/shell'

desc 'Backup current S3 repos to GCS'
task :backup do
  Infra.setup_aws
  Infra.setup_gcloud

  puts 'Backing up apt repo to GCS...'.magenta
  Shell.run("gcloud storage rsync --recursive #{Infra.apt_bucket}/ #{Infra.gcs_bucket}/apt/")

  puts 'Backing up yum repo to GCS...'.magenta
  Shell.run("gcloud storage rsync --recursive #{Infra.yum_bucket}/ #{Infra.gcs_bucket}/yum/")

  puts 'Backing up downloads to GCS...'.magenta
  Shell.run("gcloud storage rsync --recursive #{Infra.downloads_bucket}/ #{Infra.gcs_bucket}/downloads/")

  puts 'Backup complete.'.green
end
