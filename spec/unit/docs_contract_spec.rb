# frozen_string_literal: true

# Locks the prose that is supposed to follow the code: the pinned runtime tag
# quoted in docs, the README version table, CHANGELOG headings and links, the
# error table, the option list in docs/surface.md, the Ruby examples, and the
# release checklist. Nothing else fails when one of these goes stale, and each
# of them has gone stale here at least once.

require "ripper"
require "timeout"

RSpec.describe "documentation contract" do
  root = File.expand_path("../..", __dir__)
  read = ->(rel) { File.read(File.join(root, rel)) }
  tracked = Dir.chdir(root) { `git ls-files`.split("\n") }
  prose = tracked.grep(/\.(md|toml|rb|rs|rbs|example)\z/).reject { |f| f.start_with?("spec/") || f == "CHANGELOG.md" }

  # A hardcoded "pinned at vX" sentence outlives the runtime bump that makes it
  # wrong; the tag belongs in Microsandbox::RUNTIME_VERSION only.
  it "never states a pinned/current runtime tag other than RUNTIME_VERSION" do
    offenders = prose.flat_map do |f|
      read.call(f).each_line.with_index(1).filter_map do |line, no|
        next unless line =~ /\b(?:pinned|stays pinned|currently)\b[^.|\n]{0,60}?`?(v\d+\.\d+\.\d+)\b/
        "#{f}:#{no}: #{$1}" unless $1 == Microsandbox::RUNTIME_VERSION
      end
    end
    expect(offenders).to be_empty, "stale runtime-tag claims:\n  #{offenders.join("\n  ")}"
  end

  describe "README Versioning table" do
    rows = read.call("README.md").scan(/^\| `(\d+\.\d+\.\d+)`\s*\| `(v[\d.]+)`/)

    # A release that forgets the README leaves the table one row short.
    it "ends with the current gem/runtime pair" do
      expect(rows.last).to eq([Microsandbox::VERSION, Microsandbox::RUNTIME_VERSION])
      expect(read.call("README.md")).to include(%(Microsandbox::VERSION          # => "#{Microsandbox::VERSION}"))
    end

    # The table and the CHANGELOG are the two release histories a user reads;
    # a version prepared but never released must not get a row in either.
    it "lists only versions that have a CHANGELOG release heading" do
      released = read.call("CHANGELOG.md").scan(/^## \[(\d+\.\d+\.\d+)\]/).flatten
      unreleased = rows.map(&:first) - released
      expect(unreleased).to be_empty, "README Versioning rows without a CHANGELOG release heading: #{unreleased.inspect}"
    end
  end

  describe "CHANGELOG.md" do
    cl = read.call("CHANGELOG.md")
    headings = cl.scan(/^## \[([^\]]+)\]/).flatten
    refs = cl.scan(/^\[([^\]]+)\]: (\S+)/).to_h

    # The lines a git command printed, or nil when it failed or stalled: a
    # remote that cannot be reached is not a remote without tags.
    git_lines = lambda do |*args|
      io = IO.popen({"GIT_TERMINAL_PROMPT" => "0"}, ["git", *args], chdir: root, err: File::NULL)
      out = begin
        Timeout.timeout(15) { io.read }
      rescue Timeout::Error
        Process.kill("KILL", io.pid)
        nil
      ensure
        io.close
      end
      out&.lines(chomp: true) if Process.last_status&.success?
    end
    # Release tags of a remote without the leading "v", or nil when it did not
    # answer.
    remote_tags = lambda do |remote|
      git_lines.call("ls-remote", "--tags", remote)&.filter_map { |line| line[%r{\trefs/tags/v([^\^]+)}, 1] }
    end
    # The repository the link definitions point at: the one place that holds
    # every release tag (`origin` may be a fork or mirror with only some).
    canonical = refs.values.filter_map { |url| url[%r{\A(\S+?)/compare/}, 1] }.uniq

    it "has a section for the current version (or it is still Unreleased)" do
      expect(headings.first(2)).to include(Microsandbox::VERSION)
    end

    it "defines a link for every version heading" do
      expect(headings - refs.keys).to be_empty
    end

    it "compares [Unreleased] against the newest released version" do
      newest = (headings - ["Unreleased"]).first
      expect(refs["Unreleased"]).to end_with("/compare/v#{newest}...HEAD")
    end

    # A version prepared but never tagged must not keep a release heading: its
    # content shipped under the next tag.
    #
    # Tags come from the local list (CI checks out shallow, where it is empty),
    # from `origin`, and, while a heading is still unaccounted for or `origin`
    # did not answer, from the canonical repository. A local tag shows that a
    # release exists; only a remote that answered can show that one is missing.
    it "does not present a never-tagged version as released" do
      released = headings - ["Unreleased", Microsandbox::VERSION]
      tags = git_lines.call("tag").to_a.map { |t| t.delete_prefix("v") }
      answered = []
      ["origin", *canonical].each do |remote|
        break if answered.any? && (released - tags).empty?
        found = remote_tags.call(remote) or next
        answered << remote
        tags |= found
      end
      skip "no remote reachable: local tags cannot show that a release was never tagged" if answered.empty?
      if (released - tags).any? && canonical.any? && (canonical & answered).empty?
        skip "canonical repository unreachable: `origin` may hold only some of the release tags"
      end
      expect(released - tags).to be_empty
    end
  end

  # docs/errors.md is the user-facing table of lib/microsandbox/errors.rb.
  it "documents every error class with its exact #code" do
    documented = read.call("docs/errors.md").scan(/^\| `(\w+)` \| `([^`]+)` \|/).to_h
    actual = ObjectSpace.each_object(Class)
      .select { |c| c <= Microsandbox::Error && c.name&.match?(/\AMicrosandbox::\w+\z/) }
      .to_h { |c| [c.name.split("::").last, c.code] }
    expect(documented).to eq(actual)
  end

  # docs/surface.md calls itself the authoritative scope statement, so an
  # option that exists but is not named there is undocumented surface.
  it "names every create/modify keyword in docs/surface.md" do
    surface = read.call("docs/surface.md")
    keys = %i[build_create_opts build_modify_opts].flat_map { |b| Microsandbox::Sandbox.method(b).parameters.map(&:last) }.uniq
    missing = keys.reject { |k| surface.match?(/(?<!\w)#{k}(?!\w)/) }
    expect(missing).to be_empty, "create/modify keywords absent from docs/surface.md: #{missing.inspect}"
  end

  # Every ```ruby block in the shipped docs must at least parse.
  Dir.chdir(root) { Dir["README.md", "docs/*.md", "binaries/README.md"] }.sort.each do |doc|
    read.call(doc).scan(/^```ruby\n(.*?)^```/m).flatten.each_with_index do |code, i|
      it "#{doc} ruby block ##{i + 1} is valid Ruby" do
        expect(Ripper.sexp(code)).not_to be_nil, "does not parse:\n#{code}"
      end
    end
  end

  # The release checklists must name every version lock-step location; a file
  # they leave out is the one a release forgets to bump.
  %w[docs/releasing.md .claude/skills/release/SKILL.md].each do |doc|
    it "#{doc} names every version lock-step location" do
      text = read.call(doc)
      required = ["version.rb", "ext/microsandbox/Cargo.toml", "binaries.rb", "Cargo.lock",
        "microsandbox-runtime", "binaries/checksums"]
      expect(required.reject { |r| text.include?(r) }).to be_empty
    end
  end
end
