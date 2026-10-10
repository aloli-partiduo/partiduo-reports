# SPDX-License-Identifier: AGPL-3.0-or-later

# Tables de l'extension des rapports avancés et des listings : définitions
# (rapports, colonnes, lignes ; listings, colonnes, conditions) et
# résultats conservés (déclarations, listings).
#
# Intégrité en base : codes uniques sans casse ; sortes, styles, étendues
# et opérateurs contrôlés ; retrait de 0 à 5, décimales de 0 à 2 ; code
# unique par rapport ou listing ; enfants effacés avec leur définition ; un
# résultat conservé survit à sa définition (lien remis à nul).
class Migration::Reports::V0001 < Marten::Migration
  depends_on :auth, "0001_create_auth_user_table"

  CONSTRAINTS = [
    {<<-SQL, "SELECT 1"},
      ALTER TABLE reports_report
        ADD CONSTRAINT reports_report_code_check CHECK (code ~ '^[A-Z][A-Z0-9_]*$'),
        ADD CONSTRAINT reports_report_name_check CHECK (btrim(name) <> ''),
        ADD CONSTRAINT reports_report_decimals_check CHECK (decimals BETWEEN 0 AND 2),
        ADD CONSTRAINT reports_report_created_by_fk FOREIGN KEY (created_by_id) REFERENCES auth_user (id) ON DELETE SET NULL
      SQL
    {"CREATE UNIQUE INDEX reports_report_code_unique ON reports_report (lower(code))",
     "DROP INDEX IF EXISTS reports_report_code_unique"},
    {<<-SQL, "SELECT 1"},
      ALTER TABLE reports_report_column
        ADD CONSTRAINT reports_report_column_kind_check CHECK (kind IN ('period', 'formula')),
        ADD CONSTRAINT reports_report_column_span_check CHECK (span IN ('period', 'ytd', 'year', 'opening', 'month')),
        ADD CONSTRAINT reports_report_column_shift_check CHECK (shift_months BETWEEN -240 AND 240),
        ADD CONSTRAINT reports_report_column_formula_check CHECK (kind = 'period' OR btrim(formula) <> ''),
        ADD CONSTRAINT reports_report_column_report_fk FOREIGN KEY (report_id) REFERENCES reports_report (id) ON DELETE CASCADE,
        ADD CONSTRAINT reports_report_column_code_unique UNIQUE (report_id, code)
      SQL
    {<<-SQL, "SELECT 1"},
      ALTER TABLE reports_report_line
        ADD CONSTRAINT reports_report_line_kind_check
          CHECK (kind IN ('title', 'heading1', 'heading2', 'heading3', 'text', 'note', 'formula', 'accounts', 'blank')),
        ADD CONSTRAINT reports_report_line_style_check CHECK (style IN ('normal', 'bold', 'total')),
        ADD CONSTRAINT reports_report_line_indent_check CHECK (indent BETWEEN 0 AND 5),
        ADD CONSTRAINT reports_report_line_formula_check CHECK (kind NOT IN ('formula', 'accounts') OR btrim(formula) <> ''),
        ADD CONSTRAINT reports_report_line_report_fk FOREIGN KEY (report_id) REFERENCES reports_report (id) ON DELETE CASCADE
      SQL
    {"CREATE UNIQUE INDEX reports_report_line_code_unique ON reports_report_line (report_id, code) WHERE code <> ''",
     "DROP INDEX IF EXISTS reports_report_line_code_unique"},
    {<<-SQL, "SELECT 1"},
      ALTER TABLE reports_listing
        ADD CONSTRAINT reports_listing_code_check CHECK (code ~ '^[A-Z][A-Z0-9_]*$'),
        ADD CONSTRAINT reports_listing_name_check CHECK (btrim(name) <> ''),
        ADD CONSTRAINT reports_listing_created_by_fk FOREIGN KEY (created_by_id) REFERENCES auth_user (id) ON DELETE SET NULL
      SQL
    {"CREATE UNIQUE INDEX reports_listing_code_unique ON reports_listing (lower(code))",
     "DROP INDEX IF EXISTS reports_listing_code_unique"},
    {<<-SQL, "SELECT 1"},
      ALTER TABLE reports_listing_column
        ADD CONSTRAINT reports_listing_column_source_check CHECK (source IN ('field', 'attribute', 'formula')),
        ADD CONSTRAINT reports_listing_column_listing_fk FOREIGN KEY (listing_id) REFERENCES reports_listing (id) ON DELETE CASCADE,
        ADD CONSTRAINT reports_listing_column_code_unique UNIQUE (listing_id, code)
      SQL
    {<<-SQL, "SELECT 1"},
      ALTER TABLE reports_listing_condition
        ADD CONSTRAINT reports_listing_condition_operator_check CHECK (operator IN ('eq', 'ne', 'lt', 'le', 'gt', 'ge', 'contains')),
        ADD CONSTRAINT reports_listing_condition_listing_fk FOREIGN KEY (listing_id) REFERENCES reports_listing (id) ON DELETE CASCADE
      SQL
    {<<-SQL, "SELECT 1"},
      ALTER TABLE reports_snapshot
        ADD CONSTRAINT reports_snapshot_kind_check CHECK (kind IN ('declaration', 'listing')),
        ADD CONSTRAINT reports_snapshot_dates_check CHECK (date_from <= date_to),
        ADD CONSTRAINT reports_snapshot_title_check CHECK (btrim(title) <> ''),
        ADD CONSTRAINT reports_snapshot_created_by_fk FOREIGN KEY (created_by_id) REFERENCES auth_user (id) ON DELETE SET NULL
      SQL
  ]

  def plan
    create_table :reports_report do
      column :id, :big_int, primary_key: true, auto: true
      column :code, :string, max_size: 20
      column :name, :string, max_size: 120
      column :description, :text, default: ""
      column :decimals, :int, default: 2
      column :created_by_id, :big_int, null: true
      column :created_at, :date_time
      column :updated_at, :date_time
    end

    create_table :reports_report_column do
      column :id, :big_int, primary_key: true, auto: true
      column :report_id, :big_int, index: true
      column :position, :int
      column :code, :string, max_size: 20
      column :label, :string, max_size: 60
      column :kind, :string, max_size: 16, default: "period"
      column :span, :string, max_size: 16, default: "period"
      column :shift_months, :int, default: 0
      column :formula, :text, default: ""
    end

    create_table :reports_report_line do
      column :id, :big_int, primary_key: true, auto: true
      column :report_id, :big_int, index: true
      column :position, :int
      column :code, :string, max_size: 20, default: ""
      column :label, :string, max_size: 255, default: ""
      column :kind, :string, max_size: 16, default: "formula"
      column :formula, :text, default: ""
      column :style, :string, max_size: 16, default: "normal"
      column :indent, :int, default: 0
      column :negate, :bool, default: false
      column :hidden, :bool, default: false
    end

    create_table :reports_listing do
      column :id, :big_int, primary_key: true, auto: true
      column :code, :string, max_size: 20
      column :name, :string, max_size: 120
      column :description, :text, default: ""
      column :category_code, :string, max_size: 40, default: ""
      column :card_kind, :string, max_size: 32, default: ""
      column :include_disabled, :bool, default: false
      column :sort_code, :string, max_size: 20, default: ""
      column :sort_desc, :bool, default: false
      column :created_by_id, :big_int, null: true
      column :created_at, :date_time
      column :updated_at, :date_time
    end

    create_table :reports_listing_column do
      column :id, :big_int, primary_key: true, auto: true
      column :listing_id, :big_int, index: true
      column :position, :int
      column :code, :string, max_size: 20
      column :label, :string, max_size: 60
      column :source, :string, max_size: 16, default: "field"
      column :field_name, :string, max_size: 40, default: ""
      column :formula, :text, default: ""
      column :hidden, :bool, default: false
    end

    create_table :reports_listing_condition do
      column :id, :big_int, primary_key: true, auto: true
      column :listing_id, :big_int, index: true
      column :position, :int
      column :column_code, :string, max_size: 20
      column :operator, :string, max_size: 8
      column :value, :string, max_size: 255, default: ""
    end

    create_table :reports_snapshot do
      column :id, :big_int, primary_key: true, auto: true
      column :kind, :string, max_size: 16
      column :definition_id, :big_int, null: true, index: true
      column :definition_code, :string, max_size: 20
      column :definition_name, :string, max_size: 120
      column :title, :string, max_size: 255
      column :description, :text, default: ""
      column :date_from, :date
      column :date_to, :date
      column :payload, :text
      column :created_by_id, :big_int, null: true
      column :created_at, :date_time
      column :updated_at, :date_time
    end

    CONSTRAINTS.each { |(forward, backward)| execute(forward, backward) }
  end
end
