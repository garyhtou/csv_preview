# frozen_string_literal: true

require "open3"
require "rbconfig"
require "rubygems"
require "set"
require "yaml"

# The checks behind `rake docs:check` (docs/spec/branding-and-discoverability.md 4.9):
#
# - the README, the gemspec, llms.txt and the agent skill use the copy deck's strings word for word
#   (branding 1.3), and the skill copies the README's Rails snippets exactly;
# - every link and image in the public Markdown files resolves inside the repository, including
#   in-page anchors and absolute GitHub links to this repository;
# - every test ID cited in the README's security table exists as a `test_<ID>_` method in the file
#   it links to;
# - every README link in an error message points at a README heading that exists;
# - the agent skill's frontmatter is valid and the gem packages what it should;
# - no tracked file outside test/ contains an em dash (the project's writing style);
# - `yard stats --list-undoc` finds nothing undocumented in the public API, and every pinned public
#   method has an @example, a @return and a @param for each parameter (branding 4.7).
#
# Development only: not packaged with the gem.
class DocsCheck
  REPO_URL = "https://github.com/garyhtou/csv_preview"
  RAW_PREFIX = "https://raw.githubusercontent.com/garyhtou/csv_preview/main/"
  REPO_PATH = %r{\A#{Regexp.escape(REPO_URL)}/(?:blob|tree)/main/([^#?]+)(?:#(.+))?\z}
  REPO_ANCHOR = /\A#{Regexp.escape(REPO_URL)}#(.+)\z/

  COPY_DECK = "docs/spec/branding-and-discoverability.md"
  README = "README.md"
  SKILL = "skills/csv-preview/SKILL.md"
  LLMS = "llms.txt"
  SECURITY = "SECURITY.md"
  GEMSPEC = "csv_preview.gemspec"
  MARKDOWN = [README, "CHANGELOG.md", SECURITY, "CONTRIBUTING.md", "CODE_OF_CONDUCT.md", LLMS, SKILL].freeze

  # Where each copy-deck string must appear word for word (after joining wrapped lines).
  COPY_SURFACES = {
    "Descriptor" => [README, LLMS, SKILL],
    "Tagline" => [README, LLMS, SKILL],
    "Differentiator" => [README, LLMS, SKILL],
    "Safety line" => [README, SECURITY, LLMS, SKILL]
  }.freeze

  REGISTRATION = "config.active_storage.previewers.unshift CsvPreview::ActiveStoragePreviewer"
  # Code the skill must copy from the README exactly, so the two cannot drift apart.
  SHARED_SNIPPETS = [
    REGISTRATION,
    "config.csv_preview.register_previewer = true",
    "ActiveStorage::PreviewImageJob.discard_on ActiveStorage::PreviewError",
    "attachable.variant :thumb, resize_to_fill: [300, 300, { crop: :low }], preprocessed: true",
    'resize_to_fill: [300, 300, { gravity: "NorthWest" }]',
    "<%= image_tag document.file.representation(:thumb) if document.file.representable? %>"
  ].freeze
  SNIPPET_SURFACES = { REGISTRATION => [README, LLMS, SKILL] }.freeze

  # Files the gem must ship (branding 4.6, plus .yardopts so rubydoc.info renders Markdown), and paths
  # it must not.
  PACKAGED = [README, "CHANGELOG.md", "LICENSE", SECURITY, SKILL, ".yardopts", "fonts/OFL.txt",
              "fonts/Inter-Regular.ttf", "fonts/Inter-SemiBold.ttf", "lib/csv_preview.rb"].freeze
  NOT_PACKAGED = %r{\A(?:docs/|test/|bin/|rakelib/|llms\.txt\z)}

  # The pinned public API (overview section 9), whose docs must show an example (branding 4.7).
  PINNED_API = %w[
    CsvPreview.render CsvPreview.sample CsvPreview.layout CsvPreview.configure CsvPreview.config
    CsvPreview.text_supported? CsvPreview::ActiveStoragePreviewer.accept?
    CsvPreview::ActiveStoragePreviewer.text_supported? CsvPreview::ActiveStoragePreviewer#preview
  ].freeze

  TEST_ID = /\b(PS|AS|REN)-(\d+)\b/
  EM_DASH = "\u2014" # written as an escape so this file passes its own check
  SKILL_BODY_LINES = 200
  SKILL_DESCRIPTION_CHARS = 1024

  class << self
    # The anchor GitHub gives a heading (github-slugger): lowercase, punctuation removed except
    # hyphens and underscores, each space becomes a hyphen.
    def slug(heading)
      text = heading.gsub(/!?\[([^\]]*)\]\([^)]*\)/, '\1') # a link's text, not its target
      text.downcase.gsub(/[^\p{L}\p{N}\p{M}\p{Pc} -]/, "").tr(" ", "-")
    end

    # Markdown without fenced code blocks, so "# comment" lines in code are not headings and code is
    # not scanned for links.
    def without_code_blocks(markdown)
      markdown.gsub(/^ {0,3}(`{3,}|~{3,})[^\n]*\n.*?^ {0,3}\1[ \t]*$/m) { |block| "\n" * block.count("\n") }
    end

    # The anchors of every heading, with GitHub's -1, -2 suffixes for repeated headings.
    def anchors(markdown)
      seen = Hash.new(0)
      without_code_blocks(markdown).scan(/^ {0,3}\#{1,6}[ \t]+(.+?)[ \t]*#*[ \t]*$/).flatten.to_set do |heading|
        base = slug(heading)
        count = seen[base]
        seen[base] += 1
        count.zero? ? base : "#{base}-#{count}"
      end
    end

    # Every link, image and HTML src/href/srcset target outside code.
    def links(markdown)
      text = without_code_blocks(markdown).gsub(/`[^`\n]+`/, "")
      targets = text.scan(/\]\(\s*<?([^)\s>]+)>?(?:\s+"[^"]*")?\s*\)/).flatten
      targets += text.scan(/^ {0,3}\[[^\]]+\]:\s*<?(\S+?)>?(?:\s|$)/).flatten
      targets + text.scan(/\b(?:src|href|srcset)="([^"]+)"/).flatten
    end

    # Text as a reader sees it: wrapped lines joined, blockquote markers and bold markers dropped.
    def normalize(text)
      text.gsub(/^[ \t]*>[ \t]?/, "").gsub("**", "").gsub(/\s+/, " ")
    end

    # The copy deck's table rows (branding 1.3): item name => text.
    def copy_deck(spec)
      section = spec[/^### 1\.3 Copy deck.*?\n(.*?)(?=^#)/m, 1].to_s
      section.lines.grep(/\A\|/).filter_map do |row|
        cells = row.split("|").map(&:strip)
        [cells[1], cells[2]] if cells.size > 3 && !cells[1].match?(/\A(Item|-+)\z/)
      end.to_h
    end

    # The lines of the README section under "## <title>".
    def section(markdown, title)
      markdown[/^## #{Regexp.escape(title)}[ \t]*\n(.*?)(?=^## |\z)/m, 1]
    end
  end

  def initialize(root, yard: true)
    @root = File.expand_path(root)
    @yard = yard
  end

  # @return [Array<String>] every problem found, empty when the docs are consistent
  def problems
    checks = %i[missing_file_problems copy_problems gemspec_problems snippet_problems link_problems security_table_problems
                help_link_problems skill_problems package_problems em_dash_problems]
    checks.push(:yard_problems, :pinned_api_problems) if @yard
    checks.flat_map { |check| send(check) }
  end

  def missing_file_problems
    MARKDOWN.reject { |file| exist?(file) }.map { |file| "#{file}: missing" }
  end

  def copy_problems
    deck = copy_deck
    COPY_SURFACES.flat_map do |item, files|
      next ["#{COPY_DECK}: the copy deck has no #{item.inspect} row"] unless deck[item]

      files.filter_map do |file|
        "#{file}: missing the copy deck's #{item.downcase}: #{deck[item].inspect}" unless contains?(file, deck[item])
      end
    end
  end

  def gemspec_problems
    spec = gemspec
    deck = copy_deck
    problems = []
    problems << "#{GEMSPEC}: summary differs from the copy deck's gem summary" unless spec.summary == deck["Gem summary"]
    unless deck["Descriptor"] && spec.description.start_with?(deck["Descriptor"])
      problems << "#{GEMSPEC}: description does not start with the copy deck's descriptor"
    end
    problems
  end

  def snippet_problems
    SHARED_SNIPPETS.flat_map do |snippet|
      SNIPPET_SURFACES.fetch(snippet, [README, SKILL]).filter_map do |file|
        "#{file}: missing the shared snippet #{snippet.inspect}" unless read(file).include?(snippet)
      end
    end
  end

  def link_problems
    MARKDOWN.select { |file| exist?(file) }.flat_map do |file|
      self.class.links(read(file)).uniq.filter_map { |target| link_problem(file, target) }
    end
  end

  def security_table_problems
    table = (self.class.section(read(README), "Security") || "").lines.grep(/\A\|/).join
    return ["#{README}: no table under \"## Security\""] if table.empty?

    linked = table.scan(/\[((?:PS|AS|REN)-\d+)\]\(([^)\s]+)\)/)
    cited = table.scan(TEST_ID).map { |prefix, number| "#{prefix}-#{number}" }.uniq
    problems = (cited - linked.map(&:first)).map { |id| "#{README}: security table cites #{id} without linking its test" }
    problems += linked.filter_map do |id, url|
      path = repo_path(README, url)
      method = "def test_#{id.tr("-", "_")}_"
      if path.nil? || !File.file?(File.join(@root, path))
        "#{README}: security table links #{id} to #{url}, which is not a file in this repository"
      elsif !File.read(File.join(@root, path)).include?(method)
        "#{README}: security table links #{id} to #{path}, which has no #{method}* test"
      end
    end
    problems << "#{README}: the security table cites fewer than 10 tests" if cited.size < 10
    problems
  end

  def help_link_problems
    require File.join(@root, "lib/csv_preview/errors")
    return ["lib/csv_preview/errors.rb: no CsvPreview::Help module of README links"] unless defined?(CsvPreview::Help)

    urls = CsvPreview::Help.constants.map { |name| CsvPreview::Help.const_get(name) }.grep(String)
    Dir[File.join(@root, "lib/**/*.rb")].each { |path| urls.concat(File.read(path).scan(%r{#{Regexp.escape(REPO_URL)}#[\w-]+})) }
    readme_anchors = anchors(README)
    urls.uniq.filter_map do |url|
      anchor = url[REPO_ANCHOR, 1]
      "lib/: error messages link #{url}, but README.md has no such heading" if anchor && !readme_anchors.include?(anchor)
    end
  end

  def skill_problems
    return ["#{SKILL}: missing"] unless exist?(SKILL)

    text = read(SKILL)
    front, body = text.match(/\A---\n(.*?)\n---\n(.*)\z/m)&.captures
    return ["#{SKILL}: no YAML frontmatter"] unless front

    meta = YAML.safe_load(front)
    problems = []
    dir = File.basename(File.dirname(SKILL))
    problems << "#{SKILL}: name must be #{dir.inspect} (the directory)" unless meta["name"] == dir
    description = meta["description"].to_s
    if description.empty? || description.length > SKILL_DESCRIPTION_CHARS
      problems << "#{SKILL}: description must be 1 to #{SKILL_DESCRIPTION_CHARS} characters"
    end
    problems << "#{SKILL}: body has #{body.lines.size} lines, the limit is #{SKILL_BODY_LINES}" if body.lines.size >= SKILL_BODY_LINES
    problems
  end

  def package_problems
    files = gemspec.files
    missing = PACKAGED.reject { |path| files.include?(path) }.map { |path| "#{GEMSPEC}: the gem does not package #{path}" }
    missing + files.grep(NOT_PACKAGED).map { |path| "#{GEMSPEC}: the gem packages #{path}, which is for the repository only" }
  end

  def em_dash_problems
    out, status = Open3.capture2("git", "ls-files", "-z", "--cached", "--others", "--exclude-standard", chdir: @root)
    return ["git ls-files failed"] unless status.success?

    out.split("\0").reject { |path| path.start_with?("test/") }.flat_map do |path|
      full = File.join(@root, path)
      next [] unless File.file?(full)

      text = File.binread(full).force_encoding(Encoding::UTF_8)
      next [] unless text.valid_encoding? && !text.include?("\0")

      text.each_line.with_index(1).filter_map { |line, number| "#{path}:#{number}: em dash" if line.include?(EM_DASH) }
    end
  end

  def yard_problems
    out, status = Open3.capture2e(RbConfig.ruby, Gem.bin_path("yard", "yard"), "stats", "--list-undoc", "--no-save",
                                  chdir: @root)
    problems = out.lines.grep(/\[warn\]|\[error\]/).map { |line| "yard: #{line.strip}" }
    problems << "yard stats failed:\n#{out}" unless status.success?
    if out.include?("Undocumented Objects:")
      problems << "yard: undocumented public API:\n#{out[/Undocumented Objects:\n(.*)/m, 1].strip}"
    end
    problems << "yard: the public API is not 100% documented" unless out.include?("100.00% documented")
    problems
  end

  # @param paths [Array<String>] YARD paths of the methods to check
  def pinned_api_problems(paths = PINNED_API)
    require "yard"
    YARD::Registry.clear
    YARD::Logger.instance.enter_level(YARD::Logger::Severity::ERROR) do
      Dir.chdir(@root) { YARD.parse("lib/**/*.rb") }
    end
    paths.flat_map do |path|
      object = YARD::Registry.at(path)
      next ["yard: #{path} is not defined in lib/"] unless object

      documented = object.tags(:param).map(&:name)
      missing = object.parameters.map(&:first).reject { |name| name.start_with?("&") }.map { |name| name.delete("*:") }
      problems = (missing - documented).map { |name| "yard: #{path} has no @param for #{name}" }
      problems << "yard: #{path} has no @example" unless object.has_tag?(:example)
      problems << "yard: #{path} has no @return" unless object.has_tag?(:return)
      problems
    end
  ensure
    YARD::Registry.clear if defined?(YARD::Registry)
  end

  private

  def read(file) = exist?(file) ? File.read(File.join(@root, file)) : ""

  def exist?(file) = File.exist?(File.join(@root, file))

  def contains?(file, text) = exist?(file) && self.class.normalize(read(file)).include?(text)

  def anchors(file)
    @anchors ||= {}
    @anchors[file] ||= self.class.anchors(read(file))
  end

  def copy_deck
    @copy_deck ||= self.class.copy_deck(read(COPY_DECK))
  end

  def gemspec
    @gemspec ||= Dir.chdir(@root) { Gem::Specification.load(GEMSPEC) }
  end

  # The repository path a link points to, or nil for links that leave the repository.
  def repo_path(file, target)
    return target.delete_prefix(RAW_PREFIX).split("#").first if target.start_with?(RAW_PREFIX)
    return target[REPO_PATH, 1] if target.match?(REPO_PATH)
    return nil if target.match?(%r{\A[a-z][a-z0-9+.-]*:}i) || target.start_with?("#")

    path = target.split("#").first
    File.expand_path(path, File.join(@root, File.dirname(file))).delete_prefix("#{@root}/")
  end

  def link_problem(file, target)
    if (anchor = target[/\A#(.+)\z/, 1])
      return "#{file}: link to ##{anchor}, but #{file} has no such heading" unless anchors(file).include?(anchor)
    elsif (anchor = target[REPO_ANCHOR, 1])
      return "#{file}: link to #{target}, but README.md has no such heading" unless anchors(README).include?(anchor)
    elsif (path = repo_path(file, target))
      full = File.join(@root, path)
      return "#{file}: link to #{target}, but #{path} does not exist" unless File.exist?(full)

      anchor = target[/#(.+)\z/, 1]
      if anchor && path.end_with?(".md") && !anchors(path).include?(anchor)
        return "#{file}: link to #{target}, but #{path} has no such heading"
      end
    end
    nil
  end
end
