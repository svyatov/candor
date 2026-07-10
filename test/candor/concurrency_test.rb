# frozen_string_literal: true

require "test_helper"
require "timeout"

# The two claims the README leads with: fabrication is thread-safe, and dispatch allocates nothing
# below the keyword branch limit.
class ConcurrencyTest < CandorTest
  THREADS = 16

  # Built in `setup`, not memoized on first read: `@target ||= Class.new` inside `race` is itself a race,
  # and the losing threads fabricate onto a class nothing else can see.
  def setup = @target = Class.new

  attr_reader :target

  # Fabrication (R14). Definition-time only: the dispatch it installs takes no lock at all.

  def test_distinct_names_fabricated_concurrently_all_land_with_honest_signatures
    race { |i| Candor.define(target, :"m#{i}") { |a, b = 1| [i, a, b] } }
    instance = target.new

    THREADS.times do |i|
      assert_equal(-2, target.instance_method(:"m#{i}").arity)
      assert_equal [i, :a, 1], instance.send(:"m#{i}", :a)
    end
  end

  def test_one_name_re_fabricated_concurrently_warns_nothing_and_orphans_no_body
    emitted = warnings { race { |i| Candor.define(target, :greet) { i } } }

    assert_empty emitted
    assert_equal [Candor.body_name(:greet)],
                 target.private_instance_methods(false).grep(/\A#{Candor::BODY_PREFIX}/)
    # Last write wins, and the surviving wrapper and body are the same fabrication's.
    winner = target.new.greet

    assert_includes 0...THREADS, winner
    assert_equal winner, target.new.send(Candor.body_name(:greet))
  end

  # Reinstalling a name by removing it first leaves it undefined until the install lands — and the
  # install renders and `eval`s, so the hole is the whole ~40 µs. Dispatch holds no lock, so a caller
  # racing a re-fabrication sees `NoMethodError` for as long as the writer stays descheduled.
  #
  # Racing for it would only prove the scheduler's mood: MRI preempts on a 100 ms timer, so a loop short
  # enough for a test never yields inside the window and every run passes, bug or no bug. The mechanism
  # is what to assert. `define_method` replaces a method in place, so nothing is ever removed, so there
  # is no window to be caught in.
  def test_re_fabrication_never_removes_the_method_it_replaces
    removed = []
    target.define_singleton_method(:method_removed) { |name| removed << name }

    Candor.define(target, :greet, aliases: [:hi]) { :first }
    Candor.define(target, :greet, aliases: [:hi]) { :second }

    assert_empty removed
    assert_equal :second, target.new.greet
    assert_equal :second, target.new.hi
  end

  # If dispatch took the fabrication lock, the second thread could not enter the body while the first
  # is still inside it, and this would hang rather than fail.
  def test_call_time_dispatch_takes_no_lock
    entered = Thread::Queue.new
    gate = Thread::Queue.new
    Candor.define(target, :block_here) do
      entered << :in
      gate.pop
    end
    instance = target.new

    results = Timeout.timeout(10) do
      threads = Array.new(2) { Thread.new { instance.block_here } }
      2.times { entered.pop }
      2.times { gate << :go }
      threads.map(&:value)
    end

    assert_equal %i[go go], results
  end

  def test_concurrent_calls_to_one_fabricated_method_with_optionals_are_correct
    Candor.define(target, :pad) { |s, width = 8| s.ljust(width) }
    instance = target.new

    results = race { |i| i.even? ? instance.pad("x") : instance.pad("x", 3) }

    assert_equal ["x  ", "x       "], results.uniq.sort
  end

  # Allocation (R12, AE11). Direct-forward only: an interceptor's own `(name, ...)` forwarding allocates
  # one object per argument-carrying call, which is outside the wrapper-scoped guarantee.
  #
  # The counts are exact, and the `HOP` terms are Ruby's, not the renderer's: a `define_method`-created
  # method — which both the wrapper and the body are — charged a Hash for incoming keywords before 3.3
  # and another for an incoming `**hash` before 3.4. Both are zero from 3.4 on, where the guarantee reads
  # as written: nothing below the branch limit, exactly one Hash above.

  def test_dispatch_allocates_nothing_at_or_below_the_keyword_branch_limit
    Candor.define(target, :two) { |k0: 1, k1: 2| k0 & k1 }
    Candor.define(target, :positional) { |_a, b = 1| b }
    instance = target.new

    # No keyword crosses either hop: both are dropped, and the body applies its own defaults.
    assert_equal(0, allocations { instance.two })
    assert_equal(2 * KEYWORD_HOP, allocations { instance.two(k0: 9) })
    assert_equal(2 * KEYWORD_HOP, allocations { instance.two(k0: 9, k1: 8) })
    assert_equal(0, allocations { instance.positional(:a) })
    assert_equal(0, allocations { instance.positional(:a, :b) })
  end

  # The one object is the Hash the render sets up — `__k = {}`, pinned as the *only* container by
  # SignatureTest#test_optionals_dispatch_without_allocating_until_the_keyword_branch_limit.
  def test_dispatch_above_the_keyword_branch_limit_allocates_exactly_one_hash
    Candor.define(target, :three) { |k0: 1, k1: 2, k2: 3| k0 & k1 & k2 }
    instance = target.new

    assert_equal(1 + SPLAT_HOP, allocations { instance.three })
    assert_equal(1 + SPLAT_HOP + KEYWORD_HOP, allocations { instance.three(k1: 9) })
    assert_equal(1 + SPLAT_HOP + KEYWORD_HOP, allocations { instance.three(k0: 9, k1: 8, k2: 7) })
  end

  # A body declaring a keyrest costs Ruby one Hash to capture it and one to re-splat it into the body — on any
  # wrapper, hand-written or generated. The renderer adds none of its own: the keyrest *is* the Hash the
  # keyword branch accumulates into, pinned by
  # SignatureTest#test_a_keyrest_is_the_hash_the_keyword_branch_accumulates_into.
  def test_a_keyrest_above_the_branch_limit_adds_no_hash_of_the_renderers_own
    skip "the exact count holds from Ruby 3.4" unless self.class.ruby?("3.4")
    Candor.define(target, :three_rest) { |k0: 1, k1: 2, k2: 3, **kw| k0 & k1 & k2 & kw.size }
    instance = target.new

    assert_equal(2, allocations { instance.three_rest })
    assert_equal(2, allocations { instance.three_rest(k1: 9) })
    assert_equal(2, allocations { instance.three_rest(k0: 9, k1: 8, k2: 7, z: 1) })
  end

  private

  def race
    go = false
    threads = Array.new(THREADS) do |i|
      Thread.new do
        Thread.pass until go
        yield i
      end
    end
    go = true
    threads.map(&:value)
  end
end
