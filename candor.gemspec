# frozen_string_literal: true

require_relative "lib/candor/version"

Gem::Specification.new do |spec|
  spec.name = "candor"
  spec.version = Candor::VERSION
  spec.authors = ["Leonid Svyatov"]
  spec.email = ["leonid@svyatov.com"]

  spec.summary = "Turn a block or a callable into a real method with an honest signature."
  spec.description = "Candor fabricates real methods from blocks and " \
                     "callables: same arity, same parameters, source_location pointing at your code, and " \
                     "allocation-free dispatch. Zero runtime dependencies."
  spec.homepage = "https://github.com/svyatov/candor"
  spec.license = "MIT"

  spec.required_ruby_version = ">= 3.2.0"

  spec.require_paths = ["lib"]
  spec.files = Dir["lib/**/*.rb"] + Dir["sig/**/*"] +
               %w[.yardopts CHANGELOG.md LICENSE.txt README.md candor.gemspec]

  spec.metadata["rubygems_mfa_required"] = "true"
  spec.metadata["documentation_uri"] = "https://rubydoc.info/gems/candor"
  spec.metadata["source_code_uri"] = "https://github.com/svyatov/candor"
  spec.metadata["changelog_uri"] = "https://github.com/svyatov/candor/blob/main/CHANGELOG.md"
  spec.metadata["bug_tracker_uri"] = "https://github.com/svyatov/candor/issues"
end
