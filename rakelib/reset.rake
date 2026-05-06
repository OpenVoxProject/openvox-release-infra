# frozen_string_literal: true

require_relative 'lib/utils/infra'
require_relative 'lib/utils/shell'

desc 'Remove cached release container, image, and build cache; forces a full rebuild on next run'
task :reset do
  container_name = Infra::CONTAINER_TAG.split(':').first
  Shell.run(['docker', 'rm', '-f', container_name], allowed_exit_codes: [0, 1])
  Shell.run(['docker', 'rmi', '-f', Infra::CONTAINER_TAG], allowed_exit_codes: [0, 1])
  Shell.run(['docker', 'builder', 'prune', '-f'], allowed_exit_codes: [0, 1])
  puts 'Cleaned up release container, image, and build cache.'.green
end
