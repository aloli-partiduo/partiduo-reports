# SPDX-License-Identifier: AGPL-3.0-or-later

# Interface Bulma de l'extension des rapports avancés et des listings
# (ADR-005 D4) : rapports (liste, éditeur avec aperçu en HTMX, calcul sur
# une période, révision et conservation, exports), listings (éditeur,
# calcul, sélection des fiches, publipostage, suivi), déclarations et
# listings conservés, partage des définitions (export, import, définitions
# fournies, reprise de la Comptabilité et de la source legacy). Montée par
# `partiduo-ui-bulma` sous `/ext/REPORTS/` (ADR-003 D3). La distribution la
# requiert après l'interface :
#
# ```
# require "partiduo-ui-bulma/partiduo_ui"
# require "partiduo-reports"
# require "partiduo-reports/ui/bulma"
# ```
#
# puis ajoute `Reports::Ui::INSTALLED_APPS` à ses applications Marten.
#
# Ce dossier ne parle au métier que par `Reports::Api` et `Partiduo::Api`
# (vérifié par `spec/architecture/conventions_spec.cr`) ; le contrôle
# d'accès est fait par l'interface, avant le handler, à partir du montage,
# puis par le contrat.
require "../../src/partiduo-reports"

require "./presenters"
require "./handlers/base"
require "./handlers/**"

module Reports
  module Ui
    # Application Marten de l'interface Bulma de l'extension : gabarits
    # (`templates/reports/`), fichiers statiques (`assets/reports/`) et
    # libellés d'écran (`locales/`, clés `reports_ui.*`).
    class App < Marten::App
      label "reports_ui"
    end

    INSTALLED_APPS = [Reports::Ui::App] of Marten::Apps::Config.class

    # Routes servies sous `/ext/REPORTS/`, nommées `reports:<nom>` : celles
    # que citent les menus du manifeste.
    ROUTES = Marten::Routing::Map.draw do
      path "/", Reports::Ui::IndexHandler, name: "index"
      path "/formula/check", Reports::Ui::FormulaCheckHandler, name: "formula_check"
      path "/reports", Reports::Ui::ReportsHandler, name: "reports"
      path "/reports/new", Reports::Ui::ReportNewHandler, name: "report_new"
      path "/reports/row", Reports::Ui::ReportRowHandler, name: "report_row"
      path "/reports/preview", Reports::Ui::ReportPreviewHandler, name: "report_preview"
      path "/reports/core", Reports::Ui::CoreReportsHandler, name: "core_reports"
      path "/reports/<id:int>", Reports::Ui::ReportRunHandler, name: "report"
      path "/reports/<id:int>/edit", Reports::Ui::ReportEditHandler, name: "report_edit"
      path "/reports/<id:int>/copy", Reports::Ui::ReportCopyHandler, name: "report_copy"
      path "/reports/<id:int>/delete", Reports::Ui::ReportDeleteHandler, name: "report_delete"
      path "/reports/<id:int>/keep", Reports::Ui::ReportKeepHandler, name: "report_keep"
      path "/listings", Reports::Ui::ListingsHandler, name: "listings"
      path "/listings/new", Reports::Ui::ListingNewHandler, name: "listing_new"
      path "/listings/row", Reports::Ui::ListingRowHandler, name: "listing_row"
      path "/listings/preview", Reports::Ui::ListingPreviewHandler, name: "listing_preview"
      path "/listings/<id:int>", Reports::Ui::ListingRunHandler, name: "listing"
      path "/listings/<id:int>/edit", Reports::Ui::ListingEditHandler, name: "listing_edit"
      path "/listings/<id:int>/copy", Reports::Ui::ListingCopyHandler, name: "listing_copy"
      path "/listings/<id:int>/delete", Reports::Ui::ListingDeleteHandler, name: "listing_delete"
      path "/listings/<id:int>/keep", Reports::Ui::ListingKeepHandler, name: "listing_keep"
      path "/archive", Reports::Ui::ArchiveHandler, name: "archive"
      path "/archive/<id:int>", Reports::Ui::SnapshotHandler, name: "snapshot"
      path "/archive/<id:int>/delete", Reports::Ui::SnapshotDeleteHandler, name: "snapshot_delete"
      path "/archive/<id:int>/followup", Reports::Ui::FollowupHandler, name: "snapshot_followup"
      path "/sharing", Reports::Ui::SharingHandler, name: "sharing"
      path "/sharing/export", Reports::Ui::SharingExportHandler, name: "sharing_export"
      path "/sharing/import", Reports::Ui::SharingImportHandler, name: "sharing_import"
      path "/sharing/starters/<code:str>", Reports::Ui::StarterHandler, name: "starter"
    end

    # Routes qui définissent, importent ou conservent : `reports.design` ;
    # effacer ce qui est conservé : `reports.admin` ; les autres :
    # `reports.read`. Le contrat vérifie encore les permissions, et celles
    # du cœur (éditions, fiches, analytique, suivi).
    DESIGN_ROUTES = %w[report_new report_row report_preview core_reports report_edit report_copy report_delete
      report_keep listing_new listing_row listing_preview listing_edit listing_copy listing_delete listing_keep
      snapshot_followup sharing sharing_export sharing_import starter]
    ADMIN_ROUTES = %w[snapshot_delete]
  end
end

PartiduoUi::Extensions.mount Reports::CODE, Reports::Ui::ROUTES, permission: Reports::Api::READ,
  permissions: Reports::Ui::DESIGN_ROUTES.to_h { |route| {route, Reports::Api::DESIGN} }
    .merge(Reports::Ui::ADMIN_ROUTES.to_h { |route| {route, Reports::Api::ADMIN} })
