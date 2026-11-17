# frozen_string_literal: true

require "bundler/gem_tasks"
require "rake/testtask"

# Core tests never load Rails. The Active Storage tests boot a dummy app and run in their own task.
Rake::TestTask.new(:test) do |t|
  t.libs << "test" << "lib"
  t.test_files = FileList["test/**/*_test.rb"].exclude("test/active_storage/**/*", "test/dummy/**/*")
  t.warning = true
end

namespace :test do
  # Run with BUNDLE_GEMFILE=gemfiles/rails_7_2.gemfile, rails_8_0.gemfile or rails_8_1.gemfile.
  Rake::TestTask.new(:rails) do |t|
    t.libs << "test" << "lib"
    t.pattern = "test/active_storage/**/*_test.rb"
    t.warning = false
  end

  # Fail fast, with a clear message, when the Active Storage tests are run without Rails in the bundle.
  task :require_rails_gemfile do
    unless Gem.loaded_specs.key?("activestorage")
      abort "rake test:rails needs a Rails gemfile. Run it with BUNDLE_GEMFILE set to one of: " \
            "#{Dir["gemfiles/rails_*.gemfile"].sort.join(", ")} (current: #{ENV.fetch("BUNDLE_GEMFILE", "Gemfile")})."
    end
  end
  task rails: :require_rails_gemfile
end

task default: :test
