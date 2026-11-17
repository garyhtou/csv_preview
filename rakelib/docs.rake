# frozen_string_literal: true

require_relative "docs_check"

namespace :docs do
  desc "Check that the README, gemspec, llms.txt and agent skill agree, links resolve, cited tests exist " \
       "and the public API is documented"
  task :check do
    problems = DocsCheck.new(File.expand_path("..", __dir__)).problems
    abort "docs:check found #{problems.size} problem(s):\n#{problems.map { |p| "  - #{p}" }.join("\n")}" if problems.any?

    puts "docs:check passed"
  end
end
