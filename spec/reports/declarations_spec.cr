# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

private alias S = Reports::SpecSupport
private alias Api = Reports::Api

private def sales_report : Api::ReportView
  S.setup
  PartiduoUi::Books.card("CUSTOMER", "Client Morel", "MOREL")
  PartiduoUi::Books.sale("MOREL", "1234.5", "2026-03-10")
  S.report(Api::ReportInput.new(code: "VENTES", name: "Ventes", lines: [
    Api::LineInput.new(label: "Chiffre d'affaires", kind: "heading1"),
    S.line("CA", "[70%-S]"), S.line("TVA", "[4457%-S]"),
    Api::LineInput.new(label: "Total", code: "TOTAL", formula: "$CA + $TVA", style: "total"),
    Api::LineInput.new(label: "=1+1", kind: "note"),
  ]))
end

private def run_input : Api::RunInput
  Api::RunInput.new(date_from: S.date("2026-01-01"), date_to: S.date("2026-12-31"))
end

# Pages d'un PDF : objets `/Type /Page` (les octets binaires sont lus en
# Latin-1 pour la recherche).
private def pages(pdf : Bytes) : Int32
  String.new(pdf, "ISO-8859-1").scan(%r{/Type\s*/Page\b}).size
end

describe "Déclarations conservées, exports et documents (D-REP-009, D-REP-013, D-REP-021, D-REP-026)" do
  it "conserve une déclaration révisée, la relit telle quelle même si la définition change, puis l'efface" do
    report = sales_report
    run = run_input.copy_with(overrides: [Api::Override.new("TVA", "N", S.d("250"))])
    kept = Api.keep_declaration(S.designer, report.id, run, Api::KeepInput.new(description: "Pour le comptable")).value!
    kept.summary.title.should eq("Ventes — 01/01/2026 – 31/12/2026")
    Api.update_report(S.designer, report.id, report.to_input.copy_with(lines: [S.line("X", "1")])).success?.should be_true
    view = Api.declaration(S.designer, kept.summary.id)
    S.amount(view.run, "TOTAL").should eq(S.d("1484.50"))
    view.run.lines.find!(&.code.==("TVA")).revised.should eq(["N"])
    Api.snapshots(S.designer, Api::SnapshotQuery.new(kind: "declaration")).map(&.id).should eq([kept.summary.id])
    expect_raises(Partiduo::Api::Forbidden) { Api.delete_snapshot(S.actor("alice@example.com", [Api::READ, Api::DESIGN]), kept.summary.id) }
    Api.delete_snapshot(S.designer, kept.summary.id).success?.should be_true
    expect_raises(Partiduo::Api::NotFound) { Api.declaration(S.designer, kept.summary.id) }
  end

  it "exporte en CSV (protégé contre les formules), en ODS typé et en PDF/A par le socle" do
    report = sales_report
    csv = Api.report_file(S.designer, report.id, run_input, "csv").value!
    csv.filename.should eq("ventes-2026-01-01-2026-12-31.csv")
    text = String.new(csv.content)
    text.should contain("Chiffre d'affaires;\r\n")
    text.should contain("CA;1234.50\r\n")
    text.should contain("'=1+1")
    ods = Api.report_file(S.designer, report.id, run_input, "ods").value!
    ods.content_type.should eq("application/vnd.oasis.opendocument.spreadsheet")
    String.new(ods.content[30, 8]).should eq("mimetype")
    entries = {} of String => String
    Compress::Zip::Reader.open(IO::Memory.new(ods.content)) do |zip|
      zip.each_entry { |entry| entries[entry.filename] = entry.io.gets_to_end }
    end
    entries["mimetype"].should eq("application/vnd.oasis.opendocument.spreadsheet")
    entries["content.xml"].should contain(%(office:value-type="float" office:value="1234.50"))
    pdf = Api.report_file(S.designer, report.id, run_input, "pdf").value!
    pdf.content_type.should eq("application/pdf")
    String.new(pdf.content[0, 5]).should eq("%PDF-")
  end

  it "génère la déclaration depuis un modèle de partiduo-modeles, à la place du CSV des balises (D-REP-021)" do
    report = sales_report
    S.modeles_template("report", <<-MD)
      # {{ declaration.titre }}

      {{ dossier.nom }} — du {{ declaration.debut }} au {{ declaration.fin }}

      CA {{ montants.CA }} ; total {{ montants.TOTAL }}

      {% for ligne in lignes %}{{ ligne.code }}={{ ligne.montant }}|{{ ligne.N }};{% endfor %}
      MD
    kept = Api.keep_declaration(S.designer, report.id, run_input, Api::KeepInput.new(title: "Déclaration 2026")).value!
    amount = ->(text : String) { Reports::Numbers.amount(S.d(text), 2) }
    file = Api.declaration_document(S.writer, kept.summary.id).value!
    file.content_type.should eq("text/markdown")
    text = String.new(file.content)
    text.should contain("# Déclaration 2026")
    text.should contain("Atelier Brunet SARL — du 01/01/2026 au 31/12/2026")
    text.should contain("CA #{amount.call("1234.50")} ; total #{amount.call("1481.40")}")
    text.should contain("CA=#{amount.call("1234.50")}|#{amount.call("1234.50")};")
    # Le rapport calculé, sans conservation.
    run_file = Api.report_document(S.writer, report.id, run_input).value!
    String.new(run_file.content).should contain("# Ventes — 01/01/2026 – 31/12/2026")
    # PDF demandé sans convertisseur sur ce serveur : refus propre.
    Api.report_document(S.writer, report.id, run_input, pdf: true).error_keys.should eq(["modeles.errors.pdf.unavailable"])
    # modeles.read est exigé par l'extension des modèles.
    expect_raises(Partiduo::Api::Forbidden) { Api.report_document(S.designer, report.id, run_input) }
    Api.document_templates(S.designer, "report").should be_empty
    Api.document_templates(S.writer, "report").map(&.name).should eq(["Modèle report"])
  end

  it "ne propose aucun document quand l'extension des modèles est inactive" do
    report = sales_report
    Api.document_templates(S.writer, "report").should be_empty
    Api.report_document(S.writer, report.id, run_input).error_keys.should eq(["reports.errors.documents.unavailable"])
  end

  it "met chaque titre principal sur une nouvelle page et donne leur niveau aux titres dans le PDF (D-REP-026)" do
    report = sales_report
    titled = S.report(Api::ReportInput.new(code: "DEUX", name: "Deux parties", lines: [
      Api::LineInput.new(label: "Première partie", kind: "title"), S.line("A", "[70%-S]"),
      Api::LineInput.new(label: "Seconde partie", kind: "title"), Api::LineInput.new(label: "Détail", kind: "heading2"),
      S.line("B", "[4457%-S]"),
    ]))
    sheet = Reports::Sheets.run_sheet(S.run(titled.id))
    sheet.rows.map { |row| {row.style, row.level, row.page_break} }.should eq([
      {"heading", 1, true}, {"line", 0, false}, {"heading", 1, true}, {"heading", 2, false}, {"line", 0, false},
    ])
    pdf = Api.report_file(S.designer, titled.id, run_input, "pdf").value!.content
    pages(pdf).should eq(2)
    pages(Api.report_file(S.designer, report.id, run_input, "pdf").value!.content).should eq(1)
  end
end
