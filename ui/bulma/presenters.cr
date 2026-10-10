# SPDX-License-Identifier: AGPL-3.0-or-later

module Reports
  module Ui
    alias Table = PartiduoUi::Table

    # Valeurs d'un contexte de gabarit composé par morceaux.
    alias Value = (String | Array(Row) | Array(String) | Array(PartiduoUi::Screen::Action) |
                   Array(PartiduoUi::Screen::Crumb) | Row)?

    # Ligne présentée à un gabarit : textes déjà mis en forme, par nom (un
    # grand `Hash` n'est pas lu par les gabarits Marten).
    class Row
      include Marten::Template::Object

      getter values : Hash(String, String?)
      getter children : Array(Row)

      def initialize(values : Hash(String, String) | Hash(String, String?), @children = [] of Row)
        @values = values.transform_values(&.as(String?))
      end

      def resolve_template_attribute(key : String)
        return (@children.empty? ? nil : @children) if key == "children"
        values[key]?
      end
    end

    def self.row(values : Hash(String, String) | Hash(String, String?), children = [] of Row) : Row
      Row.new(values, children)
    end

    # Option d'une liste de choix d'un gabarit.
    def self.choice(value : String, label : String, selected : Bool) : Row
      row({"value" => value, "label" => label, "selected" => flag(selected)})
    end

    def self.choices(codes : Array(String), scope : String, current : String) : Array(Row)
      codes.map { |code| choice(code, I18n.t("#{scope}.#{code}"), code == current) }
    end

    def self.url(name : String, **params) : String
      Marten.routes.reverse("reports:#{name}", **params)
    end

    def self.flag(value : Bool) : String?
      value ? "1" : nil
    end

    # Avertissement d'un calcul, traduit.
    def self.issue(item : Api::IssueView) : String
      I18n.t("reports.issues.#{item.key}", item.params)
    end

    # Classe CSS d'une ligne de rapport (sorte, style, retrait).
    def self.line_class(kind : String, style : String, indent : Int32) : String
      classes = ["rep-#{kind}"]
      classes << "rep-#{style}" unless style == "normal"
      classes << "rep-indent-#{indent}" if indent > 0
      classes.join(" ")
    end
  end
end
