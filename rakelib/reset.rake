# frozen_string_literal: true

require_relative 'lib/utils/shell'

desc 'Remove cached release container, image, and build cache; forces a full rebuild on next run'
task :reset do
  Shell.run(['docker', 'rm', '-f', 'release'], allowed_exit_codes: [0, 1])
  Shell.run(['docker', 'rmi', '-f', 'release:latest'], allowed_exit_codes: [0, 1])
  Shell.run(['docker', 'builder', 'prune', '-f'], allowed_exit_codes: [0, 1])
  puts 'Cleaned up release container, image, and build cache.'.green
end
