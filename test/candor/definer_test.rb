# frozen_string_literal: true

require "test_helper"

# The fabricator's lifecycle: what it accepts, what it refuses, and what it leaves behind.
class DefinerTest < CandorTest
  # An interceptor of briefly's shape: `__call(name, ...)`, reaching the body by the reserved prefix.
  def target
    @target ||= Class.new do
      attr_reader :calls

      def initialize = @calls = []

      private

      def __call(name, *args, **kwargs, &block)
        @calls << [name, args, kwargs]
        send(Candor.body_name(name), *args, **kwargs, &block)
      end
    end
  end

  def body_name(name = :greet) = Candor.body_name(name)

  # Bodies. `define_method` takes a Proc, a Method or an UnboundMethod, and nothing else.

  def test_a_block_body_runs_with_the_receiver_as_self
    Candor.define(target, :who) { self }
    instance = target.new

    assert_same instance, instance.who
  end

  def test_define_returns_the_canonical_name
    assert_equal :greet, Candor.define(target, :greet, aliases: [:hello]) { :hi }
  end

  def test_a_proc_body_with_required_positionals_compiles_to_a_strict_signature
    Candor.define(target, :add, body: proc { |a, b| a + b })

    assert_equal 2, target.instance_method(:add).arity
    assert_equal 3, target.new.add(1, 2)
    assert_raises(ArgumentError) { target.new.add(1) }
  end

  def test_a_method_body_is_accepted
    source = Class.new { def greet(name, greeting = "hi") = "#{greeting}, #{name}" }
    child = Class.new(source)
    Candor.define(child, :greet, body: source.new.method(:greet))

    assert_equal "hi, bob", child.new.greet("bob")
    assert_equal source.instance_method(:greet).source_location, child.instance_method(:greet).source_location
  end

  def test_an_unbound_method_body_is_accepted
    mixin = Module.new { def greet(name) = "hi, #{name}" }
    consumer = Class.new { include mixin }
    Candor.define(consumer, :greet, body: mixin.instance_method(:greet))

    assert_equal "hi, bob", consumer.new.greet("bob")
  end

  def test_a_call_object_body_is_refused
    callable = Object.new
    def callable.call(name) = name

    error = assert_raises(TypeError) { Candor.define(target, :greet, body: callable) }

    assert_match(/block, a Proc, a Method or an UnboundMethod with a source_location/, error.message)
    refute_includes target.instance_methods(false), :greet
  end

  def test_a_curried_proc_body_is_refused
    error = assert_raises(TypeError) { Candor.define(target, :greet, body: proc { |a, b| [a, b] }.curry) }

    assert_match(/source_location/, error.message)
  end

  def test_a_c_defined_method_body_is_refused
    error = assert_raises(TypeError) { Candor.define(target, :puts, body: method(:puts)) }

    assert_match(/curried procs, `#call` objects and C-defined methods have none/, error.message)
  end

  def test_a_missing_body_is_refused
    assert_raises(TypeError) { Candor.define(target, :greet) }
  end

  def test_a_non_module_target_is_refused
    assert_raises(TypeError) { Candor.define(Object.new, :greet) { :hi } }
  end

  # `define_method` would raise this itself — one step too late, with the prior wrapper already gone.
  def test_a_body_whose_owner_is_not_an_ancestor_is_refused_before_any_target_state_is_touched
    Candor.define(target, :greet) { :first }
    before = target.instance_methods(false) + target.private_instance_methods(false)

    assert_raises(TypeError) { Candor.define(target, :greet, body: String.instance_method(:upcase)) }

    assert_equal before, target.instance_methods(false) + target.private_instance_methods(false)
    assert_equal :first, target.new.greet
  end

  # Validation. Nothing below mutates the target.

  def test_a_frozen_target_gains_no_methods
    frozen = Class.new.freeze

    assert_raises(FrozenError) { Candor.define(frozen, :greet, aliases: %i[hello hi]) { :hi } }

    assert_empty frozen.instance_methods(false)
    assert_empty frozen.private_instance_methods(false)
  end

  def test_a_name_under_the_reserved_prefix_is_refused
    %i[greet hello].each do |canonical|
      assert_raises(ArgumentError) do
        Candor.define(target, canonical, aliases: [Candor.body_name(:x)]) { :hi }
      end
    end

    refute_includes target.instance_methods(false), :greet
  end

  def test_an_interceptor_name_that_is_not_a_callable_method_name_is_refused
    assert_raises(ArgumentError) { Candor.define(target, :greet, via: :"__call; puts 1") { :hi } }

    refute_includes target.instance_methods(false), :greet
  end

  # Without an interceptor the body's own name is the call site, so the canonical name has to be one.
  def test_a_canonical_name_that_cannot_be_called_is_refused_in_direct_forward_mode
    assert_raises(ArgumentError) { Candor.define(target, :"foo bar") { :hi } }
  end

  def test_a_canonical_name_that_cannot_be_called_survives_interceptor_mode
    Candor.define(target, :"foo bar", via: :__call) { :hi }

    assert_equal :hi, target.new.send(:"foo bar")
  end

  def test_a_malformed_parameter_override_is_refused_before_the_body_is_installed
    assert_raises(ArgumentError) { Candor.define(target, :greet, parameters: [[:wat]]) { :hi } }

    assert_empty target.private_instance_methods(false).grep(/\A#{Candor::BODY_PREFIX}/)
  end

  # `Signature.parameters!` reads one entry at a time, so a combination only Ruby's parser rejects reaches
  # `eval`. Compiling before the first mutation is what keeps a rejected re-fabrication from destroying the
  # method it was replacing.
  def test_a_parameter_override_only_the_parser_can_reject_leaves_a_prior_fabrication_intact
    Candor.define(target, :greet) { :first }
    before = target.instance_methods(false) + target.private_instance_methods(false)

    [[%i[rest a], %i[rest b]], [%i[key a], %i[key a]], [%i[block b], %i[req a]]].each do |shape|
      # A duplicate keyword warns as it parses; that is Ruby reading source written to be rejected.
      capture_io do
        assert_raises(ArgumentError, shape.inspect) do
          Candor.define(target, :greet, parameters: shape) { |*a, **k, &b| [a, k, b] }
        end
      end

      assert_equal :first, target.new.greet
      assert_equal before, target.instance_methods(false) + target.private_instance_methods(false)
    end
  end

  # Shape override (R9). The body is untouched; only what the wrapper advertises changes.

  def test_an_empty_parameter_override_rejects_every_argument
    Candor.define(target, :catalog, parameters: []) { |page = 1| page }

    assert_equal 0, target.instance_method(:catalog).arity
    assert_equal 1, target.new.catalog
    assert_raises(ArgumentError) { target.new.catalog(2) }
  end

  # Visibility and naming.

  def test_the_wrapper_is_public_and_the_body_is_private_under_the_reserved_prefix
    Candor.define(target, :greet) { :hi }

    assert_includes target.public_instance_methods(false), :greet
    assert_includes target.private_instance_methods(false), body_name
    assert_equal [body_name], target.private_instance_methods(false).grep(/\A#{Candor::BODY_PREFIX}/)
  end

  # Multiple names.

  def test_every_name_shares_one_dispatch_and_the_interceptor_sees_the_canonical_name
    Candor.define(target, :greet, aliases: %i[hello hi], via: :__call) { |name, greeting: "hi"| [greeting, name] }
    instance = target.new

    assert_equal %w[hi bob], instance.hello("bob")
    assert_equal %w[yo ann], instance.hi("ann", greeting: "yo")
    assert_equal [[:greet, ["bob"], {}], [:greet, ["ann"], { greeting: "yo" }]], instance.calls
    canonical = target.instance_method(:greet)
    %i[hello hi].each do |name|
      assert_equal canonical.parameters, target.instance_method(name).parameters
      assert_equal canonical.source_location, target.instance_method(name).source_location
    end
  end

  # Re-fabrication (R15).

  def test_re_fabricating_a_name_emits_no_warning_and_leaves_one_body_behind
    emitted = warnings do
      Candor.define(target, :greet) { :first }
      Candor.define(target, :greet) { :second }
    end

    assert_empty emitted
    assert_equal :second, target.new.greet
    assert_equal :second, target.new.send(body_name)
    assert_equal [body_name], target.private_instance_methods(false).grep(/\A#{Candor::BODY_PREFIX}/)
  end

  # Last-write-wins, documented: an alias from a prior fabrication is not tracked, so it keeps its own
  # dispatch — its original signature — while rebinding to the replacement body.
  def test_a_prior_alias_stays_installed_and_rebinds_to_the_replacement_body
    Candor.define(target, :greet, aliases: [:hello]) { |name, greeting = "yo"| [greeting, name] }
    Candor.define(target, :greet) { |name| [:new, name] }
    instance = target.new

    assert_equal [:new, "bob"], instance.greet("bob")
    assert_equal [:new, "bob"], instance.hello("bob")
    assert_equal(-2, target.instance_method(:hello).arity)
    assert_equal 1, target.instance_method(:greet).arity
    # The stale signature accepts an argument the replacement body cannot.
    assert_raises(ArgumentError) { instance.hello("bob", "hi") }
  end

  def test_replacing_a_hand_written_method_is_warning_free
    handwritten = Class.new { def greet = :hand }

    assert_empty(warnings { Candor.define(handwritten, :greet) { :fabricated } })
    assert_equal :fabricated, handwritten.new.greet
  end

  def test_an_inherited_method_is_shadowed_not_removed
    parent = Class.new { def greet = :parent }
    child = Class.new(parent)

    assert_empty(warnings { Candor.define(child, :greet) { :child } })
    assert_equal :child, child.new.greet
    assert_equal :parent, parent.new.greet
  end

  # Interceptor mode, end to end.

  def test_a_wrong_arity_call_never_reaches_the_interceptor
    rescuer = interceptor_that_rescues_everything
    Candor.define(rescuer, :greet, via: :__call) { |name, greeting = "hi"| "#{greeting}, #{name}" }
    instance = rescuer.new

    error = assert_raises(ArgumentError) { instance.greet }

    assert_equal "wrong number of arguments (given 0, expected 1..2)", error.message
    assert_nil instance.ran
  end

  def test_an_unknown_keyword_never_reaches_the_interceptor
    rescuer = interceptor_that_rescues_everything
    Candor.define(rescuer, :greet, via: :__call) { |name, greeting: "hi"| "#{greeting}, #{name}" }

    error = assert_raises(ArgumentError) { rescuer.new.greet("bob", grating: "yo") }

    assert_equal "unknown keyword: :grating", error.message
  end

  def test_an_unpassed_optional_is_dropped_from_what_the_interceptor_receives
    Candor.define(target, :greet, via: :__call) { |name, greeting = "hi"| "#{greeting}, #{name}" }
    instance = target.new

    assert_equal "hi, bob", instance.greet("bob")
    assert_equal [[:greet, ["bob"], {}]], instance.calls
  end

  # The memoizing shape: an interceptor that answers without ever running the body.
  def test_an_interceptor_may_decline_to_run_the_body
    memoizer = Class.new do
      private

      def __call(_name, *) = :cached
    end
    Candor.define(memoizer, :catalog, parameters: [], via: :__call) { raise "the body ran" }

    assert_equal :cached, memoizer.new.catalog
  end

  # Direct-forward mode, end to end.

  def test_without_an_interceptor_the_wrapper_returns_what_the_body_returns
    Candor.define(target, :greet) { |name, greeting = "hi", punct: "!"| "#{greeting}, #{name}#{punct}" }
    instance = target.new

    assert_equal "hi, bob!", instance.greet("bob")
    assert_equal "yo, bob?", instance.greet("bob", "yo", punct: "?")
    assert_empty instance.calls
  end

  private

  def interceptor_that_rescues_everything
    Class.new do
      attr_reader :ran

      private

      def __call(name, ...)
        @ran = true
        send(Candor.body_name(name), ...)
      rescue StandardError
        :rescued
      end
    end
  end
end
