# SPDX-License-Identifier: AGPL-3.0-or-later

module Reports
  # Outils communs du métier : erreurs du contrat, acteur système, dates,
  # recherche des lignes (interne).
  module Records
    alias FieldError = Partiduo::Api::FieldError

    ZERO = BigDecimal.new(0)

    def self.error(field : String, key : String, params : Hash(String, String) = {} of String => String) : FieldError
      FieldError.new(field, "reports.errors.#{key}", params)
    end

    def self.system : Partiduo::Api::Actor
      Partiduo::Api::Actor.system
    end

    def self.today : Time
      Partiduo::Api::Core.today
    end

    def self.iso(day : Time) : String
      day.to_s("%Y-%m-%d")
    end

    def self.day(value : Time) : Time
      Time.utc(value.year, value.month, value.day)
    end

    def self.parse_day(text : String) : Time?
      Time.parse_utc(text, "%Y-%m-%d")
    rescue Time::Format::Error
      nil
    end

    def self.report!(id : Int64) : Report
      Report.filter(id: id).first || raise Partiduo::Api::NotFound.new("reports_report", id)
    end

    def self.listing!(id : Int64) : Listing
      Listing.filter(id: id).first || raise Partiduo::Api::NotFound.new("reports_listing", id)
    end

    def self.snapshot!(id : Int64, kind : String) : Snapshot
      Snapshot.filter(id: id, kind: kind).first || raise Partiduo::Api::NotFound.new("reports_snapshot", id)
    end

    # Nom affiché d'un utilisateur (vide s'il n'existe plus).
    def self.user_name(id : Int64?) : String
      return "" unless id
      Partiduo::Api::Auth.user(system, id).full_name
    rescue Partiduo::Api::NotFound | Partiduo::Api::AccessDenied
      ""
    end

    # Dossier d'un foyer (ADR-011 A3).
    def self.household? : Bool
      Partiduo::Api::Core.settings(system).household?
    rescue Partiduo::Api::NotFound
      false
    end

    # Régime du dossier (`fr`, `be`…), `fr` à défaut.
    def self.regime : String
      Partiduo::Api::Core.settings(system).tax_regime.presence || "fr"
    rescue Partiduo::Api::NotFound
      "fr"
    end
  end
end
