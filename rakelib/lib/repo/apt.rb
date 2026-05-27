# frozen_string_literal: true

require 'fileutils'
require 'shellwords'
require_relative '../utils/infra'
require_relative '../utils/platform'

class Apt
  def initialize(container)
    @container = container
  end

  def sign_debs(host_paths)
    return if host_paths.empty?

    puts "Signing #{pluralize(host_paths.size, 'DEB')}...".magenta
    host_paths.each do |host_path|
      escaped = Shellwords.shellescape(Infra.container_path(host_path))
      @container.exec("debsigs --sign=origin -k #{Infra::GPG_KEY_ID} #{escaped} && debsigs --verify #{escaped}")
    end
    puts 'DEB signing complete.'.green
  end

  def sign
    debs = Dir.glob(File.join(Infra::PACKAGES_DIR, 'deb', '*.deb'))
    sign_debs(debs)
  end

  def prepare
    debs = Dir.glob(File.join(Infra::PACKAGES_DIR, 'deb', '*.deb'))
    return if debs.empty?

    # Stage debs in the pool layout and copy existing metadata from state/
    # We don't ship any lib packages, so we only handle the standard pool layout
    # which looks like pool/<component>/<packages first letter>/<package name>/,
    # e.g. pool/openvox8/o/openvox-agent/.
    debs.each do |deb|
      container_deb = Infra.container_path(deb)
      escaped_deb = Shellwords.shellescape(container_deb)
      source_name = @container.capture("dpkg-deb --field #{escaped_deb} Source", silent: true).output.strip
      source_name = File.basename(deb).split('_').first if source_name.empty?
      pool_dir = File.join(Infra::STAGING_DIR, 'apt', 'pool', Infra.component, source_name[0], source_name)
      FileUtils.mkdir_p(pool_dir)
      FileUtils.cp(deb, pool_dir)
    end
    # Copy from state/apt/dists to staging/apt/dists
    Apt.stage_metadata

    # Generate stanzas from the staging pool for new packages. These new stanzas
    # will get merged into the existing Packages file.
    new_stanzas = generate_stanzas(debs)

    affected_dists = Set.new
    packages_cache = {}

    # Process arch-specific packages before arch:all so new binary-<arch> dirs
    # are created before arch:all replication looks for them
    sorted_stanzas = new_stanzas.sort_by { |basename, _| basename.end_with?('_all.deb') ? 1 : 0 }
    sorted_stanzas.each do |basename, stanza|
      platform = Platform.from_deb(basename)
      abort "Cannot parse DEB filename: #{basename}. Expected format: <name>_<ver>+<dist>_<arch>.deb".red unless platform

      affected_dists << platform.dist
      identity = stanza_identity(stanza)

      # Add the new stanza for the package to every relevant binary-<arch> Packages file.
      # For arch-specific packages, this is one file. For "all" packages, it gets added
      # to the Packages file in all existing binary-<arch> dir.
      target_binary_arches(platform.dist, platform.arch).each do |target_arch|
        packages_dir = File.join(Infra::STAGING_DIR, 'apt', 'dists', platform.dist, Infra.component, "binary-#{target_arch}")
        FileUtils.mkdir_p(packages_dir)
        packages_file = File.join(packages_dir, 'Packages')

        packages_cache[packages_file] ||= load_stanzas(packages_file)

        existing = packages_cache[packages_file][identity]
        if existing
          if Infra.env('FORCE_OVERWRITE') == 'true'
            puts "Overwriting existing entry for #{basename} in binary-#{target_arch}".yellow
            packages_cache[packages_file].delete(identity)
          elsif (sha = stanza[/^SHA256: (.+)$/, 1]) && sha == existing[/^SHA256: (.+)$/, 1]
            puts "Skipping #{basename} in binary-#{target_arch} (identical hash, already present)".cyan
            next
          else
            abort "Version collision: #{basename} has same Package/Version/Architecture " \
                  "but different content than the existing entry in binary-#{target_arch}. " \
                  'Use FORCE_OVERWRITE=true to replace.'.red
          end
        end

        packages_cache[packages_file][identity] = stanza
        puts "Added to #{platform.dist}/#{Infra.component}/binary-#{target_arch}: #{basename}".cyan
      end
    end

    packages_cache.each { |path, stanzas| write_packages_file(path, stanzas.values) }
    affected_dists.each { |dist| rebuild_with_aliases(dist) }
    puts "apt metadata updated for #{affected_dists.size} dists.".green
  end

  # Rebuild the indexes for the given dist and, if the dist has an upstream
  # codename (e.g. "trixie" for "debian13"), also mirror the Packages files
  # into a parallel dists/<codename>/ tree and rebuild its indexes too. The
  # codename tree shares pool/ content via identical Filename: paths; only
  # the per-dist metadata is duplicated.
  def rebuild_with_aliases(dist)
    rebuild_indexes(dist)
    codename = Platform.codename_for(dist)
    if codename.nil?
      puts "No upstream codename found for #{dist}; skipping alias.".yellow if Platform.canonical_apt_dist?(dist)
      return
    end

    mirror_packages_for_codename(dist, codename)
    rebuild_indexes(codename)
  end

  # Copy from state/apt/dists to staging/apt/dists
  def self.stage_metadata
    state_dists = File.join(Infra::STATE_DIR, 'apt', 'dists')
    return unless Dir.exist?(state_dists)

    staging_dists = File.join(Infra::STAGING_DIR, 'apt', 'dists')
    FileUtils.mkdir_p(staging_dists)
    FileUtils.cp_r(Dir.glob(File.join(state_dists, '*')), staging_dists)
  end

  # Copy from staging/apt/dists back to state/apt/dists so we can
  # commit the metadata updates later.
  def self.update_state
    staging_dists = File.join(Infra::STAGING_DIR, 'apt', 'dists')
    return unless Dir.exist?(staging_dists)

    state_dists = File.join(Infra::STATE_DIR, 'apt', 'dists')
    FileUtils.rm_rf(state_dists)
    FileUtils.mkdir_p(state_dists)
    FileUtils.cp_r(Dir.glob(File.join(staging_dists, '*')), state_dists)
  end

  # Find all packages that are reference in all Packages files for the entire
  # apt repo. This is used by the cleanup rake task to find orphaned packages
  # in pool/ on S3 after we've done a rollback.
  def self.referenced_packages
    referenced = Set.new
    Dir.glob(File.join(Infra::STATE_DIR, 'apt', '**', 'Packages')).each do |packages_file|
      File.foreach(packages_file) do |line|
        match = line.match(/^Filename: (.+)$/)
        referenced << match[1] if match
      end
    end
    referenced
  end

  # gzip the Packages file (we have both Packages and Packages.gz, the latter is used
  # by apt clients for efficiency), then create the Release file, then the
  # signed Release.gpg and InRelease files.
  def rebuild_indexes(dist)
    dists_dir = File.join(Infra::STAGING_DIR, 'apt', 'dists', dist)

    Dir.glob(File.join(dists_dir, '*', 'binary-*')).each do |binary_dir|
      packages_file = File.join(binary_dir, 'Packages')
      next unless File.exist?(packages_file)

      @container.exec("gzip -n -9 -k -f #{Infra.container_path(packages_file)}")
    end

    generate_release(dists_dir, dist)
    sign_release(dists_dir)
  end

  private

  # Copy the canonical dist's Packages files into the codename alias dir so
  # rebuild_indexes(codename) has something to gzip and reference in its
  # Release file. Packages content is byte-identical between the two trees
  # because Filename: paths point into the shared pool/. Stale top-level
  # Release files under the codename dir are removed to avoid apt-ftparchive
  # picking up self-references (same reason as in generate_release).
  def mirror_packages_for_codename(canonical, codename)
    canonical_dir = File.join(Infra::STAGING_DIR, 'apt', 'dists', canonical)
    codename_dir = File.join(Infra::STAGING_DIR, 'apt', 'dists', codename)

    %w[Release InRelease Release.gpg].each { |name| FileUtils.rm_f(File.join(codename_dir, name)) }

    Dir.glob(File.join(canonical_dir, '*', 'binary-*', 'Packages')).each do |packages_file|
      relative = packages_file.sub("#{canonical_dir}/", '')
      target = File.join(codename_dir, relative)
      FileUtils.mkdir_p(File.dirname(target))
      FileUtils.cp(packages_file, target)
    end
  end

  # Use the apt-ftparchive packages pool command to generate stanzas for the Packages file
  # for all of the packages we have in the staging directory.
  def generate_stanzas(debs)
    staging_apt = Infra.container_path(File.join(Infra::STAGING_DIR, 'apt'))
    output = @container.capture("cd #{staging_apt} && apt-ftparchive packages pool").output

    stanzas = {}
    output.split("\n\n").reject(&:empty?).each do |stanza_text|
      filename = stanza_text[/^Filename: (.+)$/, 1]
      abort "apt-ftparchive emitted a block without a Filename: field:\n#{stanza_text}".red unless filename
      stanzas[File.basename(filename)] = "#{stanza_text}\n"
    end

    if stanzas.size != debs.size
      abort "apt-ftparchive generated #{pluralize(stanzas.size, 'stanza')} for #{pluralize(debs.size, 'DEB')}. " \
            'Some packages may be corrupt or unreadable.'.red
    end

    stanzas
  end

  # For arch:all packages, find all existing binary-<arch> directories so we can put
  # the package into all of them. Some apt repos have separate binary-all directories,
  # but ours doesn't.
  def target_binary_arches(dist, arch)
    return [arch] unless arch == 'all'

    comp_dir = File.join(Infra::STAGING_DIR, 'apt', 'dists', dist, Infra.component)
    unless Dir.exist?(comp_dir)
      abort "No binary-<arch> directories exist for #{dist}/#{Infra.component}. " \
            'Cannot determine target architectures for arch:all DEB.'.red
    end

    arches = Dir.children(comp_dir)
                .select { |child| child.start_with?('binary-') && File.directory?(File.join(comp_dir, child)) }
                .map { |child| child.sub('binary-', '') }
                .reject { |arch_name| arch_name == 'all' }

    if arches.empty?
      abort "No binary-<arch> directories found for #{dist}/#{Infra.component}. " \
            'Cannot determine target architectures for arch:all DEB.'.red
    end

    arches
  end

  def stanza_identity(stanza)
    package = stanza[/^Package: (.+)$/, 1]
    version = stanza[/^Version: (.+)$/, 1]
    architecture = stanza[/^Architecture: (.+)$/, 1]
    abort "Malformed stanza (missing Package, Version, or Architecture):\n#{stanza}".red unless package && version && architecture
    "#{package}/#{version}/#{architecture}"
  end

  # Scan through the Packages file, extracting each stanza. This is implemented
  # a bit verbosely for defensive purposes. The spec says that stanzas are separated
  # by empty lines, so splitting on \n\n would work. However, if someone edits one
  # manually and an editor ended up inserting \r\n, that would break. So instead,
  # we use line.chomp.empty? to search for blank lines.
  def load_stanzas(packages_file)
    return {} unless File.exist?(packages_file)

    stanzas = {}
    current = []
    File.foreach(packages_file) do |line|
      if line.chomp.empty? && !current.empty?
        entry = current.join
        stanzas[stanza_identity(entry)] = entry
        current = []
      else
        current << line
      end
    end
    unless current.empty?
      entry = current.join
      stanzas[stanza_identity(entry)] = entry
    end
    stanzas
  end

  def write_packages_file(packages_file, stanzas)
    File.open(packages_file, 'w') do |file|
      stanzas.each_with_index do |stanza, index|
        file.write("\n") if index.positive?
        file.write(stanza)
        file.write("\n") unless stanza.end_with?("\n")
      end
    end
  end

  # Append .0 to the osver (e.g. 13.0 for debian13). This is probably not
  # really necessary, but we were doing this previously when we were using
  # reprepro, and package managers sometimes have weird logic around
  # 13 vs. 13.0, so keep it for consistency.
  def version_from_dist(dist)
    match = dist.match(/(\d[\d.]*)$/)
    abort "Cannot derive version from dist '#{dist}'. Dist must end in digits.".red unless match

    ver = match[1]
    ver.include?('.') ? ver : "#{ver}.0"
  end

  # Create the Release file using the apt-ftparchive release command, which
  # scans the directory and computes checksums of everything it finds. The
  # Components and Architectures fields are not derived by apt-ftparchive,
  # so we compute and pass them explicitly by parsing stanza fields
  # (Filename and Architecture) from the merged Packages files.
  def generate_release(dists_dir, dist)
    version = version_from_dist(dist)
    components = Set.new
    architectures = Set.new
    Dir.glob(File.join(dists_dir, '*', 'binary-*', 'Packages')).each do |packages_file|
      File.foreach(packages_file) do |line|
        if (match = line.match(%r{^Filename:\s*pool/([^/]+)/}))
          components << match[1]
        elsif (match = line.match(/^Architecture:\s*(\S+)/))
          architectures << match[1] unless match[1] == 'all'
        end
      end
    end
    abort "No components found for #{dist}, cannot generate Release file.".red if components.empty?
    abort "No architectures found for #{dist}, cannot generate Release file.".red if architectures.empty?

    # apt-ftparchive scans the directory for files matching a fixed set of
    # patterns (Packages, Packages.*, Sources, Release, Contents-*, etc.)
    # and emits checksums for every match. "Release" is one of those
    # patterns, so any Release file present in the scan directory gets
    # included. If we redirect output directly into the scan directory,
    # apt-ftparchive opens the destination, writes the header, scans, and
    # matches its own partially-written output, producing a self-reference.
    # Remove any stale top-level files and write to a path outside the
    # scan directory, then move it in once apt-ftparchive has finished.
    %w[Release InRelease Release.gpg].each { |name| FileUtils.rm_f(File.join(dists_dir, name)) }

    container_dists = Infra.container_path(dists_dir)
    release_file = Infra.container_path(File.join(dists_dir, 'Release'))
    tmp_release = "/tmp/Release.#{dist}"

    @container.exec(
      'apt-ftparchive release ' \
      "-o APT::FTPArchive::Release::Origin='Vox Pupuli' " \
      "-o APT::FTPArchive::Release::Label='openvox-#{dist}' " \
      '-o APT::FTPArchive::Release::Suite=stable ' \
      "-o APT::FTPArchive::Release::Codename=#{dist} " \
      "-o APT::FTPArchive::Release::Version=#{version} " \
      "-o APT::FTPArchive::Release::Description='OpenVox #{dist} Repository' " \
      "-o APT::FTPArchive::Release::Components='#{components.to_a.sort.join(' ')}' " \
      "-o APT::FTPArchive::Release::Architectures='#{architectures.to_a.sort.join(' ')}' " \
      '-o APT::FTPArchive::Release::NumericTimezone=false ' \
      "#{container_dists} > #{tmp_release} && mv #{tmp_release} #{release_file}"
    )
  end

  # Sign the Release file to create Release.gpg (detached signature, legacy format for
  # older apt clients) and InRelease (clearsigned, for modern apt clients). Every platform
  # we support uses InRelease, so we could drop Release.gpg, but it's cheap to calculate
  # so why not.
  def sign_release(dists_dir)
    container_dists = Infra.container_path(dists_dir)
    release_path = File.join(container_dists, 'Release')
    inrelease_path = File.join(container_dists, 'InRelease')
    release_gpg_path = File.join(container_dists, 'Release.gpg')

    @container.exec(
      "gpg --batch --yes --default-key #{Infra::GPG_KEY_ID} --digest-algo SHA512 " \
      "--clearsign --output #{inrelease_path} #{release_path}"
    )
    @container.exec("gpg --verify #{inrelease_path}")

    @container.exec(
      "gpg --batch --yes --default-key #{Infra::GPG_KEY_ID} --digest-algo SHA512 " \
      "--detach-sign --armor --output #{release_gpg_path} #{release_path}"
    )
    @container.exec("gpg --verify #{release_gpg_path} #{release_path}")
  end
end
