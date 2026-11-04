# frozen_string_literal: true

require 'fileutils'
require_relative 'lib/repo/advisory'
require_relative 'lib/repo/yum'
require_relative 'lib/utils/infra'

desc 'Add or update the security advisory of a released version in the yum repo metadata'
task :advisory do
  Infra.print_target(:yum_bucket)
  entry = Advisory.from_env
  Infra.env('GPG_PRIVATE_KEY_B64', required: true)

  Infra.force_remove(Infra::STAGING_DIR)
  FileUtils.mkdir_p(Infra::STAGING_DIR)
  Yum.stage_metadata

  written = Infra.with_signing_container { |container| Yum.new(container).apply_advisory(entry) }
  abort "No packages of #{Infra.project} #{Infra.version} found in the yum repos under state/.".red if written.empty?

  Yum.update_state
  Infra.commit_state("Advisory: #{Infra.project} #{Infra.version}") if Infra.production?
  puts "Advisory #{Advisory.id} written for #{pluralize(written.size, 'arch dir')}.".green
  puts 'Run `bundle exec rake deploy` to push to S3.'.green
end
