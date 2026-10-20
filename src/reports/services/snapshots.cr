# SPDX-License-Identifier: AGPL-3.0-or-later

module Reports
  # Résultats conservés (D-REP-009) : le calcul est écrit en JSON (montants
  # en texte décimal, jamais en flottant, dates `AAAA-MM-JJ`) et relu tel
  # quel. Interne.
  module Snapshots
    def self.decimal(value : BigDecimal?) : String?
      value.try(&.to_s)
    end

    def self.parse_decimal(value : JSON::Any?) : BigDecimal?
      text = value.try(&.as_s?) || return
      BigDecimal.new(text)
    end

    def self.date(value : Time?) : String?
      value.try { |day| Records.iso(day) }
    end

    def self.parse_date(value : JSON::Any?) : Time?
      value.try(&.as_s?).try { |text| Records.parse_day(text) }
    end

    def self.issues_json(json : JSON::Builder, issues : Array(Api::IssueView)) : Nil
      json.array { issues.each { |item| json.object { json.field "key", item.key; json.field "params", item.params } } }
    end

    def self.parse_issues(value : JSON::Any) : Array(Api::IssueView)
      value.as_a.map do |item|
        Api::IssueView.new(item["key"].as_s, item["params"].as_h.transform_values(&.as_s))
      end
    end

    # --- Déclarations --------------------------------------------------------------------

    def self.run_json(run : Api::RunView) : String
      JSON.build do |json|
        json.object do
          json.field "report_id", run.report_id
          json.field "code", run.code
          json.field "name", run.name
          json.field "date_from", date(run.date_from)
          json.field "date_to", date(run.date_to)
          json.field "step", run.step
          json.field "decimals", run.decimals
          json.field "columns" do
            json.array do
              run.columns.each do |column|
                json.object do
                  json.field "code", column.code
                  json.field "label", column.label
                  json.field "kind", column.kind
                  json.field "date_from", date(column.date_from)
                  json.field "date_to", date(column.date_to)
                end
              end
            end
          end
          rows = run.lines
          json.field "lines" do
            json.array do
              rows.each do |line|
                json.object do
                  json.field "code", line.code
                  json.field "label", line.label
                  json.field "kind", line.kind
                  json.field "style", line.style
                  json.field "indent", line.indent
                  json.field "account", line.account
                  json.field "values", line.values.map { |value| decimal(value) }
                  json.field "revised", line.revised
                end
              end
            end
          end
          json.field "issues" { issues_json(json, run.issues) }
        end
      end
    end

    def self.parse_run(text : String) : Api::RunView
      data = JSON.parse(text)
      columns = data["columns"].as_a.map do |column|
        Api::RunColumnView.new(column["code"].as_s, column["label"].as_s, column["kind"].as_s,
          parse_date(column["date_from"]?), parse_date(column["date_to"]?))
      end
      lines = data["lines"].as_a.map do |line|
        Api::RunLineView.new(code: line["code"].as_s, label: line["label"].as_s, kind: line["kind"].as_s,
          style: line["style"].as_s, indent: line["indent"].as_i, values: line["values"].as_a.map { |value| parse_decimal(value) },
          account: line["account"]?.try(&.as_s?), revised: line["revised"].as_a.map(&.as_s))
      end
      Api::RunView.new(report_id: data["report_id"].as_i64?, code: data["code"].as_s, name: data["name"].as_s,
        date_from: parse_date(data["date_from"]) || Records.today, date_to: parse_date(data["date_to"]) || Records.today,
        step: data["step"].as_s, decimals: data["decimals"].as_i, columns: columns, lines: lines,
        issues: parse_issues(data["issues"]))
    end

    # --- Listings ------------------------------------------------------------------------

    def self.listing_json(result : Api::ListingResultView) : String
      JSON.build do |json|
        json.object do
          json.field "listing_id", result.listing_id
          json.field "code", result.code
          json.field "name", result.name
          json.field "date_from", date(result.date_from)
          json.field "date_to", date(result.date_to)
          json.field "columns" do
            json.array do
              result.columns.each do |column|
                json.object do
                  json.field "code", column.code
                  json.field "label", column.label
                  json.field "amount", column.amount
                end
              end
            end
          end
          json.field "rows" do
            json.array do
              result.rows.each do |row|
                json.object do
                  json.field "card_id", row.card_id
                  json.field "card_code", row.card_code
                  json.field "card_name", row.card_name
                  json.field "cells" do
                    json.array do
                      row.cells.each do |cell|
                        json.object do
                          json.field "text", cell.text
                          json.field "amount", decimal(cell.amount)
                        end
                      end
                    end
                  end
                end
              end
            end
          end
          json.field "totals", result.totals.map { |value| decimal(value) }
          json.field "issues" { issues_json(json, result.issues) }
          json.field "paid", result.paid
        end
      end
    end

    # Un listing conservé avant le filtre « payé / non payé » (D-REP-024)
    # n'a pas la clé `paid` : toutes les écritures.
    def self.parse_listing(text : String) : Api::ListingResultView
      data = JSON.parse(text)
      columns = data["columns"].as_a.map do |column|
        Api::ListingResultColumnView.new(column["code"].as_s, column["label"].as_s, column["amount"].as_bool)
      end
      rows = data["rows"].as_a.map do |row|
        cells = row["cells"].as_a.map { |cell| Api::CellView.new(cell["text"].as_s, parse_decimal(cell["amount"]?)) }
        Api::ListingRowView.new(row["card_id"].as_i64, row["card_code"].as_s, row["card_name"].as_s, cells)
      end
      Api::ListingResultView.new(listing_id: data["listing_id"].as_i64?, code: data["code"].as_s, name: data["name"].as_s,
        date_from: parse_date(data["date_from"]) || Records.today, date_to: parse_date(data["date_to"]) || Records.today,
        columns: columns, rows: rows, totals: data["totals"].as_a.map { |value| parse_decimal(value) },
        issues: parse_issues(data["issues"]), paid: data["paid"]?.try(&.as_bool?))
    end

    # --- Vues ----------------------------------------------------------------------------

    def self.summary(row : Snapshot) : Api::SnapshotSummaryView
      Api::SnapshotSummaryView.new(row.id!.to_i64, row.kind!, row.definition_id.try(&.to_i64), row.definition_code!,
        row.definition_name!, row.title!, row.description!, Records.day(row.date_from!), Records.day(row.date_to!),
        Records.user_name(row.created_by_id.try(&.to_i64)), row.created_at!)
    end
  end
end
