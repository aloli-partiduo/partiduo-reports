# SPDX-License-Identifier: AGPL-3.0-or-later

# Composition de développement et de test : le cœur et l'interface (réglages
# de `partiduo-ui-bulma`, déjà appliqués à son chargement), puis les
# applications des modèles de documents (`partiduo-modeles`, dont dépend
# l'extension) et celles de l'extension. Une distribution fait de même avec toutes ses
# extensions.
Marten.configure do |config|
  config.installed_apps = config.installed_apps + Modeles::INSTALLED_APPS + Modeles::Ui::INSTALLED_APPS +
                          Reports::INSTALLED_APPS + Reports::Ui::INSTALLED_APPS
end
