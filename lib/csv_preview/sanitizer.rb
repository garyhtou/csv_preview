# frozen_string_literal: true

module CsvPreview
  # Turns raw cell text into a single line of literal, displayable text.
  # See docs/spec/parsing-and-safety.md section 5.
  # @api private
  module Sanitizer
    ELLIPSIS   = "…"
    BREAKS     = /(?:\r\n|[\t\n\v\f\r\u0085\u2028\u2029])+/
    REMOVE     = /[\u0000-\u0008\u000E-\u001F\u007F-\u0084\u0086-\u009F\u061C\u200B\u200E\u200F\u202A-\u202E\u2060\u2066-\u2069\uFEFF\uFFF9-\uFFFB]+/
    MARK_RUN   = /[\p{Mn}\p{Me}]{9,}/
    EDGE_SPACE = /\A +| +\z/

    module_function

    # @param text [String] one cell, valid UTF-8
    # @param max_cell_chars [Integer] cap in extended grapheme clusters
    # @param capped [Boolean] true when the raw cell was already cut upstream; forces the trailing ellipsis
    # @return [String] frozen
    def clean(text, max_cell_chars:, capped: false)
      s = text.gsub(BREAKS, " ")
      s.gsub!(REMOVE, "")
      s.gsub!(MARK_RUN) { |run| run[0, 8] }
      s.gsub!(EDGE_SPACE, "")
      clusters = s.each_grapheme_cluster.first(max_cell_chars + 1)
      return s.freeze if clusters.size <= max_cell_chars && !capped

      (clusters.first(max_cell_chars - 1).join.sub(/ +\z/, "") + ELLIPSIS).freeze
    end
  end
end
