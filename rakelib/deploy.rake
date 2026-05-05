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
        "Error: #{e.class}: #{e.message}".red
end

desc 'Deploy staged packages and metadata to S3'
task :deploy do
  Infra.setup_aws
  abort 'staging/ directory not found. Run `bundle exec rake release` first.'.red unless Dir.exist?(Infra::STAGING_DIR)

  puts "Deploying to #{Infra.production? ? 'production' : 'test'} repos...".magenta

  deploy_phase('Uploading packages') do
    pool_dir = File.join(Infra::STAGING_DIR, 'apt', 'pool')
    Shell.run("#{Infra.s3_sync} --exact-timestamps #{pool_dir}/ #{Infra.apt_bucket}/pool/") if Dir.exist?(pool_dir)

    yum_dir = File.join(Infra::STAGING_DIR, 'yum')
    Shell.run("#{Infra.s3_sync} --exact-timestamps #{yum_dir}/ #{Infra.yum_bucket}/ --exclude '*' --include '*.rpm'") if Dir.exist?(yum_dir)

    downloads_dir = File.join(Infra::STAGING_DIR, 'downloads')
    Shell.run("#{Infra.s3_sync} --exact-timestamps #{downloads_dir}/ #{Infra.downloads_bucket}/") if Dir.exist?(downloads_dir)
  end

  deploy_phase('Uploading metadata') do
    yum_dir = File.join(Infra::STAGING_DIR, 'yum')
    Shell.run("#{Infra.s3_sync} --exact-timestamps #{yum_dir}/ #{Infra.yum_bucket}/ --exclude '*.rpm'") if Dir.exist?(yum_dir)

    staging_dists = File.join(Infra::STAGING_DIR, 'apt', 'dists')
    Shell.run("#{Infra.s3_sync} --exact-timestamps #{staging_dists}/ #{Infra.apt_bucket}/dists/") if Dir.exist?(staging_dists)
  end

  puts 'Deploy complete.'.green
end
