# frozen_string_literal: true

module CsvPreview
  # What was read from a source: cleaned header and data cells plus counts. An immutable value object;
  # two samples are equal when every member is equal. Built by {CsvPreview.sample}.
  #
  # Strings are decoded, sanitised and cut to at most `max_cell_chars` grapheme clusters (the last
  # being "…" when the cell was longer), but not yet fitted to column widths. Short rows are padded
  # with "". See docs/spec/README.md section 9.3.
  class Sample
    # @return [Array<String>, nil] header cells, nil when no header row was detected or requested
    attr_reader :headers
    # @return [Array<Array<String>>] up to max_rows data rows, each exactly {#column_count} cells
    attr_reader :rows
    # @return [Integer] the widest of the header and the shown rows, at most max_columns
    attr_reader :column_count
    # @return [Integer] the widest row seen in the bytes read, ignoring trailing blank fields
    attr_reader :total_columns
    # @return [Integer, nil] data rows in the whole file, or nil when it was not fully read
    attr_reader :total_rows
    # @return [Integer] data rows seen within the bytes read (a lower bound when total_rows is nil)
    attr_reader :rows_read
    # @return [Array<Symbol>] :number or :text per kept column
    attr_reader :column_kinds
    # @return [String] the delimiter used
    attr_reader :delimiter
    # @return [String] the source encoding detected or used
    attr_reader :encoding

    # @api private
    def initialize(headers:, rows:, column_count:, total_columns:, total_rows:, rows_read:, rows_truncated:,
                   columns_truncated:, column_kinds:, delimiter:, encoding:, empty:)
      @headers = headers && freeze_strings(headers)
      @rows = rows.map { |row| freeze_strings(row) }.freeze
      @column_count = column_count
      @total_columns = total_columns
      @total_rows = total_rows
      @rows_read = rows_read
      @rows_truncated = rows_truncated ? true : false
      @columns_truncated = columns_truncated ? true : false
      @column_kinds = column_kinds.dup.freeze
      @delimiter = delimiter.dup.freeze
      @encoding = encoding.dup.freeze
      @empty = empty ? true : false
      freeze
    end

    # @return [Boolean] whether data rows were left out (or the file was not fully read)
    def rows_truncated? = @rows_truncated

    # @return [Boolean] whether columns were left out
    def columns_truncated? = @columns_truncated

    # @return [Boolean] true when the bytes read have no non-blank cells
    def empty? = @empty

    # @param other [Object]
    # @return [Boolean] whether `other` is a Sample with equal members
    def ==(other)
      other.is_a?(Sample) && state == other.state
    end
    alias eql? ==

    # @return [Integer] consistent with {#==}, so equal samples can be Hash keys
    def hash = [Sample, *state].hash

    # @return [String] the header, counts, delimiter and encoding (not the data rows)
    def inspect
      "#<CsvPreview::Sample headers=#{headers.inspect} rows=#{rows.size} column_count=#{column_count} " \
        "total_columns=#{total_columns} rows_read=#{rows_read} total_rows=#{total_rows.inspect} " \
        "delimiter=#{delimiter.inspect} encoding=#{encoding}>"
    end

    protected

    def state
      [headers, rows, column_count, total_columns, total_rows, rows_read, @rows_truncated, @columns_truncated,
       column_kinds, delimiter, encoding, @empty]
    end

    private

    def freeze_strings(cells) = cells.map { |cell| cell.frozen? ? cell : cell.dup.freeze }.freeze
  end
end
