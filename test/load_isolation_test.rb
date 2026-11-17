# frozen_string_literal: true

require "test_helper"
require_relative "support/fixtures"
require_relative "support/load_isolation"

# AS-21 in the core suite, which CI runs without Rails in the bundle: the gem loads and renders with no
# Railtie, no Rails file and the previewer not loaded.
class CoreLoadIsolationTest < Minitest::Test
  def test_AS_21_requiring_the_gem_loads_nothing_from_rails
    LoadIsolation.assert_isolated(self)
  end

  def test_AS_21_rendering_loads_nothing_from_rails
    LoadIsolation.assert_isolated(self, after: "CsvPreview.render(#{Fixtures.path("simple.csv").inspect})")
  end
end
