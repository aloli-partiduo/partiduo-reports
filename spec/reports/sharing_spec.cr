# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

private alias S = Reports::SpecSupport
private alias Api = Reports::Api

# Définition exportée par l'application d'origine (format 4) : titres,
# formule, formule sur codes avec ternaire, poste et contrepartie, liste
# de postes, TVA (non reprise), période N-1.
LEGACY_FILE = <<-BIN
  RAPAV;4
  "Test Formule";"Test sur toutes les formules"
  1;T1;"Ventes";1;10;15;1
  2;F70;"Ventes 70";3;20;15;1
  3;F70N1;"Ventes N-1";3;30;15;3
  4;COMP;"Seuil";3;40;15;1
  5;C411;"Ventes aux clients";3;50;15;1
  6;LST;"Charges";9;60;15;1
  7;TVA;"TVA";3;70;15;1
  8;OLD;"Ancienne syntaxe";3;80;15;1
  RAPAV_DETAIL
  10;2;;;[70%]*1;;;;1;;;;0
  11;3;;;[70%-S];;;;1;;;;0
  12;4;;;"([F70] > 50000)?1:0";;;;3;;;;
  13;5;70%;;;;;;4;41;2;;2
  14;6;6;;;;;;6;;1;;0
  15;7;6%;1;;;ACH;1;2;;;;0
  16;8;;;[70%S];;;;1;;;;0
  BIN

describe "Partage des définitions (D-REP-014 à D-REP-016)" do
  it "exporte et réimporte rapports et listings dans le format documenté, sans écraser par défaut" do
    S.setup
    report = S.report(Api::ReportInput.new(code: "R1", name: "Un", columns: [Api::ColumnInput.new("N", "N"),
                                                                             Api::ColumnInput.new("N1", "N-1", shift_months: -12)], lines: [S.line("A", "[70%-S; ledger=V01]")]))
    listing = Api.create_listing(S.designer, Api::ListingInput.new(code: "L1", name: "Liste", card_kind: "customer",
      columns: [Api::ListingColumnInput.new("NOM", "Nom", "field", "name")],
      conditions: [Api::ConditionInput.new("NOM", "contains", "a")])).value!
    file = Api.export_definitions(S.designer, [report.id], [listing.id])
    file.filename.should eq("definitions.partiduo-reports.json")
    json = JSON.parse(String.new(file.content))
    json["format"].should eq("partiduo-reports")
    json["version"].should eq(1)
    json["reports"][0]["lines"][0]["formula"].should eq("[70%-S; ledger=V01]")
    json["listings"][0]["conditions"][0]["operator"].should eq("contains")

    again = Api.import_definitions(S.designer, String.new(file.content)).value!
    again.skipped.should eq(["R1", "L1"])
    Api.delete_report(S.designer, report.id)
    Api.delete_listing(S.designer, listing.id)
    imported = Api.import_definitions(S.designer, String.new(file.content)).value!
    imported.created.should eq(["R1", "L1"])
    Api.report(S.designer, Api.reports(S.designer).first.id).columns.map(&.shift_months).should eq([0, -12])
    expect_raises(Partiduo::Api::Forbidden) do
      Api.import_definitions(S.actor("alice@example.com", [Api::READ, Api::DESIGN]), String.new(file.content), replace: true)
    end
    Api.import_definitions(S.designer, String.new(file.content), replace: true).value!.replaced.should eq(["R1", "L1"])
  end

  it "refuse un fichier mal formé ou une définition invalide, sans rien importer" do
    S.setup
    Api.import_definitions(S.designer, "{").error_keys.should eq(["reports.errors.import.json"])
    Api.import_definitions(S.designer, %({"format":"autre","version":1})).error_keys.should eq(["reports.errors.import.format"])
    Api.import_definitions(S.designer, %({"format":"partiduo-reports","version":9})).error_keys.should eq(["reports.errors.import.version"])
    bad = %({"format":"partiduo-reports","version":1,"reports":[{"code":"OK","name":"Bon","lines":[{"code":"A","formula":"1"}]},{"code":"KO","name":"Mauvais","lines":[{"code":"A","formula":"[70%"}]}]})
    result = Api.import_definitions(S.designer, bad)
    result.errors.map(&.field).should eq(["reports[1].lines[0].formula"])
    Api.reports(S.designer).should be_empty
  end

  it "convertit une définition de la source legacy et dit ce qui n'est pas repris" do
    S.setup
    result = Api.import_legacy(S.designer, LEGACY_FILE).value!
    result.created.should eq(["TESTFORMULE"])
    result.issues.map(&.key).should eq(["legacy_date_paid", "legacy_vat", "legacy_line"])
    report = Api.report(S.designer, Api.reports(S.designer).first.id)
    formulas = report.lines.to_h { |line| {line.code.presence || line.label, line.formula} }
    report.lines.first.kind.should eq("heading1")
    formulas["F70"].should eq("[70%]*1")
    formulas["F70N1"].should eq("[70%-S; span=year; shift=-1]")
    formulas["COMP"].should eq("if($F70 > 50000, 1, 0)")
    formulas["C411"].should eq("[70%-S; with=41]")
    formulas["LST"].should eq("[6%-s]")
    formulas["OLD"].should eq("[70%-S]")
    report.lines.find!(&.label.starts_with?("TVA")).kind.should eq("note")
    Api.import_legacy(S.designer, "autre;chose").error_keys.should eq(["reports.errors.legacy.format"])
  end

  it "installe les définitions fournies et les calcule" do
    S.setup
    PartiduoUi::Books.card("CUSTOMER", "Client Morel", "MOREL")
    PartiduoUi::Books.sale("MOREL", "1000", "2026-03-10")
    S.entry("2026-04-01", [{"641", "D", "300", nil}, {"510001", "C", "300", nil}])
    Api.starters(S.designer).map(&.code).should eq(["SIG", "CLIENTS_CA"])
    Api.install_starter(S.designer, "SIG").value!.created.should eq(["SIG"])
    Api.install_starter(S.designer, "SIG").value!.skipped.should eq(["SIG"])
    sig = Api.reports(S.designer).find!(&.code.==("SIG"))
    run = S.run(sig.id)
    S.amount(run, "PROD").should eq(S.d("1000"))
    S.amount(run, "PERSO").should eq(S.d("300"))
    S.amount(run, "EBE").should eq(S.d("700"))
    S.amount(run, "RES").should eq(S.d("700"))
    S.amount(run, "RES", 2).should eq(S.d("700"))
    run.issues.should be_empty
    Api.install_starter(S.designer, "CLIENTS_CA").value!.created.should eq(["CLIENTS_CA"])
    listing = Api.listings(S.designer).first
    rows = Api.run_listing(S.designer, listing.id).value!.rows
    rows.map(&.card_code).should eq(["MOREL"])
  end
end
