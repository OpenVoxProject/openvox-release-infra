# frozen_string_literal: true

require 'fileutils'
require_relative 'lib/repo/apt'
require_relative 'lib/repo/yum'
require_relative 'lib/utils/infra'
require_relative 'lib/utils/shell'

desc 'Rollback repo state to a prior commit'
task :rollback do
  commit = Infra.env('COMMIT', required: true)

  Dir.chdir(Infra::REPO_ROOT) do
    result = Shell.capture(['git', 'cat-file', '-t', commit], allowed_exit_codes: [0, 1])
    abort "Commit #{commit} not found.".red unless result.output.strip == 'commit'

    check = Shell.capture(['git', 'ls-tree', '--name-only', commit, 'state/'])
    abort "Commit #{commit} has no state/ directory.".red if check.output.strip.empty?
    puts "Rolling back state/ to #{commit}...".magenta
    Shell.run(['git', 'checkout', commit, '--', 'state/'])
  end

  Infra.commit_state("Rollback: restore state from #{commit}")

  # The deploy task deploys what it finds in STAGING_DIR. Since we aren't
  # changing any package files, just rolling back the metadata, we can simply
  # copy the metadata from the state/ dir.
  FileUtils.rm_rf(Infra::STAGING_DIR)
  FileUtils.mkdir_p(Infra::STAGING_DIR)

  Apt.stage_metadata
  Yum.stage_metadata

  puts 'Rollback complete. Run `bundle exec rake deploy` to push to S3, then `bundle exec rake cleanup` to remove orphaned packages.'.green
end
