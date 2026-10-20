# SPDX-License-Identifier: AGPL-3.0-or-later

module Reports
  module Ui
    # Base des écrans de l'extension, sur celle des écrans du référentiel de
    # l'interface (listes, formulaires des gabarits `ui/reference/*.html`) :
    # fil d'Ariane « Éditions › … », lecture des champs, période, fichiers.
    # L'accès a déjà été contrôlé par `PartiduoUi::ExtensionHandler` à partir
    # du montage ; `Reports::Api` vérifie encore la permission de chaque
    # commande.
    abstract class Handler < PartiduoUi::ReferenceHandler
      alias Api = Reports::Api
      alias Form = PartiduoUi::Form
      alias Screen = PartiduoUi::Screen

      def actor : Partiduo::Api::Actor
        current.actor
      end

      def crumbs(*items : {String, String?}) : Array(Screen::Crumb)
        list = [crumb("core.menu.reports")]
        items.each { |(label, url)| list << Screen::Crumb.new(label, url) }
        list
      end

      def can_design? : Bool
        can?(Api::DESIGN)
      end

      def can_admin? : Bool
        can?(Api::ADMIN)
      end

      def id_field(name : String) : Int64?
        field(name).to_i64?
      end

      def date_field(name : String) : Time?
        fmt.parse_date(field(name))
      end

      def date_query(name : String) : Time?
        text = query(name)
        fmt.parse_date(text) || Handler.iso_date(text)
      end

      # Période demandée (`from`, `to`) : défaut du contrat (début
      # d'exercice à la date du jour) quand elle est absente.
      def run_dates : {Time?, Time?}
        {date_query("from"), date_query("to")}
      end

      def self.iso_date(text : String) : Time?
        Time.parse_utc(text, "%Y-%m-%d")
      rescue Time::Format::Error
        nil
      end

      def messages(result) : String
        result.errors.map { |error| fmt.message(error) }.join(" ")
      end

      def file_response(file : Api::FileView) : Marten::HTTP::Response
        response = Marten::HTTP::Response.new(content: String.new(file.content), content_type: file.content_type)
        response["Content-Disposition"] = %(attachment; filename="#{file.filename}")
        response
      end

      # Fichier, ou retour à l'écran avec les erreurs.
      def file_or_back(result : Partiduo::Api::Result(Api::FileView), url : String) : Marten::HTTP::Response
        if file = result.value?
          return file_response(file)
        end
        flash["danger"] = messages(result)
        go(url)
      end

      # Redirection après une commande, avec le message du résultat.
      def after(result, success_key : String, url : String, params = {} of String => String) : Marten::HTTP::Response
        if result.success?
          flash["success"] = I18n.t(success_key, params)
        else
          flash["danger"] = messages(result)
        end
        go(url)
      end

      # Formulaire « Générer un document » (D-REP-021) : modèles actifs de
      # la sorte `kind` (le défaut de la langue choisi d'abord) ; vide quand
      # MODELES est inactive ou qu'aucun modèle n'existe, et le fragment
      # `reports/_document.html` n'affiche alors rien.
      def document_form(kind : String, hidden : Hash(String, String), per_card : Bool = false) : Hash(String, Ui::Value)
        templates = Api.document_templates(actor, kind)
        return {} of String => Ui::Value if templates.empty?
        language = I18n.locale.to_s
        chosen = templates.find { |item| item.is_default && item.locale == language } || templates.first
        options = templates.map do |item|
          Ui.row({"value" => item.id.to_s, "label" => "#{item.name} — #{item.format.upcase} · #{item.locale}",
                  "selected" => Ui.flag(item.id == chosen.id)})
        end
        {
          "document_templates" => options,
          "document_hidden"    => hidden.map { |name, value| Ui.row({"name" => name, "value" => value}) },
          "document_per_card"  => Ui.flag(per_card),
          "document_pdf"       => Ui.flag(templates.any?(&.pdf)),
        } of String => Ui::Value
      end

      # Modèle et PDF demandés par le formulaire d'un document.
      def document_choice : {Int64?, Bool}
        {query("template").to_i64?, query("pdf") == "1"}
      end

      def amount(value : BigDecimal?, decimals : Int32 = 2) : String
        value.nil? ? "" : fmt.amount(value, decimals)
      end
    end

    # `/ext/REPORTS/` : les rapports.
    class IndexHandler < Handler
      def get
        go(Ui.url("reports"))
      end
    end

    # Contrôle d'une formule saisie (HTMX, `hx-post` au changement) :
    # fragment vide si elle est valide, sinon le message d'erreur.
    class FormulaCheckHandler < Handler
      def post
        name = query("field").presence || "formula"
        text = field(name)
        kind = query("kind").presence || "line"
        return Marten::HTTP::Response.new(content: "", content_type: "text/html; charset=utf-8") if text.empty?
        result = Api.check_formula(actor, text, kind)
        message = result.success? ? "" : messages(result)
        render("reports/_formula_check.html", {"message" => message})
      end
    end
  end
end
