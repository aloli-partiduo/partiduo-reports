# SPDX-License-Identifier: AGPL-3.0-or-later

module Reports
  module Ui
    # `/ext/REPORTS/archive` : déclarations et listings conservés
    # (D-REP-009), par onglet ; `report` restreint aux déclarations d'un
    # rapport.
    class ArchiveHandler < Handler
      TABS = %w[declaration listing]

      def get
        kind = TABS.includes?(query("kind")) ? query("kind") : "declaration"
        definition = query("report").to_i64?
        items = Api.snapshots(actor, Api::SnapshotQuery.new(kind: kind, definition_id: kind == "declaration" ? definition : nil))
        columns = [
          Table::Column.new("title", I18n.t("reports_ui.archive.title_column")),
          Table::Column.new("definition", I18n.t("reports_ui.archive.definition")),
          Table::Column.new("period", I18n.t("reports_ui.archive.period"), "mono"),
          Table::Column.new("created", I18n.t("reports_ui.archive.created"), "mono", secondary: true),
          Table::Column.new("author", I18n.t("reports_ui.archive.author"), secondary: true),
        ]
        rows = items.map do |item|
          Table::Row.new([
            Table::Cell.new(item.title, Ui.url("snapshot", id: item.id)),
            Table::Cell.new("#{item.definition_code} · #{item.definition_name}"),
            Table::Cell.new(fmt.period(item.date_from, item.date_to), sort: date_key(item.date_from)),
            Table::Cell.new(fmt.datetime(item.created_at), sort: item.created_at.to_unix.to_s),
            Table::Cell.new(item.created_by),
          ])
        end
        title = I18n.t("reports.menu.reports_archive")
        tabs = TABS.map { |code| Screen::Tab.new(I18n.t("reports.snapshot_kinds.#{code}"), "#{Ui.url("archive")}?kind=#{code}", code == kind) }
        table = Table.new(title, columns, rows, Ui.url("archive"), params: {"kind" => kind},
          empty_message: I18n.t("reports_ui.archive.none"), id: "rep-archive")
        list_page(title, table, crumbs({title, nil}), "reports_ui.archive.csv_name", tabs: tabs,
          tabs_label: I18n.t("reports_ui.archive.tabs"), intro: I18n.t("reports_ui.archive.intro"))
      end
    end

    # Une déclaration ou un listing conservé : contenu figé, exports,
    # balises ou source de publipostage, inscription au suivi, effacement.
    class SnapshotHandler < Handler
      def get
        id = id_param
        Api.snapshot(actor, id).kind == "listing" ? listing(id) : declaration(id)
      end

      private def declaration(id : Int64) : Marten::HTTP::Response
        back = Ui.url("snapshot", id: id)
        case query("format")
        when "csv", "ods", "pdf" then return file_or_back(Api.declaration_file(actor, id, query("format")), back)
        when "tags"              then return file_or_back(Api.declaration_tags_file(actor, id), back)
        end
        view = Api.declaration(actor, id)
        context = RunPresenter.context(view.run, fmt)
        context.merge!(common(view.summary, %w[csv ods pdf tags]))
        page("reports/snapshot.html", context)
      end

      private def listing(id : Int64) : Marten::HTTP::Response
        back = Ui.url("snapshot", id: id)
        case query("format")
        when "csv", "ods", "pdf" then return file_or_back(Api.listing_snapshot_file(actor, id, query("format")), back)
        when "merge"             then return file_or_back(Api.listing_snapshot_file(actor, id, "csv", merge: true), back)
        end
        view = Api.listing_snapshot(actor, id)
        context = ListingPresenter.context(view.result, fmt, selectable: false)
        context.merge!(common(view.summary, %w[csv ods pdf merge]))
        context["followup_url"] = Ui.url("snapshot_followup", id: id) if can_design?
        page("reports/snapshot.html", context)
      end

      private def common(summary : Api::SnapshotSummaryView, formats : Array(String)) : Hash(String, Ui::Value)
        back = Ui.url("snapshot", id: summary.id)
        actions = [] of Screen::Action
        if can_admin?
          actions << post_action("reports_ui.actions.delete", Ui.url("snapshot_delete", id: summary.id),
            "reports_ui.archive.delete_confirm", "danger", "trash-2")
        end
        {
          "title"       => summary.title,
          "crumbs"      => crumbs({I18n.t("reports.menu.reports_archive"), "#{Ui.url("archive")}?kind=#{summary.kind}"}, {summary.title, nil}),
          "actions"     => actions,
          "kind_label"  => I18n.t("reports.snapshot_kinds.#{summary.kind}"),
          "definition"  => "#{summary.definition_code} · #{summary.definition_name}",
          "created"     => I18n.t("reports_ui.archive.created_by", date: fmt.datetime(summary.created_at), name: summary.created_by.presence || "—"),
          "description" => summary.description.presence,
          "exports"     => formats.map { |format| Ui.row({"url" => "#{back}?format=#{format}", "label" => I18n.t("reports_ui.exports.#{format}")}) },
        } of String => Ui::Value
      end
    end

    class SnapshotDeleteHandler < Handler
      def get
        go(Ui.url("archive"))
      end

      def post
        after(Api.delete_snapshot(actor, id_param), "reports_ui.archive.deleted", Ui.url("archive"))
      end
    end

    # Inscription au suivi des fiches d'un listing conservé : une action par
    # fiche (type, date, titre, rappel, commentaire, profil).
    class FollowupHandler < Handler
      def get
        show(form({"date" => fmt.date(Partiduo::Api::Core.today), "title" => ""}), id_param)
      end

      def post
        id = id_param
        values = %w[action_type_id date title remind_on comment visible_profile_id].to_h { |name| {name, field(name)} }
        current_form = form(values)
        date = date_field("date")
        if date.nil?
          current_form.add_error("date", I18n.t("ui.forms.invalid_date"))
          return show(current_form, id, 422)
        end
        input = Api::FollowupInput.new(action_type_id: id_field("action_type_id") || 0_i64, date: date, title: field("title"),
          comment: field("comment"), remind_on: date_field("remind_on"), visible_profile_id: id_field("visible_profile_id"))
        result = Api.add_to_followup(actor, id, input)
        if count = result.value?
          flash["success"] = I18n.t("reports_ui.followup.done", count: count)
          return go(Ui.url("snapshot", id: id))
        end
        current_form.add_errors(result.errors, fmt)
        show(current_form, id, 422)
      rescue error : Partiduo::Api::AccessDenied
        flash["danger"] = I18n.t(error.key)
        go(Ui.url("snapshot", id: id_param))
      end

      private def form(values : Hash(String, String)) : Form
        types = Partiduo::Api::Followup.action_types(actor).map { |item| option(item.id.to_s, item.label) }
        profiles = Partiduo::Api::Followup.visibility_profiles(actor).map { |item| option(item.id.to_s, item.name) }
        Form.new([Form::Group.new(nil, [
          Form::Field.new("action_type_id", I18n.t("reports_ui.followup.type"), "select", values["action_type_id"]? || "", options: types, required: true),
          Form::Field.new("date", I18n.t("reports_ui.followup.date"), "date", values["date"]? || "", required: true),
          Form::Field.new("title", I18n.t("reports_ui.followup.title_field"), value: values["title"]? || "", required: true, maxlength: 255),
          Form::Field.new("remind_on", I18n.t("reports_ui.followup.remind_on"), "date", values["remind_on"]? || ""),
          Form::Field.new("visible_profile_id", I18n.t("reports_ui.followup.profile"), "select", values["visible_profile_id"]? || "",
            options: [option("", I18n.t("reports_ui.followup.everyone"))] + profiles),
          Form::Field.new("comment", I18n.t("reports_ui.followup.comment"), "textarea", values["comment"]? || "", wide: true),
        ])])
      end

      private def show(form : Form, id : Int64, status : Int32? = nil) : Marten::HTTP::Response
        snapshot = Api.listing_snapshot(actor, id)
        title = I18n.t("reports_ui.followup.title")
        form_page(title, crumbs({I18n.t("reports.menu.reports_archive"), "#{Ui.url("archive")}?kind=listing"},
          {snapshot.summary.title, Ui.url("snapshot", id: id)}, {title, nil}), form, Ui.url("snapshot_followup", id: id),
          I18n.t("reports_ui.followup.submit", count: snapshot.result.rows.size), Ui.url("snapshot", id: id),
          intro: I18n.t("reports_ui.followup.intro", count: snapshot.result.rows.size), status: status)
      end
    end
  end
end
