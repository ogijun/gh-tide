# frozen_string_literal: true

require "minitest/autorun"
require "tide"

class TideTest < Minitest::Test
  def not_found
    GhTide::ApiError.new("HTTP 404", status: 404)
  end

  # parseArgs: サブコマンドと引数とフラグを分ける
  def test_parse_args_splits_command_target_and_flags
    assert_equal(
      { command: "pr", target: "12", repo: "o/r", stages: nil, json: true, workflows: false },
      GhTide.parse_args(["pr", "12", "-R", "o/r", "--json"])
    )
    assert_equal "dev,main", GhTide.parse_args(["path", "a/b", "--stages", "dev,main"])[:stages]
    assert_equal true, GhTide.parse_args(["commit", "abc", "--workflows"])[:workflows]
  end

  # parseArgs: サブコマンドが無ければ help
  def test_parse_args_defaults_to_help
    assert_equal "help", GhTide.parse_args([])[:command]
    assert_equal "help", GhTide.parse_args(["-h"])[:command]
  end

  # parseStages: カンマ区切りを種類つきの段に分ける
  def test_parse_stages_splits_into_typed_stages
    assert_equal(
      [
        { kind: :branch, name: "develop" },
        { kind: :branch, name: "staging" },
        { kind: :tag, pattern: "^prod-" },
        { kind: :release }
      ],
      GhTide.parse_stages("develop, staging,tag:^prod-,release")
    )
  end

  # pickLatestTag: パターンに合うタグのうち名前が最大のもの
  def test_pick_latest_tag_returns_greatest_matching_name
    tags = ["v1", "prod-20261007-201054", "stg-20261014", "prod-20261021-200232"]
    assert_equal "prod-20261021-200232", GhTide.pick_latest_tag(tags, "^prod-")
    assert_nil GhTide.pick_latest_tag(tags, "^nothing")
  end

  # isContained: compare の status で含まれるかを決める
  def test_contained_decides_by_compare_status
    assert_equal true, GhTide.contained?("identical")
    assert_equal true, GhTide.contained?("behind")
    assert_equal false, GhTide.contained?("ahead")
    assert_equal false, GhTide.contained?("diverged")
  end

  # tideForCommit: 各段について compare を呼び、含まれるかを返す
  def test_tide_for_commit_calls_compare_for_each_stage
    calls = []
    api = lambda do |path|
      calls << path
      next { "status" => "behind" } if path.include?("compare/develop...")
      next { "status" => "diverged" } if path.include?("compare/staging...")

      raise "unexpected #{path}"
    end
    rows = GhTide.tide_for_commit(api, "o/r", "abc123", [
                                    { label: "develop", ref: "develop" },
                                    { label: "staging", ref: "staging" }
                                  ])
    assert_equal(
      [
        { label: "develop", ref: "develop", present: true },
        { label: "staging", ref: "staging", present: false }
      ],
      rows
    )
    assert_equal "repos/o/r/compare/develop...abc123", calls[0]
  end

  # tideForCommit: 段の ref が解決できなければ present は null
  def test_tide_for_commit_unresolved_ref_is_nil
    rows = GhTide.tide_for_commit(->(_) { { "status" => "behind" } }, "o/r", "abc", [
                                    { label: "tag:^prod-", ref: nil }
                                  ])
    assert_nil rows[0][:present]
  end

  # tideForPath: contents が 404 なら無い
  def test_tide_for_path_404_means_missing
    err = not_found
    api = lambda do |path|
      next { "type" => "file" } if path.end_with?("ref=main")
      next { "sha" => "x" } if path.start_with?("repos/o/r/commits/")

      raise err
    end
    rows = GhTide.tide_for_path(api, "o/r", "src/a.js", [
                                  { label: "dev", ref: "dev" },
                                  { label: "main", ref: "main" }
                                ])
    assert_equal [false, true], rows.map { |r| r[:present] }
  end

  # renderTable: 段ごとに ✓ ✗ ? を並べる
  def test_render_table_marks_each_stage
    out = GhTide.render_table([
                                { label: "develop", ref: "develop", present: true },
                                { label: "tag:^prod-", ref: "prod-1", present: false },
                                { label: "release", ref: nil, present: nil }
                              ])
    assert_match(/✓\s+develop/, out)
    assert_match(/✗\s+tag:\^prod-\s+\(prod-1\)/, out)
    assert_match(/\?\s+release/, out)
  end

  # parseArgs: 値が要るフラグに値が無ければエラー
  def test_parse_args_flag_without_value_raises
    assert_raises(GhTide::Error) { GhTide.parse_args(["pr", "1", "-R"]) }
    assert_raises(GhTide::Error) { GhTide.parse_args(["pr", "1", "--stages", "--json"]) }
  end

  # encodePath: ? や # も含めて各要素をエンコードし、先頭の / を落とす
  def test_encode_path_encodes_segments_and_drops_leading_slash
    assert_equal "a%20b/c%3Fd%23e.js", GhTide.encode_path("/a b/c?d#e.js")
  end

  # encodeURIComponent と同じ非エンコード文字・UTF-8 のパーセントエンコード (追加)
  def test_encode_uri_component_matches_javascript
    assert_equal "A-Za-z0-9-_.!~*'()", GhTide.encode_uri_component("A-Za-z0-9-_.!~*'()")
    assert_equal "%2B%2F%3D%26%25%20", GhTide.encode_uri_component("+/=&% ")
    assert_equal "%E3%81%82", GhTide.encode_uri_component("あ")
  end

  # tideForCommit: 段の ref が無い（compare が 404）なら present は null で、他の段は続ける
  def test_tide_for_commit_missing_ref_is_nil_and_continues
    err = not_found
    api = lambda do |path|
      raise err if path.include?("compare/nope...")

      { "status" => "identical" }
    end
    rows = GhTide.tide_for_commit(api, "o/r", "abc", [
                                    { label: "nope", ref: "nope" },
                                    { label: "main", ref: "main" }
                                  ])
    assert_equal [nil, true], rows.map { |r| r[:present] }
  end

  # tideForPath: path is missing (404) but the stage itself does not exist either -> present is nil
  def test_tide_for_path_missing_stage_is_nil
    err = not_found
    api = lambda do |path|
      next { "sha" => "x" } if path.start_with?("repos/o/r/commits/main")

      raise err
    end
    rows = GhTide.tide_for_path(api, "o/r", "a.js", [
                                  { label: "nope", ref: "nope" },
                                  { label: "main", ref: "main" }
                                ])
    assert_equal [nil, false], rows.map { |r| r[:present] }
  end

  # describeSubject: says whether the merge commit or the head commit is checked
  def test_describe_subject_says_which_commit_is_checked
    assert_equal(
      "PR #7 open: T\nchecking head commit abcdef1 (not merged yet)",
      GhTide.describe_subject(
        { "number" => 7, "title" => "T", "state" => "open", "merged_at" => nil, "merge_commit_sha" => "m",
          "head" => { "sha" => "abcdef1234" } }
      )[:note]
    )
    merged = GhTide.describe_subject(
      { "number" => 8, "title" => "U", "state" => "closed", "merged_at" => "2026-10-29",
        "merge_commit_sha" => "1234567890", "head" => { "sha" => "h" } }
    )
    assert_equal "1234567890", merged[:sha]
    assert_equal "PR #8 merged: U\nchecking merge commit 1234567", merged[:note]
  end
end
