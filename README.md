# Candor

**Ruby's missing `functools.wraps`.** Turn a block or a callable into a real method that reports the
*body's* arity, the *body's* `parameters` and the *body's* `source_location` — and rejects a bad call
before anything of yours runs.

Zero runtime dependencies. Ruby >= 3.2.

```ruby
Candor.define(Greeter, :greet) { |name, greeting: "hi"| "#{greeting}, #{name}" }

Greeter.instance_method(:greet).arity            # => -2
Greeter.instance_method(:greet).parameters       # => [[:req, :__p0], [:key, :greeting]]
Greeter.instance_method(:greet).source_location  # => ["app/greeter.rb", 3]  ← the block, not the gem

Greeter.new.greet                                # => ArgumentError: wrong number of arguments (given 0, expected 1)
Greeter.new.greet("bob", grating: "yo")          # => ArgumentError: unknown keyword: :grating
```

## The problem

Ruby gives you no way to hand a generated wrapper the signature of the callable it wraps.
`define_method` accepts only a `Proc`, a `Method` or an `UnboundMethod`, so a wrapper's arity has to
come from an object that already has it — and the only source of such an object is a literal parameter
list, hand-typed or generated as text.

So libraries that wrap user-supplied callables retreat to `|*args, **kwargs, &block|`. The results are
right; the reflection lies. `arity` is `-1`, `parameters` reads `[[:rest], [:keyrest], [:block]]`, a
wrong-arity call blows up one frame too deep — inside the wrapper, where the library's own error
handling can swallow it — and every call allocates an Array and a Hash.

Candor generates the parameter list as source and `eval`s it, once, at definition time. There is no
degraded fallback: every shape Ruby can express wraps at full fidelity, including `end:`, `it`, `_1`,
`**nil`, and destructuring parameters.

## Install

```ruby
gem "candor"
```

## Use

### Direct forward

With no interceptor, the wrapper forwards straight to the body. An unpassed optional is **dropped** from
the forwarded arguments, so the body applies its own default.

```ruby
Candor.define(Formatter, :pad) { |string, width = 8| string.ljust(width) }

Formatter.new.pad("x")     # => "x       "   the body's own default
Formatter.new.pad("x", 3)  # => "x  "
```

### Through an interceptor

`via:` names a method on the target, resolved per call. Every call routes to it and to it alone. It
receives the canonical name and the arguments exactly as passed, and reaches the body through
`Candor.body_name`, so it can also choose *not* to run it — memoize, instrument, short-circuit.

```ruby
class Memo
  def initialize = @cache = {}

  private

  def __call(name, ...)
    @cache[name] ||= send(Candor.body_name(name), ...)
  end
end

Candor.define(Memo, :catalog, parameters: [], via: :__call) { Catalog.build }
```

A wrong-arity call raises at the wrapper, before `__call` is ever entered — so an interceptor that
rescues broadly never sees a caller's mistake as a body's failure. An alias left behind by an *earlier*
fabrication is the exception: it keeps the wrapper it was built with, so its gate is that fabrication's
signature and not the current body's. See [Re-fabrication](#the-contract).

### Aliases and shape overrides

```ruby
Candor.define(App, :configuration, aliases: %i[config c], via: :__call) { |scope| ... }
Candor.define(App, :catalog, parameters: []) { |page = 1| ... }  # advertise zero parameters
```

`aliases:` share one dispatch, and the interceptor always receives the *canonical* name.
`parameters:` overrides what the wrapper advertises; it is **not** validated against the body, so a
mismatch surfaces as the body's own `ArgumentError`.

### The compiler on its own

`Candor::Signature` is public for consumers that install methods themselves:

```ruby
dispatch = Candor::Signature.compile(parameters, name: :greet, via: :__call, source_location: loc)
klass.define_method(:greet, &dispatch)
```

## The contract

**Body kinds.** A block, a `Proc`, a `Method` or an `UnboundMethod` — the three things `define_method`
takes. A `#call` object is rejected. So is any body whose `source_location` is `nil`: a curried proc, a
`Symbol#to_proc`, a C-defined method. Ruby exposes no `curried?` predicate, and a nil `source_location`
is the one reliable discriminator — without it the honest-`source_location` guarantee cannot be kept, and
that guarantee is the product. Inside a block body, `self` is the receiver.

**Reserved prefix.** Compiled bodies are private methods named `#{Candor::BODY_PREFIX}#{name}`.
Fabricating a name that starts with the prefix raises `ArgumentError`.

**Allocation.** Dispatch allocates **nothing** for every shape up to two optional keywords. Ruby fills
optional positionals left to right, so `n` of them have `n + 1` states, enumerated as call sites rather
than accumulated into an Array. Optional keywords are independent, so `n` of them would cost `2**n` call
sites; past `Candor::Signature::KEYWORD_BRANCH_LIMIT` (2) they go through one Hash instead, and
dispatch allocates exactly one Hash per call. That shape — three or more optional keywords — is the one
case where candor is slower than the variadic wrapper it replaces. It is measured, and accepted.

