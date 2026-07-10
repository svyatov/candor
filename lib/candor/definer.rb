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
    # The only bodies +define_method+ accepts. A +#call+ object is not one of them, and converting it
    # would forge a +source_location+ nobody wrote.
    BODY_KINDS = [Proc, Method, UnboundMethod].freeze

    # @param target [Module] the module the method is installed onto
    # @param name [Symbol] the canonical name
    # @param aliases [Array<Symbol>] further names sharing the one dispatch
    # @param via [Symbol, nil] an interceptor method on +target+, resolved per call
    # @param parameters [Array<Array>, nil] an explicit shape, overriding the body's
    # @param body [Proc, Method, UnboundMethod]
    def initialize(target, name, aliases:, via:, parameters:, body:)
      @target = target
      @canonical = name.to_sym
      @names = [@canonical, *aliases.map(&:to_sym)].uniq
      @via = via
      @parameters = parameters
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
      validate_names!
      # Both call-site names are interpolated into `eval`'d source. Without `via` the body's own name is
      # the call site, so the canonical name has to survive being one.
      Signature.method_name!(@via || @body_name)
      Signature.parameters!(@parameters) if @parameters
      raise FrozenError.new("can't fabricate a method on frozen #{@target}", receiver: @target) if @target.frozen?
    end

    # +source_location+ is the one reliable discriminator: Ruby exposes no +curried?+ predicate, and a
    # curried proc, a symbol-to-proc and a C-defined method all report +nil+. R5 cannot be honoured for
    # any of them, and honouring R5 is the product.
    #
    # @return [void]
    # @raise [TypeError]
    def validate_body!
      raise TypeError, body_error unless BODY_KINDS.any? { |kind| @body.is_a?(kind) }
      raise TypeError, body_error if @body.source_location.nil?
      return unless @body.is_a?(Method) || @body.is_a?(UnboundMethod)
      # `define_method` would raise this itself — after the prior wrapper was already removed.
      raise TypeError, "#{@body.owner} is not an ancestor of #{@target}" unless @target <= @body.owner
    end

    # @return [void]
    # @raise [ArgumentError]
    def validate_names!
      offender = @names.find { |name| name.to_s.start_with?(BODY_PREFIX) }
      return unless offender

      raise ArgumentError, "#{offender.inspect} starts with the reserved prefix #{BODY_PREFIX.inspect}"
    end

    # @return [String]
    def body_error
      "body must be a block, a Proc, a Method or an UnboundMethod with a source_location, " \
        "got #{@body.inspect}; curried procs, `#call` objects and C-defined methods have none"
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
      Signature.compile(shape, name: @via ? @canonical : @body_name, via: @via,
                               source_location: @body.source_location)
    end

    # @param dispatch [Proc]
    # @return [void]
    def install(dispatch) = silently { @names.each { |name| @target.define_method(name, &dispatch) } }
  end
end
