# frozen_string_literal: true

module Candor
  # Compiles a method's +parameters+ into a dispatch lambda carrying the same parameter kinds, in the
  # same order, and therefore the same +arity+.
  #
  # Rendering switches on a parameter's *kind*, never its name. +Method#parameters+ reports names that
  # cannot be used as parameters (+:_1+), names that are reserved words (+:end+), and entries with no
  # name at all — +[[:req]]+, for both +it+ and a destructuring parameter. A renderer that echoed names
  # would die on most real shapes, and on +it+ it would fail *silently*, emitting arity 0. So every
  # positional, rest, keyrest and block parameter gets a generated name; only keyword names survive,
  # because a keyword name is the calling convention.
  #
  # Those surviving names are the only user input in the generated source, and Ruby lets a parameter
  # shadow anything the source would otherwise reach. So the lambda closes over nothing it could lose:
  # the canonical name is a Symbol literal, +binding()+ is called with parentheses a local cannot
  # shadow, and every generated local is prefixed with a run of underscores no keyword name starts
  # with. Only the sentinel survives as a free variable, and it is created by the rendered source
  # itself, under that same collision-free prefix.
  #
  # The lambda is rendered on one line, so +eval+'s line forges its +source_location+ exactly.
  #
  # The call site it forwards to is one of two shapes. With +via+ it is +via(:name, args…)+, an
  # interceptor that receives the canonical name; without, it is +name(args…)+, calling the body
  # directly. Either way the target is a method name interpolated into +eval+'d source, so
  # {method_name!} gates it first.
  #
  #   Candor::Signature.compile([%i[req a]], name: :greet, via: :__call, source_location: loc)
  #   # => ->(__p0) { __call(:greet, __p0) }
  class Signature
    # Reserved words that are legal keyword parameter names but illegal as a bare reference:
    # +__k[:end] = end+ is a +SyntaxError+.
    RESERVED_WORDS = %w[
      __ENCODING__ __FILE__ __LINE__ alias and begin break case class def do else elsif end ensure
      false for if in module next nil not or redo rescue retry return self super then true undef
      unless until when while yield
    ].freeze

    # Kinds whose reported name is the calling convention and must be preserved.
    NAMED_KINDS = %i[keyreq key].freeze

    # Kinds that may have to be dropped from the forwarded arguments, so the body applies its own default.
    OPTIONAL_KINDS = %i[opt key].freeze

    # The generated local's name, after the collision-free prefix and before the parameter's index.
    SUFFIXES = { req: "p", opt: "p", rest: "r", keyrest: "kr", block: "b" }.freeze

    # How many optional keywords still dispatch through call sites rather than a Hash. Each one doubles
    # the sites, so four is where a shape nobody writes stops paying for one everybody does.
    KEYWORD_BRANCH_LIMIT = 2

    # The lambda's parameter declaration, per kind: the name, then the sentinel. Filled with `sub`, not
    # `%`: +:nokey+ takes neither, and `format` warns about the unused arguments under +-w+.
    DECLARATIONS = {
      req: "%s", opt: "%s = %s", rest: "*%s", keyreq: "%s:", key: "%s: %s",
      keyrest: "**%s", nokey: "**nil", block: "&%s"
    }.freeze

    # Every kind +Method#parameters+ can emit, and the only ones {render} accepts.
    KINDS = DECLARATIONS.keys.freeze

    # A name the generated source may call with parentheses. Operators, spaces and everything else a
    # +Symbol+ can hold are rejected before they reach +eval+.
    METHOD_NAME = /\A[a-zA-Z_][a-zA-Z0-9_]*[?!]?\z/

    # A name the generated source may declare as a keyword parameter. Reserved words qualify — the
    # source reads them back through +binding()+ — but a numbered parameter does not.
    KEYWORD_NAME = /\A[a-zA-Z_][a-zA-Z0-9_]*\z/

    # Names Ruby reserves for the numbered block parameters; +->(_1: 1) {}+ is a +SyntaxError+.
    NUMBERED_PARAMETERS = (1..9).map { |i| "_#{i}" }.freeze

    # How the source is spelled, and what the two name gates happen to be spelled as. A consumer builds
    # against {compile}, {method_name!} and {parameters!} — which raise — not against the patterns and
    # tables they are written in terms of. Only {KINDS} and {KEYWORD_BRANCH_LIMIT} name something a
    # caller has to know to use the compiler, so only those two stay public.
    private_constant :RESERVED_WORDS, :NAMED_KINDS, :OPTIONAL_KINDS, :SUFFIXES, :DECLARATIONS,
                     :METHOD_NAME, :KEYWORD_NAME, :NUMBERED_PARAMETERS

    class << self
      # +eval+'s file and line forge the lambda's — and therefore the compiled method's —
      # +source_location+ onto the body the caller supplied.
      #
      # @param parameters [Array<Array>] a *compiled* method's +parameters+; a Proc's would report every
      #   positional as +:opt+ and silently destroy arity strictness
      # @param name [Symbol] the method to call, or — with +via+ — the canonical name handed to it
      # @param source_location [Array(String, Integer)] the body's
      # @param via [Symbol, nil] an interceptor method taking +(name, ...)+; omit to call +name+ directly
      # @return [Proc] a lambda taking the body's parameter kinds and forwarding to the call site
      # @raise [ArgumentError] if the call site's name or the parameter shape is malformed
      def compile(parameters, name:, source_location:, via: nil)
        eval(render(parameters, name: name, via: via), binding, *source_location) # rubocop:disable Security/Eval
      rescue SyntaxError => e
        # {parameters!} sees one entry at a time; only the parser sees the combination — two rests, a
        # duplicate keyword, a block before a positional. A +SyntaxError+ is a +ScriptError+, which a
        # consumer's +rescue+ never catches.
        raise ArgumentError, "malformed parameters: #{parameters.inspect} (#{e.message.lines.first.strip})"
      end

      # @param parameters [Array<Array>]
      # @param name [Symbol]
      # @param via [Symbol, nil]
      # @return [String] single-line source for a lambda forwarding to the call site
      # @raise [ArgumentError] if the call site's name or the parameter shape is malformed
      def render(parameters, name:, via: nil) = new(parameters, name, via).source

      # The call site is interpolated into +eval+'d source, so its name is a trust boundary rather than
      # a typo check.
      #
      # @param name [Symbol, String]
      # @return [Symbol] the name
      # @raise [ArgumentError] unless the name can be called with parentheses
      def method_name!(name)
        string = name.to_s
        # +:class+ is callable on a receiver and useless here: the generated source calls the site bare,
        # and a bare +class(…)+ is a +SyntaxError+. Say that, rather than "not a callable method name".
        if RESERVED_WORDS.include?(string)
          raise ArgumentError, "#{name.inspect} is a reserved word: the generated source would call it bare"
        end
        raise ArgumentError, "not a callable method name: #{name.inspect}" unless METHOD_NAME.match?(string)

        string.to_sym
      end

      # A parameter shape reaching {render} from a consumer's override never passed Ruby's parser, so
      # every kind and every keyword name is checked here rather than discovered as a +SyntaxError+.
      #
      # @param parameters [Array<Array>]
      # @return [Array<Array>] the shape
      # @raise [ArgumentError] unless every entry is a known kind, with a usable name where one is required
      def parameters!(parameters)
        raise ArgumentError, "malformed parameters: #{parameters.inspect}" unless parameters.is_a?(Array)

        # +index+, not +find+: a +nil+ entry is malformed, and +find+ would hand back the same +nil+ it
        # returns when every entry is fine. The caller passed the Array; naming the offender saves a bisect.
        index = parameters.index { |entry| !valid_entry?(entry) }
        raise ArgumentError, "malformed parameters: entry #{index} is #{parameters[index].inspect}" if index

        parameters
      end

      private

      # @param entry [Object]
      # @return [Boolean]
      def valid_entry?(entry)
        return false unless entry.is_a?(Array) && KINDS.include?(entry.first)

        case entry.size
        when 1 then !NAMED_KINDS.include?(entry.first)
        when 2 then valid_name?(entry.first, entry[1])
        else false
        end
      end

      # A keyword name is the one piece of the shape the source carries verbatim; every other name is
      # replaced by a generated one and so may be anything, or nothing.
      #
      # @param kind [Symbol]
      # @param name [Object]
      # @return [Boolean]
      def valid_name?(kind, name)
        return false unless name.is_a?(Symbol)
        return true unless NAMED_KINDS.include?(kind)

        string = name.to_s
        KEYWORD_NAME.match?(string) && !NUMBERED_PARAMETERS.include?(string)
      end
    end

    # @param parameters [Array<Array>]
    # @param name [Symbol]
    # @param via [Symbol, nil]
    def initialize(parameters, name, via = nil)
      self.class.parameters!(parameters)
      @target = self.class.method_name!(via || name)
      # With an interceptor the canonical name leads the argument list, as a literal rather than a free
      # variable a keyword could capture.
      @literal = via ? name.to_sym.inspect : nil
      @prefix = collision_free_prefix(parameters)
      @unset = "#{@prefix}u"
      @hash = "#{@prefix}k"
      @entries = entries(parameters)
      @optionals = @entries.select { |entry| OPTIONAL_KINDS.include?(entry.first) }
    end

    # The sentinel marking an unpassed optional is a local, not a constant: +Module#const_get+ pierces
    # +private_constant+, so a caller could obtain the sentinel and pass it as an argument, silently
    # defeating an optional's default.
    #
    # @return [String]
    def source = "#{@unset} = ::Object.new.freeze; ->(#{declarations}) { #{dispatch} }"

    private

    # @param parameters [Array<Array>]
    # @return [Array<Array(Symbol, String)>] each kind paired with the local the lambda gives it
    def entries(parameters)
      parameters.each_with_index.map { |(kind, given), index| [kind, local(kind, given, index)] }
    end

    # No keyword name starts with the returned prefix, so no generated local can be shadowed by one.
    #
    # @param parameters [Array<Array>]
    # @return [String]
    def collision_free_prefix(parameters)
      keywords = parameters.filter_map { |kind, given| given.to_s if NAMED_KINDS.include?(kind) }
      prefix = "__"
      prefix += "_" while keywords.any? { |keyword| keyword.start_with?(prefix) }
      prefix
    end

    # @param kind [Symbol]
    # @param given [Symbol, nil]
    # @param index [Integer]
    # @return [String]
    def local(kind, given, index) = NAMED_KINDS.include?(kind) ? given.to_s : "#{@prefix}#{SUFFIXES[kind]}#{index}"

    # @return [String] the lambda's parameter list
    def declarations
      @entries.map { |kind, name| DECLARATIONS[kind].sub("%s", name).sub("%s", @unset) }.join(", ")
    end

    # An optional's default expression is unrecoverable from +parameters+, so an unpassed optional is
    # dropped from the forwarded arguments and the body applies its own default. Which ones were passed
    # is a runtime fact, and {#branch} enumerates it as call sites rather than an Array: nothing is
    # allocated, and every kind around the optionals forwards straight through — a rest as `*r`, a
    # keyrest as `**kw`.
    #
    # Optional *keywords* are independently passed, so enumerating them costs +2**n+ call sites rather
    # than +n + 1+. Past {KEYWORD_BRANCH_LIMIT} of them the source would balloon, so they go through a
    # Hash instead and the branching sees only the positionals.
    #
    # @return [String] the lambda's body
    def dispatch
      keywords = @optionals.select { |entry| entry.first == :key }
      hash = keywords.size > KEYWORD_BRANCH_LIMIT
      statements = hash ? keyword_setup : []
      statements << branch(hash ? @optionals - keywords : @optionals, [], hash)
      statements.join("; ")
    end

    # Ruby fills optional positionals left to right, so an unpassed one guarantees every optional
    # positional after it went unpassed too. The states are a chain of +n + 1+ call sites, not the
    # +2**n+ a subset would need.
    #
    # @param optionals [Array<Array(Symbol, String)>] those still to be decided
    # @param dropped [Array<Array(Symbol, String)>] those already known unpassed
    # @param hash [Boolean]
    # @return [String] a call site, or a ternary choosing between two of them
    def branch(optionals, dropped, hash)
      return call(@entries - dropped, hash) if optionals.empty?

      first, *rest = optionals
      trailing = first.first == :opt ? rest.select { |entry| entry.first == :opt } : []
      unpassed = branch(rest - trailing, dropped + [first] + trailing, hash)
      "#{@unset}.equal?(#{value(first)}) ? #{unpassed} : #{branch(rest, dropped, hash)}"
    end

    # The target takes parentheses and, usually, an argument — neither of which a local of the same name
    # can shadow.
    #
    # @param entries [Array<Array(Symbol, String)>]
    # @param hash [Boolean]
    # @return [String]
    def call(entries, hash) = "#{@target}(#{[*@literal, *forward(entries, hash)].join(", ")})"

    # @param entry [Array(Symbol, String)]
    # @return [String] source reading that parameter's value
    def value(entry) = entry.first == :key ? reference(entry.last) : entry.last

    # A keyrest is the accumulator rather than a source to merge in: +**+ capture already allocated a Hash the
    # lambda alone owns, and Ruby routes a declared keyword to its own parameter, never into the keyrest — so
    # seeding from it and assigning after is what +{}+ plus +update+ was, one Hash cheaper.
    #
    # @return [Array<String>]
    def keyword_setup
      keyrest = @entries.find { |kind, _name| kind == :keyrest }
      @entries.filter_map do |kind, name|
        case kind
        when :keyreq then "#{@hash}[:#{name}] = #{reference(name)}"
        when :key then "#{@hash}[:#{name}] = #{reference(name)} unless #{@unset}.equal?(#{reference(name)})"
        end
      end.unshift("#{@hash} = #{keyrest ? keyrest.last : "{}"}")
    end

    # @param entries [Array<Array(Symbol, String)>]
    # @param hash [Boolean]
    # @return [Array<String>] the forwarded arguments
    def forward(entries, hash)
      args = positional_args(entries)
      args.concat(hash ? ["**#{@hash}"] : keyword_args(entries))
      args.concat(block_arg(entries))
    end

    # An +:opt+ appears here only on a call site that passes it: {#dispatch} drops it from the entries
    # of the call site that does not.
    #
    # @param entries [Array<Array(Symbol, String)>]
    # @return [Array<String>] in declaration order, so a rest keeps its place among the required
    def positional_args(entries)
      entries.filter_map do |kind, name|
        case kind
        when :req, :opt then name
        when :rest then "*#{name}"
        end
      end
    end

    # @param entries [Array<Array(Symbol, String)>]
    # @return [Array<String>]
    def keyword_args(entries)
      entries.filter_map do |kind, name|
        case kind
        when :keyreq, :key then "#{name}: #{reference(name)}"
        when :keyrest then "**#{name}"
        end
      end
    end

    # @param entries [Array<Array(Symbol, String)>]
    # @return [Array<String>] at most one element
    def block_arg(entries) = entries.filter_map { |kind, name| "&#{name}" if kind == :block }

    # +binding()+, never bare +binding+: a keyword named +binding+ is a local, and a local shadows the
    # very method this reaches for.
    #
    # @param name [String] a keyword parameter's name
    # @return [String] source reading that keyword's value
    def reference(name) = RESERVED_WORDS.include?(name) ? "binding().local_variable_get(:#{name})" : name
  end
end
