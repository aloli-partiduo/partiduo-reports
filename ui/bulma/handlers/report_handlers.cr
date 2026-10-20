# SPDX-License-Identifier: AGPL-3.0-or-later

module Reports
  module Ui
    # `/ext/REPORTS/reports` : les rapports définis (D-REP-005).
    class ReportsHandler < Handler
      def get
        design = can_design?
        columns = [
          Table::Column.new("code", I18n.t("reports_ui.reports.code"), "mono"),
          Table::Column.new("name", I18n.t("reports_ui.reports.name")),
          Table::Column.new("description", I18n.t("reports_ui.reports.description"), secondary: true),
          Table::Column.new("lines", I18n.t("reports_ui.reports.lines"), "amount", secondary: true),
        ]
        columns << Table::Column.new("actions", I18n.t("ui.forms.actions"), "actions") if design
        rows = Api.reports(actor).map do |item|
          cells = [Table::Cell.new(item.code, Ui.url("report", id: item.id)), Table::Cell.new(item.name, Ui.url("report", id: item.id)),
                   Table::Cell.new(item.description), Table::Cell.new(item.lines_count.to_s, sort: BigDecimal.new(item.lines_count))]
          if design
            cells << Table::Cell.new("", actions: [
              link_action("reports_ui.actions.edit", Ui.url("report_edit", id: item.id), "small", "pencil"),
              post_action("reports_ui.actions.copy", Ui.url("report_copy", id: item.id), nil, "small", "file-text"),
              post_action("reports_ui.actions.delete", Ui.url("report_delete", id: item.id), "reports_ui.reports.delete_confirm", "small", "trash-2"),
            ])
          end
          Table::Row.new(cells)
        end
        title = I18n.t("reports.menu.reports_advanced")
        table = Table.new(title, columns, rows, Ui.url("reports"), empty_message: I18n.t("reports_ui.reports.none"), id: "rep-reports")
        actions = [] of Screen::Action
        if design
          actions << link_action("reports_ui.reports.new", Ui.url("report_new"), "primary", "plus")
          actions << link_action("reports_ui.core.title", Ui.url("core_reports"), "", "refresh-cw")
          actions << link_action("reports.menu.reports_sharing", Ui.url("sharing"), "", "upload")
        end
        list_page(title, table, crumbs({title, nil}), "reports_ui.reports.csv_name", actions, intro: I18n.t("reports_ui.reports.intro"))
      end
    end

    # Éditeur d'un rapport : en-tête, colonnes, lignes ; ajout de ligne et
    # aperçu en HTMX, contrôle de chaque formule au changement ; sans
    # JavaScript, cinq lignes libres et l'enregistrement suffisent
    # (D-REP-017).
    abstract class ReportFormHandler < Handler
      BLANK_LINES   =   5
      BLANK_COLUMNS =   2
      MAX_INDEX     = 600

      abstract def existing : Api::ReportView?
      abstract def save(input : Api::ReportInput) : Partiduo::Api::Result(Api::ReportView)
      abstract def form_title : String
      abstract def action_url : String

      def get
        show(existing.try(&.to_input) || Api::ReportInput.new(code: "", name: "", columns: [Api::ColumnInput.new("N", I18n.t("reports.columns.default"))]),
          [] of Partiduo::Api::FieldError)
      end

      def post
        input = ReportFormHandler.submitted(self)
        result = save(input)
        if saved = result.value?
          flash["success"] = I18n.t("reports_ui.reports.saved", name: saved.name)
          return go(Ui.url("report", id: saved.id))
        end
        show(input, result.errors, 422)
      end

      private def show(input : Api::ReportInput, errors : Array(Partiduo::Api::FieldError), status : Int32 = 200) : Marten::HTTP::Response
        header = Form.new([Form::Group.new(nil, [
          Form::Field.new("code", I18n.t("reports_ui.reports.code"), value: input.code, required: true, mono: true, maxlength: 20,
            help: I18n.t("reports_ui.reports.code_help")),
          Form::Field.new("name", I18n.t("reports_ui.reports.name"), value: input.name, required: true, maxlength: 120),
          Form::Field.new("decimals", I18n.t("reports_ui.reports.decimals"), "select", input.decimals.to_s,
            options: (0..2).map { |digits| option(digits.to_s, digits.to_s) }),
          Form::Field.new("description", I18n.t("reports_ui.reports.description"), "textarea", input.description, wide: true),
        ])])
        header.add_errors(errors.reject { |error| error.field.starts_with?("lines[") || error.field.starts_with?("columns[") }, fmt)
        lines = input.lines + Array.new(input.lines.empty? ? BLANK_LINES : 1) { Api::LineInput.new }
        columns = input.columns + Array.new(BLANK_COLUMNS) { Api::ColumnInput.new(code: "", label: "") }
        page("reports/report_form.html", {
          "title"        => form_title,
          "crumbs"       => crumbs({I18n.t("reports.menu.reports_advanced"), Ui.url("reports")}, {form_title, nil}),
          "form"         => header,
          "form_action"  => action_url,
          "lines"        => lines.map_with_index { |line, index| ReportFormHandler.line_row(line, index, errors, fmt) },
          "columns"      => columns.map_with_index { |column, index| ReportFormHandler.column_row(column, index, errors, fmt) },
          "next_index"   => lines.size.to_s,
          "kinds"        => Ui.choices(Api::LINE_KINDS, "reports.line_kinds", ""),
          "styles"       => Ui.choices(Api::LINE_STYLES, "reports.line_styles", ""),
          "column_kinds" => Ui.choices(Api::COLUMN_KINDS, "reports.column_kinds", ""),
          "spans"        => Ui.choices(Api::SPANS, "reports.spans", ""),
          "steps"        => Ui.choices(Api::STEPS, "reports.steps", "none"),
          "check_url"    => Ui.url("formula_check"),
          "row_url"      => Ui.url("report_row"),
          "preview_url"  => Ui.url("report_preview"),
          "cancel_url"   => Ui.url("reports"),
        }, status: status)
      end

      # Ligne d'éditeur présentée (valeurs, erreurs du contrat).
      def self.line_row(line : Api::LineInput, index : Int32, errors : Array(Partiduo::Api::FieldError),
                        fmt : PartiduoUi::Format) : Row
        prefix = "lines[#{index}]."
        found = errors.select(&.field.starts_with?(prefix)).map { |error| fmt.message(error) }
        Ui.row({"index" => index.to_s, "position" => ((index + 1) * 10).to_s, "kind" => line.kind, "code" => line.code,
                "label" => line.label, "formula" => line.formula, "style" => line.style, "indent" => line.indent.to_s,
                "negate" => Ui.flag(line.negate), "hidden" => Ui.flag(line.hidden),
                "errors" => found.empty? ? nil : found.join(" ")})
      end

      def self.column_row(column : Api::ColumnInput, index : Int32, errors : Array(Partiduo::Api::FieldError),
                          fmt : PartiduoUi::Format) : Row
        prefix = "columns[#{index}]."
        found = errors.select(&.field.starts_with?(prefix)).map { |error| fmt.message(error) }
        Ui.row({"index" => index.to_s, "code" => column.code, "label" => column.label, "kind" => column.kind,
                "span" => column.span, "shift" => ReportFormHandler.shift_text(column.shift_months), "formula" => column.formula,
                "errors" => found.empty? ? nil : found.join(" ")})
      end

      # Décalage affiché : en années (`-1`) si entier, sinon en mois (`-3m`).
      def self.shift_text(months : Int32) : String
        return "" if months.zero?
        months % 12 == 0 ? (months // 12).to_s : "#{months}m"
      end

      def self.shift_months(text : String) : Int32
        match = text.strip.match(/\A([+-]?\d{1,3})\s*([ymYM]?)\z/) || return 0
        count = match[1].to_i
        match[2].downcase == "m" ? count : count * 12
      end

      # Définition envoyée : lignes triées par position, lignes vides et
      # cochées « supprimer » écartées.
      def self.submitted(handler : Handler) : Api::ReportInput
        Api::ReportInput.new(code: handler.field("code"), name: handler.field("name"), description: handler.field("description"),
          decimals: handler.field("decimals").to_i? || 2, columns: submitted_columns(handler), lines: submitted_lines(handler))
      end

      private def self.submitted_columns(handler : Handler) : Array(Api::ColumnInput)
        columns = [] of Api::ColumnInput
        (0...20).each do |index|
          prefix = "columns[#{index}]."
          next unless handler.request.data.has_key?("#{prefix}code")
          code = handler.field("#{prefix}code")
          label = handler.field("#{prefix}label")
          next if (code.empty? && label.empty?) || handler.field("#{prefix}delete") == "1"
          columns << Api::ColumnInput.new(code: code, label: label, kind: handler.field("#{prefix}kind").presence || "period",
            span: handler.field("#{prefix}span").presence || "period", shift_months: shift_months(handler.field("#{prefix}shift")),
            formula: handler.field("#{prefix}formula"))
        end
        columns
      end

      private def self.submitted_lines(handler : Handler) : Array(Api::LineInput)
        lines = [] of {Int32, Int32, Api::LineInput}
        (0...MAX_INDEX).each do |index|
          prefix = "lines[#{index}]."
          next unless handler.request.data.has_key?("#{prefix}kind")
          line = submitted_line(handler, prefix) || next
          lines << {handler.field("#{prefix}position").to_i? || (index + 1) * 10, index, line}
        end
        lines.sort_by { |(position, index, _)| {position, index} }.map(&.[2])
      end

      # Ligne envoyée ; `nil` si elle est vide ou cochée « supprimer ».
      private def self.submitted_line(handler : Handler, prefix : String) : Api::LineInput?
        label = handler.field("#{prefix}label")
        formula = handler.field("#{prefix}formula")
        code = handler.field("#{prefix}code")
        kind = handler.field("#{prefix}kind")
        return if handler.field("#{prefix}delete") == "1"
        return if label.empty? && formula.empty? && code.empty? && kind != "blank"
        Api::LineInput.new(label: label, kind: kind, code: code, formula: formula,
          style: handler.field("#{prefix}style").presence || "normal", indent: handler.field("#{prefix}indent").to_i? || 0,
          negate: handler.field("#{prefix}negate") == "1", hidden: handler.field("#{prefix}hidden") == "1")
      end
    end

    class ReportNewHandler < ReportFormHandler
      def existing : Api::ReportView?
        nil
      end

      def save(input : Api::ReportInput) : Partiduo::Api::Result(Api::ReportView)
        Api.create_report(actor, input)
      end

      def form_title : String
        I18n.t("reports_ui.reports.new")
      end

      def action_url : String
        Ui.url("report_new")
      end
    end

    class ReportEditHandler < ReportFormHandler
      def existing : Api::ReportView?
        Api.report(actor, id_param)
      end

      def save(input : Api::ReportInput) : Partiduo::Api::Result(Api::ReportView)
        Api.update_report(actor, id_param, input)
      end

      def form_title : String
        I18n.t("reports_ui.reports.edit")
      end

      def action_url : String
        Ui.url("report_edit", id: id_param)
      end
    end

    # Fragment HTMX : une ligne d'éditeur vide (`index`), et le compteur des
    # lignes mis à jour hors bande.
    class ReportRowHandler < Handler
      def get
        index = (query("index").to_i? || 0).clamp(0, ReportFormHandler::MAX_INDEX - 1)
        render("reports/_line_new.html", {
          "line"       => ReportFormHandler.line_row(Api::LineInput.new, index, [] of Partiduo::Api::FieldError, fmt),
          "next_index" => (index + 1).to_s,
          "kinds"      => Ui.choices(Api::LINE_KINDS, "reports.line_kinds", ""),
          "styles"     => Ui.choices(Api::LINE_STYLES, "reports.line_styles", ""),
          "check_url"  => Ui.url("formula_check"),
        })
      end
    end

    # Fragment HTMX : aperçu du rapport en cours d'édition, sur la période
    # choisie dans l'éditeur.
    class ReportPreviewHandler < Handler
      def post
        input = ReportFormHandler.submitted(self)
        run = Api::RunInput.new(date_from: date_field("preview_from"), date_to: date_field("preview_to"),
          step: field("preview_step").presence || "none")
        result = Api.preview_report(actor, input, run)
        if view = result.value?
          render("reports/_run.html", RunPresenter.context(view, fmt))
        else
          render("reports/_preview_errors.html", {"errors" => result.errors.map { |error| fmt.message(error) }})
        end
      end
    end

    # `/ext/REPORTS/reports/<id>` : calcul d'un rapport sur une période,
    # exports (`format` : `csv`, `ods`, `pdf`), déclaration générée depuis
    # un modèle (`format=document`, D-REP-021).
    class ReportRunHandler < Handler
      def get
        id = id_param
        report = Api.report(actor, id)
        from, to = run_dates
        step = Api::STEPS.includes?(query("step")) ? query("step") : "none"
        input = Api::RunInput.new(date_from: from, date_to: to, step: step)
        back = Ui.url("report", id: id)
        case query("format")
        when "csv", "ods", "pdf" then return file_or_back(Api.report_file(actor, id, input, query("format")), back)
        when "document"
          template, pdf = document_choice
          return file_or_back(Api.report_document(actor, id, input, template, pdf), back)
        end
        result = Api.run_report(actor, id, input)
        context = {
          "title"   => report.name,
          "crumbs"  => crumbs({I18n.t("reports.menu.reports_advanced"), Ui.url("reports")}, {report.name, nil}),
          "actions" => actions(id),
          "intro"   => report.description.presence,
          "steps"   => Ui.choices(Api::STEPS, "reports.steps", step),
          "path"    => back,
        } of String => Ui::Value
        if view = result.value?
          context.merge!(RunPresenter.context(view, fmt))
          params = URI::Params.encode({"from" => iso_day(view.date_from), "to" => iso_day(view.date_to), "step" => step})
          context["from"] = iso_day(view.date_from)
          context["to"] = iso_day(view.date_to)
          context["exports"] = %w[csv ods pdf].map { |format| Ui.row({"url" => "#{back}?#{params}&format=#{format}", "label" => I18n.t("reports_ui.exports.#{format}")}) }
          context.merge!(document_form(Api::DOCUMENT_KINDS[0], {"from" => iso_day(view.date_from), "to" => iso_day(view.date_to), "step" => step}))
          context["keep_url"] = "#{Ui.url("report_keep", id: id)}?#{params}" if can_design?
        else
          context["errors"] = result.errors.map { |error| fmt.message(error) }
          context["from"] = from.try { |day| iso_day(day) } || ""
          context["to"] = to.try { |day| iso_day(day) } || ""
        end
        page("reports/report_run.html", context)
      end

      private def actions(id : Int64) : Array(Screen::Action)
        list = [] of Screen::Action
        list << link_action("reports_ui.actions.edit", Ui.url("report_edit", id: id), "", "pencil") if can_design?
        list << link_action("reports.menu.reports_archive", "#{Ui.url("archive")}?report=#{id}", "", "library")
        list
      end

      private def iso_day(day : Time) : String
        day.to_s("%Y-%m-%d")
      end
    end

    # Révision puis conservation d'une déclaration : montants des lignes
    # modifiables, titre, description (D-REP-009).
    class ReportKeepHandler < Handler
      def get
        id = id_param
        input = Api::RunInput.new(date_from: date_query("from"), date_to: date_query("to"),
          step: Api::STEPS.includes?(query("step")) ? query("step") : "none")
        show(id, input, nil)
      end

      def post
        id = id_param
        step = Api::STEPS.includes?(field("step")) ? field("step") : "none"
        base = Api::RunInput.new(date_from: date_field("from"), date_to: date_field("to"), step: step)
        computed = Api.run_report(actor, id, base)
        return show(id, base, messages(computed)) if computed.failure?
        overrides = [] of Api::Override
        rows = computed.value!.lines
        rows.each do |line|
          next if line.code.empty? || !line.value?
          computed.value!.columns.each_with_index do |column, index|
            next unless column.kind == "period"
            text = field("amount[#{line.code}][#{column.code}]")
            next if text.empty?
            value = fmt.parse_decimal(text) || next
            original = line.values[index]
            overrides << Api::Override.new(line.code, column.code, value) unless original == value
          end
        end
        keep = Api::KeepInput.new(title: field("title"), description: field("description"))
        result = Api.keep_declaration(actor, id, base.copy_with(overrides: overrides), keep)
        if kept = result.value?
          flash["success"] = I18n.t("reports_ui.keep.saved", title: kept.summary.title)
          return go(Ui.url("snapshot", id: kept.summary.id))
        end
        show(id, base, messages(result), 422)
      end

      private def show(id : Int64, input : Api::RunInput, error : String?, status : Int32 = 200) : Marten::HTTP::Response
        report = Api.report(actor, id)
        result = Api.run_report(actor, id, input)
        view = result.value? || return go(Ui.url("report", id: id))
        context = RunPresenter.context(view, fmt, editable: true)
        context.merge!({
          "title"  => I18n.t("reports_ui.keep.title", name: report.name),
          "crumbs" => crumbs({I18n.t("reports.menu.reports_advanced"), Ui.url("reports")}, {report.name, Ui.url("report", id: id)},
            {I18n.t("reports_ui.keep.short"), nil}),
          "form_action" => Ui.url("report_keep", id: id),
          "from"        => view.date_from.to_s("%Y-%m-%d"),
          "to"          => view.date_to.to_s("%Y-%m-%d"),
          "step"        => view.step,
          "error"       => error,
          "cancel_url"  => Ui.url("report", id: id),
        })
        page("reports/report_keep.html", context, status: status)
      end
    end

    class ReportCopyHandler < Handler
      def get
        go(Ui.url("reports"))
      end

      def post
        result = Api.copy_report(actor, id_param)
        if copy = result.value?
          flash["success"] = I18n.t("reports_ui.reports.copied", name: copy.name)
          return go(Ui.url("report_edit", id: copy.id))
        end
        after(result, "reports_ui.reports.copied", Ui.url("reports"))
      end
    end

    class ReportDeleteHandler < Handler
      def get
        go(Ui.url("reports"))
      end

      def post
        after(Api.delete_report(actor, id_param), "reports_ui.reports.deleted", Ui.url("reports"))
      end
    end

    # Reprise des rapports personnalisés de la Comptabilité.
    class CoreReportsHandler < Handler
      def get
        title = I18n.t("reports_ui.core.title")
        columns = [
          Table::Column.new("name", I18n.t("reports_ui.reports.name")),
          Table::Column.new("lines", I18n.t("reports_ui.reports.lines"), "amount"),
          Table::Column.new("actions", I18n.t("ui.forms.actions"), "actions"),
        ]
        rows = Api.core_reports(actor).map do |item|
          Table::Row.new([Table::Cell.new(item.name), Table::Cell.new(item.lines.size.to_s, sort: BigDecimal.new(item.lines.size)),
                          Table::Cell.new("", actions: [post_action("reports_ui.core.import", "#{Ui.url("core_reports")}?id=#{item.id}", nil, "small", "download")])])
        end
        table = Table.new(title, columns, rows, Ui.url("core_reports"), empty_message: I18n.t("reports_ui.core.none"), id: "rep-core")
        list_page(title, table, crumbs({I18n.t("reports.menu.reports_advanced"), Ui.url("reports")}, {title, nil}),
          "reports_ui.reports.csv_name", intro: I18n.t("reports_ui.core.intro"))
      end

      def post
        result = Api.import_core_report(actor, query("id").to_i64? || 0_i64)
        if report = result.value?
          flash["success"] = I18n.t("reports_ui.core.imported", name: report.name)
          return go(Ui.url("report", id: report.id))
        end
        after(result, "reports_ui.core.imported", Ui.url("core_reports"))
      rescue Partiduo::Api::NotFound
        flash["danger"] = I18n.t("reports_ui.core.none")
        go(Ui.url("core_reports"))
      end
    end

    # Présentation d'un rapport calculé : colonnes, lignes (classes de
    # style), montants mis en forme, avertissements.
    module RunPresenter
      def self.context(view : Api::RunView, fmt : PartiduoUi::Format, editable : Bool = false) : Hash(String, Ui::Value)
        columns = view.columns.map do |column|
          period = (from = column.date_from) && (to = column.date_to) ? fmt.period(from, to) : ""
          Ui.row({"code" => column.code, "label" => column.label, "period" => period})
        end
        lines = view.lines.map do |line|
          cells = line.values.map_with_index do |value, index|
            column = view.columns[index]
            Ui.row({"text"    => value.nil? ? "" : fmt.amount(value, view.decimals),
                    "input"   => value.nil? ? "" : fmt.input_number(value, view.decimals),
                    "name"    => editable && column.kind == "period" && !line.code.empty? ? "amount[#{line.code}][#{column.code}]" : nil,
                    "revised" => Ui.flag(line.revised.includes?(column.code))})
          end
          label = line.account ? "#{line.account} · #{line.label}" : line.label
          Ui.row({"label" => label, "css" => Ui.line_class(line.kind, line.style, line.indent), "code" => line.code,
                  "heading" => Ui.flag(line.kind.in?("title", "heading1", "heading2", "heading3")),
                  "blank" => Ui.flag(line.kind == "blank")}, cells)
        end
        {
          "run_columns" => columns,
          "run_lines"   => lines,
          "period"      => fmt.period(view.date_from, view.date_to),
          "warnings"    => view.issues.empty? ? nil : view.issues.map { |item| Ui.issue(item) },
        } of String => Ui::Value
      end
    end
  end
end
