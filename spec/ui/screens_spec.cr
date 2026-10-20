# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

private alias S = Reports::SpecSupport
private alias Api = Reports::Api

# Administrateur connecté (profil ADMIN : toutes les permissions), dossier
# provisionné l'extension active, une vente et des charges en 2026.
private def signed_in : PartiduoUi::Browser
  S.activate
  browser = PartiduoUi::Books.admin
  PartiduoUi::Books.card("CUSTOMER", "Client Morel", "MOREL", email: "morel@example.com")
  PartiduoUi::Books.sale("MOREL", "1000", "2026-03-10")
  S.entry("2026-04-01", [{"627", "D", "300", nil}, {"641", "D", "100", nil}, {"510001", "C", "400", nil}])
  browser
end

private def report_form : Hash(String, String)
  {"code" => "marge", "name" => "Marge", "decimals" => "2", "description" => "",
   "columns[0].code" => "N", "columns[0].label" => "Exercice", "columns[0].kind" => "period", "columns[0].span" => "period",
   "columns[0].shift" => "", "columns[0].formula" => "",
   "columns[1].code" => "N1", "columns[1].label" => "Précédent", "columns[1].kind" => "period", "columns[1].span" => "period",
   "columns[1].shift" => "-1", "columns[1].formula" => "",
   "lines[0].position" => "10", "lines[0].kind" => "title", "lines[0].code" => "", "lines[0].label" => "Marge brute",
   "lines[0].formula" => "", "lines[0].style" => "normal", "lines[0].indent" => "0",
   "lines[1].position" => "30", "lines[1].kind" => "formula", "lines[1].code" => "MARGE", "lines[1].label" => "Marge",
   "lines[1].formula" => "$CA - $CH", "lines[1].style" => "total", "lines[1].indent" => "0",
   "lines[2].position" => "20", "lines[2].kind" => "formula", "lines[2].code" => "CA", "lines[2].label" => "Ventes",
   "lines[2].formula" => "[70%-S]", "lines[2].style" => "normal", "lines[2].indent" => "1",
   "lines[3].position" => "25", "lines[3].kind" => "accounts", "lines[3].code" => "CH", "lines[3].label" => "Charges",
   "lines[3].formula" => "[6%-s]", "lines[3].style" => "normal", "lines[3].indent" => "1",
   "lines[4].position" => "40", "lines[4].kind" => "formula", "lines[4].code" => "", "lines[4].label" => "",
   "lines[4].formula" => "", "lines[4].style" => "normal", "lines[4].indent" => "0"}
end

private def listing_form : Hash(String, String)
  {"code" => "clients", "name" => "Clients", "description" => "", "category_code" => "CUSTOMER", "card_kind" => "",
   "sort_code" => "CA", "sort_desc" => "1",
   "columns[0].position" => "10", "columns[0].code" => "NOM", "columns[0].label" => "Nom", "columns[0].source" => "field",
   "columns[0].field" => "name", "columns[0].attribute" => "", "columns[0].formula" => "",
   "columns[1].position" => "20", "columns[1].code" => "CA", "columns[1].label" => "Chiffre d'affaires",
   "columns[1].source" => "formula", "columns[1].field" => "", "columns[1].attribute" => "", "columns[1].formula" => "[70%-S; card=*]",
   "conditions[0].column_code" => "", "conditions[0].operator" => "eq", "conditions[0].value" => ""}
end

