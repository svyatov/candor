# Contributing

`bundle exec rake` runs RuboCop, `rbs validate` and the tests. It must be green on every supported Ruby
(3.2 through 4.0) before a pull request.

## Tests

`Rake::TestTask#warning` defaults to true, so the suite runs under `-w`. A warning is a failure waiting
to happen — a redefinition the gem should have avoided, a shape Ruby dislikes — so keep the output clean
rather than learning to scroll past it. Where a test *deliberately* feeds Ruby source written to be
rejected, wrap it in `capture_io` and say so in a comment.

Coverage is 100%, enforced by `COVERAGE=1 bundle exec rake test`. Note what it does not buy you: SimpleCov
measures **lines**, and a `case` branch such as `when :keyrest then ...` counts as covered the moment the
`when` executes, even when its body never runs. A dispatch bug lived behind exactly that for the whole of
0.1.0's development. Line coverage is a floor, not a proof — assert the behaviour.

Two properties are cheap to assert wrongly:

**Allocation counts.** Disable the GC and diff `GC.stat(:total_allocated_objects)`, and warm both the
branch under test *and* the measuring method — its own first execution allocates a cache. See
`test_helper.rb`. The counts differ per Ruby: a `define_method`-created method is charged for arguments
crossing into it before 3.3 (keywords) and before 3.4 (a splatted `**hash`). Gate an exact count on the
version, or express it through `KEYWORD_HOP` / `SPLAT_HOP`.

**Races.** MRI preempts on a ~100 ms timer, so a loop short enough to live in a test suite is never
descheduled inside a window a few microseconds wide. Such a test passes with the bug present and proves
only the scheduler's mood. Assert the mechanism instead: `test_re_fabrication_never_removes_the_method_it_replaces`
uses the `method_removed` hook to state the invariant directly, and fails the instant a `remove_method`
creeps back in.

## Types

`sig/` declares the **public API and nothing else**. `Candor::Definer`, the global `MONITOR` and the
compiler's spelling constants are all `private_constant`, and RBS has no syntax for that — a declaration
would advertise a surface that raises `NameError` on use.

`bundle exec rake rbs` runs `rbs validate`, which checks that the signatures parse and resolve. It does
**not** check them against `lib/`. `test/sig_test.rb` covers the half that matters without a type checker:
every name `sig/` declares must exist, and every public name the gem defines must be declared. The types
themselves are verified by review. Two tools that would check them, and why neither is wired up:

**`RBS::Test`** rewraps every block it sees, which changes `Proc#arity`. Preserving `Proc#arity` through
`define_method` is the entire gem; a checker that silently breaks the property under test is worse than
none.

**Steep** is static and has no such objection, but it types `define_method`'s block parameter as
`^ [self: top] -> untyped`, which no `Proc` value satisfies. Compiling procs into methods is what this
library does, so the one call it exists to make reports `BlockTypeMismatch` and has to be suppressed.
The same evaluation, in more detail and against a larger tree, is in
[briefly's CONTRIBUTING.md](https://github.com/svyatov/briefly/blob/main/CONTRIBUTING.md).

So: keep `sig/` small, and change it in the same commit as the code it describes.

## Documentation

`bundle exec rake yard:stats` fails unless the public API is 100% documented.

## Commits and pull requests

Commit messages follow [Conventional Commits](https://www.conventionalcommits.org/en/v1.0.0/).

Before opening a pull request: `bundle exec rake` is green on every supported Ruby, coverage is 100%, and
`CHANGELOG.md`'s `## Unreleased` section reflects the net user-facing change.
