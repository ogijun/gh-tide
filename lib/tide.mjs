import { execFile } from "node:child_process";
import { promisify } from "node:util";

const run = promisify(execFile);

export const HELP = `gh tide — see which branches and tags a change has reached

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
`;

export function parseArgs(argv) {
  const out = { command: "help", target: null, repo: null, stages: null, json: false, workflows: false };
  const rest = [];
  const value = (i, flag) => {
    const v = argv[i];
    if (v === undefined || v.startsWith("-")) throw new Error(`${flag} needs a value`);
    return v;
  };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === "-R" || a === "--repo") out.repo = value(++i, a);
    else if (a === "--stages") out.stages = value(++i, a);
    else if (a === "--json") out.json = true;
    else if (a === "--workflows") out.workflows = true;
    else if (a === "-h" || a === "--help") return { ...out, command: "help" };
    else rest.push(a);
  }
  if (rest.length) {
    out.command = rest[0];
    out.target = rest[1] ?? null;
  }
  return out;
}

export function parseStages(spec) {
  return spec
    .split(",")
    .map((s) => s.trim())
    .filter(Boolean)
    .map((s) => {
      if (s === "release") return { kind: "release" };
      if (s.startsWith("tag:")) return { kind: "tag", pattern: s.slice(4) };
      return { kind: "branch", name: s };
    });
}

export function pickLatestTag(tagNames, pattern) {
  const re = new RegExp(pattern);
  const hits = tagNames.filter((t) => re.test(t)).sort();
  return hits.length ? hits[hits.length - 1] : null;
}

export function encodePath(path) {
  return path
    .replace(/^\/+/, "")
    .split("/")
    .map(encodeURIComponent)
    .join("/");
}

export function isContained(compareStatus) {
  return compareStatus === "identical" || compareStatus === "behind";
}

function stageLabel(stage) {
  if (stage.kind === "branch") return stage.name;
  if (stage.kind === "tag") return `tag:${stage.pattern}`;
  return "release";
}

export async function resolveStages(api, repo, stages) {
  let tagNames = null;
  const resolved = [];
  for (const s of stages) {
    const label = stageLabel(s);
    if (s.kind === "branch") resolved.push({ label, ref: s.name });
    else if (s.kind === "tag") {
      tagNames ??= await listTagNames(api, repo);
      resolved.push({ label, ref: pickLatestTag(tagNames, s.pattern) });
    } else {
      // Only "no release yet" (404) is unresolved; auth and other errors stop
      const rel = await api(`repos/${repo}/releases/latest`).catch((e) => {
        if (e.status === 404) return null;
        throw e;
      });
      resolved.push({ label, ref: rel?.tag_name ?? null });
    }
  }
  return resolved;
}

async function listTagNames(api, repo) {
  const names = [];
  for (let page = 1; page <= 10; page++) {
    const batch = await api(`repos/${repo}/tags?per_page=100&page=${page}`);
    names.push(...batch.map((t) => t.name));
    if (batch.length < 100) break;
  }
  return names;
}

export async function tideForCommit(api, repo, sha, resolved) {
  const rows = [];
  for (const r of resolved) {
    if (!r.ref) {
      rows.push({ ...r, present: null });
      continue;
    }
    try {
      const cmp = await api(`repos/${repo}/compare/${encodeURIComponent(r.ref)}...${encodeURIComponent(sha)}`);
      rows.push({ ...r, present: isContained(cmp.status) });
    } catch (e) {
      // A stage whose branch or tag does not exist is reported as unknown; the other stages continue
      if (e.status === 404) rows.push({ ...r, present: null });
      else throw e;
    }
  }
  return rows;
}

