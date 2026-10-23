# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

# Traductions des écrans de l'extension (ADR-005 D7) : chaque route de
# `/ext/REPORTS/` servie en `GET` (liste tirée du routeur de Marten),
# obtenue dans chaque langue de l'interface par un administrateur, sur
# un dossier avec une vente et des charges en 2026 : définition fournie
# installée (SIG), rapport et listing définis, déclaration et listing
# conservés, rapport de la Comptabilité à reprendre, suivi et modèles de
# documents actifs. Contrôle de l'interface (`PartiduoUi::Translations`)
# : ni marqueur de traduction absente, ni clé brute, ni interpolation
# non résolue, et toute route atteinte par les liens des pages.

private alias S = Reports::SpecSupport
private alias Api = Reports::Api
private alias Acc = Partiduo::Api::Accounting

describe "Traductions des écrans REPORTS (langues de l'interface)" do
  it "rend chaque écran dans chaque langue, sans clé absente, brute ni interpolation non résolue" do
    S.activate
    browser = PartiduoUi::Books.admin
    PartiduoUi::Books.card("CUSTOMER", "Client Morel", "MOREL", email: "morel@example.com")
    PartiduoUi::Books.card("CUSTOMER", "Client Andrieu", "ANDRIEU")
    PartiduoUi::Books.sale("MOREL", "1000", "2026-03-10")
    S.entry("2026-04-01", [{"627", "D", "300", nil}, {"641", "D", "100", nil}, {"510001", "C", "400", nil}])
    Partiduo::Api::Modules.activate(S.system, "FOLLOWUP").value!
    Partiduo::Api::Followup.load_default_action_types(S.system)

    Api.install_starter(S.designer, "SIG").value!
    columns = [Api::ColumnInput.new("N", "Exercice"), Api::ColumnInput.new("N1", "Précédent", shift_months: -12)]
    report = S.report(Api::ReportInput.new(code: "MARGE", name: "Marge", columns: columns, lines: [
      Api::LineInput.new(label: "Marge brute", kind: "title"),
      S.line("CA", "[70%-S]", label: "Ventes"),
      S.line("CH", "[6%-s]", kind: "accounts", label: "Charges"),
      S.line("MARGE", "$CA - $CH", label: "Marge"),
    ]))
    run = Api::RunInput.new(date_from: S.date("2026-01-01"), date_to: S.date("2026-12-31"))
    Api.keep_declaration(S.designer, report.id, run, Api::KeepInput.new(title: "Marge 2026")).value!
    listing = Api.create_listing(S.designer, Api::ListingInput.new(code: "CLIENTS", name: "Clients", category_code: "CUSTOMER",
      columns: [Api::ListingColumnInput.new("NOM", "Nom", field_name: "name"),
                Api::ListingColumnInput.new("CA", "Chiffre d'affaires", source: "formula", formula: "[70%-S; card=*]")])).value!
    morel = present(Partiduo::Api::Cards.card_by_code(S.system, "MOREL"))
    kept = Api.keep_listing(S.designer, listing.id, Api::ListingRunInput.new(S.date("2026-01-01"), S.date("2026-12-31")),
      Api::KeepInput.new(title: "Relance", card_ids: [morel.id])).value!
    Acc.create_report(S.system, Acc::ReportDefinitionInput.new(name: "Ventes", lines: [Acc::ReportLineInput.new("Ventes", "[70%-S]")])).value!
    S.modeles_template("report", "Marge : {{ montants.MARGE }}")
    S.modeles_template("listing", "{{ fiche.nom }} : {{ colonnes.CA }}")
    # Envoi des documents par fiche : messagerie configurée.
    Partiduo::Api::Core.update_settings(S.system, Partiduo::Api::Core.settings(S.system).to_input.copy_with(email: "contact@atelier.test")).value!
    Partiduo::Core::Mail.transport = Partiduo::Core::Mail::MemoryTransport.new

    explorer = PartiduoUi::Translations::Explorer.new(&.name.starts_with?("reports:"))
    # Les requêtes laissent active la dernière langue obtenue (nl) : la
    # langue d'avant est rendue aux exemples suivants.
    # Graine : la liste des résultats conservés n'affiche les listings que
    # sous `?kind=listing`, forme de requête déjà explorée par
    # `?kind=declaration` ; le listing conservé n'est atteint que par elle,
    # obtenue à part (`visit`).
    seeds = ["/ext/REPORTS/archive/#{kept.summary.id}"]
    locale = I18n.locale
    begin
      explorer.crawl(browser, "REPORTS", seeds)
      explorer.visit(browser, "REPORTS", ["/ext/REPORTS/archive?kind=listing"])
    ensure
      I18n.activate(locale)
      Partiduo::Core::Mail.transport = nil
    end
    puts "\nTraductions de REPORTS : #{explorer.report}"
    (explorer.failures + explorer.unreached.map { |route| "route jamais atteinte : #{route}" }).should eq([] of String)
  end
end
