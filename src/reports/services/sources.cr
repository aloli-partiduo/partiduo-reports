# SPDX-License-Identifier: AGPL-3.0-or-later

module Reports
  # Montants des références d'une formule, lus par le contrat du cœur avec
  # les droits de l'acteur (D-REP-006) et gardés le temps d'un calcul :
  #
  # * comptes : `Accounting.trial_balance` (une balance par période et
  #   jeu de journaux) ; avec `with` (contrepartie) ou `card` (fiche de
  #   l'écriture), `Accounting.entries`, page par page ;
  # * fiches : `Accounting.auxiliary_balance` par nature de fiche ;
  # * analytique : `Analytic.balance`, et `Analytic.table` avec `account`.
  #
  # Une référence introuvable dans ce dossier (journal, fiche, poste) ou une
  # source refusée (droit, module inactif) vaut zéro et laisse un
  # avertissement (`issues`), sans arrêter le calcul. Interne.
  class Sources
    alias Acc = Partiduo::Api::Accounting
    alias Ana = Partiduo::Api::Analytic
    alias Formula = Reports::Formula
    alias Range = Periods::Range

    ZERO = BigDecimal.new(0)

    # Écritures lues au plus pour une référence `with` ou `card`.
    MAX_SCAN = 20_000
    PAGE     =    500

    # Montants d'un compte : débit et crédit de la période, intitulé.
    record AccountSum, label : String, debit : BigDecimal, credit : BigDecimal

    getter calendar : Periods::Calendar
    getter issues = [] of Api::IssueView

    @trial = {} of String => Hash(String, AccountSum)
    @scans = {} of String => Hash(String, AccountSum)
    @auxiliary = {} of String => Hash(String, AccountSum)
    @analytic = {} of String => Hash(Int64, AccountSum)
    @analytic_tables = {} of String => Array(Ana::TableRowView)
    @cards = {} of String => Partiduo::Api::Cards::CardView?
    @ledgers : Array(Acc::LedgerView)? = nil
    @posts : Array(Ana::PostView)? = nil
    @plans : Array(Ana::PlanView)? = nil
    @seen = Set(String).new

    def initialize(@actor : Partiduo::Api::Actor, calendar : Periods::Calendar? = nil)
      @calendar = calendar || Periods::Calendar.new
    end

    def issue(key : String, params : Hash(String, String) = {} of String => String) : Nil
      signature = "#{key}|#{params.to_a.sort!.join(',')}"
      @issues << Api::IssueView.new(key, params) if @seen.add?(signature)
    end

    # --- Comptes ---------------------------------------------------------------------

    # Montants par compte d'une référence sur une période (comptes retenus
    # seulement).
    def accounts(ref : Formula::AccountRef, range : Range, card : String? = nil) : Hash(String, AccountSum)
      return {} of String => AccountSum if range.empty?
      usable, ledger_ids = ledger_choice(ref.options)
      return {} of String => AccountSum unless usable
      sums = if ref.options.scan?
               scan(ref, range, ledger_ids, card)
             else
               trial(range, ledger_ids)
             end
      sums.select { |number, _| ref.covers?(number) }
    end

    def account(ref : Formula::AccountRef, range : Range, card : String? = nil) : BigDecimal
      Sources.amount(accounts(ref, range, card).values, ref.mode)
    end

    # Montant d'une liste de sommes par compte selon le suffixe de calcul.
    def self.amount(sums : Array(AccountSum), mode : Char?) : BigDecimal
      debit = sums.sum(ZERO, &.debit)
      credit = sums.sum(ZERO, &.credit)
      case mode
      when 'd' then debit
      when 'c' then credit
      when 's' then debit - credit
      when 'S' then credit - debit
      when 'D' then sums.sum(ZERO) { |sum| Sources.positive(sum.debit - sum.credit) }
      when 'C' then sums.sum(ZERO) { |sum| Sources.positive(sum.credit - sum.debit) }
      else          (debit - credit).abs
      end
    end

    def self.positive(value : BigDecimal) : BigDecimal
      value > ZERO ? value : ZERO
    end

    private def trial(range : Range, ledger_ids : Array(Int64)?) : Hash(String, AccountSum)
      key = "#{Records.iso(range.from)}|#{Records.iso(range.to)}|#{ledger_ids.try(&.join(','))}"
      @trial[key] ||= guarded("accounting.report.read", {} of String => AccountSum) do
        view = Acc.trial_balance(@actor, Acc::TrialBalanceQuery.new(date_from: range.from, date_to: range.to,
          ledger_ids: ledger_ids))
        view.rows.to_h { |row| {row.number, AccountSum.new(row.label, row.debit, row.credit)} }
      end
    end

    # Lignes des comptes de la référence dans les écritures de la période
    # qui portent aussi une ligne du compte `with`, ou la fiche `card`.
    private def scan(ref : Formula::AccountRef, range : Range, ledger_ids : Array(Int64)?, card : String?) : Hash(String, AccountSum)
      card_code = ref.options.card == "*" ? card : ref.options.card
      if ref.options.card && card_code.nil?
        issue("current_card")
        return {} of String => AccountSum
      end
      key = "#{ref.pattern}|#{ref.prefix?}|#{ref.options.counterpart}|#{card_code}|#{Records.iso(range.from)}|#{Records.iso(range.to)}|#{ledger_ids.try(&.join(','))}"
      @scans[key] ||= guarded("accounting.entry.read", {} of String => AccountSum) do
        sums = {} of String => AccountSum
        allowed = ledger_ids.try(&.to_set)
        offset = 0
        loop do
          query = Acc::EntryQuery.new(date_from: range.from, date_to: range.to, account: ref.pattern.presence,
            account_prefix: ref.prefix?, card: card_code, offset: offset, limit: PAGE)
          page = Acc.entries(@actor, query)
          page.each { |entry| add_entry(sums, entry, ref, allowed) }
          offset += PAGE
          break if page.size < PAGE
          if offset >= MAX_SCAN
            issue("scan_truncated", {"max" => MAX_SCAN.to_s})
            break
          end
        end
        sums
      end
    end

    # Ajoute les lignes retenues d'une écriture (journal admis, contrepartie
    # présente) aux sommes par compte.
    private def add_entry(sums : Hash(String, AccountSum), entry : Acc::EntryView, ref : Formula::AccountRef,
                          allowed : Set(Int64)?) : Nil
      return if allowed && !allowed.includes?(entry.ledger_id)
      items = entry.lines
      if counterpart = ref.options.counterpart
        return unless items.any?(&.account_number.starts_with?(counterpart))
      end
      items.each do |line|
        next unless ref.prefix? ? line.account_number.starts_with?(ref.pattern) : line.account_number == ref.pattern
        current = sums[line.account_number]? || AccountSum.new(line.account_label, ZERO, ZERO)
        sums[line.account_number] = AccountSum.new(current.label, current.debit + line.debit, current.credit + line.credit)
      end
    end

    # Journaux d'une référence : `{true, nil}` tous les journaux visibles
    # (le cœur les restreint à ceux de l'acteur), `{true, ids}` ceux
    # demandés, `{false, nil}` quand aucun des journaux demandés n'existe
    # (la référence vaut alors zéro).
    private def ledger_choice(options : Formula::Options) : {Bool, Array(Int64)?}
      return {true, nil} if options.ledgers.empty? && options.ledger_kinds.empty?
      list = ledgers
      ids = [] of Int64
      options.ledgers.each do |code|
        found = list.find { |ledger| ledger.code.upcase == code }
        found ? (ids << found.id) : issue("ledger_unknown", {"code" => code})
      end
      options.ledger_kinds.each do |kind|
        list.each { |ledger| ids << ledger.id if ledger.kind.code == kind }
      end
      ids.empty? ? {false, nil} : {true, ids.uniq}
    end

    private def ledgers : Array(Acc::LedgerView)
      @ledgers ||= guarded("accounting.ledger.read", [] of Acc::LedgerView) { Acc.ledgers(@actor) }
    end

    # --- Fiches ------------------------------------------------------------------------

    def card_view(code : String) : Partiduo::Api::Cards::CardView?
      return @cards[code] if @cards.has_key?(code)
      @cards[code] = guarded("cards.card.read", nil.as(Partiduo::Api::Cards::CardView?)) do
        Partiduo::Api::Cards.card_by_code(@actor, code)
      end
    end

    # Montant d'une fiche (balance des tiers de sa nature, restreinte aux
    # comptes `account`).
    def card(code : String, kind : String, ref : Formula::CardRef, range : Range) : BigDecimal
      return ZERO if range.empty?
      usable, ledger_ids = ledger_choice(ref.options)
      return ZERO unless usable
      key = "#{kind}|#{ref.options.account}|#{Records.iso(range.from)}|#{Records.iso(range.to)}|#{ledger_ids.try(&.join(','))}"
      rows = @auxiliary[key] ||= guarded("accounting.report.read", {} of String => AccountSum) do
        view = Acc.auxiliary_balance(@actor, Acc::AuxiliaryBalanceQuery.new(date_from: range.from, date_to: range.to,
          kind: kind, account: ref.options.account, ledger_ids: ledger_ids))
        view.rows.to_h { |row| {row.card_code, AccountSum.new(row.card_name, row.debit, row.credit)} }
      end
      sum = rows[code]? || return ZERO
      Sources.amount([sum], ref.mode)
    end

    # --- Analytique ----------------------------------------------------------------------

    def analytic(ref : Formula::AnalyticRef, range : Range) : BigDecimal
      return ZERO if range.empty?
      post = analytic_post(ref) || return ZERO
      if account = ref.options.account
        rows = analytic_table(post.plan_id, range)
        signed = rows.select(&.key.starts_with?(account)).sum(ZERO) { |row| row.amounts[post.id]? || ZERO }
        return case ref.mode
        when 'S' then signed
        when 's' then -signed
        else          signed.abs
        end
      end
      key = "#{post.plan_id}|#{Records.iso(range.from)}|#{Records.iso(range.to)}"
      rows = @analytic[key] ||= guarded("analytic.report.read", {} of Int64 => AccountSum) do
        view = Ana.balance(@actor, Ana::ReportQuery.new(plan_id: post.plan_id, date_from: range.from, date_to: range.to))
        view.rows.to_h { |row| {row.post.id, AccountSum.new(row.post.description, row.amounts.debit, row.amounts.credit)} }
      end
      sum = rows[post.id]? || return ZERO
      Sources.amount([sum], ref.mode)
    end

    private def analytic_table(plan_id : Int64, range : Range) : Array(Ana::TableRowView)
      key = "#{plan_id}|#{Records.iso(range.from)}|#{Records.iso(range.to)}"
      @analytic_tables[key] ||= guarded("analytic.report.read", [] of Ana::TableRowView) do
        Ana.table(@actor, Ana::TableQuery.new(plan_id: plan_id, axis: Ana::TableAxis::Account, date_from: range.from,
          date_to: range.to)).rows
      end
    end

    private def analytic_post(ref : Formula::AnalyticRef) : Ana::PostView?
      posts = @posts ||= guarded("analytic.plan.read", [] of Ana::PostView) { Ana.posts(@actor) }
      found = posts.select { |post| post.code.upcase == ref.code }
      if plan = ref.options.plan
        found = found.select { |post| post.plan_name.downcase == plan.downcase || post.plan_id.to_s == plan }
      end
      issue("analytic_unknown", {"code" => ref.code}) if found.empty?
      issue("analytic_ambiguous", {"code" => ref.code}) if found.size > 1
      found.first?
    end

    # --- Accès ---------------------------------------------------------------------------

    # Exécute une lecture du cœur ; un refus (droit, module inactif) donne
    # `fallback` et un avertissement.
    private def guarded(permission : String, fallback : T, & : -> T) : T forall T
      yield
    rescue error : Partiduo::Api::ModuleDisabled
      issue("module_disabled", {"code" => error.module_code})
      fallback
    rescue error : Partiduo::Api::Forbidden
      issue("forbidden", {"permission" => error.permission || permission})
      fallback
    rescue Partiduo::Api::AccessDenied
      issue("forbidden", {"permission" => permission})
      fallback
    end
  end
end
