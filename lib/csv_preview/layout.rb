# frozen_string_literal: true

module CsvPreview
  # Everything about a preview except the pixels: which columns and rows are shown, their widths, the
  # exact display strings, the footer and the output size (rendering.md section 6). It does all the
  # measuring, with one libvips text call per drawn string, and keeps the rendered text for the
  # painter. Built by {CsvPreview.layout}; for debugging and tests, and its shape may change before 1.0.
  #
  # Internally every value is device px. {Column#width} is the one value reported in logical px.
  class Layout
    # Every string the image shows that does not come from the file, in one place so translation is a
    # one-file change. Counts are formatted with {Layout.format_count}.
    STRINGS = {
      empty: "Empty file",
      nothing_read: "No data in the first %<size>s",
      no_rows: "No rows",
      row: "row",
      rows: "rows",
      column: "column",
      columns: "columns",
      count: "%<count>s %<noun>s",
      count_of: "%<shown>s of %<total>s %<noun>s",
      count_at_least: "%<count>s+ %<noun>s",
      count_of_at_least: "%<shown>s of %<total>s+ %<noun>s",
      separator: " · ",
      megabytes: "%<size>s MB",
      kilobytes: "%<size>s KB",
      byte: "%<size>s byte",
      bytes: "%<size>s bytes"
    }.freeze

    # The true minus sign (U+2212) that number cells show instead of a hyphen-minus.
    MINUS = "−"
    # Bytes in a kibibyte and a mebibyte, for the "No data in the first 2 MB" message.
    KIB = 1_024
    # (see KIB)
    MIB = 1_048_576

    # One fully visible column, or the peek column.
    #
    # @!attribute index [Integer] the column's index in the {Sample}
    # @!attribute kind [Symbol] :number or :text
    # @!attribute align [Symbol] :left or :right (always :left for the peek column)
    # @!attribute width [Float] logical px, `width_px / scale`
    # @!attribute width_px [Integer] device px, padding included (for the peek: up to the frame)
    # @!attribute x_px [Integer] device px from the image's left edge
    Column = Data.define(:index, :kind, :align, :width, :width_px, :x_px)

    # @api private
    # A rectangle in device px.
    Box = Data.define(:x, :y, :width, :height)

    # @api private
    # One rendered string at its final device-px position: the image's top-left corner is at
    # (`x`, `y`), and the painter clips it to `box` (its cell, or the footer or message band, without
    # rules). The painter needs nothing else from {Text}.
    Placement = Data.define(:run, :x, :y, :box)

    # @api private
    # Device-px bands and rules for the painter (rendering.md 2.3). `body_rows` is the number of row
    # bands below the header (`rows_shown`, or the message rows of the special layouts); row rules
    # are drawn only between data rows, so at the top of rows 1 to `rows_shown` - 1. `footer_top` is
    # nil without a footer, `fade` nil without a peek column.
    Geometry = Data.define(:frame, :header_height, :row_height, :footer_height, :header_rule, :row_rule,
                           :footer_rule, :body_rows, :footer_top, :fade)

    # @return [Sample]
    attr_reader :sample
    # @return [Integer] fully visible columns (the peek column is not counted)
    attr_reader :visible_columns
    # @return [Array<Column>] the fully visible columns, left to right
    attr_reader :columns
    # @return [Column, nil] the partly visible column under the fade, drawn left-aligned
    attr_reader :peek_column
    # @return [Integer] data rows drawn
    attr_reader :rows_shown
    # @return [String, nil] what the footer says (the drawn footer is cut with "…" if the image is
    #   narrower), nil when nothing is hidden and no footer is drawn
    attr_reader :footer_text
    # @return [String, nil] "Empty file", "No data in the first 2 MB", "No rows" or nil
    attr_reader :message
    # @return [Integer] output width in pixels
    attr_reader :width_px
    # @return [Integer] output height in pixels
    attr_reader :height_px
    # @return [Integer]
    attr_reader :scale
    # @return [Theme]
    attr_reader :theme
    # @return [Integer] libvips text calls made for this layout (instrumentation for tests)
    attr_reader :text_calls
    # @api private
    # @return [Array<Placement>] every drawn string in paint order: column by column (each visible
    #   column's header, then its cells), then the peek column's header and cells, then the message,
    #   then the footer
    attr_reader :placements
    # @api private
    # @return [Geometry]
    attr_reader :geometry
    # @api private
    # @return [Integer] the `max_width_px` cap the layout was built under (the painter checks it again)
    attr_reader :max_width_px
    # @api private
    # @return [Integer] the `max_height_px` cap
    attr_reader :max_height_px

    # @api private
    # @param sample [Sample]
    # @param config [Configuration] a resolved snapshot
    # @param theme [Theme]
    # @param deadline [Deadline]
    # @return [Layout]
    # @raise [RenderFailed] when libvips cannot draw text, or the result would break the size caps
    # @raise [TimeoutExceeded]
    def self.build(sample, config:, theme:, deadline:)
      Builder.new(sample, config, theme, deadline).call
    end

    # @param index [Integer] 0-based column index
    # @return [String] spreadsheet column letters: A ... Z, AA, AB, ...
    def self.column_letters(index)
      letters = +""
      n = index + 1
      while n.positive?
        n, r = (n - 1).divmod(26)
        letters.prepend((r + 65).chr)
      end
      letters
    end

    # @param n [Integer]
    # @return [String] ASCII digits with "," every three, independent of locale
    def self.format_count(n)
      n.to_s.reverse.scan(/\d{1,3}/).join(",").reverse
    end

    # @param bytes [Integer]
    # @return [String] whole or one-decimal MB (of 1,048,576 bytes), KB below that, bytes below 1 KB
    def self.format_size(bytes)
      if bytes >= MIB
        format(STRINGS[:megabytes], size: one_decimal(bytes, MIB))
      elsif bytes >= KIB
        format(STRINGS[:kilobytes], size: one_decimal(bytes, KIB))
      else
        format(STRINGS[bytes == 1 ? :byte : :bytes], size: bytes)
      end
    end

    def self.one_decimal(value, unit)
      whole, tenth = (value * 10.0 / unit).round.divmod(10)
      tenth.zero? ? format_count(whole) : "#{format_count(whole)}.#{tenth}"
    end
    private_class_method :one_decimal

    # @api private
    def initialize(sample:, visible_columns:, columns:, peek_column:, rows_shown:, footer_text:, message:,
                   width_px:, height_px:, scale:, theme:, text_calls:, placements:, geometry:, texts:, lookup:,
                   max_width_px:, max_height_px:)
      @sample = sample
      @visible_columns = visible_columns
      @columns = columns.freeze
      @peek_column = peek_column
      @rows_shown = rows_shown
      @footer_text = footer_text
      @message = message
      @width_px = width_px
      @height_px = height_px
      @scale = scale
      @theme = theme
      @text_calls = text_calls
      @placements = placements.freeze
      @geometry = geometry
      @texts = texts.freeze
      @lookup = lookup.freeze
      @max_width_px = max_width_px
      @max_height_px = max_height_px
      freeze
    end

    # @param row [Integer] 0-based data row
    # @param col [Integer] 0-based column index
    # @return [String, nil] the display string of a drawn cell (with "…" and U+2212 where applied; for
    #   the peek column, untruncated), "" for a blank cell, nil outside the drawn area
    def cell_text(row, col)
      @texts[[:cell, row, col]]
    end

    # @param col [Integer]
    # @return [String, nil] the same for the header (column letters when the file has no header row)
    def header_text(col)
      @texts[[:header, col]]
    end

    # @api private
    # @return [Placement, nil] nil when the cell draws nothing or is not drawn
    def cell_placement(row, col) = @lookup[[:cell, row, col]]

    # @api private
    # @return [Placement, nil]
    def header_placement(col) = @lookup[[:header, col]]

    # @api private
    # @return [Placement, nil]
    def footer_placement = @lookup[:footer]

    # @api private
    # @return [Placement, nil]
    def message_placement = @lookup[:message]

    # @return [String] a summary of the sizes and counts (never cell text or libvips objects)
    def inspect
      "#<CsvPreview::Layout #{width_px}x#{height_px} visible_columns=#{visible_columns} " \
        "peek_column=#{peek_column&.index.inspect} rows_shown=#{rows_shown} footer_text=#{footer_text.inspect} " \
        "message=#{message.inspect} text_calls=#{text_calls}>"
    end

    # Runs the algorithm of rendering.md section 6 once. Not shared between threads.
    # @api private
    class Builder
      # One measured column: display strings, the runs that measured them, and (for visible columns)
      # the runs fitted to the column, which are drawn.
      Measured = Struct.new(:index, :kind, :align, :header_style, :cell_style, :header, :header_run, :cells,
                            :runs, :natural, :header_fit, :fits)

      def initialize(sample, config, theme, deadline)
        @sample = sample
        @config = config
        @theme = theme
        @deadline = deadline
        @scale = config.scale
        @renderer = Text::Renderer.new(deadline: deadline)
        @styles = theme.styles(scale: @scale, font: config.font)
        @metrics = Hash.new { |cache, style| cache[style] = Text.metrics(style) }
        tokens!
      end

      def call
        return empty_layout if @sample.empty?

        @n = @sample.column_count
        @rows_shown = rows_shown
        @message = STRINGS[:no_rows] if @sample.rows.empty?
        @measured = []
        measure_until_overflow
        arrange
        footer
        fill
        truncate
        finish
      end

      private

      def tokens!
        @frame = @theme.rule_px(:frame_width, @scale)
        @header_rule = @theme.rule_px(:header_rule_width, @scale)
        @row_rule = @theme.rule_px(:row_rule_width, @scale)
        @footer_rule = @theme.rule_px(:footer_rule_width, @scale)
        @header_h = px(:header_height)
        @row_h = px(:row_height)
        @footer_h = px(:footer_height)
        @pad = px(:cell_padding)
        @edge = px(:edge_padding)
        @inset = @edge - @pad
        @fade_w = px(:fade_width)
        @peek_w = px(:peek_width)
        @min_col = px(:min_column_width)
        @max_col = px(:max_column_width)
        @min_w = px(:min_width)
        @w_cap = [px(:max_width), @config.max_width_px].min
      end

      def px(token) = @theme.px(token, @scale)

      def check! = @deadline.check!(:layout)

      # Step 2 (6.3): the footer is always reserved when counting.
      def rows_shown
        fit = (@config.max_height_px - (2 * @frame) - @header_h - @footer_h) / @row_h
        [@sample.rows.size, [fit, 0].max].min
      end

      # Step 3 (6.4): natural widths, left to right, stopping at the first column that overflows.
      def measure_until_overflow
        x = @inset
        (0...@n).each do |j|
          x += measured(j).natural
          break if x + @inset > @w_cap
        end
        @all_fit = @measured.size == @n && x + @inset <= @w_cap
      end

      def measured(j)
        @measured[j] ||= measure(j)
      end

      def measure(j)
        check!
        kind = @sample.column_kinds[j]
        number = kind == :number
        m = Measured.new(index: j, kind: kind, align: number ? :right : :left,
                         header_style: number ? @styles.header_number : @styles.header,
                         cell_style: number ? @styles.body_number : @styles.body)
        m.header = header_display(j)
        m.header_run = render(m.header, m.header_style, m.align)
        m.cells = Array.new(@rows_shown) { |r| cell_display(@sample.rows[r][j], kind) }
        m.runs = m.cells.map do |cell|
          check!
          render(cell, m.cell_style, m.align)
        end
        m.natural = natural_width(m)
        m
      end

      def natural_width(m)
        cells = m.runs.compact.map(&:extent).max || 0
        header = m.header_run&.extent || 0
        if m.kind == :number
          [[cells, [header, @max_col - (2 * @pad)].min].max + (2 * @pad), @min_col].max
        else
          ([cells, header].max + (2 * @pad)).clamp(@min_col, @max_col)
        end
      end

      # 6.2 and 4.1: column letters when there is no header row; blank for columns past the header.
      def header_display(j)
        return Layout.column_letters(j) if @sample.headers.nil?

        @sample.headers[j] || ""
      end

      # 4.1 item 2: in a number column, a cell that is a number has its hyphens drawn as U+2212.
      def cell_display(cell, kind)
        return cell unless kind == :number && @theme.true_minus && cell.include?("-")

        CellKind.cell(cell) == :number ? cell.tr("-", MINUS) : cell
      end

      def render(string, style, align) = @renderer.render(string, style: style, align: align)

      # Step 4 (6.5): visible columns, the peek column and the width before step 5.
      def arrange
        if @all_fit
          @widths = @measured.map(&:natural)
          @peek = nil
          @width = (2 * @inset) + @widths.sum
          return
        end

        @width = @w_cap
        @widths, @peek = visible_widths(@width - @frame - @fade_w)
        cap_peek if @peek
      end

      # Columns whose text ends before the fade starts are fully visible; the first that is not is the
      # peek. Column 0 is always visible, clamped when it alone is too wide (the only case where a
      # number is truncated).
      def visible_widths(limit)
        widths = []
        x = @inset
        while widths.size < @n
          natural = measured(widths.size).natural
          break if x + natural - @pad > limit

          widths << natural
          x += natural
        end
        return [widths, widths.size < @n ? widths.size : nil] unless widths.empty?
        return [[@width - (2 * @inset)], nil] if @n == 1

        measured(1)
        [[limit - @inset + @pad], 1]
      end

      # The peek gets at most peek_width; any more space goes to the visible columns.
      def cap_peek
        space = (@width - @frame) - (@inset + @widths.sum)
        distribute(space - @peek_w) if space > @peek_w
      end

      # Shares `extra` px evenly across the visible columns, the remainder to the last.
      def distribute(extra)
        share, rest = extra.divmod(@widths.size)
        @widths.map! { |w| w + share }
        @widths[-1] += rest
      end

      # Step 7 (6.8), rendered before step 5 because its width can widen a small table.
      def footer
        visible = @widths.size
        rows_hidden = @rows_shown < @sample.rows.size || @sample.rows_truncated?
        total_columns = [@sample.total_columns, visible].max
        columns_hidden = visible < total_columns
        return unless rows_hidden || columns_hidden

        @footer_text = rows_part(rows_hidden) + STRINGS[:separator] +
                       count_part(visible, total_columns, columns_hidden, :column, :columns)
        @footer_run = render(@footer_text, @styles.footer, :left)
      end

      def rows_part(hidden)
        shown = Layout.format_count(@rows_shown)
        return count_part(@rows_shown, @rows_shown, false, :row, :rows) unless hidden

        total = @sample.total_rows
        if total
          format(STRINGS[:count_of], shown: shown, total: Layout.format_count(total), noun: STRINGS[:rows])
        elsif @sample.rows_read > @rows_shown
          format(STRINGS[:count_of_at_least], shown: shown, total: Layout.format_count(@sample.rows_read),
                                              noun: STRINGS[:rows])
        else
          format(STRINGS[:count_at_least], count: shown, noun: STRINGS[:rows])
        end
      end

      def count_part(shown, total, hidden, singular, plural)
        if hidden
          format(STRINGS[:count_of], shown: Layout.format_count(shown), total: Layout.format_count(total),
                                     noun: STRINGS[plural])
        else
          format(STRINGS[:count], count: Layout.format_count(shown), noun: STRINGS[shown == 1 ? singular : plural])
        end
      end

      # Step 5 (6.6): small tables fill a minimum width, or the footer's width; never above the cap.
      def fill
        footer_need = @footer_run ? @footer_run.extent + (2 * @edge) : 0
        target = [[@width, @min_w, footer_need].max, @w_cap].min
        if target > @width
          distribute(target - @width)
          @width = target
        end
        @footer_run = fit(@footer_run, @styles.footer, @width - (2 * @edge)) if @footer_run
      end

      def fit(run, style, max_extent) = @renderer.fit(run, style: style, max_extent: max_extent)

      # Step 6 (6.7): every visible header and cell is cut to its column's text width.
      def truncate
        @widths.each_with_index do |width, j|
          check!
          m = @measured[j]
          max = width - (2 * @pad)
          m.header_fit = fit(m.header_run, m.header_style, max)
          m.fits = m.runs.map do |run|
            check!
            fit(run, m.cell_style, max)
          end
        end
      end

      def finish
        @texts = {}
        @lookup = {}
        @placements = []
        columns = place_columns
        peek = place_peek
        body_rows = @message ? 1 : @rows_shown
        footer_top = @frame + @header_h + (body_rows * @row_h)
        place_message(@frame + @header_h, @row_h, @edge) if @message
        place_footer(footer_top) if @footer_run
        height = (2 * @frame) + @header_h + (body_rows * @row_h) + (@footer_text ? @footer_h : 0)
        fade = peek && Box.new(x: @width - @frame - @fade_w, y: @frame, width: @fade_w,
                               height: @header_h + (@rows_shown * @row_h))
        layout(visible_columns: columns.size, columns: columns, peek_column: peek, rows_shown: @rows_shown,
               footer_text: @footer_text, message: @message, width_px: @width, height_px: height,
               geometry: geometry(body_rows, @footer_text ? footer_top : nil, fade))
      end

      def place_columns
        x = @inset
        @widths.each_with_index.map do |width, j|
          m = @measured[j]
          place_column(m, m.header_fit, m.fits, x, width) { |run| run.x_in(x + @pad, x + width - @pad) }
          column = Column.new(index: j, kind: m.kind, align: m.align, width: width / @scale.to_f, width_px: width,
                              x_px: x)
          x += width
          column
        end
      end

      # 6.5 item 4: the peek is drawn left-aligned whatever its kind, untruncated, and clipped at the
      # frame. A right-aligned run (a number, measured right-aligned) has its ink start at the text edge.
      def place_peek
        return nil unless @peek

        m = measured(@peek)
        x = @inset + @widths.sum
        width = (@width - @frame) - x
        place_column(m, m.header_run, m.runs, x, width) { |run| x + @pad + (run.align == :left ? run.xoffset : 0) }
        Column.new(index: m.index, kind: m.kind, align: :left, width: width / @scale.to_f, width_px: width, x_px: x)
      end

      # Records the display strings and placements of one column's header and cells. `header_run` and
      # `runs` are what is drawn: fitted runs for a visible column, the measured runs for the peek.
      def place_column(m, header_run, runs, x, width, &place_x)
        key = [:header, m.index]
        @texts[key] = text_for(m.header, m.header_run, header_run)
        if header_run
          box = Box.new(x: x, y: @frame, width: width, height: @header_h - @header_rule)
          add(key, header_run, place_x.call(header_run), band_y(header_run, m.header_style, @frame, @header_h), box)
        end
        runs.each_with_index do |run, r|
          key = [:cell, r, m.index]
          @texts[key] = text_for(m.cells[r], m.runs[r], run)
          next unless run

          top = @frame + @header_h + (r * @row_h)
          rule = r.zero? ? 0 : @row_rule
          box = Box.new(x: x, y: top + rule, width: width, height: @row_h - rule)
          add(key, run, place_x.call(run), band_y(run, m.cell_style, top, @row_h), box)
        end
      end

      # The display string: as built for a blank or untruncated string, the drawn run's when it was cut
      # with "…", and "" when not even "…" fits.
      def text_for(display, full, drawn)
        return display if full.nil? || full.equal?(drawn)

        drawn ? drawn.string : ""
      end

      def place_message(top, height, x_left)
        style = @styles.message
        run = fit(render(@message, style, :left), style, @width - (2 * @edge))
        return unless run

        x = x_left ? x_left + run.xoffset : ((@width - run.image.width) / 2.0).round
        box = Box.new(x: @frame, y: top, width: @width - (2 * @frame), height: height)
        add(:message, run, x, band_y(run, style, top, height), box)
      end

      def place_footer(top)
        run = @footer_run
        box = Box.new(x: @frame, y: top + @footer_rule, width: @width - (2 * @frame), height: @footer_h - @footer_rule)
        add(:footer, run, @edge + run.xoffset, band_y(run, @styles.footer, top, @footer_h), box)
      end

      # 4.6: every run in a band shares one baseline, with cap height centred in the band.
      def band_y(run, style, top, height) = @metrics[style].line_top(top, height) + run.yoffset

      def add(key, run, x, y, box)
        placement = Placement.new(run: run, x: x, y: y, box: box)
        @lookup[key] = placement
        @placements << placement
      end

      def geometry(body_rows, footer_top, fade)
        Geometry.new(frame: @frame, header_height: @header_h, row_height: @row_h, footer_height: @footer_h,
                     header_rule: @header_rule, row_rule: @row_rule, footer_rule: @footer_rule,
                     body_rows: body_rows, footer_top: footer_top, fade: fade)
      end

      # 6.9: the empty-file layout. The message is centred in the body; the body loses rows, down to
      # one, when the height cap is small.
      def empty_layout
        @width = [@min_w, @w_cap].min
        body_rows = @theme.empty_body_rows
        body_rows -= 1 while body_rows > 1 && (2 * @frame) + @header_h + (body_rows * @row_h) > @config.max_height_px
        @message = if @sample.total_rows
                     STRINGS[:empty]
                   else
                     format(STRINGS[:nothing_read], size: Layout.format_size(@config.max_input_bytes))
                   end
        @texts = {}
        @lookup = {}
        @placements = []
        place_message(@frame + @header_h, body_rows * @row_h, nil)
        layout(visible_columns: 0, columns: [], peek_column: nil, rows_shown: 0, footer_text: nil, message: @message,
               width_px: @width, height_px: (2 * @frame) + @header_h + (body_rows * @row_h),
               geometry: geometry(body_rows, nil, nil))
      end

      # 6.10: the size never exceeds the caps; a bug that would break them fails loudly instead.
      def layout(width_px:, height_px:, **members)
        unless width_px.positive? && height_px.positive? && width_px <= @config.max_width_px &&
               height_px <= @config.max_height_px
          raise RenderFailed, "layout of #{width_px} by #{height_px} px breaks the size caps " \
                              "(#{@config.max_width_px} by #{@config.max_height_px} px). This is a bug in " \
                              "csv_preview; please report it at #{Help::ISSUES}"
        end

        Layout.new(sample: @sample, width_px: width_px, height_px: height_px, scale: @scale, theme: @theme,
                   text_calls: @renderer.calls, placements: @placements, texts: @texts, lookup: @lookup,
                   max_width_px: @config.max_width_px, max_height_px: @config.max_height_px, **members)
      end
    end
    private_constant :Builder
  end
end
