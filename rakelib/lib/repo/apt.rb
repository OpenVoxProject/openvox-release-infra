# frozen_string_literal: true

require 'fileutils'
require_relative '../utils/infra'

class Apt
  def initialize(container)
    @container = container
  end

  def sign
    debs = Dir.glob(File.join(Infra::PACKAGES_DIR, 'deb', '*.deb'))
    return if debs.empty?

    puts "Signing #{pluralize(debs.size, 'DEB')}...".magenta
    debs.each { |deb| Infra.sign_deb(@container, deb) }
    puts 'DEB signing complete.'.green
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
      source_name = @container.capture("dpkg-deb --field #{container_deb} Source", silent: true).output.strip
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

    affected_codenames = Set.new
    packages_cache = {}

    # Process arch-specific packages before arch:all so new binary-<arch> dirs
    # are created before arch:all replication looks for them
    sorted_stanzas = new_stanzas.sort_by { |basename, _| basename.end_with?('_all.deb') ? 1 : 0 }
    sorted_stanzas.each do |basename, stanza|
      parsed = parse_filename(basename)
      abort "Cannot parse DEB filename: #{basename}. Expected format: <name>_<ver>+<codename>_<arch>.deb".red unless parsed

      codename = parsed[:codename]
      affected_codenames << codename
      identity = parse_stanza_identity(stanza)

      # Add the new stanza for the package to every relevant binary-<arch> Packages file.
      # For arch-specific packages, this is one file. For "all" packages, it gets added
      # to the Packages file in all existing binary-<arch> dir.
      target_binary_arches(codename, parsed[:arch]).each do |target_arch|
        packages_dir = File.join(Infra::STAGING_DIR, 'apt', 'dists', codename, Infra.component, "binary-#{target_arch}")
        FileUtils.mkdir_p(packages_dir)
        packages_file = File.join(packages_dir, 'Packages')

        # The packages_cache first loads the Packages file from staging/, then gets updated
        # with new packages. We do ||= so we only load from the file the first time.
        packages_cache[packages_file] ||= load_stanzas(packages_file)

        # Look to see if we already have a matching package-version-architecture stanza
        existing = packages_cache[packages_file].find { |entry| parse_stanza_identity(entry) == identity }
        if existing
          if Infra.env('FORCE_OVERWRITE') == 'true'
            puts "Overwriting existing entry for #{basename} in binary-#{target_arch}".yellow
            packages_cache[packages_file].delete(existing)
          elsif existing[/^SHA256: (.+)$/, 1] == stanza[/^SHA256: (.+)$/, 1]
            # If we have the exact same unchanged package for some reason,
            # no need to do any more work in this iteration of the loop.
            next
          else
            abort "Version collision: #{basename} has same Package/Version/Architecture " \
                  "but different content than the existing entry in binary-#{target_arch}. " \
                  'Use FORCE_OVERWRITE=true to replace.'.red
          end
        end

        packages_cache[packages_file] << stanza
        puts "Added to #{codename}/#{Infra.component}/binary-#{target_arch}: #{basename}".cyan
      end
    end

    packages_cache.each { |path, stanzas| write_packages_file(path, stanzas) }
    affected_codenames.each { |codename| rebuild_indexes(codename) }
    puts "apt metadata updated for #{affected_codenames.size} codenames.".green
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

  private

  def parse_filename(filename)
    match = filename.match(/\+([a-z]+)([\d.]+)_(\w+)\.deb$/)
    return nil unless match

    # NOTE: Not the actual codename. We chose to use "debian13" instead of "trixie" deliberately in our repo
    # after much back and forth in the community. Apt still treats it like a codename, though.
    { codename: "#{match[1]}#{match[2]}", os: match[1], osver: match[2], arch: match[3] }
  end

  # Use the apt-ftparchive packages pool command to generate stanzas for the Packages file
  # for all of the packages we have in the staging directory.
  def generate_stanzas(debs)
    staging_apt = Infra.container_path(File.join(Infra::STAGING_DIR, 'apt'))
    output = @container.capture("cd #{staging_apt} && apt-ftparchive packages pool").output

    stanzas = {}
    output.split("\n\n").reject(&:empty?).each do |stanza_text|
      filename = stanza_text[/^Filename: (.+)$/, 1]
      unless filename
        abort "apt-ftparchive emitted a block without a Filename: field:\n#{stanza_text}".red
      end
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
  def target_binary_arches(codename, arch)
    return [arch] unless arch == 'all'

    comp_dir = File.join(Infra::STAGING_DIR, 'apt', 'dists', codename, Infra.component)
    unless Dir.exist?(comp_dir)
      abort "No binary-<arch> directories exist for #{codename}/#{Infra.component}. " \
            'Cannot determine target architectures for arch:all DEB.'.red
    end

    arches = Dir.children(comp_dir)
                .select { |child| child.start_with?('binary-') && File.directory?(File.join(comp_dir, child)) }
                .map { |child| child.sub('binary-', '') }
                .reject { |arch_name| arch_name == 'all' }

    if arches.empty?
      abort "No binary-<arch> directories found for #{codename}/#{Infra.component}. " \
            'Cannot determine target architectures for arch:all DEB.'.red
    end

    arches
  end

  # Extract information from a stanza that uniquely identifies it for
  # a particular package-version-architecture.
  def parse_stanza_identity(stanza)
    identity = {
      package: stanza[/^Package: (.+)$/, 1],
      version: stanza[/^Version: (.+)$/, 1],
      architecture: stanza[/^Architecture: (.+)$/, 1],
    }
    missing = identity.select { |_key, val| val.nil? }.keys
    abort "Malformed stanza: missing #{missing.join(', ')} field(s).\nStanza:\n#{stanza}".red unless missing.empty?
    identity
  end

  # Scan through the Packages file, extracting each stanza. This is implemented
  # a bit verbosely for defensive purposes. The spec says that stanzas are separated
  # by empty lines, so splitting on \n\n would work. However, if someone edits one
  # manually and an editor ended up inserting \r\n, that would break. So instead,
  # we use line.chomp.empty? to search for blank lines.
  def load_stanzas(packages_file)
    return [] unless File.exist?(packages_file)

    stanzas = []
    current = []
    File.foreach(packages_file) do |line|
      if line.chomp.empty? && !current.empty?
        stanzas << current.join
        current = []
      else
        current << line
      end
    end
    stanzas << current.join unless current.empty?
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

  # gzip the Packages file (we have both Packages and Packages.gz, the latter is used
  # by apt clients for efficiency), then create the Release file, then the
  # signed Release.gpg and InRelease files.
  def rebuild_indexes(codename)
    dists_dir = File.join(Infra::STAGING_DIR, 'apt', 'dists', codename)

    Dir.glob(File.join(dists_dir, '*', 'binary-*')).each do |binary_dir|
      packages_file = File.join(binary_dir, 'Packages')
      next unless File.exist?(packages_file)

      @container.exec("gzip -n -9 -k -f #{Infra.container_path(packages_file)}")
    end

    generate_release(dists_dir, codename)
    sign_release(dists_dir)
  end

  # Append .0 to the osver (e.g. 13.0 for debian13). This is probably not
  # really necessary, but we were doing this previously when we were using
  # reprepro, and package managers sometimes have weird logic around
  # 13 vs. 13.0, so keep it for consistency.
  def version_from_codename(codename)
    match = codename.match(/(\d[\d.]*)$/)
    abort "Cannot derive version from codename '#{codename}'. Codenames must end in digits.".red unless match

    ver = match[1]
    ver.include?('.') ? ver : "#{ver}.0"
  end

  # Create the Release file using the apt-ftparchive release command, which
  # scans the directory and computes checksums of everything it finds.
  def generate_release(dists_dir, codename)
    version = version_from_codename(codename)
    container_dists = Infra.container_path(dists_dir)
    release_file = Infra.container_path(File.join(dists_dir, 'Release'))

    @container.exec(
      'apt-ftparchive release ' \
      "-o APT::FTPArchive::Release::Origin='Vox Pupuli' " \
      "-o APT::FTPArchive::Release::Label='openvox-#{codename}' " \
      '-o APT::FTPArchive::Release::Suite=stable ' \
      "-o APT::FTPArchive::Release::Codename=#{codename} " \
      "-o APT::FTPArchive::Release::Version=#{version} " \
      "-o APT::FTPArchive::Release::Description='OpenVox #{codename} Repository' " \
      '-o APT::FTPArchive::Release::NumericTimezone=false ' \
      "#{container_dists} > #{release_file}"
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
