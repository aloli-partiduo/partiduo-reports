# SPDX-License-Identifier: AGPL-3.0-or-later

module Reports
  # Langage de formule des rapports et des listings (D-REP-004), analysé par
  # un analyseur écrit pour l'extension : *aucune évaluation de code, aucun
  # SQL fourni par l'utilisateur*. Une formule devient un arbre, calculé en
  # `BigDecimal` ; les montants viennent du contrat du cœur (balances,
  # balance des tiers, balance analytique), lus avec les droits de l'acteur.
  #
  # Syntaxe (référence complète : `doc/formules.adoc`) :
  #
  # * `[606%]` comptes dont le numéro commence par `606`, `[606]` le compte
  #   seul ; `{QCODE}` une fiche, `{*}` la fiche de la ligne d'un listing ;
  #   `{{POSTE}}` un poste analytique ;
  # * suffixe de calcul : aucun (solde en valeur absolue), `-d` débit, `-c`
  #   crédit, `-s` débit − crédit, `-S` crédit − débit, `-D` somme des soldes
  #   débiteurs, `-C` somme des soldes créditeurs ;
  # * options après `;` dans la référence : `ledger=VEN,ACH`,
  #   `ledger_kind=sale|purchase|financial|misc`, `except=6037,609`,
  #   `account=411` (fiche, poste analytique), `plan=Nom` (analytique),
  #   `span=period|ytd|year|opening|month`, `shift=-1` (années) ou `-3m`
  #   (mois) ; pour des comptes, `with=411` (écritures qui portent aussi
  #   ce compte : contrepartie) et `card=QCODE` ou `card=*` (écritures où
  #   paraît la fiche), sommés par le cœur (`Accounting.line_sums`) ;
  #   `date=operation|payment|due` (date qui situe l'écriture dans la
  #   période) et `paid=yes|no` (écritures payées ou non), aussi pour une
  #   fiche ; `vat=CODE,…` ou
  #   `vat=*` (lignes portant ces codes de TVA, `Accounting.vat_totals`) et
  #   `vat_part=base|tax|total` ;
  # * `$CODE` montant d'une autre ligne dans la même colonne, `@CODE` d'une
  #   autre colonne sur la même ligne (formules de colonnes) ;
  # * nombres (point décimal), `+ - * /`, parenthèses ; fonctions `abs`,
  #   `round(x[, n])`, `min`, `max` (deux arguments ou plus), `pos`, `neg`,
  #   `pct(a, b)`, `if(a > b, x, y)` (`> < >= <= = <>`) ; une division par
  #   zéro vaut zéro ;
  # * `FROM=MM.AAAA` en fin de formule : la période part de ce mois
  #   (compatibilité avec les rapports personnalisés du cœur).
  module Formula
    MODES = {'d', 'c', 's', 'S', 'D', 'C'}

    # Longueur et profondeur maximales : un analyseur récursif sans borne
    # ferait déborder la pile de la fibre.
    MAX_LENGTH       = 2000
    MAX_DEPTH        =   50
    MAX_ROUND_DIGITS =   10
    MAX_SHIFT_MONTHS =  240

    SPANS        = %w[period ytd year opening month]
    LEDGER_KINDS = %w[purchase sale financial misc]
    OPTION_KEYS  = %w[ledger ledger_kind except account plan span shift with card date paid vat vat_part]
    # Date qui situe une écriture dans la période (A-REP-6) et parties d'un
    # total par code de TVA (A-REP-5).
    DATE_BASES = %w[operation payment due]
    VAT_PARTS  = %w[base tax total]
    PAID       = {"yes" => true, "no" => false}

    FUNCTIONS = {"abs" => 1..1, "round" => 1..2, "min" => 2..20, "max" => 2..20, "pos" => 1..1, "neg" => 1..1,
                 "pct" => 2..2, "if" => 3..3}

    # Comparaisons admises dans le premier argument de `if`.
    COMPARISONS = %w[>= <= <> > < =]

    # Code d'une ligne ou d'une colonne : `$CODE`, `@CODE`.
    CODE = /\A[A-Z][A-Z0-9_]{0,19}\z/

    ZERO    = BigDecimal.new(0)
    HUNDRED = BigDecimal.new(100)

    # Erreur d'analyse ou de calcul : clé `reports.errors.formula.<clé>`.
    class Error < Exception
      getter key : String
      getter params : Hash(String, String)

      def initialize(@key : String, @params = {} of String => String)
        super("#{key} #{params}")
      end
    end

    # Options d'une référence. `shift_months` : décalage de la période ;
    # `span` : `nil` = celle de la colonne.
    record Options,
      ledgers : Array(String) = [] of String,
      ledger_kinds : Array(String) = [] of String,
      except : Array(String) = [] of String,
      account : String? = nil,
      plan : String? = nil,
      span : String? = nil,
      shift_months : Int32 = 0,
      counterpart : String? = nil,
      card : String? = nil,
      date_basis : String? = nil,
      paid : Bool? = nil,
      vat : Array(String)? = nil,
      vat_part : String? = nil do
      # Sommes de lignes par critère (contrepartie, fiche de l'écriture).
      def scan? : Bool
        !counterpart.nil? || !card.nil?
      end

      # Totaux par code de TVA (`vat=`).
      def vat? : Bool
        !vat.nil?
      end

      # Critères propres aux comptes (date, paiement, TVA) : refusés sur une
      # fiche ou un poste analytique.
      def account_only? : Bool
        !date_basis.nil? || !paid.nil? || vat? || !vat_part.nil?
      end
    end

    # Source des montants d'une formule (`Evaluator`).
    abstract class Context
      abstract def account(ref : AccountRef) : BigDecimal
      abstract def card(ref : CardRef) : BigDecimal
      abstract def analytic(ref : AnalyticRef) : BigDecimal
      abstract def line(code : String) : BigDecimal
      abstract def column(code : String) : BigDecimal
    end

    abstract class Node
      abstract def evaluate(context : Context) : BigDecimal
    end

    class Number < Node
      getter value : BigDecimal

      def initialize(@value : BigDecimal)
      end

      def evaluate(context : Context) : BigDecimal
        @value
      end
    end

    class Negate < Node
      getter operand : Node

      def initialize(@operand : Node)
      end

      def evaluate(context : Context) : BigDecimal
        -@operand.evaluate(context)
      end
    end

    class Binary < Node
      def initialize(@operator : Char, @left : Node, @right : Node)
      end

      def evaluate(context : Context) : BigDecimal
        left = @left.evaluate(context)
        right = @right.evaluate(context)
        case @operator
        when '+' then left + right
        when '-' then left - right
        when '*' then left * right
        else
          right.zero? ? ZERO : Formula.divide(left, right)
        end
      end
    end

    class Call < Node
      getter name : String
      getter arguments : Array(Node)

      def initialize(@name : String, @arguments : Array(Node))
      end

      def evaluate(context : Context) : BigDecimal
        values = @arguments.map(&.evaluate(context))
        case @name
        when "abs" then values[0].abs
        when "min" then values.min
        when "max" then values.max
        when "pos" then values[0] > ZERO ? values[0] : ZERO
        when "neg" then values[0] < ZERO ? -values[0] : ZERO
        when "pct" then values[1].zero? ? ZERO : Formula.divide(values[0] * HUNDRED, values[1])
        else
          digits = values[1]?.try { |value| Call.digits(value) } || 0
          values[0].round(digits, mode: :ties_away)
        end
      end

      # Nombre de décimales de `round` : entier de 0 à `MAX_ROUND_DIGITS`.
      def self.digits(value : BigDecimal) : Int32
        unless value == value.trunc && value >= 0 && value <= MAX_ROUND_DIGITS
          raise Error.new("round", {"max" => MAX_ROUND_DIGITS.to_s})
        end
        value.to_i
      end

      # Contrôle, dès l'analyse, un nombre de décimales constant.
      def check! : Nil
        return unless @name == "round"
        digits = @arguments[1]? || return
        constant = case digits
                   when Number then digits.value
                   when Negate then (operand = digits.operand).is_a?(Number) ? -operand.value : nil
                   end
        Call.digits(constant) if constant
      end
    end

    # `if(a > b, x, y)` : `x` si la comparaison est vraie, sinon `y`.
    class Condition < Node
      def initialize(@operator : String, @left : Node, @right : Node, @then : Node, @else : Node)
      end

      def evaluate(context : Context) : BigDecimal
        left = @left.evaluate(context)
        right = @right.evaluate(context)
        holds = case @operator
                when ">=" then left >= right
                when "<=" then left <= right
                when "<>" then left != right
                when ">"  then left > right
                when "<"  then left < right
                else           left == right
                end
        holds ? @then.evaluate(context) : @else.evaluate(context)
      end
    end

    # Référence à des comptes : `pattern` normalisé (chiffres et lettres
    # majuscules), `prefix` pour `%`.
    class AccountRef < Node
      getter pattern : String
      getter? prefix : Bool
      getter mode : Char?
      getter options : Options

      def initialize(@pattern : String, @prefix : Bool, @mode : Char?, @options : Options)
      end

      def evaluate(context : Context) : BigDecimal
        context.account(self)
      end

      # Le compte `number` est-il retenu (préfixe ou égalité, exclusions) ?
      def covers?(number : String) : Bool
        matched = prefix? ? number.starts_with?(pattern) : number == pattern
        matched && options.except.none? { |excluded| number.starts_with?(excluded) }
      end
    end

    # Référence à une fiche (`code` en quick code ; `*` : la fiche courante
    # d'un listing).
    class CardRef < Node
      getter code : String
      getter mode : Char?
      getter options : Options

      def initialize(@code : String, @mode : Char?, @options : Options)
      end

      def current? : Bool
        code == "*"
      end

      def evaluate(context : Context) : BigDecimal
        context.card(self)
      end
    end

    # Référence à un poste analytique.
    class AnalyticRef < Node
      getter code : String
      getter mode : Char?
      getter options : Options

      def initialize(@code : String, @mode : Char?, @options : Options)
      end

      def evaluate(context : Context) : BigDecimal
        context.analytic(self)
      end
    end

    class LineRef < Node
      getter code : String

      def initialize(@code : String)
      end

      def evaluate(context : Context) : BigDecimal
        context.line(@code)
      end
    end

    class ColumnRef < Node
      getter code : String

      def initialize(@code : String)
      end

      def evaluate(context : Context) : BigDecimal
        context.column(@code)
      end
    end

    # Formule analysée : arbre, références citées, mois de départ imposé.
    class Parsed
      getter root : Node
      getter accounts = [] of AccountRef
      getter cards = [] of CardRef
      getter analytics = [] of AnalyticRef
      getter lines = [] of String
      getter columns = [] of String
      property from : Time? = nil
      # Cite la fiche courante d'un listing (`{*}`, `card=*`).
      property? current : Bool = false

      def initialize(@root : Node)
      end

      def evaluate(context : Context) : BigDecimal
        @root.evaluate(context)
      end
    end

    # Division au plus juste : 20 décimales, arrondies à l'affichage.
    def self.divide(left : BigDecimal, right : BigDecimal) : BigDecimal
      (left / right).round(20, mode: :ties_away)
    end

    def self.parse(text : String) : Parsed
      Parser.new(text).parse
    end

    # Erreur d'une formule, `nil` si elle est valide. `lines` : `$CODE`
    # admis ; `columns` : `@CODE` admis (formule de colonne) ; `current` :
    # `{*}` admis (colonne de listing) ; `references` : comptes, fiches et
    # postes admis (une formule de colonne n'en cite pas).
    def self.check(text : String, lines : Bool = true, columns : Bool = false, current : Bool = false,
                   references : Bool = true) : Error?
      parsed = parse(text)
      if !lines && (code = parsed.lines.first?)
        return Error.new("line_ref", {"code" => code})
      end
      if !columns && (code = parsed.columns.first?)
        return Error.new("column_ref", {"code" => code})
      end
      if !current && parsed.current?
        return Error.new("current_card")
      end
      if !references && !(parsed.accounts.empty? && parsed.cards.empty? && parsed.analytics.empty?)
        return Error.new("reference_in_column")
      end
      nil
    rescue error : Error
      error
    end

    # Analyseur descendant récursif.
    class Parser
      @position = 0
      @depth = 0
      @parsed : Parsed? = nil
      @accounts = [] of AccountRef
      @cards = [] of CardRef
      @analytics = [] of AnalyticRef
      @lines = [] of String
      @columns = [] of String
      @from : Time? = nil
      @current = false

      def initialize(text : String)
        raise Error.new("too_long", {"max" => MAX_LENGTH.to_s}) if text.size > MAX_LENGTH
        @text = text.strip
        if match = @text.match(/\s*FROM\s*=\s*(\d{1,2})\.(\d{4})\s*\z/)
          month = match[1].to_i
          raise Error.new("from", {"value" => match[0].strip}) unless 1 <= month <= 12
          @from = Time.utc(match[2].to_i, month, 1)
          @text = @text[0, match.begin(0)]
        end
      end

      def parse : Parsed
        raise Error.new("empty") if @text.blank?
        root = expression
        skip_spaces
        syntax! if @position < @text.size
        parsed = Parsed.new(root)
        parsed.accounts.concat(@accounts)
        parsed.cards.concat(@cards)
        parsed.analytics.concat(@analytics)
        parsed.lines.concat(@lines.uniq)
        parsed.columns.concat(@columns.uniq)
        parsed.from = @from
        parsed.current = @current || @cards.any?(&.current?)
        parsed
      end

      private def expression : Node
        node = term
        loop do
          skip_spaces
          char = peek
          break unless char && (char == '+' || char == '-')
          @position += 1
          node = Binary.new(char, node, term)
        end
        node
      end

      private def term : Node
        node = factor
        loop do
          skip_spaces
          char = peek
          break unless char && (char == '*' || char == '/')
          @position += 1
          node = Binary.new(char, node, factor)
        end
        node
      end

      # Chaque facteur descend d'un niveau ; au-delà de `MAX_DEPTH`, la
      # formule est refusée.
      private def factor : Node
        @depth += 1
        raise Error.new("depth", {"max" => MAX_DEPTH.to_s}) if @depth > MAX_DEPTH
        begin
          factor_body
        ensure
          @depth -= 1
        end
      end

      private def factor_body : Node
        skip_spaces
        char = peek || syntax!
        case char
        when '-'
          @position += 1
          Negate.new(factor)
        when '+'
          @position += 1
          factor
        when '('
          @position += 1
          node = expression
          expect(')')
          node
        when '['
          account_ref
        when '{'
          @text[@position + 1]? == '{' ? analytic_ref : card_ref
        when '$', '@'
          code_ref(char)
        else
          atom(char)
        end
      end

      # Nombre ou appel de fonction.
      private def atom(char : Char) : Node
        return number if char.ascii_number? || char == '.'
        return call if char.ascii_letter?
        syntax!
      end

      private def number : Node
        match = @text.match(/\G\d*(?:\.\d+)?/, @position) || syntax!
        syntax! if match[0].empty? || match[0] == "."
        @position += match[0].size
        Number.new(BigDecimal.new(match[0]))
      end

      private def call : Node
        match = @text.match(/\G[a-z_]+/, @position) || syntax!
        name = match[0]
        range = FUNCTIONS[name]? || raise Error.new("function", {"name" => name})
        @position += name.size
        expect('(')
        return condition if name == "if"
        arguments = [expression]
        loop do
          skip_spaces
          break unless peek == ','
          @position += 1
          arguments << expression
        end
        expect(')')
        raise Error.new("arguments", {"name" => name}) unless range.includes?(arguments.size)
        Call.new(name, arguments).tap(&.check!)
      end

      private def condition : Node
        left = expression
        skip_spaces
        operator = COMPARISONS.find { |item| @text[@position, item.size]? == item } || raise Error.new("comparison")
        @position += operator.size
        right = expression
        expect(',')
        yes = expression
        expect(',')
        no = expression
        expect(')')
        Condition.new(operator, left, right, yes, no)
      end

      # `[606%-s; ledger=VEN]`
      private def account_ref : Node
        match = @text.match(/\G\[([^\[\]{}]*)\]/, @position) || syntax!
        @position += match[0].size
        head, options = split_options(match[1], match[0])
        parts = head.match(/\A([0-9A-Za-z]*)(%?)(?:-([cdsSDC]))?\z/) || raise Error.new("account", {"value" => match[0]})
        pattern = parts[1].upcase
        prefix = parts[2] == "%"
        raise Error.new("account", {"value" => match[0]}) if pattern.empty? && !prefix
        account_options!(options, match[0])
        ref = AccountRef.new(pattern, prefix, parts[3]?.try(&.[0]), options)
        @current = true if options.card == "*"
        @accounts << ref
        ref
      end

      # `{QCODE-s; account=411}`, `{*}`
      private def card_ref : Node
        match = @text.match(/\G\{([^{}]+)\}/, @position) || syntax!
        @position += match[0].size
        head, options = split_options(match[1], match[0])
        body, mode = mode_of(head)
        raise Error.new("option", {"value" => match[0], "name" => "plan"}) if options.plan
        raise Error.new("option", {"value" => match[0], "name" => "except"}) unless options.except.empty?
        raise Error.new("option", {"value" => match[0], "name" => "with"}) if options.scan?
        # Date de paiement ou d'échéance et « payé / non payé » admis depuis
        # le cœur 0.18.0 (D-REP-028) ; la TVA reste propre aux comptes.
        if options.vat? || options.vat_part
          raise Error.new("option", {"value" => match[0], "name" => options.vat? ? "vat" : "vat_part"})
        end
        code = body == "*" ? "*" : quick_code(body, match[0])
        ref = CardRef.new(code, mode, options)
        @cards << ref
        ref
      end

      # `{{POSTE-s; plan=Projets; account=60}}`
      private def analytic_ref : Node
        match = @text.match(/\G\{\{([^{}]+)\}\}/, @position) || syntax!
        @position += match[0].size
        head, options = split_options(match[1], match[0])
        body, mode = mode_of(head)
        code = body.upcase.gsub(/[\s'<>]/, "")
        raise Error.new("analytic", {"value" => match[0]}) if code.empty?
        if options.ledgers.present? || options.ledger_kinds.present? || options.except.present? || options.scan?
          raise Error.new("option", {"value" => match[0], "name" => "ledger"})
        end
        raise Error.new("option", {"value" => match[0], "name" => account_only(options)}) if options.account_only?
        if options.account && mode && !mode.in?('s', 'S')
          raise Error.new("analytic_mode", {"value" => match[0]})
        end
        ref = AnalyticRef.new(code, mode, options)
        @analytics << ref
        ref
      end

      # Options admises sur des comptes : ni `account`, ni `plan` ; `vat`
      # sans `with` ni `card` ; `vat_part` avec `vat`.
      private def account_options!(options : Options, raw : String) : Nil
        if options.account || options.plan
          raise Error.new("option", {"value" => raw, "name" => options.account ? "account" : "plan"})
        end
        raise Error.new("option", {"value" => raw, "name" => "vat"}) if options.vat? && options.scan?
        raise Error.new("option", {"value" => raw, "name" => "vat_part"}) if options.vat_part && !options.vat?
      end

      # Nom de la première option propre aux comptes, pour le message.
      private def account_only(options : Options) : String
        return "date" if options.date_basis
        return "paid" unless options.paid.nil?
        options.vat? ? "vat" : "vat_part"
      end

      private def code_ref(sigil : Char) : Node
        match = @text.match(/\G[$@]([A-Za-z][A-Za-z0-9_]{0,19})/, @position) || syntax!
        @position += match[0].size
        code = match[1].upcase
        if sigil == '$'
          @lines << code
          LineRef.new(code)
        else
          @columns << code
          ColumnRef.new(code)
        end
      end

      private def mode_of(head : String) : {String, Char?}
        if suffix = head.match(/-([cdsSDC])\z/)
          {head[0, head.size - 2].strip, suffix[1][0]}
        else
          {head.strip, nil}
        end
      end

      # Caractères interdits dans un quick code (`{T*EL}` n'est pas `{TEL}`).
      CARD_FORBIDDEN = /[\s$€µ£%+*\/\\!(),;&|"#'^<>=?\[\]]/

      private def quick_code(body : String, raw : String) : String
        raise Error.new("card", {"value" => raw}) if body.empty? || body.matches?(CARD_FORBIDDEN)
        body.upcase
      end

      # Sépare la tête d'une référence de ses options `; clé=valeur` (clés
      # connues, une fois chacune, valeur non vide).
      private def split_options(inside : String, raw : String) : {String, Options}
        parts = inside.split(';')
        head = parts.shift.strip
        values = {} of String => String
        parts.each do |part|
          pair = part.split('=', 2)
          key = pair[0].strip.downcase
          value = pair[1]?.try(&.strip)
          if value.nil? || !OPTION_KEYS.includes?(key) || values.has_key?(key)
            raise Error.new("option", {"value" => raw, "name" => key})
          end
          invalid!(raw, key) if value.empty?
          values[key] = value
        end
        {head, options(values, raw)}
      end

      # Options contrôlées une à une.
      private def options(values : Hash(String, String), raw : String) : Options
        kinds = list_option(values, "ledger_kind", raw, &.downcase)
        invalid!(raw, "ledger_kind") unless kinds.all? { |kind| LEDGER_KINDS.includes?(kind) }
        except = list_option(values, "except", raw, &.upcase)
        invalid!(raw, "except") unless except.all?(&.matches?(/\A[0-9A-Z]+\z/))
        span = values["span"]?.try(&.downcase)
        invalid!(raw, "span") if span && !SPANS.includes?(span)
        shift = values["shift"]?.try { |value| Formula.shift_months(value) || invalid!(raw, "shift") } || 0
        card = values["card"]?.try { |value| value == "*" ? "*" : quick_code(value, raw) }
        date = values["date"]?.try(&.downcase)
        invalid!(raw, "date") if date && !DATE_BASES.includes?(date)
        paid = values["paid"]?.try { |value| PAID.fetch(value.downcase) { invalid!(raw, "paid") } }
        part = values["vat_part"]?.try(&.downcase)
        invalid!(raw, "vat_part") if part && !VAT_PARTS.includes?(part)
        Options.new(list_option(values, "ledger", raw, &.upcase), kinds, except, account_option(values, "account", raw),
          values["plan"]?, span, shift, account_option(values, "with", raw), card, date, paid, vat_option(values, raw), part)
      end

      # Codes de TVA (`vat=NOR,RED`) ou tous (`vat=*` : liste vide).
      private def vat_option(values : Hash(String, String), raw : String) : Array(String)?
        value = values["vat"]? || return
        return [] of String if value.strip == "*"
        codes = list(value, raw, "vat", &.upcase)
        invalid!(raw, "vat") unless codes.all?(&.matches?(/\A[0-9A-Z_.\-]{1,20}\z/))
        codes
      end

      private def list_option(values : Hash(String, String), key : String, raw : String, & : String -> String) : Array(String)
        value = values[key]? || return [] of String
        list(value, raw, key) { |item| yield item }
      end

      # Numéro de compte (ou préfixe, `%` final ôté).
      private def account_option(values : Hash(String, String), key : String, raw : String) : String?
        value = values[key]?.try(&.upcase) || return
        invalid!(raw, key) unless value.matches?(/\A[0-9A-Z]+%?\z/)
        value.rchop('%')
      end

      private def invalid!(raw : String, key : String) : NoReturn
        raise Error.new("option_value", {"value" => raw, "name" => key})
      end

      private def list(value : String, raw : String, key : String, & : String -> String) : Array(String)
        items = value.split(',').map { |item| yield item.strip }
        invalid!(raw, key) if items.any?(&.empty?)
        items.uniq
      end

      private def expect(char : Char) : Nil
        skip_spaces
        syntax! unless peek == char
        @position += 1
      end

      private def peek : Char?
        @text[@position]?
      end

      private def skip_spaces : Nil
        while (char = peek) && char.whitespace?
          @position += 1
        end
      end

      private def syntax! : NoReturn
        raise Error.new("syntax", {"position" => (@position + 1).to_s})
      end
    end

    # Décalage en mois d'un texte `-1`, `-1y`, `+2y`, `-3m` (`nil` s'il est
    # invalide ou au-delà de vingt ans).
    def self.shift_months(text : String) : Int32?
      match = text.strip.match(/\A([+-]?)(\d{1,3})([ym]?)\z/i) || return
      count = match[2].to_i
      months = match[3].downcase == "m" ? count : count * 12
      months = -months if match[1] == "-"
      months.abs <= MAX_SHIFT_MONTHS ? months : nil
    end
  end
end
