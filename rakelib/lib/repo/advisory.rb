# frozen_string_literal: true

require 'fileutils'
require 'rexml/document'
require 'shellwords'
require 'time'
require 'zlib'
require_relative '../utils/infra'

# Security advisories for the yum repos. dnf, yum and zypper read them from the
# updateinfo.xml.gz in each arch dir's repodata, and "update --security" picks
# a package up only when an advisory of type security lists it. One advisory
# per released version covers every package of that release, with the same
# content in every arch dir. mergerepo_c writes an empty updateinfo on every
# merge, so the entries recorded in state/ are carried over and the whole file
# is written again through modifyrepo_c after each merge.
module Advisory
  SEVERITIES = %w[Critical Important Moderate Low].freeze

  module_function

  def id = "OVSA-#{Infra.project}-#{Infra.version}"

  # The advisory described by ADVISORIES and SEVERITY for the project and
  # version in the environment. Aborts on bad input.
  def from_env
    severity = Infra.env('SEVERITY', required: true)
    abort "SEVERITY must be one of #{SEVERITIES.join(', ')}, got #{severity}.".red unless SEVERITIES.include?(severity)

    references = parse_references(Infra.env('ADVISORIES') || '')
    description = "Security update for #{Infra.project} #{Infra.version}."
    description += " Fixes #{references.map { |ref| ref[:id] }.join(', ')}." unless references.empty?

    puts "Advisory #{id} (#{severity}): #{description}".magenta
    { severity: severity, description: description, references: references }
  end

  # ADVISORIES lists CVE IDs and GitHub advisory links, separated by spaces or
  # commas, and may be empty while nothing is assigned yet. CVE IDs become
  # references of type cve, which "dnf update --cve" matches, and a GitHub
  # advisory link becomes a reference of type self with its GHSA ID. Anything
  # else aborts.
  def parse_references(text)
    text.split(/[\s,;]+/).reject(&:empty?).map do |token|
      ghsa = token[%r{\Ahttps://github\.com/(?:[\w.-]+/[\w.-]+/security/advisories|advisories)/(GHSA-[a-z0-9]{4}-[a-z0-9]{4}-[a-z0-9]{4})\z}, 1]
      if token.match?(/\ACVE-\d{4}-\d{4,}\z/i)
        cve = token.upcase
        { id: cve, type: 'cve', href: "https://www.cve.org/CVERecord?id=#{cve}" }
      elsif ghsa
        { id: ghsa, type: 'self', href: token }
      else
        abort "ADVISORIES must contain only CVE IDs and GitHub advisory links, got #{token}.".red
      end
    end.uniq
  end

  # Rewrite the updateinfo of one arch dir in staging from the entries recorded
  # in state/ plus the given entry, which replaces an entry with the same ID.
  # With no entry, the recorded entries are carried over as they are. Returns
  # true when a file was written, false when the arch dir has nothing to carry,
  # or is a src dir, or does not contain the release the entry is for.
  def update_repodata(container, rel_path, entry)
    return false if rel_path.end_with?('/src')

    staging_repodata = File.join(Infra::STAGING_DIR, 'yum', rel_path, 'repodata')
    # An arch dir that is new in this release has no repodata in state/ yet
    recorded = File.join(Infra::STATE_DIR, 'yum', rel_path, 'repodata', 'updateinfo.xml.gz')
    doc = File.exist?(recorded) ? read_gz_xml(recorded) : REXML::Document.new('<?xml version="1.0"?><updates/>')

    if entry
      packages = packages_for(staging_repodata, Infra.project, Infra.version)
      return false if packages.empty?

      previous = doc.root.elements.to_a('update').find { |update| update.elements['id'].text == id }
      issued = previous ? previous.elements['issued'].attributes['date'] : packages.map { |pkg| pkg[:time] }.max
      doc.root.delete_element(previous) if previous
      doc.root.add_element(build(entry, packages, rel_path, issued))
    end
    return false if doc.root.elements.to_a('update').empty?

    write(container, doc, staging_repodata)
    true
  end

  # The packages of a release in one repodata, from its primary.xml.gz. A release
  # ships packages named after the project plus subpackages with the project
  # name as a prefix, such as openvoxdb-termini.
  def packages_for(repodata, project, version)
    read_gz_xml(File.join(repodata, 'primary.xml.gz')).root.elements.to_a('package').filter_map do |package|
      name = package.elements['name'].text
      next unless name == project || name.start_with?("#{project}-")

      version_element = package.elements['version']
      next unless version_element.attributes['ver'] == version

      {
        name: name,
        epoch: version_element.attributes['epoch'] || '0',
        version: version,
        release: version_element.attributes['rel'],
        arch: package.elements['arch'].text,
        filename: File.basename(package.elements['location'].attributes['href']),
        src: package.elements['format/rpm:sourcerpm'].text,
        time: timestamp(Time.at(package.elements['time'].attributes['file'].to_i)),
      }
    end
  end

  # The packages that the advisory of the release lists in one staged arch dir,
  # as name and EVR pairs for the verifier, or none when the dir does not carry it.
  def listed_packages(rel_path)
    path = File.join(Infra::STAGING_DIR, 'yum', rel_path, 'repodata', 'updateinfo.xml.gz')
    return [] unless File.exist?(path)

    update = read_gz_xml(path).root.elements.to_a('update').find { |entry| entry.elements['id'].text == id }
    return [] unless update

    update.elements.to_a('pkglist/collection/package').map do |pkg|
      evr = "#{pkg.attributes['version']}-#{pkg.attributes['release']}"
      evr = "#{pkg.attributes['epoch']}:#{evr}" unless pkg.attributes['epoch'].to_i.zero?
      { name: pkg.attributes['name'], version: evr }
    end
  end

  def read_gz_xml(path) = REXML::Document.new(Zlib.gunzip(File.binread(path)))

  def timestamp(time) = time.utc.strftime('%Y-%m-%d %H:%M:%S')

  def build(entry, packages, rel_path, issued)
    update = REXML::Element.new('update')
    update.add_attributes('from' => 'openvox@voxpupuli.org', 'status' => 'final', 'type' => 'security', 'version' => '1')
    update.add_element('id').text = id
    update.add_element('title').text = "#{entry[:severity]}: #{Infra.project} #{Infra.version} security update"
    update.add_element('issued', 'date' => issued)
    update.add_element('updated', 'date' => timestamp(Time.now))
    update.add_element('severity').text = entry[:severity]
    update.add_element('description').text = entry[:description]

    references = update.add_element('references')
    entry[:references].each do |ref|
      references.add_element('reference', 'href' => ref[:href], 'id' => ref[:id], 'type' => ref[:type], 'title' => ref[:id])
    end

    collection = update.add_element('pkglist').add_element('collection', 'short' => rel_path.tr('/', '-'))
    collection.add_element('name').text = "OpenVox #{rel_path}"
    packages.each do |pkg|
      package = collection.add_element('package', 'name' => pkg[:name], 'version' => pkg[:version], 'release' => pkg[:release],
        'epoch' => pkg[:epoch], 'arch' => pkg[:arch], 'src' => pkg[:src])
      package.add_element('filename').text = pkg[:filename]
    end
    update
  end

  # modifyrepo_c compresses the file into the repodata, replaces the updateinfo
  # record in repomd.xml and deletes the old file. repomd.xml must be signed
  # again afterwards.
  def write(container, doc, staging_repodata)
    tmp_dir = File.join(Infra::STAGING_DIR, 'updateinfo_tmp')
    FileUtils.mkdir_p(tmp_dir)
    xml = File.join(tmp_dir, 'updateinfo.xml')
    File.open(xml, 'w') { |file| doc.write(output: file) }

    args = ['modifyrepo_c', '--mdtype', 'updateinfo', '--compress-type', 'gz', '--simple-md-filenames',
            Infra.container_path(xml), Infra.container_path(staging_repodata),]
    container.exec(Shellwords.shelljoin(args))
  ensure
    FileUtils.rm_rf(tmp_dir)
  end
end