export async function tideForPath(api, repo, path, resolved) {
  const rows = [];
  for (const r of resolved) {
    if (!r.ref) {
      rows.push({ ...r, present: null });
      continue;
    }
    try {
      await api(`repos/${repo}/contents/${encodePath(path)}?ref=${encodeURIComponent(r.ref)}`);
      rows.push({ ...r, present: true });
    } catch (e) {
      if (e.status !== 404) throw e;
      // contents also returns 404 for a missing ref; tell the two apart
      const refExists = await api(`repos/${repo}/commits/${encodeURIComponent(r.ref)}`).then(
        () => true,
        (err) => {
          if (err.status === 404 || err.status === 422) return false;
          throw err;
        },
      );
      rows.push({ ...r, present: refExists ? false : null });
    }
  }
  return rows;
}

export function renderTable(rows) {
  const mark = (p) => (p === true ? "✓" : p === false ? "✗" : "?");
  const width = Math.max(...rows.map((r) => r.label.length));
  return rows
    .map((r) => {
      const ref = r.ref && r.ref !== r.label ? `  (${r.ref})` : r.ref ? "" : "  (unresolved)";
      return `${mark(r.present)}  ${r.label.padEnd(width)}${ref}`;
    })
    .join("\n");
}

// ---- gh I/O below ----

export async function ghApi(path) {
  try {
    const { stdout } = await run("gh", ["api", path], { maxBuffer: 64 * 1024 * 1024 });
    return JSON.parse(stdout);
  } catch (e) {
    const err = new Error((e.stderr || e.message || "").trim());
    const m = (e.stderr || "").match(/HTTP (\d{3})/);
    err.status = m ? Number(m[1]) : undefined;
    throw err;
  }
}

async function gitConfig(key) {
  try {
    const { stdout } = await run("git", ["config", "--get", key]);
    return stdout.trim() || null;
  } catch {
    return null;
  }
}

async function currentRepo() {
  const { stdout } = await run("gh", ["repo", "view", "--json", "nameWithOwner", "--jq", ".nameWithOwner"]);
  return stdout.trim();
}

async function subject(api, repo, opts) {
  if (opts.command === "pr") {
    if (!/^\d+$/.test(opts.target)) throw new Error(`PR number must be numeric: ${opts.target}`);
    const pr = await api(`repos/${repo}/pulls/${opts.target}`);
    const sha = pr.merged_at ? pr.merge_commit_sha : pr.head.sha;
    return { sha, note: `PR #${pr.number} ${pr.merged_at ? "merged" : pr.state}: ${pr.title}` };
  }
  return { sha: opts.target, note: `commit ${opts.target}` };
}

export async function main(argv, api = ghApi, out = console) {
  const opts = parseArgs(argv);
  if (opts.command === "help" || !opts.target || !["pr", "commit", "path"].includes(opts.command)) {
    out.log(HELP);
    return opts.command === "help" ? 0 : 2;
  }
  const repo = opts.repo ?? (await currentRepo());
  let spec = opts.stages ?? (await gitConfig("tide.stages"));
  if (!spec) {
    const info = await api(`repos/${repo}`);
    spec = `${info.default_branch},release`;
  }
  const resolved = await resolveStages(api, repo, parseStages(spec));

  let rows;
  let note;
  if (opts.command === "path") {
    rows = await tideForPath(api, repo, opts.target, resolved);
    note = `path ${opts.target}`;
  } else {
    const s = await subject(api, repo, opts);
    rows = await tideForCommit(api, repo, s.sha, resolved);
    note = s.note;
  }

  let disabled = [];
  if (opts.workflows) {
    const wf = await api(`repos/${repo}/actions/workflows?per_page=100`);
    disabled = wf.workflows.filter((w) => w.state !== "active").map((w) => ({ name: w.name, path: w.path, state: w.state }));
  }

  if (opts.json) {
    out.log(JSON.stringify({ repo, subject: note, stages: rows, disabledWorkflows: opts.workflows ? disabled : undefined }, null, 2));
  } else {
    out.log(`${repo}  ${note}`);
    out.log(renderTable(rows));
    if (opts.workflows) {
      out.log(disabled.length ? "\nInactive workflows:" : "\nInactive workflows: none");
      for (const w of disabled) out.log(`  ${w.state}  ${w.path}  (${w.name})`);
    }
  }
  return 0;
}
