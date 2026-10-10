# SPDX-License-Identifier: AGPL-3.0-or-later

module Reports
  # Définitions fournies avec l'extension (D-REP-016), au format de partage
  # (`starters/*.json`, lus à la compilation) : elles s'installent dans le
  # dossier comme un import, puis se modifient librement. Elles remplacent
  # le dépôt de rapports téléchargeables de la source legacy. Interne.
  module Starters
    record Starter, code : String, kind : String, regime : String, content : String

    ALL = [
      Starter.new("SIG", "report", "fr", {{ read_file("#{__DIR__}/../starters/sig.json") }}),
      Starter.new("CLIENTS_CA", "listing", "", {{ read_file("#{__DIR__}/../starters/customers.json") }}),
    ]

    def self.find(code : String) : Starter?
      ALL.find(&.code.==(code))
    end
  end
end
