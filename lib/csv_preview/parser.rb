# frozen_string_literal: true

require "csv"
require "stringio"

module CsvPreview
  # Turns the Reader's decoded, bounded text into a {Sample} with Ruby's csv library, wrapped so that it
  # stays bounded and never aborts on malformed input. Internal API.
  #
  # See docs/spec/parsing-and-safety.md section 4 (and appendix A for the reference core).
  # @api private
  class Parser
    CANDIDATES = [",", ";", "\t", "|"].freeze
    DEFAULT_DELIMITER = ","
    SNIFF_BYTES = 65_536
    SNIFF_ROWS = 30
    SNIFF_COLUMNS = 64
    CONSISTENCY_SLACK = Rational(1, 10)
    # Excel's delimiter directive, honoured only as the very first line and only with delimiter: :auto.
    SEP_DIRECTIVE = /\Asep=(.)\r?\n/
    NOT_SPACE = /[^ ]/

    # @param result [Reader::Result] its text is rewritten in place (it belongs to the gem)
    # @param config [Configuration] a resolved snapshot
    # @param deadline [Deadline]
    # @return [Sample]
    # @raise [TimeoutExceeded]
    def self.call(result, config:, deadline:) = new(config, deadline).call(result)

    # Rewrites line breaks in place: CRLF and lone CR become LF, then runs of LF collapse to one.
    # Display-equivalent (section 4.2). Two C passes, no copy.
    #
    # @param text [String] mutable UTF-8 text
    # @return [String] the same object
    def self.normalize!(text)
      text.tr!("\r", "\n")
      text.squeeze!("\n")
      text
    end

    # Byte cap for one kept raw cell (section 4.8): 4 bytes per code point, twice over, plus headroom.
    # @param max_cell_chars [Integer]
    # @return [Integer]
    def self.raw_cap(max_cell_chars) = (8 * (max_cell_chars + 1)) + 64

    def initialize(config, deadline)
      @config = config
      @deadline = deadline
      @raw_cap = self.class.raw_cap(config.max_cell_chars)
    end

    # Section 4.11.
    def call(result)
      text = +result.text
      delimiter = @config.delimiter
      if delimiter == :auto
        directive, text = excel_directive(text)
        self.class.normalize!(text)
        delimiter = directive || sniff(text, result.complete)
      else
        self.class.normalize!(text)
      end

      max_rows = @config.max_rows
      records = Records.new(text, complete: result.complete, delimiter: delimiter, keep_rows: max_rows + 1,
                                  keep_columns: @config.max_columns, raw_cap: @raw_cap, deadline: @deadline).call
      cleaned = records.kept.map do |cells|
        @deadline.check!(:sanitize)
        cells.map { |cell| Sanitizer.clean(cell.text, max_cell_chars: @config.max_cell_chars, capped: cell.capped) }
      end

      header = records.count.positive? &&
               (@config.header_row == :auto ? Header.header?(cleaned, records.widths.max) : @config.header_row)
      data = header ? cleaned[1, max_rows] || [] : cleaned.first(max_rows)
      used = header ? records.widths.first(max_rows + 1) : records.widths.first(max_rows)
      column_count = used.max || 0
      rows = data.map { |row| fit(row, column_count) }
      rows_read = records.count - (header ? 1 : 0)
      complete = records.complete

      Sample.new(
        headers: header ? fit(cleaned[0], column_count) : nil,
        rows: rows,
        column_count: column_count,
        total_columns: records.max_width,
        total_rows: complete ? rows_read : nil,
        rows_read: rows_read,
        rows_truncated: rows_read > rows.size || !complete,
        columns_truncated: records.max_width > column_count,
        column_kinds: Array.new(column_count) { |c| CellKind.column(rows.map { |row| row[c] }) },
        delimiter: delimiter,
        encoding: result.encoding,
        empty: records.count.zero?
      )
    end

    private

    # Removes a leading "sep=X" line in place when X is a valid delimiter. The directive is neither shown
    # nor counted.
    #
    # @return [Array(String, String), Array(nil, String)] the directive's delimiter (or nil) and the text
    def excel_directive(text)
      return [nil, text] unless text.start_with?("sep=")

      match = SEP_DIRECTIVE.match(text)
      delimiter = match && match[1]
      return [nil, text] unless delimiter && valid_delimiter?(delimiter)

      text.bytesplice(0, match.byteoffset(0)[1], "")
      [delimiter, text]
    end

    def valid_delimiter?(char)
      char.ascii_only? && !Configuration::FORBIDDEN_DELIMITERS.include?(char)
    end

    # Section 4.9.
    def sniff(text, complete)
      sample = text.byteslice(0, SNIFF_BYTES).scrub("")
      whole = sample.bytesize == text.bytesize
      unless whole
        lf = sample.byterindex("\n")
        sample = sample.byteslice(0, lf + 1) if lf
      end

      scores = CANDIDATES.each_with_index.filter_map do |candidate, index|
        @deadline.check!(:sniff)
        score(sample, candidate, index, complete && whole)
      end
      return DEFAULT_DELIMITER if scores.empty?

      best = scores.map { |s| s[:consistency] }.max
      scores.select { |s| s[:consistency] >= best - CONSISTENCY_SLACK }
            .max_by { |s| [s[:clean], s[:mode], -s[:index]] }[:delimiter]
    end

    # @return [Hash, nil] nil when the candidate does not split the sample (mode below 2)
    def score(sample, candidate, index, complete)
      records = Records.new(sample, complete: complete, delimiter: candidate, keep_rows: SNIFF_ROWS,
                                    keep_columns: SNIFF_COLUMNS, raw_cap: @raw_cap, deadline: @deadline,
                                    kept_only: true).call
      tally = records.widths.tally
      return nil if tally.empty?

      mode, mode_count = tally.max_by { |width, count| [count, width] }
      return nil if mode < 2

      others = CANDIDATES - [candidate]
      non_empty = clean = 0
      records.kept.each do |cells|
        cells.each do |cell|
          stripped = strip_spaces(cell.text)
          next if stripped.empty?

          non_empty += 1
          clean += 1 if others.none? { |o| stripped.include?(o) } || CellKind.cell(stripped) == :number
        end
      end
      {
        delimiter: candidate, index: index, mode: mode,
        consistency: Rational(mode_count, records.widths.size),
        clean: non_empty.zero? ? 0 : Rational(clean, non_empty)
      }
    end

    # Removes leading and trailing ASCII spaces with linear searches (the cell is at most raw_cap bytes).
    def strip_spaces(text)
      first = text.index(NOT_SPACE) or return ""
      text[first..text.rindex(NOT_SPACE)]
    end

    # Pads a row with "" or cuts it to n cells.
    def fit(row, n) = row.size >= n ? row.first(n) : row + Array.new(n - row.size, "")

    # Header detection for header_row: :auto (section 4.10).
    module Header
      DATE = %r{\A(?:\d{4}[-/.]\d{1,2}[-/.]\d{1,2}|\d{1,2}[-/.]\d{1,2}[-/.]\d{2,4})
                (?:[ T]\d{1,2}:\d{2}(?::\d{2}(?:\.\d+)?)?(?:\s?(?:[AaPp][Mm]|Z|[+-]\d{2}:?\d{2}))?)?\z}x
      MAX_DATE_LENGTH = 40

      module_function

      # @param cleaned [Array<Array<String>>] the sanitized kept records, the first being the candidate
      # @param columns [Integer] the columns to consider (the widest kept record)
      # @return [Boolean]
      def header?(cleaned, columns)
        first = Array.new(columns) { |c| cleaned[0][c] || "" }
        head = first.map { |cell| klass(cell) }
        data = cleaned.drop(1)
        return head.all?(:text) if data.empty?

        score = 0
        columns.times do |c|
          cells = data.filter_map { |row| row[c] unless row[c].nil? || row[c].empty? }
          next if cells.empty?

          score += column_score(first[c], head[c], cells)
        end
        values = first.reject(&:empty?)
        score -= 1 if values.uniq.size != values.size
        score.positive? || (score.zero? && head.all?(:text))
      end

      def column_score(top, top_kind, cells)
        kinds = cells.map { |cell| klass(cell) }
        dtype = if kinds.count(:number) * 5 >= cells.size * 4 then :number
                elsif kinds.count(:date) * 5 >= cells.size * 4 then :date
                else :text
                end
        if dtype == :text
          return -1 if top_kind == :empty
          return 0 unless top_kind == :text && cells.size >= 2

          lengths = cells.map(&:length).uniq
          return 0 unless lengths.size == 1

          top.length == lengths[0] ? -1 : 1
        elsif top_kind == :text then 2
        elsif top_kind == dtype then -2
        else 0
        end
      end

      def klass(cell)
        return :empty if cell.empty?
        return :number if CellKind.cell(cell) == :number
        return :date if cell.length <= MAX_DATE_LENGTH && DATE.match?(cell)

        :text
      end
    end

    # Runs Ruby's csv library over normalised text inside the gem's bounds: chunked reads through
    # {Feed}, the field guard, and the recovery rules of section 4.6. See appendix A.
    class Records
      MAX_RECORD_FIELDS = 65_536 # field guard, section 4.5
      CHECK_EVERY = 1_024 # records between deadline checks (every chunk csv reads is checked too)
      QUOTE = '"'
      LF = 0x0A
      NOT_LF = /[^\n]/
      BLANK = " \t\n"

      # @!attribute text [String] the field, cut to the raw cap
      # @!attribute capped [Boolean] the field was longer than the raw cap
      RawCell = Data.define(:text, :capped)
      Result = Data.define(:kept, :widths, :count, :max_width, :complete, :too_wide, :recovered)

      # The IO that csv reads. Deliberately not a StringIO: csv reads a StringIO whole and runs its regexes
      # over one long string, but reads any other IO in chunks of at most 8 KiB (section 4.3).
      class Feed
        CHUNK = 8_192

        # @param text [String] the text this pass parses
        # @param base [Integer] offset of text[0] in the parser's text
        # @param owner [Records] receives the deadline checks and the field-guard counts
        # @param guard [Boolean] whether the field guard applies to this pass
        # @param chunk_limit [Integer, nil] tests only: forces smaller chunks
        def initialize(text, base, owner, guard:, chunk_limit: nil)
          @io = StringIO.new(text)
          @base = base
          @owner = owner
          @guard = guard
          @chunk_limit = chunk_limit
          @stopped = false
        end

        # csv calls gets("\n", 8192). Up to `limit` bytes are returned whatever the separator: csv's
        # chunked scanner treats chunks as a byte stream. StringIO#gets never splits a character.
        def gets(_separator = nil, limit = CHUNK)
          return nil if @stopped

          @owner.checkpoint
          limit = [limit, @chunk_limit].min if @chunk_limit
          chunk = @io.gets(nil, limit) or return nil
          @stopped = @guard && @owner.too_wide?(chunk, @base + @io.pos)
          chunk
        end

        def eof? = @stopped || @io.eof?
        alias eof eof?
        def external_encoding = Encoding::UTF_8
        def internal_encoding = nil
      end

      # @param text [String] normalised UTF-8 text (not modified)
      # @param complete [Boolean] the Reader read the whole source
      # @param delimiter [String] one ASCII character
      # @param keep_rows [Integer] non-blank records to keep (max_rows + 1)
      # @param keep_columns [Integer] fields to keep per record
      # @param raw_cap [Integer] byte cap per kept field
      # @param deadline [Deadline]
      # @param kept_only [Boolean] stop once keep_rows records are kept (the sniffer)
      # @param chunk_limit [Integer, nil] tests only: forces smaller chunks
      def initialize(text, complete:, delimiter:, keep_rows:, keep_columns:, raw_cap:, deadline:,
                     kept_only: false, chunk_limit: nil)
        @text = text
        @complete = complete
        @delimiter = delimiter
        @keep_rows = keep_rows
        @keep_columns = keep_columns
        @raw_cap = raw_cap
        @deadline = deadline
        @kept_only = kept_only
        @chunk_limit = chunk_limit
      end

      # @return [Result]
      # @raise [TimeoutExceeded]
      def call
        @end = @text.bytesize
        @last_quote = last_quote_offset
        @kept = []
        @widths = []
        @count = @max_width = @rows_seen = @fields = 0
        @too_wide = @recovered = false
        catch(:enough) { parse }
        Result.new(kept: @kept, widths: @widths, count: @count, max_width: @max_width, complete: @complete,
                   too_wide: @too_wide, recovered: @recovered)
      end

      # Feed callback: a deadline checkpoint before every chunk.
      def checkpoint = @deadline.check!(:parse)

      # Feed callback. Counts delimiters since the last record csv returned (quoted ones too, so it
      # over-counts). Past the guard, csv's input ends here.
      def too_wide?(chunk, pos)
        @fields += chunk.count(@delimiter)
        return false if @fields <= field_limit

        @stop ||= [@end, @complete, @too_wide]
        @end = pos if pos < @end
        @complete = false
        @too_wide = true
        true
      end

      private

      def field_limit = MAX_RECORD_FIELDS
      def last_quote_offset = @text.byterindex(QUOTE)

      def csv_options(quoting)
        { col_sep: @delimiter, row_sep: "\n", quote_char: (QUOTE if quoting),
          liberal_parsing: true, skip_blanks: true }
      end

      # Section 4.6: at most one stray-quote recovery, then one terminal pass.
      def parse
        start = 0
        stray_done = false
        while start < @end
          @stop = nil
          x = parse_from(start) or return

          # csv raised CSV::MalformedCSVError: the record at offset x has a quote that is still open
          # where csv's input ended.
          @recovered = true
          if @stop && !stray_done
            @end, @complete, @too_wide = @stop # rule 1: a runaway quote, not a wide record
          elsif @stop || (!@complete && cut_tail?(x))
            parse_string(@text.byteslice(x, @end - x) + QUOTE, x, quoting: true, guard: false) # rule 2
            return
          end
          if stray_done
            parse_string(@text.byteslice(x, @end - x), x, quoting: false) # rule 4
            return
          end

          stray_done = true # rule 3
          lf = @text.byteindex("\n", x)
          stop = lf && lf < @end ? lf + 1 : @end
          parse_string(@text.byteslice(x, stop - x), x, quoting: false)
          start = stop
        end
      end

      # The byte limit cut record x, as far as the gem can tell: x is past the kept records, or x
      # starts on the last line read.
      def cut_tail?(x)
        lf = @text.byteindex("\n", x)
        @count >= @keep_rows || lf.nil? || lf >= @end - 1
      end

      # Parses @text[start...@end] with quoting on. Returns nil when csv finished, or the offset of the
      # record csv rejected.
      def parse_from(start)
        @fields = 0
        pos = start
        feed = Feed.new(@text.byteslice(start, @end - start), start, self, guard: true, chunk_limit: @chunk_limit)
        csv = CSV.new(feed, **csv_options(true))
        while (row = csv.shift)
          pos = record_end(pos, csv.line)
          add(row)
          next unless @last_quote.nil? || pos > @last_quote

          # No quote character is left: quote-free mode gives the same rows, faster.
          parse_string(@text.byteslice(pos, @end - pos), pos, quoting: false) if pos < @end
          return nil
        end
        nil
      rescue CSV::MalformedCSVError
        skip_blank_lines(pos)
      end

      # A recovery or quote-free pass over a separate string. csv has nothing to reject here (no quotes,
      # or the open quote was closed); if it ever does, the rest is dropped and the counts become lower
      # bounds.
      def parse_string(str, base, quoting:, guard: true)
        @fields = 0
        feed = Feed.new(str, base, self, guard: guard, chunk_limit: @chunk_limit)
        csv = CSV.new(feed, **csv_options(quoting))
        while (row = csv.shift)
          add(row)
        end
      rescue CSV::MalformedCSVError
        @complete = false
      end

      # Byte offset just past the record csv returned (csv.line is its raw text, line break included).
      def record_end(pos, line) = skip_blank_lines(pos) + line.bytesize

      # csv skips empty lines (skip_blanks) and leaves them out of csv.line. After normalisation each
      # is a single LF.
      def skip_blank_lines(pos)
        return pos unless @text.getbyte(pos) == LF

        [@text.byteindex(NOT_LF, pos) || @end, @end].min
      end

      def add(row)
        @fields = 0
        @rows_seen += 1
        checkpoint if (@rows_seen % CHECK_EVERY).zero?
        last = row.rindex { |f| f && f.count(BLANK) != f.bytesize }
        return unless last # blank record: not kept, not counted

        width = last + 1
        if @count < @keep_rows
          @kept << row.first(@keep_columns).map { |f| cell(f) }
          @widths << [width, @keep_columns].min
        end
        @max_width = width if width > @max_width
        @count += 1
        throw :enough if @kept_only && @count >= @keep_rows
      end

      def cell(field)
        return RawCell.new("", false) if field.nil?
        return RawCell.new(field, false) if field.bytesize <= @raw_cap

        RawCell.new(field.byteslice(0, @raw_cap).scrub(""), true)
      end
    end
  end
end