describe "Écrans des rapports et listings sous /ext/REPORTS/ (ADR-005)" do
  it "est montée sous le code de l'extension, avec ses permissions par route, et n'existe pas inactive" do
    Marten.routes.reverse("reports:reports").should eq("/ext/REPORTS/reports")
    Marten.routes.reverse("reports:report", id: 4).should eq("/ext/REPORTS/reports/4")
    mount = PartiduoUi::Extensions["REPORTS"]? || raise("interface non montée")
    mount.permission.should eq("reports.read")
    mount.permission_for("reports:report_new").should eq("reports.design")
    mount.permission_for("reports:sharing_import").should eq("reports.design")
    mount.permission_for("reports:snapshot_delete").should eq("reports.admin")
    mount.permission_for("reports:report").should eq("reports.read")
    browser = PartiduoUi::Books.admin
    browser.get("/ext/REPORTS/reports").status.should eq(404)
    S.activate
    response = PartiduoUi::Browser.new.get("/ext/REPORTS/reports")
    response.status.should eq(302)
    response.headers["Location"].should eq("/login?next=%2Fext%2FREPORTS%2Freports")
  end

  it "définit un rapport dans l'éditeur (lignes HTMX, contrôle des formules, aperçu), puis le calcule et l'exporte" do
    browser = signed_in
    browser.get("/ext/REPORTS/").headers["Location"].should eq("/ext/REPORTS/reports")
    browser.get("/ext/REPORTS/reports").html.should contain("Aucun rapport")
    editor = browser.get("/ext/REPORTS/reports/new").html
    editor.should contain("<h1>Nouveau rapport")
    editor.should contain(%(hx-get="/ext/REPORTS/reports/row"))
    editor.should contain("Aide-mémoire des formules")
    browser.get("/ext/REPORTS/reports/row?index=7").html.should contain(%(name="lines[7].formula"))
    browser.get("/ext/REPORTS/reports/row?index=7").html.should contain(%(id="rep-next" name="index" value="8" hx-swap-oob="true"))
    browser.htmx_post("/ext/REPORTS/formula/check?kind=line&field=lines%5B2%5D.formula", {"lines[2].formula" => "[70%"}).html
      .should contain("Formule invalide")
    browser.htmx_post("/ext/REPORTS/formula/check?kind=line&field=f", {"f" => "[70%-S]"}).html.strip.should eq("")
    preview = browser.htmx_post("/ext/REPORTS/reports/preview", report_form.merge({"preview_from" => "2026-01-01", "preview_to" => "2026-12-31"})).html
    preview.should contain(%(id="rep-run"))
    preview.should contain("1\u202F000,00")

    refused = browser.post("/ext/REPORTS/reports/new", report_form.merge({"lines[1].formula" => "$CA - $XX"}))
    refused.status.should eq(422)
    refused.html.should contain("Ligne XX inconnue ou sans montant.")
    created = browser.post("/ext/REPORTS/reports/new", report_form)
    created.status.should eq(302)
    report = Api.reports(S.system).first
    report.code.should eq("MARGE")
    Api.report(S.system, report.id).lines.map(&.code).should eq(["", "CA", "CH", "MARGE"])

    page = browser.get("/ext/REPORTS/reports/#{report.id}?from=2026-01-01&to=2026-12-31").html
    page.should contain(%(class="rep-title"))
    page.should contain("627 · ")
    page.should contain("600,00")
    page.should contain(%(data-rep-line="MARGE"))
    csv = browser.get("/ext/REPORTS/reports/#{report.id}?from=2026-01-01&to=2026-12-31&format=csv")
    csv.content_type.should contain("text/csv")
    csv.content.should contain("Marge;600.00;0.00")
    browser.get("/ext/REPORTS/reports/#{report.id}?format=ods").content_type.should eq("application/vnd.oasis.opendocument.spreadsheet")
    browser.get("/ext/REPORTS/reports/#{report.id}?format=pdf").content_type.should eq("application/pdf")
    browser.get("/ext/REPORTS/reports/#{report.id}?format=tags").content_type.should_not contain("text/csv")
    page.should_not contain("data-reports-document")
    template = S.modeles_template("report", "Marge : {{ montants.MARGE }} / {{ montants.MARGE_N1 }}")
    page = browser.get("/ext/REPORTS/reports/#{report.id}?from=2026-01-01&to=2026-12-31").html
    page.should contain("data-reports-document")
    page.should contain(%(<option value="#{template}" selected>))
    document = browser.get("/ext/REPORTS/reports/#{report.id}?from=2026-01-01&to=2026-12-31&step=none&format=document&template=#{template}")
    document.content_type.should eq("text/markdown")
    document.content.should contain("Marge : 600,00 / 0,00")
    refused = browser.get("/ext/REPORTS/reports/#{report.id}?from=2026-01-01&to=2026-12-31&format=document&template=#{template}&pdf=1")
    browser.follow(refused).html.should contain("Pas de convertisseur PDF pour ce format sur ce serveur.")
    monthly = browser.get("/ext/REPORTS/reports/#{report.id}?from=2026-01-01&to=2026-06-30&step=quarter").html
    monthly.should contain("01/04/2026 – 30/06/2026")
    browser.get("/ext/REPORTS/reports/#{report.id}?from=2026-05-01&to=2026-01-01").html.should contain("La date de début suit la date de fin.")
  end

  it "révise et conserve une déclaration, la consulte, l'exporte et l'efface" do
    browser = signed_in
    browser.post("/ext/REPORTS/reports/new", report_form)
    report = Api.reports(S.system).first
    keep = browser.get("/ext/REPORTS/reports/#{report.id}/keep?from=2026-01-01&to=2026-12-31").html
    keep.should contain(%(name="amount[CA][N]"))
    kept = browser.post("/ext/REPORTS/reports/#{report.id}/keep", {"from" => "2026-01-01", "to" => "2026-12-31", "step" => "none",
                                                                   "title" => "Marge 2026", "description" => "", "amount[CA][N]" => "1\u202F500,00", "amount[CA][N1]" => "0,00",
                                                                   "amount[CH][N]" => "400,00", "amount[CH][N1]" => "0,00", "amount[MARGE][N]" => "600,00", "amount[MARGE][N1]" => "0,00"})
    kept.status.should eq(302)
    detail = browser.follow(kept).html
    detail.should contain("« Marge 2026 » conservé.")
    detail.should contain("1\u202F100,00")
    detail.should contain("rep-revised")
    snapshot = Api.snapshots(S.system).first
    browser.get("/ext/REPORTS/archive").html.should contain("Marge 2026")
    browser.get("/ext/REPORTS/archive/#{snapshot.id}?format=csv").content.should contain("Marge;1100.00")
    S.modeles_template("report", "{{ declaration.titre }} : {{ montants.MARGE }}")
    browser.get("/ext/REPORTS/archive/#{snapshot.id}").html.should contain("data-reports-document")
    browser.get("/ext/REPORTS/archive/#{snapshot.id}?format=document").content.should contain("Marge 2026 : 1\u202F100,00")
    deleted = browser.post("/ext/REPORTS/archive/#{snapshot.id}/delete")
    browser.follow(deleted).html.should contain("Résultat conservé effacé.")
    Api.snapshots(S.system).should be_empty
  end

  it "définit et calcule un listing, conserve les fiches cochées et les inscrit au suivi" do
    browser = signed_in
    PartiduoUi::Books.card("CUSTOMER", "Client Andrieu", "ANDRIEU")
    browser.get("/ext/REPORTS/listings/new").html.should contain(%(name="columns[0].source"))
    browser.get("/ext/REPORTS/listings/row?index=3").html.should contain(%(name="columns[3].formula"))
    browser.htmx_post("/ext/REPORTS/listings/preview", listing_form).html.should contain("Client Morel")
    created = browser.post("/ext/REPORTS/listings/new", listing_form)
    created.status.should eq(302)
    listing = Api.listings(S.system).first
    page = browser.get("/ext/REPORTS/listings/#{listing.id}?from=2026-01-01&to=2026-12-31").html
    page.should contain("Client Andrieu")
    page.should contain("1\u202F000,00")
    page.should contain(%(name="card_ids"))
    browser.get("/ext/REPORTS/listings/#{listing.id}?format=merge").content.should contain("QUICKCODE;NAME;NOM;CA")
    morel = present(Partiduo::Api::Cards.card_by_code(S.system, "MOREL"))
    kept = browser.perform_raw("/ext/REPORTS/listings/#{listing.id}/keep", "from=2026-01-01&to=2026-12-31&title=Relance&description=&card_ids=#{morel.id}")
    kept.status.should eq(302)
    detail = browser.follow(kept).html
    detail.should contain("Client Morel")
    detail.should_not contain("Client Andrieu")
    snapshot = Api.snapshots(S.system).first
    Partiduo::Api::Modules.activate(S.system, "FOLLOWUP").value!
    Partiduo::Api::Followup.load_default_action_types(S.system)
    type = Partiduo::Api::Followup.action_types(S.system).first
    browser.get("/ext/REPORTS/archive/#{snapshot.id}/followup").html.should contain("Créer l'action")
    done = browser.post("/ext/REPORTS/archive/#{snapshot.id}/followup", {"action_type_id" => type.id.to_s, "date" => "01/10/2026",
                                                                         "title" => "Relancer", "remind_on" => "", "comment" => "", "visible_profile_id" => ""})
    done.status.should eq(302)
    browser.follow(done).html.should contain("1 action créée dans le suivi.")

    # Documents par fiche depuis un modèle (D-REP-021) et envoi (D-REP-027).
    browser.get("/ext/REPORTS/archive/#{snapshot.id}").html.should_not contain("data-reports-document")
    S.modeles_template("listing", "{{ fiche.nom }} : {{ colonnes.CA }}")
    archived = browser.get("/ext/REPORTS/archive/#{snapshot.id}").html
    archived.should contain("data-reports-document")
    archived.should contain(%(name="per_card"))
    archived.should_not contain("data-reports-mail")
    zip = browser.get("/ext/REPORTS/archive/#{snapshot.id}?format=document&per_card=1")
    zip.content_type.should eq("application/zip")
    whole = browser.get("/ext/REPORTS/archive/#{snapshot.id}?format=document&per_card=0")
    whole.content_type.should eq("text/markdown")
    transport = Partiduo::Core::Mail::MemoryTransport.new
    Partiduo::Core::Mail.transport = transport
    begin
      browser.get("/ext/REPORTS/archive/#{snapshot.id}").html.should contain("data-reports-mail")
      Partiduo::Api::Core.update_settings(S.system, Partiduo::Api::Core.settings(S.system).to_input.copy_with(email: "contact@atelier.test")).value!
      mailed = browser.post("/ext/REPORTS/archive/#{snapshot.id}/mail", {"subject" => "Relevé", "body" => "Bonjour", "template" => ""})
      browser.follow(mailed).html.should contain("1 message(s) envoyé(s)")
      transport.messages.map(&.to).should eq([["morel@example.com"]])
    ensure
      Partiduo::Core::Mail.transport = nil
    end
    page = browser.get("/ext/REPORTS/listings/#{listing.id}?from=2026-01-01&to=2026-12-31&paid=no").html
    page.should contain(%(<option value="no" selected>))
  end

  it "partage les définitions : export choisi, définitions fournies, reprise de la Comptabilité, copie" do
    browser = signed_in
    sharing = browser.get("/ext/REPORTS/sharing").html
    sharing.should contain("Soldes intermédiaires de gestion (France)")
    sharing.should contain(%(enctype="multipart/form-data"))
    installed = browser.post("/ext/REPORTS/sharing/starters/SIG")
    browser.follow(installed).html.should contain("Définition SIG installée.")
    sig = Api.reports(S.system).first
    file = browser.perform_raw("/ext/REPORTS/sharing/export", "report_ids=#{sig.id}")
    file.headers["Content-Disposition"].should contain("sig.partiduo-reports.json")
    JSON.parse(file.content)["reports"][0]["code"].should eq("SIG")
    Partiduo::Api::Accounting.create_report(S.system, Partiduo::Api::Accounting::ReportDefinitionInput.new(
      name: "Ventes", lines: [Partiduo::Api::Accounting::ReportLineInput.new("Ventes", "[70%-S]")])).value!
    core = Partiduo::Api::Accounting.reports(S.system).first
    browser.get("/ext/REPORTS/reports/core").html.should contain("Ventes")
    taken = browser.post("/ext/REPORTS/reports/core?id=#{core.id}")
    browser.follow(taken).html.should contain("Rapport « Ventes » repris.")
    copy = browser.post("/ext/REPORTS/reports/#{sig.id}/copy")
    copy.headers["Location"].should match(%r{/ext/REPORTS/reports/\d+/edit})
    Api.reports(S.system).map(&.code).sort!.should eq(["SIG", "SIG_2", "VENTES"])
  end
end
