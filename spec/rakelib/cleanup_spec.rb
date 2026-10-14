# frozen_string_literal: true

RSpec.describe 'cleanup task' do
  include_context 'with rake tasks'

  let(:rake_files) { 'cleanup' }
  let(:apt_objects) { [] }
  let(:yum_objects) { [] }

  def s3_keys(prefix, bucket_subpath)
    keys = (prefix == 'pool/') ? apt_objects : yum_objects
    return 'null' if keys.empty?

    JSON.generate(keys.map { |key| "#{bucket_subpath}/#{key}" })
  end

  before do
    stub_capture do |cmd|
      next unless cmd.include?('list-objects-v2')

      prefix = cmd[cmd.index('--prefix') + 1]
      if prefix.start_with?('repo_test/apt/')
        Shell::Result.new(s3_keys('pool/', 'repo_test/apt'), 0)
      else
        Shell::Result.new(s3_keys('', 'repo_test/yum'), 0)
      end
    end
    allow(Apt).to receive(:referenced_packages).and_return(Set['pool/openvox8/o/openvox-agent/kept.deb'])
    allow(Yum).to receive(:referenced_packages).and_return(Set['openvox8/el/9/x86_64/kept.rpm'])
  end

  def add_state(apt: true, yum: true)
    touch_file(File.join(state_dir, 'apt', 'dists', 'debian13', 'openvox8', 'binary-amd64', 'Packages')) if apt
    touch_file(File.join(state_dir, 'yum', 'openvox8', 'el', '9', 'x86_64', 'repodata', 'primary.xml.gz')) if yum
  end

  it 'refuses to run without any state metadata' do
    run_task('cleanup')

    expect(aborted?).to be(true)
    expect(strip_ansi(task_stderr)).to include('Refusing to run cleanup with empty state')
  end

  context 'with state metadata' do
    before { add_state }

    it 'reports nothing to do when every object is referenced' do
      apt_objects.push('pool/openvox8/o/openvox-agent/kept.deb')
      yum_objects.push('openvox8/el/9/x86_64/kept.rpm')

      run_task('cleanup')

      expect(strip_ansi(task_stdout)).to include('No orphaned packages found.')
      expect(shell_runs_matching('rm')).to be_empty
    end

    it 'deletes orphaned apt and yum packages when CONFIRM_CLEANUP=true' do
      ENV['CONFIRM_CLEANUP'] = 'true'
      apt_objects.push('pool/openvox8/o/openvox-agent/kept.deb', 'pool/openvox8/o/openvox-agent/orphan.deb')
      yum_objects.push('openvox8/el/9/x86_64/kept.rpm', 'openvox8/el/9/x86_64/orphan.rpm')

      run_task('cleanup')

      removed = shell_runs_matching('rm').map(&:last)
      expect(removed).to contain_exactly(
        "#{Infra::APT_TEST_BUCKET}/pool/openvox8/o/openvox-agent/orphan.deb",
        "#{Infra::YUM_TEST_BUCKET}/openvox8/el/9/x86_64/orphan.rpm",
      )
    end

    it 'ignores rpms at the yum bucket root' do
      ENV['CONFIRM_CLEANUP'] = 'true'
      yum_objects.push('openvox8-release-el-9.noarch.rpm', 'openvox8/el/9/x86_64/index.html')

      run_task('cleanup')

      expect(shell_runs_matching('rm')).to be_empty
    end

    it 'prompts for confirmation and deletes on "y"' do
      allow($stdin).to receive(:gets).and_return("y\n")
      apt_objects.push('pool/openvox8/o/openvox-agent/orphan.deb')

      run_task('cleanup')

      expect(shell_runs_matching('rm').size).to eq(1)
    end

    it 'does not delete when the prompt is declined' do
      pending 'cleanup.rake uses `return` inside the task block, which raises LocalJumpError (should be `next`)'
      allow($stdin).to receive(:gets).and_return("n\n")
      apt_objects.push('pool/openvox8/o/openvox-agent/orphan.deb')

      expect { run_task('cleanup') }.not_to raise_error
      expect(shell_runs_matching('rm')).to be_empty
    end
  end

  context 'with only apt state' do
    before { add_state(yum: false) }

    it 'skips the yum check' do
      run_task('cleanup')

      expect(strip_ansi(task_stdout)).to include('No yum state/ metadata found')
      expect(Yum).not_to have_received(:referenced_packages)
    end
  end

  context 'with only yum state' do
    before { add_state(apt: false) }

    it 'skips the apt check' do
      run_task('cleanup')

      expect(strip_ansi(task_stdout)).to include('No apt state/ metadata found')
      expect(Apt).not_to have_received(:referenced_packages)
    end
  end
end
