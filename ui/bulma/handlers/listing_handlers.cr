# SPDX-License-Identifier: AGPL-3.0-or-later

module Reports
  module Ui
    # `/ext/REPORTS/listings` : les listings de fiches (D-REP-011).
    class ListingsHandler < Handler
      def get
        design = can_design?
        columns = [
          Table::Column.new("code", I18n.t("reports_ui.reports.code"), "mono"),
          Table::Column.new("name", I18n.t("reports_ui.reports.name")),
          Table::Column.new("cards", I18n.t("reports_ui.listings.cards")),
          Table::Column.new("columns", I18n.t("reports_ui.listings.columns"), "amount", secondary: true),
        ]
        columns << Table::Column.new("actions", I18n.t("ui.forms.actions"), "actions") if design
        rows = Api.listings(actor).map do |item|
          cards = item.category_code.presence || (item.card_kind.empty? ? I18n.t("reports_ui.listings.all_cards") : I18n.t("cards.kinds.#{item.card_kind}"))
          cells = [Table::Cell.new(item.code, Ui.url("listing", id: item.id)), Table::Cell.new(item.name, Ui.url("listing", id: item.id)),
                   Table::Cell.new(cards), Table::Cell.new(item.columns_count.to_s, sort: BigDecimal.new(item.columns_count))]
          if design
            cells << Table::Cell.new("", actions: [
              link_action("reports_ui.actions.edit", Ui.url("listing_edit", id: item.id), "small", "pencil"),
              post_action("reports_ui.actions.copy", Ui.url("listing_copy", id: item.id), nil, "small", "file-text"),
              post_action("reports_ui.actions.delete", Ui.url("listing_delete", id: item.id), "reports_ui.listings.delete_confirm", "small", "trash-2"),
            ])
          end
          Table::Row.new(cells)
        end
        title = I18n.t("reports.menu.reports_listings")
        table = Table.new(title, columns, rows, Ui.url("listings"), empty_message: I18n.t("reports_ui.listings.none"), id: "rep-listings")
        actions = [] of Screen::Action
        actions << link_action("reports_ui.listings.new", Ui.url("listing_new"), "primary", "plus") if design
        list_page(title, table, crumbs({title, nil}), "reports_ui.listings.csv_name", actions, intro: I18n.t("reports_ui.listings.intro"))
      end
    end

    # Éditeur d'un listing : en-tête (catégorie ou nature, tri), colonnes,
    # conditions ; aperçu en HTMX.
    abstract class ListingFormHandler < Handler
      BLANK_COLUMNS    = 3
      BLANK_CONDITIONS = 2
      MAX_INDEX        = Api::MAX_LISTING_COLUMNS + 20

      abstract def existing : Api::ListingView?
      abstract def save(input : Api::ListingInput) : Partiduo::Api::Result(Api::ListingView)
      abstract def form_title : String
      abstract def action_url : String

      def get
        show(existing.try(&.to_input) || Api::ListingInput.new(code: "", name: ""), [] of Partiduo::Api::FieldError)
      end

      def post
        input = ListingFormHandler.submitted(self)
        result = save(input)
        if saved = result.value?
          flash["success"] = I18n.t("reports_ui.listings.saved", name: saved.name)
          return go(Ui.url("listing", id: saved.id))
        end
        show(input, result.errors, 422)
      end

      private def show(input : Api::ListingInput, errors : Array(Partiduo::Api::FieldError), status : Int32 = 200) : Marten::HTTP::Response
        categories = begin
          Partiduo::Api::Cards.categories(actor).map { |item| option(item.code, "#{item.code} · #{item.name}") }
        rescue Partiduo::Api::AccessDenied
          [] of Form::Option
        end
        kinds = Partiduo::Api::Cards::KINDS.map { |kind| option(kind, I18n.t("cards.kinds.#{kind}")) }
        header = Form.new([Form::Group.new(nil, [
          Form::Field.new("code", I18n.t("reports_ui.reports.code"), value: input.code, required: true, mono: true, maxlength: 20,
            help: I18n.t("reports_ui.reports.code_help")),
          Form::Field.new("name", I18n.t("reports_ui.reports.name"), value: input.name, required: true, maxlength: 120),
          Form::Field.new("category_code", I18n.t("reports_ui.listings.category"), "select", input.category_code,
            options: [option("", I18n.t("reports_ui.listings.any_category"))] + categories, help: I18n.t("reports_ui.listings.category_help")),
          Form::Field.new("card_kind", I18n.t("reports_ui.listings.kind"), "select", input.card_kind,
            options: [option("", I18n.t("reports_ui.listings.any_kind"))] + kinds),
          Form::Field.new("include_disabled", I18n.t("reports_ui.listings.include_disabled"), "checkbox", input.include_disabled ? "1" : ""),
          Form::Field.new("sort_code", I18n.t("reports_ui.listings.sort_code"), value: input.sort_code, mono: true, maxlength: 20,
            help: I18n.t("reports_ui.listings.sort_help")),
          Form::Field.new("sort_desc", I18n.t("reports_ui.listings.sort_desc"), "checkbox", input.sort_desc ? "1" : ""),
          Form::Field.new("description", I18n.t("reports_ui.reports.description"), "textarea", input.description, wide: true),
        ])])
        header.add_errors(errors.reject { |error| error.field.starts_with?("columns[") || error.field.starts_with?("conditions[") }, fmt)
        columns = input.columns + Array.new(input.columns.empty? ? BLANK_COLUMNS : 1) { Api::ListingColumnInput.new(code: "", label: "") }
        conditions = input.conditions + Array.new(BLANK_CONDITIONS) { Api::ConditionInput.new("", "eq", "") }
        page("reports/listing_form.html", {
          "title"       => form_title,
          "crumbs"      => crumbs({I18n.t("reports.menu.reports_listings"), Ui.url("listings")}, {form_title, nil}),
          "form"        => header,
          "form_action" => action_url,
          "columns"     => columns.map_with_index { |column, index| ListingFormHandler.column_row(column, index, errors, fmt) },
          "conditions"  => conditions.map_with_index { |condition, index| ListingFormHandler.condition_row(condition, index, errors, fmt) },
          "next_index"  => columns.size.to_s,
          "sources"     => Ui.choices(Api::SOURCES, "reports.sources", ""),
          "fields"      => Ui.choices(Api::CARD_FIELDS, "reports.card_fields", ""),
          "operators"   => Ui.choices(Api::OPERATORS, "reports.operators", ""),
          "check_url"   => Ui.url("formula_check"),
          "row_url"     => Ui.url("listing_row"),
          "preview_url" => Ui.url("listing_preview"),
          "cancel_url"  => Ui.url("listings"),
        }, status: status)
      end

      def self.column_row(column : Api::ListingColumnInput, index : Int32, errors : Array(Partiduo::Api::FieldError),
                          fmt : PartiduoUi::Format) : Row
        prefix = "columns[#{index}]."
        found = errors.select(&.field.starts_with?(prefix)).map { |error| fmt.message(error) }
        Ui.row({"index" => index.to_s, "position" => ((index + 1) * 10).to_s, "code" => column.code, "label" => column.label,
                "source" => column.source, "field" => column.source == "field" ? column.field_name : "",
                "attribute" => column.source == "attribute" ? column.field_name : "", "formula" => column.formula,
                "hidden" => Ui.flag(column.hidden), "errors" => found.empty? ? nil : found.join(" ")})
      end

      def self.condition_row(condition : Api::ConditionInput, index : Int32, errors : Array(Partiduo::Api::FieldError),
                             fmt : PartiduoUi::Format) : Row
        prefix = "conditions[#{index}]."
        found = errors.select(&.field.starts_with?(prefix)).map { |error| fmt.message(error) }
        Ui.row({"index" => index.to_s, "column_code" => condition.column_code, "operator" => condition.operator,
                "value" => condition.value, "errors" => found.empty? ? nil : found.join(" ")})
      end

      def self.submitted(handler : Handler) : Api::ListingInput
        columns = [] of {Int32, Int32, Api::ListingColumnInput}
        (0...MAX_INDEX).each do |index|
          prefix = "columns[#{index}]."
          next unless handler.request.data.has_key?("#{prefix}code")
          code = handler.field("#{prefix}code")
          label = handler.field("#{prefix}label")
          next if (code.empty? && label.empty?) || handler.field("#{prefix}delete") == "1"
          source = handler.field("#{prefix}source").presence || "field"
          name = source == "attribute" ? handler.field("#{prefix}attribute") : handler.field("#{prefix}field")
          position = handler.field("#{prefix}position").to_i? || (index + 1) * 10
          columns << {position, index, Api::ListingColumnInput.new(code: code, label: label, source: source, field_name: name,
            formula: handler.field("#{prefix}formula"), hidden: handler.field("#{prefix}hidden") == "1")}
        end
        conditions = [] of Api::ConditionInput
        (0...Api::MAX_CONDITIONS + 5).each do |index|
          prefix = "conditions[#{index}]."
          next unless handler.request.data.has_key?("#{prefix}column_code")
          code = handler.field("#{prefix}column_code")
          next if code.empty?
          conditions << Api::ConditionInput.new(code, handler.field("#{prefix}operator"), handler.field("#{prefix}value"))
        end
        Api::ListingInput.new(code: handler.field("code"), name: handler.field("name"), description: handler.field("description"),
          category_code: handler.field("category_code"), card_kind: handler.field("card_kind"),
          include_disabled: handler.field("include_disabled") == "1", sort_code: handler.field("sort_code"),
          sort_desc: handler.field("sort_desc") == "1",
          columns: columns.sort_by { |(position, index, _)| {position, index} }.map(&.[2]), conditions: conditions)
      end
    end

    class ListingNewHandler < ListingFormHandler
      def existing : Api::ListingView?
        nil
      end

      def save(input : Api::ListingInput) : Partiduo::Api::Result(Api::ListingView)
        Api.create_listing(actor, input)
      end

      def form_title : String
        I18n.t("reports_ui.listings.new")
      end

      def action_url : String
        Ui.url("listing_new")
      end
    end

    class ListingEditHandler < ListingFormHandler
      def existing : Api::ListingView?
        Api.listing(actor, id_param)
      end

      def save(input : Api::ListingInput) : Partiduo::Api::Result(Api::ListingView)
        Api.update_listing(actor, id_param, input)
      end

      def form_title : String
        I18n.t("reports_ui.listings.edit")
      end

      def action_url : String
        Ui.url("listing_edit", id: id_param)
      end
    end

    # Fragment HTMX : une colonne de listing vide.
    class ListingRowHandler < Handler
      def get
        index = (query("index").to_i? || 0).clamp(0, ListingFormHandler::MAX_INDEX - 1)
        render("reports/_listing_column_new.html", {
          "column"     => ListingFormHandler.column_row(Api::ListingColumnInput.new(code: "", label: ""), index, [] of Partiduo::Api::FieldError, fmt),
          "next_index" => (index + 1).to_s,
          "sources"    => Ui.choices(Api::SOURCES, "reports.sources", ""),
          "fields"     => Ui.choices(Api::CARD_FIELDS, "reports.card_fields", ""),
          "check_url"  => Ui.url("formula_check"),
        })
      end
    end

    class ListingPreviewHandler < Handler
      def post
        input = ListingFormHandler.submitted(self)
        run = Api::ListingRunInput.new(date_field("preview_from"), date_field("preview_to"))
        result = Api.preview_listing(actor, input, run)
        if view = result.value?
          render("reports/_listing.html", ListingPresenter.context(view, fmt, selectable: false))
        else
          render("reports/_preview_errors.html", {"errors" => result.errors.map { |error| fmt.message(error) }})
        end
      end
    end

    # `/ext/REPORTS/listings/<id>` : calcul sur une période, fiches à
    # cocher pour la conservation, exports (`format` : `csv`, `ods`, `pdf`,
    # `merge`) ; filtre « payé / non payé » (`paid` : `yes`, `no`,
    # D-REP-024).
    class ListingRunHandler < Handler
      # Valeurs du filtre « payé / non payé ».
      PAID = {"yes" => true, "no" => false}

      def get
        id = id_param
        listing = Api.listing(actor, id)
        from, to = run_dates
        paid = PAID[query("paid")]?
        input = Api::ListingRunInput.new(from, to, paid)
        back = Ui.url("listing", id: id)
        case query("format")
        when "csv", "ods", "pdf" then return file_or_back(Api.listing_file(actor, id, input, query("format")), back)
        when "merge"             then return file_or_back(Api.listing_merge_file(actor, id, input), back)
        end
        result = Api.run_listing(actor, id, input)
        actions = [] of Screen::Action
        actions << link_action("reports_ui.actions.edit", Ui.url("listing_edit", id: id), "", "pencil") if can_design?
        actions << link_action("reports.menu.reports_archive", "#{Ui.url("archive")}?kind=listing", "", "library")
        context = {
          "title"   => listing.name,
          "crumbs"  => crumbs({I18n.t("reports.menu.reports_listings"), Ui.url("listings")}, {listing.name, nil}),
          "actions" => actions,
          "intro"   => listing.description.presence,
          "path"    => back,
        } of String => Ui::Value
        if view = result.value?
          context.merge!(ListingPresenter.context(view, fmt, selectable: can_design?))
          dates = URI::Params.encode({"from" => view.date_from.to_s("%Y-%m-%d"), "to" => view.date_to.to_s("%Y-%m-%d"),
                                      "paid" => query("paid")})
          context["from"] = view.date_from.to_s("%Y-%m-%d")
          context["to"] = view.date_to.to_s("%Y-%m-%d")
          context["paid"] = PAID.has_key?(query("paid")) ? query("paid") : ""
          context["exports"] = %w[csv ods pdf merge].map { |format| Ui.row({"url" => "#{back}?#{dates}&format=#{format}", "label" => I18n.t("reports_ui.exports.#{format}")}) }
          context["keep_url"] = Ui.url("listing_keep", id: id) if can_design?
        else
          context["errors"] = result.errors.map { |error| fmt.message(error) }
          context["from"] = from.try(&.to_s("%Y-%m-%d")) || ""
          context["to"] = to.try(&.to_s("%Y-%m-%d")) || ""
        end
        page("reports/listing_run.html", context)
      end
    end

    # Conserve le listing calculé, réduit aux fiches cochées.
    class ListingKeepHandler < Handler
      def get
        go(Ui.url("listing", id: id_param))
      end

      def post
        id = id_param
        values = request.data.fetch_all("card_ids")
        ids = values ? values.compact_map(&.to_s.to_i64?) : [] of Int64
        run = Api::ListingRunInput.new(date_field("from"), date_field("to"), ListingRunHandler::PAID[field("paid")]?)
        result = Api.keep_listing(actor, id, run, Api::KeepInput.new(title: field("title"), description: field("description"), card_ids: ids))
        if kept = result.value?
          flash["success"] = I18n.t("reports_ui.keep.saved", title: kept.summary.title)
          return go(Ui.url("snapshot", id: kept.summary.id))
        end
        after(result, "reports_ui.keep.saved", Ui.url("listing", id: id))
      end
    end

    class ListingCopyHandler < Handler
      def get
        go(Ui.url("listings"))
      end

      def post
        result = Api.copy_listing(actor, id_param)
        if copy = result.value?
          flash["success"] = I18n.t("reports_ui.listings.copied", name: copy.name)
          return go(Ui.url("listing_edit", id: copy.id))
        end
        after(result, "reports_ui.listings.copied", Ui.url("listings"))
      end
    end

    class ListingDeleteHandler < Handler
      def get
        go(Ui.url("listings"))
      end

      def post
        after(Api.delete_listing(actor, id_param), "reports_ui.listings.deleted", Ui.url("listings"))
      end
    end

    # Présentation d'un listing calculé.
    module ListingPresenter
      def self.context(view : Api::ListingResultView, fmt : PartiduoUi::Format, selectable : Bool) : Hash(String, Ui::Value)
        columns = view.columns.map { |column| Ui.row({"label" => column.label, "code" => column.code, "amount" => Ui.flag(column.amount)}) }
        rows = view.rows.map do |row|
          cells = row.cells.map_with_index do |cell, index|
            amount = view.columns[index].amount
            Ui.row({"text" => amount ? fmt.amount(cell.amount) : cell.text, "amount" => Ui.flag(amount)})
          end
          Ui.row({"card_id" => row.card_id.to_s, "card_code" => row.card_code, "card_name" => row.card_name}, cells)
        end
        totals = view.totals.map_with_index do |value, index|
          Ui.row({"text" => value ? fmt.amount(value) : "", "amount" => Ui.flag(view.columns[index].amount)})
        end
        {
          "listing_columns" => columns,
          "listing_rows"    => rows.empty? ? nil : rows,
          "listing_totals"  => view.totals.present? ? totals : nil,
          "selectable"      => Ui.flag(selectable),
          "count"           => view.rows.size.to_s,
          "period"          => fmt.period(view.date_from, view.date_to),
          "warnings"        => view.issues.empty? ? nil : view.issues.map { |item| Ui.issue(item) },
        } of String => Ui::Value
      end
    end
  end
end
