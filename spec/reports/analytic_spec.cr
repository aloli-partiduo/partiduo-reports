# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

private alias S = Reports::SpecSupport
private alias Api = Reports::Api
private alias Ana = Partiduo::Api::Analytic

describe "Rapports avancés : références analytiques (D-REP-006)" do
  it "lit un poste analytique, restreint ou non à des comptes, et signale ce qui manque" do
    S.setup
    report = S.report(Api::ReportInput.new(code: "ANA", name: "Analytique", lines: [
      S.line("A", "{{ALPHA-s}}"), S.line("B", "{{ALPHA-s; account=627}}"), S.line("C", "{{ALPHA-S; account=641}}"),
      S.line("D", "{{BETA}}"), S.line("E", "{{alpha-s; plan=Projets}}"),
    ]))
    entry = S.entry("2026-04-01", [{"627", "D", "300", nil}, {"641", "D", "100", nil}, {"510001", "C", "400", nil}])
    before = S.run(report.id)
    S.amount(before, "A").should eq(S.d("0"))
    before.issues.map(&.key).uniq!.should eq(["analytic_unknown"])

    Partiduo::Api::Modules.activate(S.system, "ANALYTIC") unless Partiduo::Modules.active?("ANALYTIC")
    plan = Ana.create_plan(S.system, Ana::PlanInput.new(name: "Projets")).value!
    post = Ana.create_post(S.system, Ana::PostInput.new(plan_id: plan.id, code: "ALPHA")).value!
    line = entry.lines.find!(&.account_number.==("627"))
    Ana.distribute_entry(S.system, entry.id, [Ana::LineDistributionInput.new(line.id,
      [Ana::DistributionRowInput.new(S.d("300"), [post.id])])]).success?.should be_true

    run = S.run(report.id)
    S.amount(run, "A").should eq(S.d("300"))
    S.amount(run, "B").should eq(S.d("300"))
    S.amount(run, "C").should eq(S.d("0"))
    S.amount(run, "D").should eq(S.d("0"))
    S.amount(run, "E").should eq(S.d("300"))
    run.issues.map(&.key).should eq(["analytic_unknown"])
  end
end
