# frozen_string_literal: true

require 'json'
require 'minitest/autorun'
require_relative '../rakelib/lib/repo_packages'

class RepoPackagesTest < Minitest::Test
  class FakeContainer
    attr_reader :commands

    def initialize
      @commands = []
    end

    def exec(command)
      @commands << command
    end
  end

  PACKAGE = {
    'package' => 'openvox9-release',
    'version' => '1',
    'license' => 'ASL 2.0',
    'vendor' => 'Vox Pupuli <openvox@voxpupuli.org>',
    'homepage' => 'https://voxpupuli.org',
    'description' => 'Release packages for the OpenVox 9 repository',
  }.freeze

  def build_command(output_type, conflicts: nil)
    package = PACKAGE.dup
    package['conflicts'] = conflicts unless conflicts.nil?
    container = FakeContainer.new

    RepoPackages.run_fpm(
      container,
      package,
      '/tmp/build',
      "/tmp/openvox9-release.#{output_type}",
      output_type,
      '1',
    )

    container.commands.fetch(0)
  end

  def test_deb_package_includes_every_conflict
    command = build_command('deb', conflicts: %w[openvox7-release openvox8-release])

    assert_includes command, '--conflicts openvox7-release'
    assert_includes command, '--conflicts openvox8-release'
  end

  def test_rpm_package_includes_every_conflict
    command = build_command('rpm', conflicts: %w[openvox7-release openvox8-release])

    assert_includes command, '--conflicts openvox7-release'
    assert_includes command, '--conflicts openvox8-release'
  end

  def test_package_without_conflicts_has_no_conflicts_flag
    assert_includes build_command('deb'), '--config-files'
    refute_includes build_command('deb'), '--conflicts'
    refute_includes build_command('rpm'), '--conflicts'
  end

  def test_package_with_empty_conflicts_has_no_conflicts_flag
    refute_includes build_command('deb', conflicts: []), '--conflicts'
    refute_includes build_command('rpm', conflicts: []), '--conflicts'
  end

  def test_release_package_conflicts_are_complete_and_symmetric
    definitions = package_definitions
    release_packages = definitions.select { |name, _| name.match?(/\Aopenvox\d+-release\z/) }

    assert_operator release_packages.size, :>, 1

    release_packages.each_key do |package|
      expected = release_packages.keys - [package]

      assert_equal expected.sort, Array(definitions[package]['conflicts']).sort,
        "#{package} must conflict with every other OpenVox release package"
    end
  end

  private

  def package_definitions
    Dir[File.join(__dir__, '..', 'files', 'repo_packages', '*.json')].to_h do |path|
      data = JSON.parse(File.read(path))
      [data.fetch('package'), data]
    end
  end
end
