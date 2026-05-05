# frozen_string_literal: true

require 'fileutils'
require_relative 'lib/repo_packages'
require_relative 'lib/utils/infra'

namespace :repo_packages do
  desc 'Build and sign repo RPM/DEB packages and repo/list files'
  task :build do
    Infra.require_env('GPG_PRIVATE_KEY_B64')

    puts 'Building and signing repo packages...'.magenta
    container = Infra.start_container
    begin
      Infra.import_gpg_key(container)
      RepoPackages.build_and_sign(container)
    ensure
      container&.teardown
    end
  end

  desc 'Upload repo package artifacts to S3'
  task :upload do
    RepoPackages.upload
  end

  desc 'Add platform(s) to a repo package definition (commits locally, does not push)'
  task :add_platform do
    RepoPackages.add_platform
  end
end
