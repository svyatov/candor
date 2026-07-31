# Security policy

## Reporting a vulnerability

Report privately through GitHub's advisory form:
[github.com/svyatov/candor/security/advisories/new](https://github.com/svyatov/candor/security/advisories/new).
That opens a report only you and the maintainer can read. If you cannot use it, email
leonid@svyatov.com.

Please do not open a public issue for a security problem. A public report tells everyone running the
gem about the bug at the same moment it tells the maintainer.

You will get an initial response within 14 days. That is an acknowledgement and a first assessment,
not a fix; the fix timeline depends on what the report turns out to be, and you will hear the
estimate in that first reply.

## Supported versions

Candor is pre-1.0, so only the latest released version gets fixes. Older versions are not patched.
Check [rubygems.org/gems/candor](https://rubygems.org/gems/candor) for what that currently is.

## Scope

Candor compiles a parameter list to Ruby source and `eval`s it, so the interesting reports are about
that boundary. `Candor::Signature`'s three gates, `method_name!`, `parameters!` and
`source_location!`, are what stand between a caller's input and `eval`. A parameter shape, a method
name or a source location that reaches `eval` without being rejected by the matching gate, and that
executes something the caller did not write, is a vulnerability.

Before filing, read what the render would actually run. `Candor::Signature.render` returns the source
`compile` would `eval`, without evaluating it, so a suspected injection can be shown rather than
described. Include that output in the report. The README's "The contract" section covers what the
`eval` does and does not accept.
