# frozen_string_literal: true

def pluralize(count, word) = "#{count} #{word}#{'s' if count != 1}"

begin
  require 'voxpupuli/rubocop/rake'
rescue LoadError
  # the voxpupuli-rubocop gem is optional
end

begin
  require 'rspec/core/rake_task'
  RSpec::Core::RakeTask.new(:spec)
rescue LoadError
  # the rspec gem is optional
end
