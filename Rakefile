# frozen_string_literal: true

require "bundler/gem_tasks"
require "rake/testtask"
require "rubocop/rake_task"
require "yard"

# `warning` defaults to true, so every test run is under `-w`: a redefinition warning fails the suite
# rather than scrolling past.
Rake::TestTask.new(:test) do |t|
  t.libs << "test"
  t.libs << "lib"
  t.test_files = FileList["test/**/*_test.rb"]
end

RuboCop::RakeTask.new

# `rbs validate` only checks that `sig/` is internally well-formed; it never reads `lib/`. The names it
# declares are pinned against the real ones by `test/sig_test.rb`.
desc "Validate RBS signatures"
task :rbs do
  sh "rbs -I sig validate"
end

YARD::Rake::YardocTask.new

namespace :yard do
  desc "Fail unless 100% of the public API is documented"
  task :stats do
    out = `yard stats --list-undoc`
    puts out
    abort "Undocumented public API found" unless out.include?("100.00% documented")
  end
end

desc "Run the dispatch benchmarks"
task :bench do
  ruby "benchmark/dispatch_bench.rb"
end

# Publishing moved to .github/workflows/release.yml, where rubygems.org mints a short-lived token
# through OIDC for that workflow and the `release` environment alone. No API key exists here to use.
# Leaving `rake release` able to push would keep a second route open, and a second route is the one
# that gets taken when the gate is inconvenient, so it fails loudly instead.
Rake::Task["release:rubygem_push"].clear
task "release:rubygem_push" do
  abort <<~MSG
    Publishing runs in CI, not from a developer machine.

    Bump Candor::VERSION, add the CHANGELOG.md section, merge, then:

      git tag -s v#{Candor::VERSION} -m "v#{Candor::VERSION}"
      git push origin v#{Candor::VERSION}

    That triggers .github/workflows/release.yml and waits for approval on the `release` environment.
  MSG
end

task default: %i[rubocop rbs test]
