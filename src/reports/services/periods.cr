# SPDX-License-Identifier: AGPL-3.0-or-later

module Reports
  # Périodes d'un calcul (D-REP-007) : période demandée, décalée de
  # `shift` mois, puis étendue (`span`) d'après les exercices du socle
  # (à défaut, l'année civile). Interne.
  module Periods
    record Range, from : Time, to : Time do
      def empty? : Bool
        from > to
      end
    end

    # Exercices du socle : bornes, lues une fois par calcul.
    class Calendar
      @years : Array({Time, Time})

      def initialize
        @years = Partiduo::Api::Core.fiscal_years(Records.system).compact_map do |year|
          from = year.starts_on || next
          to = year.ends_on || next
          {from, to}
        end
      end

      # Bornes de l'exercice qui contient `day` ; à défaut, l'année civile.
      def bounds(day : Time) : {Time, Time}
        @years.find { |(from, to)| from <= day <= to } || {Time.utc(day.year, 1, 1), Time.utc(day.year, 12, 31)}
      end

      # Période par défaut : du début de l'exercice de `to` (défaut : la date
      # du jour) à `to`.
      def default(from : Time?, to : Time?) : Range
        last = Records.day(to || Records.today)
        Range.new(from.try { |day| Records.day(day) } || bounds(last)[0], last)
      end

      # Période d'une colonne ou d'une référence : `base` décalée de
      # `shift_months`, puis étendue selon `span`.
      def resolve(base : Range, span : String, shift_months : Int32) : Range
        from = Periods.shift(base.from, shift_months, false)
        to = Periods.shift(base.to, shift_months, true)
        case span
        when "ytd"     then Range.new(bounds(to)[0], to)
        when "year"    then Range.new(*bounds(to))
        when "month"   then Range.new(Time.utc(to.year, to.month, 1), to)
        when "opening" then Range.new(bounds(from)[0], from - 1.day)
        else                Range.new(from, to)
        end
      end
    end

    # Décale une date de `months` mois ; une fin de mois reste une fin de
    # mois (`end_of_month`).
    def self.shift(day : Time, months : Int32, end_of_month : Bool) : Time
      return day if months.zero?
      shifted = day.shift(months: months)
      last = Time.utc(day.year, day.month, Time.days_in_month(day.year, day.month))
      if end_of_month && day == last
        Time.utc(shifted.year, shifted.month, Time.days_in_month(shifted.year, shifted.month))
      else
        shifted
      end
    end

    # Tranches d'une génération périodique (D-REP-008) : consécutives
    # depuis `from` ; la dernière, incomplète, s'arrête à `to`.
    def self.steps(range : Range, step : String) : Array(Range)
      return [range] if step == "none"
      list = [] of Range
      start = range.from
      while start <= range.to && list.size < 120
        after = case step
                when "week"      then start + 7.days
                when "fortnight" then start + 14.days
                when "month"     then start.shift(months: 1)
                when "bimester"  then start.shift(months: 2)
                when "quarter"   then start.shift(months: 3)
                when "semester"  then start.shift(months: 6)
                else                  start.shift(years: 1)
                end
        last = after - 1.day
        list << Range.new(start, last > range.to ? range.to : last)
        start = after
      end
      list
    end
  end
end
