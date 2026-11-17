# csv_preview: Active Storage integration

- **Status:** accepted; implemented in 0.1
- **Started:** 2026-11-15
- **Part of:** the [specification](./README.md). This section must conform to the pinned contract in sections 9 and 10 of the overview. Proposed changes to that contract are collected in [section 12](#12-proposed-changes-to-the-overview).
- **Related sections:** [`parsing-and-safety.md`](./parsing-and-safety.md) (bounded reads, timeouts, thread safety), [`rendering.md`](./rendering.md) (the image itself, the libvips text capability check).

This document covers everything needed to build and test the Rails side of the gem: `CsvPreview::ActiveStoragePreviewer`, `CsvPreview::Railtie`, how Active Storage drives them, recipes for apps, and the dummy app in the test suite.

## 1. What ships

| Piece | File | Loaded |
|---|---|---|
| `CsvPreview::ActiveStoragePreviewer < ActiveStorage::Previewer` | `lib/csv_preview/active_storage_previewer.rb` | Lazily, the first time the constant is referenced (Ruby `autoload`). Requires `active_storage`. |
| `CsvPreview::Railtie < Rails::Railtie` | `lib/csv_preview/railtie.rb` | By `lib/csv_preview.rb` when `Rails::Railtie` is defined. |
| Rails setting `config.csv_preview.register_previewer` | (Railtie) | Default `false`. |

Global setting used by the previewer: `CsvPreview.config.previewer_content_types` (pinned default `["text/csv", "text/tab-separated-values"]`).

Decisions made in this section that the overview does not pin:

1. `accept?` also returns false when libvips cannot draw text ([3.2](#32-accept)).
2. The previewer downloads only the first `max_input_bytes` bytes of the blob with a ranged read, not the whole file ([3.4](#34-reading-the-blob-a-bounded-ranged-read)).
3. The previewer always produces PNG, whatever `CsvPreview.config.format` says ([3.5](#35-output-format-always-png)).
4. The opt-in setting is named `config.csv_preview.register_previewer` and means "put the previewer first" ([4.2](#42-opt-in-automatic-registration)).
5. A small, documented extension point: subclasses may override the private `render_options` method ([3.8](#38-extension-point-render_options)).
6. A public class method `CsvPreview::ActiveStoragePreviewer.text_supported?` for health checks ([3.2](#32-accept)).

## 2. The Active Storage previewer contract, verified

Verified on 2026-11-15 by reading the tagged sources of `rails/rails` (v7.1.0, v7.1.1 to v7.1.3, v7.1.3.4, v7.1.4, v7.1.6, v7.2.3 to v7.2.4, v8.0.5 to v8.0.5.2, v8.1.0, v8.1.3 to v8.1.4.1), and by booting a throwaway Rails app with a stand-in gem against Active Storage 7.1.3.4, 7.1.6, 7.2.4, 8.0.5.2 and 8.1.4.1 (both variant processors on the 8.x versions).

### 2.1 How Active Storage uses a previewer

1. `ActiveStorage.previewers` is an ordered list of previewer classes. In a Rails app it is copied from `config.active_storage.previewers` by an `after_initialize` hook that the Active Storage engine registers in its `"active_storage.configs"` initializer: `ActiveStorage.previewers = app.config.active_storage.previewers || []`. The copy is the **same Array object**, not a duplicate. Default list: `PopplerPDFPreviewer`, `MuPDFPreviewer`, `VideoPreviewer`. Identical in every checked version.
2. `blob.previewable?` is `ActiveStorage.previewers.any? { |klass| klass.accept?(blob) }`. `representable?` is `variable? || previewable?`. A CSV blob is never variable, so for CSV `representable?` equals `previewable?`.
3. `blob.preview(transformations)` returns an `ActiveStorage::Preview` (or raises `ActiveStorage::UnpreviewableError`). `blob.representation(transformations)` returns a preview when the blob is previewable, otherwise a variant.
4. `ActiveStorage::Preview#processed` calls the private `process` unless `blob.preview_image` is already attached. `process` picks the **first** class whose `accept?` returns true, instantiates it with the blob, and calls:

   ```ruby
   previewer.preview(service_name: blob.service_name) do |attachable|
     ActiveRecord::Base.connected_to(role: ActiveRecord.writing_role) do
       image.attach(attachable)   # image is blob.preview_image
     end
   end
   ```

   `service_name:` is the only option passed, in every checked version. The previewer must pass it through in the yielded hash so the preview image lands on the same storage service as the original. **The requested size is never passed to the previewer.** Transformations are applied afterwards, as a variant of the stored preview image.
5. `ActiveStorage::Previewer` (the base class) provides `attr_reader :blob`, `initialize(blob)`, `self.accept?(blob)` (returns false), `preview(**options)` (raises `NotImplementedError`), and private helpers: `download_blob_to_tempfile` (which is `blob.open(tmpdir: tmpdir, &block)`), `draw`, `open_tempfile`, `instrument(operation, payload)`, `service_name`, `capture`, `logger` (`ActiveStorage.logger`) and `tmpdir` (`Dir.tmpdir`).
6. `ActiveStorage::PreviewError < ActiveStorage::Error` is defined in `active_storage/errors.rb` in every checked version, so the gem can reference it unconditionally.

### 2.2 Differences between versions

| Area | 7.1.0 to 7.1.2 | 7.1.3 | 7.1.4 to 7.1.6 | 7.2.x | 8.0.x | 8.1.x |
|---|---|---|---|---|---|---|
| `ActiveStorage::Previewer` | same | same | same | same | same | same; 8.1.4.1 adds `in: IO::NULL` to the private `capture` (irrelevant: the gem never shells out) |
| `Preview#process` and the options it passes (`service_name:`) | same | same | same | same | same | same |
| `Preview#processed` | generates the preview image only; the variant is generated lazily by `url`/`key`/`download` | same as 7.1.0 | also processes the variant (`variant.processed`) | processes the variant only when transformations are present (`variant.processed if variant?`); `preview({})` presents the stored preview image itself | as 7.2 | as 7.2 |
| `download_blob_to_tempfile` | `blob.open(tmpdir:)` | same | same | same | same | same |
| `ActiveStorage::PreviewError` | present | present | present | present | present | present |
| `ActiveStorage::PreviewImageJob` | absent | absent | present | present | present | present (body identical from 7.1.4) |
| Preprocessed named variants of a previewable blob | each goes to `TransformJob`, which calls `blob.variant` and raises `ActiveStorage::InvariableError` for a CSV: **broken** | `TransformJob` now calls `blob.representation`: works, but every variant job may race to generate the same preview | `PreviewImageJob` generates the preview once, then enqueues one `TransformJob` per variant | as 7.1.4, and the job is only enqueued when at least one preprocessed variant exists | as 7.2 | as 7.2 |
| `Vips.block_untrusted(true)` set process-wide by Active Storage when ruby-vips is available | no | no | no | from 7.2.3.2 | from 8.0.5.1 | from 8.1.3.1 |
| Active Storage's own ImageMagick policy applied to MiniMagick | no | no | no | no | from 8.0.5.2 | from 8.1.4.1 |

Notes:

- On 7.1.x, `preview({}).processed` creates a variant record even with no transformations (observed: two variant records where 7.2 and later create one). Harmless, but tests that count variant records must allow for it.
- **`Vips.block_untrusted(true)`** (in `active_storage/vips.rb`) is applied whenever ruby-vips is loadable, which is always true when csv_preview is in the bundle. image_processing 2.x does the same when it loads, unless `VIPS_BLOCK_UNTRUSTED` is set. In a booted app on 7.2.4, 8.0.5.2 and 8.1.4.1, `Vips::Image.csvload` fails with "operation is blocked" while `Vips::Image.text` works. With libvips 8.18, `vips -l` marks loaders such as `svgload`, `ppmload`, `vipsload`, `csvload`, `matload`, `pdfload` and `magickload` as untrusted; `text`, the drawing and compositing operations, and the PNG, JPEG and WebP savers are not. The core must therefore never depend on an untrusted operation (see [section 12](#12-proposed-changes-to-the-overview), item 4).
- The ImageMagick policy Active Storage ships (8.0.5.2, 8.1.4.1) denies `TEXT`, `MSL`, `EPHEMERAL`, `URL`/`HTTP(S)`/`FTP`/`FILE`, the PostScript and PDF coder families, and `@` indirect reads. It adds to the host's policy rather than replacing it. Resizing a PNG is unaffected.

## 3. `CsvPreview::ActiveStoragePreviewer`

### 3.1 Loading

`lib/csv_preview.rb` declares the constant without loading Active Storage:

```ruby
module CsvPreview
  autoload :ActiveStoragePreviewer, "csv_preview/active_storage_previewer"
end

require "csv_preview/railtie" if defined?(Rails::Railtie)
```

`lib/csv_preview/active_storage_previewer.rb` starts with `require "active_storage"` (which in turn requires Active Record and Active Support, and autoloads `ActiveStorage::Previewer`). Nothing in the core may require this file. A process that never references the constant never loads Active Storage (acceptance test AS-21).

### 3.2 `accept?`

```ruby
def self.accept?(blob)
  content_type_accepted?(blob.content_type) && text_supported?
end
```

**Content type match.** Normalise `blob.content_type` by taking the part before any `;`, stripping whitespace and downcasing, then compare it with each entry of `CsvPreview.config.previewer_content_types` normalised the same way. `nil` and empty strings never match. The configuration is read on every call, so it is not cached, but apps should only change it at boot (a list that changes at runtime makes `previewable?` inconsistent between processes).

**Text support.** `accept?` returns false when this process's libvips cannot draw text. Decision and reasons:

- It matches Rails' own previewers, which return false from `accept?` when their tool is missing (`pdftoppm_exists?`, `ffmpeg_exists?`). Apps already write views as "show a preview if `representable?`, else an icon"; an honest `previewable?` keeps that working.
- Without it, every CSV upload on such a host would enqueue a job that is guaranteed to fail, and every preview URL would return an error.
- Returning false lets a later previewer in the list (for example a LibreOffice-based one) still handle the file on that host.

The cost of this choice is that a misconfigured host fails quietly. Mitigations, all required:

- The first time the check fails, log one warning through `ActiveStorage.logger`: `csv_preview: libvips has no text support (Pango), so CSV files are not previewable in this process. See the README for system requirements.`
- Expose the check as a public class method, `CsvPreview::ActiveStoragePreviewer.text_supported?`, so apps can assert it in a health check or a boot-time test.
- Document it in the README troubleshooting section.

The check must be cheap and must not render anything, because `accept?` runs for every attachment a view asks about. It uses the same capability check the core uses before raising `CsvPreview::RenderFailed` (defined in [`rendering.md`](./rendering.md); at minimum `Vips.type_find("VipsOperation", "text") != 0`, which is 0 when libvips was built without Pango). It is computed once per class and memoised. Two threads computing it at the same time is a benign race (same result; at worst two warnings). It must not call `Vips::Image.text`, because the first Pango call can trigger a fontconfig cache build that takes seconds, and `accept?` runs inside web requests.

### 3.3 `#preview(**options)`

Steps:

1. Build the render options: `render_options.merge(format: :png)` ([3.5](#35-output-format-always-png), [3.8](#38-extension-point-render_options)). Every other option comes from `CsvPreview.config` (the global configuration), because Active Storage gives the previewer no per-request options.
2. Read the head of the blob ([3.4](#34-reading-the-blob-a-bounded-ranged-read)).
3. Inside `instrument(:preview, key: blob.key) { ... }`, call `CsvPreview.render(source, **render_options)`.
4. Convert any `CsvPreview::Error` into `ActiveStorage::PreviewError` ([3.6](#36-errors)).
5. Outside the rescue and outside the instrumentation block, yield `io: StringIO.new(png), filename: "#{blob.filename.base}.png", content_type: "image/png", **options`.

The `options` received (today only `service_name:`) are passed through untouched in the yielded hash and are **never** passed to `CsvPreview.render`, which would reject an unknown option.

Reference implementation (verified against 7.1.3.4 to 8.1.4.1 with a stand-in core):

```ruby
# lib/csv_preview/active_storage_previewer.rb
require "stringio"
require "active_storage"

module CsvPreview
  class ActiveStoragePreviewer < ActiveStorage::Previewer
    class << self
      def accept?(blob)
        content_type_accepted?(blob.content_type) && text_supported?
      end

      def text_supported?
        return @text_supported unless @text_supported.nil?

        @text_supported = CsvPreview::Text.supported? # the capability check from rendering.md
        unless @text_supported
          ActiveStorage.logger&.warn("csv_preview: libvips has no text support (Pango), so CSV files " \
            "are not previewable in this process. See the README for system requirements.")
        end
        @text_supported
      end

      private
        def content_type_accepted?(content_type)
          type = content_type.to_s.split(";", 2).first.to_s.strip.downcase
          return false if type.empty?

          CsvPreview.config.previewer_content_types.any? { |accepted| accepted.to_s.strip.downcase == type }
        end
    end

    def preview(**options)
      png = render_image
      yield io: StringIO.new(png), filename: "#{blob.filename.base}.png", content_type: "image/png", **options
    end

    private
      # Extension point: per-call options for CsvPreview.render. `format` is always forced to :png.
      def render_options
        {}
      end

      def render_image
        options = render_options.merge(format: :png)
        if (head = read_head(options))
          render(head, options)
        else
          download_blob_to_tempfile { |file| render(file, options) }
        end
      rescue CsvPreview::Error => error
        raise ActiveStorage::PreviewError, "#{error.class.name}: #{error.message}"
      end

      def render(source, options)
        instrument(:preview, key: blob.key) { CsvPreview.render(source, **options) }
      end

      # The first max_input_bytes bytes of the blob, or nil when the service cannot serve ranges.
      def read_head(options)
        limit = options.fetch(:max_input_bytes) { CsvPreview.config.max_input_bytes } + 1
        length = [blob.byte_size.to_i, limit].min
        StringIO.new(length.positive? ? blob.download_chunk(0...length) : "".b)
      rescue NotImplementedError
        nil
      end
  end
end
```

`CsvPreview::Text.supported?` is an internal name; use whatever `rendering.md` defines.

### 3.4 Reading the blob: a bounded ranged read

Rails' built-in previewers call `download_blob_to_tempfile`, which downloads the **whole** blob to disk and verifies its checksum, because they hand a path to an external program. The core reads at most `max_input_bytes` (2 MiB by default) from its source, so downloading a 500 MB upload in full would be work proportional to file size, which the overview lists as an anti-goal. The previewer therefore reads only the head:

- **What it reads:** `blob.download_chunk(0...n)` with `n = min(blob.byte_size, max_input_bytes)`, wrapped in a `StringIO`. The core never reads more than `max_input_bytes` (overview 9.1), so the head gives exactly the same result as the full file, including `total_rows` being `nil` for any blob of `max_input_bytes` bytes or more (the same rule as for any IO source). Rendering the head and rendering the full file must give identical bytes (acceptance test AS-13).
- **Empty blobs:** when `byte_size` is 0 the previewer does not call the service at all (there is nothing to read, and some services reject a range request on an empty object) and renders an empty `StringIO`, which produces the core's "empty file" image.
- **Precedent:** Active Storage itself identifies content types with `service.download_chunk(key, 0...4.kilobytes)`, so every service an app uses with content-type identification already supports ranged reads. The Disk, S3 and GCS services implement it; the Mirror service delegates it to its primary.
- **Fallback:** the base `ActiveStorage::Service#download_chunk` raises `NotImplementedError`. A third-party service that does not implement it falls back to `download_blob_to_tempfile` (full download, the core still reads at most `max_input_bytes`). `NotImplementedError` is a `ScriptError`, not a `StandardError`, so it must be rescued by name, and only around the download.
- **No checksum verification:** a ranged read cannot be checked against the blob's checksum. That is acceptable for a preview: a corrupted read can at worst produce a wrong picture, never wrong data. A consequence is that `ActiveStorage::PreviewImageJob`'s `retry_on ActiveStorage::IntegrityError` never fires for csv_preview.
- **Memory:** at most `max_input_bytes` bytes per concurrent preview held as a String, plus whatever the core copies (see [`parsing-and-safety.md`](./parsing-and-safety.md)). No temporary file is written on the main path.
- **Instrumentation:** the service instruments the read itself as `service_download_chunk.active_storage` with the range, which is what AS-13 asserts on.
- Service errors (for example `ActiveStorage::FileNotFoundError` when the stored file is missing) propagate unchanged.

### 3.5 Output format: always PNG

The previewer passes `format: :png` on every call, overriding `CsvPreview.config.format` and anything a subclass returns from `render_options`. The yielded `filename` and `content_type` therefore always say PNG. Reasons:

- **Variants stay PNG.** Active Storage picks a variant's format from the source image when it is a "web image" (`config.active_storage.web_image_content_types`, default `image/png image/jpeg image/gif` in every supported version), and otherwise converts to PNG. A PNG preview gives PNG variants. A WebP preview would be converted to PNG for every variant anyway.
- **Locked-down ImageMagick.** Apps that use the `mini_magick` variant processor often restrict ImageMagick to a few raster coders. PNG is allowed in every such policy that allows raster images at all; WebP is not always.
- **Text quality and size.** PNG is lossless, so glyph edges and 1px rules stay crisp; JPEG rings around text and tints flat backgrounds. In a quick measurement of a 1043x955 image of monospaced text, PNG was 141 KB and JPEG at quality 85 was 197 KB.
- `image/png` is in Active Storage's default `content_types_allowed_inline`, so previews are served inline.

### 3.6 Errors

- Every `CsvPreview::Error` raised while rendering (`UnreadableInput`, `TimeoutExceeded`, `RenderFailed`) is re-raised as `ActiveStorage::PreviewError` with the message `"#{error.class.name}: #{error.message}"`. Raising inside `rescue` sets `PreviewError#cause` to the original error, so error trackers show both.
- Nothing else is converted. Service errors, `ActiveRecord` errors and unexpected exceptions (bugs) propagate unchanged, so job retry policies and error reports stay accurate. The core is responsible for wrapping libvips errors (`Vips::Error`) in `RenderFailed` ([`rendering.md`](./rendering.md)).
- Error messages must never contain cell contents or raw file bytes. Uploads may hold personal or financial data, and error messages end up in logs and third-party error trackers. This is a requirement on the core's messages (see [`parsing-and-safety.md`](./parsing-and-safety.md)); the previewer adds only the class name.
- Errors raised by the block the previewer yields to (attaching the image) are not rescued.

What happens next is Active Storage's behaviour, not the gem's:

- In `ActiveStorage::PreviewImageJob`, which discards only `ActiveRecord::RecordNotFound` and `ActiveStorage::UnrepresentableError`, a `PreviewError` fails the job and the queue backend's retry policy applies (Sidekiq, for example, retries a failed job 25 times by default). Apps should add `discard_on ActiveStorage::PreviewError` ([section 8](#8-operational-guidance)).
- In `ActiveStorage::Representations::*Controller` (on-demand processing behind `representation` URLs), the error is not rescued, so the request fails with a 500.

### 3.7 Logging and instrumentation

- The render is wrapped in the base class's private `instrument(:preview, key: blob.key)` helper, which emits `preview.active_storage` with `key:` and `service:`. Active Storage's log subscriber logs `Previewed file from key: <key>` at info level, and on 8.1 the structured event `active_storage.preview` is emitted, exactly as for the built-in previewers. The helper is private API, but it is identical in every checked version; AS-16 catches any change.
- Like the built-in previewers, the event is emitted even when rendering fails (the notification records the exception in its payload).
- The gem logs nothing else during normal operation. Two warnings exist: the one-time "no text support" warning ([3.2](#32-accept)) and the boot-time warning when `register_previewer` is true but Active Storage is not loaded ([4.2](#42-opt-in-automatic-registration)).
- No log line or event payload contains file contents.

### 3.8 Extension point: `render_options`

A subclass may override the private instance method `render_options` to pass per-call options, for example fewer rows in previews than in other `CsvPreview.render` calls:

```ruby
class CompactCsvPreviewer < CsvPreview::ActiveStoragePreviewer
  private
    def render_options = super.merge(max_rows: 12)
end
```

The subclass is registered instead of the base class. `format` is always overridden to `:png`. `max_input_bytes` from `render_options` also sets the size of the ranged read. This is the only supported customisation point besides `accept?` (see the content-type recipe in [section 7](#7-content-types-in-the-wild)).

## 4. Registration

### 4.1 Explicit registration

```ruby
# config/application.rb
require_relative "boot"
require "rails/all"              # or at least require "active_storage/engine"
Bundler.require(*Rails.groups)   # loads lib/csv_preview.rb (and the Railtie)

module MyApp
  class Application < Rails::Application
    config.active_storage.previewers.unshift CsvPreview::ActiveStoragePreviewer
  end
end
```

What must be loaded, and when:

- `config.active_storage` exists only once the Active Storage engine is loaded, which `rails/all` (or `active_storage/engine`) does before `Bundler.require` in the generated `application.rb`.
- The gem must be required before the class body references the constant. `Bundler.require` does this unless the Gemfile says `require: false`; in that case add `require "csv_preview"` before the `Application` class.
- Referencing `CsvPreview::ActiveStoragePreviewer` triggers the autoload, which requires `active_storage` (already loaded) and subclasses `ActiveStorage::Previewer`.
- The same line also works in an initializer: `Rails.application.config.active_storage.previewers.unshift CsvPreview::ActiveStoragePreviewer`. Initializer files run before the `after_initialize` hook that copies the list (verified on 7.1 to 8.1).
- Mutating `ActiveStorage.previewers` directly after boot also works (it is the same Array object as the config value), but is not recommended: it is easy to do it after a request has already cached `previewable?` results in memory.
- Outside Rails, modify `ActiveStorage.previewers` directly.

Because the gem's code is not managed by the app's Zeitwerk loader, the registered class object never goes stale when the app reloads code in development.

### 4.2 Opt-in automatic registration

```ruby
config.csv_preview.register_previewer = true   # default: false
```

When true, the Railtie puts `CsvPreview::ActiveStoragePreviewer` **first** in `config.active_storage.previewers`. It may be set in `config/application.rb`, in `config/environments/*.rb`, or in an initializer file. It does nothing when the class is already in the list (so explicit registration plus the flag registers once, and an explicit position wins). Setting it after boot has no effect.

Implementation:

```ruby
# lib/csv_preview/railtie.rb
require "rails/railtie"

module CsvPreview
  class Railtie < Rails::Railtie
    config.csv_preview = ActiveSupport::OrderedOptions.new
    config.csv_preview.register_previewer = false

    initializer "csv_preview.register_previewer", before: "active_storage.configs" do |app|
      config.after_initialize do
        next unless app.config.csv_preview.register_previewer

        if defined?(ActiveStorage::Engine)
          previewers = (app.config.active_storage.previewers ||= [])
          unless previewers.include?(CsvPreview::ActiveStoragePreviewer)
            previewers.unshift(CsvPreview::ActiveStoragePreviewer)
          end
        else
          Rails.logger&.warn("csv_preview: config.csv_preview.register_previewer is true, but Active Storage is not loaded")
        end
      end
    end
  end
end
```

Why this ordering works:

- The flag must be read after initializer files have run, so the registration happens in an `after_initialize` hook, not directly in the initializer.
- `after_initialize` hooks run in the order they were registered. Active Storage registers the hook that copies the list inside its `"active_storage.configs"` initializer. Declaring the gem's initializer `before: "active_storage.configs"` registers the gem's hook first, so it runs before the copy. (In the experiments the gem's hook already ran first without `before:`, because plain Railtie initializers are ordered ahead of Engine initializers; `before:` makes that explicit and survives a custom `config.railties_order`.)
- The list is mutated in place with `unshift`. Since the copy is the same Array object, even a hook that ran after the copy would still take effect, as long as nothing reassigned the config value in between.
- If an app requires the gem late (for example `require: false` and a `require` inside an initializer file), the Railtie is defined after Rails collected its initializers and the flag is ignored. Such apps must register explicitly.

Why it is opt-in rather than automatic: adding a gem should not silently change which previewer handles an existing content type. An app that already previews CSV with another previewer would switch on `bundle install`. One explicit line is cheap.

### 4.3 Previewers are checked in order

`ActiveStorage::Preview` uses `ActiveStorage.previewers.detect { |klass| klass.accept?(blob) }`: the first previewer that accepts a blob wins, and the others are never asked to render it. Consequences:

- `unshift` puts csv_preview first, so it wins over any other previewer that also accepts `text/csv`, such as a LibreOffice-based office previewer, whether that one was added before or after.
- `config.active_storage.previewers << CsvPreview::ActiveStoragePreviewer` puts it last, so an earlier previewer that accepts `text/csv` keeps handling CSV.
- The built-in previewers (Poppler, MuPDF, video) never accept CSV, so in an app with no other previewers the position does not matter. The README still recommends `unshift`.
- `previewable?` asks every previewer, so if csv_preview declines a blob (unlisted content type, or no text support) a later previewer may still accept it.
- Blobs that already have a preview image keep it: `processed` never re-renders an attached preview image, whichever previewer made it ([8.5](#85-regenerating-existing-previews)).

## 5. How previews flow

1. **One preview image per blob.** The first `Preview#processed` for a blob (from a view, a controller, or `ActiveStorage::PreviewImageJob`) runs the previewer once and attaches the PNG as `blob.preview_image`, a `has_one_attached` on the blob, stored on the same service. Its blob is identified by Marcel as `image/png`.
2. **Every size is a variant of that one image.** `blob.preview(resize_to_limit: [300, 300])` and `blob.preview(resize_to_limit: [1024, 1024])` share the same preview image and differ only in the variant the app's variant processor (vips or mini_magick, through image_processing) produces from it. The previewer is **never told the requested size**, so the preview image has to work both full size and scaled down; that is a [`rendering.md`](./rendering.md) concern.
3. **`previewable?` / `representable?`** are true for a blob whose content type is in `previewer_content_types`, on a host whose libvips can draw text.
4. **`blob.preview(t).processed`** generates the preview image if needed, then the variant (see [2.2](#22-differences-between-versions) for 7.1). On 7.2 and later, `blob.preview({}).processed` returns the stored preview image itself with no variant, which is the way to show it full size.
5. **`blob.representation(t)`** returns the same `ActiveStorage::Preview` for a CSV blob. In views, `image_tag blob.representation(:thumb)` generates a representations route; the image is processed on the first request for it unless it was preprocessed.
6. **Preprocessed named variants.** With

   ```ruby
   has_one_attached :file do |attachable|
     attachable.variant :thumb, resize_to_limit: [1024, 1024], preprocessed: true
   end
   ```

   attaching a CSV commits an attachment whose `after_create_commit` sees a previewable blob without a preview image and at least one preprocessed variant, and enqueues `ActiveStorage::PreviewImageJob.perform_later(blob, [transformations])` (7.1.4 and later). The job runs `blob.preview({}).processed` (one render) and then `blob.preprocessed(transformations)` for each variant, which enqueues one `ActiveStorage::TransformJob` per variant. Without any preprocessed variant, nothing is generated at upload time and the first request renders inline. `preprocessed:` also accepts a symbol or a lambda receiving the record, which lets an attachment that holds both images and CSV files preprocess a CSV-only variant.
7. **Failures.** `PreviewImageJob` declares `discard_on ActiveRecord::RecordNotFound, ActiveStorage::UnrepresentableError` and `retry_on ActiveStorage::IntegrityError`. It does not discard `ActiveStorage::PreviewError`, so apps add that themselves ([8.1](#81-discarding-files-that-cannot-be-previewed)). `TransformJob` has the same handlers; it only re-runs the previewer if the preview image is missing when it runs (a rare race), so discarding `PreviewError` there too is cheap insurance.
8. **Purging.** The preview image is purged with its blob by Active Storage; the gem does nothing.

## 6. Thumbnail recipe

A centred crop of a wide table shows the middle columns of the middle rows, which tells the reader nothing. Cropping anchored to the top-left corner keeps the header and the first rows and columns, which is what makes a table recognisable.

```ruby
# libvips (the default variant processor since Rails 7.0)
attachable.variant :thumb, resize_to_fill: [300, 300, { crop: :low }]

# MiniMagick
attachable.variant :thumb, resize_to_fill: [300, 300, { gravity: "NorthWest" }]
```

Verified against the image_processing source (1.14.0 and 2.2.0, identical signatures) and by experiment, both directly and through Active Storage on 7.1.6 to 8.1.4.1:

- **vips:** `ImageProcessing::Vips#resize_to_fill(width, height, **options)` calls `thumbnail(width, height, crop: :centre, **options)`, and the caller's `crop:` replaces the default. `crop: :low` is libvips' `VipsInteresting` value "low", which keeps the low coordinates, that is the top-left corner. Active Storage passes the trailing hash as keyword options.
- **mini_magick:** `ImageProcessing::MiniMagick#resize_to_fill(width, height, gravity: "Center", **options)` runs `-resize WxH^ -gravity <gravity> -background transparent -extent WxH`. `gravity: "NorthWest"` (also accepted: `"north-west"`) keeps the top-left corner. Active Storage's MiniMagick argument validation accepts it (verified on 8.0.5.2 and 8.1.4.1).
- The image is scaled so it covers the box, then the excess is cut on the right and bottom. Small previews are scaled up to fill the box.

**Under locked-down ImageMagick.** With a `policy.xml` that denies every coder and delegate and then allows only `JPEG`, `JPG`, `PNG`, `GIF` and `WEBP` (plus `path` `@*` denied), and with Active Storage 8.0.5.2/8.1.4.1's own policy on top, the MiniMagick recipe resizes the PNG preview correctly (verified with ImageMagick 7.1.2). `TEXT` and `SVG` reads are refused by the same policy, which is fine: the gem never asks ImageMagick to draw anything, it only receives a PNG to resize. Because previews are always PNG ([3.5](#35-output-format-always-png)), an app only needs PNG read and write allowed.

**Limits.** How legible a 300px thumbnail is depends on the preview's aspect ratio and type sizes ([`rendering.md`](./rendering.md)): the recipe only chooses which part survives. A stronger zoom ("crop a fixed top-left region, then resize") cannot be written portably as a variant: libvips' `crop` and `smartcrop` raise `bad extract area` when the region is larger than the image, while ImageMagick clamps silently.

**Mixed attachments.** Named variants apply to every file in the attachment, so for an attachment that also holds photos, define a separate CSV variant and choose it in the view:

```ruby
has_one_attached :file do |attachable|
  attachable.variant :thumb, resize_to_limit: [300, 300]
  attachable.variant :table_thumb, resize_to_fill: [300, 300, { crop: :low }],
    preprocessed: ->(record) { CsvPreview::ActiveStoragePreviewer.accept?(record.file.blob) }
end
```

```erb
<% variant = CsvPreview::ActiveStoragePreviewer.accept?(document.file.blob) ? :table_thumb : :thumb %>
<%= image_tag document.file.representation(variant) if document.file.representable? %>
```

## 7. Content types in the wild

### 7.1 What Active Storage stores

Active Storage identifies the content type with Marcel when a file is attached: from the uploaded IO for uploads that pass through Rails, and for direct uploads through `identify_without_saving` (called by `Attached::Changes::CreateOne`), which reads the first 4 KB from the service. Active Storage 7.1 to 8.1 depend on `marcel ~> 1.0`; the behaviour below was checked with marcel 1.2.1. Marcel's order is: magic bytes first, then the client's declared type (unless it is `application/octet-stream`, or a parent type of the filename's type), then the filename.

| Upload | Stored content type |
|---|---|
| `x.csv`, text body, declared `text/csv`, `text/plain`, `application/octet-stream`, `text/csv; charset=utf-8`, or nothing | `text/csv` |
| `x.tsv`, text body | `text/tab-separated-values` |
| `x.tab` or `x.txt` with tab-separated text | `application/octet-stream` / `text/plain` (not previewed) |
| `x.csv`, text body, declared `application/vnd.ms-excel` | `application/vnd.ms-excel` (the declared type wins) |
| `x.csv`, text body, declared `text/x-csv` or `application/csv` | kept as declared |
| PNG bytes renamed `x.csv`, declared `text/csv` | `image/png` (magic bytes win) |
| ZIP bytes renamed `x.csv` | `application/zip` |
| Real binary `.xls` (OLE2), any name | `application/vnd.ms-excel` |

So identification already stops most renamed binary files before the gem sees them. Binary data with no recognisable magic bytes, a file whose first 4 KB look like text, or an upload attached with `identify: false`, can still arrive labelled `text/csv`; the core's binary detection then raises `UnreadableInput`, which becomes `PreviewError`.

### 7.2 What clients send

- Current Chromium-based browsers (Chrome, Edge) hard-code `text/csv` for `.csv` as a "primary" mapping that overrides the operating system, specifically because Excel registers `.csv` as `application/vnd.ms-excel` on Windows. Current Firefox lists `text/csv` for `.csv` among its non-overridable defaults. Both send `text/csv`.
- Older browser versions, and other clients that ask the operating system (native apps, some upload libraries, email-to-upload bridges), may send `application/vnd.ms-excel` on Windows machines with Excel installed. Other labels seen for CSV include `text/x-csv`, `application/csv`, `application/x-csv` and `text/comma-separated-values`.

### 7.3 Why the default list excludes `application/vnd.ms-excel`

`application/vnd.ms-excel` is the registered type of binary `.xls` workbooks. Accepting it would make every real XLS upload `previewable?`, guarantee a failing preview for each of them (`UnreadableInput`), and, because the README recommends `unshift`, take XLS files away from a later spreadsheet previewer that could actually render them.

### 7.4 Extending the list

```ruby
# config/initializers/csv_preview.rb
CsvPreview.configure do |config|
  config.previewer_content_types += %w[text/x-csv application/csv application/x-csv text/comma-separated-values]
end
```

These labels are unambiguous (no binary format uses them), so adding them is low risk. For CSV files labelled `application/vnd.ms-excel`, accept them only when the filename says CSV, and let binary detection reject real workbooks:

```ruby
class ExcelLabelledCsvPreviewer < CsvPreview::ActiveStoragePreviewer
  def self.accept?(blob)
    super || (blob.content_type == "application/vnd.ms-excel" &&
              blob.filename.extension.to_s.casecmp?("csv") && text_supported?)
  end
end
```

An alternative is to correct the content type before attaching (for example, when the filename ends in `.csv` and the first bytes are text). Either way, the app owns that decision.

## 8. Operational guidance

### 8.1 Discarding files that cannot be previewed

```ruby
# config/initializers/csv_preview.rb
Rails.application.config.to_prepare do
  ActiveStorage::PreviewImageJob.discard_on ActiveStorage::PreviewError
  ActiveStorage::TransformJob.discard_on ActiveStorage::PreviewError
end
```

`to_prepare` is required, not a plain initializer: Active Storage's `app/jobs` directory is managed by the app's reloading autoloader (verified on 8.1), so in development the job classes are replaced on reload and would lose a handler added once. To still hear about discards, pass a block: `discard_on(ActiveStorage::PreviewError) { |_job, error| Rails.error.report(error, handled: true) }`.

### 8.2 Background versus inline generation

- **Prefer background generation.** Declare at least one `preprocessed: true` variant so `PreviewImageJob` renders the preview right after upload. Views then usually find it ready.
- **Inline generation happens** when a view or controller calls `preview(...).processed`, or when a representation URL is requested before the job has run. Worst-case time in the request is roughly: one ranged read of at most `max_input_bytes` bytes, plus the render (bounded by `timeout`, default 5 seconds; how far a render can overrun its deadline is defined in [`parsing-and-safety.md`](./parsing-and-safety.md)), plus uploading the PNG, plus generating the variant.
- **Choose `timeout` with requests in mind.** The previewer uses the global `CsvPreview.config.timeout` for jobs and requests alike. Keep it comfortably below the app's request timeout (for example a Rack timeout or a load balancer limit). A subclass can set a different value through `render_options` if previews need a different budget from other `render` calls.
- **On-demand failures.** A `PreviewError` raised in Active Storage's representations controller is not rescued and becomes a 500. Views that may show files that cannot be previewed can render the image only when `blob.preview_image.attached?` (generated in the background) and fall back to an icon otherwise.
- **Queues.** `PreviewImageJob` uses `config.active_storage.queues.preview_image`; `TransformJob` uses `config.active_storage.queues.transform`.
- **Concurrent first requests.** Two processes processing the same preview at once both render and both attach; Active Storage keeps one. This is Active Storage behaviour for every previewer and is harmless.

### 8.3 Thread safety under Puma and Sidekiq

A previewer instance is created per preview and holds only its blob. The only class-level state is the memoised text-support flag ([3.2](#32-accept)), whose concurrent computation is harmless. Each preview allocates its own `StringIO`. Everything else (concurrent renders, libvips threading, memory per render, the global configuration) is specified in [`parsing-and-safety.md`](./parsing-and-safety.md). For capacity planning, peak memory is roughly the number of concurrent previews (Puma threads plus Sidekiq concurrency on a host) times the per-render peak from that document, plus `max_input_bytes` each for the downloaded head.

### 8.4 Privacy

The previewer never logs cell contents, and its error messages contain only the error class and the core's message, which must not include file contents ([3.6](#36-errors)). The preview image itself contains the first rows of the file: apps must serve it with the same authorisation as the original file (for example by not exposing public representation URLs for private uploads).

### 8.5 Regenerating existing previews

Existing preview images are never replaced automatically: after switching from another previewer, or after upgrading the gem to a version that renders differently, old previews stay. To regenerate one, purge its preview image and process it again:

```ruby
blob.preview_image.purge
blob.preview({}).processed
```

## 9. Testing

### 9.1 Layout

The Active Storage tests run against a dummy Rails app inside the test suite, in a separate Rake task from the core tests. Two reasons: the core must be proven to work with no Rails or Active Support loaded (so an accidental `blank?` fails), and booting Active Storage changes process-wide state (`Vips.block_untrusted(true)` on 7.2.3.2, 8.0.5.1, 8.1.3.1 and later).

```
test/
  test_helper.rb                    # core tests; never loads Rails
  rails_helper.rb                   # boots test/dummy, includes ActiveJob::TestHelper
  fixtures/                         # shared fixtures: simple.csv, tabs.tsv, wide_long.csv, png_renamed.csv, ...
  active_storage/
    previewer_test.rb               # AS-1 to AS-3, AS-6, AS-17
    preview_flow_test.rb            # AS-4, AS-5, AS-7 to AS-10, AS-13 to AS-16, AS-18, AS-20
    ordering_test.rb                # AS-11
    registration_test.rb            # AS-12 (one subprocess per scenario)
    thumbnail_recipe_test.rb        # AS-19
    load_isolation_test.rb          # AS-21 (subprocess with no Rails)
  dummy/
    config/application.rb           # require "rails"; railties for active_record, active_job, active_storage only
    config/environments/test.rb
    config/database.yml             # sqlite3 file under tmp/
    config/storage.yml              # test: Disk under tmp/storage; alternate: a second Disk root (AS-6);
                                    # no_ranges: a Disk subclass whose download_chunk raises NotImplementedError (AS-15)
    config/initializers/csv_preview.rb  # to_prepare discard_on (section 8.1)
    app/models/document.rb          # has_one_attached :file with a preprocessed :thumb variant
    app/models/plain_document.rb    # has_one_attached :file, no variants
    lib/other_csv_previewer.rb      # accepts text/csv, raises if asked to render (stands in for an office previewer)
    bin/boot_probe                  # boots the app in a scenario chosen by ENV and prints the previewer list as JSON
gemfiles/
  common.gemfile                    # rake, minitest and the other test-only gems, shared through eval_gemfile
  no_rails.gemfile
  csv_floor.gemfile                 # csv pinned to its floor, 3.2.8 (PS-36)
  ruby_vips_floor.gemfile           # ruby-vips pinned to its floor, 2.2.2 (rendering.md 9)
  rails_7_2.gemfile
  rails_8_0.gemfile
  rails_8_1.gemfile
```

- Create the schema at test start by loading Active Storage's own migration from the installed gem (`"#{Gem.loaded_specs["activestorage"].full_gem_path}/db/migrate/20170806125915_create_active_storage_tables.rb"`, then `CreateActiveStorageTables.new.migrate(:up)`), plus a `documents` table. This keeps the schema correct for each Rails version without committing one.
- `config.active_job.queue_adapter = :test`; use `perform_enqueued_jobs` (which also performs jobs enqueued by performed jobs, needed for `PreviewImageJob` followed by `TransformJob`).
- `config.active_storage.variant_processor` comes from `ENV["VARIANT_PROCESSOR"]` (default `:vips`).
- Attachment callbacks run `after_commit`, so tests do not wrap examples in transactions; each test deletes rows and the storage directory in `teardown`.
- Registration scenarios need a fresh boot each, so `registration_test.rb` runs `test/dummy/bin/boot_probe` in a subprocess per scenario. (Subprocesses in tests are fine; the no-subprocess rule applies to rendering.)

### 9.2 Running against several Rails versions

Plain gemfiles selected with `BUNDLE_GEMFILE`, no Appraisal (one fewer dependency and generation step for a handful of tiny files):

```ruby
# gemfiles/rails_8_1.gemfile
source "https://rubygems.org"
gemspec path: ".."
%w[railties activestorage activerecord activejob actionpack].each { |name| gem name, "~> 8.1.0" }
gem "sqlite3", ">= 2.1"
gem "image_processing", ">= 1.12"
gem "mini_magick", ">= 5.1", require: false
eval_gemfile "common.gemfile"   # rake, minitest, and other test-only gems
```

```sh
BUNDLE_GEMFILE=gemfiles/rails_8_1.gemfile bundle install
BUNDLE_GEMFILE=gemfiles/rails_8_1.gemfile bundle exec rake test:rails
BUNDLE_GEMFILE=gemfiles/no_rails.gemfile bundle exec rake test
BUNDLE_GEMFILE=gemfiles/csv_floor.gemfile bundle exec rake test   # csv pinned to its floor, 3.2.8 (PS-36)
BUNDLE_GEMFILE=gemfiles/ruby_vips_floor.gemfile bundle exec rake test   # ruby-vips pinned to its floor, 2.2.2
```

`sqlite3` 2.x works with Active Storage 7.2.4 and later (verified); 7.1 would need `sqlite3 ~> 1.4`.

CI as built (`.github/workflows/ci.yml`; each job sets `BUNDLE_GEMFILE`, `ruby/setup-ruby` caches per gemfile, and the workflow has `permissions: contents: read`). The core suite (`rake test`, never loading Rails) runs in `core`; the Active Storage suite (`rake test:rails`) runs in `rails`. macOS runs only in a manual workflow (`macos.yml`, `workflow_dispatch`), because macOS minutes cost ten times as much.

| Job | OS | Ruby | Gemfile | Notes |
|---|---|---|---|---|
| core | ubuntu-22.04 | 3.3 | `no_rails` | libvips 8.12.1, the oldest supported; a system Inter is installed so the bundled files must win over a same-name font (rendering.md 5.4) |
| core, csv floor | ubuntu-24.04 | 3.3 | `csv_floor` | csv 3.2.8 (PS-36) |
| core, exact goldens | ubuntu-24.04 | 3.4 | `no_rails` | `CSV_PREVIEW_GOLDEN=exact`: the pinned golden image (rendering.md 11) |
| core | ubuntu-24.04 | 4.0 | `no_rails` | newest Ruby; a system Inter is installed |
| core, ruby-vips floor | ubuntu-24.04 | 4.0 | `ruby_vips_floor` | ruby-vips 2.2.2 (rendering.md 9) on libvips 8.15, on Ruby 4.0 because 2.2.1 cannot load there |
| rails 7.2 | ubuntu-24.04 | 3.3 | `rails_7_2` | vips variant processor |
| rails 8.0 | ubuntu-24.04 | 3.4 | `rails_8_0` | vips |
| rails 8.1 | ubuntu-24.04 | 3.4 | `rails_8_1` | vips |
| rails 8.1, MiniMagick | ubuntu-24.04 | 4.0 | `rails_8_1` | installs `imagemagick`, sets `VARIANT_PROCESSOR=mini_magick`, and runs `rake test:rails` (so AS-19 and the policy check) with `MAGICK_CONFIGURE_PATH` pointing at the restrictive policy file under `test/support/imagemagick`; the MiniMagick cases fail, not skip, on CI |

AS-19 runs both processors in every job; the MiniMagick row is the one where the dummy app itself uses MiniMagick.

### 9.3 Acceptance tests

Fixtures are referenced by name; their contents are listed in [`parsing-and-safety.md`](./parsing-and-safety.md) and [`rendering.md`](./rendering.md). "Previewed" means the preview image is attached, decodes as a PNG with libvips, and its variant fits the requested box.

- **AS-1. `accept?` by content type.** True for `text/csv`, `text/tab-separated-values`, `TEXT/CSV` and `text/csv; charset=utf-8`. False for `application/vnd.ms-excel`, `image/png`, `application/pdf`, `text/plain`, `""` and `nil`.
- **AS-2. The list is configurable.** After `previewer_content_types += ["text/x-csv"]`, `accept?` is true for `text/x-csv`. After setting the list to `["text/csv"]`, it is false for `text/tab-separated-values`. The configuration is restored after the test.
- **AS-3. No text support.** With the capability check stubbed to false and the memo reset, `accept?` is false for `text/csv`, `blob.previewable?` is false for a CSV blob, `text_supported?` is false, and exactly one warning is logged across several calls.
- **AS-4. Basic preview.** `simple.csv` attached to a `PlainDocument` normally: content type `text/csv`; `previewable?` and `representable?` are true; `blob.preview(resize_to_limit: [300, 300]).processed` succeeds; `blob.preview_image.content_type == "image/png"` and its filename is `simple.png`; the variant fits 300x300; `blob.representation(resize_to_limit: [300, 300])` is an `ActiveStorage::Preview`.
- **AS-5. TSV.** `tabs.tsv` is identified as `text/tab-separated-values` and previewed.
- **AS-6. Options pass-through and format.** A blob attached to the `alternate` service gets its preview image on `alternate`. A spy on `CsvPreview.render` receives exactly `format: :png` as options (no `service_name`). With `CsvPreview.config.format = :jpeg`, the preview image is still a PNG.
- **AS-7. Preprocessed variant.** Attaching `simple.csv` to a `Document` enqueues exactly one `ActiveStorage::PreviewImageJob`. After `perform_enqueued_jobs`, the preview image is attached, one variant record exists for `:thumb` on the preview image's blob, and `CsvPreview.render` was called exactly once. `document.file.representation(:thumb).processed` afterwards does not call `CsvPreview.render`.
- **AS-8. Unreadable file.** `png_renamed.csv` attached with `content_type: "text/csv", identify: false` keeps `text/csv`. `blob.preview(resize_to_limit: [300, 300]).processed` raises `ActiveStorage::PreviewError` whose message starts with `CsvPreview::UnreadableInput: `, contains none of the file's first 16 bytes, and whose `cause` is a `CsvPreview::UnreadableInput`. No preview image is attached.
- **AS-9. Discarded job.** For the document from AS-8, performing its `PreviewImageJob` with the dummy app's `discard_on ActiveStorage::PreviewError` raises nothing, enqueues no retry, and leaves no preview image.
- **AS-10. Identification stops renamed binaries.** `png_renamed.csv` attached normally (identification on) is stored as `image/png` and `accept?` is false for it.
- **AS-11. Order.** With `OtherCsvPreviewer` appended and csv_preview unshifted, the previewer chosen for a `text/csv` blob is `CsvPreview::ActiveStoragePreviewer` and the preview succeeds. In a boot scenario where csv_preview is appended after `OtherCsvPreviewer`, `OtherCsvPreviewer` is chosen.
- **AS-12. Registration scenarios** (one boot each; the previewer list is read after boot):
  - (a) nothing configured: absent;
  - (b) explicit `unshift` in `application.rb`: first;
  - (c) explicit `unshift` in an initializer file: first;
  - (d) `register_previewer = true` in `application.rb`: first;
  - (e) set in `config/environments/test.rb`: first;
  - (f) set in an initializer file: first;
  - (g) explicit `unshift` plus the flag: present exactly once, first;
  - (h) the flag plus an initializer that reassigns `config.active_storage.previewers = [OtherCsvPreviewer]`: `[CsvPreview::ActiveStoragePreviewer, OtherCsvPreviewer]`.
  
  In every scenario `ActiveStorage.previewers.equal?(Rails.application.config.active_storage.previewers)` is true.
- **AS-13. Bounded read.** For a generated 6 MiB CSV blob, processing its preview emits exactly one `service_download_chunk.active_storage` event for the blob's key, with range `0...(max_input_bytes)`, and no `service_download.active_storage` event for that key. The rendered bytes equal `CsvPreview.render(File.open(path), format: :png)` on the original file. With a subclass whose `render_options` returns `max_input_bytes: 1024`, the range is `0...1024`. The previewer reads at most `max_input_bytes` and never one byte more (an earlier draft of this test said `0...1025`, a byte to confirm end of file; the core does not need it, and an exactly `max_input_bytes`-long blob reports `total_rows` as `nil`, section 3.4).
- **AS-14. Empty blob.** A 0-byte blob declared `text/csv` is previewed with no download event for its key and produces the core's empty-file image (no error).
- **AS-15. Services without ranged reads.** On the `no_ranges` service, a preview of `simple.csv` succeeds through the `download_blob_to_tempfile` fallback.
- **AS-16. Instrumentation.** Processing a preview emits `preview.active_storage` with `payload[:key] == blob.key`, and the log contains `Previewed file from key: <key>`.
- **AS-17. Error mapping.** A `CsvPreview::TimeoutExceeded` (with `timeout: 0.001` on `wide_long.csv`, or a stub) and a stubbed `CsvPreview::RenderFailed` both surface as `ActiveStorage::PreviewError` with the original error as `cause`. A non-gem error (`ActiveStorage::FileNotFoundError`, after deleting the stored file from the service) propagates unchanged.
- **AS-18. libvips untrusted operations blocked.** With `Vips.block_untrusted(true)` set explicitly (so the test does not depend on the Rails version), AS-4 passes.
- **AS-19. Thumbnail recipe.** With vips, `blob.preview(resize_to_fill: [120, 120, { crop: :low }]).processed` on `wide_long.csv` gives a 120x120 PNG whose top-left 8x8 block matches the top-left of the preview image scaled by the same factor (the header band) and differs from the default centre crop. With MiniMagick (skipped when ImageMagick is not installed) and `MAGICK_CONFIGURE_PATH` pointing at a policy that allows only the `JPEG`, `JPG`, `PNG`, `GIF` and `WEBP` coders and denies all delegates, `resize_to_fill: [120, 120, { gravity: "NorthWest" }]` gives a 120x120 PNG with the same top-left property.
- **AS-20. Concurrent previews.** Previews of eight different blobs processed from four threads at once all succeed and each blob ends with one preview image.
- **AS-21. Load isolation.** In a process without Rails, after `require "csv_preview"`: `defined?(CsvPreview::Railtie)` is nil, no `active_storage`, `active_record` or `rails` file is in `$LOADED_FEATURES`, and `CsvPreview.autoload?(:ActiveStoragePreviewer)` returns the autoload path (not yet loaded).

## 10. README content

### Rails setup

````markdown
### Rails

```ruby
# Gemfile
gem "csv_preview"

# config/application.rb, inside your Application class
config.active_storage.previewers.unshift CsvPreview::ActiveStoragePreviewer

# config/initializers/csv_preview.rb: give up on files that can't be previewed instead of retrying them
Rails.application.config.to_prepare do
  ActiveStorage::PreviewImageJob.discard_on ActiveStorage::PreviewError
end
```

CSV and TSV attachments are now `previewable?`, and `blob.preview(...)`, `blob.representation(...)` and
preprocessed variants work like they do for PDFs and videos. Previews are always PNG.

Active Storage tries previewers in order and uses the first one that accepts a file. `unshift` puts
csv_preview first, so it handles CSV even if another previewer (for example a LibreOffice-based one)
also accepts `text/csv`. Prefer a setting? `config.csv_preview.register_previewer = true` does the same.
````

### Thumbnail recipe

````markdown
### Thumbnails that show the header

A centred crop of a wide table shows nothing useful. Crop to the top-left corner instead, so small
thumbnails keep the header and the first rows:

```ruby
class Document < ApplicationRecord
  has_one_attached :file do |attachable|
    # libvips (Rails' default variant processor)
    attachable.variant :thumb, resize_to_fill: [300, 300, { crop: :low }], preprocessed: true
    # MiniMagick: resize_to_fill: [300, 300, { gravity: "NorthWest" }]
  end
end
```

```erb
<%= image_tag document.file.representation(:thumb) if document.file.representable? %>
```

`preprocessed: true` renders the preview in a background job right after upload
(`ActiveStorage::PreviewImageJob`), then the thumbnail. The preview is a PNG, so this also works where
ImageMagick is locked down to a few raster formats, as long as PNG is allowed.
````

## 11. Open questions

1. **Should `TimeoutExceeded` be discarded with other errors?** The overview converts every `CsvPreview::Error` into `PreviewError`, so an app that discards `PreviewError` also discards a timeout that might have succeeded on a less loaded host. Active Job's `retry_on` cannot easily filter on `cause`. Options: keep as is (simple, bounded), or leave `TimeoutExceeded` unconverted so the app's retry policy applies.
2. **Unambiguous CSV aliases in the default list?** Marcel keeps declared types such as `text/x-csv`, `application/csv`, `application/x-csv` and `text/comma-separated-values`, none of which a binary format uses. Adding them by default would preview more real uploads at little risk. The overview pins only `text/csv` and `text/tab-separated-values`; this section keeps that and documents the aliases.
3. **First-class support for `application/vnd.ms-excel` with a `.csv` filename?** Currently a subclass recipe ([7.4](#74-extending-the-list)). A setting would be friendlier, but it widens what `previewable?` claims.
4. **WebP.** Lossless WebP was about 8 times smaller than PNG for a text image in a quick measurement, but Active Storage converts non-web-image previews' variants to PNG, and locked-down ImageMagick may refuse WebP. Revisit if Active Storage adds `image/webp` to `web_image_content_types`.
5. **Per-previewer options without subclassing.** Is a setting such as `config.csv_preview.render_options` worth adding, or is the `render_options` subclass hook enough?
6. **Legible thumbnails.** The thumbnail recipe can only choose the top-left corner, not zoom further ([section 6](#6-thumbnail-recipe)). Should [`rendering.md`](./rendering.md) bound the preview's aspect ratio so `resize_to_fill` keeps text readable at 300px, or is that out of scope?
7. **Regeneration helper.** Should the gem ship a Rake task that regenerates preview images for CSV blobs ([8.5](#85-regenerating-existing-previews)), for example after an upgrade that changes the look?

## 12. Proposed changes to the overview

> **Status: applied** to the overview on 2026-11-15. Rails 7.2 was chosen as the minimum (rather than 7.1.4), the previewer always emits PNG, and `CsvPreview.text_supported?` is public. Kept below for the reasoning.

1. **Minimum Active Storage version (overview section 5).** "7.1 or newer" is not accurate for preprocessed variants: on 7.1.0 to 7.1.2 they fail with `InvariableError`, on 7.1.3 each variant job may render the preview separately, and `PreviewImageJob` only exists from 7.1.4. The official Rails maintenance page currently lists only 8.0 and 8.1 as supported. Proposal: state "Active Storage 7.1.4 or newer; CI covers 7.2, 8.0 and 8.1", or raise the documented minimum to 7.2 to match CI.
2. **Format in the previewer (overview section 9.2).** Add one sentence: "The Active Storage previewer always renders PNG, regardless of `format`." Otherwise readers will expect `config.format = :webp` to change previews.
3. **Text capability check as public API (optional, overview section 9).** Add `CsvPreview.text_supported?` (no Rails needed) so the core's `RenderFailed` check, the previewer's `accept?` and app health checks share one definition. If not adopted, `CsvPreview::ActiveStoragePreviewer.text_supported?` stays the public probe.
4. **libvips blocking of untrusted operations (overview section 5, for `rendering.md` and `parsing-and-safety.md`).** Active Storage 7.2.3.2, 8.0.5.1, 8.1.3.1 and later, and image_processing 2.x, call `Vips.block_untrusted(true)` process-wide. Add to the constraints: "Rendering must work with `Vips.block_untrusted(true)`; the core may use no operation libvips marks untrusted (for example `svgload`, `ppmload`, `vipsload`, `csvload`)." Add a core test run with blocking on, not only AS-18.
5. **Code layout (overview section 10).** Add `test/dummy/` (the dummy Rails app), `test/active_storage/` and `gemfiles/` (one gemfile per Rails version plus `no_rails`).
