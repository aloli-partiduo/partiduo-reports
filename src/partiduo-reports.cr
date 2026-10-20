# SPDX-License-Identifier: AGPL-3.0-or-later

# Point d'entrée du shard `partiduo-reports` : le métier de l'extension des
# rapports avancés et des listings (manifeste, modèles, langage de formule,
# calcul, exports, partage des définitions, contrat `Reports::Api`), sans
# interface. L'interface Bulma est dans `ui/bulma/`, requise à part par la
# distribution : `require "partiduo-reports/ui/bulma"`.
#
# La distribution ajoute ensuite `Reports::INSTALLED_APPS` à ses
# applications Marten, et `require "partiduo-reports/cli"` à sa ligne de
# commande (migrations).
require "partiduo"
# Modèles de documents (A-REP-1) : contrat `Modeles::Api`.
require "partiduo-modeles"

require "./reports/app"
