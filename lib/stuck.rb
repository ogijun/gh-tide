# frozen_string_literal: true

require "json"
require "time"

module GhTide
  # gh tide stuck: open pull requests that have not reached their base branch, grouped by why
  module Stuck
    # Ordered by what to act on first. A PR gets every reason that applies; the first one is its main reason.
    REASONS = %w[conflict ci-failing changes-requested awaiting-reply re-review waiting-review stacked ci-pending
                 ready-to-merge unknown].freeze

    HINTS = {
      "conflict" => "update the branch and resolve the conflicts",
      "ci-failing" => "fix or re-run the failing checks",
      "changes-requested" => "address the requested changes",
      "awaiting-reply" => "someone else spoke last; reply",
      "re-review" => "commits were added after the approval; ask for another look",
      "waiting-review" => "no approval yet",
      "stacked" => "waits for its parent PR",
      "ci-pending" => "checks are still running",
      "ready-to-merge" => "approved, green, no conflicts; only the merge is left",
      "unknown" => "GitHub did not report whether it can merge"
    }.freeze

    HELP = <<~'TEXT'
      gh tide stuck — open pull requests that have not been merged, grouped by why they are stuck

      Usage:
        gh tide stuck [options]

      Options:
        --author <login>         whose PRs (default: @me)
        --owner <owner>          only repositories of this user or organization
        -R, --repo <owner/repo>  only this repository (default: every repository)
        --min-age <duration>     only PRs opened at least this long ago: 12h, 3d, 2w
        --merged-unreleased      also list merged PRs that have not reached the last stage
        --since <duration>       how far back --merged-unreleased looks (default: 30d)
        --stages <list>          stages for --merged-unreleased (default: git config tide.stages in the
                                 current repository, otherwise "<default branch>,release")
        --json                   JSON output

      Reasons, in the order to act on them:
        conflict           the branch cannot be merged because of conflicts
        ci-failing         a check failed (required checks only, if any are required)
        changes-requested  a reviewer requested changes
        awaiting-reply     the last comment is from someone else and the author has not replied
        re-review          approved, but commits were added after the approval
        waiting-review     no approval yet
        stacked            the base is not the default branch (waits for a parent PR)
        ci-pending         checks are still running
        ready-to-merge     approved, green, no conflicts
    TEXT

    FAILED = %w[FAILURE TIMED_OUT STARTUP_FAILURE ACTION_REQUIRED ERROR].freeze
    OK = %w[SUCCESS NEUTRAL SKIPPED STALE].freeze

    module_function

    # ---- options ----

    def parse_duration(spec)
      m = spec.to_s.match(/\A(\d+)([hdw])\z/)
      raise Error, "duration must look like 12h, 3d, or 2w: #{spec}" unless m

      m[1].to_i * { "h" => 3600, "d" => 86_400, "w" => 7 * 86_400 }[m[2]]
    end

    def parse_args(argv)
      out = { author: "@me", owner: nil, repo: nil, min_age: nil, json: false, merged_unreleased: false,
              since: 30 * 86_400, stages: nil, help: false }
      value = lambda do |i, flag|
        v = argv[i]
        raise Error, "#{flag} needs a value" if v.nil? || v.start_with?("-")

        v
      end
      i = 0
      while i < argv.length
        a = argv[i]
        case a
        when "--author" then out[:author] = value.call(i += 1, a)
        when "--owner" then out[:owner] = value.call(i += 1, a)
        when "-R", "--repo" then out[:repo] = value.call(i += 1, a)
        when "--min-age"
          out[:min_age_label] = value.call(i += 1, a)
          out[:min_age] = parse_duration(out[:min_age_label])
        when "--since" then out[:since] = parse_duration(value.call(i += 1, a))
        when "--stages" then out[:stages] = value.call(i += 1, a)
        when "--merged-unreleased" then out[:merged_unreleased] = true
        when "--json" then out[:json] = true
        when "-h", "--help" then out[:help] = true
        else raise Error, "unknown argument for stuck: #{a}"
        end
        i += 1
      end
      raise Error, "use either --owner or -R, not both" if out[:owner] && out[:repo]

      out
    end

    def scope_qualifier(owner, repo)
      if repo then " repo:#{repo}"
      elsif owner then " user:#{owner}"
      else ""
      end
    end

    def search_query(author, owner, repo)
      "is:pr is:open draft:false author:#{author}#{scope_qualifier(owner, repo)}"
    end

    # ---- normalizing the GraphQL node ----

    def time(s)
      s.nil? || s.empty? ? nil : Time.iso8601(s)
    end

    def bot?(author)
      author.nil? || author["__typename"] == "Bot" || author["login"].to_s.end_with?("[bot]")
    end

    def nodes(node, key)
      (node[key] || {})["nodes"] || []
    end

    def normalize_check(c)
      if c["__typename"] == "StatusContext"
        state = case c["state"]
                when "SUCCESS" then "ok"
                when "PENDING", "EXPECTED" then "pending"
                else "failure"
                end
        return { name: c["context"], state: state, required: c["isRequired"] == true, at: c["createdAt"].to_s }
      end
      state = if c["status"] != "COMPLETED" then "pending"
              elsif OK.include?(c["conclusion"]) then "ok"
              elsif c["conclusion"] == "CANCELLED" then "cancelled"
              else "failure"
              end
      run = c.dig("checkSuite", "workflowRun")
      {
        name: c["name"], state: state, required: c["isRequired"] == true, at: c["startedAt"].to_s,
        workflow_id: run && run.dig("workflow", "databaseId"), event: run && run["event"],
        run_id: run && run["databaseId"], run_number: run && run["runNumber"]
      }
    end

    def requested_name(r)
      x = r["requestedReviewer"] || {}
      x["login"] || x["slug"] || x["name"]
    end

    def normalize(node)
      author = node.dig("author", "login")
      head = (nodes(node, "headCommit").last || {})["commit"] || {}
      rollup = head["statusCheckRollup"] || {}
      conversation = []
      nodes(node, "comments").each { |c| conversation << { author: c["author"], at: c["createdAt"], reply: true } }
      nodes(node, "reviews").each do |r|
        # An approval answers the conversation; a comment or change request asks for a reply
        conversation << { author: r["author"], at: r["submittedAt"], reply: r["state"] != "APPROVED" }
      end
      nodes(node, "reviewThreads").each do |t|
        next if t["isResolved"]

        # Inline comments left with an approval are part of that approval
        nodes(t, "comments").each do |c|
          conversation << { author: c["author"], at: c["createdAt"], reply: c.dig("pullRequestReview", "state") != "APPROVED" }
        end
      end
      {
        repo: node.dig("baseRepository", "nameWithOwner"),
        number: node["number"],
        title: node["title"],
        url: node["url"],
        author: author,
        created_at: time(node["createdAt"]),
        base: node["baseRefName"],
        default_branch: node.dig("baseRepository", "defaultBranchRef", "name"),
        head_oid: node["headRefOid"],
        head_committed_at: time(head["committedDate"]),
        mergeable: node["mergeable"],
        merge_state: node["mergeStateStatus"],
        review_decision: node["reviewDecision"],
        reviews: nodes(node, "latestOpinionatedReviews")
          .reject { |r| r.dig("author", "login") == author }
          .map { |r| { login: r.dig("author", "login"), state: r["state"], at: time(r["submittedAt"]), commit: r.dig("commit", "oid") } },
        requested: nodes(node, "reviewRequests").map { |r| requested_name(r) }.compact,
        history: nodes(node, "history").map { |c| { oid: c.dig("commit", "oid"), merge: c.dig("commit", "parents", "totalCount").to_i > 1 } },
        checks: nodes(rollup, "contexts").map { |c| normalize_check(c) },
        conversation: conversation
          .reject { |e| bot?(e[:author]) || e[:at].nil? }
          .map { |e| { login: e[:author]["login"], at: time(e[:at]), reply: e[:reply] } }
          .sort_by { |e| e[:at] },
        parent: nil
      }
    end

    # ---- CI ----

    # Same idea as gh tally: per (workflow, event) only the newest run counts, so a failure that a later run
    # fixed is not a failure; a cancelled run while the same workflow succeeded on this commit only looks red.
    def effective_checks(checks)
      actions, others = checks.partition { |c| c[:workflow_id] }
      newest = {}
      actions.each do |c|
        key = [c[:workflow_id], c[:event]]
        cur = newest[key]
        newest[key] = c if cur.nil? || ([c[:run_number].to_i, c[:run_id].to_i] <=> [cur[:run_number].to_i, cur[:run_id].to_i]).positive?
      end
      newest_runs = newest.values.map { |c| c[:run_id] }
      # Re-running failed jobs keeps the run id; the latest attempt of each job wins
      latest = ->(list, key) { list.group_by(&key).values.map { |g| g.max_by { |c| c[:at] } } }
      kept = latest.call(actions.select { |c| newest_runs.include?(c[:run_id]) }, ->(c) { [c[:run_id], c[:name]] })
      ok_runs = actions.group_by { |c| c[:run_id] }.select { |_, g| g.all? { |c| c[:state] == "ok" } }
      succeeded = ok_runs.values.map { |g| g.first[:workflow_id] }.uniq
      kept = kept.map do |c|
        c[:state] == "cancelled" && succeeded.include?(c[:workflow_id]) ? c.merge(state: "ok", looks_red: true) : c
      end
      kept + latest.call(others, ->(c) { c[:name] })
    end

    def ci_status(checks)
      list = effective_checks(checks)
      list = list.select { |c| c[:required] } if list.any? { |c| c[:required] }
      return { state: "none", failing: [], pending: [] } if list.empty?

      failing = checks.map { |c| c[:name] }.uniq & list.select { |c| %w[failure cancelled].include?(c[:state]) }.map { |c| c[:name] }
      pending = list.select { |c| c[:state] == "pending" }.map { |c| c[:name] }.uniq
      state = if failing.any? then "failing"
              elsif pending.any? then "pending"
              else "passing"
              end
      { state: state, failing: failing, pending: pending }
    end

    # ---- reasons ----

    def days(from, to)
      ((to - from) / 86_400).floor
    end

    def short(oid)
      oid.to_s[0, 7]
    end

    def list(names, max = 3)
      shown = names.first(max).join(", ")
      names.length > max ? "#{shown} (+#{names.length - max})" : shown
    end

    def plural(n, word)
      "#{n} #{word}#{"s" unless n == 1}"
    end

    def review_state(pr)
      approvals = pr[:reviews].select { |r| r[:state] == "APPROVED" }
      changes = pr[:reviews].select { |r| r[:state] == "CHANGES_REQUESTED" }
      decision = pr[:review_decision] ||
                 (if changes.any? then "CHANGES_REQUESTED"
                  elsif approvals.any? then "APPROVED"
                  end)
      { decision: decision, approvals: approvals, changes: changes }
    end

    # nil when the approval still matches the branch; otherwise why it needs another look
    def stale_approval(pr, approvals)
      last = approvals.max_by { |r| r[:at] || Time.at(0) }
      return nil if last.nil? || last[:commit].nil? || last[:commit] == pr[:head_oid]

      idx = pr[:history].index { |c| c[:oid] == last[:commit] }
      return "approved commit #{short(last[:commit])} is no longer on the branch" if idx.nil?

      added = pr[:history][(idx + 1)..].reject { |c| c[:merge] }
      return nil if added.empty?

      "approved at #{short(last[:commit])}, #{plural(added.length, "commit")} since"
    end

    def last_activity(pr)
      [pr[:created_at], pr[:head_committed_at], *pr[:conversation].map { |e| e[:at] }].compact.max
    end

    def classify(pr, now:)
      found = {}
      if pr[:mergeable] == "CONFLICTING" || pr[:merge_state] == "DIRTY"
        found["conflict"] = "with #{pr[:base]}"
      end
      ci = ci_status(pr[:checks])
      found["ci-failing"] = "failing: #{list(ci[:failing])}" if ci[:state] == "failing"

      rv = review_state(pr)
      approved = rv[:decision] == "APPROVED"
      found["changes-requested"] = "by #{list(rv[:changes].map { |r| r[:login] })}" if rv[:decision] == "CHANGES_REQUESTED"

      last = pr[:conversation].last
      if last && last[:login] != pr[:author] && last[:reply]
        found["awaiting-reply"] = "last comment by #{last[:login]} #{days(last[:at], now)}d ago"
      end

      stale = approved ? stale_approval(pr, rv[:approvals]) : nil
      found["re-review"] = stale if stale

      if !approved && rv[:decision] != "CHANGES_REQUESTED"
        parts = [pr[:requested].empty? ? "no reviewer requested" : "requested: #{list(pr[:requested])}"]
        parts << "#{plural(rv[:approvals].length, "approval")} so far" if rv[:approvals].any?
        found["waiting-review"] = parts.join("; ")
      end

      stacked = pr[:default_branch] && pr[:base] != pr[:default_branch]
      found["stacked"] = pr[:parent] ? "on ##{pr[:parent]} (#{pr[:base]})" : "on #{pr[:base]}" if stacked

      found["ci-pending"] = "running: #{list(ci[:pending])}" if ci[:state] == "pending" && found.empty?

      mergeable = pr[:mergeable] == "MERGEABLE"
      blocking = found.keys - ["awaiting-reply"]
      if approved && !stale && !stacked && mergeable && blocking.empty? && ci[:state] != "pending"
        found["ready-to-merge"] = "approved by #{list(rv[:approvals].map { |r| r[:login] })}"
      end
      found["unknown"] = "mergeable: #{pr[:mergeable]}, merge state: #{pr[:merge_state]}" if found.empty?

      reasons = REASONS.select { |r| found.key?(r) }
      active = last_activity(pr) || now
      pr.merge(
        reason: reasons.first,
        reasons: reasons,
        details: found.slice(*reasons),
        ci: ci[:state],
        last_activity_at: active,
        age_days: pr[:created_at] ? days(pr[:created_at], now) : nil,
        idle_days: days(active, now)
      )
    end

    # ---- output ----

    def truncate(s, width)
      s = s.to_s
      s.length > width ? "#{s[0, width - 1]}…" : s
    end

    def render(rows, header:)
      lines = [header]
      return lines.join("\n") if rows.empty?

      grouped = rows.group_by { |r| r[:reason] }
      order = REASONS.select { |r| grouped.key?(r) }
      width = order.map(&:length).max
      lines << ""
      order.each { |r| lines << "  #{r.ljust(width)}  #{grouped[r].length}" }
      order.each do |r|
        list = grouped[r].sort_by { |x| [-(x[:age_days] || 0), x[:repo].to_s, x[:number]] }
        ref_width = list.map { |x| "#{x[:repo]}##{x[:number]}".length }.max
        lines << ""
        lines << "#{r} (#{list.length}) — #{HINTS[r]}"
        list.each do |x|
          ref = "#{x[:repo]}##{x[:number]}".ljust(ref_width)
          ages = "#{x[:age_days]}d old, idle #{x[:idle_days]}d".ljust(20)
          lines << "  #{ref}  #{ages}  #{truncate(x[:title], 72)}"
          extra = [x[:details][r]]
          others = x[:reasons] - [r]
          others = others.map { |o| o == "stacked" && x[:parent] ? "stacked on ##{x[:parent]}" : o }
          extra << "also #{others.join(", ")}" if others.any?
          lines << "      #{extra.compact.join("; ")}"
        end
      end
      lines.join("\n")
    end

    # ---- gh I/O below ----

    SEARCH_QUERY = <<~'GRAPHQL'
      query($q: String!, $after: String) {
        search(query: $q, type: ISSUE, first: 100, after: $after) {
          issueCount
          pageInfo { hasNextPage endCursor }
          nodes { ... on PullRequest { number repository { nameWithOwner } } }
        }
      }
    GRAPHQL

    PR_QUERY = <<~'GRAPHQL'
      query($owner: String!, $name: String!, $number: Int!) {
        repository(owner: $owner, name: $name) {
          pullRequest(number: $number) {
            number title url createdAt isDraft
            baseRefName headRefName headRefOid mergeable mergeStateStatus reviewDecision
            author { __typename login }
            baseRepository { nameWithOwner defaultBranchRef { name } }
            reviewRequests(first: 20) {
              nodes { requestedReviewer { __typename ... on User { login } ... on Team { slug } ... on Bot { login } ... on Mannequin { login } } }
            }
            latestOpinionatedReviews(first: 50) { nodes { state submittedAt author { __typename login } commit { oid } } }
            reviews(last: 30) { nodes { state submittedAt author { __typename login } } }
            comments(last: 30) { nodes { createdAt author { __typename login } } }
            reviewThreads(last: 50) { nodes { isResolved comments(last: 1) { nodes { createdAt author { __typename login } pullRequestReview { state } } } } }
            history: commits(last: 100) { nodes { commit { oid parents { totalCount } } } }
            headCommit: commits(last: 1) {
              nodes {
                commit {
                  oid committedDate
                  statusCheckRollup {
                    contexts(first: 100) {
                      nodes {
                        __typename
                        ... on CheckRun {
                          name status conclusion startedAt isRequired(pullRequestNumber: $number)
                          checkSuite { workflowRun { databaseId runNumber event workflow { databaseId } } }
                        }
                        ... on StatusContext { context state createdAt isRequired(pullRequestNumber: $number) }
                      }
                    }
                  }
                }
              }
            }
          }
        }
      }
    GRAPHQL

    PARENT_QUERY = <<~'GRAPHQL'
      query($owner: String!, $name: String!, $head: String!) {
        repository(owner: $owner, name: $name) {
          pullRequests(headRefName: $head, states: OPEN, first: 5) { nodes { number headRepository { nameWithOwner } } }
        }
      }
    GRAPHQL

    def gh_graphql(query, vars)
      args = ["gh", "api", "graphql", "-f", "query=#{query}"]
      vars.each do |k, v|
        next if v.nil?

        args.push(v.is_a?(Integer) ? "-F" : "-f", "#{k}=#{v}")
      end
      body = JSON.parse(GhTide.run_command(*args))
      raise ApiError, body["errors"].map { |e| e["message"] }.join("; ") if body["errors"] && body["data"].nil?

      body["data"]
    rescue CommandFailed => e
      m = e.stderr.match(/HTTP (\d{3})/)
      raise ApiError.new((e.stderr.empty? ? e.message : e.stderr).strip, status: m && m[1].to_i)
    rescue JSON::ParserError => e
      # GitHub sometimes answers a heavy GraphQL request with an HTML error page
      raise ApiError, "unexpected response from GraphQL: #{e.message[0, 80]}"
    end

    # Retry once on errors that are not the caller's fault (5xx, HTML instead of JSON, timeouts)
    def with_retry(sleeper)
      yield
    rescue ApiError => e
      raise if e.status && e.status < 500

      sleeper.call(2)
      yield
    end

    def search(gql, query, sleeper)
      found = []
      after = nil
      total = 0
      10.times do
        page = with_retry(sleeper) { gql.call(SEARCH_QUERY, { q: query, after: after }) }["search"]
        total = page["issueCount"]
        found.concat(page["nodes"].filter_map { |n| n["number"] && { repo: n.dig("repository", "nameWithOwner"), number: n["number"] } })
        break unless page.dig("pageInfo", "hasNextPage")

        after = page.dig("pageInfo", "endCursor")
      end
      [found, total]
    end

    def fetch_pr(gql, repo, number, sleeper)
      owner, name = repo.split("/", 2)
      vars = { owner: owner, name: name, number: number }
      get = -> { with_retry(sleeper) { gql.call(PR_QUERY, vars) }.dig("repository", "pullRequest") }
      node = get.call
      # Right after many merges GitHub often has not computed mergeability yet; ask once more
      if node["mergeable"] == "UNKNOWN" || node["mergeStateStatus"] == "UNKNOWN"
        sleeper.call(2)
        node = get.call
      end
      node
    end

    # The open PR in the same repository whose head branch is this PR's base
    def find_parent(gql, pr, sleeper)
      owner, name = pr[:repo].split("/", 2)
      data = with_retry(sleeper) { gql.call(PARENT_QUERY, { owner: owner, name: name, head: pr[:base] }) }
      hit = data.dig("repository", "pullRequests", "nodes").to_a.find do |n|
        n.dig("headRepository", "nameWithOwner") == pr[:repo] && n["number"] != pr[:number]
      end
      hit && hit["number"]
    end

    def pool(items, size)
      out = Array.new(items.length)
      queue = Queue.new
      items.each_index { |i| queue << i }
      Array.new([size, items.length].min) do
        Thread.new do
          loop do
            k = begin
              queue.pop(true)
            rescue ThreadError
              break
            end
            out[k] = yield(items[k])
          end
        end
      end.each(&:join)
      out
    end

    def first_line(s)
      s.to_s.split("\n", 2)[0] || ""
    end

    def load_open(gql, opts, now, sleeper)
      found, total = search(gql, search_query(opts[:author], opts[:owner], opts[:repo]), sleeper)
      results = pool(found, 4) do |f|
        pr = normalize(fetch_pr(gql, f[:repo], f[:number], sleeper))
        if pr[:default_branch] && pr[:base] != pr[:default_branch]
          pr[:parent] = begin
            find_parent(gql, pr, sleeper)
          rescue ApiError
            nil
          end
        end
        classify(pr, now: now)
      rescue StandardError => e
        # One PR that cannot be read should not hide the rest
        { repo: f[:repo], number: f[:number], error: first_line(e.message) }
      end
      errors, rows = results.partition { |r| r[:error] }
      rows = rows.select { |r| r[:created_at] && now - r[:created_at] >= opts[:min_age] } if opts[:min_age]
      { rows: rows, errors: errors, total: total, found: found.length }
    end

    def json_row(r)
      {
        repo: r[:repo], number: r[:number], title: r[:title], url: r[:url],
        reason: r[:reason], reasons: r[:reasons], details: r[:details],
        createdAt: r[:created_at]&.iso8601, lastActivityAt: r[:last_activity_at]&.iso8601,
        ageDays: r[:age_days], idleDays: r[:idle_days], ci: r[:ci], base: r[:base], parent: r[:parent]
      }
    end

    def main(argv, gql: method(:gh_graphql), out: $stdout, now: Time.now, sleeper: ->(s) { sleep(s) })
      opts = parse_args(argv)
      if opts[:help]
        out.print(HELP)
        return 0
      end
      result = load_open(gql, opts, now, sleeper)
      rows = result[:rows]
      who = opts[:author]
      scope = opts[:repo] || opts[:owner]
      header = "#{rows.length} open PRs by #{who}#{" in #{scope}" if scope}, drafts excluded"
      header += ", opened at least #{opts[:min_age_label]} ago" if opts[:min_age]

      if opts[:json]
        out.print(JSON.pretty_generate(
          author: who,
          counts: REASONS.to_h { |r| [r, rows.count { |x| x[:reason] == r }] }.reject { |_, n| n.zero? },
          prs: rows.sort_by { |r| [REASONS.index(r[:reason]), -(r[:age_days] || 0)] }.map { |r| json_row(r) },
          errors: result[:errors],
          truncated: result[:total] > result[:found]
        ), "\n")
        return 0
      end
      out.print(render(rows, header: header), "\n")
      result[:errors].each { |e| out.print("Could not read #{e[:repo]}##{e[:number]}: #{e[:error]}\n") }
      if result[:total] > result[:found]
        out.print("Note: search returned only #{result[:found]} of #{result[:total]} PRs (the 1,000-result limit).\n")
      end
      0
    end
  end
end
