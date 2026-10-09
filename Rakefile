# frozen_string_literal: true

def pluralize(count, word) = "#{count} #{word}#{'s' if count != 1}"

begin
  require 'voxpupuli/rubocop/rake'
rescue LoadError
  # the voxpupuli-rubocop gem is optional
end
