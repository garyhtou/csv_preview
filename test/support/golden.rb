# frozen_string_literal: true

# What the golden images cover, shared by test/golden_test.rb and bin/goldens.
module Golden
  DIR = File.expand_path("../golden", __dir__)
  NAMES = %w[simple wide_long numbers emoji_cjk statement].freeze

  module_function

  # Facts that survive different fonts: stored beside each golden by bin/goldens.
  def facts(layout)
    {
      "visible_columns" => layout.visible_columns,
      "rows_shown" => layout.rows_shown,
      "footer_pattern" => layout.footer_text&.gsub(/\d[\d,]*/, "N")
    }
  end
end
