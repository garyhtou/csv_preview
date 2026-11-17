# frozen_string_literal: true

module CsvPreview
  # The only code that calls `Vips::Image.text`. One call per string both measures and draws it: the
  # returned image is kept in a {Run} and composited later, so measuring and drawing can never
  # disagree (rendering.md section 4). The one exception: on hosts where libvips draws subpixel
  # (coloured) edges, a string that can contain a colour glyph is drawn a second time, in a
  # contrasting colour with the same layout, to tell its emoji from its text (rendering.md section 9).
  #
  # ruby-vips is required lazily, on first use ({supported?}, {warm_up!} or the first render), never
  # when this file is loaded, so the gem loads on hosts without libvips.
  #
  # Text is always greyscale-antialiased: on hosts where libvips draws subpixel (coloured) edges, each
  # run is corrected after drawing (rendering.md section 9).
  #
  # Process-global state (font registration, the feature probe, the antialiasing probe, the font
  # self-check, {Metrics} and ellipsis extents) is computed once under a Mutex. Everything else lives in
  # a per-render {Renderer}.
  # @api private
  module Text
    # Width of the box right-aligned strings are laid out in. Pango puts the line's logical right
    # edge exactly here, which is how the logical width is recovered (rendering.md 4.3).
    RIGHT_BOX = 32_768
    ELLIPSIS = "\u2026"

    FONT_DIR = File.expand_path("../../fonts", __dir__)
    REGULAR = File.join(FONT_DIR, "Inter-Regular.ttf")
    SEMIBOLD = File.join(FONT_DIR, "Inter-SemiBold.ttf")
    BUNDLED_FILES = [REGULAR, SEMIBOLD].freeze

    # Same set as GLib's g_markup_escape_text.
    ESCAPES = { "&" => "&amp;", "<" => "&lt;", ">" => "&gt;", '"' => "&quot;", "'" => "&apos;" }.freeze
    ESCAPE_PATTERN = /[&<>"']/

    # Strings with no ink: libvips would raise "no text to render" for them (rendering.md 4.4).
    BLANK = /\A[\p{Space}\p{Default_Ignorable_Code_Point}]*\z/
    NO_TEXT = "no text to render"
    INVALID_MARKUP = "invalid markup"

    # Self-check probes at 100 px, right-aligned, and the extents accepted as the bundled Inter 4.1
    # (rendering.md 5.4). Inter measures about 644 px for "0000000000" with tabular figures. DejaVu Sans
    # and Verdana measure 634 px there, so a second probe draws "1111111111" with the default figures:
    # Inter's are proportional (about 406 px), theirs are tabular (about 630 px).
    SELF_CHECK_EXTENT = (630..660)
    SELF_CHECK_PROPORTIONAL_EXTENT = (380..440)
    # Ends messages about the libvips, Pango or font installation.
    INSTALL_HINT = "see #{Help::INSTALLATION}"
    # Ends every "failed to draw text" message; libvips' own message stays on the error's cause.
    DRAW_HINT = "check the libvips, Pango and font installation, #{INSTALL_HINT}"
    ALIGNMENTS = %i[left right].freeze
    PROCESS_CACHE_LIMIT = 256

    # Characters that can draw as a colour glyph (an emoji) instead of in the markup colour:
    # pictographs, emoji-presentation characters, skin-tone modifiers, VS16, the keycap mark and emoji
    # tag characters (rendering.md section 9).
    COLOR_GLYPH = /\p{Extended_Pictographic} | \p{Emoji_Presentation} | \p{Emoji_Modifier}
                  | [\u{FE0F}\u{20E3}\u{E0020}-\u{E007F}]/x
    # Antialiasing probe (rendering.md section 9): mid-grey text composited over white keeps its
    # channels equal when antialiasing is greyscale (largest summed channel difference 0, measured on
    # libvips 8.15 and 8.18). Subpixel antialiasing (rgb, bgr or vrgb) gives its edges about 160.
    SUBPIXEL_PROBE = "Hamburgefonstiv"
    SUBPIXEL_PROBE_COLOR = "#808080"
    SUBPIXEL_SPREAD = 24

    # Font and colour of one string. Sizes are device px (already multiplied by `scale`). The values
    # are interpolated into Pango markup attributes, so they are validated here as well as in the
    # theme.
    #
    # @!attribute family [String] Pango family list, for example "Inter"
    # @!attribute fontfile [String, nil] font file to register, nil for system fonts (`font:` option)
    # @!attribute size_px [Integer] font size in device px
    # @!attribute weight [Integer] numeric weight, 400 regular, 600 semibold
    # @!attribute color [String] "#RRGGBB"
    # @!attribute tnum [Boolean] request tabular figures
    Style = Data.define(:family, :fontfile, :size_px, :weight, :color, :tnum) do
      def initialize(family:, fontfile:, size_px:, weight:, color:, tnum:)
        unless family.is_a?(String) && !family.strip.empty? && !family.match?(/[[:cntrl:]]/)
          raise ArgumentError, "family must be a non-empty String without control characters"
        end
        raise ArgumentError, "fontfile must be nil or a String" unless fontfile.nil? || fontfile.is_a?(String)
        raise ArgumentError, "size_px must be a positive Integer" unless size_px.is_a?(Integer) && size_px.positive?
        unless weight.is_a?(Integer) && (100..1000).cover?(weight)
          raise ArgumentError, "weight must be an Integer from 100 to 1000"
        end
        raise ArgumentError, "color must be #RRGGBB" unless color.is_a?(String) && color.match?(/\A#\h{6}\z/)
        raise ArgumentError, "tnum must be true or false" unless [true, false].include?(tnum)

        super
      end
    end

    # One rendered string: the image is both the measurement and the drawing.
    #
    # @!attribute string [String] the string drawn (NUL and invalid UTF-8 replaced by U+FFFD)
    # @!attribute image [Vips::Image] 4-band sRGB image cropped to the ink rectangle
    # @!attribute xoffset [Integer] ink left relative to the layout origin
    # @!attribute yoffset [Integer] ink top relative to the line top
    # @!attribute extent [Integer] device px the string needs: for left-aligned runs from the origin
    #   to the ink's right edge, for right-aligned runs from the ink's left edge to the logical right edge
    # @!attribute align [Symbol] :left or :right, as requested
    Run = Data.define(:string, :image, :xoffset, :yoffset, :extent, :align) do
      # @return [Boolean] true when a right-aligned string turned out to be a right-to-left paragraph
      #   (Pango swapped the alignment); it is measured and placed by its ink (rendering.md 4.3)
      def right_to_left?
        align == :right && xoffset + image.width <= RIGHT_BOX / 2
      end

      # @param left [Integer] left edge of the text area (device px)
      # @param right [Integer] right edge of the text area (device px)
      # @return [Integer] x of the image's left edge
      def x_in(left, right)
        if align == :left
          left + xoffset
        elsif right_to_left?
          right - image.width
        else
          right - RIGHT_BOX + xoffset
        end
      end
    end

    # Cap-height metrics of one style, from rendering "H" (rendering.md 4.6).
    Metrics = Data.define(:cap_top, :cap_height) do
      # @return [Integer] y of the line top that centres cap height in the band; a run is drawn at
      #   `line_top + run.yoffset`, so every run in the band shares one baseline
      def line_top(band_top, band_height)
        band_top + ((band_height - cap_height) / 2.0).round - cap_top
      end
    end

    # Per-render text cache: repeated strings cost one libvips call (two for a string that
    # {Text.text_calls} says is drawn twice). Counts every libvips call it makes and checks the deadline
    # whenever the count reaches the next multiple of 32, so a string that adds two calls cannot step
    # over a checkpoint. Not shared between threads.
    class Renderer
      DEADLINE_EVERY = 32

      # @return [Integer] libvips text calls made by this renderer
      attr_reader :calls

      # @param deadline [#check!, nil]
      def initialize(deadline: nil)
        @deadline = deadline
        @calls = 0
        @next_deadline_check = DEADLINE_EVERY
        @cache = {}
      end

      # @param string [String]
      # @param style [Style]
      # @param align [Symbol] :left or :right
      # @return [Run, nil] nil when the string is blank: nothing is drawn and its extent is 0
      # @raise [RenderFailed] when libvips is missing, lacks text support, or fails to draw
      def render(string, style:, align:)
        raise ArgumentError, "align must be :left or :right" unless ALIGNMENTS.include?(align)
        raise ArgumentError, "style must be a CsvPreview::Text::Style" unless style.is_a?(Style)

        key = [string, style, align]
        return @cache[key] if @cache.key?(key)

        @cache[key] = draw(Text.display_string(string), style, align)
      end

      # Ellipsis truncation by measuring (rendering.md 4.5): the longest prefix of whole grapheme
      # clusters, trailing spaces removed, plus U+2026 that fits in `max_extent`.
      #
      # @param run [Run, nil] the full string's run
      # @param style [Style] the style `run` was rendered with
      # @param max_extent [Integer] device px available
      # @return [Run, nil] `run` itself when it fits; nil when even the ellipsis alone does not fit
      def fit(run, style:, max_extent:)
        return run if run.nil? || run.extent <= max_extent

        align = run.align
        ellipsis = Text.ellipsis_extent(style, align)
        return nil if ellipsis > max_extent

        clusters = run.string.grapheme_clusters
        probes = {}
        fits = lambda do |k|
          next true if k.zero?

          probe = probes[k] ||= draw(clusters[0, k].join.rstrip + ELLIPSIS, style, align)
          !probe.nil? && probe.extent <= max_extent
        end

        n = clusters.size
        guess = ((max_extent - ellipsis) * n / run.extent.to_f).floor.clamp(0, n - 1)
        k = largest_fitting(guess, n - 1, &fits)
        k.zero? ? render(ELLIPSIS, style: style, align: align) : probes.fetch(k)
      end

      private

      def draw(text, style, align)
        return nil if text.match?(BLANK)

        Text.prepare!(style)
        @calls += Text.text_calls(text)
        if @calls >= @next_deadline_check
          @deadline&.check!(:text)
          @next_deadline_check = ((@calls / DEADLINE_EVERY) + 1) * DEADLINE_EVERY
        end
        Text.build_run(text, style, align)
      end

      # Gallop from `guess` (up if it fits, down otherwise) with steps 1, 2, 4, ... until the answer is
      # bracketed, then binary-search the bracket. fits(0) is always true.
      def largest_fitting(guess, max_k)
        if yield(guess)
          lo = guess
          hi = max_k
          step = 1
          while lo + step <= max_k
            unless yield(lo + step)
              hi = lo + step - 1
              break
            end
            lo += step
            step *= 2
          end
        else
          lo = 0
          hi = guess - 1
          step = 1
          while hi - step + 1 >= 0
            candidate = hi - step + 1
            if yield(candidate)
              lo = candidate
              break
            end
            hi = candidate - 1
            step *= 2
          end
        end

        while lo < hi
          mid = (lo + hi + 1) / 2
          yield(mid) ? lo = mid : hi = mid - 1
        end
        lo
      end
    end

    @load_lock = Mutex.new
    @warm_lock = Mutex.new
    @cache_lock = Mutex.new
    @support_checked = false
    @support_problem = nil
    @warm = false
    @tnum = true
    @subpixel = false
    @bundled_font_active = nil
    @metrics = {}
    @ellipsis = {}

    class << self
      # @param string [String]
      # @return [String] `string` with & < > " ' replaced by markup entities
      def escape(string)
        string.gsub(ESCAPE_PATTERN, ESCAPES)
      end

      # Renders one string with one libvips call. Layout uses a {Renderer} instead, for caching.
      #
      # @param string [String]
      # @param style [Style]
      # @param align [Symbol] :left or :right
      # @return [Run, nil] nil when the string is blank
      # @raise [RenderFailed]
      def render(string, style:, align:)
        Renderer.new.render(string, style: style, align: align)
      end

      # @param run [Run, nil]
      # @param style [Style]
      # @param max_extent [Integer]
      # @return [Run, nil] see {Renderer#fit}
      # @raise [RenderFailed]
      def fit(run, style:, max_extent:)
        Renderer.new.fit(run, style: style, max_extent: max_extent)
      end

      # Cheap capability check that never renders: ruby-vips loads, libvips is 8.12 or newer and was
      # built with the text operation. Memoised.
      #
      # @return [Boolean]
      def supported?
        support_problem.nil?
      end

      # Once per process, under a Mutex: checks support, registers both bundled font files, probes
      # OpenType feature support and the antialiasing mode, runs the bundled-font self-check and
      # computes the cap-height {Metrics} of the Ledger body, header and footer styles at the globally
      # configured scale (rendering.md sections 5.4 and 9). Later calls return at once.
      #
      # @return [void]
      # @raise [RenderFailed] when libvips is missing or cannot draw text
      def warm_up!
        warm_up_base!
        self_check!
        ledger_styles.each { |style| metrics(style) }
        nil
      end

      # @return [Boolean] whether the bundled Inter is what libvips draws with (runs the self-check
      #   on first use; false when libvips cannot draw text at all)
      def bundled_font_active?
        warm_up!
        @bundled_font_active
      rescue RenderFailed
        false
      end

      # @api private
      # @return [Boolean] whether libvips draws this process's text with subpixel (coloured)
      #   antialiasing, which every run is then corrected for (rendering.md section 9). Runs warm-up.
      # @raise [RenderFailed] when libvips is missing or cannot draw text
      def subpixel_antialiasing?
        warm_up_base!
        @subpixel
      end

      # @api private
      # Greyscale antialiasing from a subpixel text image (rendering.md section 9): every pixel takes
      # `color` and keeps its alpha, which is the coverage libvips drew. Use it only on text drawn in
      # `color` alone, without colour glyphs.
      #
      # @param image [Vips::Image] 4-band text image from `Vips::Image.text` with `rgba: true`
      # @param color [String] "#RRGGBB"
      # @return [Vips::Image] 4-band uchar sRGB, same size and offsets
      def recolor(image, color)
        image.linear([0, 0, 0, 1], [*color.delete_prefix("#").scan(/../).map(&:hex), 0], uchar: true)
      end

      # @api private
      # @param color [String] "#RRGGBB"
      # @return [String] a colour at least 128 levels away from `color` in every channel: text drawn in
      #   it differs from text drawn in `color` in every pixel with coverage, colour glyphs do not
      def contrast_color(color)
        "##{color.delete_prefix("#").scan(/../).map { |pair| pair.hex < 128 ? "FF" : "00" }.join}"
      end

      # @param style [Style]
      # @return [Metrics] cap-height metrics, computed once per process per family, file, size and
      #   weight
      # @raise [RenderFailed]
      def metrics(style)
        prepare!(style)
        key = [style.family, style.fontfile, style.size_px, style.weight]
        process_cached(@metrics, key) do
          image = draw(markup("H", style), style, :left)
          Metrics.new(cap_top: image.yoffset, cap_height: image.height)
        end
      end

      # @api private
      # @return [Integer] extent of U+2026 alone in `style` and `align`, computed once per process
      def ellipsis_extent(style, align)
        prepare!(style)
        process_cached(@ellipsis, [style, align]) { build_run(ELLIPSIS, style, align).extent }
      end

      # @api private
      # Draws the self-check probe (rendering.md 5.4) in `family`, registering `fontfile` when given.
      #
      # @return [Array(Integer, Integer), nil] the extents in px of "0000000000" with tabular figures and
      #   "1111111111" with the default figures, nil when libvips cannot draw them
      def self_check_extents(family: "Inter", fontfile: REGULAR)
        tabular = Style.new(family: family, fontfile: fontfile, size_px: 100, weight: 400, color: "#000000", tnum: true)
        [probe_extent("0000000000", tabular), probe_extent("1111111111", tabular.with(tnum: false))]
      rescue Vips::Error
        nil
      end

      # @api private
      # @param extents [Array<Integer>, nil] from {self_check_extents}
      # @return [Boolean] whether the extents are the bundled Inter's
      def self_check_passes?(extents)
        !extents.nil? && SELF_CHECK_EXTENT.cover?(extents[0]) && SELF_CHECK_PROPORTIONAL_EXTENT.cover?(extents[1])
      end

      # @api private
      # Warm-up, plus the self-check when `style` uses a bundled font file.
      def prepare!(style)
        warm_up_base!
        self_check! if BUNDLED_FILES.include?(style.fontfile)
      end

      # @api private
      # @return [String] UTF-8 with NUL and invalid bytes replaced by U+FFFD, frozen
      def display_string(string)
        text = String(string)
        unless text.encoding == Encoding::UTF_8
          text = text.encode(Encoding::UTF_8, invalid: :replace, undef: :replace, replace: "\uFFFD")
        end
        text = text.scrub("\uFFFD") unless text.valid_encoding?
        text = text.tr("\u0000", "\uFFFD") if text.include?("\u0000")
        text.frozen? ? text : text.dup.freeze
      end

      # @api private
      # @return [String] the string escaped and wrapped in one span whose attributes come only from
      #   the style
      def markup(text, style)
        features = style.tnum && @tnum ? ' font_features="tnum"' : ""
        %(<span weight="#{style.weight}" foreground="#{style.color}"#{features}>#{escape(text)}</span>)
      end

      # @api private
      # @param text [String] a display string
      # @return [Integer] the libvips text calls {build_run} makes for `text`: 2 for a string that can
      #   contain a colour glyph on a host with subpixel antialiasing (rendering.md section 9), else 1
      #   (the second is skipped only if the first finds no ink). Callers have run {prepare!}.
      def text_calls(text)
        @subpixel && text.match?(COLOR_GLYPH) ? 2 : 1
      end

      # @api private
      # The libvips call for `text` (already a display string), plus the antialiasing correction on
      # hosts that need it, which draws once more when {text_calls} is 2 (rendering.md section 9).
      # Callers have run {prepare!}.
      # @return [Run, nil] nil when libvips finds no ink
      def build_run(text, style, align)
        image = draw(markup(text, style), style, align)
        return nil if image.nil?

        image = greyscale(image, text, style, align) if @subpixel
        xoffset = image.xoffset
        ink_right = xoffset + image.width
        # Right-to-left guard: Pango swaps the alignment of a right-to-left paragraph, so the ink
        # comes back near the left of the box. Measure it by its ink, like a left-aligned string.
        extent = align == :right && ink_right > RIGHT_BOX / 2 ? RIGHT_BOX - xoffset : ink_right
        Run.new(string: text, image: image, xoffset: xoffset, yoffset: image.yoffset, extent: extent, align: align)
      end

      private

      def support_problem
        return @support_problem if @support_checked

        @load_lock.synchronize do
          unless @support_checked
            @support_problem = detect_support_problem
            @support_checked = true
          end
        end
        @support_problem
      end

      def detect_support_problem
        begin
          require "vips"
        rescue LoadError
          return "csv_preview needs libvips, which could not be loaded. " \
                 "Install libvips 8.12 or newer with Pango, #{INSTALL_HINT}"
        end
        unless Vips.at_least_libvips?(8, 12)
          return "csv_preview needs libvips 8.12 or newer (this process has libvips #{Vips.version_string}), " \
                 "#{INSTALL_HINT}"
        end
        if Vips.type_find("VipsOperation", "text").zero?
          return "libvips was built without text (Pango) support. Install libvips with Pango, #{INSTALL_HINT}"
        end

        nil
      end

      def warm_up_base!
        return if @warm

        @warm_lock.synchronize do
          next if @warm

          problem = support_problem
          raise RenderFailed, problem if problem

          register_fonts
          probe_font_features
          @subpixel = probe_subpixel_antialiasing
          @warm = true
        end
      end

      # libvips adds each fontfile to fontconfig once (process-global and permanent). Both files are
      # registered before any text other than these probes is drawn.
      def register_fonts
        [[REGULAR, 400], [SEMIBOLD, 600]].each do |file, weight|
          style = probe_style(fontfile: file, weight: weight)
          draw(markup("x", style), style, :left)
        end
        refresh_font_list unless Vips.at_least_libvips?(8, 13)
      end

      # libvips 8.12 adds a font file to fontconfig without telling Pango (8.13 and later clear Pango's
      # font cache), and Pango keeps the font list it read at the first draw, when only the Regular file
      # was registered: weight 600 then draws with Regular. Drawing once at another resolution makes
      # libvips set its font map's resolution, which drops Pango's cached list; it is read again, with
      # both files, before the next draw. Every other draw uses 72 dpi.
      def refresh_font_list
        style = probe_style
        vips_text(markup("x", style), style, :left, dpi: 73)
      rescue Vips::Error
        raise RenderFailed, "libvips failed to draw text; #{DRAW_HINT}"
      end

      # Pango older than 1.38 rejects font_features as invalid markup. Then tnum is disabled for the
      # process and numbers use proportional figures.
      def probe_font_features
        vips_text(%(<span font_features="tnum">0</span>), probe_style, :left)
      rescue Vips::Error => e
        raise RenderFailed, "libvips failed to draw text; #{DRAW_HINT}" unless e.message.include?(INVALID_MARKUP)

        @tnum = false
        warn "csv_preview: this Pango cannot apply OpenType features (font_features needs Pango 1.38), " \
             "so numbers use proportional figures. Install Pango 1.44 or newer, #{INSTALL_HINT}"
      end

      # libvips before 8.17.1 lets fontconfig choose the antialiasing of rgba text, and many Linux
      # configurations (Ubuntu's default among them) choose subpixel rendering. The alpha band is then
      # the coverage of the middle subpixel, and the colour bands carry red and blue fringes
      # (rendering.md section 9). Detected once, by drawing mid-grey text over white.
      def probe_subpixel_antialiasing
        style = probe_style(size_px: 26).with(color: SUBPIXEL_PROBE_COLOR)
        image = vips_text(markup(SUBPIXEL_PROBE, style), style, :left)
        flat = image.flatten(background: [255, 255, 255]).cast(:int)
        spread = (flat[0] - flat[1]).abs + (flat[1] - flat[2]).abs + (flat[0] - flat[2]).abs
        spread.max > SUBPIXEL_SPREAD
      rescue Vips::Error
        raise RenderFailed, "libvips failed to draw text; #{DRAW_HINT}"
      end

      # The correction for subpixel antialiasing (rendering.md section 9): text pixels take the style
      # colour and keep their coverage. A string that can contain a colour glyph is drawn once more in a
      # contrasting colour; pixels that come out identical belong to colour glyphs and are kept as drawn.
      # Both drawings share one layout, so they always have the same size; if they ever did not, the run
      # would keep libvips' own pixels rather than lose its emoji.
      def greyscale(image, text, style, align)
        neutral = recolor(image, style.color)
        return neutral if text_calls(text) == 1

        other = draw(markup(text, style.with(color: contrast_color(style.color))), style, align)
        return image unless other && other.width == image.width && other.height == image.height

        image.relational(other, :equal).bandand.ifthenelse(image, neutral)
             .copy(interpretation: :srgb, xoffset: image.xoffset, yoffset: image.yoffset)
      end

      # Detects a fallback font standing in for the bundled Inter (rendering.md 5.3 and 5.4). Warns
      # once and never raises.
      def self_check!
        return unless @bundled_font_active.nil?

        @warm_lock.synchronize do
          next unless @bundled_font_active.nil?

          extents = self_check_extents
          active = self_check_passes?(extents)
          warn_fallback_font(extents) unless active
          @bundled_font_active = active
        end
      end

      # The three Ledger styles whose metrics warm-up computes. Metrics are cached per process, so
      # later warm-ups are cache hits.
      def ledger_styles
        scale = CsvPreview.config.scale
        scale = Configuration.new.scale unless scale.is_a?(Integer) && Configuration::SCALES.cover?(scale)
        styles = Theme::LEDGER.styles(scale: scale)
        [styles.body, styles.header, styles.footer]
      end

      # A bundled-font style for the warm-up probes.
      def probe_style(fontfile: REGULAR, size_px: 16, weight: 400, tnum: false)
        Style.new(family: "Inter", fontfile: fontfile, size_px: size_px, weight: weight, color: "#000000", tnum: tnum)
      end

      # Extent of `text` drawn right-aligned in `style`: from its ink's left edge to the logical right edge.
      def probe_extent(text, style)
        RIGHT_BOX - vips_text(markup(text, style), style, :right).xoffset
      end

      def warn_fallback_font(extents)
        measured = if extents
                     "measured #{extents[0]} and #{extents[1]} px, expected 630 to 660 and 380 to 440"
                   else
                     "the probe failed"
                   end
        warn "csv_preview: the bundled Inter font is not active (self-check #{measured}), so previews use a " \
             "fallback font. On macOS, set PANGOCAIRO_BACKEND=fontconfig in the environment, or require " \
             "\"csv_preview\" at boot before anything else draws text with libvips; #{INSTALL_HINT}"
      end

      def draw(markup, style, align)
        vips_text(markup, style, align)
      rescue Vips::Error => e
        return nil if e.message.include?(NO_TEXT)

        # The libvips message stays on the cause; this message never includes input content.
        raise RenderFailed, "libvips failed to draw text; #{DRAW_HINT}"
      end

      def vips_text(markup, style, align, dpi: 72)
        options = { font: "#{style.family}, #{style.size_px}", dpi: dpi, rgba: true }
        options[:fontfile] = style.fontfile if style.fontfile
        options.update(width: RIGHT_BOX, align: :high) if align == :right
        Vips::Image.text(markup, **options)
      end

      def process_cached(store, key)
        @cache_lock.synchronize do
          return store[key] if store.key?(key)

          value = yield
          store[key] = value if store.size < PROCESS_CACHE_LIMIT
          value
        end
      end
    end
  end
end
