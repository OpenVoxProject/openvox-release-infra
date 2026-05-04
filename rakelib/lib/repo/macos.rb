# frozen_string_literal: true

require 'fileutils'
require 'rexml/document'
require 'tmpdir'
require_relative '../utils/infra'

module MacOS
  module_function

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
      Shell.run(['security', 'unlock-keychain', '-p', Infra::MACOS_KEYCHAIN_PASSWORD, Infra::MACOS_KEYCHAIN_PATH])
      entitlements = is_x86 ? ['--entitlements', File.join(Infra::FILES_MACOS, 'ruby_entitlements.plist')] : []

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
      Shell.run(['productsign', '--keychain', Infra::MACOS_KEYCHAIN_PATH,
                 '--sign', Infra.installer_signing_identity,
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
          if File.extname(file) == '.pkg'
            FileUtils.cp(file, staging)
          else
            FileUtils.cp(file, output)
          end
        end
      ensure
        Shell.run(['hdiutil', 'detach', mount, '-force'], allowed_exit_codes: [0, 1])
      end
    end
  end

  def sign_plugin_binary(plugins, entitlements)
    puts 'Signing plugin binary...'.cyan
    plugin = Dir.glob(File.join(plugins, '**', 'puppet-agent-installer-plugin')).first
    abort 'Plugin binary puppet-agent-installer-plugin not found.'.red unless plugin
    codesign_and_verify(plugin, entitlements: entitlements)
  end

  def sign_component_binaries(root, entitlements)
    puts 'Signing component binaries...'.cyan
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
    puts 'Building uninstaller app...'.cyan
    project = Infra.project
    uninstaller_name = project == 'openbolt' ? 'Uninstall OpenBolt' : 'Uninstall OpenVox Agent'
    app_path = File.join(output, "#{uninstaller_name}.app")

    Shell.run(['osacompile', '-o', app_path, File.join(Infra::FILES_MACOS, "#{project}-uninstaller.applescript")])

    FileUtils.mv(
      File.join(output, "#{project}-uninstaller.tool"),
      File.join(app_path, 'Contents', 'Resources', "#{project}-uninstaller.tool")
    )

    FileUtils.cp(
      File.join(Infra::FILES_MACOS, 'openvox.png'),
      File.join(app_path, 'Contents', 'Resources', 'openvox.png')
    )
    FileUtils.cp(
      File.join(Infra::FILES_MACOS, 'openvox.icns'),
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
    sign_cmd = ['codesign', '--timestamp', '--keychain', Infra::MACOS_KEYCHAIN_PATH,
                '-vfs', Infra.app_signing_identity]
    sign_cmd.push('--options', 'runtime') if runtime
    sign_cmd.concat(entitlements)
    sign_cmd << file

    Shell.run(sign_cmd)
    Shell.run(['codesign', '--verify', '--deep', '--strict', '--verbose=2', file])
  end

  def notarize(dmg)
    puts 'Notarizing...'.cyan
    result = Shell.capture([
      'xcrun', 'notarytool', 'submit', dmg,
      '--keychain-profile', Infra::MACOS_NOTARY_PROFILE,
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
