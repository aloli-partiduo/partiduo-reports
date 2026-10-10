# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

private alias S = Reports::SpecSupport
private alias Api = Reports::Api

# Ventes à Morel (706, 44571, compte du client) en 2025 et 2026 ; charges
# 627 et 641 réglées par la banque en 2026.
private def books : Partiduo::Api::Cards::CardView
  S.setup
  card = PartiduoUi::Books.card("CUSTOMER", "Client Morel", "MOREL")
  PartiduoUi::Books.sale("MOREL", "500", "2025-06-10")
  PartiduoUi::Books.sale("MOREL", "1000", "2026-03-10")
  S.entry("2026-04-01", [{"627", "D", "300", nil}, {"641", "D", "100", nil}, {"510001", "C", "400", nil}])
  card
end

private def margin_report : Api::ReportView
  S.report(Api::ReportInput.new(code: "marge", name: "Marge", decimals: 2,
    columns: [
      Api::ColumnInput.new(code: "N", label: "N"),
      Api::ColumnInput.new(code: "N1", label: "N-1", shift_months: -12),
      Api::ColumnInput.new(code: "VAR", label: "Écart", kind: "formula", formula: "@N - @N1"),
    ],
    lines: [
      Api::LineInput.new(label: "Compte de marge", kind: "title"),
      S.line("CA", "[70%-S]"),
      S.line("CHARGES", "[6%-s]"),
      Api::LineInput.new(label: "Marge", code: "MARGE", formula: "$CA - $CHARGES", style: "bold"),
      S.line("DETAIL", "[6%-s]", kind: "accounts"),
      S.line("TVA", "[44571-S; ledger=V01]"),
      S.line("TVAO", "[44571-S; ledger=O01]"),
      S.line("INCONNU", "[70%-S; ledger=ZZZ]"),
      S.line("CLIENT", "{MOREL-s}"),
      S.line("CONTRE", "[70%-S; with=4]"),
      S.line("ANNEE", "[70%-S; span=year]"),
      S.line("OUVERT", "[70%-S; span=opening]"),
      Api::LineInput.new(label: "Caché", code: "CACHE", formula: "$CA * 2", hidden: true),
      Api::LineInput.new(label: "Signe", code: "SIGNE", formula: "$CACHE", negate: true),
    ]))
end

