# frozen_string_literal: true

RSpec.describe 'deploy task' do
  include_context 'with rake tasks'

  let(:rake_files) { 'deploy' }
  let(:deb) { File.join(staging_dir, 'apt', 'pool', 'openvox8', 'o', 'openvox-agent', 'openvox-agent_8.12.1-1+debian13_amd64.deb') }
  let(:rpm) { File.join(staging_dir, 'yum', 'openvox8', 'el', '9', 'x86_64', 'openvox-agent-8.12.1-1.el9.x86_64.rpm') }
  let(:msi) { File.join(staging_dir, 'downloads', 'windows', 'openvox8', 'openvox-agent-8.12.1-x64.msi') }

  def stage_everything
    [deb, rpm, msi].each { |path| touch_file(path) }
    touch_file(File.join(staging_dir, 'yum', 'openvox8', 'el', '9', 'x86_64', 'repodata', 'repomd.xml'))
    touch_file(File.join(staging_dir, 'apt', 'dists', 'debian13', 'Release'))
  end

  def existing_on_s3
    stub_capture { |cmd| Shell::Result.new('2026-01-01 1 file', 0) if cmd.include?('ls') }
  end

  it 'aborts when there is no staging directory' do
    FileUtils.rm_rf(staging_dir)
    run_task('deploy')

    expect(aborted?).to be(true)
    expect(strip_ansi(task_stderr)).to include('staging/ directory not found')
  end

  context 'with staged packages and metadata' do
    before { stage_everything }

    it 'syncs packages before metadata' do
      run_task('deploy')

      expect(aborted?).to be(false)
      syncs = shell_runs_matching('sync')
      expect(syncs.size).to eq(5)
      expect(syncs[0]).to include("#{staging_dir}/apt/pool/", "#{Infra::APT_TEST_BUCKET}/pool/")
      expect(syncs[1]).to include('--include', '*.rpm')
      expect(syncs[2]).to include("#{staging_dir}/downloads/", "#{Infra::DOWNLOADS_TEST_BUCKET}/")
      expect(syncs[3]).to include('--exclude', '*.rpm')
      expect(syncs[4]).to include("#{staging_dir}/apt/dists/", "#{Infra::APT_TEST_BUCKET}/dists/")
      expect(strip_ansi(task_stdout)).to include('Deploy complete.')
    end

    it 'uploads to the production buckets when PRODUCTION=true' do
      ENV['PRODUCTION'] = 'true'
      run_task('deploy')

      expect(shell_runs_matching('sync').flatten).to include('s3://openvox-apt/pool/', 's3://openvox-yum/')
    end

    it 'checks every package against S3 before uploading' do
      run_task('deploy')

      checked = shell_captures.select { |cmd| cmd.include?('ls') }.map(&:last)
      expect(checked).to contain_exactly(
        "#{Infra::APT_TEST_BUCKET}/pool/openvox8/o/openvox-agent/openvox-agent_8.12.1-1+debian13_amd64.deb",
        "#{Infra::YUM_TEST_BUCKET}/openvox8/el/9/x86_64/openvox-agent-8.12.1-1.el9.x86_64.rpm",
        "#{Infra::DOWNLOADS_TEST_BUCKET}/windows/openvox8/openvox-agent-8.12.1-x64.msi",
      )
    end

    context 'when packages already exist on S3' do
      before { existing_on_s3 }

      it 'refuses to overwrite them' do
        run_task('deploy')

        expect(aborted?).to be(true)
        expect(strip_ansi(task_stderr)).to include('Refusing to overwrite existing packages')
        expect(shell_runs_matching('sync')).to be_empty
      end

      it 'overwrites them when FORCE_OVERWRITE=true' do
        ENV['FORCE_OVERWRITE'] = 'true'
        run_task('deploy')

        expect(aborted?).to be(false)
        expect(shell_captures.select { |cmd| cmd.include?('ls') }).to be_empty
        expect(shell_runs_matching('sync').size).to eq(5)
      end
    end
  end

  context 'with only yum packages staged' do
    before { touch_file(rpm) }

    it 'only syncs yum' do
      run_task('deploy')

      syncs = shell_runs_matching('sync')
      expect(syncs.size).to eq(2)
      expect(syncs.flatten).not_to include("#{staging_dir}/apt/pool/", "#{staging_dir}/downloads/")
    end
  end

  context 'when a phase fails' do
    before do
      stage_everything
      allow(Shell).to receive(:run).and_raise(RuntimeError, 'boom')
    end

    it 'aborts with a partial deploy warning' do
      run_task('deploy')

      expect(aborted?).to be(true)
      expect(strip_ansi(task_stderr)).to match(/PARTIAL DEPLOY: Uploading packages failed.*boom/m)
    end
  end
end
