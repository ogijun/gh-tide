# frozen_string_literal: true

require "json"
require "open3"

require_relative "stuck"

module GhTide
  class Error < StandardError; end

  # Raised by gh_api; status is the HTTP status parsed from gh's stderr (nil if unknown)
  class ApiError < Error
    attr_reader :status

    def initialize(message, status: nil)
      super(message)
      @status = status
    end
  end

  class CommandFailed < Error
    attr_reader :stderr

    def initialize(message, stderr: "")
      super(message)
      @stderr = stderr
    end
  end

  HELP = <<~'TEXT'
    gh tide — see which branches and tags a change has reached

    Usage:
      gh tide pr <number>      a PR (the merge commit if merged, otherwise the head commit)
      gh tide commit <sha>     a commit
      gh tide path <path>      whether a file or directory exists on each stage

    Options:
      -R, --repo <owner/repo>  target repository (default: the current one)
      --stages <list>          comma-separated stages in promotion order, e.g. develop,staging,main,tag:^prod-
                               a branch name / tag:<regex> (greatest matching tag name) / release (latest release)
                               default: git config tide.stages, otherwise "<default branch>,release"
      --workflows              also list workflows that are not active
      --json                   JSON output
  TEXT

  module_function

  def parse_args(argv)
    out = { command: "help", target: nil, repo: nil, stages: nil, json: false, workflows: false }
    rest = []
    value = lambda do |i, flag|
      v = argv[i]
      raise Error, "#{flag} needs a value" if v.nil? || v.start_with?("-")

      v
    end
    i = 0
    while i < argv.length
      a = argv[i]
      case a
      when "-R", "--repo"
        i += 1
        out[:repo] = value.call(i, a)
      when "--stages"
        i += 1
        out[:stages] = value.call(i, a)
      when "--json" then out[:json] = true
      when "--workflows" then out[:workflows] = true
      when "-h", "--help" then return out.merge(command: "help")
      else rest << a
      end
      i += 1
    end
    unless rest.empty?
      out[:command] = rest[0]
      out[:target] = rest[1]
    end
    out
  end

  def parse_stages(spec)
    spec
      .split(",")
      .map(&:strip)
      .reject(&:empty?)
      .map do |s|
        if s == "release" then { kind: :release }
        elsif s.start_with?("tag:") then { kind: :tag, pattern: s[4..] }
        else { kind: :branch, name: s }
        end
      end
  end

  def pick_latest_tag(tag_names, pattern)
    re = Regexp.new(pattern)
    tag_names.select { |t| re.match?(t) }.max
  end

  # Same unreserved set as JavaScript's encodeURIComponent: A-Z a-z 0-9 - _ . ! ~ * ' ( )
  def encode_uri_component(str)
    str.b.gsub(/[^A-Za-z0-9\-_.!~*'()]/n) { |c| format("%%%02X", c.ord) }.force_encoding(Encoding::UTF_8)
  end

  def encode_path(path)
    path
      .sub(%r{\A/+}, "")
      .split("/", -1)
      .map { |seg| encode_uri_component(seg) }
      .join("/")
  end

  def contained?(compare_status)
    compare_status == "identical" || compare_status == "behind"
  end

  def stage_label(stage)
    case stage[:kind]
    when :branch then stage[:name]
    when :tag then "tag:#{stage[:pattern]}"
    else "release"
    end
  end

  def unresolved?(ref)
    ref.nil? || ref.empty?
  end

  def resolve_stages(api, repo, stages)
    tag_names = nil
    stages.map do |s|
      label = stage_label(s)
      case s[:kind]
      when :branch
        { label: label, ref: s[:name] }
      when :tag
        tag_names ||= list_tag_names(api, repo)
        { label: label, ref: pick_latest_tag(tag_names, s[:pattern]) }
      else
        # Only "no release yet" (404) is unresolved; auth and other errors stop
        rel = begin
          api.call("repos/#{repo}/releases/latest")
        rescue ApiError => e
          raise unless e.status == 404

          nil
        end
        { label: label, ref: rel && rel["tag_name"] }
      end
    end
  end

  def list_tag_names(api, repo)
    names = []
    (1..10).each do |page|
      batch = api.call("repos/#{repo}/tags?per_page=100&page=#{page}")
      names.concat(batch.map { |t| t["name"] })
      break if batch.length < 100
    end
    names
  end

  def tide_for_commit(api, repo, sha, resolved)
    resolved.map do |r|
      next r.merge(present: nil) if unresolved?(r[:ref])

      begin
        cmp = api.call("repos/#{repo}/compare/#{encode_uri_component(r[:ref])}...#{encode_uri_component(sha)}")
        r.merge(present: contained?(cmp["status"]))
      rescue ApiError => e
        # A stage whose branch or tag does not exist is reported as unknown; the other stages continue
        raise unless e.status == 404

        r.merge(present: nil)
      end
    end
  end

  def tide_for_path(api, repo, path, resolved)
    resolved.map do |r|
      next r.merge(present: nil) if unresolved?(r[:ref])

      begin
        api.call("repos/#{repo}/contents/#{encode_path(path)}?ref=#{encode_uri_component(r[:ref])}")
        r.merge(present: true)
      rescue ApiError => e
        raise unless e.status == 404

        # contents also returns 404 for a missing ref; tell the two apart
        ref_exists = begin
          api.call("repos/#{repo}/commits/#{encode_uri_component(r[:ref])}")
          true
        rescue ApiError => err
          raise unless [404, 422].include?(err.status)

          false
        end
        r.merge(present: ref_exists ? false : nil)
      end
    end
  end

  def describe_subject(pr)
    merged_at = pr["merged_at"]
    merged = !(merged_at.nil? || merged_at == "")
    sha = merged ? pr["merge_commit_sha"] : pr["head"]["sha"]
    basis = merged ? "checking merge commit #{sha[0, 7]}" : "checking head commit #{sha[0, 7]} (not merged yet)"
    { sha: sha, note: "PR ##{pr["number"]} #{merged ? "merged" : pr["state"]}: #{pr["title"]}\n#{basis}" }
  end

  def render_table(rows)
    mark = ->(p) { p == true ? "✓" : p == false ? "✗" : "?" }
    return "" if rows.empty?

    width = rows.map { |r| r[:label].length }.max
    rows.map do |r|
      ref =
        if unresolved?(r[:ref]) then "  (unresolved)"
        elsif r[:ref] != r[:label] then "  (#{r[:ref]})"
        else ""
        end
      "#{mark.call(r[:present])}  #{r[:label].ljust(width)}#{ref}"
    end.join("\n")
  end

  # ---- gh I/O below ----

  def run_command(*cmd)
    stdout, stderr, status = Open3.capture3(*cmd)
    stderr = stderr.dup.force_encoding(Encoding::UTF_8).scrub
    return stdout.force_encoding(Encoding::UTF_8) if status.success?

    raise CommandFailed.new("Command failed: #{cmd.join(" ")}\n#{stderr}", stderr: stderr)
  rescue Errno::ENOENT
    raise CommandFailed.new("spawn #{cmd.first} ENOENT")
  end

  def gh_api(path)
    JSON.parse(run_command("gh", "api", path))
  rescue CommandFailed => e
    m = e.stderr.match(/HTTP (\d{3})/)
    raise ApiError.new((e.stderr.empty? ? e.message : e.stderr).strip, status: m && m[1].to_i)
  rescue JSON::ParserError => e
    raise ApiError, e.message
  end

  def git_config(key)
    v = run_command("git", "config", "--get", key).strip
    v.empty? ? nil : v
  rescue CommandFailed
    nil
  end

  def current_repo
    run_command("gh", "repo", "view", "--json", "nameWithOwner", "--jq", ".nameWithOwner").strip
  end

  def subject(api, repo, opts)
    if opts[:command] == "pr"
      raise Error, "PR number must be numeric: #{opts[:target]}" unless opts[:target].match?(/\A\d+\z/)

      return describe_subject(api.call("repos/#{repo}/pulls/#{opts[:target]}"))
    end
    { sha: opts[:target], note: "commit #{opts[:target]}" }
  end

  def say(out, text)
    out.print("#{text}\n")
  end

  def main(argv, api = method(:gh_api), out = $stdout)
    opts = parse_args(argv)
    target = opts[:target]
    if opts[:command] == "help" || target.nil? || target.empty? || !%w[pr commit path].include?(opts[:command])
      say(out, HELP)
      return opts[:command] == "help" ? 0 : 2
    end
    repo = opts[:repo].nil? ? current_repo : opts[:repo]
    spec = opts[:stages].nil? ? git_config("tide.stages") : opts[:stages]
    if spec.nil? || spec.empty?
      info = api.call("repos/#{repo}")
      spec = "#{info["default_branch"]},release"
    end
    resolved = resolve_stages(api, repo, parse_stages(spec))

    if opts[:command] == "path"
      rows = tide_for_path(api, repo, target, resolved)
      note = "path #{target}"
    else
      s = subject(api, repo, opts)
      rows = tide_for_commit(api, repo, s[:sha], resolved)
      note = s[:note]
    end

    disabled = []
    if opts[:workflows]
      wf = api.call("repos/#{repo}/actions/workflows?per_page=100")
      disabled = wf["workflows"]
                 .reject { |w| w["state"] == "active" }
                 .map { |w| { name: w["name"], path: w["path"], state: w["state"] } }
    end

    if opts[:json]
      payload = { repo: repo, subject: note, stages: rows }
      payload[:disabledWorkflows] = disabled if opts[:workflows]
      say(out, JSON.pretty_generate(payload))
    else
      say(out, "#{repo}  #{note}")
      say(out, render_table(rows))
      if opts[:workflows]
        say(out, disabled.empty? ? "\nInactive workflows: none" : "\nInactive workflows:")
        disabled.each { |w| say(out, "  #{w[:state]}  #{w[:path]}  (#{w[:name]})") }
      end
    end
    0
  end
end
