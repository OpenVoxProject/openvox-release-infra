# frozen_string_literal: true

require 'fileutils'
require_relative '../utils/infra'

class Windows
  def initialize(container)
    @container = container
  end

  def sign
    msis = Dir.glob(File.join(Infra::PACKAGES_DIR, 'msi', '*.msi'))
    return if msis.empty?

    puts "Signing #{pluralize(msis.size, 'MSI')}...".magenta
    @container.exec('echo "$WINDOWS_SM_CLIENT_CERT_B64" | base64 -d > /tmp/client_cert.p12')

    msis.each do |msi|
      basename = File.basename(msi)
      @container.exec(
        'jsign --storetype DIGICERTONE ' \
        '--keystore "$WINDOWS_SM_HOST" ' \
        '--storepass "${WINDOWS_SM_API_KEY}|/tmp/client_cert.p12|${WINDOWS_SM_CLIENT_CERT_PASSWORD}" ' \
        '--alias "$WINDOWS_CERT_ALIAS" ' \
        "#{Infra::CONTAINER_WORK}/packages/msi/#{basename}"
      )
      @container.exec("osslsigncode verify -in #{Infra::CONTAINER_WORK}/packages/msi/#{basename}")
    end
    puts 'MSI signing complete.'.green
  end

  # Since there is no metadata, all we have to do is copy packages into the
  # staging dir in the right place.
  def prepare
    Dir.glob(File.join(Infra::PACKAGES_DIR, 'msi', '*.msi')).each do |pkg|
      staging_dir = File.join(Infra::STAGING_DIR, 'downloads', 'windows', Infra.component)
      FileUtils.mkdir_p(staging_dir)
      FileUtils.cp(pkg, staging_dir)
    end
  end
end
