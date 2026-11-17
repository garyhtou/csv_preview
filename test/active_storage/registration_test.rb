# frozen_string_literal: true

require_relative "../rails_helper"
require "json"
require "open3"
require "rbconfig"

# Acceptance test AS-12 (active-storage.md 4 and 9.3): how the previewer gets into the list. Every
# scenario boots the dummy app in a fresh process with test/dummy/bin/boot_probe.
class RegistrationTest < Minitest::Test
  PROBE = File.expand_path("../dummy/bin/boot_probe", __dir__)
  OURS = "CsvPreview::ActiveStoragePreviewer"

  def boot(scenario)
    Dir.mktmpdir("csvprev-probe") do |dir|
      out, err, status = Open3.capture3({ "CSV_PREVIEW_SCENARIO" => scenario, "CSV_PREVIEW_DUMMY_TMP" => dir },
                                        RbConfig.ruby, PROBE)
      assert status.success?, "boot failed for scenario #{scenario}:\n#{out}\n#{err}"
      JSON.parse(out.lines.last)
    end
  end

  def previewers_for(scenario)
    result = boot(scenario)
    assert result.fetch("same_object"), "ActiveStorage.previewers is not the config's Array (scenario #{scenario})"
    result.fetch("previewers")
  end

  def test_AS_12a_nothing_configured_leaves_it_absent
    refute_includes previewers_for("a"), OURS
  end

  def test_AS_12b_explicit_unshift_in_application_rb
    assert_equal OURS, previewers_for("b").first
  end

  def test_AS_12c_explicit_unshift_in_an_initializer
    assert_equal OURS, previewers_for("c").first
  end

  def test_AS_12d_flag_in_application_rb
    assert_equal OURS, previewers_for("d").first
  end

  def test_AS_12e_flag_in_an_environment_file
    assert_equal OURS, previewers_for("e").first
  end

  def test_AS_12f_flag_in_an_initializer
    assert_equal OURS, previewers_for("f").first
  end

  def test_AS_12g_explicit_unshift_plus_the_flag_registers_once
    list = previewers_for("g")
    assert_equal 1, list.count(OURS)
    assert_equal OURS, list.first
  end

  def test_AS_12h_flag_survives_an_initializer_that_reassigns_the_list
    assert_equal [OURS, "OtherCsvPreviewer"], previewers_for("h")
  end

  # Booting with the flag off and the previewer not registered must not autoload it: the Railtie's
  # warm-up gate may not reference the constant.
  def test_flag_off_and_not_registered_leaves_the_previewer_unloaded
    result = boot("a")
    refute_includes result.fetch("previewers"), OURS
    assert_equal false, result.fetch("previewer_loaded"), "booting loaded #{OURS} although nothing registered it"
  end

  def test_the_probe_sees_the_previewer_loaded_when_it_is_registered
    assert_equal true, boot("b").fetch("previewer_loaded")
  end

  # The Railtie warms up the fonts at boot only when the previewer is registered, by either route.
  def test_boot_warms_up_the_fonts_only_when_the_previewer_is_registered
    assert_equal({ "a" => false, "b" => true, "d" => true },
                 %w[a b d].to_h { |scenario| [scenario, boot(scenario).fetch("warmed_up")] })
  end

  def test_the_flag_defaults_to_false
    assert_equal false, Rails.application.config.csv_preview.register_previewer
  end

  def test_the_railtie_is_loaded_inside_rails
    assert defined?(CsvPreview::Railtie)
  end
end
