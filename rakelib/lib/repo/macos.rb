# frozen_string_literal: true

require 'base64'
require 'fileutils'
require 'rexml/document'
require 'securerandom'
require 'tempfile'
require 'tmpdir'
require_relative '../utils/infra'
require_relative '../utils/shell'

module MacOS
  FILES_DIR = File.join(Infra::REPO_ROOT, 'files', 'macos')
  KEYCHAIN_PATH = '/tmp/openvox-signing.keychain-db'
  # Random per-run so a stranded keychain (local crash, killed CI job) can't
  # be unlocked by anyone who knows the source.
  KEYCHAIN_PASSWORD = SecureRandom.hex(32)
  NOTARY_PROFILE = 'openvox-notary'

  module_function

  def app_signing_identity = Infra.env('MACOS_APP_SIGNING_IDENTITY', required: true)
  def installer_signing_identity = Infra.env('MACOS_INSTALLER_SIGNING_IDENTITY', required: true)

  def setup_signing
    %w[MACOS_APP_CERT_B64 MACOS_INSTALLER_CERT_B64 MACOS_CERT_PASSWORD
       MACOS_APP_SIGNING_IDENTITY MACOS_INSTALLER_SIGNING_IDENTITY
       MACOS_NOTARY_APPLE_ID MACOS_NOTARY_TEAM_ID MACOS_NOTARY_APP_TOKEN].each { |name| Infra.env(name, required: true) }

    Shell.run(['security', 'create-keychain', '-p', KEYCHAIN_PASSWORD, KEYCHAIN_PATH], print_command: false)
    Shell.run(['security', 'set-keychain-settings', '-lut', '21600', KEYCHAIN_PATH])
    Shell.run(['security', 'unlock-keychain', '-p', KEYCHAIN_PASSWORD, KEYCHAIN_PATH], print_command: false)

    # Add to search list so codesign can find it
    existing = Shell.capture(['security', 'list-keychains', '-d', 'user']).output
    keychains = existing.scan(/"([^"]+)"/).flatten
    keychains.unshift(KEYCHAIN_PATH)
    Shell.run(['security', 'list-keychains', '-d', 'user', '-s', *keychains])

    # Import certificates
    import_cert(ENV.fetch('MACOS_APP_CERT_B64'), ENV.fetch('MACOS_CERT_PASSWORD'))
    import_cert(ENV.fetch('MACOS_INSTALLER_CERT_B64'), ENV.fetch('MACOS_CERT_PASSWORD'))

    # Store notarytool credentials
    Shell.run([
      'xcrun', 'notarytool', 'store-credentials', NOTARY_PROFILE,
      '--apple-id', ENV.fetch('MACOS_NOTARY_APPLE_ID'),
      '--team-id', ENV.fetch('MACOS_NOTARY_TEAM_ID'),
      '--password', ENV.fetch('MACOS_NOTARY_APP_TOKEN'),
      '--keychain', KEYCHAIN_PATH
    ], print_command: false)
  end

  def teardown_signing
    Shell.run(['security', 'delete-keychain', KEYCHAIN_PATH], allowed_exit_codes: [0, 1])

    # delete-keychain removes the file but doesn't always clean the search list
    existing = Shell.capture(['security', 'list-keychains', '-d', 'user']).output
    keychains = existing.scan(/"([^"]+)"/).flatten.reject { |path| path == KEYCHAIN_PATH }
    Shell.run(['security', 'list-keychains', '-d', 'user', '-s', *keychains])
  end

  def import_cert(cert_b64, password)
    certfile = Tempfile.new(['cert', '.p12'])
    certfile.binmode
    certfile.write(Base64.decode64(cert_b64))
    certfile.close
    Shell.run([
      'security', 'import', certfile.path,
      '-k', KEYCHAIN_PATH,
      '-P', password,
      '-T', '/usr/bin/codesign',
      '-T', '/usr/bin/productsign'
    ], print_command: false)
  ensure
    certfile&.unlink
  end

  def sign
    dmgs = Dir.glob(File.join(Infra::PACKAGES_DIR, 'dmg', '*.dmg'))
    return if dmgs.empty?

    puts "Signing #{pluralize(dmgs.size, 'DMG')}...".magenta
    dmgs.each { |dmg| sign_dmg(dmg) }
    puts 'MacOS signing complete.'.green
  end

  # Since there is no metadata, all we have to do is copy packages into the
  # staging dir in the right place.
  def prepare
    Dir.glob(File.join(Infra::PACKAGES_DIR, 'dmg', '*.dmg')).each do |pkg|
      staging_dir = File.join(Infra::STAGING_DIR, 'downloads', 'mac', Infra.component)
      FileUtils.mkdir_p(staging_dir)
      FileUtils.cp(pkg, staging_dir)
    end
  end

  # This is an arduous process. Vanagon creates the fully packaged .dmg file with
  # nothing in it signed, so we have to extract all the pieces, sign them, then
  # repackage them. Someday, we should make this whole process better end-to-end, but
  # this strategy keeps signing concerns out of vanagon and confined to this tool. The
  # signing mechanisms in vanagon are very much written with Perforce's infrastructure
  # and signing strategy in mind, which are not compatible with what we do in OpenVox.
  #
  # On x86_64, Ruby's FFI gem uses JIT trampolines that are incompatible with
  # Apple's hardened runtime. We provide ruby_entitlements.plist to grant
  # allow-jit and allow-unsigned-executable-memory exceptions when codesigning.
  # On arm64, FFI works differently and no entitlements are needed.
  #
  # Flow:
  #
  #                     DMG file
  #                        │
  #                        ▼
  #   ┌────────────────────────────────────────────┐
  #   │ Mount DMG                                  │
  #   │ Copy .pkg ──► staging/                     │
  #   │ Copy non-pkg ──► output/                   │
  #   │ Unmount                                    │
  #   └────────────────────┬───────────────────────┘
  #                        │
  #                        ▼
  #              staging/<installer>.pkg
  #                        │
  #                        ▼
  #   ┌────────────────────────────────────────────┐
  #   │ pkgutil --expand                           │
  #   │ ► staging/installer_expanded/              │
  #   │   ├── Distribution                         │
  #   │   ├── Plugins (archive)                    │
  #   │   └── <component>.pkg/                     │
  #   │       ├── Payload (archive)                │
  #   │       ├── Scripts/                         │
  #   │       └── PackageInfo                      │
  #   └────────────────────┬───────────────────────┘
  #                        │
  #           ┌────────────┴────────────┐
  #           ▼                         ▼
  #   ┌────────────────┐     ┌──────────────────────┐
  #   │ cpio extract   │     │ cpio extract         │
  #   │ Plugins        │     │ Payload              │
  #   │ ► staging/     │     │ ► staging/payload/   │
  #   │   plugins/     │     │   (/opt/puppetlabs)  │
  #   └───────┬────────┘     └──────────┬───────────┘
  #           │                         │
  #           ▼                         ▼
  #   ┌────────────────┐     ┌──────────────────────┐
  #   │ codesign       │     │ codesign all         │
  #   │ plugin binary  │     │ binaries + dylibs    │
  #   │ (in-place)     │     │ (in-place)           │
  #   └───────┬────────┘     └──────────┬───────────┘
  #           │                         │
  #           │                         ▼
  #           │              ┌──────────────────────────────────┐
  #           │              │ pkgbuild                         │
  #           │              │   --root staging/payload/        │
  #           │              │   --scripts .../Scripts          │
  #           │              │   ► build/component.pkg          │
  #           │              └──────────┬───────────────────────┘
  #           │                         │
  #           └────────────┬────────────┘
  #                        ▼
  #   ┌────────────────────────────────────────────┐
  #   │ productbuild                               │
  #   │   build/component.pkg                      │
  #   │   + installer_expanded/Distribution        │
  #   │   + staging/plugins/                       │
  #   │   ► build/unsigned-installer.pkg           │
  #   └────────────────────┬───────────────────────┘
  #                        │
  #                        ▼
  #   ┌────────────────────────────────────────────┐
  #   │ productsign                                │
  #   │   ► output/<installer>.pkg                 │
  #   └────────────────────┬───────────────────────┘
  #                        │
  #                        ▼
  #   ┌────────────────────────────────────────────┐
  #   │ build_uninstaller_app                      │
  #   │   ► output/<Uninstall>.app                 │
  #   └────────────────────┬───────────────────────┘
  #                        │
  #                        ▼
  #              output/ now contains:
  #              ├── <installer>.pkg  (signed)
  #              ├── <Uninstall>.app  (signed)
  #              └── (any non-pkg files from DMG)
  #                        │
  #                        ▼
  #   ┌────────────────────────────────────────────┐
  #   │ hdiutil create -srcfolder output/ ► .dmg   │
  #   │ codesign + notarize the DMG                │
  #   └────────────────────────────────────────────┘
  def sign_dmg(dmg)
    is_x86 = dmg.include?('x86_64')
    basename = File.basename(dmg)
    puts "Processing #{basename}...".magenta

    Dir.mktmpdir('signing') do |tmp|
      staging = File.join(tmp, 'staging')
      output = File.join(tmp, 'output')
      build = File.join(tmp, 'build')
      FileUtils.mkdir_p([staging, output, build])

      extract_dmg(dmg, staging, output)
      FileUtils.rm_f(dmg)

      installer_pkg = Dir.glob(File.join(staging, '*.pkg')).first
      abort "No .pkg found in DMG: #{basename}".red unless installer_pkg

      installer_expanded = File.join(staging, 'installer_expanded')
      Shell.run(['pkgutil', '--expand', installer_pkg, installer_expanded])

      plugins = File.join(staging, 'plugins')
      FileUtils.mkdir_p(plugins)
      Dir.chdir(plugins) { Shell.run(['bash', '-o', 'pipefail', '-c', "cat '#{installer_expanded}/Plugins' | gunzip -dc | cpio -i"]) }

      component_pkg = Dir.glob(File.join(installer_expanded, '*.pkg')).first
      abort "No component .pkg found in installer: #{basename}".red unless component_pkg

      payload = File.join(staging, 'payload')
      FileUtils.mkdir_p(payload)
      Dir.chdir(payload) { Shell.run(['bash', '-o', 'pipefail', '-c', "cat '#{component_pkg}/Payload' | gunzip -dc | cpio -i"]) }
      abort 'Extraction failed: /opt/puppetlabs not found'.red unless Dir.exist?(File.join(payload, 'opt', 'puppetlabs'))

      # MacOS will re-lock keychains after some time, and notarization takes a while,
      # so we unlock every time through the loop.
      Shell.run(['security', 'unlock-keychain', '-p', KEYCHAIN_PASSWORD, KEYCHAIN_PATH], print_command: false)
      entitlements = is_x86 ? ['--entitlements', File.join(FILES_DIR, 'ruby_entitlements.plist')] : []

      sign_plugin_binary(plugins, entitlements)
      sign_component_binaries(payload, entitlements)

      identifier, version = read_package_info(component_pkg)

      component_pkg_path = File.join(build, File.basename(component_pkg))
      Shell.run(['pkgbuild', '--root', payload, '--scripts', File.join(component_pkg, 'Scripts'),
                 '--identifier', identifier, '--version', version, '--preserve-xattr',
                 '--install-location', '/', component_pkg_path])

      unsigned_pkg_path = File.join(build, 'unsigned-installer.pkg')
      Shell.run(['productbuild', '--distribution', File.join(installer_expanded, 'Distribution'),
                 '--identifier', "#{identifier}-installer", '--package-path', build,
                 '--plugins', plugins, unsigned_pkg_path])

      signed_pkg_path = File.join(output, File.basename(installer_pkg))
      Shell.run(['productsign', '--keychain', KEYCHAIN_PATH,
                 '--sign', installer_signing_identity,
                 unsigned_pkg_path, signed_pkg_path])

      build_uninstaller_app(output)

      output_dmg = build_dmg(output, dmg, identifier, version)
      codesign_and_verify(output_dmg, runtime: false)
      notarize(output_dmg)
    end
  end

  def extract_dmg(dmg, staging, output)
    Dir.mktmpdir('dmg-mount') do |mount|
      Shell.run(['hdiutil', 'attach', dmg, '-mountpoint', mount, '-nobrowse', '-noverify', '-noautoopen'])
      begin
        Dir.glob(File.join(mount, '*')).each do |file|
          target = File.extname(file) == '.pkg' ? staging : output
          FileUtils.cp(file, target)
        end
      ensure
        Shell.run(['hdiutil', 'detach', mount, '-force'], allowed_exit_codes: [0, 1])
      end
    end
  end

  def sign_plugin_binary(plugins, entitlements)
    puts 'Signing plugin binary...'.magenta
    plugin = Dir.glob(File.join(plugins, '**', 'puppet-agent-installer-plugin')).first
    abort 'Plugin binary puppet-agent-installer-plugin not found.'.red unless plugin
    codesign_and_verify(plugin, entitlements: entitlements)
  end

  def sign_component_binaries(root, entitlements)
    puts 'Signing component binaries...'.magenta
    projdir = Infra.project == 'openbolt' ? 'bolt' : 'puppet'

    paths_with_binaries = {
      File.join(root, 'opt', 'puppetlabs', 'bin') => '*',
      File.join(root, 'opt', 'puppetlabs', projdir, 'bin') => '*',
      File.join(root, 'opt', 'puppetlabs', projdir, 'lib', 'ruby', 'vendor_gems', 'bin') => '*',
      File.join(root, 'opt', 'puppetlabs', projdir, 'lib') => '*.{dylib,bundle}',
    }

    paths_with_binaries.each do |path, pattern|
      Dir.glob(File.join(path, '**', pattern)).each do |file|
        next if File.symlink?(file)

        # x86_64 FFI uses JIT trampolines incompatible with hardened runtime
        use_runtime = !(entitlements.any? && file.match?(/ffi_c|libffi/))
        codesign_and_verify(file, entitlements: entitlements, runtime: use_runtime)
      end
    end
  end

  def read_package_info(component_pkg)
    pkg_info_path = File.join(component_pkg, 'PackageInfo')
    doc = REXML::Document.new(File.read(pkg_info_path))
    identifier = doc.root.attributes['identifier']
    version = doc.root.attributes['version']
    abort "PackageInfo missing 'identifier' attribute in #{pkg_info_path}".red unless identifier
    abort "PackageInfo missing 'version' attribute in #{pkg_info_path}".red unless version
    [identifier, version]
  end

  # This is only written for OpenVox Agent and OpenBolt right now. Might be good to make this more
  # generic in the future.
  def build_uninstaller_app(output)
    puts 'Building uninstaller app...'.magenta
    project = Infra.project
    uninstaller_name = project == 'openbolt' ? 'Uninstall OpenBolt' : 'Uninstall OpenVox Agent'
    app_path = File.join(output, "#{uninstaller_name}.app")

    Shell.run(['osacompile', '-o', app_path, File.join(FILES_DIR, "#{project}-uninstaller.applescript")])

    FileUtils.mv(
      File.join(output, "#{project}-uninstaller.tool"),
      File.join(app_path, 'Contents', 'Resources', "#{project}-uninstaller.tool")
    )

    FileUtils.cp(
      File.join(FILES_DIR, 'openvox.png'),
      File.join(app_path, 'Contents', 'Resources', 'openvox.png')
    )
    FileUtils.cp(
      File.join(FILES_DIR, 'openvox.icns'),
      File.join(app_path, 'Contents', 'Resources', 'applet.icns')
    )

    codesign_and_verify(app_path)
  end

  def build_dmg(output, original_dmg, identifier, version)
    vol_name = "#{identifier.split('.')[-1]}-#{version}"
    Shell.run([
      'hdiutil', 'create',
      '-volname', vol_name,
      '-fs', 'APFS',
      '-format', 'ULFO',
      '-srcfolder', output,
      original_dmg
    ])
    original_dmg
  end

  def codesign_and_verify(file, entitlements: [], runtime: true)
    sign_cmd = ['codesign', '--timestamp', '--keychain', KEYCHAIN_PATH,
                '-vfs', app_signing_identity]
    sign_cmd.push('--options', 'runtime') if runtime
    sign_cmd.concat(entitlements)
    sign_cmd << file

    Shell.run(sign_cmd)
    Shell.run(['codesign', '--verify', '--deep', '--strict', '--verbose=2', file])
  end

  def notarize(dmg)
    puts 'Notarizing...'.magenta
    result = Shell.capture([
      'xcrun', 'notarytool', 'submit', dmg,
      '--keychain-profile', NOTARY_PROFILE,
      '--wait'
    ], silent: false)
    unless result.output.match?(/^\s*status: Accepted$/i)
      submission_id = result.output[/^\s*id: (.+)$/, 1]
      abort "Notarization failed. Run `xcrun notarytool log #{submission_id}` for details.".red
    end
    Shell.run(['xcrun', 'stapler', 'staple', dmg])
    Shell.run(['spctl', '--assess', '--type', 'install', '--verbose', dmg])
  end
end
