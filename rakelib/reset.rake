# frozen_string_literal: true

require_relative 'lib/utils/shell'

desc 'Remove cached release containers and images; they will rebuild on next run'
task :reset do
  %w[release release-setup].each { |name| Shell.run(['docker', 'rm', '-f', name], allowed_exit_codes: [0, 1]) }
  Shell.run(['docker', 'rmi', '-f', 'release:latest'], allowed_exit_codes: [0, 1])
  puts 'Cleaned up release containers and images.'.green
end
