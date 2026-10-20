# SPDX-License-Identifier: AGPL-3.0-or-later

module Reports
  # Contrat public de l'extension des rapports avancés et des listings, sur
  # le modèle de `Partiduo::Api` : acteur en premier argument, contrôle
  # d'accès en première ligne (extension active, permission), objets de vue
  # immuables, toute écriture par une commande qui rend un `Result` avec ses
  # erreurs par champ, dans une transaction. L'interface de l'extension
  # (`ui/bulma/`) ne voit que ce module et `Partiduo::Api`.
  #
  # Les montants sont lus par le contrat du cœur *avec l'acteur* : un
  # rapport ne montre que ce que son lecteur peut voir (journaux visibles,
  # droits des éditions, des fiches, de l'analytique) ; ce qui lui est
  # refusé est signalé (`issues`), jamais contourné.
  #
  # Référence : `doc/api/reports.adoc`.
  module Api
    alias Actor = Partiduo::Api::Actor
    alias Guard = Partiduo::Api::Guard
    alias Result = Partiduo::Api::Result
    alias FieldError = Partiduo::Api::FieldError
    alias Transaction = Partiduo::Api::Transaction

    MODULE_CODE = Reports::CODE
    READ        = "reports.read"
    DESIGN      = "reports.design"
    ADMIN       = "reports.admin"

    # --- Rapports ------------------------------------------------------------------------

    def self.reports(actor : Actor) : Array(ReportSummaryView)
      authorize!(actor, READ)
      Definitions.report_summaries
    end

    def self.report(actor : Actor, id : Int64) : ReportView
      authorize!(actor, READ)
      Definitions.report_view(Records.report!(id))
    end

    def self.check_report(actor : Actor, input : ReportInput, id : Int64? = nil) : Result(Nil)
      authorize!(actor, DESIGN)
      errors = Checks.report_errors(input, id)
      errors.empty? ? Result(Nil).success(nil) : Result(Nil).failure(errors)
    end

    def self.create_report(actor : Actor, input : ReportInput) : Result(ReportView)
      authorize!(actor, DESIGN)
      Transaction.run do
        errors = Checks.report_errors(input)
        next Result(ReportView).failure(errors) unless errors.empty?
        row = Definitions.save_report!(Report.new, input, actor)
        Result(ReportView).success(Definitions.report_view(row))
      end
    end

    # Remplace l'en-tête, les colonnes et toutes les lignes.
    def self.update_report(actor : Actor, id : Int64, input : ReportInput) : Result(ReportView)
      authorize!(actor, DESIGN)
      Transaction.run do
        row = Report.filter(id: id).lock.first || raise Partiduo::Api::NotFound.new("reports_report", id)
        errors = Checks.report_errors(input, id)
        next Result(ReportView).failure(errors) unless errors.empty?
        Definitions.save_report!(row, input, actor)
        Result(ReportView).success(Definitions.report_view(row))
      end
    end

    # Efface la définition ; ses déclarations conservées restent.
    def self.delete_report(actor : Actor, id : Int64) : Result(Nil)
      authorize!(actor, DESIGN)
      Transaction.run do
        Records.report!(id).delete
        Result(Nil).success(nil)
      end
    end

    # Copie sous un code libre (`SIG_2`) et un nom suivi de « (copie) ».
    def self.copy_report(actor : Actor, id : Int64) : Result(ReportView)
      source = report(actor, id).to_input
      code = Definitions.free_code(source.code, ->Definitions.report_code_taken?(String))
      create_report(actor, source.copy_with(code: code, name: I18n.t("reports.copy_name", name: source.name)[0, 120]))
    end

    # Contrôle d'une formule saisie (`kind` : `line`, `column`, `listing`).
    def self.check_formula(actor : Actor, text : String, kind : String = "line") : Result(Nil)
      authorize!(actor, READ)
      failure = case kind
                when "column"  then Formula.check(text, lines: false, columns: true, references: false)
                when "listing" then Formula.check(text, current: true)
                else                Formula.check(text)
                end
      return Result(Nil).success(nil) unless failure
      Result(Nil).failure(Checks.formula_error("formula", failure))
    end

    # Calcule un rapport sur une période (défaut : de début d'exercice à la
    # date du jour). Erreurs : `run.dates`, `step` invalide, montant révisé
    # d'une ligne ou d'une colonne inconnue.
    def self.run_report(actor : Actor, id : Int64, input : RunInput = RunInput.new) : Result(RunView)
      authorize!(actor, READ)
      calculate(actor, Definitions.report_view(Records.report!(id)), input)
    end

    # Calcule une définition non enregistrée (aperçu de l'éditeur) ; ses
    # erreurs de définition sont rendues comme celles d'un enregistrement.
    def self.preview_report(actor : Actor, input : ReportInput, run : RunInput = RunInput.new) : Result(RunView)
      authorize!(actor, DESIGN)
      errors = Checks.report_errors(input).reject(&.key.ends_with?("code.taken"))
      return Result(RunView).failure(errors) unless errors.empty?
      columns = input.columns.map_with_index do |column, index|
        ColumnView.new(index + 1, Checks.normalize_code(column.code), column.label.strip, column.kind, column.span,
          column.shift_months, column.formula)
      end
      lines = input.lines.map_with_index do |line, index|
        LineView.new(index + 1, Checks.normalize_code(line.code), line.label.strip, line.kind, line.formula, line.style,
          line.indent, line.negate, line.hidden)
      end
      view = ReportView.new(0_i64, Checks.normalize_code(input.code), input.name.strip, input.description, input.decimals,
        columns, lines, Records.today)
      calculate(actor, view, run)
    end

    # Fichier d'un rapport calculé : `csv`, `ods` ou `pdf` (PDF/A-2b du
    # socle).
    def self.report_file(actor : Actor, id : Int64, input : RunInput, format : String) : Result(FileView)
      run = run_report(actor, id, input)
      return Result(FileView).failure(run.errors) if run.failure?
      Sheets.file(Sheets.run_sheet(run.value!), format, actor)
    end

    # Déclaration générée depuis un modèle de `partiduo-modeles` (sorte
    # `report`, D-REP-021) pour un rapport calculé : le PDF si `pdf`, sinon
    # le fichier au format du modèle. `template_id` `nil` : le modèle par
    # défaut de la langue courante. Exige `reports.read` ici, `modeles.read`
    # chez MODELES, et MODELES active.
    def self.report_document(actor : Actor, id : Int64, input : RunInput, template_id : Int64? = nil,
                             pdf : Bool = false) : Result(FileView)
      authorize!(actor, READ)
      return Result(FileView).failure(Documents.unavailable) unless Partiduo::Modules.active?(Documents::MODELES)
      run = run_report(actor, id, input)
      return Result(FileView).failure(run.errors) if run.failure?
      view = run.value!
      title = "#{view.name} — #{Numbers.range_label(view.date_from, view.date_to)}"
      Documents.render(actor, template_id, Documents::REPORT, Documents.report_data(view, title, ""), pdf,
        "#{view.code.downcase}-#{Records.iso(view.date_to)}")
    end

    # Modèles actifs de `partiduo-modeles` pour une sorte de document
    # (`DOCUMENT_KINDS`) ; vide quand MODELES est inactive ou sans
    # `modeles.read` : la fonction n'est alors pas proposée.
    def self.document_templates(actor : Actor, kind : String) : Array(TemplateOptionView)
      authorize!(actor, READ)
      return [] of TemplateOptionView unless DOCUMENT_KINDS.includes?(kind) && Documents.available?(actor)
      templates = Modeles::Api.templates(actor, Modeles::Api::TemplateQuery.new(kind: kind, active_only: true))
      templates.map do |view|
        TemplateOptionView.new(view.id, view.name, view.format, view.locale, view.is_default,
          Modeles::Api.pdf_available?(actor, view.format))
      end
    end

    # Rapports personnalisés de la Comptabilité, à reprendre ici.
    def self.core_reports(actor : Actor) : Array(Partiduo::Api::Accounting::ReportDefinitionView)
      authorize!(actor, DESIGN)
      Partiduo::Api::Accounting.reports(actor)
    end

    # Reprend un rapport personnalisé de la Comptabilité (même syntaxe de
    # formule) : une ligne de formule par ligne d'origine.
    def self.import_core_report(actor : Actor, core_id : Int64) : Result(ReportView)
      authorize!(actor, DESIGN)
      source = Partiduo::Api::Accounting.report(actor, core_id)
      base = source.name.upcase.unicode_normalize(:nfkd).gsub(/[^A-Z0-9]/, "")[0, 16]
      base = "RAPPORT" unless base.matches?(/\A[A-Z]/)
      code = Definitions.free_code(base, ->Definitions.report_code_taken?(String))
      lines = source.lines.map do |line|
        LineInput.new(label: line.label, kind: "formula", code: "L#{line.position}", formula: line.formula)
      end
      create_report(actor, ReportInput.new(code: code, name: source.name[0, 120], lines: lines))
    end

    # --- Déclarations conservées ------------------------------------------------------------

    # Calcule et conserve une déclaration (montants révisés compris).
    def self.keep_declaration(actor : Actor, id : Int64, run : RunInput, keep : KeepInput) : Result(DeclarationView)
      authorize!(actor, DESIGN)
      report = Definitions.report_view(Records.report!(id))
      result = calculate(actor, report, run)
      return Result(DeclarationView).failure(result.errors) if result.failure?
      view = result.value!
      title = keep.title.strip.presence || "#{report.name} — #{Numbers.range_label(view.date_from, view.date_to)}"
      return Result(DeclarationView).failure(Records.error("title", "title.too_long", {"max" => "255"})) if title.size > 255
      Transaction.run do
        row = Snapshot.create!(kind: "declaration", definition_id: id, definition_code: report.code,
          definition_name: report.name, title: title, description: keep.description.strip, date_from: view.date_from,
          date_to: view.date_to, payload: Snapshots.run_json(view), created_by_id: actor.user_id)
        Result(DeclarationView).success(DeclarationView.new(Snapshots.summary(row), view))
      end
    end

    def self.snapshots(actor : Actor, query : SnapshotQuery = SnapshotQuery.new) : Array(SnapshotSummaryView)
      authorize!(actor, READ)
      rows = Snapshot.all
      query.kind.try { |kind| rows = rows.filter(kind: kind) }
      query.definition_id.try { |definition| rows = rows.filter(definition_id: definition) }
      rows.order("-created_at", "-id")[0...query.limit.clamp(1, 1000)].to_a.map { |row| Snapshots.summary(row) }
    end

    # En-tête d'un résultat conservé, déclaration ou listing.
    def self.snapshot(actor : Actor, id : Int64) : SnapshotSummaryView
      authorize!(actor, READ)
      row = Snapshot.filter(id: id).first || raise Partiduo::Api::NotFound.new("reports_snapshot", id)
      Snapshots.summary(row)
    end

    def self.declaration(actor : Actor, id : Int64) : DeclarationView
      authorize!(actor, READ)
      row = Records.snapshot!(id, "declaration")
      DeclarationView.new(Snapshots.summary(row), Snapshots.parse_run(row.payload!))
    end

    def self.declaration_file(actor : Actor, id : Int64, format : String) : Result(FileView)
      view = declaration(actor, id)
      Sheets.file(Sheets.run_sheet(view.run, view.summary.title), format, actor)
    end

    # Déclaration conservée générée depuis un modèle (sorte `report`,
    # D-REP-021) : mêmes valeurs que la copie figée, titre et description
    # compris.
    def self.declaration_document(actor : Actor, id : Int64, template_id : Int64? = nil, pdf : Bool = false) : Result(FileView)
      view = declaration(actor, id)
      return Result(FileView).failure(Documents.unavailable) unless Partiduo::Modules.active?(Documents::MODELES)
      data = Documents.report_data(view.run, view.summary.title, view.summary.description)
      Documents.render(actor, template_id, Documents::REPORT, data, pdf, Documents.slug(view.summary.title))
    end

    def self.listing_snapshot(actor : Actor, id : Int64) : ListingSnapshotView
      authorize!(actor, READ)
      row = Records.snapshot!(id, "listing")
      ListingSnapshotView.new(Snapshots.summary(row), Snapshots.parse_listing(row.payload!))
    end

    # `merge` : source de publipostage (en-tête des codes) au lieu du
    # tableau.
    def self.listing_snapshot_file(actor : Actor, id : Int64, format : String, merge : Bool = false) : Result(FileView)
      view = listing_snapshot(actor, id)
      sheet = merge ? Sheets.merge_listing(view.result) : Sheets.listing_sheet(view.result, view.summary.title)
      Sheets.file(sheet, merge ? "csv" : format, actor)
    end

    # Documents d'un listing conservé depuis un modèle (sorte `listing`,
    # D-REP-021) : avec `per_card`, un document par fiche réunis dans une
    # archive ZIP (le publipostage de la source legacy ; 500 fiches au
    # plus), sinon un document pour tout le listing (fiches en lignes,
    # totaux).
    def self.listing_document(actor : Actor, id : Int64, template_id : Int64? = nil, pdf : Bool = false,
                              per_card : Bool = true) : Result(FileView)
      view = listing_snapshot(actor, id)
      return Result(FileView).failure(Documents.unavailable) unless Partiduo::Modules.active?(Documents::MODELES)
      result = view.result
      title = view.summary.title
      unless per_card
        data = Documents.listing_data(result, title, view.summary.description, rows: true)
        return Documents.render(actor, template_id, Documents::LISTING, data, pdf, Documents.slug(title))
      end
      if result.rows.size > Documents::MAX_DOCUMENTS
        return Result(FileView).failure(Records.error("base", "documents.too_many", {"max" => Documents::MAX_DOCUMENTS.to_s}))
      end
      files = [] of FileView
      result.rows.each do |row|
        data = Documents.listing_data(result, title, view.summary.description, row)
        file = Documents.render(actor, template_id, Documents::LISTING, data, pdf, Documents.slug(row.card_code))
        return file if file.failure?
        files << file.value!
      end
      return Result(FileView).failure(Records.error("base", "keep.none")) if files.empty?
      Result(FileView).success(FileView.new("#{Documents.slug(title)}.zip", "application/zip", Documents.zip(files)))
    end

    # Envoie à chaque fiche d'un listing conservé son document en pièce
    # jointe (A-REP-2, `Partiduo::Api::Mail.deliver`, D-REP-027) : un message
    # par fiche à son adresse électronique, parti à la validation (tout ou
    # rien : un rendu refusé n'envoie rien). Les fiches sans adresse, ou
    # dont l'adresse est refusée, sont écartées et rendues. Exige
    # `reports.design`, `modeles.read`, le transport de l'instance
    # configuré et MODELES active.
    def self.mail_listing(actor : Actor, id : Int64, input : MailInput) : Result(MailView)
      authorize!(actor, DESIGN)
      view = listing_snapshot(actor, id)
      return Result(MailView).failure(Documents.unavailable) unless Partiduo::Modules.active?(Documents::MODELES)
      errors = [] of FieldError
      errors << Records.error("subject", "mail.subject_blank") if input.subject.strip.empty?
      errors << Records.error("body", "mail.body_blank") if input.body.strip.empty?
      errors << FieldError.base("core.errors.mail.not_configured") unless Partiduo::Api::Mail.configured?(actor)
      if view.result.rows.size > Documents::MAX_DOCUMENTS
        errors << Records.error("base", "documents.too_many", {"max" => Documents::MAX_DOCUMENTS.to_s})
      end
      return Result(MailView).failure(errors) unless errors.empty?
      Transaction.run do
        sent = 0
        skipped = [] of String
        failure = nil
        view.result.rows.each do |row|
          email = Partiduo::Api::Cards.card(actor, row.card_id).email.strip
          if email.empty?
            skipped << row.card_code
            next
          end
          data = Documents.listing_data(view.result, view.summary.title, view.summary.description, row, email)
          file = Documents.render(actor, input.template_id, Documents::LISTING, data, input.pdf, Documents.slug(row.card_code))
          unless document = file.value?
            failure = file.errors
            break
          end
          attachment = Partiduo::Api::Mail::AttachmentInput.new(document.filename, document.content_type, document.content)
          message = Partiduo::Api::Mail::MessageInput.new(to: [email], subject: input.subject.strip, body: input.body,
            attachments: [attachment])
          delivered = Partiduo::Api::Mail.deliver(actor, message, MODULE_CODE)
          delivered.success? ? (sent += 1) : (skipped << row.card_code)
        end
        # Un échec annule la transaction : aucun message ne part.
        if errors = failure
          next Result(MailView).failure(errors)
        end
        Result(MailView).success(MailView.new(sent, skipped))
      end
    end

    # Efface une déclaration ou un listing conservé.
    def self.delete_snapshot(actor : Actor, id : Int64) : Result(Nil)
      authorize!(actor, ADMIN)
      Transaction.run do
        row = Snapshot.filter(id: id).first || raise Partiduo::Api::NotFound.new("reports_snapshot", id)
        row.delete
        Result(Nil).success(nil)
      end
    end

    # --- Listings ------------------------------------------------------------------------

    def self.listings(actor : Actor) : Array(ListingSummaryView)
      authorize!(actor, READ)
      Definitions.listing_summaries
    end

    def self.listing(actor : Actor, id : Int64) : ListingView
      authorize!(actor, READ)
      Definitions.listing_view(Records.listing!(id))
    end

    def self.check_listing(actor : Actor, input : ListingInput, id : Int64? = nil) : Result(Nil)
      authorize!(actor, DESIGN)
      errors = Checks.listing_errors(input, id)
      errors.empty? ? Result(Nil).success(nil) : Result(Nil).failure(errors)
    end

    def self.create_listing(actor : Actor, input : ListingInput) : Result(ListingView)
      authorize!(actor, DESIGN)
      Transaction.run do
        errors = Checks.listing_errors(input)
        next Result(ListingView).failure(errors) unless errors.empty?
        row = Definitions.save_listing!(Listing.new, input, actor)
        Result(ListingView).success(Definitions.listing_view(row))
      end
    end

    def self.update_listing(actor : Actor, id : Int64, input : ListingInput) : Result(ListingView)
      authorize!(actor, DESIGN)
      Transaction.run do
        row = Listing.filter(id: id).lock.first || raise Partiduo::Api::NotFound.new("reports_listing", id)
        errors = Checks.listing_errors(input, id)
        next Result(ListingView).failure(errors) unless errors.empty?
        Definitions.save_listing!(row, input, actor)
        Result(ListingView).success(Definitions.listing_view(row))
      end
    end

    def self.delete_listing(actor : Actor, id : Int64) : Result(Nil)
      authorize!(actor, DESIGN)
      Transaction.run do
        Records.listing!(id).delete
        Result(Nil).success(nil)
      end
    end

    # Copie sous un code libre ; les conditions sont copiées aussi.
    def self.copy_listing(actor : Actor, id : Int64) : Result(ListingView)
      source = listing(actor, id).to_input
      code = Definitions.free_code(source.code, ->Definitions.listing_code_taken?(String))
      create_listing(actor, source.copy_with(code: code, name: I18n.t("reports.copy_name", name: source.name)[0, 120]))
    end

    def self.run_listing(actor : Actor, id : Int64, input : ListingRunInput = ListingRunInput.new) : Result(ListingResultView)
      authorize!(actor, READ)
      calculate_listing(actor, Definitions.listing_view(Records.listing!(id)), input)
    end

    def self.preview_listing(actor : Actor, input : ListingInput, run : ListingRunInput = ListingRunInput.new) : Result(ListingResultView)
      authorize!(actor, DESIGN)
      errors = Checks.listing_errors(input).reject(&.key.ends_with?("code.taken"))
      return Result(ListingResultView).failure(errors) unless errors.empty?
      columns = input.columns.map_with_index do |column, index|
        ListingColumnView.new(index + 1, Checks.normalize_code(column.code), column.label.strip, column.source,
          column.field_name, column.formula, column.hidden)
      end
      conditions = input.conditions.map_with_index do |condition, index|
        ConditionView.new(index + 1, Checks.normalize_code(condition.column_code), condition.operator, condition.value)
      end
      view = ListingView.new(0_i64, Checks.normalize_code(input.code), input.name.strip, input.description,
        input.category_code, input.card_kind, input.include_disabled, Checks.normalize_code(input.sort_code),
        input.sort_desc, columns, conditions, Records.today)
      calculate_listing(actor, view, run)
    end

    def self.listing_file(actor : Actor, id : Int64, input : ListingRunInput, format : String) : Result(FileView)
      result = run_listing(actor, id, input)
      return Result(FileView).failure(result.errors) if result.failure?
      Sheets.file(Sheets.listing_sheet(result.value!), format, actor)
    end

    # Source de publipostage (D-REP-012) : CSV, en-tête des codes de
    # colonnes, une ligne par fiche.
    def self.listing_merge_file(actor : Actor, id : Int64, input : ListingRunInput) : Result(FileView)
      result = run_listing(actor, id, input)
      return Result(FileView).failure(result.errors) if result.failure?
      Sheets.file(Sheets.merge_listing(result.value!), "csv", actor)
    end

    # Calcule et conserve un listing ; `keep.card_ids` : fiches retenues
    # (vide : toutes).
    def self.keep_listing(actor : Actor, id : Int64, run : ListingRunInput, keep : KeepInput) : Result(ListingSnapshotView)
      authorize!(actor, DESIGN)
      listing = Definitions.listing_view(Records.listing!(id))
      result = calculate_listing(actor, listing, run)
      return Result(ListingSnapshotView).failure(result.errors) if result.failure?
      view = result.value!
      unless keep.card_ids.empty?
        chosen = keep.card_ids.to_set
        rows = view.rows.select { |row| chosen.includes?(row.card_id) }
        return Result(ListingSnapshotView).failure(Records.error("card_ids", "keep.none")) if rows.empty?
        totals = view.columns.map_with_index do |column, index|
          column.amount ? rows.sum(BigDecimal.new(0)) { |row| row.cells[index].amount || BigDecimal.new(0) } : nil
        end
        view = view.copy_with(rows: rows, totals: totals)
      end
      title = keep.title.strip.presence || "#{listing.name} — #{Numbers.range_label(view.date_from, view.date_to)}"
      return Result(ListingSnapshotView).failure(Records.error("title", "title.too_long", {"max" => "255"})) if title.size > 255
      Transaction.run do
        row = Snapshot.create!(kind: "listing", definition_id: id, definition_code: listing.code,
          definition_name: listing.name, title: title, description: keep.description.strip, date_from: view.date_from,
          date_to: view.date_to, payload: Snapshots.listing_json(view), created_by_id: actor.user_id)
        Result(ListingSnapshotView).success(ListingSnapshotView.new(Snapshots.summary(row), view))
      end
    end

    # Inscrit au suivi une action par fiche d'un listing conservé
    # (`Partiduo::Api::Followup.create_action`, avec les droits de
    # l'acteur) ; rend le nombre d'actions créées. Tout ou rien.
    def self.add_to_followup(actor : Actor, snapshot_id : Int64, input : FollowupInput) : Result(Int32)
      authorize!(actor, DESIGN)
      view = listing_snapshot(actor, snapshot_id)
      return Result(Int32).failure(Records.error("title", "title.blank")) if input.title.strip.empty?
      Transaction.run do
        errors = [] of FieldError
        view.result.rows.each do |row|
          action = Partiduo::Api::Followup::ActionInput.new(action_type_id: input.action_type_id, date: input.date,
            title: input.title.strip, remind_on: input.remind_on, card_id: row.card_id, comment: input.comment,
            visible_profile_id: input.visible_profile_id)
          created = Partiduo::Api::Followup.create_action(actor, action)
          if created.failure?
            errors.concat(created.errors)
            break
          end
        end
        errors.empty? ? Result(Int32).success(view.result.rows.size) : Result(Int32).failure(errors)
      end
    end

    # --- Partage des définitions -------------------------------------------------------------

    # Fichier JSON des définitions choisies (format `partiduo-reports`,
    # version 1).
    def self.export_definitions(actor : Actor, report_ids : Array(Int64), listing_ids : Array(Int64)) : FileView
      authorize!(actor, DESIGN)
      reports = report_ids.uniq.map { |id| Definitions.report_view(Records.report!(id)) }
      listings = listing_ids.uniq.map { |id| Definitions.listing_view(Records.listing!(id)) }
      name = reports.size + listings.size == 1 ? (reports.first? || listings.first).code.downcase : "definitions"
      FileView.new("#{name}.partiduo-reports.json", "application/json", Sharing.dump(reports, listings).to_slice)
    end

    # Importe un fichier de définitions. Un code déjà pris est ignoré, ou
    # remplacé avec `replace` (qui exige `reports.admin`). Tout ou rien :
    # une définition invalide refuse l'import (erreurs sous
    # `reports[<i>].<champ>` ou `listings[<i>].<champ>`).
    def self.import_definitions(actor : Actor, content : String, replace : Bool = false) : Result(ImportView)
      authorize!(actor, DESIGN)
      authorize!(actor, ADMIN) if replace
      bundle = begin
        Sharing.load(content)
      rescue error : Sharing::Invalid
        return Result(ImportView).failure(Records.error("file", error.key, error.params))
      end
      import_bundle(actor, bundle, replace, [] of IssueView)
    end

    # Importe une définition de rapport exportée par la source legacy
    # (`.bin`) ; ce qui ne se convertit pas est rendu en avertissements.
    def self.import_legacy(actor : Actor, content : String) : Result(ImportView)
      authorize!(actor, DESIGN)
      converted = begin
        Legacy.load(content)
      rescue error : Sharing::Invalid
        return Result(ImportView).failure(Records.error("file", error.key, error.params))
      end
      input = converted.input
      code = Definitions.free_code(input.code, ->Definitions.report_code_taken?(String))
      import_bundle(actor, Sharing::Bundle.new([input.copy_with(code: code)], [] of ListingInput), false, converted.issues)
    end

    def self.starters(actor : Actor) : Array(StarterView)
      authorize!(actor, READ)
      Starters::ALL.map do |item|
        StarterView.new(item.code, item.kind, "reports.starters.#{item.code.downcase}.name",
          "reports.starters.#{item.code.downcase}.description", item.regime)
      end
    end

    # Installe une définition fournie ; ignorée si son code est déjà pris.
    def self.install_starter(actor : Actor, code : String) : Result(ImportView)
      authorize!(actor, DESIGN)
      starter = Starters.find(code) || raise Partiduo::Api::NotFound.new("reports_starter", code)
      import_bundle(actor, Sharing.load(starter.content), false, [] of IssueView)
    end

    # --- Interne -------------------------------------------------------------------------

    private def self.authorize!(actor : Actor, permission : String) : Nil
      Guard.authorize!(actor, permission, module_code: MODULE_CODE)
    end

    private def self.run_errors(input : RunInput, report : ReportView) : Array(FieldError)
      errors = [] of FieldError
      if (from = input.date_from) && (to = input.date_to) && from > to
        errors << Records.error("date_from", "run.dates")
      end
      errors << Records.error("step", "choice.invalid") unless STEPS.includes?(input.step)
      codes = report.lines.select(&.value?).map(&.code).reject(&.empty?)
      columns = report.columns.map(&.code)
      columns = ["N"] if columns.empty?
      input.overrides.each do |item|
        next if codes.includes?(item.line.upcase) && (input.step != "none" || columns.includes?(item.column.upcase))
        errors << Records.error("overrides", "override.unknown", {"line" => item.line, "column" => item.column})
      end
      errors
    end

    private def self.calculate(actor : Actor, report : ReportView, input : RunInput) : Result(RunView)
      errors = run_errors(input, report)
      return Result(RunView).failure(errors) unless errors.empty?
      sources = Sources.new(actor)
      base = sources.calendar.default(input.date_from, input.date_to)
      view = ReportEngine.new(actor, report, input, sources).run(base)
      view = view.copy_with(report_id: nil) if report.id.zero?
      Result(RunView).success(view)
    end

    private def self.calculate_listing(actor : Actor, listing : ListingView, input : ListingRunInput) : Result(ListingResultView)
      if (from = input.date_from) && (to = input.date_to) && from > to
        return Result(ListingResultView).failure(Records.error("date_from", "run.dates"))
      end
      sources = Sources.new(actor)
      sources.default_paid = input.paid
      range = sources.calendar.default(input.date_from, input.date_to)
      view = ListingEngine.new(actor, listing, sources).run(range)
      view = view.copy_with(listing_id: nil) if listing.id.zero?
      Result(ListingResultView).success(view)
    end

    private def self.import_bundle(actor : Actor, bundle : Sharing::Bundle, replace : Bool,
                                   issues : Array(IssueView)) : Result(ImportView)
      Transaction.run do
        created = [] of String
        replaced = [] of String
        skipped = [] of String
        errors = [] of FieldError
        bundle.reports.each_with_index do |input, index|
          code = Checks.normalize_code(input.code)
          existing = Report.filter(code__iexact: code).first
          if existing && !replace
            skipped << code
            next
          end
          found = Checks.report_errors(input, existing.try(&.id!.to_i64))
          if found.empty?
            Definitions.save_report!(existing || Report.new, input, actor)
            (existing ? replaced : created) << code
          else
            errors.concat(found.map { |error| FieldError.new("reports[#{index}].#{error.field}", error.key, error.params) })
          end
        end
        bundle.listings.each_with_index do |input, index|
          code = Checks.normalize_code(input.code)
          existing = Listing.filter(code__iexact: code).first
          if existing && !replace
            skipped << code
            next
          end
          found = Checks.listing_errors(input, existing.try(&.id!.to_i64))
          if found.empty?
            Definitions.save_listing!(existing || Listing.new, input, actor)
            (existing ? replaced : created) << code
          else
            errors.concat(found.map { |error| FieldError.new("listings[#{index}].#{error.field}", error.key, error.params) })
          end
        end
        next Result(ImportView).failure(errors) unless errors.empty?
        Result(ImportView).success(ImportView.new(created, replaced, skipped, issues))
      end
    end
  end
end
