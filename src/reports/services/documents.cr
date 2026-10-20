# SPDX-License-Identifier: AGPL-3.0-or-later

module Reports
  # Documents générés depuis un modèle de `partiduo-modeles` (A-REP-1,
  # D-REP-021) : la déclaration d'un rapport et les documents d'un listing
  # (un par fiche, ou un pour tout le listing), remplis par
  # `Modeles::Api.render_data` avec le vocabulaire déclaré ici. Ils
  # remplacent le CSV des balises et la source de publipostage pour un
  # traitement de texte (D-REP-010, D-REP-012). Interne.
  module Documents
    alias Render = Modeles::Api::RenderView

    # Sortes de modèles déclarées par l'extension.
    REPORT  = "report"
    LISTING = "listing"
    KINDS   = [REPORT, LISTING]

    MODELES = "MODELES"
    # Documents d'un listing rendus par une demande (archive ZIP ou envoi).
    MAX_DOCUMENTS = 500

    # Nom d'un champ libre du vocabulaire (celui de `partiduo-modeles`) :
    # codes de lignes et de colonnes, balises `CODE_COL`.
    FIELD = /\A[A-Za-z][A-Za-z0-9_]{0,39}\z/

    # Préfixe des libellés du vocabulaire (`<préfixe>.groups.<groupe>`,
    # `<préfixe>.<groupe>.<champ>`), lus par l'écran de MODELES.
    LABELS = %w[reports modeles vocabulary].join('.')

    DOSSIER = %w[nom tva siren rue numero code_postal ville pays telephone]

    # Rapport : `{{ declaration.titre }}`, `{{ montants.CA }}` (première
    # colonne), `{{ montants.CA_N1 }}` (colonne `N1`, comme les balises
    # `<<CODE_COL>>` de la source legacy), lignes affichées
    # (`{% for ligne in lignes %}{{ ligne.libelle }} {{ ligne.N }}`).
    Modeles::Api.register_vocabulary(REPORT, Modeles::Api::VocabularyInput.new(
      module_code: Reports::CODE, label_key: "reports.modeles.kinds.report", labels: LABELS,
      objects: {
        "declaration" => %w[titre note rapport code periode debut fin date jours mois annees],
        "dossier"     => DOSSIER,
        "montants"    => [] of String,
      },
      open: %w[montants lignes], list: "lignes", item: "ligne",
      list_fields: %w[code libelle sorte style retrait compte montant],
      sample_values: {"declaration.titre" => "Soldes intermédiaires de gestion — exemple",
                      "declaration.periode" => "01/01/2026 – 31/12/2026", "dossier.nom" => "Atelier Exemple SARL",
                      "montants.CA" => "125 000,00", "montants.CA_N1" => "118 400,00"},
      sample_rows: [{"code" => "CA", "libelle" => "Chiffre d'affaires", "sorte" => "formula", "style" => "bold",
                     "retrait" => "0", "compte" => "", "montant" => "125 000,00", "N" => "125 000,00", "N1" => "118 400,00"}]))

    # Listing : la fiche du document (`{{ fiche.nom }}`, `{{ colonnes.CA }}`)
    # pour un document par fiche, ou toutes les fiches
    # (`{% for ligne in fiches %}{{ ligne.nom }} {{ ligne.CA }}`) et les
    # totaux (`{{ totaux.CA }}`) pour un document du listing entier.
    Modeles::Api.register_vocabulary(LISTING, Modeles::Api::VocabularyInput.new(
      module_code: Reports::CODE, label_key: "reports.modeles.kinds.listing", labels: LABELS,
      objects: {
        "listing"  => %w[titre note nom code periode debut fin date],
        "dossier"  => DOSSIER,
        "fiche"    => %w[code nom courriel],
        "colonnes" => [] of String,
        "totaux"   => [] of String,
      },
      open: %w[colonnes totaux fiches], list: "fiches", item: "ligne", list_fields: %w[code nom],
      sample_values: {"listing.titre" => "Clients — exemple", "fiche.code" => "CLI001", "fiche.nom" => "Client Modèle & Fils",
                      "colonnes.CA" => "12 500,00", "totaux.CA" => "12 500,00"},
      sample_rows: [{"code" => "CLI001", "nom" => "Client Modèle & Fils", "CA" => "12 500,00"}]))

    # Les documents sont-ils proposés ? Extension MODELES active et droit de
    # lire ses modèles.
    def self.available?(actor : Partiduo::Api::Actor) : Bool
      Partiduo::Modules.active?(MODELES) && actor.can?(Modeles::Api::READ)
    end

    # Refus quand MODELES est inactive (la fonction n'est alors pas
    # proposée).
    def self.unavailable : Array(Partiduo::Api::FieldError)
      [Records.error("base", "documents.unavailable")]
    end

    # --- Données ---------------------------------------------------------------------

    # Valeurs et lignes d'une déclaration calculée ou conservée.
    def self.report_data(run : Api::RunView, title : String, description : String) : {Hash(String, String), Array(Hash(String, String))}
      values = dossier
      tags = Tags.special(run, title, description).to_h
      {"titre" => "TITRE", "note" => "NOTE", "periode" => "PERIODE_DECLARATION", "debut" => "START_DATE",
       "fin" => "END_DATE", "date" => "TODAY", "jours" => "INTERVAL_DAY", "mois" => "INTERVAL_MONTH",
       "annees" => "INTERVAL_YEAR"}.each { |field, tag| values["declaration.#{field}"] = tags[tag]? || "" }
      values["declaration.rapport"] = run.name
      values["declaration.code"] = run.code
      rows = run.lines.map do |line|
        row = {"code" => line.code, "libelle" => line.account ? "#{line.account} #{line.label}" : line.label,
               "sorte" => line.kind, "style" => line.style, "retrait" => line.indent.to_s, "compte" => line.account || "",
               "montant" => text(line.values.first?, run.decimals)}
        run.columns.each_with_index { |column, index| row[column.code] = text(line.values[index]?, run.decimals) }
        if !line.code.empty? && line.value?
          line.values.each_with_index do |value, index|
            tag = index.zero? ? line.code : "#{line.code}_#{run.columns[index].code}"
            values["montants.#{tag}"] = text(value, run.decimals) if FIELD.matches?(tag)
          end
        end
        row
      end
      {values, rows}
    end

    # Valeurs d'un listing : en-tête, totaux ; fiche et colonnes de `row`
    # (document d'une fiche) ; toutes les fiches en lignes (`rows`).
    def self.listing_data(result : Api::ListingResultView, title : String, description : String,
                          row : Api::ListingRowView? = nil, email : String = "",
                          rows : Bool = false) : {Hash(String, String), Array(Hash(String, String))}
      values = dossier
      values["listing.titre"] = title
      values["listing.note"] = description
      values["listing.nom"] = result.name
      values["listing.code"] = result.code
      values["listing.periode"] = Numbers.range_label(result.date_from, result.date_to)
      values["listing.debut"] = Numbers.date(result.date_from)
      values["listing.fin"] = Numbers.date(result.date_to)
      values["listing.date"] = Numbers.date(Records.today)
      result.columns.each_with_index do |column, index|
        next unless FIELD.matches?(column.code)
        values["totaux.#{column.code}"] = text(result.totals[index]?, 2) if column.amount
      end
      if row
        values["fiche.code"] = row.card_code
        values["fiche.nom"] = row.card_name
        values["fiche.courriel"] = email
        cells(result, row).each { |code, value| values["colonnes.#{code}"] = value }
      end
      list = rows ? result.rows.map { |item| {"code" => item.card_code, "nom" => item.card_name}.merge(cells(result, item)) } : [] of Hash(String, String)
      {values, list}
    end

    private def self.cells(result : Api::ListingResultView, row : Api::ListingRowView) : Hash(String, String)
      cells = {} of String => String
      result.columns.each_with_index do |column, index|
        next unless FIELD.matches?(column.code)
        cell = row.cells[index]? || next
        cells[column.code] = (amount = cell.amount) ? Numbers.amount(amount, 2) : cell.text
      end
      cells
    end

    # Coordonnées du dossier (réglages du socle).
    private def self.dossier : Hash(String, String)
      settings = begin
        Partiduo::Api::Core.settings(Records.system)
      rescue Partiduo::Api::NotFound
        nil
      end
      {
        "dossier.nom"         => settings.try(&.company_name) || "",
        "dossier.tva"         => settings.try(&.vat_number) || "",
        "dossier.siren"       => settings.try(&.siren) || "",
        "dossier.rue"         => settings.try(&.street) || "",
        "dossier.numero"      => settings.try(&.street_number) || "",
        "dossier.code_postal" => settings.try(&.postcode) || "",
        "dossier.ville"       => settings.try(&.city) || "",
        "dossier.pays"        => settings.try(&.country_code) || "",
        "dossier.telephone"   => settings.try(&.phone) || "",
      }
    end

    private def self.text(value : BigDecimal?, decimals : Int32) : String
      value.nil? ? "" : Numbers.amount(value, decimals)
    end

    # --- Rendu -----------------------------------------------------------------------

    # Fichier rendu : le PDF s'il est demandé (refus avec la clé de l'échec
    # de la conversion, `modeles.errors.pdf.*`, s'il n'a pas été produit),
    # sinon le fichier au format du modèle.
    def self.render(actor : Partiduo::Api::Actor, template_id : Int64?, kind : String, data : {Hash(String, String), Array(Hash(String, String))},
                    pdf : Bool, name : String) : Partiduo::Api::Result(Api::FileView)
      result = Modeles::Api.render_data(actor, template_id, kind, data[0], data[1], pdf: pdf, name: name)
      rendered = result.value? || return Partiduo::Api::Result(Api::FileView).failure(result.errors)
      file(rendered, pdf)
    end

    def self.file(rendered : Render, pdf : Bool) : Partiduo::Api::Result(Api::FileView)
      chosen = pdf ? rendered.pdf : rendered.file
      unless chosen
        field = "pdf"
        error = Partiduo::Api::FieldError.new(field, rendered.pdf_error || "modeles.errors.pdf.unavailable",
          {"detail" => rendered.pdf_detail})
        return Partiduo::Api::Result(Api::FileView).failure([error])
      end
      Partiduo::Api::Result(Api::FileView).success(Api::FileView.new(chosen.filename, chosen.content_type, chosen.content))
    end

    # Nom de fichier sûr et lisible : lettres, chiffres, tirets.
    def self.slug(text : String) : String
      text.unicode_normalize(:nfkd).gsub(/[^\x00-\x7F]/, "").downcase.gsub(/[^a-z0-9]+/, "-").strip('-').presence || "document"
    end

    # Archive ZIP de fichiers (noms rendus uniques).
    def self.zip(files : Array(Api::FileView)) : Bytes
      io = IO::Memory.new
      names = Set(String).new
      Compress::Zip::Writer.open(io) do |zip|
        files.each do |file|
          name = file.filename
          number = 2
          while names.includes?(name)
            name = file.filename.sub(/(\.[a-z]+)?\z/) { |ext| "-#{number}#{ext}" }
            number += 1
          end
          names << name
          zip.add(name, file.content)
        end
      end
      io.to_slice
    end
  end
end
