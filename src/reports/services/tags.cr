# SPDX-License-Identifier: AGPL-3.0-or-later

module Reports
  # Balises spéciales d'une déclaration (D-REP-010) : dossier et période,
  # sur le modèle de la source legacy ; elles remplissent les objets
  # `declaration` et `dossier` d'un document généré depuis un modèle
  # (`Documents`, D-REP-021). Interne.
  module Tags
    def self.special(run : Api::RunView, title : String, description : String) : Array({String, String})
      settings = begin
        Partiduo::Api::Core.settings(Records.system)
      rescue Partiduo::Api::NotFound
        nil
      end
      days = (run.date_to - run.date_from).days + 1
      months = (run.date_to.year - run.date_from.year) * 12 + run.date_to.month - run.date_from.month + 1
      [
        {"TITRE", title},
        {"NOTE", description},
        {"PERIODE_DECLARATION", Numbers.range_label(run.date_from, run.date_to)},
        {"START_DATE", Numbers.date(run.date_from)},
        {"END_DATE", Numbers.date(run.date_to)},
        {"TODAY", Numbers.date(Records.today)},
        {"INTERVAL_DAY", days.to_s},
        {"INTERVAL_MONTH", months.to_s},
        {"INTERVAL_YEAR", (months // 12).to_s},
        {"NAME", settings.try(&.company_name) || ""},
        {"ENTITY_ID", settings.try(&.vat_number) || ""},
        {"SIREN", settings.try(&.siren) || ""},
        {"STREET", settings.try(&.street) || ""},
        {"NUMBER", settings.try(&.street_number) || ""},
        {"CEDEX", settings.try(&.postcode) || ""},
        {"LOCALITE", settings.try(&.city) || ""},
        {"COUNTRY", settings.try(&.country_code) || ""},
        {"PHONE", settings.try(&.phone) || ""},
      ]
    end
  end
end
