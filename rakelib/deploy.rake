# frozen_string_literal: true

require_relative 'lib/utils/infra'
require_relative 'lib/utils/shell'

def deploy_phase(name)
  puts "--- #{name} ---".magenta
  yield
rescue SystemExit => e
  warn "PARTIAL DEPLOY: #{name} failed. Repos may be inconsistent. " \
       'Re-run `bundle exec rake deploy` to complete.'.red
  raise e
rescue StandardError => e
  abort "PARTIAL DEPLOY: #{name} failed. Repos may be inconsistent. " \
        "Re-run `bundle exec rake deploy` to complete.\n" \
        "Error: #{e.class}: #{e.message}\n#{e.backtrace.join("\n")}".red
end

def check_for_existing_packages(local_files, staging_prefix, bucket)
  return if local_files.empty?

  existing = local_files.select do |local_path|
    rel = local_path.sub("#{staging_prefix}/", '')
    remote = "#{bucket}/#{rel}"
    result = Shell.capture([*Infra.s3_cmd, 'ls', remote], allowed_exit_codes: [0, 1], print_command: false)
    result.exitcode.zero? && !result.output.strip.empty?
  end

  return if existing.empty?

  puts 'The following packages already exist on S3:'.red
  existing.each { |path| puts "  #{File.basename(path)}".red }
  abort 'Refusing to overwrite existing packages. Set FORCE_OVERWRITE=true to allow (e.g. when re-signing).'.red
end

desc 'Deploy staged packages and metadata to S3'
task :deploy do
  Infra.setup_aws
  Infra.print_target(:apt_bucket, :yum_bucket, :downloads_bucket)
  abort 'staging/ directory not found. Run `bundle exec rake release` first.'.red unless Dir.exist?(Infra::STAGING_DIR)

  pool_dir = File.join(Infra::STAGING_DIR, 'apt', 'pool')
  yum_dir = File.join(Infra::STAGING_DIR, 'yum')
  downloads_dir = File.join(Infra::STAGING_DIR, 'downloads')

  if Infra.env('FORCE_OVERWRITE') == 'true'
    puts 'Bypassing existing package check due to FORCE_OVERWRITE=true'.yellow
  else
    deploy_phase('Checking for existing packages') do
      if Dir.exist?(pool_dir)
        check_for_existing_packages(
          Dir.glob(File.join(pool_dir, '**', '*.deb')),
          File.join(Infra::STAGING_DIR, 'apt'),
          Infra.apt_bucket
        )
      end

      if Dir.exist?(yum_dir)
        check_for_existing_packages(
          Dir.glob(File.join(yum_dir, '**', '*.rpm')),
          File.join(Infra::STAGING_DIR, 'yum'),
          Infra.yum_bucket
        )
      end

      if Dir.exist?(downloads_dir)
        check_for_existing_packages(
          Dir.glob(File.join(downloads_dir, '**', '*')).select { |path| File.file?(path) },
          File.join(Infra::STAGING_DIR, 'downloads'),
          Infra.downloads_bucket
        )
      end
    end
  end

  deploy_phase('Uploading packages') do
    Shell.run([*Infra.s3_sync, '--exact-timestamps', "#{pool_dir}/", "#{Infra.apt_bucket}/pool/"]) if Dir.exist?(pool_dir)
    Shell.run([*Infra.s3_sync, '--exact-timestamps', "#{yum_dir}/", "#{Infra.yum_bucket}/", '--exclude', '*', '--include', '*.rpm']) if Dir.exist?(yum_dir)
    Shell.run([*Infra.s3_sync, '--exact-timestamps', "#{downloads_dir}/", "#{Infra.downloads_bucket}/"]) if Dir.exist?(downloads_dir)
  end

  deploy_phase('Uploading metadata') do
    Shell.run([*Infra.s3_sync, '--exact-timestamps', "#{yum_dir}/", "#{Infra.yum_bucket}/", '--exclude', '*.rpm']) if Dir.exist?(yum_dir)

    dists_dir = File.join(Infra::STAGING_DIR, 'apt', 'dists')
    Shell.run([*Infra.s3_sync, '--exact-timestamps', "#{dists_dir}/", "#{Infra.apt_bucket}/dists/"]) if Dir.exist?(dists_dir)
  end

  puts 'Deploy complete.'.green
end
