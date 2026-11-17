# frozen_string_literal: true

require "json"
require_relative "child_ruby"

# Acceptance test AS-21 (active-storage.md 9.3), shared by the core suite (no Rails in the bundle) and the
# Active Storage suite (Rails in the bundle but not required): in a fresh process, requiring the gem, and
# then running +after+, defines no Railtie, loads no Active Storage, Active Record or Rails file, and
# leaves the previewer's autoload pending.
module LoadIsolation
  module_function

  # @param test [Minitest::Test]
  # @param after [String] Ruby source run in the child after +require "csv_preview"+
  def assert_isolated(test, after: "")
    out, err, status = ChildRuby.run(<<~RUBY)
      require "csv_preview"
      require "json"
      #{after}
      rails_files = $LOADED_FEATURES.grep(%r{/(active_storage|active_record|rails)(/|\\.rb)})
      puts JSON.generate(railtie: defined?(CsvPreview::Railtie).inspect,
                         rails_files: rails_files,
                         autoload: CsvPreview.autoload?(:ActiveStoragePreviewer),
                         active_storage: defined?(ActiveStorage).inspect)
    RUBY
    test.assert status.success?, err

    result = JSON.parse(out.lines.last)
    test.assert_equal "nil", result["railtie"], "CsvPreview::Railtie is defined"
    test.assert_empty result["rails_files"]
    test.assert_equal "csv_preview/active_storage_previewer", result["autoload"], "the previewer was loaded"
    test.assert_equal "nil", result["active_storage"], "ActiveStorage is defined"
  end
end
