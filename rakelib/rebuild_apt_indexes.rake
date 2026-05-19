# frozen_string_literal: true

# One-time task to regenerate apt Release/InRelease/Release.gpg for every
# dist in state/. Was originally used after fixing the issue where Components
# and Architectures were missing from the Release file. Can more generally be
# used if we update how we derive the apt repo metadata and want to regenerate
# it for the entire set of apt repos.

require 'fileutils'
require_relative 'lib/repo/apt'
require_relative 'lib/utils/infra'
require_relative 'lib/utils/shell'

desc 'Regenerate apt Release/InRelease/Release.gpg for every dist in state/, or a subset via the DISTS env var'
task :rebuild_apt_indexes do
  Infra.env('GPG_PRIVATE_KEY_B64', required: true)

  state_dists = File.join(Infra::STATE_DIR, 'apt', 'dists')
  abort "No apt state at #{state_dists}".red unless Dir.exist?(state_dists)

  available_dists = Dir.children(state_dists).select { |entry| File.directory?(File.join(state_dists, entry)) }.sort
  abort "No dists found under #{state_dists}".red if available_dists.empty?

  requested = Infra.env('DISTS')&.split(',')&.map(&:strip)&.reject(&:empty?)
  dists = if requested && !requested.empty?
            unknown = requested - available_dists
            abort "Unknown dists requested: #{unknown.join(', ')}. Available: #{available_dists.join(', ')}".red unless unknown.empty?
            requested
          else
            available_dists
          end

  Infra.force_remove(Infra::STAGING_DIR)
  FileUtils.mkdir_p(Infra::STAGING_DIR)
  Apt.stage_metadata

  container = Infra.start_container(env_vars: ['GPG_PRIVATE_KEY_B64'])
  begin
    Infra.import_gpg_key(container)
    apt = Apt.new(container)
    dists.each do |dist|
      puts "Rebuilding apt indexes: #{dist}".magenta
      apt.rebuild_indexes(dist)
    end
    Apt.update_state
  ensure
    Infra.teardown_with_chown(container)
  end

  Infra.commit_state('Rebuild_apt_indexes: Regenerate apt repo metadata')
  puts 'Rebuild complete. Run `bundle exec rake deploy` to push to S3.'.green
end
