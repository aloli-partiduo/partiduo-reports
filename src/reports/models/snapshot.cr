# SPDX-License-Identifier: AGPL-3.0-or-later

module Reports
  # Résultat conservé (D-REP-009) : déclaration (rapport calculé, montants
  # éventuellement révisés) ou listing (fiches retenues). Copie figée en
  # JSON : la définition peut changer ou disparaître sans l'altérer. Interne.
  class Snapshot < Marten::Model
    field :id, :big_int, primary_key: true, auto: true
    field :kind, :string, max_size: 16
    field :definition_id, :big_int, blank: true, null: true
    field :definition_code, :string, max_size: 20
    field :definition_name, :string, max_size: 120
    field :title, :string, max_size: 255
    field :description, :text, blank: true, default: ""
    field :date_from, :date
    field :date_to, :date
    field :payload, :text
    field :created_by_id, :big_int, blank: true, null: true

    with_timestamp_fields
  end
end
