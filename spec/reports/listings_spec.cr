# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

private alias S = Reports::SpecSupport
private alias Api = Reports::Api

private def customers : Nil
  S.setup
  PartiduoUi::Books.card("CUSTOMER", "Client Morel", "MOREL", email: "morel@example.com")
  PartiduoUi::Books.card("CUSTOMER", "Client Andrieu", "ANDRIEU")
  PartiduoUi::Books.card("CUSTOMER", "Client Zola", "ZOLA")
  PartiduoUi::Books.sale("MOREL", "1000", "2026-03-10")
  PartiduoUi::Books.sale("ANDRIEU", "250", "2026-05-10")
  PartiduoUi::Books.receipt("MOREL", "1200", "2026-03-20")
end

private def listing_input(conditions = [] of Api::ConditionInput) : Api::ListingInput
  Api::ListingInput.new(code: "clients", name: "Clients", category_code: "CUSTOMER", sort_code: "CA", sort_desc: true,
    columns: [
      Api::ListingColumnInput.new(code: "NOM", label: "Nom", source: "field", field_name: "name"),
      Api::ListingColumnInput.new(code: "MAIL", label: "Courriel", source: "field", field_name: "email"),
      Api::ListingColumnInput.new(code: "CA", label: "CA", source: "formula", formula: "[70%-S; card=*]"),
      Api::ListingColumnInput.new(code: "SOLDE", label: "Solde", source: "formula", formula: "{*-s}"),
      Api::ListingColumnInput.new(code: "TTC", label: "TTC", source: "formula", formula: "$CA * 1.2"),
      Api::ListingColumnInput.new(code: "TOUT", label: "Ventes totales", source: "formula", formula: "[70%-S]", hidden: true),
    ], conditions: conditions)
end

describe "Listings de fiches (D-REP-011, D-REP-012)" do
  it "calcule une ligne par fiche : champs, formules sur la fiche courante, colonnes citées, tri et totaux" do
    customers
    listing = Api.create_listing(S.designer, listing_input).value!
    listing.code.should eq("CLIENTS")
    result = Api.run_listing(S.designer, listing.id, Api::ListingRunInput.new(S.date("2026-01-01"), S.date("2026-12-31"))).value!
    result.columns.map(&.code).should eq(["NOM", "MAIL", "CA", "SOLDE", "TTC"])
    result.rows.map(&.card_code).should eq(["MOREL", "ANDRIEU", "ZOLA"])
    morel = result.rows.first
    morel.cells.map(&.text)[0, 2].should eq(["Client Morel", "morel@example.com"])
    morel.cells[2].amount.should eq(S.d("1000"))
    morel.cells[3].amount.should eq(S.d("0"))
    morel.cells[4].amount.should eq(S.d("1200"))
    result.rows[1].cells[3].amount.should eq(S.d("300"))
    result.totals.should eq([nil, nil, S.d("1250"), S.d("300"), S.d("1500")])
  end

  it "filtre par conditions (toutes ensemble) et garde les fiches désactivées sur demande" do
    customers
    conditions = [Api::ConditionInput.new("CA", "gt", "0"), Api::ConditionInput.new("NOM", "contains", "mor")]
    listing = Api.create_listing(S.designer, listing_input(conditions)).value!
    rows = Api.run_listing(S.designer, listing.id).value!.rows
    rows.map(&.card_code).should eq(["MOREL"])
    Reports::ListingEngine.matches?(Api::CellView.new("Paris"), "eq", "paris").should be_true
    Reports::ListingEngine.matches?(Api::CellView.new("12"), "lt", "9").should be_false
    Reports::ListingEngine.matches?(Api::CellView.new(amount: S.d("5")), "ne", "5").should be_false
  end

  it "refuse une définition incohérente" do
    S.setup
    input = Api::ListingInput.new(code: "L", name: "", card_kind: "alien", sort_code: "ZZ",
      columns: [Api::ListingColumnInput.new(code: "A", label: "A", source: "field", field_name: "shoe_size"),
                Api::ListingColumnInput.new(code: "B", label: "B", source: "formula", formula: "$Q"),
                Api::ListingColumnInput.new(code: "C", label: "C", source: "attribute", field_name: "Bad Key")],
      conditions: [Api::ConditionInput.new("Z", "like", "x")])
    fields = Api.check_listing(S.designer, input).errors.map { |error| {error.field, error.key.lchop("reports.errors.")} }
    fields.should contain({"name", "name.blank"})
    fields.should contain({"card_kind", "choice.invalid"})
    fields.should contain({"columns[0].field_name", "choice.invalid"})
    fields.should contain({"columns[1].formula", "line.unknown"})
    fields.should contain({"columns[2].field_name", "attribute.blank"})
    fields.should contain({"sort_code", "column.unknown"})
    fields.should contain({"conditions[0].column_code", "column.unknown"})
    fields.should contain({"conditions[0].operator", "choice.invalid"})
  end

  it "conserve les fiches retenues et les inscrit au suivi, une action par fiche" do
    customers
    listing = Api.create_listing(S.designer, listing_input).value!
    morel = present(Partiduo::Api::Cards.card_by_code(S.system, "MOREL"))
    kept = Api.keep_listing(S.designer, listing.id, Api::ListingRunInput.new, Api::KeepInput.new(title: "Relance",
      card_ids: [morel.id])).value!
    kept.result.rows.map(&.card_code).should eq(["MOREL"])
    kept.result.totals[2].should eq(S.d("1000"))
    Api.keep_listing(S.designer, listing.id, Api::ListingRunInput.new, Api::KeepInput.new(card_ids: [-1_i64]))
      .error_keys.should eq(["reports.errors.keep.none"])
    snapshot = Api.listing_snapshot(S.designer, kept.summary.id)
    snapshot.summary.title.should eq("Relance")
    snapshot.summary.created_by.should eq("Alice Test")
    snapshot.result.rows.first.cells[2].amount.should eq(S.d("1000"))

    Partiduo::Api::Modules.activate(S.system, "FOLLOWUP").value!
    Partiduo::Api::Followup.load_default_action_types(S.system)
    type = Partiduo::Api::Followup.action_types(S.system).first
    added = Api.add_to_followup(S.designer, kept.summary.id, Api::FollowupInput.new(action_type_id: type.id,
      date: S.date("2026-10-01"), title: "Relance client"))
    added.value!.should eq(1)
    actions = Partiduo::Api::Followup.actions(S.system)
    actions.size.should eq(1)
    actions.first.title.should eq("Relance client")
    csv = String.new(Api.listing_snapshot_file(S.designer, kept.summary.id, "csv", merge: true).value!.content)
    csv.lines.first.should eq("﻿QUICKCODE;NAME;NOM;MAIL;CA;SOLDE;TTC")
    csv.lines[1].should eq("MOREL;Client Morel;Client Morel;morel@example.com;1000.00;0.00;1200.00")
  end
end
