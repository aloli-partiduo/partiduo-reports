# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

private alias F = Reports::Formula

# Contexte de calcul fixe : comptes, fiches et postes à montant connu.
private class FixedContext < Reports::Formula::Context
  getter cited = [] of String

  def account(ref : Reports::Formula::AccountRef) : BigDecimal
    @cited << "#{ref.pattern}#{ref.prefix? ? "%" : ""}#{ref.mode}"
    BigDecimal.new(ref.pattern == "70" ? 1000 : 250)
  end

  def card(ref : Reports::Formula::CardRef) : BigDecimal
    BigDecimal.new(ref.current? ? 7 : 40)
  end

  def analytic(ref : Reports::Formula::AnalyticRef) : BigDecimal
    BigDecimal.new(12)
  end

  def line(code : String) : BigDecimal
    code == "A" ? BigDecimal.new(100) : BigDecimal.new(3)
  end

  def column(code : String) : BigDecimal
    code == "N" ? BigDecimal.new(120) : BigDecimal.new(100)
  end
end

private def value(text : String) : BigDecimal
  F.parse(text).evaluate(FixedContext.new)
end

private def failure(text : String, **options) : String?
  F.check(text, **options).try(&.key)
end

describe "Langage de formule (D-REP-004)" do
  it "calcule en décimal, avec priorités, parenthèses, signes et division par zéro nulle" do
    value("[70%]*0.25+[71%]").should eq(BigDecimal.new("500"))
    value("-(1 + 2) * 3").should eq(BigDecimal.new(-9))
    value("round(1 / 3 * 3, 10)").should eq(BigDecimal.new(1))
    value("10 / 0").should eq(BigDecimal.new(0))
    value("0.1 + 0.2").should eq(BigDecimal.new("0.3"))
  end

  it "connaît les fonctions abs, round, min, max, pos, neg, pct et if" do
    value("abs(-4)").should eq(BigDecimal.new(4))
    value("round(2 / 3, 2)").should eq(BigDecimal.new("0.67"))
    value("round(2.5)").should eq(BigDecimal.new(3))
    value("min(3, 1, 2)").should eq(BigDecimal.new(1))
    value("max(3, 1, 2)").should eq(BigDecimal.new(3))
    value("pos(-5) + neg(-5)").should eq(BigDecimal.new(5))
    value("pct(@N - @N1, @N1)").should eq(BigDecimal.new(20))
    value("pct(1, 0)").should eq(BigDecimal.new(0))
    value("if([70%] > 12, 0, -12)").should eq(BigDecimal.new(0))
    value("if($A <> 100, 1, 2)").should eq(BigDecimal.new(2))
  end

  it "lit les références de comptes, de fiches, analytiques, de lignes et de colonnes" do
    context = FixedContext.new
    F.parse("[70%-s] + [6011] + {CLI1-d} + {{PROJET-S}} + $A + {*}").evaluate(context).should eq(BigDecimal.new(1409))
    context.cited.should eq(["70%s", "6011"])
    parsed = F.parse("[60%-s; ledger=ACH,ach2; except=603; span=ytd; shift=-1] + {CLI1; account=411; ledger_kind=sale}")
    ref = parsed.accounts.first
    ref.options.ledgers.should eq(["ACH", "ACH2"])
    ref.options.except.should eq(["603"])
    ref.options.span.should eq("ytd")
    ref.options.shift_months.should eq(-12)
    ref.covers?("6011").should be_true
    ref.covers?("6037").should be_false
    parsed.cards.first.options.account.should eq("411")
    parsed.cards.first.options.ledger_kinds.should eq(["sale"])
    F.parse("[70%-S; shift=-3m]").accounts.first.options.shift_months.should eq(-3)
    F.parse("[70%-S; with=411]").accounts.first.options.counterpart.should eq("411")
    F.parse("[70%-S; card=*]").current?.should be_true
    F.parse("[606%] FROM=04.2026").from.should eq(Time.utc(2026, 4, 1))
  end

  it "refuse ce qui n'est pas du langage, sans jamais rien évaluer d'autre" do
    failure("[70%] +").should eq("syntax")
    failure("system(\"ls\")").should eq("function")
    failure("`ls`").should eq("syntax")
    failure("[70%]; DROP TABLE x").should eq("syntax")
    failure("[70%' OR 1=1]").should eq("account")
    failure("{T*EL}").should eq("card")
    failure("[70%; ledger=]").should eq("option_value")
    failure("[70%; bogus=1]").should eq("option")
    failure("[70%; span=forever]").should eq("option_value")
    failure("[70%; shift=-400]").should eq("option_value")
    failure("{{P1; ledger=VEN}}").should eq("option")
    failure("{CLI; with=411}").should eq("option")
    failure("round(1, 11)").should eq("round")
    failure("if(1, 2, 3)").should eq("comparison")
    failure("abs(1, 2)").should eq("arguments")
    failure("[70%] FROM=13.2026").should eq("from")
    failure("").should eq("empty")
    failure("1" + "+1" * 1200).should eq("too_long")
    failure("(" * 60 + "1" + ")" * 60).should eq("depth")
  end

  it "dit où chaque sorte de référence est admise" do
    failure("@N - @N1").should eq("column_ref")
    failure("@N - @N1", lines: false, columns: true, references: false).should be_nil
    failure("[70%] + @N", lines: false, columns: true, references: false).should eq("reference_in_column")
    failure("$A", lines: false, columns: true, references: false).should eq("line_ref")
    failure("{*}").should eq("current_card")
    failure("[70%; card=*]").should eq("current_card")
    failure("{*-s} + [70%-S; card=*]", current: true).should be_nil
  end

  it "décale une période en années ou en mois" do
    F.shift_months("-1").should eq(-12)
    F.shift_months("+2y").should eq(24)
    F.shift_months("-3m").should eq(-3)
    F.shift_months("abc").should be_nil
  end
end
