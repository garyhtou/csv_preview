# frozen_string_literal: true

require "vips"

# Reads encoded preview images back for assertions: decoding, pixels, ink edges, and the container
# structure (PNG chunks, WebP RIFF chunks, JPEG markers) that shows which metadata was written.
module Images
  PNG_SIGNATURE = "\x89PNG\r\n\x1A\n".b

  module_function

  # @param bytes [String] an encoded PNG, JPEG or WebP
  # @return [Vips::Image] decoded and fully loaded
  def decode(bytes)
    Vips::Image.new_from_buffer(bytes, "", access: :random).copy_memory
  end

  # @return [Array<Integer>] the pixel's band values
  def pixel(image, x, y)
    image.getpoint(x, y).map(&:round)
  end

  # @param rgb [Array<Integer>]
  # @return [String] "#RRGGBB"
  def hex(rgb)
    format("#%02X%02X%02X", *rgb)
  end

  # Right edge (exclusive) of the ink inside +box+: the x just past the rightmost pixel whose value
  # differs from +background+ by more than +threshold+ levels in any band. nil when the box has no ink.
  #
  # @param image [Vips::Image] 3-band
  # @param box [#x, #y, #width, #height]
  # @param background [Array<Integer>]
  # @param threshold [Integer]
  # @return [Integer, nil]
  def ink_right(image, box, background, threshold)
    mask = ink_mask(image, box, background, threshold)
    columns, = mask.project
    sums = columns.to_a.flatten
    last = sums.rindex(&:positive?)
    last && box.x + last + 1
  end

  # @return [Vips::Image] one band, 255 where a pixel of +box+ is ink
  def ink_mask(image, box, background, threshold)
    region = image.crop(box.x, box.y, box.width, box.height)
    band_rank((region - background).abs, :max) > threshold
  end

  # @return [Float] the largest HSV saturation, (max - min) / max over the bands, of any pixel in +box+
  def max_saturation(image, box)
    region = image.crop(box.x, box.y, box.width, box.height).cast(:float)
    high = band_rank(region, :max)
    low = band_rank(region, :min)
    ((high - low) / (high + 0.001)).max
  end

  # @param which [Symbol] :max or :min
  # @return [Vips::Image] one band: the largest or smallest band value of each pixel
  def band_rank(image, which)
    first, *rest = image.bandsplit
    Vips::Image.bandrank([first, *rest], index: which == :max ? rest.size : 0)
  end

  # @return [Array<Array(String, String)>] [type, data] of every chunk, in order
  def png_chunks(bytes)
    raise ArgumentError, "not a PNG" unless bytes.byteslice(0, 8) == PNG_SIGNATURE

    chunks = []
    pos = 8
    while pos < bytes.bytesize
      length = bytes.byteslice(pos, 4).unpack1("N")
      chunks << [bytes.byteslice(pos + 4, 4), bytes.byteslice(pos + 8, length)]
      pos += 12 + length
    end
    chunks
  end

  # @return [Array<String>] the RIFF chunk types of a WebP file, in order
  def webp_chunks(bytes)
    raise ArgumentError, "not a WebP" unless bytes.byteslice(0, 4) == "RIFF" && bytes.byteslice(8, 4) == "WEBP"

    types = []
    pos = 12
    while pos + 8 <= bytes.bytesize
      length = bytes.byteslice(pos + 4, 4).unpack1("V")
      types << bytes.byteslice(pos, 4)
      pos += 8 + length + (length.odd? ? 1 : 0)
    end
    types
  end

  # @return [Array<Array(Integer, String)>] [marker, first bytes of the segment] up to the start of scan
  def jpeg_segments(bytes)
    raise ArgumentError, "not a JPEG" unless bytes.byteslice(0, 2) == "\xFF\xD8".b

    segments = []
    pos = 2
    while pos + 4 <= bytes.bytesize
      marker = bytes.getbyte(pos + 1)
      length = bytes.byteslice(pos + 2, 2).unpack1("n")
      segments << [marker, bytes.byteslice(pos + 4, [length - 2, 32].min)]
      break if marker == 0xDA

      pos += 2 + length
    end
    segments
  end
end
