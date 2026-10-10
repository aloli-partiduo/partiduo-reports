# SPDX-License-Identifier: AGPL-3.0-or-later

module Reports
  # Contrôles des définitions (rapports et listings) : erreurs par champ
  # (`lines[3].formula`…), clés `reports.errors.*`. Les références à des
  # journaux, fiches ou postes analytiques ne sont *pas* contrôlées ici :
  # une définition reste portable d'un dossier à l'autre, et ce qui manque
  # est signalé au calcul (D-REP-014). Interne.
  module Checks
    alias FieldError = Partiduo::Api::FieldError
    alias Formula = Reports::Formula

    CODE = Formula::CODE

    def self.error(field : String, key : String, params = {} of String => String) : FieldError
      Records.error(field, key, params)
    end

    def self.formula_error(field : String, error : Formula::Error) : FieldError
      FieldError.new(field, "reports.errors.formula.#{error.key}", error.params)
    end

    # Code d'une définition, en majuscules.
    def self.normalize_code(code : String) : String
      code.strip.upcase
    end

    # --- Rapports ----------------------------------------------------------------------

    def self.report_errors(input : Api::ReportInput, id : Int64? = nil) : Array(FieldError)
      errors = [] of FieldError
      code = normalize_code(input.code)
      if !code.matches?(CODE)
        errors << error("code", "code.invalid")
      elsif Report.all.filter(code__iexact: code).to_a.any? { |row| row.id != id }
        errors << error("code", "code.taken")
      end
      errors << error("name", "name.blank") if input.name.strip.empty?
      errors << error("name", "name.too_long", {"max" => "120"}) if input.name.strip.size > 120
      errors << error("decimals", "decimals.range") unless (0..2).includes?(input.decimals)
      errors.concat(column_errors(input.columns))
      errors.concat(line_errors(input.lines))
      errors
    end

    private def self.column_errors(columns : Array(Api::ColumnInput)) : Array(FieldError)
      errors = [] of FieldError
      errors << error("columns", "columns.count", {"max" => Api::MAX_COLUMNS.to_s}) if columns.size > Api::MAX_COLUMNS
      seen = [] of String
      columns.each_with_index do |column, index|
        path = "columns[#{index}]"
        code = normalize_code(column.code)
        if !code.matches?(CODE)
          errors << error("#{path}.code", "code.invalid")
        elsif seen.includes?(code)
          errors << error("#{path}.code", "code.duplicate")
        end
        errors << error("#{path}.label", "label.blank") if column.label.strip.empty?
        errors << error("#{path}.label", "label.too_long", {"max" => "60"}) if column.label.strip.size > 60
        errors << error("#{path}.kind", "choice.invalid") unless Api::COLUMN_KINDS.includes?(column.kind)
        errors << error("#{path}.span", "choice.invalid") unless Api::SPANS.includes?(column.span)
        unless column.shift_months.abs <= Formula::MAX_SHIFT_MONTHS
          errors << error("#{path}.shift_months", "shift.range", {"max" => Formula::MAX_SHIFT_MONTHS.to_s})
        end
        if column.kind == "formula"
          if failure = Formula.check(column.formula, lines: false, columns: true, references: false)
            errors << formula_error("#{path}.formula", failure)
          else
            Formula.parse(column.formula).columns.each do |cited|
              next if seen.includes?(cited)
              errors << error("#{path}.formula", "column.order", {"code" => cited})
              break
            end
          end
        end
        seen << code
      end
      errors
    end

    private def self.line_errors(lines : Array(Api::LineInput)) : Array(FieldError)
      errors = [] of FieldError
      if lines.empty? || lines.size > Api::MAX_LINES
        errors << error("lines", "lines.count", {"max" => Api::MAX_LINES.to_s})
      end
      codes = line_codes(lines, errors)
      references = {} of Int32 => Array(String)
      lines.each_with_index do |line, index|
        path = "lines[#{index}]"
        errors.concat(layout_errors(line, path))
        next unless Api::VALUE_KINDS.includes?(line.kind)
        found = formula_line_error(line, path, lines, codes)
        if found.is_a?(FieldError)
          errors << found
        else
          references[index] = found
        end
      end
      cycle_errors(lines, codes, references, errors)
      errors
    end

    # Codes des lignes (rang par code), doublons et codes invalides signalés.
    private def self.line_codes(lines : Array(Api::LineInput), errors : Array(FieldError)) : Hash(String, Int32)
      codes = {} of String => Int32
      lines.each_with_index do |line, index|
        code = normalize_code(line.code)
        next if code.empty?
        if !code.matches?(CODE)
          errors << error("lines[#{index}].code", "code.invalid")
        elsif codes.has_key?(code)
          errors << error("lines[#{index}].code", "code.duplicate")
        else
          codes[code] = index
        end
      end
      codes
    end

    # Sorte, style, retrait, libellé d'une ligne.
    private def self.layout_errors(line : Api::LineInput, path : String) : Array(FieldError)
      errors = [] of FieldError
      errors << error("#{path}.kind", "choice.invalid") unless Api::LINE_KINDS.includes?(line.kind)
      errors << error("#{path}.style", "choice.invalid") unless Api::LINE_STYLES.includes?(line.style)
      errors << error("#{path}.indent", "indent.range") unless (0..5).includes?(line.indent)
      errors << error("#{path}.label", "label.too_long", {"max" => "255"}) if line.label.size > 255
      if !Api::VALUE_KINDS.includes?(line.kind) && line.label.strip.empty? && line.kind != "blank"
        errors << error("#{path}.label", "label.blank")
      end
      errors
    end

    # Erreur de la formule d'une ligne à montant, ou les lignes qu'elle cite.
    private def self.formula_line_error(line : Api::LineInput, path : String, lines : Array(Api::LineInput),
                                        codes : Hash(String, Int32)) : FieldError | Array(String)
      if failure = Formula.check(line.formula)
        return formula_error("#{path}.formula", failure)
      end
      parsed = Formula.parse(line.formula)
      if line.kind == "accounts" && !parsed.root.is_a?(Formula::AccountRef)
        return error("#{path}.formula", "accounts.single")
      end
      unknown = parsed.lines.find { |cited| !codes.has_key?(cited) || !Api::VALUE_KINDS.includes?(lines[codes[cited]].kind) }
      return error("#{path}.formula", "line.unknown", {"code" => unknown}) if unknown
      parsed.lines
    end

    # Boucles entre lignes (`$A` cite `$B` qui cite `$A`).
    private def self.cycle_errors(lines : Array(Api::LineInput), codes : Hash(String, Int32),
                                  references : Hash(Int32, Array(String)), errors : Array(FieldError)) : Nil
      state = {} of Int32 => Symbol
      references.each_key do |index|
        next if state[index]? == :done
        if cyclic?(index, codes, references, state)
          errors << error("lines[#{index}].formula", "line.cycle")
          return
        end
      end
    end

    private def self.cyclic?(index : Int32, codes : Hash(String, Int32), references : Hash(Int32, Array(String)),
                             state : Hash(Int32, Symbol)) : Bool
      case state[index]?
      when :done   then return false
      when :active then return true
      end
      state[index] = :active
      cyclic = (references[index]? || [] of String).any? do |code|
        target = codes[code]?
        target ? cyclic?(target, codes, references, state) : false
      end
      state[index] = :done
      cyclic
    end

    # --- Listings ------------------------------------------------------------------------

    def self.listing_errors(input : Api::ListingInput, id : Int64? = nil) : Array(FieldError)
      errors = [] of FieldError
      code = normalize_code(input.code)
      if !code.matches?(CODE)
        errors << error("code", "code.invalid")
      elsif Listing.all.filter(code__iexact: code).to_a.any? { |row| row.id != id }
        errors << error("code", "code.taken")
      end
      errors << error("name", "name.blank") if input.name.strip.empty?
      errors << error("name", "name.too_long", {"max" => "120"}) if input.name.strip.size > 120
      if !input.card_kind.empty? && !Partiduo::Api::Cards::KINDS.includes?(input.card_kind)
        errors << error("card_kind", "choice.invalid")
      end
      if input.columns.empty? || input.columns.size > Api::MAX_LISTING_COLUMNS
        errors << error("columns", "columns.count", {"max" => Api::MAX_LISTING_COLUMNS.to_s})
      end
      codes = input.columns.map { |column| normalize_code(column.code) }
      input.columns.each_with_index do |column, index|
        errors.concat(listing_column_errors(column, "columns[#{index}]", codes, index))
      end
      sort = normalize_code(input.sort_code)
      errors << error("sort_code", "column.unknown", {"code" => sort}) unless sort.empty? || codes.includes?(sort)
      errors.concat(condition_errors(input.conditions, codes))
      errors
    end

    private def self.listing_column_errors(column : Api::ListingColumnInput, path : String, codes : Array(String),
                                           index : Int32) : Array(FieldError)
      errors = [] of FieldError
      code = codes[index]
      if !code.matches?(CODE)
        errors << error("#{path}.code", "code.invalid")
      elsif codes[0, index].includes?(code)
        errors << error("#{path}.code", "code.duplicate")
      end
      errors << error("#{path}.label", "label.blank") if column.label.strip.empty?
      errors << error("#{path}.label", "label.too_long", {"max" => "60"}) if column.label.strip.size > 60
      source_error(column, path, codes).try { |found| errors << found }
      errors
    end

    # Champ connu, clé d'attribut bien formée, ou formule valide qui ne
    # cite que des colonnes du listing.
    private def self.source_error(column : Api::ListingColumnInput, path : String, codes : Array(String)) : FieldError?
      case column.source
      when "field"
        error("#{path}.field_name", "choice.invalid") unless Api::CARD_FIELDS.includes?(column.field_name)
      when "attribute"
        error("#{path}.field_name", "attribute.blank") unless column.field_name.strip.matches?(/\A[a-z0-9_]{1,40}\z/)
      when "formula"
        if failure = Formula.check(column.formula, current: true)
          return formula_error("#{path}.formula", failure)
        end
        unknown = Formula.parse(column.formula).lines.find { |cited| !codes.includes?(cited) }
        error("#{path}.formula", "line.unknown", {"code" => unknown}) if unknown
      else
        error("#{path}.source", "choice.invalid")
      end
    end

    private def self.condition_errors(conditions : Array(Api::ConditionInput), codes : Array(String)) : Array(FieldError)
      errors = [] of FieldError
      errors << error("conditions", "conditions.count", {"max" => Api::MAX_CONDITIONS.to_s}) if conditions.size > Api::MAX_CONDITIONS
      conditions.each_with_index do |condition, index|
        path = "conditions[#{index}]"
        cited = normalize_code(condition.column_code)
        errors << error("#{path}.column_code", "column.unknown", {"code" => cited}) unless codes.includes?(cited)
        errors << error("#{path}.operator", "choice.invalid") unless Api::OPERATORS.includes?(condition.operator)
        errors << error("#{path}.value", "label.too_long", {"max" => "255"}) if condition.value.size > 255
      end
      errors
    end
  end
end
