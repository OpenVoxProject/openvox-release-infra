# frozen_string_literal: true

require 'json'
require_relative 'lib/repo/apt'
require_relative 'lib/repo/yum'
require_relative 'lib/utils/infra'

# Examples:
#   bucket_path = "s3://openvox-apt"
#   prefix      = "pool/"
#   bucket_name = "openvox-apt"
#   subpath     = ""
#   full_prefix = "pool/"
#   key_prefix  = ""
#   return      = ["pool/openvox8/o/openvox-agent/openvox-agent_8.26.2+debian13_amd64.deb", ...]
#
#   bucket_path      = "s3://openvox-artifacts/repo_test/apt"
#   prefix      = "pool/"
#   bucket_name = "openvox-artifacts"
#   subpath     = "repo_test/apt"
#   full_prefix = "repo_test/apt/pool"
#   key_prefix  = "repo_test/apt/"
#   return      = ["pool/openvox8/o/openvox-agent/openvox-agent_8.26.2+debian13_amd64.deb", ...]
def list_s3_objects(bucket_path, prefix)
  bucket_name = bucket_path.sub(%r{^s3://}, '').split('/').first
  subpath = bucket_path.sub(%r{^s3://[^/]+/?}, '')
  full_prefix = subpath.empty? ? prefix : "#{subpath.chomp('/')}/#{prefix}"
  key_prefix = subpath.empty? ? '' : subpath.chomp('/') + '/'

  result = Shell.capture(
    "aws s3api list-objects-v2 --endpoint-url=#{Infra::S3_ENDPOINT} " \
    "--bucket #{bucket_name} --prefix '#{full_prefix}' --query 'Contents[].Key'"
  )

  return [] if result.output.strip == 'null' || result.output.strip.empty?

  JSON.parse(result.output).map { |key| key.delete_prefix(key_prefix) }
end

desc 'Remove packages from S3 not referenced in current metadata'
task :cleanup do
  Infra.setup_aws

  apt_state_files = Dir.glob(File.join(Infra::STATE_DIR, 'apt', '**', 'Packages'))
  yum_state_files = Dir.glob(File.join(Infra::STATE_DIR, 'yum', '**', 'primary.xml.gz'))
  if apt_state_files.empty? && yum_state_files.empty?
    abort 'No state/ metadata found (no Packages or primary.xml.gz files). ' \
          'This likely means state/ was not checked out or bootstrapped. ' \
          'Refusing to run cleanup with empty state to avoid deleting all packages.'.red
  end

  orphaned = []

  if apt_state_files.any?
    referenced_apt = Apt.referenced_packages
    list_s3_objects(Infra.apt_bucket, 'pool/').each do |obj|
      orphaned << { bucket: Infra.apt_bucket, key: obj } unless referenced_apt.include?(obj)
    end
  else
    puts 'No apt state/ metadata found, skipping apt orphan check.'.yellow
  end

  if yum_state_files.any?
    referenced_yum = Yum.referenced_packages
    # Skip RPMs at the bucket root (release packages live there, not in repo metadata)
    list_s3_objects(Infra.yum_bucket, '').select { |obj| obj.end_with?('.rpm') && obj.include?('/') }.each do |obj|
      orphaned << { bucket: Infra.yum_bucket, key: obj } unless referenced_yum.include?(obj)
    end
  else
    puts 'No yum state/ metadata found, skipping yum orphan check.'.yellow
  end

  if orphaned.empty?
    puts 'No orphaned packages found.'.green
    next
  end

  puts "Found #{orphaned.size} orphaned packages:".yellow
  orphaned.each { |obj| puts "  #{obj[:bucket]}/#{obj[:key]}".yellow }

  unless ENV['CONFIRM_CLEANUP']
    print 'Delete these packages? [y/N] > '
    answer = $stdin.gets&.chomp
    unless %w[y Y yes].include?(answer)
      puts 'Cleanup cancelled.'.yellow
      return
    end
  end

  orphaned.each do |obj|
    Shell.run(['aws', 's3', '--endpoint-url', Infra::S3_ENDPOINT, 'rm', "#{obj[:bucket]}/#{obj[:key]}"])
  end
  puts "Deleted #{orphaned.size} orphaned packages. You will need to clean up 'downloads' manually if any packages should be removed.".green
end
