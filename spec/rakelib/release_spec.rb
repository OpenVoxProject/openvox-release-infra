# frozen_string_literal: true

RSpec.describe 'release task' do
  include_context 'with rake tasks'

  let(:rake_files) { 'release' }
  let(:container) { instance_double(Container) }
  let(:yum) { instance_double(Yum, sign: nil, prepare: nil) }
  let(:apt) { instance_double(Apt, sign: nil, prepare: nil) }
  let(:windows) { instance_double(Windows, setup_signing: nil, sign: nil, prepare: nil) }
  # Package files the fake `aws s3 sync` drops into packages/
  let(:downloaded) { [] }

  before do
    ENV['PROJECT'] = 'openvox-agent'
    ENV['VERSION'] = '8.12.1'
    ENV['GPG_PRIVATE_KEY_B64'] = 'secret'

    allow(Shell).to receive(:run) do |cmd, **|
      shell_runs << cmd
      downloaded.each { |name| FileUtils.touch(File.join(packages_dir, name)) } if cmd.include?('sync')
      0
    end

    allow(Infra).to receive_messages(start_container: container, import_gpg_key: nil, teardown_with_chown: nil, commit_state: nil)
    allow(Yum).to receive_messages(new: yum, update_state: nil)
    allow(Apt).to receive_messages(new: apt, update_state: nil)
    allow(Windows).to receive(:new).and_return(windows)
    allow(MacOS).to receive_messages(setup_signing: nil, sign: nil, prepare: nil, teardown_signing: nil)
  end

  def sync_includes
    cmd = shell_runs_matching('sync').first
    cmd.each_cons(2).filter_map { |flag, value| value if flag == '--include' }
  end

  describe 'input validation' do
    it 'requires PROJECT' do
      ENV.delete('PROJECT')
      run_task('release')

      expect(aborted?).to be(true)
      expect(strip_ansi(task_stderr)).to include('PROJECT must be set.')
    end

    it 'requires VERSION' do
      ENV.delete('VERSION')
      run_task('release')

      expect(aborted?).to be(true)
      expect(strip_ansi(task_stderr)).to include('VERSION must be set.')
    end

    it 'rejects unsafe input' do
      ENV['VERSION'] = '1.0; rm -rf /'
      run_task('release')

      expect(aborted?).to be(true)
      expect(strip_ansi(task_stderr)).to include('VERSION contains invalid characters')
    end
  end

  describe 'downloading packages' do
    it 'syncs from the artifacts bucket for the project and version' do
      run_task('release')

      expect(shell_runs_matching('sync').first).to include("s3://#{Infra::ARTIFACTS_BUCKET}/openvox-agent/8.12.1/", "#{packages_dir}/")
    end

    it 'includes every package type without a platform filter' do
      run_task('release')

      expect(sync_includes).to eq(%w[*.rpm *.deb *.dmg *.msi])
    end

    it 'translates platform filters to include globs' do
      ENV['PLATFORMS'] = 'el-9-x86_64, debian-13-amd64'
      run_task('release')

      expect(sync_includes).to eq(
        %w[*.el9.x86_64.rpm *.el9.noarch.rpm *+debian13_amd64.deb *+debian13_all.deb],
      )
    end

    it 'aborts on malformed platform filters' do
      ENV['PLATFORMS'] = 'el9'
      run_task('release')

      expect(aborted?).to be(true)
      expect(strip_ansi(task_stderr)).to include("Malformed platform filter 'el9'")
    end

    it 'rejects platform filters with unsafe characters' do
      pending 'Infra::SAFE_INPUT contains the range `+-~`, which matches characters such as `;` and `|`'
      ENV['PLATFORMS'] = 'el-9-x86_64;ls'
      run_task('release')

      expect(aborted?).to be(true)
    end

    it 'recreates the packages and staging directories' do
      touch_file(File.join(staging_dir, 'stale'))
      touch_file(File.join(packages_dir, 'stale'))
      run_task('release')

      expect(File).not_to exist(File.join(staging_dir, 'stale'))
      expect(File).not_to exist(File.join(packages_dir, 'stale'))
    end
  end

  context 'when nothing was downloaded' do
    it 'does not start a container or sign anything' do
      run_task('release')

      expect(strip_ansi(task_stdout)).to include('Nothing to release')
      expect(Infra).not_to have_received(:start_container)
      expect(Infra).not_to have_received(:commit_state)
    end
  end

  context 'with an rpm' do
    let(:downloaded) { ['openvox-agent-8.12.1-1.el9.x86_64.rpm'] }

    it 'moves the package into packages/rpm' do
      run_task('release')

      expect(File).to exist(File.join(packages_dir, 'rpm', downloaded.first))
    end

    it 'signs and prepares yum metadata only' do
      run_task('release')

      expect(yum).to have_received(:sign).ordered
      expect(yum).to have_received(:prepare).ordered
      expect(Yum).to have_received(:update_state)
      expect(Apt).not_to have_received(:new)
      expect(Windows).not_to have_received(:new)
    end

    it 'imports the GPG key and tears the container down' do
      run_task('release')

      expect(Infra).to have_received(:import_gpg_key).with(container)
      expect(Infra).to have_received(:teardown_with_chown).with(container)
    end

    it 'requires the GPG private key' do
      ENV.delete('GPG_PRIVATE_KEY_B64')
      run_task('release')

      expect(aborted?).to be(true)
      expect(strip_ansi(task_stderr)).to include('GPG_PRIVATE_KEY_B64 must be set.')
    end

    it 'tears the container down when signing fails' do
      allow(yum).to receive(:sign).and_raise(RuntimeError, 'gpg failed')

      expect { run_task('release') }.to raise_error(RuntimeError, 'gpg failed')
      expect(Infra).to have_received(:teardown_with_chown).with(container)
    end
  end

  context 'with a deb' do
    let(:downloaded) { ['openvox-agent_8.12.1-1+debian13_amd64.deb'] }

    it 'signs and prepares apt metadata only' do
      run_task('release')

      expect(apt).to have_received(:sign)
      expect(apt).to have_received(:prepare)
      expect(Apt).to have_received(:update_state)
      expect(Yum).not_to have_received(:new)
    end
  end

  context 'with an msi' do
    let(:downloaded) { ['openvox-agent-8.12.1-x64.msi'] }

    it 'signs windows packages without needing a GPG key' do
      ENV.delete('GPG_PRIVATE_KEY_B64')
      run_task('release')

      expect(aborted?).to be(false)
      expect(windows).to have_received(:setup_signing)
      expect(windows).to have_received(:sign)
      expect(windows).to have_received(:prepare)
      expect(Infra).not_to have_received(:import_gpg_key)
    end
  end

  context 'with a dmg' do
    let(:downloaded) { ['openvox-agent-8.12.1-1.macos-all-arm64.dmg'] }

    it 'skips signing on a non-macOS host' do
      stub_const('RUBY_PLATFORM', 'x86_64-linux')
      run_task('release')

      expect(strip_ansi(task_stdout)).to include('MacOS packages must be signed on a MacOS host')
      expect(MacOS).not_to have_received(:sign)
    end

    it 'signs and prepares on a macOS host' do
      stub_const('RUBY_PLATFORM', 'arm64-darwin24')
      run_task('release')

      expect(MacOS).to have_received(:setup_signing).ordered
      expect(MacOS).to have_received(:sign).ordered
      expect(MacOS).to have_received(:prepare).ordered
      expect(MacOS).to have_received(:teardown_signing)
      expect(Infra).not_to have_received(:start_container)
    end
  end

  describe 'committing state' do
    let(:downloaded) { ['openvox-agent-8.12.1-1.el9.x86_64.rpm'] }

    it 'does not commit in test mode' do
      run_task('release')

      expect(Infra).not_to have_received(:commit_state)
      expect(strip_ansi(task_stdout)).to include('Release complete.')
    end

    it 'commits state when PRODUCTION=true' do
      ENV['PRODUCTION'] = 'true'
      ENV['COMPONENT'] = 'openvox9'
      run_task('release')

      expect(Infra).to have_received(:commit_state).with('Release: openvox-agent 8.12.1 (openvox9)')
    end
  end
end
