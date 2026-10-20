# SPDX-License-Identifier: AGPL-3.0-or-later

module Reports
  # Calcul d'un listing de fiches (D-REP-011, D-REP-012) : fiches de la
  # catégorie ou de la nature choisie, lues par `Partiduo::Api::Cards` ;
  # une valeur par colonne (champ, attribut, formule où `{*}` et `card=*`
  # désignent la fiche de la ligne, `$CODE` une autre colonne de la même
  # fiche) ; conditions appliquées ensemble ; tri ; totaux des montants.
  # Interne.
  class ListingEngine
    alias Range = Periods::Range
    alias Formula = Reports::Formula
    alias Cards = Partiduo::Api::Cards

    ZERO = BigDecimal.new(0)

    @parsed = {} of Int32 => Formula::Parsed
    @by_code = {} of String => Int32

    def initialize(@actor : Partiduo::Api::Actor, @listing : Api::ListingView, @sources : Sources = Sources.new(actor))
    end

    def run(range : Range) : Api::ListingResultView
      columns = @listing.columns
      columns.each_with_index do |column, index|
        @by_code[column.code] = index
        next unless column.source == "formula"
        begin
          @parsed[index] = Formula.parse(column.formula)
        rescue error : Formula::Error
          @sources.issue("formula_error", {"line" => column.code, "error" => error.key})
        end
      end
      rows = cards.compact_map do |card|
        cells = Array(Api::CellView?).new(columns.size, nil)
        columns.each_index { |index| cell(card, index, range, cells, Set(Int32).new) }
        row = Api::ListingRowView.new(card.id, card.code, card.name, cells.map { |item| item || Api::CellView.new })
        row if keep?(row)
      end
      rows = sort(rows)
      visible = columns.each_index.reject { |index| columns[index].hidden }.to_a
      result_columns = visible.map do |index|
        column = columns[index]
        Api::ListingResultColumnView.new(column.code, column.label, column.amount?)
      end
      shown = rows.map { |row| Api::ListingRowView.new(row.card_id, row.card_code, row.card_name, visible.map { |index| row.cells[index] }) }
      totals = visible.map do |index|
        columns[index].amount? ? rows.sum(ZERO) { |row| row.cells[index].amount || ZERO } : nil
      end
      Api::ListingResultView.new(listing_id: @listing.id, code: @listing.code, name: @listing.name, date_from: range.from,
        date_to: range.to, columns: result_columns, rows: shown, totals: totals, issues: @sources.issues,
        paid: @sources.default_paid)
    end

    # --- Fiches --------------------------------------------------------------------------

    private def cards : Array(Cards::CardView)
      category_id = nil
      unless @listing.category_code.empty?
        category = guarded { Cards.category_by_code(@actor, @listing.category_code) }
        unless category
          @sources.issue("category_unknown", {"code" => @listing.category_code})
          return [] of Cards::CardView
        end
        category_id = category.id
      end
      kind = @listing.card_kind.presence
      enabled = @listing.include_disabled ? nil : true
      list = [] of Cards::CardView
      offset = 0
      loop do
        page = guarded { Cards.cards(@actor, Cards::CardQuery.new(category_id: category_id, kind: kind, enabled: enabled, limit: 1000, offset: offset)) }
        break unless page
        list.concat(page)
        offset += 1000
        break if page.size < 1000
        if list.size >= Api::MAX_CARDS
          @sources.issue("cards_truncated", {"max" => Api::MAX_CARDS.to_s})
          break
        end
      end
      list
    end

    private def guarded(& : -> T) : T? forall T
      yield
    rescue error : Partiduo::Api::ModuleDisabled
      @sources.issue("module_disabled", {"code" => error.module_code})
      nil
    rescue Partiduo::Api::AccessDenied
      @sources.issue("forbidden", {"permission" => "cards.card.read"})
      nil
    end

    # --- Cellules ------------------------------------------------------------------------

    private def cell(card : Cards::CardView, index : Int32, range : Range, cells : Array(Api::CellView?),
                     visiting : Set(Int32)) : Api::CellView
      if done = cells[index]
        return done
      end
      column = @listing.columns[index]
      result = case column.source
               when "attribute"
                 Api::CellView.new(text: ListingEngine.extra(card, column.field_name))
               when "formula"
                 if visiting.add?(index)
                   amount = formula(card, index, range, cells, visiting)
                   visiting.delete(index)
                   Api::CellView.new(text: "", amount: amount)
                 else
                   @sources.issue("cycle", {"line" => column.code})
                   Api::CellView.new(text: "", amount: ZERO)
                 end
               else
                 ListingEngine.field(card, column.field_name)
               end
      cells[index] = result
    end

    private def formula(card : Cards::CardView, index : Int32, range : Range, cells : Array(Api::CellView?),
                        visiting : Set(Int32)) : BigDecimal
      parsed = @parsed[index]? || return ZERO
      parsed.evaluate(CardContext.new(self, card, index, range, parsed, cells, visiting))
    rescue error : Formula::Error
      @sources.issue("formula_error", {"line" => @listing.columns[index].code, "error" => error.key})
      ZERO
    end

    # Valeur numérique d'une autre colonne de la même fiche (`$CODE`) : le
    # montant, ou le texte lu comme un nombre (zéro sinon).
    protected def column_amount(code : String, card : Cards::CardView, range : Range, cells : Array(Api::CellView?),
                                visiting : Set(Int32)) : BigDecimal
      index = @by_code[code]? || raise Formula::Error.new("line_unknown", {"code" => code})
      value = cell(card, index, range, cells, visiting)
      value.amount || ListingEngine.number(value.text) || ZERO
    end

    protected def sources : Sources
      @sources
    end

    def self.number(text : String) : BigDecimal?
      cleaned = text.strip.gsub(/[\s  ]/, "").gsub(',', '.')
      return unless cleaned.matches?(/\A-?\d+(\.\d+)?\z/)
      BigDecimal.new(cleaned)
    end

    alias Text = Proc(Cards::CardView, String)

    # Texte des champs d'une fiche (`Api::CARD_FIELDS`, hors prix).
    TEXT_FIELDS = {
      "code"          => Text.new(&.code),
      "name"          => Text.new(&.name),
      "category"      => Text.new(&.category_name),
      "kind"          => Text.new { |card| I18n.t("cards.kinds.#{card.kind}") },
      "description"   => Text.new(&.description),
      "vat_number"    => Text.new(&.vat_number),
      "siren"         => Text.new(&.siren),
      "siret"         => Text.new(&.siret),
      "email"         => Text.new(&.email),
      "phone"         => Text.new(&.phone),
      "contact_name"  => Text.new(&.contact_name),
      "address_line1" => Text.new { |card| card.address.try(&.line1) || "" },
      "address_line2" => Text.new { |card| card.address.try(&.line2) || "" },
      "postcode"      => Text.new { |card| card.address.try(&.postcode) || "" },
      "city"          => Text.new { |card| card.address.try(&.city) || "" },
      "country"       => Text.new { |card| card.address.try(&.country_code) || "" },
      "iban"          => Text.new(&.iban),
      "bic"           => Text.new(&.bic),
      "enabled"       => Text.new { |card| I18n.t(card.enabled ? "reports.answers.yes" : "reports.answers.no") },
    }

    # Champ d'une fiche (`Api::CARD_FIELDS`).
    def self.field(card : Cards::CardView, name : String) : Api::CellView
      case name
      when "sale_price"     then Api::CellView.new(amount: card.sale_price || ZERO)
      when "purchase_price" then Api::CellView.new(amount: card.purchase_price || ZERO)
      else                       Api::CellView.new(text: TEXT_FIELDS[name]?.try(&.call(card)) || "")
      end
    end

    # Attribut libre de la catégorie (`extra`), en texte.
    def self.extra(card : Cards::CardView, key : String) : String
      value = card.extra[key]? || return ""
      value.as_s? || (value.raw.nil? ? "" : value.to_json)
    end

    # --- Conditions et tri ---------------------------------------------------------------

    private def keep?(row : Api::ListingRowView) : Bool
      @listing.conditions.all? do |condition|
        index = @by_code[condition.column_code]? || next true
        ListingEngine.matches?(row.cells[index], condition.operator, condition.value)
      end
    end

    # Une cellule satisfait-elle une condition ? Montants comparés en
    # nombres, textes sans casse.
    def self.matches?(cell : Api::CellView, operator : String, value : String) : Bool
      if operator == "contains"
        return (cell.amount.try(&.to_s) || cell.text).downcase.includes?(value.strip.downcase)
      end
      comparison = compare(cell, value) || return false
      case operator
      when "eq" then comparison == 0
      when "ne" then comparison != 0
      when "lt" then comparison < 0
      when "le" then comparison <= 0
      when "gt" then comparison > 0
      else           comparison >= 0
      end
    end

    # Ordre d'une cellule par rapport à une valeur : en nombres si les deux
    # en sont, sinon en textes sans casse ; `nil` pour un montant comparé à
    # un texte.
    private def self.compare(cell : Api::CellView, value : String) : Int32?
      if amount = cell.amount
        expected = number(value) || return
        return amount <=> expected
      end
      if (left = number(cell.text)) && (right = number(value))
        left <=> right
      else
        cell.text.downcase <=> value.strip.downcase
      end
    end

    private def sort(rows : Array(Api::ListingRowView)) : Array(Api::ListingRowView)
      index = @by_code[@listing.sort_code]?
      sorted = if index
                 rows.sort do |left, right|
                   a = left.cells[index]
                   b = right.cells[index]
                   order = if (x = a.amount) && (y = b.amount)
                             x <=> y
                           else
                             a.text.downcase <=> b.text.downcase
                           end
                   order.zero? ? left.card_name.downcase <=> right.card_name.downcase : order
                 end
               else
                 rows.sort_by { |row| {row.card_name.downcase, row.card_id} }
               end
      @listing.sort_desc ? sorted.reverse : sorted
    end

    # Contexte d'une formule de listing : la fiche de la ligne.
    class CardContext < Formula::Context
      def initialize(@engine : ListingEngine, @card : Cards::CardView, @index : Int32, @range : Range,
                     @parsed : Formula::Parsed, @cells : Array(Api::CellView?), @visiting : Set(Int32))
      end

      private def range_for(options : Formula::Options) : Range
        range = @engine.sources.calendar.resolve(@range, options.span || "period", options.shift_months)
        if from = @parsed.from
          range = Range.new(from, range.to)
        end
        range
      end

      def account(ref : Formula::AccountRef) : BigDecimal
        @engine.sources.account(ref, range_for(ref.options), @card.code)
      end

      def card(ref : Formula::CardRef) : BigDecimal
        if ref.current?
          return @engine.sources.card(@card.code, @card.kind, ref, range_for(ref.options))
        end
        view = @engine.sources.card_view(ref.code)
        unless view
          @engine.sources.issue("card_unknown", {"code" => ref.code})
          return BigDecimal.new(0)
        end
        @engine.sources.card(view.code, view.kind, ref, range_for(ref.options))
      end

      def analytic(ref : Formula::AnalyticRef) : BigDecimal
        @engine.sources.analytic(ref, range_for(ref.options))
      end

      def line(code : String) : BigDecimal
        @engine.column_amount(code, @card, @range, @cells, @visiting)
      end

      def column(code : String) : BigDecimal
        raise Formula::Error.new("column_ref", {"code" => code})
      end
    end
  end
end
