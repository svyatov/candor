# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html) and to [Conventional Commits](https://www.conventionalcommits.org/en/v1.0.0/).

## [0.2.0] - 2026-07-10

### Added
- `Candor.define(..., source_location:)` — the location every fabricated name reports, overriding the body's. A caller whose body is a proc it generated on the user's behalf can now point the wrapper at what the user actually wrote, rather than at the generator. It is also the only way to fabricate from a body carrying no location of its own — a curried proc, a symbol-to-proc, a C-defined method — which is the caller assuming responsibility for the honesty the gem otherwise derives. A `#call` object is not one of them and no `source_location:` rescues it: that refusal is about the kind. A `source_location:` that is not a `[String, Integer]` pair, or whose line is one `eval` will not take, raises `ArgumentError` before the target is touched.
- `Candor::Signature.source_location!` — the location gate, public beside `method_name!` and `parameters!`. `Signature.compile` calls it, so a consumer installing dispatch itself can no longer forge a location `eval` refuses, nor one it silently misreads. Its line must fit `eval`'s: a C `int`.

## [0.1.0] - 2026-07-10

### Added
- `Candor.define(target, name, aliases:, via:, parameters:, body:)` — fabricates a real method whose arity, `parameters` kinds and `source_location` are the body's. Bodies may be a block, a `Proc`, a `Method` or an `UnboundMethod`; a `#call` object or any body with a `nil` `source_location` (a curried proc, a C-defined method) raises `TypeError`. With `via:` every call routes to that interceptor, which reaches the body through `Candor.body_name`; without it the wrapper forwards straight to the body. A wrong-arity call or an unknown keyword raises `ArgumentError` at the wrapper, before the interceptor or the body runs. An unpassed optional is dropped from the forwarded arguments, so the body applies its own default.
- `Candor::Signature` — the low-level compiler, public on its own: a parameter shape, a call-site name and a `source_location` in, a dispatch lambda out. Renders off a parameter's kind, never its name, so `end:`, `it`, `_1`, `**nil` and destructuring parameters all wrap at full fidelity. Both call-site names are validated against a strict method-name pattern, and a malformed `parameters` shape raises `ArgumentError` rather than a `SyntaxError` from inside `eval` — including a shape whose entries are each legal but whose combination Ruby's parser rejects, which is compiled before the target is mutated so a rejected fabrication cannot destroy the method it was replacing.
- Dispatch allocates nothing for shapes up to `Candor::Signature::KEYWORD_BRANCH_LIMIT` (2) optional keywords; beyond it, exactly one Hash per call. Past the limit a body's keyrest *is* that Hash, so a `**kw` in the signature costs only the capture and re-splat Ruby charges any wrapper. Exact from Ruby 3.4: on earlier Rubies the VM charges a `define_method`-created method for arguments crossing into it, and both the wrapper and the body are ones. A call carrying no keyword allocates nothing on every supported Ruby.
- Fabrication is thread-safe through one global `Monitor`; call-time dispatch takes no lock and never needs one. Re-fabricating a name overwrites the wrapper and the body in place, so it is warning-free under `ruby -w`, leaves no orphaned body, and a concurrent caller sees the old method or the new one, never a `NoMethodError`. A frozen target, an unbindable `Method`/`UnboundMethod` body, a name under the reserved `Candor::BODY_PREFIX`, an uncallable `via:` and a malformed `parameters:` all raise before the target is touched.
- `sig/` ships RBS for the public API: `Candor.define`, `Candor.body_name`, `BODY_PREFIX`, and `Candor::Signature` with `KINDS` and `KEYWORD_BRANCH_LIMIT`. Everything else is `private_constant`, which RBS cannot express and therefore does not declare.

[0.2.0]: https://github.com/svyatov/candor/releases/tag/v0.2.0
[0.1.0]: https://github.com/svyatov/candor/releases/tag/v0.1.0
