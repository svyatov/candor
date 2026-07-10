# frozen_string_literal: true

module Candor
  # Fabricates a real method from a block or a callable: compile the body strictly, read its true
  # parameter shape, render a signature-identical wrapper, install it.
  #
  # The pipeline is an order, not a sequence of conveniences. Every check runs before the first
  # mutation, so a rejected fabrication leaves the target exactly as it was — a frozen target, an
  # unbindable +Method+, a name under the reserved prefix and a malformed shape all raise before the
  # prior wrapper is replaced. The parameter shape is then read from the *compiled* method, never from
  # the Proc, which reports every positional as +:opt+ and would silently destroy arity strictness.
  #
  # @api private
  class Definer
    # The only bodies +define_method+ accepts. A +#call+ object is not one of them, and no
    # +source_location:+ rescues it: the refusal is about the kind, not the location.
    BODY_KINDS = [Proc, Method, UnboundMethod].freeze

    # @param target [Module] the module the method is installed onto
    # @param name [Symbol] the canonical name
    # @param aliases [Array<Symbol>] further names sharing the one dispatch
    # @param via [Symbol, nil] an interceptor method on +target+, resolved per call
    # @param parameters [Array<Array>, nil] an explicit shape, overriding the body's
    # @param source_location [Array(String, Integer), nil] a location, overriding the body's
    # @param body [Proc, Method, UnboundMethod]
    def initialize(target, name, aliases:, via:, parameters:, source_location:, body:)
      @target = target
      @canonical = name.to_sym
      @names = [@canonical, *aliases.map(&:to_sym)].uniq
      @via = via
      @parameters = parameters
      @source_location = source_location
      @body = body
      @body_name = Candor.body_name(@canonical)
    end

    # @return [Symbol] the canonical name
    def call
      validate!
      # An overridden shape never passed Ruby's parser, so it is compiled before the first mutation: a
      # combination {Signature.parameters!} cannot see — two rests, a duplicate keyword — must not fail once
      # the body is already installed. A shape read from the compiled body always renders.
      dispatch = compile(@parameters) if @parameters
      # Definition is a boot-time operation, so one global lock is the whole answer to concurrency;
      # the dispatch it installs takes no lock at all.
      MONITOR.synchronize do
        install_body
        install(dispatch || compile(@target.instance_method(@body_name).parameters))
      end
      @canonical
    end

    private

    # @return [void]
    # @raise [TypeError, ArgumentError, FrozenError]
    def validate!
      raise TypeError, "target must be a Module, got #{@target.inspect}" unless @target.is_a?(Module)

      validate_body!
      validate_location!
      validate_names!
      # Both call-site names are interpolated into `eval`'d source. Without `via` the body's own name is
      # the call site, so the canonical name has to survive being one.
      Signature.method_name!(@via || @body_name)
      Signature.parameters!(@parameters) if @parameters
      raise FrozenError.new("can't fabricate a method on frozen #{@target}", receiver: @target) if @target.frozen?
    end

    # @return [void]
    # @raise [TypeError]
    def validate_body!
      raise TypeError, kind_error unless BODY_KINDS.any? { |kind| @body.is_a?(kind) }
      return unless @body.is_a?(Method) || @body.is_a?(UnboundMethod)
      # `define_method` would raise this itself — after the prior wrapper was already removed.
      raise TypeError, "#{@body.owner} is not an ancestor of #{@target}" unless @target <= @body.owner
    end

    # A body's +source_location+ is the one reliable discriminator: Ruby exposes no +curried?+ predicate,
    # and a curried proc, a symbol-to-proc and a C-defined method all report +nil+. Honouring the body's
    # location is the product, so a body carrying none is refused — unless the caller names one, which is
    # the caller assuming responsibility for the honesty. A caller that *rewrites* a location has to be
    # able to: a wrapper whose body is a proc literal the caller generated should point at what the user
    # wrote, not at the generator.
    #
    # {Signature.compile} gates the location it is handed, but a shape read from the compiled body only
    # reaches that gate once the body is installed. So an overridden location is gated here too, exactly
    # as {Signature.method_name!} is: the compiler owns the rule, and the pipeline pays it early enough
    # that a rejected fabrication still leaves the target untouched.
    #
    # @return [void]
    # @raise [TypeError, ArgumentError]
    def validate_location!
      Signature.source_location!(@source_location) if @source_location
      raise TypeError, no_location_error if location.nil?
    end

    # @return [Array(String, Integer), nil] the location the fabricated method will report
    def location = @source_location || @body.source_location

    # @return [void]
    # @raise [ArgumentError]
    def validate_names!
      offender = @names.find { |name| name.to_s.start_with?(BODY_PREFIX) }
      return unless offender

      raise ArgumentError, "#{offender.inspect} starts with the reserved prefix #{BODY_PREFIX.inspect}"
    end

    # @return [String]
    def kind_error
      "body must be a block, a Proc, a Method or an UnboundMethod with a source_location, " \
        "got #{@body.inspect}; a `#call` object is none of them, and no source_location: rescues it"
    end

    # Separate from {kind_error} because the remedy differs. Only a body +define_method+ accepts reaches
    # this, so naming a location really is the fix — where a +#call+ object is refused for its kind, and
    # naming one buys it nothing.
    #
    # @return [String]
    def no_location_error
      "#{@body.inspect} carries no source_location: curried procs, symbol-to-procs and C-defined " \
        "methods have none, so fabricating from one takes an explicit source_location:"
    end

    # +define_method+ replaces a method in place, so a re-fabrication is never observable as a missing
    # one. Calling +remove_method+ first — the obvious way to reinstall a name — leaves it undefined for
    # as long as the install takes, and a concurrent caller sees +NoMethodError+. Removal only ever bought
    # silence from the +-w+ redefinition warning, so buy that here instead.
    #
    # +$VERBOSE+ is process-global, and that is the ceiling: {MONITOR} serializes fabricators, so two of
    # them cannot interleave these assignments, but a thread warning about something else while one holds
    # the lock loses that warning. An install is microseconds, and this runs at boot.
    #
    # @return [void]
    def silently
      verbose = $VERBOSE
      $VERBOSE = nil
      yield
    ensure
      $VERBOSE = verbose
    end

    # An inherited method of the same name is shadowed by the install, never removed.
    #
    # @return [void]
    def install_body
      silently { @target.define_method(@body_name, @body) }
      @target.send(:private, @body_name)
    end

    # @param shape [Array<Array>]
    # @return [Proc] the dispatch lambda
    # @raise [ArgumentError] if the shape does not render to legal source
    def compile(shape)
      Signature.compile(shape, name: @via ? @canonical : @body_name, via: @via, source_location: location)
    end

    # @param dispatch [Proc]
    # @return [void]
    def install(dispatch) = silently { @names.each { |name| @target.define_method(name, &dispatch) } }
  end
end
