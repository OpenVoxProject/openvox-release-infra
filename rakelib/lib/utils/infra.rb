# frozen_string_literal: true

require 'base64'
require 'shellwords'
require 'tempfile'
require_relative 'container'
require_relative 'shell'

module Infra
  GPG_KEY_ID = 'openvox@voxpupuli.org'
  S3_ENDPOINT = 'https://s3.osuosl.org'
  ARTIFACTS_BUCKET = ENV.fetch('ARTIFACTS_BUCKET', 'openvox-artifacts')

  APT_PRODUCTION_BUCKET = 's3://openvox-apt'
  YUM_PRODUCTION_BUCKET = 's3://openvox-yum'
  DOWNLOADS_PRODUCTION_BUCKET = "s3://#{ARTIFACTS_BUCKET}/downloads"
  GCS_PRODUCTION_BUCKET = 'gs://openvox-backup'

  APT_TEST_BUCKET = "s3://#{ARTIFACTS_BUCKET}/repo_test/apt"
  YUM_TEST_BUCKET = "s3://#{ARTIFACTS_BUCKET}/repo_test/yum"
  DOWNLOADS_TEST_BUCKET = "s3://#{ARTIFACTS_BUCKET}/repo_test/downloads"
  GCS_TEST_BUCKET = 'gs://openvox-backup-test'

  REPO_ROOT = File.expand_path('../../..', __dir__)
  PACKAGES_DIR = File.join(REPO_ROOT, 'packages')
  STAGING_DIR = File.join(REPO_ROOT, 'staging')
  STATE_DIR = File.join(REPO_ROOT, 'state')
  CONTAINER_WORK = '/work'

  FILES_MACOS = File.join(REPO_ROOT, 'files', 'macos')
  MACOS_KEYCHAIN_PATH = '/tmp/openvox-signing.keychain-db'
  MACOS_KEYCHAIN_PASSWORD = 'signing-temp'
  MACOS_NOTARY_PROFILE = 'openvox-notary'

  CONTAINER_TAG = 'release:latest'
  DOCKERFILE = File.join(REPO_ROOT, 'Dockerfile')

  SAFE_INPUT = /\A[a-zA-Z0-9._+-]+\z/

  module_function

  def validate_input(name, value)
    return nil if value.nil? || value.empty?
    abort "#{name} contains invalid characters: #{value.inspect}. Only alphanumeric, '.', '_', '+', '-' are allowed.".red unless value.match?(SAFE_INPUT)
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
  def app_signing_identity = env('MACOS_APP_SIGNING_IDENTITY', required: true)
  def installer_signing_identity = env('MACOS_INSTALLER_SIGNING_IDENTITY', required: true)

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
  def s3_cmd = "aws s3 --endpoint-url=#{S3_ENDPOINT}"
  def s3_sync = "#{s3_cmd} sync --no-progress"

  def start_container
    Container.build_image(dockerfile: DOCKERFILE, tag: CONTAINER_TAG) unless Container.image_exists?(CONTAINER_TAG)

    name = CONTAINER_TAG.split(':').first
    container_env = {}
    %w[GPG_PRIVATE_KEY_B64 WINDOWS_SM_API_KEY WINDOWS_SM_HOST WINDOWS_SM_CLIENT_CERT_B64 WINDOWS_SM_CLIENT_CERT_PASSWORD WINDOWS_CERT_ALIAS].each do |var|
      value = env(var)
      container_env[var] = value if value
    end

    container = Container.new(name: name, image: CONTAINER_TAG)
    container.start(command: 'sleep infinity', volumes: { REPO_ROOT => CONTAINER_WORK }, env: container_env)
    container
  end

  def require_command(*names)
    names.each do |name|
      result = Shell.capture(['which', name], allowed_exit_codes: [0, 1], print_command: false)
      abort "#{name} is required but not found in PATH.".red unless result.exitcode.zero?
    end
  end

  def import_gpg_key(container)
    container.exec('set -euo pipefail; echo "$GPG_PRIVATE_KEY_B64" | base64 -d | gpg --batch --import')
    container.exec("gpg --list-secret-keys '#{GPG_KEY_ID}' >/dev/null")
    container.exec("printf 'trust\\n5\\ny\\n' | gpg --batch --command-fd 0 --edit-key '#{GPG_KEY_ID}'")
    container.exec("gpg --export --armor '#{GPG_KEY_ID}' > /tmp/gpg-pub.key && rpm --import /tmp/gpg-pub.key && rm /tmp/gpg-pub.key")
  end

  def sign_rpm(container, host_path)
    escaped = Shellwords.shellescape(container_path(host_path))
    container.exec("GPG_TTY= rpmsign --addsign --define '%_gpg_name #{GPG_KEY_ID}' #{escaped}")
    result = container.capture("rpm --checksig #{escaped}", silent: false)
    return unless result.output.match?(/NOT OK|NOKEY|MISSING KEYS|NOT INSTALLED/i)

    abort "RPM signature verification failed for #{File.basename(host_path)}: #{result.output}".red
  end

  def sign_deb(container, host_path)
    escaped = Shellwords.shellescape(container_path(host_path))
    container.exec("debsigs --sign=origin -k #{GPG_KEY_ID} #{escaped}")
    container.exec("debsigs --verify #{escaped}")
  end

  def gpg_detach_sign(container, host_path)
    escaped = Shellwords.shellescape(container_path(host_path))
    container.exec(
      "gpg --batch --yes --default-key '#{GPG_KEY_ID}' --digest-algo SHA512 " \
      "--detach-sign --armor --output #{escaped}.asc #{escaped}"
    )
    container.exec("gpg --verify #{escaped}.asc #{escaped}")
  end

  def setup_aws
    require_command('aws')
    %w[AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY].each { |name| env(name, required: true) }
    ENV['AWS_REQUEST_CHECKSUM_CALCULATION'] ||= 'WHEN_REQUIRED'
    ENV['AWS_RESPONSE_CHECKSUM_VALIDATION'] ||= 'WHEN_REQUIRED'
  end

  def setup_macos_signing
    %w[MACOS_APP_CERT_B64 MACOS_INSTALLER_CERT_B64 MACOS_CERT_PASSWORD
       MACOS_APP_SIGNING_IDENTITY MACOS_INSTALLER_SIGNING_IDENTITY
       MACOS_NOTARY_APPLE_ID MACOS_NOTARY_TEAM_ID MACOS_NOTARY_APP_TOKEN].each { |name| env(name, required: true) }

    Shell.run(['security', 'create-keychain', '-p', MACOS_KEYCHAIN_PASSWORD, MACOS_KEYCHAIN_PATH])
    Shell.run(['security', 'set-keychain-settings', '-lut', '21600', MACOS_KEYCHAIN_PATH])
    Shell.run(['security', 'unlock-keychain', '-p', MACOS_KEYCHAIN_PASSWORD, MACOS_KEYCHAIN_PATH])

    # Add to search list so codesign can find it
    existing = Shell.capture(['security', 'list-keychains', '-d', 'user']).output
    keychains = existing.scan(/"([^"]+)"/).flatten
    keychains.unshift(MACOS_KEYCHAIN_PATH)
    Shell.run(['security', 'list-keychains', '-d', 'user', '-s', *keychains])

    # Import certificates
    import_macos_cert(ENV.fetch('MACOS_APP_CERT_B64'), ENV.fetch('MACOS_CERT_PASSWORD'))
    import_macos_cert(ENV.fetch('MACOS_INSTALLER_CERT_B64'), ENV.fetch('MACOS_CERT_PASSWORD'))

    # Store notarytool credentials
    Shell.run([
      'xcrun', 'notarytool', 'store-credentials', MACOS_NOTARY_PROFILE,
      '--apple-id', ENV.fetch('MACOS_NOTARY_APPLE_ID'),
      '--team-id', ENV.fetch('MACOS_NOTARY_TEAM_ID'),
      '--password', ENV.fetch('MACOS_NOTARY_APP_TOKEN'),
      '--keychain', MACOS_KEYCHAIN_PATH
    ])
  end

  def teardown_macos_signing
    Shell.run(['security', 'delete-keychain', MACOS_KEYCHAIN_PATH], allowed_exit_codes: [0, 1])
  end

  def import_macos_cert(cert_b64, password)
    certfile = Tempfile.new(['cert', '.p12'])
    certfile.binmode
    certfile.write(Base64.decode64(cert_b64))
    certfile.close
    Shell.run([
      'security', 'import', certfile.path,
      '-k', MACOS_KEYCHAIN_PATH,
      '-P', password,
      '-T', '/usr/bin/codesign',
      '-T', '/usr/bin/productsign'
    ])
  ensure
    certfile&.unlink
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
