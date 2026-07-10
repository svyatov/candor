# frozen_string_literal: true

require "monitor"

require "candor/version"
require "candor/signature"
require "candor/definer"

# Turns a block or a callable into a real method with an honest signature: the body's arity, the body's
# +parameters+, the body's +source_location+, and allocation-free dispatch.
#
#   Candor.define(MyClass, :greet) { |name, greeting: "hi"| "#{greeting}, #{name}" }
#   MyClass.instance_method(:greet).parameters # => [[:req, :__p0], [:key, :greeting]]
#
# A wrong-arity call and an unknown keyword raise +ArgumentError+ at the fabricated method, before
# anything of yours runs.
module Candor
  # Prefix of the private methods holding compiled bodies. Fabricated names may not start with it, and
  # an interceptor reaches its body through {Candor.body_name}.
  BODY_PREFIX = "__candor_body_"

  # Fabrication is a boot-time operation, so one global lock serializes it; nothing is taken at call time.
  MONITOR = Monitor.new
  private_constant :MONITOR

  class << self
    # Defines a real method on +target+ whose signature is the body's.
    #
    # With +via+, every call routes to that method on the target as +via(canonical_name, ...)+, and it
    # alone decides whether to run the body — which it reaches under {body_name}. Without +via+, the
    # wrapper forwards straight to the body.
    #
    # An unpassed optional is dropped from the forwarded arguments, so the body applies its own default.
    #
    #   Candor.define(App.singleton_class, :fetch, aliases: [:get], via: :__call) { |id, ttl: 60| ... }
    #
    # @param target [Module] the module — often a +singleton_class+ — to install onto
    # @param name [Symbol] the canonical name, passed to the interceptor and used for the body method
    # @param aliases [Array<Symbol>] further names sharing the one dispatch and the one canonical name
    # @param via [Symbol, nil] an interceptor method on +target+, resolved per call
    # @param parameters [Array<Array>, nil] an explicit shape advertised instead of the body's; not
    #   validated against the body, so a mismatch surfaces as the body's own +ArgumentError+
    # @param source_location [Array(String, Integer), nil] a location reported instead of the body's, for
    #   a caller whose body is a proc it generated on the user's behalf; also the only way to fabricate
    #   from a body carrying no location of its own
    # @param body [Proc, Method, UnboundMethod, nil] the body, when it is not given as a block
    # @yield the body, when it is not given as +body+; +self+ inside it is the receiver
    # @return [Symbol] the canonical name
    # @raise [TypeError] if +target+ is not a Module, or the body is neither a block, a Proc, a Method
    #   nor an UnboundMethod, or neither it nor +source_location+ carries a location, or the body's owner
    #   is not an ancestor of +target+
    # @raise [ArgumentError] if a name starts with {BODY_PREFIX}, or +via+ is not a callable method
    #   name, or +parameters+ or +source_location+ is malformed
    # @raise [FrozenError] if +target+ is frozen
    def define(target, name, aliases: [], via: nil, parameters: nil, source_location: nil, body: nil, &block)
      Definer.new(target, name, aliases: aliases, via: via, parameters: parameters,
                                source_location: source_location, body: body || block).call
    end

    # The private method holding a fabricated method's body. An interceptor calls it with +send+.
    #
    # @param name [Symbol] a canonical name
    # @return [Symbol]
    def body_name(name) = :"#{BODY_PREFIX}#{name}"
  end

  private_constant :Definer
end
