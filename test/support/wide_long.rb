# frozen_string_literal: true

# Deterministic generator for test/fixtures/wide_long.csv: a fictional bank-style export with 31 columns
# and 1,284 data rows under a header. The checked-in file must equal this output (a test checks it).
#
#   ruby test/support/wide_long.rb    # rewrites test/fixtures/wide_long.csv
module WideLong
  ROWS = 1_284
  HEADER = [
    "Transaction ID", "Date", "Posted Date", "Description", "Category", "Amount", "Currency", "Balance",
    "Card", "City", "State", "Country", "MCC", "Reference", "Type", "Status", "Memo", "Receipt", "Tags",
    "Cardholder", "Account", "Exchange Rate", "Original Amount", "Original Currency", "Fee", "Tax", "Tip",
    "Merchant ID", "Terminal", "Channel", "Notes"
  ].freeze
  MERCHANTS = [
    ["NORTHWIND SUPPLY CO", "Office Supplies", "5942"], ["TIDEPOOL COFFEE", "Meals", "5814"],
    ["ZIPCAB TRIP", "Travel", "4121"], ["BLUE HERON HOTEL", "Lodging", "7011"],
    ["CASCADE AIR", "Travel", "4511"], ["PIXEL PRINT SHOP", "Printing", "7338"],
    ["GREENLEAF MARKET", "Groceries", "5411"], ["CLOUDNINE HOSTING", "Software", "5734"]
  ].freeze
  CITIES = [%w[Seattle WA], %w[Oakland CA], %w[Portland OR], %w[Austin TX], %w[Denver CO]].freeze
  HOLDERS = ["Avery Chen", "Jordan Lee", "Sam Rivera", "Taylor Kim"].freeze
  CARDS = ["•••• 4821", "•••• 7710", "•••• 3094"].freeze
  MEMOS = ["Team lunch", "Client visit", "Monthly plan", "Conference", "Restock", "Airport ride"].freeze

  module_function

  # @return [String] the whole file, LF line endings
  def generate
    seed = 20_260_314
    rand = lambda do |n|
      seed = (seed * 1_103_515_245 + 12_345) % 2_147_483_648
      (seed >> 16) % n
    end
    balance = 1_840_217
    lines = [HEADER.join(",")]
    ROWS.times do |i|
      merchant, category, mcc = MERCHANTS[rand.call(MERCHANTS.size)]
      city, state = CITIES[rand.call(CITIES.size)]
      cents = rand.call(250_000) + 99
      cents = (i % 9).zero? ? cents * 8 : -cents
      balance += cents
      date = format("2026-03-%02d", 28 - (i / 48))
      fee = rand.call(4).zero? ? money(rand.call(500)) : ""
      lines << [
        format("TXN-%06d", ROWS - i), date, date, merchant, category,
        quote(money(cents)), "USD", quote(money(balance)), CARDS[i % CARDS.size], city, state, "US", mcc,
        format("%023d", 24_692_165_073_000_000_000_000 + (i * 7_919)), cents.negative? ? "Purchase" : "Credit",
        "Posted", MEMOS[rand.call(MEMOS.size)], rand.call(3).zero? ? "No" : "Yes", "",
        HOLDERS[i % HOLDERS.size], "Operating", "1.0000", "", "", fee, "", "", format("M%05d", rand.call(100_000)),
        format("T%03d", rand.call(1_000)), %w[card online recurring][i % 3], ""
      ].join(",")
    end
    lines.join("\n") + "\n"
  end

  def money(cents)
    sign = cents.negative? ? "-" : ""
    dollars, rest = cents.abs.divmod(100)
    "#{sign}$#{dollars.to_s.reverse.scan(/\d{1,3}/).join(",").reverse}.#{format("%02d", rest)}"
  end

  def quote(field) = field.include?(",") ? "\"#{field}\"" : field
end

if $PROGRAM_NAME == __FILE__
  File.binwrite(File.expand_path("../fixtures/wide_long.csv", __dir__), WideLong.generate)
end
