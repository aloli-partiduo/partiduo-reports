# SPDX-License-Identifier: AGPL-3.0-or-later

require "csv"

module Reports
  # Import d'une définition de rapport exportée par l'application d'origine
  # (fichier `.bin` : CSV `;`, en-tête `RAPAV;<version>`, D-REP-015) :
  # lignes et détails convertis dans le langage de l'extension ; ce qui ne
  # se convertit pas (TVA par code, opérations rapprochées, date de
  # paiement ou d'échéance, formule illisible) devient une remarque et un
  # avertissement. Interne.
  module Legacy
    alias Formula = Reports::Formula

    TYPES = {"1" => "heading1", "2" => "heading2", "3" => "formula", "6" => "heading3", "7" => "text",
             "8" => "note", "9" => "accounts", "10" => "title"}

    # Période d'une ligne (`t_id`) : options ajoutées à ses références.
    PERIODS = {"2" => "span=year", "3" => "span=year; shift=-1", "4" => "span=year; shift=-2",
               "5" => "span=year; shift=-3", "6" => "span=ytd"}

    MODES = {"1" => "s", "2" => "S", "3" => "d", "4" => "c"}

    record Line, id : String, code : String, label : String, type : String, order : Int32, period : String

    record Detail, line_id : String, account : String, formula : String, type : String, with : String,
      sum_type : String, date_paid : String

    # Rapport lu, et ce qui n'a pas été repris.
    record Converted, input : Api::ReportInput, issues : Array(Api::IssueView)

    def self.load(text : String) : Converted
      raise Sharing::Invalid.new("import.too_large", {"max" => "2 Mo"}) if text.bytesize > Sharing::MAX_SIZE
      rows = begin
        CSV.parse(text.lchop('﻿'), separator: ';')
      rescue CSV::MalformedCSVError
        raise Sharing::Invalid.new("legacy.format")
      end
      header = rows.shift? || raise Sharing::Invalid.new("legacy.format")
      raise Sharing::Invalid.new("legacy.format") unless header[0]?.try(&.strip) == "RAPAV"
      version = header[1]?.try(&.strip.to_i?) || 1
      heading = rows.shift? || raise Sharing::Invalid.new("legacy.format")
      rows.reject!(&.all?(&.strip.empty?))
      split = rows.index { |row| cell(row, 0) == "RAPAV_DETAIL" } || rows.size
      lines = rows[0, split].map { |row| line(row, version) }
      details = (rows[(split + 1)..]? || [] of Array(String)).map { |row| detail(row, version) }
      convert(heading[0]? || "", heading[1]? || "", lines.sort_by(&.order), details)
    end

    private def self.cell(row : Array(String), index : Int32, default : String = "") : String
      (row[index]? || default).strip
    end

    # Ligne d'un rapport : `p_id;p_code;p_libelle;p_type;p_order;f_id;t_id`
    # (format 2 : une colonne de plus, retirée).
    private def self.line(row : Array(String), version : Int32) : Line
      row = row.dup
      row.delete_at(5) if version == 2 && row.size >= 8
      Line.new(cell(row, 0), cell(row, 1), row[2]? || "", cell(row, 3), cell(row, 4, "0").to_i? || 0, cell(row, 6, "1"))
    end

    # Détail : `fp_id;p_id;tmp_val;tva_id;fp_formula;fp_signed;jrn_def_type;
    # tt_id;type_detail;with_tmp_val;type_sum_account;operation_pcm_val;
    # date_paid` (avant le format 4 : sans date de paiement).
    private def self.detail(row : Array(String), version : Int32) : Detail
      Detail.new(cell(row, 1), cell(row, 2), cell(row, 4), cell(row, 8), cell(row, 9), cell(row, 10),
        version < 4 ? "0" : cell(row, 12, "0"))
    end

    private def self.convert(title : String, description : String, lines : Array(Line), details : Array(Detail)) : Converted
      issues = [] of Api::IssueView
      codes = line_codes(lines)
      inputs = lines.map { |line| convert_line(line, details.select(&.line_id.==(line.id)), codes, issues) }
      name = title.strip.presence || "RAPAV"
      code = name.upcase.unicode_normalize(:nfkd).gsub(/[^A-Z0-9]/, "")[0, 16]
      code = "RAPAV" unless code.matches?(/\A[A-Z]/)
      input = Api::ReportInput.new(code: code, name: name[0, 120], description: description.strip, decimals: 2,
        lines: inputs)
      Converted.new(input, issues)
    end

    # Codes des lignes à montant, rendus valides et uniques (ancien code →
    # nouveau), pour les lignes et les formules qui les citent.
    private def self.line_codes(lines : Array(Line)) : Hash(String, String)
      codes = {} of String => String
      lines.each do |line|
        next unless {"3", "9"}.includes?(line.type)
        cleaned = line.code.upcase.gsub(/[^A-Z0-9_]/, "")
        cleaned = "L#{cleaned}" unless cleaned.matches?(/\A[A-Z]/)
        cleaned = cleaned[0, 20]
        candidate = cleaned
        number = 2
        while codes.values.includes?(candidate)
          candidate = "#{cleaned[0, 16]}_#{number}"
          number += 1
        end
        codes[line.code.upcase] = candidate
      end
      codes
    end

    private def self.convert_line(line : Line, own : Array(Detail), codes : Hash(String, String),
                                  issues : Array(Api::IssueView)) : Api::LineInput
      kind = TYPES[line.type]? || "note"
      label = line.label.strip[0, 255]
      return Api::LineInput.new(label: label.presence || "—", kind: kind) unless Api::VALUE_KINDS.includes?(kind)
      parts = own.compact_map { |detail| detail_formula(detail, codes, issues, label) }
      formula = parts.size == 1 ? parts.first : parts.map { |part| "(#{part})" }.join(" + ")
      if (options = PERIODS[line.period]?) && !formula.empty?
        formula = with_options(formula, options)
      end
      return Api::LineInput.new(label: label, kind: kind, code: codes[line.code.upcase], formula: formula) if valid?(formula, kind)
      sources = own.map(&.formula).reject(&.empty?).join(" | ")
      issues << Api::IssueView.new("legacy_line", {"line" => label, "formula" => sources})
      Api::LineInput.new(label: "#{label} — #{sources}".strip(" —"), kind: "note")
    end

    private def self.valid?(formula : String, kind : String) : Bool
      return false if formula.empty? || Formula.check(formula)
      kind != "accounts" || Formula.parse(formula).root.is_a?(Formula::AccountRef)
    end

    # Formule d'un détail, ou `nil` (avec un avertissement) s'il n'a pas
    # d'équivalent.
    private def self.detail_formula(detail : Detail, codes : Hash(String, String), issues : Array(Api::IssueView),
                                    label : String) : String?
      if detail.date_paid.in?("1", "2")
        issues << Api::IssueView.new("legacy_date_paid", {"line" => label})
      end
      case detail.type
      when "1"
        convert_formula(detail.formula.gsub(/\s*FROM\s*=\s*\d{1,2}\.\d{4}\s*\z/, ""))
      when "3"
        compute = detail.formula.gsub(/\[([A-Za-z0-9_]+)\]/) do |_, match|
          "$#{codes[match[1].upcase]? || match[1].upcase}"
        end
        convert_formula(compute)
      when "4", "6"
        account_formula(detail)
      else
        key = {"2" => "legacy_vat", "5" => "legacy_reconciled"}[detail.type]?
        issues << Api::IssueView.new(key, {"line" => label}) if key
        nil
      end
    end

    # Poste (motif), contrepartie, sens du total : référence de comptes.
    private def self.account_formula(detail : Detail) : String?
      account = detail.account.upcase.gsub(/[^0-9A-Z%]/, "")
      return if account.empty?
      pattern = account.rchop('%').gsub("%", "")
      prefix = detail.type == "6" || account.ends_with?('%')
      options = detail.with.empty? ? "" : "; with=#{detail.with.upcase.gsub(/[^0-9A-Z]/, "")}"
      "[#{pattern}#{prefix ? "%" : ""}-#{MODES[detail.sum_type]? || "s"}#{options}]"
    end

    # Ancienne syntaxe (`[70%s]` → `[70%-s]`) et ternaire simple
    # (`(a > b)?x:y` → `if(a > b, x, y)`).
    def self.convert_formula(text : String) : String
      converted = text.strip.gsub(/\[([0-9A-Za-z]+%*)([cdsS])\]/) { |_, match| "[#{match[1]}-#{match[2]}]" }
      if match = converted.match(/\A\(\s*(.+?)\s*(>=|<=|<>|>|<|=)\s*(.+?)\s*\)\s*\?\s*(.+?)\s*:\s*(.+)\z/)
        converted = "if(#{match[1]} #{match[2]} #{match[3]}, #{match[4]}, #{match[5]})"
      end
      converted
    end

    # Ajoute des options à chaque référence (comptes, fiches, analytique).
    def self.with_options(formula : String, options : String) : String
      formula.gsub(/\{\{[^{}]+\}\}|\{[^{}]+\}|\[[^\[\]]+\]/) do |reference|
        closing = reference.starts_with?("{{") ? "}}" : reference[-1].to_s
        "#{reference[0, reference.size - closing.size]}; #{options}#{closing}"
      end
    end
  end
end
