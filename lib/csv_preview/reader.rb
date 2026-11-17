# frozen_string_literal: true

require "pathname"

module CsvPreview
  # Turns a source (path or IO-like) into bounded, decoded UTF-8 text. Internal API.
  #
  # See docs/spec/parsing-and-safety.md section 3. Messages of raised errors never include input bytes.
  # @api private
  module Reader
    # @!attribute text [String] valid UTF-8, BOM removed
    # @!attribute encoding [String] canonical Ruby name of the source encoding
    # @!attribute complete [Boolean] the whole source was read within max_input_bytes
    # @!attribute bytes_read [Integer] never above max_input_bytes
    Result = Data.define(:text, :encoding, :complete, :bytes_read)

    CHUNK = 65_536
    # Open flag for paths (see read_path); 0 where the platform has no O_NONBLOCK.
    OPEN_NONBLOCK = defined?(File::NONBLOCK) ? File::NONBLOCK : 0
    BINARY_WINDOW_BYTES = 8_192
    BINARY_WINDOW_CHARS = 4_096
    PARITY_WINDOW_BYTES = 4_096
    SUSPICIOUS = "\x01-\x08\x0B\x0C\x0E-\x1F\x7F"
    REPLACEMENT = "�"
    # Appended to every UnreadableInput message.
    NOT_TEXT_HINT = "Only CSV and TSV text can be previewed; show a fallback for other files, see #{Help::ERRORS}"

    MAGIC = [
      ["a PNG image", ->(b) { b.start_with?("\x89PNG\r\n\x1A\n".b) }],
      ["a JPEG image", ->(b) { b.start_with?("\xFF\xD8\xFF".b) }],
      ["a GIF image", ->(b) { b.start_with?("GIF87a".b, "GIF89a".b) }],
      ["a PDF document", ->(b) { b.start_with?("%PDF-".b) }],
      ["a ZIP archive (XLSX, ODS and similar)", ->(b) { b.start_with?("PK\x03\x04".b, "PK\x05\x06".b, "PK\x07\x08".b) }],
      ["an OLE2 file (XLS and similar)", ->(b) { b.start_with?("\xD0\xCF\x11\xE0\xA1\xB1\x1A\xE1".b) }],
      ["gzip data", ->(b) { b.start_with?("\x1F\x8B".b) }],
      ["bzip2 data", ->(b) { b.match?(/\ABZh[1-9]\x31\x41\x59\x26\x53\x59/n) }],
      ["xz data", ->(b) { b.start_with?("\xFD7zXZ\x00".b) }],
      ["zstd data", ->(b) { b.start_with?("\x28\xB5\x2F\xFD".b) }],
      ["a 7z archive", ->(b) { b.start_with?("7z\xBC\xAF\x27\x1C".b) }],
      ["a RAR archive", ->(b) { b.start_with?("Rar!\x1A\x07".b) }],
      ["a RIFF container", ->(b) { b.start_with?("RIFF".b) }],
      ["a TIFF image", ->(b) { b.start_with?("II*\x00".b, "MM\x00*".b) }],
      ["an ISO media file", ->(b) { b.byteslice(4, 4) == "ftyp".b }],
      ["an ELF executable", ->(b) { b.start_with?("\x7FELF".b) }],
      ["a SQLite database", ->(b) { b.start_with?("SQLite format 3\x00".b) }]
    ].freeze

    # Detection BOMs, UTF-32LE before UTF-16LE because they share FF FE.
    BOMS = [
      ["\xFF\xFE\x00\x00".b, Encoding::UTF_32LE],
      ["\x00\x00\xFE\xFF".b, Encoding::UTF_32BE],
      ["\xEF\xBB\xBF".b, Encoding::UTF_8],
      ["\xFF\xFE".b, Encoding::UTF_16LE],
      ["\xFE\xFF".b, Encoding::UTF_16BE]
    ].freeze

    module_function

    # @param source [String, Pathname, #read] a path, or an object responding to `read(length)`
    # @param config [Configuration] a resolved snapshot
    # @param deadline [Deadline]
    # @return [Result]
    # @raise [UnreadableInput] binary or non-text content
    # @raise [ArgumentError] unsupported source type or a non-regular file
    # @raise [SystemCallError] opening a path failed
    def call(source, config:, deadline:)
      limit = config.max_input_bytes
      if source.is_a?(String) || source.is_a?(Pathname)
        buffer, complete = read_path(source.to_s, limit, deadline)
      elsif source.respond_to?(:read)
        buffer, complete = read_bounded(source, limit, deadline)
      else
        raise ArgumentError, "source must be a path or respond to #read"
      end

      decode(buffer, complete, config.encoding, deadline)
    end

    # Opened non-blocking so the open cannot wait for a writer (a FIFO), which no timeout could bound;
    # the stat then refuses anything but a regular file, where non-blocking changes nothing.
    def read_path(path, limit, deadline)
      File.open(path, File::RDONLY | OPEN_NONBLOCK, binmode: true) do |file|
        raise ArgumentError, "source path is not a regular file" unless file.stat.file?

        buffer, eof = read_bounded(file, limit, deadline)
        [buffer, eof || file.size <= limit]
      end
    end

    # @return [Array(String, Boolean)] the binary buffer and whether end of file was seen
    def read_bounded(io, limit, deadline)
      buffer = String.new(capacity: [limit, CHUNK].min, encoding: Encoding::BINARY)
      eof = false
      while buffer.bytesize < limit
        deadline.check!(:read)
        want = [CHUNK, limit - buffer.bytesize].min
        chunk = io.read(want)
        unless chunk.nil? || chunk.is_a?(String)
          raise ArgumentError, "source#read returned #{chunk.class}"
        end
        if chunk.nil? || chunk.empty?
          eof = true
          break
        end

        chunk = chunk.byteslice(0, want) if chunk.bytesize > want
        buffer << chunk.b
      end
      [buffer, eof]
    end

    def decode(buffer, complete, option, deadline)
      bytes_read = buffer.bytesize
      reject_magic!(buffer)

      if option == :auto
        encoding, body = detect(buffer, complete)
      else
        encoding = Encoding.find(option)
        body = trim_cut(strip_bom(buffer, encoding), encoding, complete)
      end

      # ASCII-compatible encodings are checked on the raw bytes before paying for a decode.
      reject_binary_bytes!(buffer) if encoding.ascii_compatible?
      text = to_utf8(body, encoding)
      reject_binary_text!(text) unless encoding.ascii_compatible?
      text = text.byteslice(3, text.bytesize - 3) if text.start_with?("\uFEFF")
      deadline.check!(:decode)
      Result.new(text: text, encoding: encoding.name, complete: complete, bytes_read: bytes_read)
    end

    # Step 1 of binary detection: magic numbers at offset 0.
    def reject_magic!(buffer)
      MAGIC.each do |label, matcher|
        raise UnreadableInput, "input looks like #{label}, not CSV text. #{NOT_TEXT_HINT}" if matcher.call(buffer)
      end
    end

    # Step 3 for ASCII-compatible encodings, on the raw bytes.
    def reject_binary_bytes!(buffer)
      window = buffer.byteslice(0, BINARY_WINDOW_BYTES).b
      raise UnreadableInput, "input contains NUL bytes, so it is not CSV text. #{NOT_TEXT_HINT}" if window.include?("\0")

      reject_control_ratio!(window, window.bytesize)
    end

    # Step 3 for UTF-16 and UTF-32, on the decoded text (NUL bytes are normal there).
    def reject_binary_text!(text)
      window = text[0, BINARY_WINDOW_CHARS]
      raise UnreadableInput, "input contains NUL characters, so it is not CSV text. #{NOT_TEXT_HINT}" if window.include?("\0")

      reject_control_ratio!(window, window.length)
    end

    def reject_control_ratio!(window, size)
      return if window.count(SUSPICIOUS) <= [8, size / 20].max

      raise UnreadableInput, "input contains too many control characters to be CSV text. #{NOT_TEXT_HINT}"
    end

    # @return [Array(Encoding, String)] the encoding and the BOM-stripped, cut-trimmed bytes to decode
    def detect(buffer, complete)
      BOMS.each do |bom, encoding|
        return [encoding, trim_cut(buffer.byteslice(bom.bytesize..), encoding, complete)] if buffer.start_with?(bom)
      end

      parity = utf16_by_parity(buffer)
      return [parity, trim_cut(buffer, parity, complete)] if parity

      detect_utf8_or_windows1252(buffer, complete)
    end

    def utf16_by_parity(buffer)
      n = [buffer.bytesize, PARITY_WINDOW_BYTES].min & ~1
      return nil if n.zero?

      even = odd = 0
      (0...n).step(2) do |i|
        even += 1 if buffer.getbyte(i).zero?
        odd += 1 if buffer.getbyte(i + 1).zero?
      end
      units = n / 2.0
      even_ratio = even / units
      odd_ratio = odd / units
      return Encoding::UTF_16LE if odd_ratio >= 0.30 && even_ratio <= 0.05
      return Encoding::UTF_16BE if even_ratio >= 0.30 && odd_ratio <= 0.05

      nil
    end

    def detect_utf8_or_windows1252(buffer, complete)
      candidate = trim_cut(buffer, Encoding::UTF_8, complete)
      candidate.force_encoding(Encoding::UTF_8)
      return [Encoding::UTF_8, candidate] if candidate.valid_encoding?

      clean = candidate.scrub("")
      invalid = candidate.bytesize - clean.bytesize
      multibyte = clean.length - clean.count("\x00-\x7F")
      return [Encoding::UTF_8, candidate] if multibyte >= 1 && multibyte >= invalid

      [Encoding::Windows_1252, buffer.force_encoding(Encoding::BINARY)]
    end

    def strip_bom(buffer, encoding)
      bom = BOMS.find { |_, enc| enc == encoding }&.first
      bom && buffer.start_with?(bom) ? buffer.byteslice(bom.bytesize..) : buffer
    end

    # Drops an incomplete trailing character when the byte limit cut the input.
    def trim_cut(body, encoding, complete)
      return body if complete

      case encoding
      when Encoding::UTF_8 then trim_utf8(body)
      when Encoding::UTF_16LE, Encoding::UTF_16BE then trim_utf16(body, encoding)
      when Encoding::UTF_32LE, Encoding::UTF_32BE then body.byteslice(0, body.bytesize - (body.bytesize % 4))
      else body
      end
    end

    def trim_utf8(body)
      n = body.bytesize
      j = n - 1
      steps = 0
      while steps < 3 && j >= 0 && (body.getbyte(j) & 0xC0) == 0x80
        j -= 1
        steps += 1
      end
      return body if j.negative?

      lead = body.getbyte(j)
      need = if lead >= 0xF0 && lead <= 0xF7 then 4
             elsif lead >= 0xE0 && lead < 0xF0 then 3
             elsif lead >= 0xC0 && lead < 0xE0 then 2
             else 1
             end
      need > n - j ? body.byteslice(0, j) : body
    end

    def trim_utf16(body, encoding)
      body = body.byteslice(0, body.bytesize - 1) if body.bytesize.odd?
      return body if body.bytesize < 2

      hi_index = encoding == Encoding::UTF_16LE ? body.bytesize - 1 : body.bytesize - 2
      high = body.getbyte(hi_index)
      high >= 0xD8 && high <= 0xDB ? body.byteslice(0, body.bytesize - 2) : body
    end

    # Never raises: invalid and undefined sequences become U+FFFD.
    def to_utf8(body, encoding)
      if encoding == Encoding::UTF_8
        text = body.force_encoding(Encoding::UTF_8)
        text.valid_encoding? ? text : text.scrub(REPLACEMENT)
      else
        body.force_encoding(encoding).encode(Encoding::UTF_8, invalid: :replace, undef: :replace, replace: REPLACEMENT)
      end
    end
  end
end
