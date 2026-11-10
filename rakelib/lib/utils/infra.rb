# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'shellwords'
require_relative 'container'
require_relative 'shell'

module Infra
  GPG_KEY_ID = 'openvox@voxpupuli.org'
  S3_ENDPOINT = 'https://s3.osuosl.org'
  ARTIFACTS_BUCKET = ENV.fetch('ARTIFACTS_BUCKET', 'openvox-artifacts')

  APT_PRODUCTION_BUCKET = 's3://openvox-apt'
  YUM_PRODUCTION_BUCKET = 's3://openvox-yum'
  DOWNLOADS_PRODUCTION_BUCKET = "s3://#{ARTIFACTS_BUCKET}/downloads".freeze
  GCS_PRODUCTION_BUCKET = 'gs://openvox-backup'

  APT_TEST_BUCKET = "s3://#{ARTIFACTS_BUCKET}/repo_test/apt".freeze
  YUM_TEST_BUCKET = "s3://#{ARTIFACTS_BUCKET}/repo_test/yum".freeze
  DOWNLOADS_TEST_BUCKET = "s3://#{ARTIFACTS_BUCKET}/repo_test/downloads".freeze
  GCS_TEST_BUCKET = 'gs://openvox-backup-test'

  REPO_ROOT = File.expand_path('../../..', __dir__)
  PACKAGES_DIR = File.join(REPO_ROOT, 'packages')
  STAGING_DIR = File.join(REPO_ROOT, 'staging')
  STATE_DIR = File.join(REPO_ROOT, 'state')
  CONTAINER_WORK = '/work'

  CONTAINER_TAG = 'release:latest'
  DOCKERFILE = File.join(REPO_ROOT, 'Dockerfile')

  SAFE_INPUT = /\A[a-zA-Z0-9._+-~]+\z/

  # How many times an S3 or GCS transfer is attempted before the task gives up
  TRANSFER_ATTEMPTS = 5

  module_function

  def validate_input(name, value)
    return nil if value.nil? || value.empty?

    abort "#{name} contains invalid characters: #{value.inspect}. Only alphanumeric, '.', '_', '+', '-', and '~' are allowed.".red unless value.match?(SAFE_INPUT)
    value
  end

  def env(name, required: false, default: nil)
    value = ENV[name]
    value = nil if value&.strip&.empty?

    if value.nil? && !default.nil?
      value = default
      ENV[name] = default
    end

    if value.nil? && required
      if $stdin.tty?
        print "#{name}: "
        value = $stdin.gets&.chomp
        abort "#{name} is required.".red if value.nil? || value.empty?
        ENV[name] = value
      else
        abort "#{name} must be set.".red
      end
    end

    value
  end

  # These are functions instead of constants so they can be lazy loaded so that,
  # for example, PROJECT isn't required for actions that don't require it.
  def project = validate_input('PROJECT', env('PROJECT', required: true))
  def version = validate_input('VERSION', env('VERSION', required: true))
  def component = validate_input('COMPONENT', env('COMPONENT', required: true, default: 'openvox8'))
  def production? = env('PRODUCTION') == 'true'

  def apt_bucket = env('APT_BUCKET', default: production? ? APT_PRODUCTION_BUCKET : APT_TEST_BUCKET)
  def yum_bucket = env('YUM_BUCKET', default: production? ? YUM_PRODUCTION_BUCKET : YUM_TEST_BUCKET)
  def downloads_bucket = env('DOWNLOADS_BUCKET', default: production? ? DOWNLOADS_PRODUCTION_BUCKET : DOWNLOADS_TEST_BUCKET)
  def gcs_bucket = env('GCS_BUCKET', default: production? ? GCS_PRODUCTION_BUCKET : GCS_TEST_BUCKET)

  # Base URLs baked into release package .repo/.list files so end-user
  # package managers know where to find the OpenVox apt/yum repos.
  def yum_release_package_base = production? ? 'https://yum.voxpupuli.org' : "#{S3_ENDPOINT}/#{ARTIFACTS_BUCKET}/repo_test/yum"
  def apt_release_package_base = production? ? 'https://apt.voxpupuli.org' : "#{S3_ENDPOINT}/#{ARTIFACTS_BUCKET}/repo_test/apt"

  def print_target(*bucket_methods)
    puts "Target: #{production? ? 'PRODUCTION' : 'test'}".orange
    bucket_methods.each { |name| puts "  #{name}: #{send(name)}".orange }
  end

  def container_path(host_path) = host_path.sub(REPO_ROOT, CONTAINER_WORK)
  def s3_cmd
    ca_bundle = ENV.fetch('AWS_CA_BUNDLE', '/etc/ssl/certs/ca-certificates.crt')
    ['aws', 's3', '--endpoint-url', S3_ENDPOINT, '--ca-bundle', ca_bundle]
  end

  # The transfers below get TRANSFER_ATTEMPTS tries. They are safe to repeat,
  # and a retried sync only carries what is still missing.
  def s3_sync(*args) = Shell.run([*s3_cmd, 'sync', '--no-progress', *args], attempts: TRANSFER_ATTEMPTS)

  def s3_exists?(remote)
    result = Shell.capture([*s3_cmd, 'ls', remote], allowed_exit_codes: [0, 1], print_command: false, attempts: TRANSFER_ATTEMPTS)
    result.exitcode.zero? && !result.output.strip.empty?
  end

  def gcs_rsync(source, destination)
    Shell.run(['gcloud', 'storage', 'rsync', '--recursive', '--delete-unmatched-destination-objects', source, destination], attempts: TRANSFER_ATTEMPTS)
  end

  def start_container(env_vars: ['GPG_PRIVATE_KEY_B64'])
    Container.build_image(dockerfile: DOCKERFILE, tag: CONTAINER_TAG) unless Container.image_exists?(CONTAINER_TAG)

    name = CONTAINER_TAG.split(':').first
    container_env = {}
    env_vars.each do |var|
      value = env(var)
      container_env[var] = value if value
    end

    container = Container.new(name: name, image: CONTAINER_TAG)
    container.start(command: 'sleep infinity', volumes: { REPO_ROOT => CONTAINER_WORK }, env: container_env)
    container
  end

  # Start the release container with the GPG key imported, yield it, and tear
  # it down. Returns what the block returns.
  def with_signing_container
    container = start_container
    import_gpg_key(container)
    yield container
  ensure
    teardown_with_chown(container)
  end

  def require_command(*names)
    names.each do |name|
      result = Shell.capture(['which', name], allowed_exit_codes: [0, 1], print_command: false)
      abort "#{name} is required but not found in PATH.".red unless result.exitcode.zero?
    end
  end

  def teardown_with_chown(container)
    container&.exec(
      "chown -R #{Process.uid}:#{Process.gid} #{CONTAINER_WORK}/staging #{CONTAINER_WORK}/packages",
      allowed_exit_codes: [0, 1]
    )
  ensure
    container&.teardown
  end

  # Remove a directory that may contain root-owned files left by a container.
  # Tries host-side rm_rf first; falls back to a one-shot container if needed.
  def force_remove(path)
    FileUtils.rm_rf(path)
    return unless Dir.exist?(path)

    Container.run_once(
      image: 'debian:13',
      cmd: "rm -rf /target/#{File.basename(path)}",
      volumes: { File.dirname(path) => '/target' }
    )
  end

  def import_gpg_key(container)
    container.exec(
      'echo "$GPG_PRIVATE_KEY_B64" | base64 -d | gpg --batch --import && ' \
      "gpg --list-secret-keys '#{GPG_KEY_ID}' >/dev/null && " \
      "printf 'trust\\n5\\ny\\n' | gpg --batch --command-fd 0 --edit-key '#{GPG_KEY_ID}' && " \
      "gpg --export --armor '#{GPG_KEY_ID}' > /tmp/gpg-pub.key && rpm --import /tmp/gpg-pub.key && rm /tmp/gpg-pub.key"
    )
  end

  def gpg_detach_sign(container, host_path)
    escaped = Shellwords.shellescape(container_path(host_path))
    container.exec(
      "gpg --batch --yes --default-key '#{GPG_KEY_ID}' --digest-algo SHA512 " \
      "--detach-sign --armor --output #{escaped}.asc #{escaped}"
    )
    container.exec("gpg --verify #{escaped}.asc #{escaped}")
  end

  # The checksum line of a file, in the format that sha256sum -c and
  # shasum -a 256 -c read
  def sha256_line(path) = "#{Digest::SHA256.file(path).hexdigest}  #{File.basename(path)}"

  # Write the checksum line of a file into dir
  def write_sha256(path, dir)
    checksum = sha256_line(path)
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, "#{File.basename(path)}.sha256"), "#{checksum}\n")
    puts "SHA256 #{checksum}".cyan
  end

  # Copy the checksums folder of a downloads dir into state/downloads. It is
  # committed with the rest of state/, so git records what each package hashed
  # to when it was uploaded. Like a package in the bucket, a recorded checksum
  # is only replaced with FORCE_OVERWRITE.
  def record_checksums(downloads_dir)
    Dir.glob('checksums/**/*.sha256', base: downloads_dir).each do |rel_path|
      checksum_file = File.join(downloads_dir, rel_path)
      state_path = File.join(STATE_DIR, 'downloads', rel_path)
      if File.exist?(state_path) && !FileUtils.identical?(checksum_file, state_path)
        if env('FORCE_OVERWRITE') == 'true'
          puts "Overwriting the recorded #{rel_path}".yellow
        else
          abort "Checksum collision: #{rel_path} differs from the checksum already recorded in state/. " \
                'Use FORCE_OVERWRITE=true to replace.'.red
        end
      end

      FileUtils.mkdir_p(File.dirname(state_path))
      FileUtils.cp(checksum_file, state_path)
      puts "Recorded #{state_path}".cyan
    end
  end

  def setup_aws
    require_command('aws')
    %w[AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY].each { |name| env(name, required: true) }
    ENV['AWS_REQUEST_CHECKSUM_CALCULATION'] ||= 'WHEN_REQUIRED'
    ENV['AWS_RESPONSE_CHECKSUM_VALIDATION'] ||= 'WHEN_REQUIRED'
    # The CLI gives up on a request after 3 tries by default, which lets one
    # slow response from the S3 endpoint fail a whole sync
    ENV['AWS_MAX_ATTEMPTS'] ||= '10'
  end

  def setup_gcloud
    require_command('gcloud')
    Shell.run(['gcloud', 'config', 'set', 'storage/s3_endpoint_url', S3_ENDPOINT, '--quiet'])
  end

  def commit_state(message)
    Dir.chdir(REPO_ROOT) do
      Shell.run(['git', 'add', 'state/'])
      status = Shell.capture(['git', 'diff', '--cached', '--quiet', '--', 'state/'], allowed_exit_codes: [0, 1])
      if status.exitcode.zero?
        puts 'No state/ changes to commit.'.yellow
      else
        Shell.run(['git', 'commit', '-s', '-m', message, '--', 'state/'])
      end
    end
  end
end
