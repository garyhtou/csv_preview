# frozen_string_literal: true

require "ffi"

# Asks this process's fontconfig, the one libvips and Pango use, which file it picks for a pattern. Test
# code only (lib/ never calls FFI); it shows which file the bundled-font registrations resolve to. ffi is
# already in every bundle as a dependency of ruby-vips.
module Fontconfig
  extend FFI::Library
  ffi_lib %w[libfontconfig.so.1 libfontconfig.1.dylib fontconfig]

  MATCH_PATTERN = 0 # FcMatchPattern
  RESULT_MATCH = 0 # FcResultMatch

  attach_function :FcNameParse, [:string], :pointer
  attach_function :FcConfigSubstitute, %i[pointer pointer int], :int
  attach_function :FcDefaultSubstitute, [:pointer], :void
  attach_function :FcFontMatch, %i[pointer pointer pointer], :pointer
  attach_function :FcPatternGetString, %i[pointer string int pointer], :int
  attach_function :FcPatternDestroy, [:pointer], :void

  module_function

  # @param pattern [String] a fontconfig pattern, for example "Inter:weight=semibold"
  # @return [String, nil] the file of the best match in the current configuration
  def match_file(pattern)
    query = FcNameParse(pattern)
    FcConfigSubstitute(nil, query, MATCH_PATTERN)
    FcDefaultSubstitute(query)
    match = FcFontMatch(nil, query, FFI::MemoryPointer.new(:int))
    return nil if match.null?

    file = FFI::MemoryPointer.new(:pointer)
    FcPatternGetString(match, "file", 0, file) == RESULT_MATCH ? file.read_pointer.read_string : nil
  ensure
    FcPatternDestroy(match) if match && !match.null?
    FcPatternDestroy(query) if query && !query.null?
  end
end
