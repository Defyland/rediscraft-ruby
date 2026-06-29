require "test_helper"
require "pathname"

class DocumentationContractTest < Minitest::Test
  ROOT = Pathname(__dir__).join("..", "..").expand_path

  def read_doc(*parts)
    ROOT.join(*parts).read
  end

  def test_engineering_case_study_matches_current_repo_evidence
    doc = read_doc("docs", "engineering-case-study.md")

    assert_includes doc, "Resp2Protocol"
    assert_includes doc, "benchmarks/baseline.md"
    assert_match(/`INFO` keyspace\s+gauges/, doc)
    refute_includes doc, "Benchmarks are deferred"
    refute_includes doc, "`INFO`, counters, and structured logs are planned"
    refute_includes doc, "Add `INFO`, AOF fsync policy, compaction, snapshots, RESP parsing, and local benchmarks"
  end

  def test_product_roadmap_only_lists_remaining_work
    doc = read_doc("docs", "product", "roadmap.md")

    assert_includes doc, "Add an `INFO` request counter through a shared metrics object."
    assert_includes doc, "Expand the benchmark matrix"
    refute_includes doc, "Add `INFO` counters."
    refute_includes doc, "Add benchmarks for command throughput."
    refute_includes doc, "Add RESP parser."
  end

  def test_senior_readiness_spec_reflects_current_benchmark_and_ci_contract
    doc = read_doc("docs", "spec-driven", "senior-readiness-spec.md")

    assert_match(/local benchmark harness plus collected baseline\s+evidence/, doc)
    assert_includes doc, "GitHub Actions running `bin/check`"
    assert_includes doc, "Benchmark evidence exists"
    refute_includes doc, "Performance is planned through local benchmarks"
    refute_includes doc, "CI is planned"
  end

  def test_verification_report_describes_current_surface_without_freezing_test_counts
    doc = read_doc("docs", "spec-driven", "verification-report.md")

    assert_includes doc, "`LPUSH`, `RPUSH`, `LLEN`, `LRANGE`"
    assert_includes doc, "benchmarks/baseline.md"
    assert_includes doc, "`bin/check` output is authoritative"
    refute_includes doc, "49 runs, 116 assertions"
    refute_includes doc, "Benchmarks are documented but not collected."
  end

  def test_high_memory_runbook_uses_info_that_now_exists
    doc = read_doc("docs", "runbooks", "incident-high-memory.md")

    assert_includes doc, "Check `INFO` for `keys` and `keys_with_expiry`."
    refute_includes doc, "once `INFO` exists"
  end
end
