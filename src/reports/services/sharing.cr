# SPDX-License-Identifier: AGPL-3.0-or-later

module Reports
  # Partage des définitions entre dossiers (D-REP-014) : format JSON
  # `partiduo-reports`, version 1, décrit dans `doc/format-definitions.adoc`.
  # Un fichier porte des rapports et des listings ; les références à des
  # journaux, catégories, fiches ou postes se font par leur *code*, jamais
  # par un identifiant interne du dossier. Interne.
  module Sharing
    FORMAT    = "partiduo-reports"
    VERSION   =         1
    MAX_SIZE  = 2_000_000
    MAX_ITEMS =       200

    class Invalid < Exception
      getter key : String
      getter params : Hash(String, String)

      def initialize(@key : String, @params = {} of String => String)
        super(key)
      end
    end

    # Contenu lu : rapports et listings, avant contrôle.
    record Bundle, reports : Array(Api::ReportInput), listings : Array(Api::ListingInput)

    # --- Écriture ------------------------------------------------------------------------

    def self.dump(reports : Array(Api::ReportView), listings : Array(Api::ListingView)) : String
      JSON.build(2) do |json|
        json.object do
          json.field "format", FORMAT
          json.field "version", VERSION
          json.field "generator", "partiduo-reports #{Reports::VERSION}"
          json.field "exported_on", Records.iso(Records.today)
          json.field "reports" do
            json.array { reports.each { |report| report_json(json, report) } }
          end
          json.field "listings" do
            json.array { listings.each { |listing| listing_json(json, listing) } }
          end
        end
      end
    end

    private def self.report_json(json : JSON::Builder, report : Api::ReportView) : Nil
      json.object do
        json.field "code", report.code
        json.field "name", report.name
        json.field "description", report.description
        json.field "decimals", report.decimals
        json.field "columns" do
          json.array do
            report.columns.each do |column|
              json.object do
                json.field "code", column.code
                json.field "label", column.label
                json.field "kind", column.kind
                json.field "span", column.span
                json.field "shift_months", column.shift_months
                json.field "formula", column.formula
              end
            end
          end
        end
        rows = report.lines
        json.field "lines" do
          json.array do
            rows.each do |line|
              json.object do
                json.field "kind", line.kind
                json.field "code", line.code
                json.field "label", line.label
                json.field "formula", line.formula
                json.field "style", line.style
                json.field "indent", line.indent
                json.field "negate", line.negate
                json.field "hidden", line.hidden
              end
            end
          end
        end
      end
    end

    private def self.listing_json(json : JSON::Builder, listing : Api::ListingView) : Nil
      json.object do
        json.field "code", listing.code
        json.field "name", listing.name
        json.field "description", listing.description
        json.field "category_code", listing.category_code
        json.field "card_kind", listing.card_kind
        json.field "include_disabled", listing.include_disabled
        json.field "sort_code", listing.sort_code
        json.field "sort_desc", listing.sort_desc
        json.field "columns" do
          json.array do
            listing.columns.each do |column|
              json.object do
                json.field "code", column.code
                json.field "label", column.label
                json.field "source", column.source
                json.field "field_name", column.field_name
                json.field "formula", column.formula
                json.field "hidden", column.hidden
              end
            end
          end
        end
        json.field "conditions" do
          json.array do
            listing.conditions.each do |condition|
              json.object do
                json.field "column_code", condition.column_code
                json.field "operator", condition.operator
                json.field "value", condition.value
              end
            end
          end
        end
      end
    end

    # --- Lecture -------------------------------------------------------------------------

    def self.load(text : String) : Bundle
      raise Invalid.new("import.too_large", {"max" => "2 Mo"}) if text.bytesize > MAX_SIZE
      data = begin
        JSON.parse(text)
      rescue JSON::ParseException
        raise Invalid.new("import.json")
      end
      object = data.as_h? || raise Invalid.new("import.json")
      raise Invalid.new("import.format") unless object["format"]?.try(&.as_s?) == FORMAT
      version = object["version"]?.try(&.as_i?) || raise Invalid.new("import.format")
      raise Invalid.new("import.version", {"version" => version.to_s}) unless version == VERSION
      reports = list(object, "reports").map { |item| report(item) }
      listings = list(object, "listings").map { |item| listing(item) }
      raise Invalid.new("import.empty") if reports.empty? && listings.empty?
      raise Invalid.new("import.count", {"max" => MAX_ITEMS.to_s}) if reports.size + listings.size > MAX_ITEMS
      Bundle.new(reports, listings)
    end

    private def self.list(object : Hash(String, JSON::Any), key : String) : Array(Hash(String, JSON::Any))
      value = object[key]? || return [] of Hash(String, JSON::Any)
      items = value.as_a? || raise Invalid.new("import.structure", {"field" => key})
      items.map { |item| item.as_h? || raise Invalid.new("import.structure", {"field" => key}) }
    end

    private def self.text(item : Hash(String, JSON::Any), key : String, default : String = "") : String
      value = item[key]? || return default
      return default if value.raw.nil?
      value.as_s? || raise Invalid.new("import.structure", {"field" => key})
    end

    private def self.int(item : Hash(String, JSON::Any), key : String, default : Int32) : Int32
      value = item[key]? || return default
      value.as_i? || raise Invalid.new("import.structure", {"field" => key})
    end

    private def self.bool(item : Hash(String, JSON::Any), key : String) : Bool
      value = item[key]? || return false
      flag = value.as_bool?
      raise Invalid.new("import.structure", {"field" => key}) if flag.nil?
      flag
    end

    private def self.report(item : Hash(String, JSON::Any)) : Api::ReportInput
      columns = list(item, "columns").map do |column|
        Api::ColumnInput.new(code: text(column, "code"), label: text(column, "label"), kind: text(column, "kind", "period"),
          span: text(column, "span", "period"), shift_months: int(column, "shift_months", 0), formula: text(column, "formula"))
      end
      lines = list(item, "lines").map do |line|
        Api::LineInput.new(label: text(line, "label"), kind: text(line, "kind", "formula"), code: text(line, "code"),
          formula: text(line, "formula"), style: text(line, "style", "normal"), indent: int(line, "indent", 0),
          negate: bool(line, "negate"), hidden: bool(line, "hidden"))
      end
      Api::ReportInput.new(code: text(item, "code"), name: text(item, "name"), description: text(item, "description"),
        decimals: int(item, "decimals", 2), columns: columns, lines: lines)
    end

    private def self.listing(item : Hash(String, JSON::Any)) : Api::ListingInput
      columns = list(item, "columns").map do |column|
        Api::ListingColumnInput.new(code: text(column, "code"), label: text(column, "label"),
          source: text(column, "source", "field"), field_name: text(column, "field_name"),
          formula: text(column, "formula"), hidden: bool(column, "hidden"))
      end
      conditions = list(item, "conditions").map do |condition|
        Api::ConditionInput.new(column_code: text(condition, "column_code"), operator: text(condition, "operator"),
          value: text(condition, "value"))
      end
      Api::ListingInput.new(code: text(item, "code"), name: text(item, "name"), description: text(item, "description"),
        category_code: text(item, "category_code"), card_kind: text(item, "card_kind"),
        include_disabled: bool(item, "include_disabled"), sort_code: text(item, "sort_code"),
        sort_desc: bool(item, "sort_desc"), columns: columns, conditions: conditions)
    end
  end
end
