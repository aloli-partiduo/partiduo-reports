# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

private alias S = Reports::SpecSupport
private alias Api = Reports::Api
private alias Acc = Partiduo::Api::Accounting

# Ancien calcul de `with=` et `card=` (avant D-REP-022) : lecture des
# écritures page par page, lignes des comptes retenus des écritures qui
# portent la contrepartie ou la fiche. Gardé ici pour vérifier que
# `Accounting.line_sums` donne les mêmes totaux.
private def scanned(pattern : String, prefix : Bool, counterpart : String?, card : String?, from : String,
                    to : String) : {BigDecimal, BigDecimal}
  debit = BigDecimal.new(0)
  credit = BigDecimal.new(0)
  offset = 0
  loop do
    page = Acc.entries(S.designer, Acc::EntryQuery.new(date_from: S.date(from), date_to: S.date(to),
      account: pattern.presence, account_prefix: prefix, card: card, offset: offset, limit: 500))
    page.each do |entry|
      next if counterpart && entry.lines.none?(&.account_number.starts_with?(counterpart))
      lines = entry.lines
      lines.each do |line|
        next unless prefix ? line.account_number.starts_with?(pattern) : line.account_number == pattern
        debit += line.debit
        credit += line.credit
      end
    end
    offset += 500
    break if page.size < 500
  end
  {debit, credit}
end

# Ventes à deux clients, un règlement de MOREL (lettré), un avoir, une
# écriture diverse qui touche 70 sans client.
private def books : Nil
  S.setup
  PartiduoUi::Books.card("CUSTOMER", "Client Morel", "MOREL", email: "morel@example.com")
  PartiduoUi::Books.card("CUSTOMER", "Client Andrieu", "ANDRIEU")
  PartiduoUi::Books.sale("MOREL", "1000", "2026-03-10")
  PartiduoUi::Books.sale("ANDRIEU", "400", "2026-04-02")
  PartiduoUi::Books.sale("MOREL", "250", "2026-11-20")
  S.entry("2026-05-15", [{"706", "D", "60", nil}, {"510001", "C", "60", nil}])
end

