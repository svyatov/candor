# frozen_string_literal: true

require "test_helper"

# `Signature` is a pure function of a compiled method's `parameters`, so these exercise it without the
# fabricator: compile the body, compile a dispatch lambda from its `parameters`, install, and call.
class SignatureTest < CandorTest
  # Stands in for a fabricated method's target. `install` picks the seam under test: with `via` the
  # dispatch reaches a private interceptor, without it the private body directly.
  class Harness
    attr_reader :seen

    def initialize(body) = singleton_class.send(:define_method, :__body, &body)

    def install(parameters, name = :x, via: :__call)
      dispatch = Candor::Signature.compile(
        parameters, name: via ? name : :__body, via: via, source_location: [FAKE_FILE, FAKE_LINE]
      )
      singleton_class.define_method(name, &dispatch)
      self
    end

    private

    def __call(name, ...)
      @seen = name
      __body(...)
    end
  end

  FAKE_FILE = "/nowhere/declared.rb"
  FAKE_LINE = 4200

  # The property this whole gem rests on: the dispatch method's kinds and arity are the body's.
  def test_every_shape_renders_to_the_bodys_kinds_and_arity
    SHAPES.each do |label, body|
      harness = Harness.new(body)
      body = body_method(harness)
      harness.install(body.parameters)
      dispatch = harness.method(:x)

      assert_equal body.parameters.map(&:first), dispatch.parameters.map(&:first), label
      assert_equal body.arity, dispatch.arity, label
    end
  end

  def test_every_shape_renders_to_the_bodys_kinds_and_arity_in_direct_forward_mode
    SHAPES.each do |label, body|
      harness = Harness.new(body)
      body = body_method(harness)
      harness.install(body.parameters, via: nil)
      dispatch = harness.method(:x)

      assert_equal body.parameters.map(&:first), dispatch.parameters.map(&:first), label
      assert_equal body.arity, dispatch.arity, label
    end
  end

  def test_every_shape_forges_the_declaring_locations
    SHAPES.each_value do |body|
      harness = Harness.new(body)
      harness.install(body_method(harness).parameters)

      assert_equal [FAKE_FILE, FAKE_LINE], harness.method(:x).source_location
    end
  end

  def test_the_table_covers_every_parameter_kind
    kinds = SHAPES.each_value.flat_map { |body| body_method(Harness.new(body)).parameters.map(&:first) }

    assert_empty(Candor::Signature::KINDS - kinds)
  end

  # The silent-failure case. A renderer keyed off names sees `[[:req]]` with no name, emits nothing,
  # and reports arity 0 — the body then raises inside the interceptor, where a handler can swallow it.
  #
  # Direct-forward, because Ruby 3.4 packs the arguments into an Array when an `it` body is reached
  # through `(name, ...)` forwarding, `send` or a splat — the harness's interceptor is all three. Fixed
  # in 4.0, and never a path the renderer emits: every generated call site names its arguments.
  def test_an_implicit_parameter_body_keeps_arity_one
    skip "`it` is an implicit parameter only from Ruby 3.4" unless IMPLICIT_PARAMETER

    harness = build(self.class.shape("proc { it * 2 }"), via: nil)

    assert_equal 1, harness.method(:x).arity
    assert_equal 8, harness.x(4)
    assert_raises(ArgumentError) { harness.x }
  end

  def test_an_unpassed_optional_reaches_the_body_as_the_bodys_own_default
    harness = build(proc { |s, width = 8| s.ljust(width) })

    assert_equal(-2, harness.method(:x).arity)
    assert_equal "x       ", harness.x("x")
    assert_equal "x  ", harness.x("x", 3)
  end

  def test_a_reserved_word_keyword_forwards_defaulted_and_passed
    harness = build(self.class.shape("proc { |end: 5| binding.local_variable_get(:end) }"))

    assert_equal 5, harness.x
    assert_equal 9, harness.x(end: 9)
  end

  # A lone optional dispatches through two call sites rather than an accumulator; the one that omits it
  # must still forward everything around it.
  def test_a_lone_optional_still_forwards_the_rest_around_it
    harness = build(proc { |a, b = 2, *r, &blk| [a, b, r, blk&.call] })

    assert_equal [1, 2, [], nil], harness.x(1)
    assert_equal [1, 9, [8, 7], :ran], harness.x(1, 9, 8, 7) { :ran }
  end

  # The multi-optional shapes below are the ones the shape table only ever *renders*. Rendering a branch
  # is not running it: every assertion in this file survived a mutation that dropped a forwarded kind
  # outright, until these called the generated source.
  def test_two_optional_positionals_chain_through_three_call_sites
    harness = build(proc { |a, b = 1, c = 2| [a, b, c] })

    assert_equal [1, 1, 2], harness.x(1)
    assert_equal [1, 9, 2], harness.x(1, 9)
    assert_equal [1, 9, 8], harness.x(1, 9, 8)
  end

  # Optional keywords are passed independently, so their call sites are a tree, not a chain.
  def test_two_optional_keywords_branch_through_four_call_sites
    harness = build(proc { |j: 1, k: 2| [j, k] })

    assert_equal [1, 2], harness.x
    assert_equal [1, 5], harness.x(k: 5)
    assert_equal [4, 1], harness.x(j: 4, k: 1)
    assert_equal [4, 5], harness.x(j: 4, k: 5)
  end

  # Past `KEYWORD_BRANCH_LIMIT` the keywords take the Hash while an optional positional still chains, so
  # both mechanisms run at once — and every other kind, a required positional, a rest, a required
  # keyword, a keyrest and a block, must survive both.
  def test_an_optional_on_each_side_survives_both_mechanisms
    harness = build(proc { |a, b = 1, *r, k:, c: 2, d: 3, e: 4, **kw, &blk| [a, b, r, k, c, d, e, kw, blk&.call] })

    assert_equal [1, 1, [], :req, 2, 3, 4, {}, nil], harness.x(1, k: :req)
    assert_equal [1, 9, [8, 7], :req, 5, 4, 3, { z: 1 }, :ran],
                 harness.x(1, 9, 8, 7, k: :req, c: 5, d: 4, e: 3, z: 1) { :ran }
  end

  # An unpassed optional positional guarantees the ones after it went unpassed too, and a few optional
  # keywords enumerate. So neither allocates: dispatch is call sites, not containers.
  def test_optionals_dispatch_without_allocating_until_the_keyword_branch_limit
    keys = Array.new(4) { |i| [:key, :"k#{i}"] }
    chained = Candor::Signature.render([%i[req a], %i[opt b], %i[opt c], *keys.first(2)], name: :x, via: :__call)
    hashed = Candor::Signature.render(keys.first(3), name: :x, via: :__call)

    refute_match(/= \{\}|= \[\]/, chained)
    assert_match(/= \{\}/, hashed)
  end

  # `**` capture already allocated a Hash the lambda owns, so the hashed path adopts it rather than building
  # a second one and merging. Ruby routes a declared keyword to its own parameter, never into the keyrest.
  def test_a_keyrest_is_the_hash_the_keyword_branch_accumulates_into
    keys = Array.new(3) { |i| [:key, :"k#{i}"] }
    hashed = Candor::Signature.render([*keys, %i[keyrest kw]], name: :x, via: :__call)

    assert_match(/__k = __kr3/, hashed)
    refute_match(/= \{\}/, hashed)
    refute_match(/\.update\(/, hashed)
  end

  def test_an_unpassed_optional_keyword_reaches_the_body_as_its_own_default
    harness = build(proc { |k: 7, **kw| [k, kw] })

    assert_equal [7, {}], harness.x
    assert_equal [1, { z: 2 }], harness.x(k: 1, z: 2)
  end

  def test_a_destructuring_body_forwards_the_whole_argument
    harness = build(proc { |a, (b, c)| [a, b, c] })

    assert_equal 2, harness.method(:x).arity
    assert_equal [1, 2, 3], harness.x(1, [2, 3])
  end

  def test_a_block_reaches_a_body_declaring_one
    harness = build(proc { |&blk| blk.call })

    assert_equal(:called, harness.x { :called })
  end

  def test_a_nokey_body_rejects_keywords
    harness = build(self.class.shape("proc { |a, **nil| a }"))

    assert_equal 1, harness.x(1)
    assert_raises(ArgumentError) { harness.x(1, k: 2) }
  end

  def test_a_wrong_arity_call_raises_rubys_own_message_at_the_lambda
    harness = build(proc { |name, greeting = "hi"| [name, greeting] })

    error = assert_raises(ArgumentError) { harness.x }

    assert_equal "wrong number of arguments (given 0, expected 1..2)", error.message
    assert_nil harness.seen
  end

  def test_an_unknown_keyword_raises_rubys_own_message_at_the_lambda
    harness = build(proc { |name, greeting: "hi"| [name, greeting] })

    error = assert_raises(ArgumentError) { harness.x("bob", grating: "yo") }

    assert_equal "unknown keyword: :grating", error.message
    assert_nil harness.seen
  end

  def test_the_interceptor_receives_the_canonical_name_as_a_literal
    harness = build(proc { |a| a })

    assert_equal 1, harness.x(1)
    assert_equal :x, harness.seen
  end

  # The sentinel marking an unpassed optional must be nameless. A constant would not be: `const_get`
  # pierces `private_constant`, so a caller could obtain it and pass it, silently taking the body's
  # default instead of the argument they wrote.

  def test_the_unset_sentinel_is_a_local_the_rendered_source_creates
    source = Candor::Signature.render([%i[opt a]], name: :__body)

    assert_match(/\A__u = ::Object\.new\.freeze; /, source)
  end

  def test_an_object_a_caller_can_name_never_stands_in_for_the_sentinel
    harness = build(proc { |a, b = :default| [a, b] })
    probe = ::Object.new.freeze

    assert_equal [1, probe], harness.x(1, probe)
  end

  # Only keyword names are interpolated, and Ruby's parser guarantees those are identifiers or
  # reserved words. Nothing else from the input may reach the generated source.
  def test_rendering_never_interpolates_a_positional_rest_keyrest_or_block_name
    source = Candor::Signature.render(
      [[:req, :"a; puts 1"], [:opt, :"b; puts 2"], [:rest, :"r; puts 3"],
       [:keyrest, :"kw; puts 4"], [:block, :"blk; puts 5"]], name: :x, via: :__call
    )

    refute_match(/puts/, source)
  end

  def test_a_required_keyword_is_interpolated_by_name
    assert_includes Candor::Signature.render([%i[keyreq token]], name: :x, via: :__call), "token:"
  end

  # A keyword name is the one piece of user input the source carries verbatim, so it can be spelled
  # like anything the source relies on. Shadowing is silent: the value is wrong, not missing.

  def test_a_keyword_named_like_a_generated_local_is_defaulted_and_passed
    harness = build(self.class.shape("proc { |__u: 1, __a: 2, __k: 3, __name: 4| [__u, __a, __k, __name] }"))

    assert_equal [1, 2, 3, 4], harness.x
    assert_equal [9, 8, 7, 6], harness.x(__u: 9, __a: 8, __k: 7, __name: 6)
  end

  # The generated name of a positional is its index, which a keyword can spell exactly.
  def test_a_keyword_cannot_capture_a_generated_positional
    harness = build(self.class.shape("proc { |a, __p0: 1| [a, __p0] }"))

    assert_equal [7, 1], harness.x(7)
    assert_equal [7, 2], harness.x(7, __p0: 2)
  end

  # `binding` is how a reserved-word keyword is read at all, and a keyword named `binding` is a local
  # that shadows the method. The source calls `binding()`, which a local cannot shadow.
  def test_a_keyword_named_binding_does_not_shadow_the_reserved_word_lookup
    harness = build(self.class.shape("proc { |binding: 1, end: 2| [binding, binding().local_variable_get(:end)] }"))

    assert_equal [1, 2], harness.x
    assert_equal [9, 8], harness.x(binding: 9, end: 8)
  end

  # The forward target is a name too, and a keyword may be spelled like it. The call site carries
  # parentheses, which a local cannot shadow.
  def test_a_keyword_named_like_the_interceptor_cannot_shadow_the_call_site
    harness = build(self.class.shape("proc { |__call: 1| __call }"))

    assert_equal 1, harness.x
    assert_equal 2, harness.x(__call: 2)
  end

  def test_a_keyword_named_like_the_body_cannot_shadow_a_direct_call_site
    harness = build(self.class.shape("proc { |__body: 1| __body }"), via: nil)

    assert_equal 1, harness.x
    assert_equal 2, harness.x(__body: 2)
  end

  # Direct-forward mode: the body is the call site, and no canonical name rides along.

  def test_direct_forward_renders_the_body_name_and_no_canonical_literal
    source = Candor::Signature.render([%i[req a]], name: :__body)

    assert_includes source, "__body(__p0)"
    refute_includes source, ":__body"
  end

  def test_direct_forward_renders_a_parenthesised_call_for_a_bodyless_shape
    assert_includes Candor::Signature.render([], name: :__body), "{ __body() }"
  end

  def test_direct_forward_returns_what_the_body_returns_defaults_included
    body = proc { |name, greeting = "hi", punct: "!"| "#{greeting}, #{name}#{punct}" }
    harness = build(body, via: nil)

    assert_equal "hi, bob!", harness.x("bob")
    assert_equal "yo, bob?", harness.x("bob", "yo", punct: "?")
    assert_nil harness.seen
  end

  # Both call-site names are consumer input interpolated into `eval`'d source. They are gated, not
  # trusted, and the gate runs before anything is rendered.

  def test_a_call_site_name_that_is_not_a_callable_method_name_raises
    [:"foo bar", :end, :+, :"1a", :"", :"a-b", :"a\nb", :"puts 1; x"].each do |name|
      assert_raises(ArgumentError, name.inspect) { Candor::Signature.render([], name: name) }
      assert_raises(ArgumentError, name.inspect) { Candor::Signature.render([], name: :x, via: name) }
    end
  end

  def test_a_call_site_name_may_end_in_a_question_or_bang
    assert_includes Candor::Signature.render([], name: :x, via: :call!), "call!(:x)"
    assert_includes Candor::Signature.render([], name: :ok?), "ok?()"
  end

  # With an interceptor the canonical name is a Symbol literal, so it need not be callable itself.
  def test_a_canonical_name_that_is_not_an_identifier_survives_as_a_literal
    source = Candor::Signature.render([], name: :"foo bar", via: :__call)

    assert_includes source, '__call(:"foo bar")'
  end

  # A consumer's `parameters:` override never passed Ruby's parser, so `render` is where a malformed
  # shape becomes an `ArgumentError` instead of a `SyntaxError` from inside `eval`.

  def test_a_malformed_parameter_shape_raises_before_rendering
    [nil, :nope, [[:wat]], [[:req, "a"]], [:req], [[]], [%i[req a b]], [[:key]], [[:keyreq, "a"]]].each do |shape|
      assert_raises(ArgumentError, shape.inspect) { Candor::Signature.render(shape, name: :x, via: :__call) }
    end
  end

  # Every entry above is illegal on its own. These are entries Ruby's parser would each accept, in a
  # combination it will not — which only `eval` can discover, and `compile` must not let escape as the
  # `ScriptError` a consumer's `rescue` misses.
  def test_a_shape_that_only_the_parser_can_reject_raises_an_argument_error_from_compile
    combinations = [
      [%i[rest a], %i[rest b]], [%i[key a], %i[key a]], [%i[block b], %i[req a]],
      [%i[keyrest kw], [:nokey]], [%i[block a], %i[block b]], [%i[keyreq k], %i[req a]]
    ]

    combinations.each do |shape|
      error = nil
      # A duplicate keyword warns as it parses, before it raises. That warning is Ruby reading source written
      # to be rejected, not the renderer misbehaving, so it stays out of the suite's `-w` output.
      capture_io do
        error = assert_raises(ArgumentError, shape.inspect) do
          Candor::Signature.compile(shape, name: :x, via: :__call, source_location: [FAKE_FILE, FAKE_LINE])
        end
      end

      assert_match(/malformed parameters/, error.message)
    end
  end

  # With `via`, the canonical name is not gated by `method_name!` — nothing calls it, so anything a
  # Symbol can hold is legal. It reaches the source as `#{name.inspect}`, and that literal is the second
  # thing `eval` sees the caller's input in. Every Symbol inspects to a literal that parses back to
  # itself, so a name carrying a quote, a newline, a NUL, a backslash or `#{}` closes nothing.
  def test_a_hostile_canonical_name_reaches_the_interceptor_intact
    hostile = [
      :'a"; raise("escaped"); "', :"a\nraise('escaped')\n", :"\#{raise(\"escaped\")}", :"\\", :'a\\";',
      :"a\x00b", :"", :+, :[]=, :"foo bar", :"\e[31m", :日本語
    ]
    receiver = Class.new { def __call(name) = name }.new

    hostile.each do |name|
      dispatch = Candor::Signature.compile([], name: name, via: :__call, source_location: [FAKE_FILE, FAKE_LINE])

      assert_same name, receiver.instance_exec(&dispatch), name.inspect
    end
  end

  # `method_name!` and `parameters!` are public: a consumer installing dispatch itself gates the same two
  # trust boundaries. Each rejection names which one, and which entry.

  # `:class` *is* callable — on a receiver. The generated source calls the site bare, and a bare
  # `class(...)` is a `SyntaxError`, so "not a callable method name" would be the wrong reason.
  def test_a_reserved_word_is_refused_as_a_call_site_for_the_reason_it_is
    error = assert_raises(ArgumentError) { Candor::Signature.method_name!(:class) }

    assert_match(/reserved word/, error.message)
    assert_equal :klass, Candor::Signature.method_name!(:klass)
  end

  def test_a_name_the_generated_source_cannot_call_is_refused
    [:"a b", :"a; puts 1", :+, :"", :"1a"].each do |name|
      error = assert_raises(ArgumentError, name.inspect) { Candor::Signature.method_name!(name) }

      assert_match(/not a callable method name/, error.message)
    end
  end

  def test_a_malformed_entry_is_named_by_its_index
    error = assert_raises(ArgumentError) { Candor::Signature.parameters!([%i[req a], [:wat], %i[opt b]]) }

    assert_match(/entry 1 is \[:wat\]/, error.message)
  end

  def test_a_parameters_shape_that_is_not_an_array_is_refused
    error = assert_raises(ArgumentError) { Candor::Signature.parameters!(:nope) }

    assert_match(/malformed parameters: :nope/, error.message)
  end

  # The keyword names are interpolated verbatim, so a hand-written shape could otherwise inject source.
  def test_a_keyword_name_that_is_not_an_identifier_raises_before_rendering
    [:"a; puts 1", :"a-b", :"", :_1, :"end:"].each do |name|
      assert_raises(ArgumentError, name.inspect) do
        Candor::Signature.render([[:key, name]], name: :x, via: :__call)
      end
    end
  end

  def test_a_nameless_positional_rest_keyrest_or_block_entry_is_accepted
    source = Candor::Signature.render([[:req], [:rest], [:keyrest], [:block]], name: :x, via: :__call)

    assert_includes source, "__call(:x, __p0, *__r1, **__kr2, &__b3)"
  end

  private

  def body_method(harness) = harness.singleton_class.instance_method(:__body)

  def build(body, via: :__call)
    harness = Harness.new(body)
    harness.install(body_method(harness).parameters, via: via)
  end
end
