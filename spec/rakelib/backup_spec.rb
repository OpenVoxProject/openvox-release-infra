# frozen_string_literal: true

RSpec.describe 'backup task' do
  include_context 'with rake tasks'

  let(:rake_files) { 'backup' }

  def rsync_commands = shell_runs_matching('gcloud', 'storage', 'rsync')

  context 'when a source bucket is empty' do
    it 'aborts without touching GCS' do
      run_task('backup')

      expect(aborted?).to be(true)
      expect(strip_ansi(task_stderr)).to include('appears empty or inaccessible')
      expect(rsync_commands).to be_empty
    end
  end

  context 'when a source bucket is inaccessible' do
    before { stub_capture { Shell::Result.new('', 1) } }

    it 'aborts without touching GCS' do
      run_task('backup')

      expect(aborted?).to be(true)
      expect(rsync_commands).to be_empty
    end
  end

  context 'when all buckets have content' do
    before { stub_capture { Shell::Result.new('2026-01-01 file', 0) } }

    it 'rsyncs apt, yum and downloads to the test GCS bucket' do
      run_task('backup')

      expect(aborted?).to be(false)
      expect(rsync_commands.map { |cmd| cmd.last(2) }).to eq(
        [
          ["#{Infra::APT_TEST_BUCKET}/", 'gs://openvox-backup-test/apt/'],
          ["#{Infra::YUM_TEST_BUCKET}/", 'gs://openvox-backup-test/yum/'],
          ["#{Infra::DOWNLOADS_TEST_BUCKET}/", 'gs://openvox-backup-test/downloads/'],
        ],
      )
      expect(strip_ansi(task_stdout)).to include('Backup complete.')
    end

    it 'deletes unmatched destination objects' do
      run_task('backup')

      expect(rsync_commands).to all(include('--delete-unmatched-destination-objects'))
    end

    it 'targets the production buckets when PRODUCTION=true' do
      ENV['PRODUCTION'] = 'true'
      run_task('backup')

      expect(rsync_commands.map { |cmd| cmd.last(2) }).to eq(
        [
          ['s3://openvox-apt/', 'gs://openvox-backup/apt/'],
          ['s3://openvox-yum/', 'gs://openvox-backup/yum/'],
          ["#{Infra::DOWNLOADS_PRODUCTION_BUCKET}/", 'gs://openvox-backup/downloads/'],
        ],
      )
    end
  end
end
