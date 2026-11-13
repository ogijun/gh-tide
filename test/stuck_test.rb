# frozen_string_literal: true

require "minitest/autorun"
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
end
