# frozen_string_literal: true

module CsvPreview
  # Base class for every error the gem raises on purpose. Messages never include input content, and
  # each one says what to do next and links the README section that explains it.
  class Error < StandardError; end

  # The input is binary, undecodable, or not text at all (for example a PNG or XLSX file renamed
  # `.csv`). Show a fallback for such files; in Rails, discard the preview job's
  # `ActiveStorage::PreviewError`.
  class UnreadableInput < Error; end

  # The call ran past its `timeout`. The message names the stage that noticed.
  class TimeoutExceeded < Error; end

  # libvips is missing, lacks text (Pango) support, failed, or cannot encode the requested format.
  class RenderFailed < Error; end

  # README sections that error messages and warnings link to, so a person or a coding agent reading a
  # log knows where the fix is documented.
  # @api private
  module Help
    REPOSITORY = "https://github.com/garyhtou/csv_preview"
    INSTALLATION = "#{REPOSITORY}#installation"
    ERRORS = "#{REPOSITORY}#errors"
    OPTIONS = "#{REPOSITORY}#options"
    RAILS = "#{REPOSITORY}#rails-usage"
    ISSUES = "#{REPOSITORY}/issues"
  end
end
