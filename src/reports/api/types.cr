# SPDX-License-Identifier: AGPL-3.0-or-later

module Reports
  module Api
    # Sortes de lignes d'un rapport (D-REP-005) : `title` (titre principal),
    # `heading1` à `heading3` (titres), `text` (texte), `note` (remarque),
    # `formula` (montant calculé), `accounts` (liste de comptes : une ligne
    # par compte, soldes nuls omis), `blank` (ligne vide).
    LINE_KINDS   = %w[title heading1 heading2 heading3 text note formula accounts blank]
    VALUE_KINDS  = %w[formula accounts]
    LINE_STYLES  = %w[normal bold total]
    COLUMN_KINDS = %w[period formula]
    SPANS        = Formula::SPANS
    # Pas d'une génération périodique (une colonne par tranche, D-REP-008).
    STEPS = %w[none week fortnight month bimester quarter semester year]

    # Sources d'une colonne de listing, champs de fiche et opérateurs des
    # conditions (D-REP-011, D-REP-012).
    SOURCES     = %w[field attribute formula]
    CARD_FIELDS = %w[code name category kind description vat_number siren siret email phone contact_name address_line1
      address_line2 postcode city country iban bic enabled sale_price purchase_price]
    AMOUNT_FIELDS = %w[sale_price purchase_price]
    OPERATORS     = %w[eq ne lt le gt ge contains]

    # Formats d'export (D-REP-013) et sortes de résultat conservé.
    FORMATS        = %w[csv ods pdf]
    SNAPSHOT_KINDS = %w[declaration listing]

    MAX_COLUMNS         =     12
    MAX_LINES           =    500
    MAX_LISTING_COLUMNS =     30
    MAX_CONDITIONS      =     20
    MAX_CARDS           = 10_000

    # Avertissement d'un calcul ou d'un import : clé i18n
    # (`reports.issues.*`) et paramètres.
    record IssueView, key : String, params : Hash(String, String) = {} of String => String

    # --- Rapports ------------------------------------------------------------------------

    record ColumnInput,
      code : String,
      label : String,
      kind : String = "period",
      span : String = "period",
      shift_months : Int32 = 0,
      formula : String = ""

    record LineInput,
      label : String = "",
      kind : String = "formula",
      code : String = "",
      formula : String = "",
      style : String = "normal",
      indent : Int32 = 0,
      negate : Bool = false,
      hidden : Bool = false

    record ReportInput,
      code : String,
      name : String,
      description : String = "",
      decimals : Int32 = 2,
      columns : Array(ColumnInput) = [] of ColumnInput,
      lines : Array(LineInput) = [] of LineInput

    record ColumnView, position : Int32, code : String, label : String, kind : String, span : String,
      shift_months : Int32, formula : String do
      def to_input : ColumnInput
        ColumnInput.new(code: code, label: label, kind: kind, span: span, shift_months: shift_months, formula: formula)
      end
    end

    record LineView, position : Int32, code : String, label : String, kind : String, formula : String,
      style : String, indent : Int32, negate : Bool, hidden : Bool do
      def to_input : LineInput
        LineInput.new(label: label, kind: kind, code: code, formula: formula, style: style, indent: indent,
          negate: negate, hidden: hidden)
      end

      def value? : Bool
        VALUE_KINDS.includes?(kind)
      end
    end

    record ReportSummaryView, id : Int64, code : String, name : String, description : String,
      lines_count : Int32, columns_count : Int32, updated_at : Time

    record ReportView, id : Int64, code : String, name : String, description : String, decimals : Int32,
      columns : Array(ColumnView), lines : Array(LineView), updated_at : Time do
      def to_input : ReportInput
        ReportInput.new(code: code, name: name, description: description, decimals: decimals,
          columns: columns.map(&.to_input), lines: lines.map(&.to_input))
      end
    end

    # Montant révisé à la main avant de conserver une déclaration (code de
    # ligne, code de colonne).
    record Override, line : String, column : String, amount : BigDecimal

    # Calcul d'un rapport : période (défaut : exercice de la date du jour,
    # jusqu'à ce jour), pas d'une génération périodique, montants révisés.
    record RunInput,
      date_from : Time? = nil,
      date_to : Time? = nil,
      step : String = "none",
      overrides : Array(Override) = [] of Override

    # Colonne calculée : bornes de sa période (nulles pour une formule).
    record RunColumnView, code : String, label : String, kind : String, date_from : Time?, date_to : Time?

    # Ligne calculée : `values` par colonne (nul pour une ligne sans
    # montant), déjà arrondis aux décimales du rapport et au signe affiché ;
    # `account` : compte d'une ligne fille d'une liste de comptes ;
    # `revised` : codes des colonnes dont le montant a été révisé.
    record RunLineView, code : String, label : String, kind : String, style : String, indent : Int32,
      values : Array(BigDecimal?), account : String? = nil, revised : Array(String) = [] of String do
      def value? : Bool
        values.any? { |value| !value.nil? }
      end
    end

    record RunView, report_id : Int64?, code : String, name : String, date_from : Time, date_to : Time,
      step : String, decimals : Int32, columns : Array(RunColumnView), lines : Array(RunLineView),
      issues : Array(IssueView)

    # --- Listings ------------------------------------------------------------------------

    # `field_name` : champ de la fiche (`CARD_FIELDS`) ou clé d'attribut de
    # sa catégorie, selon `source`.
    record ListingColumnInput,
      code : String,
      label : String,
      source : String = "field",
      field_name : String = "",
      formula : String = "",
      hidden : Bool = false

    record ConditionInput, column_code : String, operator : String, value : String

    record ListingInput,
      code : String,
      name : String,
      description : String = "",
      category_code : String = "",
      card_kind : String = "",
      include_disabled : Bool = false,
      sort_code : String = "",
      sort_desc : Bool = false,
      columns : Array(ListingColumnInput) = [] of ListingColumnInput,
      conditions : Array(ConditionInput) = [] of ConditionInput

    record ListingColumnView, position : Int32, code : String, label : String, source : String,
      field_name : String, formula : String, hidden : Bool do
      def to_input : ListingColumnInput
        ListingColumnInput.new(code: code, label: label, source: source, field_name: field_name, formula: formula,
          hidden: hidden)
      end

      # Montant (formule, prix) plutôt que texte.
      def amount? : Bool
        source == "formula" || (source == "field" && AMOUNT_FIELDS.includes?(field_name))
      end
    end

    record ConditionView, position : Int32, column_code : String, operator : String, value : String do
      def to_input : ConditionInput
        ConditionInput.new(column_code: column_code, operator: operator, value: value)
      end
    end

    record ListingSummaryView, id : Int64, code : String, name : String, description : String,
      category_code : String, card_kind : String, columns_count : Int32, updated_at : Time

    record ListingView, id : Int64, code : String, name : String, description : String, category_code : String,
      card_kind : String, include_disabled : Bool, sort_code : String, sort_desc : Bool,
      columns : Array(ListingColumnView), conditions : Array(ConditionView), updated_at : Time do
      def to_input : ListingInput
        ListingInput.new(code: code, name: name, description: description, category_code: category_code,
          card_kind: card_kind, include_disabled: include_disabled, sort_code: sort_code, sort_desc: sort_desc,
          columns: columns.map(&.to_input), conditions: conditions.map(&.to_input))
      end
    end

    # Calcul d'un listing : période ; `paid` (A-REP-6, D-REP-024) : `true`
    # écritures payées seulement, `false` non payées, `nil` toutes, appliqué
    # aux références de comptes qui ne fixent pas le leur.
    record ListingRunInput, date_from : Time? = nil, date_to : Time? = nil, paid : Bool? = nil

    # Cellule : `amount` pour une colonne de montant, `text` sinon.
    record CellView, text : String = "", amount : BigDecimal? = nil

    record ListingRowView, card_id : Int64, card_code : String, card_name : String, cells : Array(CellView)

    record ListingResultColumnView, code : String, label : String, amount : Bool

    record ListingResultView, listing_id : Int64?, code : String, name : String, date_from : Time, date_to : Time,
      columns : Array(ListingResultColumnView), rows : Array(ListingRowView), totals : Array(BigDecimal?),
      issues : Array(IssueView), paid : Bool? = nil

    # --- Résultats conservés ---------------------------------------------------------------

    # Déclaration ou listing à conserver : titre (défaut : nom et période),
    # description ; fiches retenues d'un listing (vide : toutes).
    record KeepInput, title : String = "", description : String = "", card_ids : Array(Int64) = [] of Int64

    record SnapshotSummaryView, id : Int64, kind : String, definition_id : Int64?, definition_code : String,
      definition_name : String, title : String, description : String, date_from : Time, date_to : Time,
      created_by : String, created_at : Time

    record DeclarationView, summary : SnapshotSummaryView, run : RunView

    record ListingSnapshotView, summary : SnapshotSummaryView, result : ListingResultView

    record SnapshotQuery, kind : String? = nil, definition_id : Int64? = nil, limit : Int32 = 200

    # Inscription au suivi des fiches d'un listing conservé (une action par
    # fiche, par `Partiduo::Api::Followup.create_action`).
    record FollowupInput,
      action_type_id : Int64,
      date : Time,
      title : String,
      comment : String = "",
      remind_on : Time? = nil,
      visible_profile_id : Int64? = nil

    # --- Documents depuis un modèle (A-REP-1, D-REP-021) ---------------------------------------

    # Sortes de modèles déclarées à `partiduo-modeles` : déclaration d'un
    # rapport, document d'un listing.
    DOCUMENT_KINDS = Documents::KINDS

    # Modèle actif de `partiduo-modeles` proposé pour un document.
    record TemplateOptionView, id : Int64, name : String, format : String, locale : String, is_default : Bool,
      pdf : Bool

    # Envoi par courriel des documents d'un listing conservé (une fiche, un
    # message, son document en pièce jointe) par `Partiduo::Api::Mail`.
    record MailInput, subject : String, body : String, template_id : Int64? = nil, pdf : Bool = true

    # Bilan d'un envoi : messages remis au transport (partis à la
    # validation), fiches écartées (sans adresse ou adresse refusée, par
    # quick code).
    record MailView, sent : Int32, skipped : Array(String)

    # --- Fichiers et partage -----------------------------------------------------------------

    record FileView, filename : String, content_type : String, content : Bytes

    # Bilan d'un import : définitions créées, remplacées, ignorées (code
    # déjà pris), avertissements (lignes de la source legacy non reprises,
    # références introuvables dans ce dossier).
    record ImportView, created : Array(String), replaced : Array(String), skipped : Array(String),
      issues : Array(IssueView)

    # Définition fournie avec l'extension, à installer dans le dossier.
    record StarterView, code : String, kind : String, name_key : String, description_key : String, regime : String
  end
end
