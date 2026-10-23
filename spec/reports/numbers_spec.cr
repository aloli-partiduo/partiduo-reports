# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

describe Reports::Numbers do
  it "met en forme montants et dates dans chacune des langues de l'interface" do
    expected = {
      "fr" => {"-1\u202F234\u202F567,89", "07/09/2026"},
      "en" => {"-1,234,567.89", "2026-09-07"},
      "nl" => {"-1.234.567,89", "07-09-2026"},
      "de" => {"-1.234.567,89", "07.09.2026"},
      "es" => {"-1.234.567,89", "07/09/2026"},
      "it" => {"-1.234.567,89", "07/09/2026"},
      "pt" => {"-1\u00A0234\u00A0567,89", "07/09/2026"},
    }
    expected.keys.sort!.should eq(Partiduo::LOCALES.sort)
    day = Time.utc(2026, 9, 7)
    expected.each do |locale, (amount, date)|
      I18n.with_locale(locale) do
        Reports::Numbers.amount(BigDecimal.new("-1234567.891")).should eq(amount)
        Reports::Numbers.date(day).should eq(date)
        Reports::Numbers.range_label(day, day).should eq("#{date} – #{date}")
      end
    end
  end

  it "groupe les milliers dès quatre chiffres et respecte les décimales demandées" do
    I18n.with_locale("es") do
      Reports::Numbers.amount(BigDecimal.new("1234.5")).should eq("1.234,50")
      Reports::Numbers.amount(BigDecimal.new("999.995")).should eq("1.000,00")
      Reports::Numbers.amount(BigDecimal.new("1234.5"), 0).should eq("1.235")
    end
  end
end
