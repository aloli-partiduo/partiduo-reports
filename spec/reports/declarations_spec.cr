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

describe "Déclarations conservées et exports (D-REP-009, D-REP-010, D-REP-013)" do
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

  it "fournit les balises d'une déclaration comme source de publipostage" do
    report = sales_report
    kept = Api.keep_declaration(S.designer, report.id, run_input, Api::KeepInput.new(title: "Déclaration 2026")).value!
    csv = String.new(Api.declaration_tags_file(S.designer, kept.summary.id).value!.content)
    header, values = csv.lchop('﻿').lines
    tags = header.split(';').zip(values.split(';')).to_h
    tags["CA"].should eq("1234.50")
    tags["TOTAL"].should eq("1481.40")
    tags["TITRE"].should eq("Déclaration 2026")
    tags["NAME"].should eq("Atelier Brunet SARL")
    tags["START_DATE"].should eq("01/01/2026")
  end
end
