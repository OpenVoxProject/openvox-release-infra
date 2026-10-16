# frozen_string_literal: true

# Loads the rake file(s) named by `rake_files` into a fresh Rake application,
# points Infra at temporary directories and replaces every external command
# (aws, gcloud, docker, git) with a recording stub.
#
# Available in examples:
#   run_task('name')   - invoke a task; stdout/stderr are captured and a
#                        SystemExit (abort) is recorded instead of raised
#   task_stdout, task_stderr, aborted?
#   shell_runs         - argv of every Shell.run call
#   shell_captures     - argv of every Shell.capture call
#   staging_dir, state_dir, packages_dir
RSpec.shared_context 'with rake tasks' do
  let(:rake_files) { raise NotImplementedError, 'define let(:rake_files)' }
  let(:tmp_root) { Dir.mktmpdir('release-infra-spec') }
  let(:staging_dir) { File.join(tmp_root, 'staging') }
  let(:state_dir) { File.join(tmp_root, 'state') }
  let(:packages_dir) { File.join(tmp_root, 'packages') }
  let(:shell_runs) { [] }
  let(:shell_captures) { [] }
  let(:task_stdout) { @task_stdout.string }
  let(:task_stderr) { @task_stderr.string }

  let(:env_vars_to_clear) do
    %w[
      APT_BUCKET YUM_BUCKET DOWNLOADS_BUCKET GCS_BUCKET GCS_SOURCE COMPONENT COMMIT
      CONFIRM_CLEANUP CONFIRM_RESET CONFIRM_RESTORE DISTS FORCE_OVERWRITE
      GPG_PRIVATE_KEY_B64 PLATFORMS PRODUCTION PROJECT TARGET TIMESTAMP VERSION
    ]
  end

  before do
    @saved_env = ENV.to_h
    env_vars_to_clear.each { |name| ENV.delete(name) }
    ENV['AWS_ACCESS_KEY_ID'] = 'test'
    ENV['AWS_SECRET_ACCESS_KEY'] = 'test'

    FileUtils.mkdir_p([staging_dir, state_dir, packages_dir])
    stub_const('Infra::REPO_ROOT', tmp_root)
    stub_const('Infra::STAGING_DIR', staging_dir)
    stub_const('Infra::STATE_DIR', state_dir)
    stub_const('Infra::PACKAGES_DIR', packages_dir)

    allow($stdin).to receive(:tty?).and_return(false)
    allow(Infra).to receive_messages(setup_aws: nil, setup_gcloud: nil)

    allow(Shell).to receive(:run) do |cmd, **|
      shell_runs << cmd
      0
    end
    allow(Shell).to receive(:capture) do |cmd, **|
      shell_captures << cmd
      Shell::Result.new('', 0)
    end

    Rake.application = Rake::Application.new
    Array(rake_files).each { |name| load_rake_file(name) }
  end

  after do
    FileUtils.rm_rf(tmp_root)
    ENV.replace(@saved_env)
  end

  def load_rake_file(name)
    verbose = $VERBOSE
    $VERBOSE = nil # top-level constants in the rake files are redefined on every load
    load File.join(RAKELIB, "#{name}.rake")
  ensure
    $VERBOSE = verbose
  end

  def run_task(name)
    @aborted = false
    @task_stdout = StringIO.new
    @task_stderr = StringIO.new
    original = [$stdout, $stderr]
    $stdout = @task_stdout
    $stderr = @task_stderr
    begin
      Rake::Task[name].invoke
    rescue SystemExit
      @aborted = true
    ensure
      $stdout, $stderr = original
    end
  end

  def aborted? = @aborted

  def capture_output
    @task_stdout = StringIO.new
    @task_stderr = StringIO.new
    original = [$stdout, $stderr]
    $stdout = @task_stdout
    $stderr = @task_stderr
    yield
  ensure
    $stdout, $stderr = original
  end

  def strip_ansi(text) = text.gsub(/\e\[[\d;]*m/, '')

  def shell_runs_matching(*parts)
    shell_runs.select { |cmd| parts.all? { |part| cmd.include?(part) } }
  end

  def touch_file(path, content = '')
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, content)
    path
  end

  def stub_capture(&)
    allow(Shell).to receive(:capture) do |cmd, **kwargs|
      shell_captures << cmd
      yield(cmd, **kwargs) || Shell::Result.new('', 0)
    end
  end
end
