# SPDX-License-Identifier: AGPL-3.0-or-later

module Reports
  # Mise en forme des montants et des dates des fichiers exportés selon la
  # langue courante (`I18n.locale`) : le PDF du socle reçoit des textes
  # déjà mis en forme. Le CSV et l'ODS gardent les montants bruts. Interne.
  module Numbers
    # Séparateurs des milliers et des décimales, format des dates.
    SEPARATORS = {"fr" => {" ", ","}, "nl" => {".", ","}, "en" => {",", "."}}
    DATES      = {"fr" => "%d/%m/%Y", "nl" => "%d-%m-%Y", "en" => "%Y-%m-%d"}

    def self.locale : String
      code = I18n.locale.to_s[0, 2]
      SEPARATORS.has_key?(code) ? code : "fr"
    end

    # Montant arrondi à `decimals`, séparateurs de la langue.
    def self.amount(value : BigDecimal, decimals : Int32 = 2) : String
      thousands, point = SEPARATORS[locale]
      rounded = value.round(decimals, mode: :ties_away)
      negative = rounded < 0
      text = rounded.abs.to_s
      whole, _, fraction = text.partition('.')
      fraction = (fraction + "0" * decimals)[0, decimals]
      grouped = whole.reverse.scan(/\d{1,3}/).map(&.[0]).join(thousands).reverse
      result = decimals > 0 ? "#{grouped}#{point}#{fraction}" : grouped
      negative ? "-#{result}" : result
    end

    # Montant brut des fichiers de données : point décimal, sans
    # séparateur de milliers.
    def self.raw(value : BigDecimal, decimals : Int32 = 2) : String
      rounded = value.round(decimals, mode: :ties_away)
      whole, _, fraction = rounded.to_s.partition('.')
      decimals > 0 ? "#{whole}.#{(fraction + "0" * decimals)[0, decimals]}" : whole
    end

    def self.date(day : Time) : String
      day.to_s(DATES[locale])
    end

    def self.range_label(from : Time, to : Time) : String
      "#{date(from)} – #{date(to)}"
    end
  end
end