describe "Rapports avancés : définition et calcul (D-REP-005 à D-REP-008)" do
  it "calcule les lignes par colonne, les formules de colonnes, les listes de comptes et les options" do
    books
    report = margin_report
    report.code.should eq("MARGE")
    run = S.run(report.id, "2026-01-01", "2026-12-31")
    run.columns.map(&.code).should eq(["N", "N1", "VAR"])
    run.columns[1].date_from.should eq(S.date("2025-01-01"))
    S.amount(run, "CA").should eq(S.d("1000"))
    S.amount(run, "CA", 1).should eq(S.d("500"))
    S.amount(run, "CA", 2).should eq(S.d("500"))
    S.amount(run, "CHARGES").should eq(S.d("400"))
    S.amount(run, "MARGE").should eq(S.d("600"))
    S.amount(run, "MARGE", 2).should eq(S.d("100"))
    children = run.lines.select(&.account)
    children.map { |line| {line.account, line.values[0]} }.should eq([{"627", S.d("300")}, {"641", S.d("100")}])
    children.first.indent.should eq(1)
    S.amount(run, "TVA").should eq(S.d("200"))
    S.amount(run, "TVAO").should eq(S.d("0"))
    S.amount(run, "INCONNU").should eq(S.d("0"))
    S.amount(run, "CLIENT").should eq(S.d("1200"))
    S.amount(run, "CLIENT", 1).should eq(S.d("600"))
    S.amount(run, "CONTRE").should eq(S.d("1000"))
    S.amount(run, "ANNEE").should eq(S.d("1000"))
    run.lines.any?(&.code.==("CACHE")).should be_false
    S.amount(run, "SIGNE").should eq(S.d("-2000"))
    S.amount(run, "SIGNE", 2).should eq(S.d("-1000"))
    run.issues.map(&.key).should eq(["ledger_unknown"])

    partial = S.run(report.id, "2026-04-01", "2026-12-31")
    S.amount(partial, "CA").should eq(S.d("0"))
    S.amount(partial, "OUVERT").should eq(S.d("1000"))
  end

  it "génère une colonne par tranche (pas mensuel, dernière tranche tronquée)" do
    books
    run = S.run(margin_report.id, "2026-01-01", "2026-04-15", step: "month")
    run.columns.size.should eq(4)
    run.columns.last.date_to.should eq(S.date("2026-04-15"))
    S.amount(run, "CA", 2).should eq(S.d("1000"))
    S.amount(run, "CHARGES", 3).should eq(S.d("400"))
  end

  it "prend les montants révisés et les reporte sur les lignes qui les citent" do
    books
    report = margin_report
    input = Api::RunInput.new(date_from: S.date("2026-01-01"), date_to: S.date("2026-12-31"),
      overrides: [Api::Override.new("CA", "N", S.d("1500"))])
    run = Api.run_report(S.designer, report.id, input).value!
    S.amount(run, "MARGE").should eq(S.d("1100"))
    run.lines.find!(&.code.==("CA")).revised.should eq(["N"])
    bad = Api.run_report(S.designer, report.id, Api::RunInput.new(overrides: [Api::Override.new("ZZ", "N", S.d("1"))]))
    bad.error_keys.should eq(["reports.errors.override.unknown"])
    Api.run_report(S.designer, report.id, Api::RunInput.new(date_from: S.date("2026-05-01"), date_to: S.date("2026-01-01")))
      .error_keys.should eq(["reports.errors.run.dates"])
  end

  it "ne montre au lecteur que ce que ses droits du cœur lui ouvrent, et le dit" do
    books
    run = S.run(margin_report.id, actor: S.reader)
    S.amount(run, "CA").should eq(S.d("0"))
    run.issues.map(&.key).should contain("forbidden")
    expect_raises(Partiduo::Api::Forbidden) { Api.create_report(S.reader, Api::ReportInput.new(code: "X", name: "X")) }
  end

  it "refuse une définition incohérente, champ par champ" do
    S.setup
    input = Api::ReportInput.new(code: "1x", name: " ", decimals: 3,
      columns: [Api::ColumnInput.new(code: "D", label: "D", kind: "formula", formula: "@N"),
                Api::ColumnInput.new(code: "N", label: "N")],
      lines: [S.line("A", "$B"), S.line("B", "$A"), S.line("C", "[70%] +"), S.line("L", "[6%] + 1", kind: "accounts"),
              S.line("A", "1"), Api::LineInput.new(kind: "heading1", label: "")])
    result = Api.check_report(S.designer, input)
    fields = result.errors.map { |error| {error.field, error.key.lchop("reports.errors.")} }
    fields.should contain({"code", "code.invalid"})
    fields.should contain({"name", "name.blank"})
    fields.should contain({"decimals", "decimals.range"})
    fields.should contain({"columns[0].formula", "column.order"})
    fields.should contain({"lines[2].formula", "formula.syntax"})
    fields.should contain({"lines[3].formula", "accounts.single"})
    fields.should contain({"lines[4].code", "code.duplicate"})
    fields.should contain({"lines[5].label", "label.blank"})
    cyclic = Api.check_report(S.designer, Api::ReportInput.new(code: "C", name: "C", lines: [S.line("A", "$B"), S.line("B", "$A")]))
    cyclic.error_keys.should eq(["reports.errors.line.cycle"])
    S.report(Api::ReportInput.new(code: "UN", name: "Un", lines: [S.line("A", "1")]))
    Api.create_report(S.designer, Api::ReportInput.new(code: "un", name: "Deux", lines: [S.line("A", "1")]))
      .error_keys.should eq(["reports.errors.code.taken"])
  end

  it "modifie, copie et efface une définition ; l'aperçu calcule sans enregistrer" do
    books
    report = margin_report
    copy = Api.copy_report(S.designer, report.id).value!
    copy.code.should eq("MARGE_2")
    copy.name.should eq("Marge (copie)")
    copy.lines.size.should eq(report.lines.size)
    updated = Api.update_report(S.designer, copy.id, copy.to_input.copy_with(name: "Marge bis", lines: [S.line("X", "[70%-S]")])).value!
    updated.lines.map(&.code).should eq(["X"])
    preview = Api.preview_report(S.designer, Api::ReportInput.new(code: "MARGE", name: "Aperçu", lines: [S.line("P", "[70%-S] * 2")]),
      Api::RunInput.new(date_from: S.date("2026-01-01"), date_to: S.date("2026-12-31"))).value!
    preview.report_id.should be_nil
    S.amount(preview, "P").should eq(S.d("2000"))
    Api.delete_report(S.designer, copy.id).success?.should be_true
    Api.reports(S.designer).map(&.code).should eq(["MARGE"])
  end

  it "reprend un rapport personnalisé de la Comptabilité" do
    books
    core = Partiduo::Api::Accounting.create_report(S.system, Partiduo::Api::Accounting::ReportDefinitionInput.new(
      name: "Ventes", lines: [Partiduo::Api::Accounting::ReportLineInput.new("Ventes", "[70%-S]")])).value!
    Api.core_reports(S.designer).map(&.name).should eq(["Ventes"])
    imported = Api.import_core_report(S.designer, core.id).value!
    imported.code.should eq("VENTES")
    S.amount(S.run(imported.id), "L1").should eq(S.d("1000"))
  end
end
