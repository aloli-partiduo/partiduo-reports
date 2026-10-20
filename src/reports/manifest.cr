# SPDX-License-Identifier: AGPL-3.0-or-later

# Manifeste de l'extension des rapports avancés et des listings (ADR-003 D2).
#
# * Dépendance : `ACCOUNTING` — les montants viennent des éditions de la
#   Comptabilité (balance générale, balance des tiers, écritures), lues
#   avec les droits de l'acteur. Fiches et analytique sont lues par leur
#   contrat quand elles sont actives ; l'analytique reste facultative.
# * Aucune incompatibilité : un foyer tient aussi la Comptabilité et tire
#   profit d'un rapport sur ses catégories ou d'un listing de ses
#   contacts (D-REP-003).
# * Permissions (D4) : `reports.read` (calculer et exporter rapports et
#   listings, consulter ce qui est conservé), `reports.design` (définir,
#   copier, importer et exporter les définitions ; conserver une
#   déclaration ou un listing), `reports.admin` (effacer ce qui est
#   conservé, remplacer une définition à l'import). Le contrat du cœur
#   exige en plus ses propres droits : `accounting.report.read` (balances,
#   sommes de lignes, totaux de TVA), `cards.card.read`,
#   `analytic.report.read`, `followup.action.write` ; `MODELES` exige
#   `modeles.read` pour les documents depuis un modèle.
# * Pas de dépendance à `MODELES` : les documents depuis un modèle
#   (`partiduo-modeles`, dépendance du shard) ne sont proposés que si elle
#   est active (D-REP-021).
# * Menu (D6 d'ADR-003) : sous « Éditions » du cœur (`REPORTS`) ; partage
#   des définitions sous « Paramètres ».
# * Aucun abonnement : un rapport se calcule à la demande ; une
#   déclaration conservée est une copie figée.
Partiduo::Modules.register do
  code "REPORTS"
  name "reports.module.name"
  version Reports::VERSION
  requires_core "~> 0.1"
  depends_on "ACCOUNTING"

  permission "reports.read"
  permission "reports.design"
  permission "reports.admin"

  menu "REPORTS_ADVANCED", parent: "REPORTS", order: 40, route: "reports:reports", permission: "reports.read"
  menu "REPORTS_LISTINGS", parent: "REPORTS", order: 41, route: "reports:listings", permission: "reports.read"
  menu "REPORTS_ARCHIVE", parent: "REPORTS", order: 42, route: "reports:archive", permission: "reports.read"
  menu "REPORTS_SHARING", parent: "SETTINGS", order: 96, route: "reports:sharing", permission: "reports.design"

  ui "bulma", path: "ui/bulma"
end
