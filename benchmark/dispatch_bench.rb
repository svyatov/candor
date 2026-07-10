# frozen_string_literal: true

# rubocop:disable Style/GlobalVars

# Call-time overhead is the north star: a fabricated wrapper should cost about what a hand-written
# method costs, and less than the `|*args, **kwargs, &block|` wrapper every other gem retreats to.
#
#   bundle exec rake bench
#
# The call sites are compiled source, not blocks passed around: a `Proc#call` in the measuring harness
# would cost more than the difference being measured. `benchmark-ips` takes the source directly, and it
# reaches the subject through a global — the one name an `eval`'d method body can still see.
#
# The definition-time benchmark at the end grounds the deferred shape-cache decision: one `eval` per
# fabricated method is the accepted price, and this says how much it is.

require "benchmark/ips"

require_relative "../lib/candor"

# Each shape carries a body, a call site, and two hand-written controls.
#
# `method` is a bare `def` doing the work inline — the floor, one call where every wrapper is two. It is
# there to price wrapping at all, not to price candor.
#
# `wrapper` is the real `def` a developer would write *if they knew both the shape and the defaults* —
# same signature, same private body, no branch, because the defaults are hard-coded. That is the ceiling
# candor is measured against: it cannot know a default expression (Feature #8629), so it drops an
# unpassed optional through a chain of call sites instead.
SHAPES = {
  "no arguments" => {
    body: proc { :ok },
    call: "run",
    method: "def run = :ok",
    wrapper: "def run = __body()"
  },
  "required + optional, omitted" => {
    body: proc { |a, b = 2| a & b },
    call: "run(1)",
    method: "def run(a, b = 2) = a & b",
    wrapper: "def run(a, b = 2) = __body(a, b)"
  },
  "required + optional, passed" => {
    body: proc { |a, b = 2| a & b },
    call: "run(1, 9)",
    method: "def run(a, b = 2) = a & b",
    wrapper: "def run(a, b = 2) = __body(a, b)"
  },
  "two optional keywords" => {
    body: proc { |k0: 1, k1: 2| k0 & k1 },
    call: "run(k0: 9)",
    method: "def run(k0: 1, k1: 2) = k0 & k1",
    wrapper: "def run(k0: 1, k1: 2) = __body(k0: k0, k1: k1)"
  },
  "three optional keywords, past the branch limit" => {
    body: proc { |k0: 1, k1: 2, k2: 3| k0 & k1 & k2 },
    call: "run(k0: 9)",
    method: "def run(k0: 1, k1: 2, k2: 3) = k0 & k1 & k2",
    wrapper: "def run(k0: 1, k1: 2, k2: 3) = __body(k0: k0, k1: k1, k2: k2)"
  }
}.freeze

def fabricated(body)
  klass = Class.new
  Candor.define(klass, :run, body: body)
  klass.new
end

# The retreat every gem makes when it cannot generate the signature: honest results, dishonest
# reflection — arity -1, `parameters` reporting `[[:rest], [:keyrest], [:block]]` — and an Array plus a
# Hash allocated on every call.
def variadic(body)
  wrapping(body) { |klass| klass.define_method(:run) { |*args, **kwargs, &block| __body(*args, **kwargs, &block) } }
end

def handwritten_wrapper(body, source)
  wrapping(body) { |klass| klass.class_eval(source, __FILE__, __LINE__) }
end

def wrapping(body)
  klass = Class.new
  klass.define_method(:__body, body)
  klass.send(:private, :__body)
  yield klass
  klass.new
end

def handwritten(source)
  klass = Class.new
  klass.class_eval(source, __FILE__, __LINE__)
  klass.new
end

# Exact, not an upper bound: GC is off, the branch is warm, and the harness itself is measured once and
# discarded, because its own first execution allocates a cache too.
def allocations(probe, subject)
  3.times { probe.call(subject) }
  measure(probe, subject)
  measure(probe, subject)
end

def measure(probe, subject)
  GC.start
  GC.disable
  before = GC.stat(:total_allocated_objects)
  probe.call(subject)
  GC.stat(:total_allocated_objects) - before
ensure
  GC.enable
end

puts RUBY_DESCRIPTION, "candor #{Candor::VERSION}", ""

SHAPES.each do |label, shape|
  # `benchmark-ips` compiles the call site into a method of its own, where a local is out of scope.
  $candor = fabricated(shape[:body])
  $wrapper = handwritten_wrapper(shape[:body], shape[:wrapper])
  $method = handwritten(shape[:method])
  $variadic = variadic(shape[:body])
  subjects = { "candor" => $candor, "hand-written wrapper" => $wrapper,
               "hand-written method" => $method, "variadic wrapper" => $variadic }
  probe = eval("->(subject) { subject.#{shape[:call]} }", binding, __FILE__, __LINE__) # rubocop:disable Security/Eval

  puts "== #{label} — allocations per call"
  subjects.each do |name, subject|
    puts format("  %-22<name>s %<count>d", name: name, count: allocations(probe, subject))
  end
  puts

  puts "== #{label} — calls per second"
  Benchmark.ips do |x|
    x.report("candor", "$candor.#{shape[:call]}")
    x.report("hand-written wrapper", "$wrapper.#{shape[:call]}")
    x.report("hand-written method", "$method.#{shape[:call]}")
    x.report("variadic wrapper", "$variadic.#{shape[:call]}")
    x.compare!
  end
end

puts "== definition time — one eval per fabricated method"
Benchmark.ips do |x|
  x.report("Candor.define") { Candor.define(Class.new, :run) { |a, b = 1, k: 2| [a, b, k] } }
  x.report("bare define_method") { Class.new.define_method(:run) { |a, b = 1, k: 2| [a, b, k] } }
  x.compare!
end

# rubocop:enable Style/GlobalVars
