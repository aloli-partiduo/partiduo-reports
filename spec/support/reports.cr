# SPDX-License-Identifier: AGPL-3.0-or-later

# Valeur attendue présente : échoue clairement sinon (plutôt que `not_nil!`).
def present(value : T?) : T forall T
  value.nil? ? raise("valeur attendue, nil obtenu") : value
end

module Reports
  # Outils des specs : dossier provisionné par le contrat du cœur (plan
  # comptable du régime, journaux de référence), exercices 2025 à 2027,
  # extension active, acteurs, écritures d'exemple.
  module SpecSupport
    alias Api = Reports::Api
    alias Acc = Partiduo::Api::Accounting

    # Droits du cœur d'un lecteur de rapports complet.
    CORE_PERMISSIONS = ["accounting.report.read", "accounting.entry.read", "accounting.ledger.read",
                        "accounting.account.read", "cards.card.read", "analytic.report.read", "analytic.plan.read",
                        "followup.action.read", "followup.action.write"]

    def self.system : Partiduo::Api::Actor
      Partiduo::Api::Actor.system
    end

    def self.d(text : String) : BigDecimal
      BigDecimal.new(text)
    end

    def self.date(text : String) : Time
      Time.parse_utc(text, "%Y-%m-%d")
    end

    def self.setup(regime : String = "fr") : Nil
      activate
      PartiduoUi::Reference.provision(regime)
      [2025, 2026, 2027].each { |year| PartiduoUi::Reference.fiscal_year(year) }
      user("alice@example.com", "Alice")
      user("bruno@example.com", "Bruno")
    end

    def self.activate : Nil
      Partiduo::Api::Modules.activate(system, Reports::CODE).value!
    end

    def self.user(email : String, first_name : String) : Int64
      input = Partiduo::Api::Auth::UserInput.new(email: email, first_name: first_name, last_name: "Test", role: "member",
        profile_id: PartiduoUi::Accounts.profile_id("ADMIN"), password: PartiduoUi::Accounts::PASSWORD)
      Partiduo::Api::Auth.create_user(system, input).value!.user.id
    end

    def self.user_id(email : String) : Int64
      Partiduo::Api::Auth.user_by_email(system, email).try(&.id) || raise "utilisateur #{email} absent"
    end

    def self.actor(email : String, permissions : Array(String)) : Partiduo::Api::Actor
      Partiduo::Api::Actor.user(user_id(email), permissions, level: 3)
    end

    # Concepteur : toute l'extension et les droits du cœur qu'elle lit.
    def self.designer : Partiduo::Api::Actor
      actor("alice@example.com", [Api::READ, Api::DESIGN, Api::ADMIN] + CORE_PERMISSIONS)
    end

    # Lecteur sans droit sur les éditions de la Comptabilité.
    def self.reader : Partiduo::Api::Actor
      actor("bruno@example.com", [Api::READ, "cards.card.read"])
    end

    def self.ledger(code : String) : Acc::LedgerView
      Acc.ledger_by_code(system, code)
    end

    # Écriture d'opérations diverses : `{compte, sens, montant, fiche}`.
    def self.entry(day : String, lines : Array({String, String, String, String?}), ledger : String = "O01") : Acc::EntryView
      inputs = lines.map do |(account, side, amount, card)|
        Acc::EntryLineInput.new(account: account, side: side == "D" ? Acc::Side::Debit : Acc::Side::Credit,
          amount: d(amount), card: card)
      end
      Acc.post_entry(system, Acc::EntryInput.new(ledger_id: ledger(ledger).id, date: date(day), lines: inputs)).value!
    end

    def self.report(input : Api::ReportInput) : Api::ReportView
      result = Api.create_report(designer, input)
      raise "rapport refusé : #{result.errors.map { |error| "#{error.field} #{error.key}" }.join(", ")}" if result.failure?
      result.value!
    end

    def self.run(id : Int64, from : String = "2026-01-01", to : String = "2026-12-31", step : String = "none",
                 actor : Partiduo::Api::Actor = designer) : Api::RunView
      Api.run_report(actor, id, Api::RunInput.new(date_from: date(from), date_to: date(to), step: step)).value!
    end

    # Montant d'une ligne (par code) dans une colonne (par rang).
    def self.amount(run : Api::RunView, code : String, column : Int32 = 0) : BigDecimal?
      run.lines.find! { |line| line.code == code }.values[column]
    end

    # Active l'extension des modèles de documents et y dépose (puis active,
    # et désigne par défaut en français) un modèle Markdown de la sorte
    # `kind` (`report` ou `listing`).
    def self.modeles_template(kind : String, content : String, format : String = "markdown") : Int64
      Partiduo::Api::Modules.activate(system, "MODELES").value! unless Partiduo::Modules.active?("MODELES")
      upload = Modeles::Api.upload(system, Modeles::Api::UploadInput.new(filename: "modele.#{Modeles::Config::EXTENSIONS[format]}",
        content: content.to_slice, name: "Modèle #{kind}", kind: kind, locale: "fr"))
      raise "modèle refusé : #{upload.errors.map(&.key).join(", ")}" if upload.failure?
      id = upload.value!.id
      Modeles::Api.activate(system, id).value!
      Modeles::Api.set_default(system, id).value!
      id
    end

    # Concepteur qui lit aussi les modèles de documents.
    def self.writer : Partiduo::Api::Actor
      actor("alice@example.com", [Api::READ, Api::DESIGN, Api::ADMIN, Modeles::Api::READ] + CORE_PERMISSIONS)
    end

    def self.line(code : String, formula : String, kind : String = "formula", label : String? = nil) : Api::LineInput
      Api::LineInput.new(label: label || code, kind: kind, code: code, formula: formula)
    end
  end
end
