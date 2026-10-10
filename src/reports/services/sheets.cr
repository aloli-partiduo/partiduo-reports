# SPDX-License-Identifier: AGPL-3.0-or-later

module Reports
  # Fichiers exportés (D-REP-013) : un tableau neutre (`Sheet`) rendu en
  # CSV (`;`, UTF-8 avec BOM, montants au point décimal, texte protégé
  # contre les formules), en ODS (OpenDocument, montants typés, styles des
  # titres et des totaux) ou en PDF/A-2b par le service neutre du socle
  # (`Partiduo::Api::Core.table_pdf`). Interne.
  module Sheets
    # Cellule : texte, ou montant (`amount`).
    record Cell, text : String = "", amount : BigDecimal? = nil

    # Ligne : style (`line`, `heading`, `subtotal`, `total`), retrait.
    record Row, cells : Array(Cell), style : String = "line", indent : Int32 = 0

    record Column, title : String, amount : Bool = false

    record Sheet, name : String, title : String, subtitle : Array(String), columns : Array(Column),
      rows : Array(Row), decimals : Int32 = 2

    # --- Rapports et listings en tableaux --------------------------------------------------

    # Style d'export d'une ligne calculée.
    def self.style(line : Api::RunLineView) : String
      case line.kind
      when "title", "heading1", "heading2", "heading3" then "heading"
      else
        case line.style
        when "bold"  then "subtotal"
        when "total" then "total"
        else              "line"
        end
      end
    end

    def self.run_sheet(run : Api::RunView, title : String? = nil) : Sheet
      columns = [Column.new(I18n.t("reports.export.label"))] + run.columns.map { |column| Column.new(column.label, true) }
      rows = run.lines.map do |line|
        label = line.account ? "#{line.account} #{line.label}" : line.label
        cells = [Cell.new(label)] + line.values.map { |value| value ? Cell.new(amount: value) : Cell.new }
        Row.new(cells, style(line), line.indent)
      end
      Sheet.new(name: "#{run.code.downcase}-#{Records.iso(run.date_from)}-#{Records.iso(run.date_to)}",
        title: title || run.name, subtitle: [Numbers.range_label(run.date_from, run.date_to)], columns: columns,
        rows: rows, decimals: run.decimals)
    end

    def self.listing_sheet(result : Api::ListingResultView, title : String? = nil) : Sheet
      columns = [Column.new(I18n.t("reports.export.card"))] + result.columns.map { |column| Column.new(column.label, column.amount) }
      rows = result.rows.map do |row|
        Row.new([Cell.new(row.card_code)] + row.cells.map { |cell| Cell.new(cell.text, cell.amount) })
      end
      if result.totals.present?
        rows << Row.new([Cell.new(I18n.t("reports.export.total"))] + result.totals.map { |value| value ? Cell.new(amount: value) : Cell.new }, "total")
      end
      Sheet.new(name: "#{result.code.downcase}-#{Records.iso(result.date_to)}", title: title || result.name,
        subtitle: [Numbers.range_label(result.date_from, result.date_to)], columns: columns, rows: rows)
    end

    # Source de publipostage d'un listing (D-REP-012) : en-tête des codes de
    # colonnes, une ligne par fiche, montants bruts.
    def self.merge_listing(result : Api::ListingResultView) : Sheet
      columns = [Column.new("QUICKCODE"), Column.new("NAME")] + result.columns.map { |column| Column.new(column.code, column.amount) }
      rows = result.rows.map do |row|
        Row.new([Cell.new(row.card_code), Cell.new(row.card_name)] + row.cells.map { |cell| Cell.new(cell.text, cell.amount) })
      end
      Sheet.new(name: "#{result.code.downcase}-publipostage", title: result.name, subtitle: [] of String,
        columns: columns, rows: rows)
    end

    # Balises d'une déclaration (D-REP-010) : un enregistrement unique,
    # une colonne par balise (`CODE` pour la première colonne, `CODE_COL`
    # pour les autres, puis les balises du dossier et de la période).
    def self.merge_run(run : Api::RunView, title : String, description : String) : Sheet
      columns = [] of Column
      cells = [] of Cell
      rows = run.lines
      rows.each do |line|
        next if line.code.empty? || !line.value?
        line.values.each_with_index do |value, index|
          tag = index.zero? ? line.code : "#{line.code}_#{run.columns[index].code}"
          columns << Column.new(tag, true)
          cells << Cell.new(amount: value)
        end
      end
      Tags.special(run, title, description).each do |(tag, value)|
        columns << Column.new(tag)
        cells << Cell.new(value)
      end
      Sheet.new(name: "#{run.code.downcase}-balises", title: title, subtitle: [] of String, columns: columns,
        rows: [Row.new(cells)], decimals: run.decimals)
    end

    # --- Rendus --------------------------------------------------------------------------

    def self.file(sheet : Sheet, format : String, actor : Partiduo::Api::Actor) : Partiduo::Api::Result(Api::FileView)
      case format
      when "ods"
        Partiduo::Api::Result(Api::FileView).success(Api::FileView.new("#{sheet.name}.ods",
          "application/vnd.oasis.opendocument.spreadsheet", Ods.build(sheet)))
      when "pdf"
        pdf(sheet, actor)
      else
        Partiduo::Api::Result(Api::FileView).success(Api::FileView.new("#{sheet.name}.csv", "text/csv; charset=utf-8",
          csv(sheet).to_slice))
      end
    end

    def self.csv(sheet : Sheet) : String
      String.build do |io|
        io << '﻿'
        io << sheet.columns.map { |column| csv_text(column.title) }.join(';') << "\r\n"
        sheet.rows.each do |row|
          cells = row.cells.map do |cell|
            if amount = cell.amount
              Numbers.raw(amount, sheet.decimals)
            else
              csv_text(cell.text)
            end
          end
          io << cells.join(';') << "\r\n"
        end
      end
    end

    # Texte d'une cellule CSV : entre guillemets si besoin ; une cellule qui
    # commencerait une formule de tableur (`=`, `+`, `-`, `@`) est préfixée
    # d'une apostrophe.
    def self.csv_text(text : String) : String
      value = text.matches?(/\A[=+\-@\t\r]/) ? "'#{text}" : text
      value.matches?(/[;"\r\n]/) ? %("#{value.gsub('"', "\"\"")}") : value
    end

    private def self.pdf(sheet : Sheet, actor : Partiduo::Api::Actor) : Partiduo::Api::Result(Api::FileView)
      columns = sheet.columns.map_with_index do |column, index|
        Partiduo::Api::Core::TableColumnInput.new(column.title, column.amount ? "amount" : "text", index.zero? ? 3.0 : 1.2)
      end
      rows = sheet.rows.map do |row|
        cells = row.cells.map { |cell| (amount = cell.amount) ? Numbers.amount(amount, sheet.decimals) : cell.text }
        Partiduo::Api::Core::TableRowInput.new(cells[0, columns.size], row.style, row.indent.clamp(0, 10))
      end
      input = Partiduo::Api::Core::TableInput.new(name: sheet.name, title: sheet.title, columns: columns, rows: rows, subtitle: sheet.subtitle)
      result = Partiduo::Api::Core.table_pdf(actor, input)
      if file = result.value?
        Partiduo::Api::Result(Api::FileView).success(Api::FileView.new(file.filename, file.content_type, file.content))
      else
        Partiduo::Api::Result(Api::FileView).failure(result.errors)
      end
    end
  end
end
