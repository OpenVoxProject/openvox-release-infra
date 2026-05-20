# frozen_string_literal: true

require 'fileutils'
require 'shellwords'
require 'zlib'
require_relative '../utils/infra'
require_relative '../utils/platform'

class Yum
  def initialize(container)
    @container = container
  end

  def sign_rpms(host_paths)
    return if host_paths.empty?

    puts "Signing #{pluralize(host_paths.size, 'RPM')}...".magenta
    host_paths.each do |host_path|
      escaped = Shellwords.shellescape(Infra.container_path(host_path))
      @container.exec("GPG_TTY= rpmsign --addsign --define '%_gpg_name #{Infra::GPG_KEY_ID}' #{escaped} && rpm --checksig #{escaped}")
    end
    puts 'RPM signing complete.'.green
  end

  def sign
    rpms = Dir.glob(File.join(Infra::PACKAGES_DIR, 'rpm', '*.rpm'))
    sign_rpms(rpms)
  end

  def prepare
    rpms = Dir.glob(File.join(Infra::PACKAGES_DIR, 'rpm', '*.rpm'))
    return if rpms.empty?

    Yum.stage_metadata
    affected = Set.new
    referenced = Yum.referenced_packages

    # Process arch-specific RPMs before noarch so that arch dirs exist in staging
    # when noarch RPMs look for them
    rpms.sort_by! { |rpm| File.basename(rpm).include?('.noarch.') ? 1 : 0 }

    rpms.each do |rpm|
      basename = File.basename(rpm)
      platform = Platform.from_rpm(basename)
      abort "Cannot parse RPM filename: #{basename}. Expected format: <name>-<ver>.<dist><platver>.<arch>.rpm".red unless platform

      target_arch_dirs(platform.os, platform.version, platform.arch).each do |arch_dir|
        if referenced.include?("#{arch_dir}/#{basename}")
          if Infra.env('FORCE_OVERWRITE') == 'true'
            puts "Overwriting existing entry for #{basename} in #{arch_dir}".yellow
          else
            abort "Package collision: #{basename} already exists in #{arch_dir}. " \
                  'Use FORCE_OVERWRITE=true to replace.'.red
          end
        end

        staging_path = File.join(Infra::STAGING_DIR, 'yum', arch_dir)
        FileUtils.mkdir_p(staging_path)
        FileUtils.cp(rpm, staging_path)
        affected << arch_dir
      end
    end

    affected.each do |rel_path|
      puts "Updating yum metadata: #{rel_path}".magenta
      staging_path = File.join(Infra::STAGING_DIR, 'yum', rel_path)
      container_staging = Infra.container_path(staging_path)

      # Generate repodata for the new RPMs in staging
      @container.exec("createrepo_c --general-compress-type=gz --simple-md-filenames --no-database #{container_staging}")

      # Merge with existing repodata from state/. mergerepo_c must output to a separate
      # location than either of the two source repos, so we have to create a short-lived
      # temp dir to store the merge before we copy it back.
      state_repodata = File.join(Infra::STATE_DIR, 'yum', rel_path, 'repodata')
      if Dir.exist?(state_repodata)
        merge_tmp = File.join(Infra::STAGING_DIR, 'yum_merge_tmp')
        container_state = Infra.container_path(File.join(Infra::STATE_DIR, 'yum', rel_path))
        container_merge = Infra.container_path(merge_tmp)

        @container.exec(
          'mergerepo_c --omit-baseurl --all --simple-md-filenames --no-database ' \
          "--compress-type gz --repo #{container_staging} --repo #{container_state} " \
          "-o #{container_merge}"
        )

        container_merged_repomd = "#{container_merge}/repodata/repomd.xml"
        result = @container.capture("test -f #{container_merged_repomd}", allowed_exit_codes: [0, 1])
        abort "mergerepo_c produced no repomd.xml at #{container_merge}/repodata".red unless result.exitcode.zero?

        @container.exec("rm -rf #{container_staging}/repodata && mv #{container_merge}/repodata #{container_staging} && rm -rf #{container_merge}")
      end

      repomd = File.join(staging_path, 'repodata', 'repomd.xml')
      @container.exec("rm -f #{Infra.container_path(repomd)}.asc")
      Infra.gpg_detach_sign(@container, repomd)
    end

    puts "yum metadata updated for #{affected.size} arch dirs.".green
  end

  # Copy repodata from staging/ back to state/ so we can commit the
  # metadata updates later.
  def self.update_state
    staging_yum = File.join(Infra::STAGING_DIR, 'yum')
    return unless Dir.exist?(staging_yum)

    Dir.glob(File.join(staging_yum, '**', 'repodata')).each do |staging_repodata|
      rel_path = staging_repodata.sub("#{staging_yum}/", '')
      state_repodata = File.join(Infra::STATE_DIR, 'yum', rel_path)
      FileUtils.rm_rf(state_repodata)
      FileUtils.mkdir_p(File.dirname(state_repodata))
      FileUtils.cp_r(staging_repodata, state_repodata)
    end
  end

  def self.stage_metadata
    state_yum = File.join(Infra::STATE_DIR, 'yum')
    return unless Dir.exist?(state_yum)

    Dir.glob(File.join(state_yum, '**', 'repodata')).each do |repodata_dir|
      rel_path = repodata_dir.sub("#{state_yum}/", '')
      staging_repodata = File.join(Infra::STAGING_DIR, 'yum', rel_path)
      FileUtils.mkdir_p(staging_repodata)
      FileUtils.cp_r(Dir.glob(File.join(repodata_dir, '*')), staging_repodata)
    end
  end

  # Find all packages referenced in primary.xml.gz across the entire yum repo.
  # Used by the cleanup rake task to find orphaned packages on S3 after a rollback.
  def self.referenced_packages
    referenced = Set.new
    Dir.glob(File.join(Infra::STATE_DIR, 'yum', '**', 'primary.xml.gz')).each do |primary_gz|
      rel_prefix = File.dirname(primary_gz, 2).sub("#{Infra::STATE_DIR}/yum/", '')
      xml = Zlib::GzipReader.open(primary_gz, &:read)
      xml.scan(/<location href="([^"]+)"/) do |(href)|
        referenced << "#{rel_prefix}/#{href}"
      end
    end
    referenced
  end

  private

  # For noarch RPMs, find all existing arch directories so we can put the
  # package into all of them (yum has no shared noarch directory).
  def target_arch_dirs(plat, platver, arch)
    return ["#{Infra.component}/#{plat}/#{platver}/#{arch}"] if arch != 'noarch'

    staging_base = File.join(Infra::STAGING_DIR, 'yum', Infra.component, plat, platver)
    arches = arch_dirs_under(staging_base)
    arches = discover_sibling_arches(plat) if arches.empty?

    if arches.empty?
      abort "No existing arch dirs found for #{plat}/#{platver} and no siblings to copy from. " \
            'Cannot determine target architectures for noarch RPM.'.red
    end

    arches.map { |target_arch| "#{Infra.component}/#{plat}/#{platver}/#{target_arch}" }
  end

  def arch_dirs_under(path)
    return [] unless Dir.exist?(path)

    Dir.children(path).select do |child|
      File.directory?(File.join(path, child)) && !%w[repodata src].include?(child)
    end
  end

  def discover_sibling_arches(plat)
    plat_base = File.join(Infra::STAGING_DIR, 'yum', Infra.component, plat)
    return [] unless Dir.exist?(plat_base)

    Dir.children(plat_base)
       .select { |ver| File.directory?(File.join(plat_base, ver)) }
       .flat_map { |ver| arch_dirs_under(File.join(plat_base, ver)) }
       .uniq
  end
end