describe "Amendements du contrat réalisés le 20 octobre 2026" do
  it "calcule with= et card= par les sommes du cœur, aux mêmes totaux que l'ancienne lecture des écritures (D-REP-022)" do
    books
    report = S.report(Api::ReportInput.new(code: "CMP", name: "Comparaison", lines: [
      S.line("W", "[70%-s; with=41]"), S.line("WC", "[70%-c; with=410]"), S.line("WD", "[44%-d; with=7]"),
      S.line("M", "[70%-s; card=MOREL]"), S.line("A", "[7%-S; card=ANDRIEU]"), S.line("T", "[41%-s; card=MOREL]"),
      S.line("X", "[70%-s; with=51]"),
    ]))
    run = S.run(report.id)
    run.issues.should be_empty
    {
      "W" => {"70", true, "41", nil, 's'}, "WC" => {"70", true, "410", nil, 'c'}, "WD" => {"44", true, "7", nil, 'd'},
      "M" => {"70", true, nil, "MOREL", 's'}, "A" => {"7", true, nil, "ANDRIEU", 'S'}, "T" => {"41", true, nil, "MOREL", 's'},
      "X" => {"70", true, "51", nil, 's'},
    }.each do |code, (pattern, prefix, counterpart, card, mode)|
      debit, credit = scanned(pattern, prefix, counterpart, card, "2026-01-01", "2026-12-31")
      expected = case mode
                 when 'd' then debit
                 when 'c' then credit
                 when 'S' then credit - debit
                 else          debit - credit
                 end
      S.amount(run, code).should eq(expected.round(2))
    end
    S.amount(run, "M").should eq(S.d("-1250"))
    S.amount(run, "A").should eq(S.d("400"))
    S.amount(run, "X").should eq(S.d("60"))
  end

  it "ne demande plus accounting.entry.read pour with= et card= : accounting.report.read suffit" do
    books
    report = S.report(Api::ReportInput.new(code: "CA", name: "CA", lines: [S.line("M", "[70%-S; card=MOREL]")]))
    reader = S.actor("bruno@example.com", [Api::READ, "accounting.report.read", "cards.card.read"])
    run = S.run(report.id, actor: reader)
    run.issues.should be_empty
    S.amount(run, "M").should eq(S.d("1250"))
  end

  it "situe les écritures à leur date de paiement ou d'échéance, payées ou non (D-REP-024)" do
    books
    sale = PartiduoUi::Books.sale("MOREL", "100", "2026-05-20", due: "2026-07-15")
    receipt = PartiduoUi::Books.receipt("MOREL", "120", "2026-06-30").first
    Acc.match_lines(S.system, [PartiduoUi::Books.line_of(sale, "MOREL").id, PartiduoUi::Books.line_of(receipt, "MOREL").id]).value!
    report = S.report(Api::ReportInput.new(code: "PAY", name: "Paiements", lines: [
      S.line("ALL", "[70%-S]"), S.line("UNPAID", "[70%-S; paid=no]"), S.line("PAID", "[70%-S; paid=yes]"),
      S.line("PAYMENT", "[70%-S; date=payment]"), S.line("DUE", "[70%-S; date=due]"),
      S.line("WITH", "[70%-S; with=41; paid=yes]"),
    ]))
    Api.check_formula(S.designer, "[70%; date=hier]").error_keys.should eq(["reports.errors.formula.option_value"])
    Api.check_formula(S.designer, "[70%; paid=peut-etre]").error_keys.should eq(["reports.errors.formula.option_value"])
    Api.check_formula(S.designer, "{MOREL; paid=no}").error_keys.should eq(["reports.errors.formula.option"])
    Api.check_formula(S.designer, "{{P; date=due}}").error_keys.should eq(["reports.errors.formula.option"])
    year = S.run(report.id)
    S.amount(year, "ALL").should eq(S.d("1690"))
    S.amount(year, "PAID").should eq(S.d("100"))
    # Ventes non payées : la vente diverse sans tiers n'est ni l'une ni l'autre.
    S.amount(year, "UNPAID").should eq(S.d("1650"))
    S.amount(year, "WITH").should eq(S.d("100"))
    june = S.run(report.id, from: "2026-06-01", to: "2026-06-30")
    S.amount(june, "ALL").should eq(S.d("0"))
    S.amount(june, "PAYMENT").should eq(S.d("100"))
    july = S.run(report.id, from: "2026-07-01", to: "2026-07-31")
    S.amount(july, "DUE").should eq(S.d("100"))
    S.amount(july, "ALL").should eq(S.d("0"))
  end

  it "applique le filtre payé / non payé d'un listing à ses références de comptes et le conserve (D-REP-024)" do
    books
    listing = Api.create_listing(S.designer, Api::ListingInput.new(code: "DUS", name: "Dus", card_kind: "customer",
      columns: [Api::ListingColumnInput.new("CA", "CA", "formula", formula: "[70%-S; card=*]"),
                Api::ListingColumnInput.new("SOLDE", "Solde", "formula", formula: "{*-s}")])).value!
    from = S.date("2026-01-01")
    to = S.date("2026-12-31")
    all = Api.run_listing(S.designer, listing.id, Api::ListingRunInput.new(from, to)).value!
    unpaid = Api.run_listing(S.designer, listing.id, Api::ListingRunInput.new(from, to, false)).value!
    paid = Api.run_listing(S.designer, listing.id, Api::ListingRunInput.new(from, to, true)).value!
    total = ->(view : Api::ListingResultView) { view.totals[0] || S.d("0") }
    (total.call(paid) + total.call(unpaid)).should eq(total.call(all))
    total.call(all).should eq(S.d("1650"))
    total.call(unpaid).should eq(S.d("1650"))
    unpaid.paid.should be_false
    unpaid.issues.map(&.key).should contain("paid_card")
    all.issues.map(&.key).should_not contain("paid_card")
    kept = Api.keep_listing(S.designer, listing.id, Api::ListingRunInput.new(from, to, false), Api::KeepInput.new).value!
    Api.listing_snapshot(S.designer, kept.summary.id).result.paid.should be_false
  end

  it "détaille la base et la TVA par code de taux (D-REP-023)" do
    books
    totals = Acc.vat_totals(S.designer, Acc::VatTotalsQuery.new(date_from: S.date("2026-01-01"), date_to: S.date("2026-12-31")))
    codes = totals.map(&.vat_rate_code).uniq!
    report = S.report(Api::ReportInput.new(code: "TVA", name: "TVA", lines: [
      S.line("BASE", "[%-S; vat=*]"), S.line("TAXE", "[%-S; vat=*; vat_part=tax]"),
      S.line("TOUT", "[%-S; vat=*; vat_part=total]"), S.line("VENTE", "[70%-S; vat=*; ledger_kind=sale]"),
      S.line("AUCUN", "[%-S; vat=ZZZ]"),
    ]))
    Api.check_formula(S.designer, "[70%; vat=*; with=41]").error_keys.should eq(["reports.errors.formula.option"])
    Api.check_formula(S.designer, "[70%; vat_part=tax]").error_keys.should eq(["reports.errors.formula.option"])
    Api.check_formula(S.designer, "[70%; vat_part=autre; vat=*]").error_keys.should eq(["reports.errors.formula.option_value"])
    run = S.run(report.id)
    base = -totals.sum(S.d("0"), &.base)
    tax = -totals.sum(S.d("0"), &.tax)
    S.amount(run, "BASE").should eq(base.round(2))
    S.amount(run, "TAXE").should eq(tax.round(2))
    S.amount(run, "TOUT").should eq((base + tax).round(2))
    S.amount(run, "AUCUN").should eq(S.d("0"))
    codes.should_not be_empty
    base.should be > S.d("0")
  end

  it "génère les documents d'un listing conservé, un par fiche ou un pour tout le listing (D-REP-021)" do
    books
    listing = Api.create_listing(S.designer, Api::ListingInput.new(code: "CLI", name: "Clients", card_kind: "customer",
      columns: [Api::ListingColumnInput.new("CA", "CA", "formula", formula: "[70%-S; card=*]")])).value!
    kept = Api.keep_listing(S.designer, listing.id, Api::ListingRunInput.new(S.date("2026-01-01"), S.date("2026-12-31")),
      Api::KeepInput.new(title: "Relance")).value!
    S.modeles_template("listing", <<-MD)
      # {{ listing.titre }}

      {% if fiche.nom %}Cher {{ fiche.nom }}, votre chiffre d'affaires : {{ colonnes.CA }}.{% endif %}
      {% for ligne in fiches %}{{ ligne.code }}={{ ligne.CA }};{% endfor %}
      Total : {{ totaux.CA }}
      MD
    zip = Api.listing_document(S.writer, kept.summary.id).value!
    zip.content_type.should eq("application/zip")
    entries = {} of String => String
    Compress::Zip::Reader.open(IO::Memory.new(zip.content)) do |archive|
      archive.each_entry { |entry| entries[entry.filename] = entry.io.gets_to_end }
    end
    entries.keys.sort!.should eq(["andrieu-modele-listing-v1.md", "morel-modele-listing-v1.md"])
    morel = entries["morel-modele-listing-v1.md"]
    morel.should contain("Cher Client Morel, votre chiffre d'affaires : #{Reports::Numbers.amount(S.d("1250"), 2)}.")
    morel.should_not contain("ANDRIEU=")
    whole = String.new(Api.listing_document(S.writer, kept.summary.id, per_card: false).value!.content)
    whole.should_not contain("Cher")
    whole.should contain("MOREL=#{Reports::Numbers.amount(S.d("1250"), 2)};")
    whole.should contain("ANDRIEU=")
    whole.should contain("Total : #{Reports::Numbers.amount(S.d("1650"), 2)}")
  end

  it "envoie à chaque fiche son document par le courriel du socle, après validation (D-REP-027)" do
    books
    listing = Api.create_listing(S.designer, Api::ListingInput.new(code: "CLI", name: "Clients", card_kind: "customer",
      columns: [Api::ListingColumnInput.new("CA", "CA", "formula", formula: "[70%-S; card=*]")])).value!
    kept = Api.keep_listing(S.designer, listing.id, Api::ListingRunInput.new(S.date("2026-01-01"), S.date("2026-12-31")),
      Api::KeepInput.new(title: "Relance")).value!
    S.modeles_template("listing", "{{ fiche.nom }} : {{ colonnes.CA }} ({{ fiche.courriel }})")
    input = Api::MailInput.new(subject: "Votre relevé", body: "Bonjour,\nvoici votre relevé.", pdf: false)
    Api.mail_listing(S.writer, kept.summary.id, input).error_keys.should eq(["core.errors.mail.not_configured"])
    transport = Partiduo::Core::Mail::MemoryTransport.new
    Partiduo::Core::Mail.transport = transport
    begin
      Partiduo::Api::Core.update_settings(S.system, Partiduo::Api::Core.settings(S.system).to_input.copy_with(email: "contact@atelier.test")).value!
      expect_raises(Partiduo::Api::Forbidden) { Api.mail_listing(S.actor("alice@example.com", [Api::READ, Modeles::Api::READ]), kept.summary.id, input) }
      Api.mail_listing(S.writer, kept.summary.id, input.copy_with(subject: " ")).error_keys.should eq(["reports.errors.mail.subject_blank"])
      result = Api.mail_listing(S.writer, kept.summary.id, input)
      sent = result.value? || raise "envoi refusé : #{result.error_keys}"
      sent.sent.should eq(1)
      sent.skipped.should eq(["ANDRIEU"])
      transport.messages.size.should eq(1)
      message = transport.messages.first
      message.to.should eq(["morel@example.com"])
      message.subject.should eq("Votre relevé")
      message.attachments.map(&.filename).should eq(["morel-modele-listing-v1.md"])
      String.new(message.attachments.first.content).should contain("Client Morel : #{Reports::Numbers.amount(S.d("1250"), 2)} (morel@example.com)")
      Partiduo::Api::Mail.messages(S.system, Reports::CODE).size.should eq(1)
    ensure
      Partiduo::Core::Mail.transport = nil
    end
  end
end
