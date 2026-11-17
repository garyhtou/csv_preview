# frozen_string_literal: true

require_relative "../rails_helper"
require_relative "../support/load_isolation"

# Acceptance test AS-21 (active-storage.md 3.1): with Rails in the bundle, requiring the gem still loads
# no Rails and no Active Storage. The core suite runs the same check without Rails in the bundle.
class LoadIsolationTest < Minitest::Test
  def test_AS_21_requiring_the_gem_loads_nothing_from_rails
    LoadIsolation.assert_isolated(self)
  end
end
