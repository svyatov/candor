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

# `rake release` pushes to RubyGems, which requires an MFA OTP. Feed it a fresh code from
# 1Password via GEM_HOST_OTP_CODE, which `gem push` reads.
Rake::Task["release:rubygem_push"].enhance(["fetch_otp"])

task :fetch_otp do
  ENV["GEM_HOST_OTP_CODE"] = `op item get "RubyGems" --account my --otp`.strip
end

task default: %i[rubocop rbs test]
