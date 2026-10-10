# SPDX-License-Identifier: AGPL-3.0-or-later

module Reports
  # Définition d'un rapport avancé (D-REP-005) : code unique sans casse,
  # nom, description, nombre de décimales affichées ; ses colonnes et ses
  # lignes sont remplacées en bloc à chaque enregistrement. Interne.
  class Report < Marten::Model
    field :id, :big_int, primary_key: true, auto: true
    field :code, :string, max_size: 20
    field :name, :string, max_size: 120
    field :description, :text, blank: true, default: ""
    field :decimals, :int, default: 2
    field :created_by_id, :big_int, blank: true, null: true

    with_timestamp_fields
  end

  # Colonne d'un rapport : période (décalage et étendue par rapport à la
  # période demandée) ou formule sur les autres colonnes. Interne.
  class ReportColumn < Marten::Model
    field :id, :big_int, primary_key: true, auto: true
    field :report_id, :big_int
    field :position, :int
    field :code, :string, max_size: 20
    field :label, :string, max_size: 60
    field :kind, :string, max_size: 16, default: "period"
    field :span, :string, max_size: 16, default: "period"
    field :shift_months, :int, default: 0
    field :formula, :text, blank: true, default: ""
  end

  # Ligne d'un rapport : titre, sous-titre, texte, remarque, formule, liste
  # de comptes ou ligne vide ; style, retrait, signe inversé, ligne
  # masquée (calcul intermédiaire). Interne.
  class ReportLine < Marten::Model
    field :id, :big_int, primary_key: true, auto: true
    field :report_id, :big_int
    field :position, :int
    field :code, :string, max_size: 20, blank: true, default: ""
    field :label, :string, max_size: 255, blank: true, default: ""
    field :kind, :string, max_size: 16, default: "formula"
    field :formula, :text, blank: true, default: ""
    field :style, :string, max_size: 16, default: "normal"
    field :indent, :int, default: 0
    field :negate, :bool, default: false
    field :hidden, :bool, default: false
  end
end
