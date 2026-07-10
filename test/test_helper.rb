# frozen_string_literal: true

if ENV["COVERAGE"]
  require "simplecov"

  if ENV["CI"]
    require "simplecov_json_formatter"
    SimpleCov.formatter = SimpleCov::Formatter::JSONFormatter
  end

  SimpleCov.start do
    add_filter "/test/"
    minimum_coverage 100
  end
end

require "minitest/autorun"

require "candor"

class CandorTest < Minitest::Test
  # @param minimum [String]
  # @return [Boolean]
  def self.ruby?(minimum) = Gem::Version.new(RUBY_VERSION) >= Gem::Version.new(minimum)

  # `{ it }` and the anonymous parameters are newer than the oldest Ruby this gem supports. A shape the
  # running parser rejects cannot reach the renderer either, so drop it rather than branch the renderer.
  # `eval` is the only way to write one without a `SyntaxError` on an older parser; every `source` passed
  # here is a literal in this repo's own test files, never input.
  #
  # @return [Proc, nil]
  def self.shape(source)
    eval(source, binding, __FILE__, __LINE__) # rubocop:disable Security/Eval
  rescue SyntaxError
    nil
  end

  # Every kind `Method#parameters` can emit, one body each. The table is the spec, and
  # SignatureTest#test_the_table_covers_every_parameter_kind is what keeps it one. ReflectionTest slices
  # the hostile rows out of it rather than restating them, so the two cannot drift apart.
  SHAPES = {
    "no parameters" => proc { :ok },
    "|a, b|" => proc { |a, b| [a, b] },
    "|a, b = 2|" => proc { |a, b = 2| [a, b] },
    "|a = 1, b|" => proc { |a = 1, b| [a, b] },
    "|a, *r|" => proc { |a, *r| [a, r] },
    "|a, *r, z|" => proc { |a, *r, z| [a, r, z] },
    "|a, b = 2, *r|" => proc { |a, b = 2, *r| [a, b, r] },
    "|a, *|" => shape("proc { |a, *| a }"),
    "|a, **|" => shape("proc { |a, **| a }"),
    "|a, &|" => shape("proc { |a, &| a }"),
    "|k:|" => proc { |k:| k },
    "|k: 7|" => proc { |k: 7| k },
    "|**kw|" => proc { |**kw| kw },
    "|&b|" => proc { |&b| b },
    "|a, **nil|" => shape("proc { |a, **nil| a }"),
    "|a, (b, c)|" => proc { |a, (b, c)| [a, b, c] },
    "{ it }" => shape("proc { it }"),
    "{ _1 }" => shape("proc { _1 }"),
    "|end: 5|" => shape("proc { |end: 5| binding.local_variable_get(:end) }"),
    "|a, b = 2, *r, k:, j: 8, **kw, &blk|" => proc { |a, b = 2, *r, k:, j: 8, **kw, &blk| [a, b, r, k, j, kw, blk] }
  }.compact.freeze

  # `it` names the first block parameter only from Ruby 3.4; before that it parses as a method call.
  IMPLICIT_PARAMETER = ruby?("3.4")

  # Two allocation costs Ruby charges a `define_method`-created method, neither reachable from the gem
  # and both gone by 3.4. The wrapper and the body are both such methods, so a keyword-carrying call
  # crosses two hops.
  #
  # Passing keywords into one allocates a Hash before 3.3; splatting a `**hash` into one allocates
  # another before 3.4. Below the keyword branch limit the generated call site names its keywords, so it
  # pays the first and not the second; above it, the reverse.
  KEYWORD_HOP = ruby?("3.3") ? 0 : 1
  SPLAT_HOP = ruby?("3.4") ? 0 : 1

  # Method redefinition is warned by the VM, not by `Kernel#warn`, but both reach `$stderr`.
  def warnings(&)
    verbose = $VERBOSE
    $VERBOSE = true
    _out, err = capture_io(&)
    err.lines.grep(/warning/)
  ensure
    $VERBOSE = verbose
  end

  # A cold call site allocates the caches a warm one reuses, and a dispatch branch is only warm once it
  # has run — twice, in practice. Every measurement below is of a warm branch.
  WARMUP = 3

  # Exact allocation counts, not upper bounds: GC is off, so nothing is reclaimed mid-measurement.
  # {#measure} is discarded once first because its *own* first execution allocates a cache too.
  def allocations(&)
    WARMUP.times(&)
    measure(&)
    measure(&)
  end

  private

  # @return [Integer] objects allocated by one call of the block
  def measure
    GC.start
    GC.disable
    before = GC.stat(:total_allocated_objects)
    yield
    GC.stat(:total_allocated_objects) - before
  ensure
    GC.enable
  end
end
