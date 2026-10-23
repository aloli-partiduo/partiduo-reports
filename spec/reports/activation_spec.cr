# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

private alias S = Reports::SpecSupport
private alias Api = Reports::Api

private def menu_routes(entries : Array(Partiduo::Api::Modules::MenuView)) : Array(String?)
  entries.flat_map { |entry| [entry.route] + menu_routes(entry.children) }
end

describe "Extension REPORTS : manifeste et activation (ADR-003 D2)" do
  it "déclare une extension conforme au contrat du cœur, qui dépend de la Comptabilité, sans abonnement" do
    manifest = Partiduo::Modules[Reports::CODE]
    manifest.kind.should eq(Partiduo::Modules::Kind::Extension)
    manifest.version.should eq(Reports::VERSION)
    Reports::VERSION.should match(/\A\d+\.\d+\.\d+\z/)
    manifest.requires_core.should eq("~> 0.1")
    manifest.permissions.should eq(["reports.read", "reports.design", "reports.admin"])
    manifest.depends_on.should eq(["ACCOUNTING"])
    manifest.incompatible_with.should be_empty
    manifest.subscribed_events.should be_empty
    manifest.uis.map(&.path).should eq(["ui/bulma"])
    manifest.menus.map { |menu| {menu.code, menu.parent, menu.route} }.should eq([
      {"REPORTS_ADVANCED", "REPORTS", "reports:reports"},
      {"REPORTS_LISTINGS", "REPORTS", "reports:listings"},
      {"REPORTS_ARCHIVE", "REPORTS", "reports:archive"},
      {"REPORTS_SHARING", "SETTINGS", "reports:sharing"},
    ])
    Partiduo::Modules.structure_errors.should be_empty
    Partiduo::Modules.dependency_errors(manifest, Set{Reports::CODE, "ACCOUNTING"}).should be_empty
    Partiduo::Modules.dependency_errors(manifest, Set{Reports::CODE}).should eq(["REPORTS requiert ACCOUNTING, inactif"])
  end

  it "traduit son nom, ses permissions et ses menus dans chaque langue de l'interface" do
    manifest = Partiduo::Modules[Reports::CODE]
    keys = [manifest.name] + manifest.permission_entries.map(&.label) + manifest.menus.map(&.label)
    Partiduo::LOCALES.each do |locale|
      I18n.with_locale(locale) { keys.each { |key| I18n.t(key).should_not contain("missing") } }
    end
    I18n.with_locale("fr") { I18n.t("reports.menu.reports_advanced").should eq("Rapports avancés") }
  end

  it "est inactive tant que l'instance ne l'active pas, puis se montre sous « Éditions »" do
    PartiduoUi::Reference.provision
    S.user("alice@example.com", "Alice")
    S.user("bruno@example.com", "Bruno")
    S.user("carla@example.com", "Carla")
    expect_raises(Partiduo::Api::ModuleDisabled) { Api.reports(S.designer) }
    menu_routes(Partiduo::Api::Modules.menu(S.designer)).should_not contain("reports:reports")
    S.activate
    Partiduo::Modules.check!
    routes = menu_routes(Partiduo::Api::Modules.menu(S.designer))
    routes.should contain("reports:reports")
    routes.should contain("reports:sharing")
    menu_routes(Partiduo::Api::Modules.menu(S.reader)).should_not contain("reports:sharing")
    expect_raises(Partiduo::Api::Forbidden) { Api.reports(S.actor("carla@example.com", ["accounting.report.read"])) }
  end
end
