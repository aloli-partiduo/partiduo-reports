# SPDX-License-Identifier: AGPL-3.0-or-later

module Reports
  # Définition d'un listing de fiches (D-REP-011) : catégorie (par son
  # code, portable d'un dossier à l'autre) ou nature de fiches, fiches
  # désactivées comprises ou non, colonne de tri. Interne.
  class Listing < Marten::Model
    field :id, :big_int, primary_key: true, auto: true
    field :code, :string, max_size: 20
    field :name, :string, max_size: 120
    field :description, :text, blank: true, default: ""
    field :category_code, :string, max_size: 40, blank: true, default: ""
    field :card_kind, :string, max_size: 32, blank: true, default: ""
    field :include_disabled, :bool, default: false
    field :sort_code, :string, max_size: 20, blank: true, default: ""
    field :sort_desc, :bool, default: false
    field :created_by_id, :big_int, blank: true, null: true

    with_timestamp_fields
  end

  # Colonne d'un listing : champ de la fiche, attribut de sa catégorie ou
  # formule (`{*}` : la fiche de la ligne). Interne.
  class ListingColumn < Marten::Model
    field :id, :big_int, primary_key: true, auto: true
    field :listing_id, :big_int
    field :position, :int
    field :code, :string, max_size: 20
    field :label, :string, max_size: 60
    field :source, :string, max_size: 16, default: "field"
    field :field_name, :string, max_size: 40, blank: true, default: ""
    field :formula, :text, blank: true, default: ""
    field :hidden, :bool, default: false
  end

  # Condition de filtrage d'un listing : toutes s'appliquent (ET). Interne.
  class ListingCondition < Marten::Model
    field :id, :big_int, primary_key: true, auto: true
    field :listing_id, :big_int
    field :position, :int
    field :column_code, :string, max_size: 20
    field :operator, :string, max_size: 8
    field :value, :string, max_size: 255, blank: true, default: ""
  end
end
