# frozen_string_literal: true

require "test_helper"

# The "real methods" thesis, under the reflection APIs a developer reaches for after the first hour.
# `Candor.define` must hand back the body's own arity, `parameters` kinds and `source_location` —
# for every shape Ruby can express, including the ones whose reported names are unusable.
class ReflectionTest < CandorTest
  # Bodies whose shapes a name-echoing renderer cannot survive: a reserved word, an implicit parameter,
  # a numbered parameter, a destructuring parameter, and a keyword-refusing body. Sliced out of {SHAPES}
  # rather than restated, so an edit to one of these bodies cannot leave the two tables disagreeing.
  # `SHAPES` already dropped whatever the running parser rejects, so a slice of it drops the same rows.
  HOSTILE = SHAPES.slice(
    "|end: 5|", "{ it }", "{ _1 }", "|a, (b, c)|", "|a, **nil|", "|a, *|", "|a, **|", "|a, &|"
  ).freeze

  def target = @target ||= Class.new

  def test_a_fixed_arity_body_reports_its_kinds_and_arity
    Candor.define(target, :add) { |a, b| a + b }

    assert_equal(%i[req req], target.instance_method(:add).parameters.map(&:first))
    assert_equal 2, target.instance_method(:add).arity
  end

  def test_an_optional_body_reports_its_kinds_and_arity
    Candor.define(target, :pad) { |s, width = 8| s.ljust(width) }

    assert_equal(%i[req opt], target.instance_method(:pad).parameters.map(&:first))
    assert_equal(-2, target.instance_method(:pad).arity)
    assert_equal "x       ", target.new.pad("x")
  end

  def test_a_keyword_body_reports_its_kinds_and_arity_and_keeps_the_keyword_name
    Candor.define(target, :fetch) { |key, ttl: 60| [key, ttl] }
    parameters = target.instance_method(:fetch).parameters

    assert_equal(%i[req key], parameters.map(&:first))
    assert_equal(-2, target.instance_method(:fetch).arity)
    assert_equal :ttl, parameters.last.last
    assert_equal [:a, 5], target.new.fetch(:a, ttl: 5)
  end

  def test_a_block_taking_body_reports_its_kinds_and_arity
    Candor.define(target, :around) { |&blk| blk.call }

    assert_equal([:block], target.instance_method(:around).parameters.map(&:first))
    assert_equal 0, target.instance_method(:around).arity
    assert_equal(:ran, target.new.around { :ran })
  end

  # AE5: every hostile shape wraps at full fidelity. There is no degraded fallback path to fall into.
  def test_every_hostile_shape_reports_the_bodys_kinds_and_arity
    HOSTILE.each do |label, body|
      klass = Class.new
      Candor.define(klass, :x, body: body)
      compiled = klass.instance_method(Candor.body_name(:x))
      wrapper = klass.instance_method(:x)

      assert_equal compiled.parameters.map(&:first), wrapper.parameters.map(&:first), label
      assert_equal compiled.arity, wrapper.arity, label
    end
  end

  def test_a_reserved_word_keyword_keeps_its_name_and_its_default
    Candor.define(target, :slice, body: self.class.shape("proc { |end: 5| binding.local_variable_get(:end) }"))

    assert_equal [%i[key end]], target.instance_method(:slice).parameters
    assert_equal 5, target.new.slice
    assert_equal 9, target.new.slice(end: 9)
  end

  # `it` parses as a method call before 3.4 — a body Ruby accepts and gives zero parameters, not a
  # `SyntaxError` the shape table can drop.
  def test_an_implicit_parameter_body_keeps_arity_one
    skip "`it` is an implicit parameter only from Ruby 3.4" unless IMPLICIT_PARAMETER

    Candor.define(target, :double, body: self.class.shape("proc { it * 2 }"))

    assert_equal 1, target.instance_method(:double).arity
    assert_equal 8, target.new.double(4)
    assert_raises(ArgumentError) { target.new.double }
  end

  def test_a_nokey_body_still_rejects_keywords
    Candor.define(target, :strict, body: self.class.shape("proc { |a, **nil| a }"))

    assert_equal 1, target.new.strict(1)
    assert_raises(ArgumentError) { target.new.strict(1, k: 2) }
  end

  def test_source_location_points_at_the_declaring_block
    line = __LINE__ + 1
    Candor.define(target, :redis) { :pool }

    assert_equal [__FILE__, line], target.instance_method(:redis).source_location
  end

  def test_no_fabricated_method_reports_a_location_inside_the_gem
    Candor.define(target, :redis, aliases: [:pool]) { :pool }
    locations = %i[redis pool].map { |name| target.instance_method(name).source_location.first }

    assert_equal [__FILE__] * 2, locations
  end

  def test_aliases_report_what_their_canonical_reports
    Candor.define(target, :configuration, aliases: %i[config c], via: :__call) { |scope| scope }
    canonical = target.instance_method(:configuration)

    %i[config c].each do |name|
      assert_equal canonical.parameters, target.instance_method(name).parameters
      assert_equal canonical.arity, target.instance_method(name).arity
      assert_equal canonical.source_location, target.instance_method(name).source_location
    end
  end

  # A shape override is the one place reflection deliberately departs from the body (R9).
  def test_a_parameter_override_is_what_the_wrapper_advertises
    Candor.define(target, :catalog, parameters: []) { |page = 1| page }

    assert_empty target.instance_method(:catalog).parameters
    assert_equal 0, target.instance_method(:catalog).arity
  end

  # The compiled body is what the shape is read from: a Proc reports every positional as `:opt`, so a
  # renderer fed `body.parameters` would advertise an all-optional signature and lose arity strictness.
  def test_the_shape_is_read_from_the_compiled_body_not_from_the_proc
    body = proc { |a, b| [a, b] }

    assert_equal(%i[opt opt], body.parameters.map(&:first))

    Candor.define(target, :pair, body: body)

    assert_equal(%i[req req], target.instance_method(:pair).parameters.map(&:first))
  end
end
