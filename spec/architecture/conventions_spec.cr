# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"
require "../../lib/partiduo-ui-bulma/scripts/api_boundary"

private def source_files(pattern : String) : Array(String)
  Dir.glob(File.join(Reports::SpecSupport::ROOT, pattern)).reject(&.includes?("/lib/")).sort!
end

describe "Conventions de l'extension REPORTS" do
  it "ouvre chaque fichier source par l'en-tête SPDX" do
    missing = (source_files("{src,ui,spec,config,scripts}/**/*.cr") + source_files("*.cr")).reject do |path|
      File.read_lines(path).first? == "# SPDX-License-Identifier: AGPL-3.0-or-later"
    end
    missing += source_files("ui/**/*.html").reject do |path|
      File.read(path).starts_with?("{# SPDX-License-Identifier: AGPL-3.0-or-later")
    end
    missing += source_files("ui/**/*.{js,css}").reject do |path|
      File.read(path).includes?("SPDX-License-Identifier: AGPL-3.0-or-later")
    end
    missing.should be_empty
  end

  it "ne cite le logiciel d'origine que dans la documentation (*.adoc, *.md)" do
    root = Reports::SpecSupport::ROOT
    name = "noa" + "lyss"
    offenders = Dir.glob(File.join(root, "**", "*")).reject do |path|
      path.includes?("/lib/") || path.includes?("/bin/") || path.includes?("/tmp/") || path.ends_with?(".adoc") ||
        path.ends_with?(".md") || File.directory?(path)
    end.select { |path| File.read(path).downcase.includes?(name) rescue false }
    offenders.should be_empty
  end

  it "a les mêmes clés de traduction dans chaque langue de l'interface, aux mêmes interpolations" do
    %w[src/reports/locales ui/bulma/locales].flat_map do |dir|
      PartiduoUi::Translations.parity_failures(File.join(Reports::SpecSupport::ROOT, dir))
    end.should eq([] of String)
  end

  it "traduit dans chaque langue de l'interface toute clé passée à I18n.t ou {% translate %} (cœur, interface, extension)" do
    PartiduoUi::Translations.unknown_keys(Reports::SpecSupport::ROOT, %w[src/**/*.cr ui/**/*.cr ui/**/*.html]).should eq([] of String)
  end

  it "traduit toute clé citée par le code et les gabarits de l'extension" do
    cited = source_files("{src,ui}/**/*.{cr,html}").flat_map do |path|
      File.read(path).scan(/["'](reports(?:_ui)?\.[a-z_]+(?:\.[a-z_]+)+)["']/).map(&.[1])
    end.uniq! - Partiduo::Modules[Reports::CODE].permissions
    cited.size.should be > 50
    missing = Partiduo::LOCALES.flat_map do |locale|
      I18n.with_locale(locale) do
        cited.select { |key| I18n.t(key).includes?("missing") && I18n.t("#{key}.one").includes?("missing") }
          .map { |key| "#{locale}:#{key}" }
      end
    end
    missing.should be_empty
  end

  it "traduit toute clé d'erreur du contrat (reports.errors.*) dans chaque langue de l'interface" do
    cited = source_files("src/**/*.cr").flat_map do |path|
      text = File.read(path)
      text.scan(/error\([^()]*?, "([a-z_]+(?:\.[a-z_]+)+)"/).map(&.[1]) + text.scan(/issue\(\w+, "([a-z_]+(?:\.[a-z_]+)+)"/).map(&.[1])
    end.uniq!
    cited.size.should be > 20
    missing = Partiduo::LOCALES.flat_map do |locale|
      I18n.with_locale(locale) do
        cited.select { |key| I18n.t("reports.errors.#{key}").includes?("missing") }.map { |key| "#{locale}:#{key}" }
      end
    end
    missing.should be_empty
  end

  it "traduit chaque sorte, style, étendue, pas, source, champ, opérateur, format et définition fournie" do
    {
      "reports.line_kinds"     => Reports::Api::LINE_KINDS + ["account"],
      "reports.line_styles"    => Reports::Api::LINE_STYLES,
      "reports.column_kinds"   => Reports::Api::COLUMN_KINDS,
      "reports.spans"          => Reports::Api::SPANS,
      "reports.steps"          => Reports::Api::STEPS,
      "reports.sources"        => Reports::Api::SOURCES,
      "reports.card_fields"    => Reports::Api::CARD_FIELDS,
      "reports.operators"      => Reports::Api::OPERATORS,
      "reports.formats"        => Reports::Api::FORMATS,
      "reports.snapshot_kinds" => Reports::Api::SNAPSHOT_KINDS,
      "reports.starters"       => Reports::Starters::ALL.map { |item| "#{item.code.downcase}.name" },
      "reports_ui.exports"     => %w[csv ods pdf merge],
    }.each do |scope, codes|
      Partiduo::LOCALES.each do |locale|
        I18n.with_locale(locale) { codes.each { |code| I18n.t("#{scope}.#{code}").should_not contain("missing") } }
      end
    end
  end

  it "traduit chaque avertissement de calcul et chaque erreur de formule" do
    keys = Dir.glob(File.join(Reports::SpecSupport::ROOT, "src/**/*.cr")).flat_map do |path|
      text = File.read(path)
      text.scan(/issue\("([a-z_]+)"/).map { |match| "reports.issues.#{match[1]}" } +
        text.scan(/IssueView\.new\("([a-z_]+)"/).map { |match| "reports.issues.#{match[1]}" } +
        text.scan(/Error\.new\("([a-z_]+)"/).map { |match| "reports.errors.formula.#{match[1]}" }
    end.uniq!
    keys.size.should be > 30
    Partiduo::LOCALES.each do |locale|
      I18n.with_locale(locale) { keys.each { |key| I18n.t(key).should_not contain("missing") } }
    end
  end

  it "écrit ses montants en BigDecimal, jamais en flottant" do
    source_files("{src,ui}/**/*.cr").flat_map do |path|
      File.read_lines(path).each_with_index(1).compact_map do |line, number|
        "#{path}:#{number}" if ApiBoundary.strip_comment(line).matches?(/\bFloat(32|64)?\b|\.to_f\b/)
      end
    end.should be_empty
  end

  it "écrit ses feuilles de style en propriétés logiques, avec les jetons du thème (ADR-005 D7)" do
    physical = /(?:margin|padding|border)-(?:left|right|top|bottom)\b|\b(?:left|right)\s*:|text-align:\s*(?:left|right)|float:\s*(?:left|right)/
    source_files("ui/**/*.css").each do |path|
      File.read(path).scan(physical).map(&.[0]).should eq([] of String)
      File.read(path).scan(/#[0-9a-fA-F]{3,6}\b|rgba?\(/).map(&.[0]).should eq([] of String)
    end
  end

  it "ne parle au cœur, depuis ui/bulma, que par Partiduo::Api (ADR-005 D3)" do
    root = Reports::SpecSupport::ROOT
    ApiBoundary.scan([File.join(root, "ui")], base: root).map(&.to_s).should eq([] of String)
  end

  it "ne parle au métier de l'extension, depuis ui/bulma, que par Reports::Api (ADR-005 D4)" do
    allowed = %w[Api Ui CODE VERSION]
    leaks = source_files("ui/**/*.cr").flat_map do |path|
      File.read_lines(path).each_with_index(1).flat_map do |line, number|
        ApiBoundary.strip_comment(line).scan(/(?<![\w:])Reports::([A-Za-z_]\w*)/).compact_map do |match|
          "#{path.lchop(Reports::SpecSupport::ROOT + "/")}:#{number} Reports::#{match[1]}" unless allowed.includes?(match[1])
        end
      end
    end
    leaks.should be_empty
  end

  it "n'utilise que des icônes de la planche de l'interface (ADR-005 D5)" do
    lucide = File.join(Reports::SpecSupport::ROOT, "lib", "partiduo-ui-bulma", "icons", "lucide")
    known = Dir.glob(File.join(lucide, "*.svg")).map { |path| File.basename(path, ".svg") }
    known.should_not be_empty
    used = source_files("ui/bulma/templates/**/*.html").flat_map do |path|
      File.read(path).scan(/_icon\.html" with name="([a-z0-9-]+)"/).map { |match| "#{path.lchop(Reports::SpecSupport::ROOT + "/")} #{match[1]}" }
    end
    used += source_files("ui/**/*.cr").flat_map do |path|
      File.read(path).scan(/_action\("[^"]+", [^\n]*?, "(?:primary|danger|)", "([a-z0-9-]+)"\)/).map { |match| "#{path} #{match[1]}" }
    end
    used.reject { |item| known.includes?(item.split(' ').last) }.should be_empty
  end
end
