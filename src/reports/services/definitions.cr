# SPDX-License-Identifier: AGPL-3.0-or-later

module Reports
  # Enregistrement et vues des définitions : un rapport ou un listing est
  # remplacé en bloc (en-tête, colonnes, lignes ou conditions), dans la
  # transaction de la commande. Interne.
  module Definitions
    # --- Rapports ----------------------------------------------------------------------

    def self.save_report!(row : Report, input : Api::ReportInput, actor : Partiduo::Api::Actor) : Report
      row.code = Checks.normalize_code(input.code)
      row.name = input.name.strip
      row.description = input.description.strip
      row.decimals = input.decimals
      row.created_by_id ||= actor.user_id
      row.save!
      id = row.id!.to_i64
      ReportColumn.filter(report_id: id).delete
      ReportLine.filter(report_id: id).delete
      input.columns.each_with_index do |column, index|
        ReportColumn.create!(report_id: id, position: index + 1, code: Checks.normalize_code(column.code),
          label: column.label.strip, kind: column.kind, span: column.span, shift_months: column.shift_months,
          formula: column.kind == "formula" ? column.formula.strip : "")
      end
      input.lines.each_with_index do |line, index|
        value = Api::VALUE_KINDS.includes?(line.kind)
        ReportLine.create!(report_id: id, position: index + 1, code: value ? Checks.normalize_code(line.code) : "",
          label: line.label.strip, kind: line.kind, formula: value ? line.formula.strip : "", style: line.style,
          indent: line.indent, negate: value && line.negate, hidden: value && line.hidden)
      end
      row
    end

    def self.report_view(row : Report) : Api::ReportView
      id = row.id!.to_i64
      columns = ReportColumn.filter(report_id: id).order(:position).to_a.map do |column|
        Api::ColumnView.new(column.position!.to_i, column.code!, column.label!, column.kind!, column.span!,
          column.shift_months!.to_i, column.formula!)
      end
      lines = ReportLine.filter(report_id: id).order(:position).to_a.map do |line|
        Api::LineView.new(line.position!.to_i, line.code!, line.label!, line.kind!, line.formula!, line.style!,
          line.indent!.to_i, line.negate!, line.hidden!)
      end
      Api::ReportView.new(id, row.code!, row.name!, row.description!, row.decimals!.to_i, columns, lines, row.updated_at!)
    end

    def self.report_summaries : Array(Api::ReportSummaryView)
      rows = Report.all.order(:name, :id).to_a
      ids = rows.map(&.id!.to_i64)
      lines = ReportLine.filter(report_id__in: ids).to_a.group_by(&.report_id!)
      columns = ReportColumn.filter(report_id__in: ids).to_a.group_by(&.report_id!)
      rows.map do |row|
        id = row.id!.to_i64
        Api::ReportSummaryView.new(id, row.code!, row.name!, row.description!, lines[id]?.try(&.size) || 0,
          columns[id]?.try(&.size) || 0, row.updated_at!)
      end
    end

    # --- Listings ------------------------------------------------------------------------

    def self.save_listing!(row : Listing, input : Api::ListingInput, actor : Partiduo::Api::Actor) : Listing
      row.code = Checks.normalize_code(input.code)
      row.name = input.name.strip
      row.description = input.description.strip
      row.category_code = input.category_code.strip
      row.card_kind = input.card_kind.strip
      row.include_disabled = input.include_disabled
      row.sort_code = Checks.normalize_code(input.sort_code)
      row.sort_desc = input.sort_desc
      row.created_by_id ||= actor.user_id
      row.save!
      id = row.id!.to_i64
      ListingColumn.filter(listing_id: id).delete
      ListingCondition.filter(listing_id: id).delete
      input.columns.each_with_index do |column, index|
        ListingColumn.create!(listing_id: id, position: index + 1, code: Checks.normalize_code(column.code),
          label: column.label.strip, source: column.source,
          field_name: column.source == "formula" ? "" : column.field_name.strip,
          formula: column.source == "formula" ? column.formula.strip : "", hidden: column.hidden)
      end
      input.conditions.each_with_index do |condition, index|
        ListingCondition.create!(listing_id: id, position: index + 1, column_code: Checks.normalize_code(condition.column_code),
          operator: condition.operator, value: condition.value.strip)
      end
      row
    end

    def self.listing_view(row : Listing) : Api::ListingView
      id = row.id!.to_i64
      columns = ListingColumn.filter(listing_id: id).order(:position).to_a.map do |column|
        Api::ListingColumnView.new(column.position!.to_i, column.code!, column.label!, column.source!, column.field_name!,
          column.formula!, column.hidden!)
      end
      conditions = ListingCondition.filter(listing_id: id).order(:position).to_a.map do |condition|
        Api::ConditionView.new(condition.position!.to_i, condition.column_code!, condition.operator!, condition.value!)
      end
      Api::ListingView.new(id, row.code!, row.name!, row.description!, row.category_code!, row.card_kind!,
        row.include_disabled!, row.sort_code!, row.sort_desc!, columns, conditions, row.updated_at!)
    end

    def self.listing_summaries : Array(Api::ListingSummaryView)
      rows = Listing.all.order(:name, :id).to_a
      columns = ListingColumn.filter(listing_id__in: rows.map(&.id!.to_i64)).to_a.group_by(&.listing_id!)
      rows.map do |row|
        id = row.id!.to_i64
        Api::ListingSummaryView.new(id, row.code!, row.name!, row.description!, row.category_code!, row.card_kind!,
          columns[id]?.try(&.size) || 0, row.updated_at!)
      end
    end

    # Code libre dérivé de `code` (`SIG`, `SIG_2`, `SIG_3`…) pour une copie
    # ou un import qui ne remplace pas.
    def self.free_code(code : String, taken : Proc(String, Bool)) : String
      base = Checks.normalize_code(code)[0, 16]
      return base unless taken.call(base)
      (2..999).each do |number|
        candidate = "#{base}_#{number}"
        return candidate unless taken.call(candidate)
      end
      base
    end

    def self.report_code_taken?(code : String) : Bool
      Report.filter(code__iexact: code).exists?
    end

    def self.listing_code_taken?(code : String) : Bool
      Listing.filter(code__iexact: code).exists?
    end
  end
end
