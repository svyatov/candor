# Contributing

`bundle exec rake` runs RuboCop, `rbs validate` and the tests. It must be green on every supported Ruby
(3.2 through 4.0) before a pull request.

## Setup

```sh
git clone https://github.com/svyatov/candor.git
cd candor
bundle install
bundle exec rake
```

Candor has no runtime dependencies, so `bundle install` is pulling in development tools only: RuboCop,
Minitest, RBS, YARD, SimpleCov and benchmark-ips. Ruby 3.2 or newer is the only prerequisite.

Useful subsets of the default task:

```sh
bundle exec rake test TEST=test/candor/signature_test.rb   # one file
bundle exec rake test TESTOPTS="--name=/re_fabrication/"   # one test
COVERAGE=1 bundle exec rake test                           # enforce 100% line coverage
bundle exec rake rbs                                       # sig/ parses and resolves
bundle exec rake yard:stats                                # public API is 100% documented
bundle exec rake bench                                     # dispatch benchmarks
```

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

Fork the repository, branch off `main`, and open a pull request against `main`. Commit messages follow
[Conventional Commits](https://www.conventionalcommits.org/en/v1.0.0/). One logical change per pull
request; a refactor bundled with a fix costs the review twice.

A change that adds or alters functionality arrives with a test. That is not a review preference, it is
the only way the suite can tell the difference: candor's whole subject is what a fabricated method
*reports*, and no existing assertion covers a shape nobody has written one for.

A contribution is acceptable when all of these hold:

- `bundle exec rake` is green on 3.2, 3.3, 3.4 and 4.0
- `COVERAGE=1 bundle exec rake test` reports 100% line coverage
- `bundle exec rake yard:stats` reports the public API 100% documented
- the style rules in [`.rubocop.yml`](.rubocop.yml) pass, including the per-file exclusions and the
  reasons written above them
- `sig/` changed in the same commit as any public API it describes
- `CHANGELOG.md`'s `## Unreleased` section reflects the net user-facing change

CI checks the first three on every supported Ruby. The last three are what review is for.

## Governance

Candor has one maintainer, [Leonid Svyatov](https://github.com/svyatov), who reviews and merges every
change and publishes every release. Decisions are his; there is no committee and no vote.

There is no succession arranged. If he stops maintaining the gem, the repository is either transferred
to someone who volunteers to take it or archived with a notice in the README, and the RubyGems
name stays reserved either way. Nobody else currently holds push access or a publishing credential,
so plan around that if you are deciding whether to depend on candor.
