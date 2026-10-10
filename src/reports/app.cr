# SPDX-License-Identifier: AGPL-3.0-or-later

require "json"
require "compress/zip"

require "./manifest"
require "./models/**"
require "./services/formula"
require "./services/**"
require "./api/**"

# Extension des rapports avancés et des listings de Partiduo (ADR-003) :
# rapports définis par lignes et colonnes, formules sûres sur les comptes,
# les fiches, l'analytique et les périodes, calculées en `BigDecimal` par
# le contrat du cœur ; déclarations conservées ; listings de fiches à
# colonnes paramétrables, filtrés, source de publipostage, inscrits au
# suivi ; exports CSV, ODS et PDF ; définitions partagées entre dossiers
# par un format JSON documenté. Même plan qu'une application du cœur :
# `manifest.cr`, `models/`, `migrations/`, `services/` (internes), `api/`
# (contrat public `Reports::Api`), `locales/`, `starters/` (définitions
# fournies).
module Reports
  # Lue à la compilation dans `shard.yml`, seule source du numéro : chaque
  # commit y incrémente le dernier chiffre.
  VERSION = {{
              (read_file("#{__DIR__}/../../shard.yml")
                .lines
                .find(&.starts_with?("version:")) || "version: 0.0.0")
                .gsub(/^version:\s*/, "")
                .chomp
            }}

  # Code du registre (ADR-003 D2) : `reports` dans `PARTIDUO_MODULES`.
  CODE = "REPORTS"

  # Application Marten du métier : modèles (tables `reports_*`), migrations
  # et libellés.
  class App < Marten::App
    label "reports"
  end

  # Applications Marten du métier, à ajouter à `installed_apps` de la
  # distribution après `Partiduo::INSTALLED_APPS`.
  INSTALLED_APPS = [Reports::App] of Marten::Apps::Config.class
end
