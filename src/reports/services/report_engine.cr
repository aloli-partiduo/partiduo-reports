# SPDX-License-Identifier: AGPL-3.0-or-later

module Reports
  # Calcul d'un rapport (D-REP-006 à D-REP-008) : colonnes de période
  # (période demandée décalée et étendue, ou une tranche par pas d'une
  # génération périodique), lignes calculées dans chaque colonne (`$CODE`
  # résolu à la demande, boucles refusées), listes de comptes développées,
  # colonnes de formule calculées ensuite sur chaque ligne ; montants
  # révisés pris tels quels, et repris par les lignes qui les citent.
  # Interne.
  class ReportEngine
    alias Range = Periods::Range
    alias Formula = Reports::Formula

    ZERO = BigDecimal.new(0)

    # Colonne du calcul : période résolue ou formule analysée.
    record Column, code : String, label : String, kind : String, span : String, shift_months : Int32,
      range : Range?, formula : Formula::Parsed?

    # Compte d'une liste de comptes : intitulé, montant par colonne.
    class Child
      getter label : String
      getter values : Array(BigDecimal?)

      def initialize(@label : String, size : Int32)
        @values = Array(BigDecimal?).new(size, nil)
      end
    end

    @lines : Array(Api::LineView)
    @parsed = {} of Int32 => Formula::Parsed
    @by_code = {} of String => Int32
    @values = [] of Array(BigDecimal?)
    @children = [] of Hash(String, Child)
    @columns = [] of Column
    @overrides = {} of {String, String} => BigDecimal

    def initialize(@actor : Partiduo::Api::Actor, @report : Api::ReportView, @input : Api::RunInput,
                   @sources : Sources = Sources.new(actor))
      @lines = @report.lines
      @input.overrides.each { |item| @overrides[{item.line.upcase, item.column.upcase}] = item.amount }
    end

    def run(base : Range) : Api::RunView
      @columns = columns(base)
      @lines.each_with_index do |line, index|
        @by_code[line.code] = index unless line.code.empty?
        next unless line.value?
        begin
          @parsed[index] = Formula.parse(line.formula)
        rescue error : Formula::Error
          @sources.issue("formula_error", {"line" => line_name(line), "error" => error.key})
        end
      end
      @values = @lines.map { Array(BigDecimal?).new(@columns.size, nil) }
      @children = @lines.map { {} of String => Child }
      @columns.each_with_index do |column, index|
        next unless column.kind == "period"
        @lines.each_index { |line| value(line, index, base, Set(Int32).new) }
      end
      @columns.each_with_index do |column, index|
        formula = column.formula
        next unless column.kind == "formula" && formula
        @lines.each_index do |line|
          next unless @lines[line].value?
          negate = @lines[line].negate
          @values[line][index] = column_value(formula, @values[line], negate, index)
          @children[line].each_value { |child| child.values[index] = column_value(formula, child.values, negate, index) }
        end
      end
      Api::RunView.new(report_id: @report.id, code: @report.code, name: @report.name, date_from: base.from,
        date_to: base.to, step: @input.step, decimals: @report.decimals,
        columns: @columns.map { |column| Api::RunColumnView.new(column.code, column.label, column.kind, column.range.try(&.from), column.range.try(&.to)) },
        lines: output, issues: @sources.issues)
    end

    # --- Colonnes ----------------------------------------------------------------------

    private def columns(base : Range) : Array(Column)
      if @input.step != "none"
        return Periods.steps(base, @input.step).map_with_index do |range, index|
          Column.new("P#{index + 1}", Numbers.range_label(range.from, range.to), "period", "period", 0, range, nil)
        end
      end
      defined = @report.columns
      if defined.empty?
        return [Column.new("N", I18n.t("reports.columns.default"), "period", "period", 0, base, nil)]
      end
      defined.map do |column|
        if column.kind == "formula"
          parsed = begin
            Formula.parse(column.formula)
          rescue error : Formula::Error
            @sources.issue("formula_error", {"line" => column.code, "error" => error.key})
            nil
          end
          Column.new(column.code, column.label, "formula", column.span, column.shift_months, nil, parsed)
        else
          Column.new(column.code, column.label, "period", column.span, column.shift_months,
            @sources.calendar.resolve(base, column.span, column.shift_months), nil)
        end
      end
    end

    # --- Lignes --------------------------------------------------------------------------

    # Montant brut d'une ligne dans une colonne de période.
    private def value(line : Int32, column : Int32, base : Range, visiting : Set(Int32)) : BigDecimal
      definition = @lines[line]
      return ZERO unless definition.value?
      if cached = @values[line][column]
        return cached
      end
      if revised = @overrides[{definition.code, @columns[column].code}]?
        return @values[line][column] = revised
      end
      unless visiting.add?(line)
        @sources.issue("cycle", {"line" => line_name(definition)})
        return ZERO
      end
      parsed = @parsed[line]? || return(@values[line][column] = ZERO)
      context = LineContext.new(self, column, base, parsed, visiting)
      amount = begin
        if definition.kind == "accounts" && (ref = parsed.root.as?(Formula::AccountRef))
          accounts(line, column, ref, context.range_for(ref.options))
        else
          parsed.evaluate(context)
        end
      rescue error : Formula::Error
        @sources.issue("formula_error", {"line" => line_name(definition), "error" => error.key})
        ZERO
      end
      visiting.delete(line)
      @values[line][column] = amount
    end

    # Liste de comptes : un montant par compte, le total pour la ligne.
    private def accounts(line : Int32, column : Int32, ref : Formula::AccountRef, range : Range) : BigDecimal
      sums = @sources.accounts(ref, range)
      sums.each do |number, sum|
        child = @children[line][number] ||= Child.new(sum.label, @columns.size)
        child.values[column] = Sources.amount([sum], ref.mode)
      end
      Sources.amount(sums.values, ref.mode)
    end

    # Formule de colonne sur les montants d'une ligne (`@CODE`), pris au
    # signe affiché ; le résultat est rendu au signe brut, que l'affichage
    # inverse de nouveau.
    private def column_value(formula : Formula::Parsed, values : Array(BigDecimal?), negate : Bool, index : Int32) : BigDecimal
      shown = negate ? values.map { |amount| amount.try { |value| -value } } : values
      result = formula.evaluate(ColumnContext.new(@columns, shown, @sources))
      negate ? -result : result
    rescue error : Formula::Error
      @sources.issue("formula_error", {"line" => @columns[index].code, "error" => error.key})
      ZERO
    end

    # Montant d'une autre ligne (`$CODE`) dans la même colonne.
    protected def line_value(code : String, column : Int32, base : Range, visiting : Set(Int32)) : BigDecimal
      index = @by_code[code]? || raise Formula::Error.new("line_unknown", {"code" => code})
      value(index, column, base, visiting)
    end

    protected def sources : Sources
      @sources
    end

    protected def column(index : Int32) : Column
      @columns[index]
    end

    private def line_name(line : Api::LineView) : String
      line.code.presence || line.label.presence || "#{line.position}"
    end

    # --- Résultat ----------------------------------------------------------------------

    private def output : Array(Api::RunLineView)
      list = [] of Api::RunLineView
      @lines.each_with_index do |line, index|
        next if line.hidden
        values = line.value? ? @values[index].map { |amount| shown(amount || ZERO, line.negate).as(BigDecimal?) } : Array(BigDecimal?).new(@columns.size, nil)
        revised = line.value? ? @columns.compact_map { |column| column.code if @overrides.has_key?({line.code, column.code}) } : [] of String
        list << Api::RunLineView.new(code: line.code, label: line.label, kind: line.kind, style: line.style,
          indent: line.indent, values: values, revised: revised)
        next unless line.kind == "accounts"
        @children[index].keys.sort!.each do |number|
          child = @children[index][number]
          amounts = child.values.map { |amount| shown(amount || ZERO, line.negate).as(BigDecimal?) }
          next if amounts.all? { |amount| amount.nil? || amount.zero? }
          list << Api::RunLineView.new(code: "", label: child.label, kind: "account", style: "normal",
            indent: Math.min(line.indent + 1, 5), values: amounts, account: number)
        end
      end
      list
    end

    private def shown(amount : BigDecimal, negate : Bool) : BigDecimal?
      rounded = amount.round(@report.decimals, mode: :ties_away)
      negate ? -rounded : rounded
    end

    # Contexte d'une ligne dans une colonne de période.
    class LineContext < Formula::Context
      def initialize(@engine : ReportEngine, @column : Int32, @base : Range, @parsed : Formula::Parsed,
                     @visiting : Set(Int32))
      end

      # Période d'une référence : celle de la colonne, décalée et étendue
      # par les options de la référence ; `FROM=MM.AAAA` en fixe le début.
      def range_for(options : Formula::Options) : Range
        column = @engine.column(@column)
        range = @engine.sources.calendar.resolve(@base, options.span || column.span, column.shift_months + options.shift_months)
        if from = @parsed.from
          range = Range.new(from, range.to)
        end
        range
      end

      def account(ref : Formula::AccountRef) : BigDecimal
        @engine.sources.account(ref, range_for(ref.options))
      end

      def card(ref : Formula::CardRef) : BigDecimal
        if ref.current?
          @engine.sources.issue("current_card")
          return ZERO
        end
        view = @engine.sources.card_view(ref.code)
        unless view
          @engine.sources.issue("card_unknown", {"code" => ref.code})
          return ZERO
        end
        @engine.sources.card(view.code, view.kind, ref, range_for(ref.options))
      end

      def analytic(ref : Formula::AnalyticRef) : BigDecimal
        @engine.sources.analytic(ref, range_for(ref.options))
      end

      def line(code : String) : BigDecimal
        @engine.line_value(code, @column, @base, @visiting)
      end

      def column(code : String) : BigDecimal
        raise Formula::Error.new("column_ref", {"code" => code})
      end
    end

    # Contexte d'une formule de colonne : montants de la ligne.
    class ColumnContext < Formula::Context
      def initialize(@columns : Array(Column), @values : Array(BigDecimal?), @sources : Sources)
      end

      def column(code : String) : BigDecimal
        index = @columns.index(&.code.==(code)) || raise Formula::Error.new("column_unknown", {"code" => code})
        @values[index]? || ZERO
      end

      def account(ref : Formula::AccountRef) : BigDecimal
        raise Formula::Error.new("reference_in_column")
      end

      def card(ref : Formula::CardRef) : BigDecimal
        raise Formula::Error.new("reference_in_column")
      end

      def analytic(ref : Formula::AnalyticRef) : BigDecimal
        raise Formula::Error.new("reference_in_column")
      end

      def line(code : String) : BigDecimal
        raise Formula::Error.new("line_ref", {"code" => code})
      end
    end
  end
end
