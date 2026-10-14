# frozen_string_literal: true

require 'fileutils'
require 'json'
require 'rake'
require 'stringio'
require 'tmpdir'
require 'zlib'

RAKELIB = File.expand_path('../rakelib', __dir__)

# Defined in the Rakefile, which the specs don't load.
def pluralize(count, word) = "#{count} #{word}#{'s' if count != 1}"

%w[
  lib/utils/shell
  lib/utils/container
  lib/utils/infra
  lib/utils/platform
  lib/repo/apt
  lib/repo/yum
  lib/repo/windows
  lib/repo/macos
  lib/repo_packages
].each { |lib| require File.join(RAKELIB, lib) }

Dir[File.join(__dir__, 'support', '**', '*.rb')].each { |file| require file }

RSpec.configure do |config|
  config.mock_with :rspec do |mocks|
    mocks.verify_partial_doubles = true
  end
  config.disable_monkey_patching!
  config.order = :random
  config.expect_with(:rspec) { |expectations| expectations.syntax = :expect }
end
