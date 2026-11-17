# frozen_string_literal: true

module CsvPreview
  # Draws a {Layout} and encodes it (rendering.md section 7): a canvas with the header fill, the rules
  # and the frame, then one n-ary composite of every rendered string (each cut to its cell) and the
  # right-edge fade, flattened on the background and encoded with its metadata stripped.
  #
  # The painter draws no text itself. Every string was rendered, and measured with the same call, by
  # {Layout}; the painter only places those images. Colours and sizes come from the layout's {Theme}.
  #
  # ruby-vips is already loaded when a {Layout} exists (building one draws its text), so loading this
  # file does not load it.
  # @api private
  class Painter
    # Output resolution at scale 1, written to the PNG pHYs chunk: 72 dpi, so a scale-2 image says 144
    # dpi and viewers that honour it show it at its logical size.
    DPI = 72.0
    MM_PER_INCH = 25.4

    # Saver settings for each output format (rendering.md 7.5). Metadata stripping is added per call.
    ENCODINGS = {
      png: [".png", { compression: 6 }.freeze],
      webp: [".webp", { lossless: true }.freeze],
      jpeg: [".jpg", { Q: 90, optimize_coding: true, subsample_mode: :off, interlace: false }.freeze]
    }.freeze

    # VIPS_FOREIGN_KEEP_NONE, the saver `keep` flags value that strips all metadata (libvips 8.15 or
    # newer). Passed as the Integer because ruby-vips before 2.2.5 cannot convert a Symbol such as
    # `:none` for a flags argument and raises TypeError; every supported ruby-vips accepts the Integer.
    KEEP_NONE = 0

    # One image to composite and the position of its top-left corner on the canvas.
    Layer = Data.define(:image, :x, :y)
    private_constant :Layer

    # @param layout [Layout]
    # @param format [Symbol] :png, :jpeg or :webp
    # @param deadline [#check!] checked before each cell is placed, before compositing and before encoding
    # @return [String] the encoded image (binary)
    # @raise [ArgumentError] for an unknown format
    # @raise [RenderFailed] when libvips is missing, fails, lacks the saver for `format`, or the image
    #   would not match the layout's size and caps
    # @raise [TimeoutExceeded]
    def self.call(layout, format:, deadline:)
      raise ArgumentError, "format must be one of #{ENCODINGS.keys.inspect}" unless ENCODINGS.key?(format)
      unless Text.supported?
        raise RenderFailed, "csv_preview needs libvips 8.12 or newer with text (Pango) support. Install libvips " \
                            "with Pango, #{Text::INSTALL_HINT}"
      end

      new(layout, format, deadline).paint
    end

    private_class_method :new

    # @api private
    def initialize(layout, format, deadline)
      @layout = layout
      @format = format
      @deadline = deadline
      @theme = layout.theme
      @geometry = layout.geometry
      @width = layout.width_px
      @height = layout.height_px
      @resolution = DPI * layout.scale / MM_PER_INCH
    end

    # @api private
    def paint
      layers = text_layers
      layers << fade_layer if @geometry.fade
      check!
      image = composite(canvas, layers)
      check_size!(image)
      check!
      encode(image)
    rescue Vips::Error
      # The libvips message stays on the cause; this message never includes input content.
      raise RenderFailed, "libvips failed to paint the preview; check the libvips installation, #{Text::INSTALL_HINT}"
    end

    private

    def check! = @deadline.check!(:paint)

    def rgb(token) = @theme.rgb(token)

    # 7.1: one image with the header fill, the rules and the frame. The frame can be part of it because
    # nothing composited later reaches it: text is cut inside it and the fade stops at it.
    #
    # Nothing is drawn in place. Every band but the two side frames spans the full width, so the
    # canvas is a 1 px column of row colours (later bands overwrite earlier ones), stretched to the
    # width, with the side frames inserted on top. In-place drawing (`mutate` with `draw_rect!`) is
    # not thread-safe: each draw makes libvips signal the earlier draw operations on the image without
    # holding a reference to them, and Ruby's GC on another thread can free one mid-signal, which
    # crashes the process.
    def canvas
      g = @geometry
      rows = Array.new(@height, pixel(:background))
      band = lambda do |token, y, height|
        top = y.clamp(0, @height)
        bottom = (y + height).clamp(0, @height)
        rows.fill(pixel(token), top...bottom) if bottom > top
      end
      band.call(:header_fill, g.frame, g.header_height)
      band.call(:header_rule_color, g.frame + g.header_height - g.header_rule, g.header_rule)
      (1...@layout.rows_shown).each { |i| band.call(:row_rule_color, row_top(i), g.row_rule) }
      band.call(:footer_rule_color, g.footer_top, g.footer_rule) if g.footer_top
      band.call(:frame_color, 0, g.frame)
      band.call(:frame_color, @height - g.frame, g.frame)
      image = Vips::Image.new_from_memory_copy(rows.join, 1, @height, 3, :uchar)
                         .embed(0, 0, @width, @height, extend: :copy)
      if g.frame.positive?
        side = Vips::Image.black(g.frame, @height, bands: 3).new_from_image(rgb(:frame_color))
        image = image.insert(side, 0, 0).insert(side, @width - g.frame, 0)
      end
      image.copy(interpretation: :srgb, xres: @resolution, yres: @resolution)
    end

    # One sRGB pixel of a colour token as 3 bytes.
    def pixel(token) = rgb(token).pack("C3")

    def row_top(i) = @geometry.frame + @geometry.header_height + (i * @geometry.row_height)

    # 7.2: every string at its placement, cut to its cell box.
    def text_layers
      @layout.placements.filter_map do |placement|
        check!
        clip(placement)
      end
    end

    # Cuts a string's image to the intersection of its box and the area inside the frame, so tall
    # marks and fallback glyphs never paint over a neighbouring cell, a rule or the frame. nil when
    # nothing is left.
    def clip(placement)
      image = placement.run.image
      box = placement.box
      frame = @geometry.frame
      left = [placement.x, box.x, frame].max
      top = [placement.y, box.y, frame].max
      right = [placement.x + image.width, box.x + box.width, @width - frame].min
      bottom = [placement.y + image.height, box.y + box.height, @height - frame].min
      return nil if right <= left || bottom <= top

      width = right - left
      height = bottom - top
      unless width == image.width && height == image.height
        image = image.crop(left - placement.x, top - placement.y, width, height)
      end
      Layer.new(image: image, x: left, y: top)
    end

    # 7.3: the background colour with an alpha ramp of 255 * t ** fade_exponent, from 0 at the fade's
    # left edge to 255 at the frame, over the header band and the rows.
    def fade_layer
      box = @geometry.fade
      ramp = ((Vips::Image.grey(box.width, 1)**@theme.fade_exponent) * 255).cast(:uchar)
      ramp = ramp.embed(0, 0, box.width, box.height, extend: :copy)
      colour = Vips::Image.black(box.width, box.height, bands: 3).new_from_image(rgb(:background))
      Layer.new(image: colour.bandjoin(ramp).copy(interpretation: :srgb), x: box.x, y: box.y)
    end

    # 7.4: one n-ary composite of every layer, then the alpha is flattened away: 8-bit, 3-band sRGB.
    def composite(base, layers)
      return base if layers.empty?

      base.composite(layers.map(&:image), Array.new(layers.size, :over), x: layers.map(&:x), y: layers.map(&:y))
          .flatten(background: rgb(:background))
          .cast(:uchar)
          .copy(interpretation: :srgb, xres: @resolution, yres: @resolution)
    end

    # 7.6: the image is exactly the layout's size, within the caps, before anything is encoded.
    def check_size!(image)
      return if image.width == @width && image.height == @height && image.bands == 3 &&
                @width <= @layout.max_width_px && @height <= @layout.max_height_px

      raise RenderFailed, "painted #{image.width} by #{image.height} px for a #{@width} by #{@height} px layout " \
                          "with caps of #{@layout.max_width_px} by #{@layout.max_height_px} px. This is a bug in " \
                          "csv_preview; please report it at #{Help::ISSUES}"
    end

    # 7.5: metadata is always stripped; libvips otherwise writes an eXIf chunk into PNGs.
    def encode(image)
      suffix, options = ENCODINGS.fetch(@format)
      strip = Vips.at_least_libvips?(8, 15) ? { keep: KEEP_NONE } : { strip: true }
      image.write_to_buffer(suffix, **options, **strip)
    rescue Vips::Error
      raise RenderFailed, "libvips could not encode #{@format} (it may have been built without a #{@format} saver). " \
                          "Use format: :png or a libvips with #{@format} support, see #{Help::OPTIONS}"
    end
  end
end
