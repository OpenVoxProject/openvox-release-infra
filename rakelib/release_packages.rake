# frozen_string_literal: true

require 'fileutils'
require_relative 'lib/release_packages'
require_relative 'lib/utils/infra'

namespace :release_packages do
  desc 'Build and sign release RPM/DEB packages and repo/list files'
  task :build do
    Infra.require_env('GPG_PRIVATE_KEY_B64')

    puts 'Building and signing release packages...'.magenta
    container = Infra.start_container
    begin
      Infra.import_gpg_key(container)
      ReleasePackages.build_and_sign(container)
    ensure
      container&.teardown
    end
  end

  desc 'Upload release package artifacts to S3'
  task :upload do
    ReleasePackages.upload
  end

  desc 'Add platform(s) to a release package definition (commits locally, does not push)'
  task :add_platform do
    ReleasePackages.add_platform
  end
end
