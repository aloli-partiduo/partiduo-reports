# SPDX-License-Identifier: AGPL-3.0-or-later

module Reports
  module Ui
    # `/ext/REPORTS/sharing` : partage des définitions entre dossiers
    # (D-REP-014 à D-REP-016) — export des rapports et listings cochés en
    # JSON, import d'un fichier JSON ou d'une définition de la source legacy
    # (`.bin`), définitions fournies avec l'extension.
    class SharingHandler < Handler
      def get
        show(nil)
      end

      def show(report : Api::ImportView?, errors = [] of String, status : Int32 = 200) : Marten::HTTP::Response
        reports = Api.reports(actor).map { |item| Ui.row({"id" => item.id.to_s, "code" => item.code, "name" => item.name}) }
        listings = Api.listings(actor).map { |item| Ui.row({"id" => item.id.to_s, "code" => item.code, "name" => item.name}) }
        starters = Api.starters(actor).map do |item|
          Ui.row({"code" => item.code, "name" => I18n.t(item.name_key), "description" => I18n.t(item.description_key),
                  "kind" => I18n.t("reports_ui.sharing.kinds.#{item.kind}"), "url" => Ui.url("starter", code: item.code)})
        end
        title = I18n.t("reports.menu.reports_sharing")
        context = {
          "title"         => title,
          "crumbs"        => [crumb("core.menu.settings"), Screen::Crumb.new(title, nil)],
          "reports_list"  => reports.empty? ? nil : reports,
          "listings_list" => listings.empty? ? nil : listings,
          "starters"      => starters,
          "export_url"    => Ui.url("sharing_export"),
          "import_url"    => Ui.url("sharing_import"),
          "can_replace"   => Ui.flag(can_admin?),
          "errors"        => errors.empty? ? nil : errors,
        } of String => Ui::Value
        if report
          context["created"] = report.created.join(", ").presence
          context["replaced"] = report.replaced.join(", ").presence
          context["skipped"] = report.skipped.join(", ").presence
          context["issues"] = report.issues.empty? ? nil : report.issues.map { |item| Ui.issue(item) }
        end
        page("reports/sharing.html", context, status: status)
      end
    end

    # Télécharge les définitions cochées.
    class SharingExportHandler < Handler
      def get
        go(Ui.url("sharing"))
      end

      def post
        reports = ids("report_ids")
        listings = ids("listing_ids")
        if reports.empty? && listings.empty?
          flash["warning"] = I18n.t("reports_ui.sharing.nothing")
          return go(Ui.url("sharing"))
        end
        file_response(Api.export_definitions(actor, reports, listings))
      end

      private def ids(name : String) : Array(Int64)
        values = request.data.fetch_all(name)
        values ? values.compact_map(&.to_s.to_i64?) : [] of Int64
      end
    end

    # Importe un fichier déposé : JSON du format de partage, ou `.bin` de la
    # source legacy (reconnu à son en-tête).
    class SharingImportHandler < SharingHandler
      MAX_UPLOAD = 2_000_000

      def get
        go(Ui.url("sharing"))
      end

      def post
        file = request.data["file"]?
        unless file.is_a?(Marten::HTTP::UploadedFile) && file.size > 0
          return show(nil, [I18n.t("reports_ui.sharing.no_file")], 422)
        end
        return show(nil, [I18n.t("reports_ui.sharing.too_large")], 422) if file.size > MAX_UPLOAD
        content = String.new(file.io.getb_to_end).scrub
        result = if content.lstrip('﻿').starts_with?("RAPAV")
                   Api.import_legacy(actor, content)
                 else
                   Api.import_definitions(actor, content, replace: field("replace") == "1")
                 end
        if report = result.value?
          return show(report)
        end
        show(nil, result.errors.map { |error| "#{error.field == "file" ? "" : "#{error.field} : "}#{fmt.message(error)}" }, 422)
      rescue error : Partiduo::Api::Forbidden
        show(nil, [I18n.t(error.key)], 403)
      end
    end

    # Installe une définition fournie.
    class StarterHandler < SharingHandler
      def get
        go(Ui.url("sharing"))
      end

      def post
        result = Api.install_starter(actor, params["code"].to_s)
        if report = result.value?
          if report.created.empty?
            flash["warning"] = I18n.t("reports_ui.sharing.starter_present")
          else
            flash["success"] = I18n.t("reports_ui.sharing.starter_installed", code: report.created.join(", "))
          end
        else
          flash["danger"] = messages(result)
        end
        go(Ui.url("sharing"))
      end
    end
  end
end
