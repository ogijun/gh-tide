# frozen_string_literal: true

require "minitest/autorun"
require "stringio"
require "tide"

class StuckTest < Minitest::Test
  NOW = Time.utc(2026, 1, 20, 12, 0, 0)
  HEAD = "h" * 40
  OLD = "a" * 40

  def check(name, conclusion, status: "COMPLETED", required: false, workflow: nil, run: nil, number: nil, event: "pull_request", at: "2026-01-19T10:00:00Z")
    suite = workflow && { "workflowRun" => { "databaseId" => run, "runNumber" => number || run, "event" => event, "workflow" => { "databaseId" => workflow, "name" => "wf#{workflow}" } } }
    { "__typename" => "CheckRun", "name" => name, "status" => status, "conclusion" => conclusion, "startedAt" => at,
      "isRequired" => required, "checkSuite" => suite }
  end

  def status_context(name, state, required: false)
    { "__typename" => "StatusContext", "context" => name, "state" => state, "createdAt" => "2026-01-19T10:00:00Z", "isRequired" => required }
  end

  def user(login)
    { "__typename" => "User", "login" => login }
  end

  def review(login, state, oid: HEAD, at: "2026-01-19T09:00:00Z")
    { "state" => state, "submittedAt" => at, "author" => user(login), "commit" => { "oid" => oid } }
  end

  # A GraphQL pullRequest node; everything is fine unless overridden
  def pr_node(**over)
    node = {
      "number" => 7, "title" => "Add a thing", "url" => "https://github.com/acme/api/pull/7",
      "createdAt" => "2026-01-10T12:00:00Z", "isDraft" => false,
      "baseRefName" => "main", "headRefName" => "feature/thing", "headRefOid" => HEAD,
      "mergeable" => "MERGEABLE", "mergeStateStatus" => "CLEAN", "reviewDecision" => "APPROVED",
      "author" => user("me"),
      "baseRepository" => { "nameWithOwner" => "acme/api", "defaultBranchRef" => { "name" => "main" } },
      "reviewRequests" => { "nodes" => [] },
      "latestOpinionatedReviews" => { "nodes" => [review("alice", "APPROVED")] },
      "reviews" => { "nodes" => [] },
      "comments" => { "nodes" => [] },
      "reviewThreads" => { "nodes" => [] },
      "history" => { "nodes" => [{ "commit" => { "oid" => HEAD, "parents" => { "totalCount" => 1 } } }] },
      "headCommit" => { "nodes" => [{ "commit" => { "oid" => HEAD, "committedDate" => "2026-01-18T12:00:00Z",
                                                     "statusCheckRollup" => { "contexts" => { "nodes" => [check("test", "SUCCESS")] } } } }] }
    }
    node.merge(over.transform_keys(&:to_s))
  end

  def checks(*nodes)
    { "headCommit" => { "nodes" => [{ "commit" => { "oid" => HEAD, "committedDate" => "2026-01-18T12:00:00Z",
                                                    "statusCheckRollup" => { "contexts" => { "nodes" => nodes } } } }] } }
  end

  def classify(**over)
    GhTide::Stuck.classify(GhTide::Stuck.normalize(pr_node(**over)), now: NOW)
  end

  # ---- CI ----

  def test_ci_passing_when_every_check_succeeds
    assert_equal "passing", GhTide::Stuck.ci_status(GhTide::Stuck.normalize(pr_node)[:checks])[:state]
  end

  def test_ci_failing_lists_failed_checks
    pr = GhTide::Stuck.normalize(pr_node(**checks(check("lint", "SUCCESS"), check("test", "FAILURE"), status_context("ext", "ERROR"))))
    ci = GhTide::Stuck.ci_status(pr[:checks])
    assert_equal "failing", ci[:state]
    assert_equal %w[test ext], ci[:failing]
  end

  # gh tally's "looks red": the newest run of a workflow was cancelled while the workflow succeeded on this commit
  def test_cancelled_duplicate_run_is_not_a_failure
    pr = GhTide::Stuck.normalize(pr_node(**checks(
      check("test", "SUCCESS", workflow: 1, run: 100, number: 5, event: "push"),
      check("test", "CANCELLED", workflow: 1, run: 101, number: 6, event: "pull_request")
    )))
    assert_equal "passing", GhTide::Stuck.ci_status(pr[:checks])[:state]
  end

  def test_cancelled_run_without_a_success_is_a_failure
    pr = GhTide::Stuck.normalize(pr_node(**checks(check("test", "CANCELLED", workflow: 1, run: 101))))
    assert_equal "failing", GhTide::Stuck.ci_status(pr[:checks])[:state]
  end

  # A failed run that was re-run (a newer run of the same workflow and event) and passed is not a failure
  def test_failure_superseded_by_a_newer_run_is_not_a_failure
    pr = GhTide::Stuck.normalize(pr_node(**checks(
      check("test", "FAILURE", workflow: 1, run: 100, number: 5),
      check("test", "SUCCESS", workflow: 1, run: 102, number: 6)
    )))
    assert_equal "passing", GhTide::Stuck.ci_status(pr[:checks])[:state]
  end

  # Re-running failed jobs keeps the run id; the newest attempt of a job wins
  def test_rerun_attempt_of_the_same_job_wins
    pr = GhTide::Stuck.normalize(pr_node(**checks(
      check("test", "FAILURE", workflow: 1, run: 100, at: "2026-01-19T10:00:00Z"),
      check("test", "SUCCESS", workflow: 1, run: 100, at: "2026-01-19T11:00:00Z")
    )))
    assert_equal "passing", GhTide::Stuck.ci_status(pr[:checks])[:state]
  end

  def test_only_required_checks_count_when_some_are_required
    pr = GhTide::Stuck.normalize(pr_node(**checks(check("build", "SUCCESS", required: true), check("optional", "FAILURE"))))
    assert_equal "passing", GhTide::Stuck.ci_status(pr[:checks])[:state]
  end

  def test_running_checks_are_pending
    pr = GhTide::Stuck.normalize(pr_node(**checks(check("test", nil, status: "IN_PROGRESS"), status_context("ext", "PENDING"))))
    assert_equal "pending", GhTide::Stuck.ci_status(pr[:checks])[:state]
  end

  # ---- reasons ----

  def test_ready_to_merge
    r = classify
    assert_equal "ready-to-merge", r[:reason]
    assert_equal ["ready-to-merge"], r[:reasons]
    assert_equal "approved by alice", r[:details]["ready-to-merge"]
  end

  def test_conflict_comes_first_and_keeps_the_others
    r = classify(mergeable: "CONFLICTING", mergeStateStatus: "DIRTY", reviewDecision: nil,
                 latestOpinionatedReviews: { "nodes" => [] }, **checks(check("test", "FAILURE")))
    assert_equal "conflict", r[:reason]
    assert_equal %w[conflict ci-failing waiting-review], r[:reasons]
  end

  def test_dirty_merge_state_alone_is_a_conflict
    assert_equal "conflict", classify(mergeable: "UNKNOWN", mergeStateStatus: "DIRTY")[:reason]
  end

  def test_ci_failing
    r = classify(**checks(check("test", "FAILURE")))
    assert_equal "ci-failing", r[:reason]
    assert_equal "failing: test", r[:details]["ci-failing"]
  end

  def test_changes_requested
    r = classify(reviewDecision: "CHANGES_REQUESTED",
                 latestOpinionatedReviews: { "nodes" => [review("alice", "APPROVED"), review("bob", "CHANGES_REQUESTED")] })
    assert_equal "changes-requested", r[:reason]
    assert_equal "by bob", r[:details]["changes-requested"]
  end

  # Without branch protection reviewDecision is null; the latest reviews decide
  def test_changes_requested_without_review_decision
    r = classify(reviewDecision: nil, latestOpinionatedReviews: { "nodes" => [review("bob", "CHANGES_REQUESTED")] })
    assert_equal "changes-requested", r[:reason]
  end

  def test_waiting_review_with_requested_reviewers
    r = classify(reviewDecision: "REVIEW_REQUIRED", latestOpinionatedReviews: { "nodes" => [] },
                 reviewRequests: { "nodes" => [{ "requestedReviewer" => user("carol") },
                                               { "requestedReviewer" => { "__typename" => "Team", "slug" => "backend" } }] })
    assert_equal "waiting-review", r[:reason]
    assert_equal "requested: carol, backend", r[:details]["waiting-review"]
  end

  def test_waiting_review_without_requested_reviewers
    r = classify(reviewDecision: nil, latestOpinionatedReviews: { "nodes" => [] })
    assert_equal "no reviewer requested", r[:details]["waiting-review"]
  end

  # One approval but the branch rule wants more
  def test_waiting_review_when_more_approvals_are_needed
    r = classify(reviewDecision: "REVIEW_REQUIRED")
    assert_equal "waiting-review", r[:reason]
    assert_match(/1 approval so far/, r[:details]["waiting-review"])
  end

  def test_re_review_when_commits_were_added_after_the_approval
    r = classify(latestOpinionatedReviews: { "nodes" => [review("alice", "APPROVED", oid: OLD)] },
                 history: { "nodes" => [{ "commit" => { "oid" => OLD, "parents" => { "totalCount" => 1 } } },
                                        { "commit" => { "oid" => HEAD, "parents" => { "totalCount" => 1 } } }] })
    assert_equal "re-review", r[:reason]
    assert_equal "approved at aaaaaaa, 1 commit since", r[:details]["re-review"]
  end

  # Merging the base branch in after the approval is not a change to review
  def test_no_re_review_when_only_merge_commits_follow_the_approval
    r = classify(latestOpinionatedReviews: { "nodes" => [review("alice", "APPROVED", oid: OLD)] },
                 history: { "nodes" => [{ "commit" => { "oid" => OLD, "parents" => { "totalCount" => 1 } } },
                                        { "commit" => { "oid" => HEAD, "parents" => { "totalCount" => 2 } } }] })
    assert_equal "ready-to-merge", r[:reason]
  end

  # A force-push removed the approved commit from the branch
  def test_re_review_when_the_approved_commit_is_gone
    r = classify(latestOpinionatedReviews: { "nodes" => [review("alice", "APPROVED", oid: OLD)] })
    assert_equal "re-review", r[:reason]
    assert_equal "approved commit aaaaaaa is no longer on the branch", r[:details]["re-review"]
  end

  def test_stacked_on_a_parent_pr
    pr = GhTide::Stuck.normalize(pr_node(baseRefName: "feature/parent")).merge(parent: 6)
    r = GhTide::Stuck.classify(pr, now: NOW)
    assert_equal "stacked", r[:reason]
    assert_equal "on #6 (feature/parent)", r[:details]["stacked"]
  end

  def test_stacked_pr_still_waiting_for_review_shows_review_first
    r = classify(baseRefName: "feature/parent", reviewDecision: nil, latestOpinionatedReviews: { "nodes" => [] })
    assert_equal %w[waiting-review stacked], r[:reasons]
    assert_equal "on feature/parent", r[:details]["stacked"]
  end

  def test_awaiting_reply_when_someone_else_commented_last
    r = classify(comments: { "nodes" => [
      { "author" => user("me"), "createdAt" => "2026-01-18T00:00:00Z" },
      { "author" => user("bob"), "createdAt" => "2026-01-19T00:00:00Z" }
    ] })
    assert_equal "awaiting-reply", r[:reason]
    assert_equal %w[awaiting-reply ready-to-merge], r[:reasons]
    assert_equal "last comment by bob 1d ago", r[:details]["awaiting-reply"]
  end

  def test_no_awaiting_reply_after_the_author_answered
    r = classify(comments: { "nodes" => [
      { "author" => user("bob"), "createdAt" => "2026-01-18T00:00:00Z" },
      { "author" => user("me"), "createdAt" => "2026-01-19T00:00:00Z" }
    ] })
    assert_equal ["ready-to-merge"], r[:reasons]
  end

  def test_bot_comments_and_resolved_threads_do_not_count
    r = classify(
      comments: { "nodes" => [{ "author" => { "__typename" => "Bot", "login" => "linter" }, "createdAt" => "2026-01-19T00:00:00Z" }] },
      reviewThreads: { "nodes" => [{ "isResolved" => true, "comments" => { "nodes" => [{ "author" => user("bob"), "createdAt" => "2026-01-19T01:00:00Z" }] } }] }
    )
    assert_equal ["ready-to-merge"], r[:reasons]
  end

  # An approval answers the conversation; nothing is owed after it
  def test_an_approval_after_a_question_needs_no_reply
    r = classify(
      comments: { "nodes" => [{ "author" => user("bob"), "createdAt" => "2026-01-18T00:00:00Z" }] },
      reviews: { "nodes" => [{ "state" => "APPROVED", "body" => "", "submittedAt" => "2026-01-19T00:00:00Z", "author" => user("bob") }] }
    )
    assert_equal ["ready-to-merge"], r[:reasons]
  end

  # Inline comments that came with an approval are part of it
  def test_inline_comments_of_an_approval_need_no_reply
    r = classify(reviewThreads: { "nodes" => [{ "isResolved" => false, "comments" => { "nodes" => [
      { "author" => user("bob"), "createdAt" => "2026-01-19T01:00:00Z", "pullRequestReview" => { "state" => "APPROVED" } }
    ] } }] })
    assert_equal ["ready-to-merge"], r[:reasons]
  end

  def test_unresolved_review_comment_awaits_a_reply
    r = classify(reviewThreads: { "nodes" => [{ "isResolved" => false, "comments" => { "nodes" => [
      { "author" => user("bob"), "createdAt" => "2026-01-19T01:00:00Z", "pullRequestReview" => { "state" => "COMMENTED" } }
    ] } }] })
    assert_equal "awaiting-reply", r[:reason]
  end

  def test_ci_pending_is_reported_when_nothing_else_blocks
    r = classify(**checks(check("test", nil, status: "QUEUED")))
    assert_equal ["ci-pending"], r[:reasons]
  end

  def test_unknown_mergeability_is_not_ready
    r = classify(mergeable: "UNKNOWN", mergeStateStatus: "UNKNOWN")
    assert_equal "unknown", r[:reason]
  end

  def test_ages_count_from_creation_and_last_activity
    r = classify(comments: { "nodes" => [{ "author" => user("me"), "createdAt" => "2026-01-19T00:00:00Z" }] })
    assert_equal 10, r[:age_days]
    assert_equal 1, r[:idle_days]
  end

  # ---- options and output ----

  def test_parse_args_defaults
    o = GhTide::Stuck.parse_args([])
    assert_equal "@me", o[:author]
    assert_nil o[:min_age]
    assert_equal false, o[:json]
  end

  def test_parse_args_reads_options
    o = GhTide::Stuck.parse_args(%w[--author octo --owner acme --min-age 3d --json])
    assert_equal "octo", o[:author]
    assert_equal "acme", o[:owner]
    assert_equal 3 * 86_400, o[:min_age]
    assert_equal true, o[:json]
    assert_raises(GhTide::Error) { GhTide::Stuck.parse_args(%w[--owner acme -R acme/api]) }
    assert_raises(GhTide::Error) { GhTide::Stuck.parse_args(%w[--min-age soon]) }
  end

  def test_parse_duration
    assert_equal 12 * 3600, GhTide::Stuck.parse_duration("12h")
    assert_equal 14 * 86_400, GhTide::Stuck.parse_duration("2w")
  end

  def test_search_query
    assert_equal "is:pr is:open draft:false author:@me", GhTide::Stuck.search_query("@me", nil, nil)
    assert_equal "is:pr is:open draft:false author:octo user:acme", GhTide::Stuck.search_query("octo", "acme", nil)
    assert_equal "is:pr is:open draft:false author:octo repo:acme/api", GhTide::Stuck.search_query("octo", nil, "acme/api")
  end

  def test_render_groups_by_reason_and_lists_oldest_first
    rows = [
      { repo: "acme/api", number: 2, title: "Newer", reason: "ci-failing", reasons: ["ci-failing"], details: { "ci-failing" => "failing: test" }, age_days: 2, idle_days: 1 },
      { repo: "acme/web", number: 9, title: "Older", reason: "ci-failing", reasons: %w[ci-failing waiting-review], details: { "ci-failing" => "failing: lint" }, age_days: 30, idle_days: 5 },
      { repo: "acme/api", number: 3, title: "Ready", reason: "ready-to-merge", reasons: ["ready-to-merge"], details: { "ready-to-merge" => "approved by alice" }, age_days: 1, idle_days: 0 }
    ]
    out = GhTide::Stuck.render(rows, header: "3 open PRs")
    assert_match(/ci-failing\s+2\n\s+ready-to-merge\s+1/, out)
    assert_operator out.index("acme/web#9"), :<, out.index("acme/api#2")
    assert_match(/acme\/web#9\s+30d old, idle 5d\s+Older\n\s+failing: lint; also waiting-review/, out)
  end

  def test_render_names_the_parent_of_a_stacked_pr
    rows = [{ repo: "acme/api", number: 8, title: "Child", reason: "waiting-review", reasons: %w[waiting-review stacked],
              details: { "waiting-review" => "no reviewer requested" }, age_days: 1, idle_days: 1, parent: 6 }]
    assert_match(/no reviewer requested; also stacked on #6/, GhTide::Stuck.render(rows, header: "1 open PR"))
  end

  def test_gh_tide_dispatches_stuck
    out = StringIO.new
    assert_equal 0, GhTide.main(%w[stuck --help], nil, out)
    assert_match(/gh tide stuck \[options\]/, out.string)
  end

  # ---- gh I/O, with a fake GraphQL transport ----

  def search_page(numbers, next_cursor = nil)
    { "search" => { "issueCount" => 3, "pageInfo" => { "hasNextPage" => !next_cursor.nil?, "endCursor" => next_cursor },
                    "nodes" => numbers.map { |n| { "number" => n, "repository" => { "nameWithOwner" => "acme/api" } } } } }
  end

  def test_search_follows_pages
    pages = { nil => search_page([1, 2], "c1"), "c1" => search_page([3]) }
    found, total = GhTide::Stuck.search(->(_q, v) { pages.fetch(v[:after]) }, "is:pr", ->(_) {})
    assert_equal [1, 2, 3], found.map { |f| f[:number] }
    assert_equal 3, total
  end

  # Right after many merges mergeability is often UNKNOWN; it is fetched once more
  def test_fetch_pr_asks_again_when_mergeability_is_unknown
    answers = [pr_node(mergeable: "UNKNOWN", mergeStateStatus: "UNKNOWN"), pr_node]
    sleeps = []
    node = GhTide::Stuck.fetch_pr(->(_q, _v) { { "repository" => { "pullRequest" => answers.shift } } }, "acme/api", 7, ->(s) { sleeps << s })
    assert_equal "MERGEABLE", node["mergeable"]
    assert_equal 1, sleeps.length
  end

  # GraphQL sometimes answers with an HTML page; that is retried once
  def test_html_response_is_retried_once
    calls = 0
    gql = lambda do |_q, _v|
      calls += 1
      raise GhTide::Stuck::TransientError, "unexpected response from GraphQL" if calls == 1

      { "repository" => { "pullRequest" => pr_node } }
    end
    GhTide::Stuck.fetch_pr(gql, "acme/api", 7, ->(_) {})
    assert_equal 2, calls
  end

  def test_client_errors_are_not_retried
    calls = 0
    gql = lambda do |_q, _v|
      calls += 1
      raise GhTide::ApiError.new("HTTP 401", status: 401)
    end
    assert_raises(GhTide::ApiError) { GhTide::Stuck.fetch_pr(gql, "acme/api", 7, ->(_) {}) }
    assert_equal 1, calls
  end

  def test_main_prints_reasons_and_parent_of_stacked_prs
    child = pr_node(number: 8, title: "Child", baseRefName: "feature/parent")
    gql = lambda do |q, v|
      if q.include?("search(") then search_page([7, 8])
      elsif q.include?("pullRequests(headRefName") then { "repository" => { "pullRequests" => { "nodes" => [{ "number" => 6, "headRepository" => { "nameWithOwner" => "acme/api" } }] } } }
      elsif v[:number] == 8 then { "repository" => { "pullRequest" => child } }
      else { "repository" => { "pullRequest" => pr_node } }
      end
    end
    out = StringIO.new
    assert_equal 0, GhTide::Stuck.main([], gql: gql, out: out, now: NOW, sleeper: ->(_) {})
    text = out.string
    assert_match(/2 open PRs by @me, drafts excluded/, text)
    assert_match(/stacked\s+1\n\s+ready-to-merge\s+1/, text)
    assert_match(%r{acme/api#8 .*\n\s+on #6 \(feature/parent\)}, text)
    assert_match(/Note: search returned only 2 of 3 PRs/, text)
  end

  def test_main_json_and_min_age
    gql = lambda do |q, v|
      next search_page([7, 8]) if q.include?("search(")

      created = v[:number] == 8 ? "2026-01-20T00:00:00Z" : "2026-01-10T12:00:00Z"
      { "repository" => { "pullRequest" => pr_node(number: v[:number], createdAt: created) } }
    end
    out = StringIO.new
    GhTide::Stuck.main(%w[--min-age 3d --json], gql: gql, out: out, now: NOW, sleeper: ->(_) {})
    data = JSON.parse(out.string)
    assert_equal [7], data["prs"].map { |p| p["number"] }
    assert_equal({ "ready-to-merge" => 1 }, data["counts"])
    assert_equal "ready-to-merge", data["prs"][0]["reason"]
  end

  # One PR that cannot be read is reported, not fatal
  def test_main_reports_a_pr_it_could_not_read
    gql = lambda do |q, v|
      next search_page([7, 8]) if q.include?("search(")
      raise GhTide::ApiError.new("HTTP 404: Not Found", status: 404) if v[:number] == 8

      { "repository" => { "pullRequest" => pr_node } }
    end
    out = StringIO.new
    GhTide::Stuck.main([], gql: gql, out: out, now: NOW, sleeper: ->(_) {})
    assert_match(%r{Could not read acme/api#8: HTTP 404}, out.string)
  end

  # ---- --merged-unreleased ----

  def merged_node(number, oid, repo: "acme/api", merged_at: "2026-01-15T00:00:00Z")
    { "number" => number, "title" => "Merged #{number}", "url" => "https://github.com/#{repo}/pull/#{number}",
      "mergedAt" => merged_at, "mergeCommit" => { "oid" => oid },
      "repository" => { "nameWithOwner" => repo, "defaultBranchRef" => { "name" => "main" } } }
  end

  def merged_gql(nodes)
    lambda do |q, _v|
      next { "search" => { "issueCount" => 0, "pageInfo" => { "hasNextPage" => false }, "nodes" => [] } } unless q.include?("mergedAt")

      { "search" => { "issueCount" => nodes.length, "pageInfo" => { "hasNextPage" => false }, "nodes" => nodes } }
    end
  end

  def test_merged_query
    assert_equal "is:pr is:merged author:@me merged:>=2025-12-21 user:acme",
                 GhTide::Stuck.merged_query("@me", "acme", nil, NOW - (30 * 86_400))
  end

  # Only the last stage is checked; a PR whose merge commit is not on it is listed
  def test_merged_unreleased_checks_the_last_stage
    calls = []
    api = lambda do |path|
      calls << path
      next [{ "name" => "prod-20260110" }, { "name" => "prod-20260118" }] if path.include?("/tags?")
      next { "status" => "behind" } if path.include?("...old")

      { "status" => "ahead" }
    end
    opts = GhTide::Stuck.parse_args(%w[--merged-unreleased])
    r = GhTide::Stuck.load_unreleased(merged_gql([merged_node(4, "old"), merged_node(5, "new")]), api, opts, NOW, ->(_) {},
                                      ->(_) { "develop,main,tag:^prod-" })
    assert_equal [5], r[:rows].map { |x| x[:number] }
    assert_equal "tag:^prod-", r[:rows][0][:stage]
    assert_equal "prod-20260118", r[:rows][0][:ref]
    assert(calls.none? { |c| c.include?("compare/develop") })
  end

  # Without stages the default is "<default branch>,release"; no release at all means the repository is skipped
  def test_merged_unreleased_skips_a_repository_without_the_stage
    api = ->(_path) { raise GhTide::ApiError.new("HTTP 404", status: 404) }
    opts = GhTide::Stuck.parse_args(%w[--merged-unreleased])
    r = GhTide::Stuck.load_unreleased(merged_gql([merged_node(4, "x")]), api, opts, NOW, ->(_) {}, ->(_) {})
    assert_empty r[:rows]
    assert_equal [{ repo: "acme/api", stage: "release", count: 1, error: "the stage could not be resolved" }], r[:skipped]
  end

  def test_main_prints_the_merged_unreleased_section
    api = lambda do |path|
      next { "tag_name" => "v1.2.0" } if path.end_with?("releases/latest")

      { "status" => "diverged" }
    end
    out = StringIO.new
    GhTide::Stuck.main(%w[--merged-unreleased --since 2w], gql: merged_gql([merged_node(4, "x")]), api: api, out: out,
                                                          now: NOW, sleeper: ->(_) {}, stage_spec: ->(_) {})
    assert_match(%r{merged-unreleased \(1\) — merged in the last 2w, not yet on the last stage\n  acme/api#4  merged 5d ago\s+Merged 4\n      not on release \(v1\.2\.0\)}, out.string)
  end

  # ---- edge cases found in review ----

  # GitHub will not merge it yet (e.g. unresolved conversations or an out-of-date branch)
  def test_blocked_merge_state_is_not_ready
    r = classify(mergeStateStatus: "BLOCKED")
    assert_equal "unknown", r[:reason]
    assert_match(/merge state: BLOCKED/, r[:details]["unknown"])
  end

  def test_unstable_merge_state_is_still_ready
    assert_equal "ready-to-merge", classify(mergeStateStatus: "UNSTABLE")[:reason]
  end

  # More than 100 commits: an approved commit outside the window is not called gone
  def test_approval_older_than_the_fetched_history
    r = classify(latestOpinionatedReviews: { "nodes" => [review("alice", "APPROVED", oid: OLD)] },
                 history: { "totalCount" => 150, "nodes" => [{ "commit" => { "oid" => HEAD, "parents" => { "totalCount" => 1 } } }] })
    assert_equal "approved at aaaaaaa, more than 1 commits ago", r[:details]["re-review"]
  end

  def test_truncated_checks_are_not_ready
    node = checks(check("test", "SUCCESS"))
    node["headCommit"]["nodes"][0]["commit"]["statusCheckRollup"]["contexts"]["totalCount"] = 150
    assert_equal "unknown", classify(**node)[:reason]
  end

  # A re-queued job has no startedAt yet; it is the newest attempt
  def test_requeued_job_without_start_time_is_pending
    pr = GhTide::Stuck.normalize(pr_node(**checks(
      check("test", "FAILURE", workflow: 1, run: 100),
      check("test", nil, status: "QUEUED", workflow: 1, run: 100, at: nil)
    )))
    assert_equal "pending", GhTide::Stuck.ci_status(pr[:checks])[:state]
  end

  # A run that passed on re-run counts as a success, so a cancelled duplicate is forgiven
  def test_run_fixed_by_rerun_forgives_a_cancelled_duplicate
    pr = GhTide::Stuck.normalize(pr_node(**checks(
      check("test", "FAILURE", workflow: 1, run: 100, number: 5, event: "push", at: "2026-01-19T10:00:00Z"),
      check("test", "SUCCESS", workflow: 1, run: 100, number: 5, event: "push", at: "2026-01-19T11:00:00Z"),
      check("test", "CANCELLED", workflow: 1, run: 101, number: 6)
    )))
    assert_equal "passing", GhTide::Stuck.ci_status(pr[:checks])[:state]
  end

  # An empty COMMENTED review only wraps inline comments; resolved threads owe nothing
  def test_empty_commented_review_with_resolved_threads_needs_no_reply
    r = classify(reviews: { "nodes" => [{ "state" => "COMMENTED", "body" => "", "submittedAt" => "2026-01-19T00:00:00Z", "author" => user("bob") }] })
    assert_equal ["ready-to-merge"], r[:reasons]
  end

  def test_review_with_a_body_awaits_a_reply
    r = classify(reviews: { "nodes" => [{ "state" => "COMMENTED", "body" => "Why?", "submittedAt" => "2026-01-19T00:00:00Z", "author" => user("bob") }] })
    assert_equal "awaiting-reply", r[:reason]
  end

  # A GraphQL error (no HTTP status, not an HTML page) is not worth retrying
  def test_graphql_errors_are_not_retried
    calls = 0
    gql = lambda do |_q, _v|
      calls += 1
      raise GhTide::ApiError, "Could not resolve to a Repository"
    end
    assert_raises(GhTide::ApiError) { GhTide::Stuck.fetch_pr(gql, "acme/api", 7, ->(_) {}) }
    assert_equal 1, calls
  end

  def test_missing_pr_is_a_clear_error
    err = assert_raises(GhTide::ApiError) do
      GhTide::Stuck.fetch_pr(->(_q, _v) { { "repository" => { "pullRequest" => nil } } }, "acme/api", 7, ->(_) {})
    end
    assert_match(/not found or is not accessible/, err.message)
  end

  # Results that could not be read still count, so they do not look like the 1,000-result limit
  def test_unreadable_search_results_do_not_look_truncated
    page = search_page([7])
    page["search"]["issueCount"] = 2
    page["search"]["nodes"] << {}
    gql = ->(q, _v) { q.include?("search(") ? page : { "repository" => { "pullRequest" => pr_node } } }
    out = StringIO.new
    GhTide::Stuck.main([], gql: gql, out: out, now: NOW, sleeper: ->(_) {})
    refute_match(/Note: search returned only/, out.string)
  end

  # The search is by day; PRs merged before the exact --since window are dropped
  def test_merged_unreleased_keeps_the_exact_window
    api = ->(path) { path.end_with?("releases/latest") ? { "tag_name" => "v1" } : { "status" => "diverged" } }
    opts = GhTide::Stuck.parse_args(%w[--merged-unreleased --since 12h])
    nodes = [merged_node(4, "x", merged_at: "2026-01-20T06:00:00Z"), merged_node(5, "y", merged_at: "2026-01-19T20:00:00Z")]
    r = GhTide::Stuck.load_unreleased(merged_gql(nodes), api, opts, NOW, ->(_) {}, ->(_) {})
    assert_equal [4], r[:rows].map { |x| x[:number] }
  end

  # One PR that cannot be compared does not hide the rest of its repository
  def test_merged_unreleased_keeps_going_after_one_failure
    api = lambda do |path|
      next { "tag_name" => "v1" } if path.end_with?("releases/latest")
      raise GhTide::ApiError.new("HTTP 500", status: 500) if path.include?("...bad")

      { "status" => "diverged" }
    end
    opts = GhTide::Stuck.parse_args(%w[--merged-unreleased])
    r = GhTide::Stuck.load_unreleased(merged_gql([merged_node(4, "bad"), merged_node(5, "ok")]), api, opts, NOW, ->(_) {}, ->(_) {})
    assert_equal [5], r[:rows].map { |x| x[:number] }
    assert_equal [{ repo: "acme/api", stage: nil, count: 1, error: "#4: HTTP 500" }], r[:skipped]
  end
end