Those counts are what the *wrapper* adds. A body that declares a **keyrest** (`**kw`) costs Ruby one Hash
to capture it and one to re-splat it into the body, on any wrapper you could write by hand; candor adds
none of its own, because past the branch limit the captured keyrest *is* the Hash the keywords accumulate
into.

Exactly as stated from **Ruby 3.4**. Below that, Ruby itself charges a `define_method`-created method for
arguments crossing into it, and both the wrapper and the body are ones: on 3.3 the hashed path costs one
Hash more, and on 3.2 a keyword-carrying call costs one Hash per hop. Nothing in the gem can reach that,
and no call that carries no keyword ever allocates, on any supported Ruby.

**Thread safety.** Fabrication takes one global `Monitor`; concurrent `Candor.define` calls
serialize. Call-time dispatch takes no lock at all, and never needs one: re-fabrication replaces a
method in place rather than removing and reinstalling it, so a caller racing a `Candor.define` gets
the old method or the new one, never a `NoMethodError`.

**Failing fast.** A frozen target raises `FrozenError`, an `UnboundMethod` whose owner is not an
ancestor of the target raises `TypeError`, and a malformed `parameters:` or an uncallable `via:` raises
`ArgumentError` — all *before* the target is touched. A rejected fabrication leaves the target exactly
as it was. A hand-written `parameters:` never passed Ruby's parser, so it is compiled before the first
mutation: a shape whose *combination* is illegal — two rests, a duplicate keyword — is an `ArgumentError`
too. Nothing ever surfaces as a `SyntaxError` from inside `eval`, which a `rescue` would not catch.

**A Ruby 3.4 wrinkle.** On 3.4 alone, a body written with the implicit `it` parameter receives its
arguments packed into an Array when it is reached through `(name, ...)` forwarding, `send`, or a splat —
the shape an interceptor is usually written in. Candor's own generated call sites name every
argument, so direct-forward mode is unaffected; fixed in Ruby 4.0, and `_1` and named parameters never
had it.

**Re-fabrication.** Redefining a name overwrites candor's own prior wrapper and body in place, so a
second `Candor.define` is warning-free under `ruby -w` and orphans nothing. It rewrites only the
names passed to the *current* call: an alias installed by an earlier fabrication stays installed and
rebinds to the replacement body while still advertising its original signature. Last write wins. A
hand-written method of the same name is replaced cleanly; an inherited one is shadowed, not removed.

## Benchmarks

`bundle exec rake bench`, on ruby 4.0.5 (arm64-darwin23). Nanoseconds per call, lower is better; the
optional-argument rows carry a few percent of noise.

| shape | candor | hand-written wrapper | bare method | variadic wrapper |
|---|---|---|---|---|
| no arguments | 52 ns · 0 alloc | 47 ns · 0 | 27 ns · 0 | 122 ns · 2 |
| required + optional, omitted | 107 ns · 0 alloc | 82 ns · 0 | 43 ns · 0 | 140 ns · 2 |
| required + optional, passed | 81 ns · 0 alloc | 63 ns · 0 | 36 ns · 0 | 149 ns · 2 |
| two optional keywords | 112 ns · 0 alloc | 79 ns · 0 | 46 ns · 0 | 170 ns · 2 |
| three optional keywords | 251 ns · 1 alloc | 99 ns · 0 | 46 ns · 0 | 185 ns · 2 |

- **hand-written wrapper** is the ceiling: a real `def` with the same signature forwarding to the same
  private body, with the defaults hard-coded — what you would write by hand if you knew the shape *and*
  the default expressions. Candor is within ~10–40% of it, and allocates the same nothing.
- **bare method** is a single `def` doing the work inline. It is roughly twice as fast as any wrapper,
  because it is one method call rather than two. That is the price of wrapping at all, not of candor.
- **variadic wrapper** is the `|*args, **kwargs, &block|` retreat: slower than candor on every shape
  below the keyword branch limit, faster on the hashed one, and dishonest about its signature everywhere.

Definition time is ~40 µs per fabricated method — one `eval` — against ~1.3 µs for a bare
`define_method`. It runs once, at boot.

## What it is not

Candor routes calls. It does not rescue, memoize, delegate or instrument; it is the method-fabrication
layer those features stand on. It does not recover an optional's default expression — that is
[permanently closed upstream](https://bugs.ruby-lang.org/issues/8629), and dropping the unpassed optional
so the body defaults is the semantics that replaces it. Fabricated methods are not Ractor-shareable, and
the gem needs `eval`, so it does not run on eval-restricted platforms.

## License

MIT. See [LICENSE.txt](LICENSE.txt).
