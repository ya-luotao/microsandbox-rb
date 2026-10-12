# frozen_string_literal: true

# Locks sig/microsandbox.rbs to the loaded gem by reflection. The signature
# file is maintained by hand, so it drifts without anything failing: a method
# gains a keyword, a class is added or removed, a constructor takes arguments
# the sig never declared. Every public class/module/method must be declared,
# nothing declared may be missing at runtime, and positional arity, keyword
# names, required-vs-optional, visibility and superclass must agree. Methods
# that take `**kwargs` and forward to a shared keyword builder are compared
# against the builder. Block contracts (whether a method requires, accepts or
# forbids a block) are outside the comparison.

require "rbs"

RSpec.describe "sig/microsandbox.rbs contract" do
  sig_path = File.expand_path("../../sig/microsandbox.rbs", __dir__)
  decls = RBS::Parser.parse_signature(RBS::Buffer.new(name: sig_path, content: File.read(sig_path)))[2]

  # Runtime methods that are deliberately NOT part of the typed public surface.
  # Each entry must carry a reason; the spec fails if an entry goes stale.
  internal = {
    "Microsandbox.close_after" => "@api private block-then-close helper",
    "Microsandbox.coerce_write_bytes" => "@api private write-coercion helper",
    "Microsandbox.time_from_ms" => "@api private epoch-milliseconds helper",
    "Microsandbox::Rule.build" => "@api private (module_function side effect)",
    "Microsandbox::Rule.normalize_destination" => "@api private (module_function side effect)",
    "Microsandbox::Sandbox.acquire" => "@api private; public only because PullSession#sandbox calls it across classes",
    "Microsandbox::Sandbox.build_create_opts" => "@api private keyword builder"
  }.freeze
  # Methods whose `**kwargs` are forwarded verbatim to a keyword builder: the
  # builder's keyword list is their real signature.
  kw_builders = {
    "Microsandbox::Sandbox.create" => :build_create_opts,
    "Microsandbox::Sandbox.connect_or_create" => :build_create_opts,
    "Microsandbox::Sandbox.create_with_progress" => :build_create_opts,
    "Microsandbox::Sandbox#modify" => :build_modify_opts,
    "Microsandbox::SandboxHandle#modify" => :build_modify_opts
  }.freeze
  # Namespaces the sig does not describe: Native is the extension's own
  # (untyped) layer, and Binaries belongs to the companion gem, which other
  # specs load from binaries/ into this process.
  untyped_namespaces = %w[Microsandbox::Native Microsandbox::Binaries].freeze

  d = RBS::AST::Declarations
  m = RBS::AST::Members
  # "Microsandbox::X" => {kind:, super:, methods: {"#name"/".name" => [overload shapes]}, private: [keys]}
  sig = {}
  walk = lambda do |decl, prefix|
    path = prefix ? "#{prefix}::#{decl.name}" : decl.name.to_s
    entry = sig[path] ||= {kind: decl.is_a?(d::Class) ? :class : :module,
                           super: decl.is_a?(d::Class) && decl.super_class&.name&.to_s, methods: {}, private: []}
    section = :public # a bare `private`/`public` covers the instance members that follow it
    decl.members.each do |mem|
      if mem.is_a?(m::MethodDefinition) || mem.is_a?(m::AttrReader)
        visibility = mem.visibility || ((mem.kind == :instance) ? section : :public)
        entry[:private] << "#{(mem.kind == :instance) ? "#" : "."}#{mem.name}" if visibility == :private
      end
      case mem
      when m::Private then section = :private
      when m::Public then section = :public
      when d::Class, d::Module then walk.call(mem, path)
      when m::MethodDefinition
        shapes = mem.overloads.map do |o|
          f = o.method_type.type
          {req: f.required_positionals.size + f.trailing_positionals.size, opt: f.optional_positionals.size,
           rest: !f.rest_positionals.nil?, keyreq: f.required_keywords.keys.map(&:to_s).sort,
           key: f.optional_keywords.keys.map(&:to_s).sort, keyrest: !f.rest_keywords.nil?}
        end
        entry[:methods]["#{(mem.kind == :instance) ? "#" : "."}#{mem.name}"] = shapes
      when m::AttrReader
        entry[:methods]["#{(mem.kind == :instance) ? "#" : "."}#{mem.name}"] =
          [{req: 0, opt: 0, rest: false, keyreq: [], key: [], keyrest: false}]
      end
    end
  end
  decls.each { |decl| walk.call(decl, nil) }

  runtime_shape = lambda do |params|
    by = params.group_by(&:first)
    {req: by.fetch(:req, []).size, opt: by.fetch(:opt, []).size, rest: by.key?(:rest),
     keyreq: by.fetch(:keyreq, []).map { |_, n| n.to_s }.sort, key: by.fetch(:key, []).map { |_, n| n.to_s }.sort,
     keyrest: by.key?(:keyrest)}
  end

  namespaces = ObjectSpace.each_object(Module).select do |mod|
    n = mod.name
    n && (n == "Microsandbox" || n.start_with?("Microsandbox::")) &&
      untyped_namespaces.none? { |u| n == u || n.start_with?("#{u}::") }
  end.sort_by(&:name)

  it "declares every runtime class/module, and nothing that no longer exists" do
    runtime_names = namespaces.map(&:name)
    expect(runtime_names - sig.keys).to be_empty, "missing from sig: #{(runtime_names - sig.keys).inspect}"
    expect(sig.keys - runtime_names).to be_empty, "stale in sig: #{(sig.keys - runtime_names).inspect}"
  end

  namespaces.each do |mod|
    entry = sig[mod.name] or next
    describe mod.name do
      if mod.is_a?(Class)
        it "has the declared superclass" do
          declared = entry[:super] ? entry[:super].delete_prefix("::") : "Object"
          expect(mod.superclass.name.split("::").last).to eq(declared.split("::").last)
        end
      end

      module_function_like = !mod.is_a?(Class) && mod.name != "Microsandbox"
      sides = {"." => mod.singleton_class}
      sides["#"] = mod unless module_function_like
      sides.each do |sep, target|
        own_public = target.public_instance_methods(false).map(&:to_s)
        # `#inspect` is every object's debugging hook, not typed surface. A
        # singleton `inspect` (Image.inspect) is a real API and stays in.
        own_public -= %w[inspect] if sep == "#"
        declared = entry[:methods].keys.select { |k| k.start_with?(sep) }.map { |k| k[1..] } - %w[initialize]
        declared_private = declared.select { |n| entry[:private].include?("#{sep}#{n}") }

        it "declares every public #{(sep == ".") ? "singleton" : "instance"} method (and no stale ones)" do
          undeclared = (own_public - declared).reject { |n| internal.key?("#{mod.name}#{sep}#{n}") }
          stale = (declared - declared_private).reject { |n| target.public_method_defined?(n) }
          expect(undeclared).to be_empty, "public at runtime, absent from sig: #{undeclared.inspect}"
          expect(stale).to be_empty, "declared in sig, not public at runtime: #{stale.inspect}"
        end

        it "declares no public #{(sep == ".") ? "singleton" : "instance"} method private (and no missing private ones)" do
          hidden = own_public & declared_private
          stale = declared_private.reject { |n| target.private_method_defined?(n) || own_public.include?(n) }
          expect(hidden).to be_empty, "public at runtime, declared private in sig: #{hidden.inspect}"
          expect(stale).to be_empty, "declared private in sig, not private at runtime: #{stale.inspect}"
        end

        (own_public & declared).each do |name|
          it "#{sep}#{name} has matching parameters" do
            shape = runtime_shape.call(target.instance_method(name).parameters)
            if (builder = kw_builders["#{mod.name}#{sep}#{name}"])
              b = runtime_shape.call(Microsandbox::Sandbox.method(builder).parameters)
              shape = shape.merge(keyreq: b[:keyreq], key: b[:key], keyrest: false)
            end
            candidates = entry[:methods]["#{sep}#{name}"].map do |s|
              # `**untyped` in the sig stands in for a builder's fixed keyword set.
              (builder && s[:keyrest]) ? s.merge(keyreq: shape[:keyreq], key: shape[:key], keyrest: false) : s
            end
            expect(candidates).to include(shape)
          end
        end
      end

      # The sig file's own header promises `initialize` is declared wherever the
      # synthesized `new: () -> instance` would be wrong.
      if mod.is_a?(Class) && !(mod <= Exception) && mod.instance_method(:initialize).owner == mod
        it "declares #initialize when the constructor takes arguments" do
          shape = runtime_shape.call(mod.instance_method(:initialize).parameters)
          needs_args = shape[:req].positive? || shape[:keyreq].any?
          declared = entry[:methods]["#initialize"]
          if needs_args
            expect(declared).not_to be_nil, "RBS synthesizes `#{mod.name}.new: () -> instance`, but #initialize needs arguments"
            expect(declared).to include(shape)
          end
        end
      end
    end
  end

  it "has no stale allowlist entries" do
    stale = internal.keys.reject do |key|
      owner, sep, name = key.rpartition(/[.#]/).then { |o, s, n| [Object.const_get(o), s, n] }
      ((sep == ".") ? owner.singleton_class : owner).public_method_defined?(name)
    end
    expect(stale).to be_empty
    expect(kw_builders.values.uniq.reject { |b| Microsandbox::Sandbox.respond_to?(b, true) }).to be_empty
  end
end
