import { execFile } from "node:child_process";
import { promisify } from "node:util";

const run = promisify(execFile);

export const HELP = `gh tide — 変更がどのブランチ・タグまで届いたかを見る

使い方:
  gh tide pr <番号>       PR（merge 済みなら merge コミット、未 merge なら head）
  gh tide commit <sha>    コミット
  gh tide path <パス>     ファイル・ディレクトリが各段にあるか

オプション:
  -R, --repo <owner/repo> 対象のリポ（既定は今いるリポ）
  --stages <並び>         段の並び（カンマ区切り）。例: develop,staging,main,tag:^prod-
                          branch 名 / tag:<正規表現>（名前が最大のタグ）/ release（最新リリース）
                          既定は git config tide.stages、無ければ「既定ブランチ,release」
  --workflows             無効になっている workflow も表示する
  --json                  JSON で出す
`;

export function parseArgs(argv) {
  const out = { command: "help", target: null, repo: null, stages: null, json: false, workflows: false };
  const rest = [];
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === "-R" || a === "--repo") out.repo = argv[++i];
    else if (a === "--stages") out.stages = argv[++i];
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
      const rel = await api(`repos/${repo}/releases/latest`).catch(() => null);
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
    const cmp = await api(`repos/${repo}/compare/${encodeURIComponent(r.ref)}...${sha}`);
    rows.push({ ...r, present: isContained(cmp.status) });
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
      await api(`repos/${repo}/contents/${encodeURI(path)}?ref=${encodeURIComponent(r.ref)}`);
      rows.push({ ...r, present: true });
    } catch (e) {
      if (e.status === 404) rows.push({ ...r, present: false });
      else throw e;
    }
  }
  return rows;
}

export function renderTable(rows) {
  const mark = (p) => (p === true ? "✓" : p === false ? "✗" : "?");
  const width = Math.max(...rows.map((r) => r.label.length));
  return rows
    .map((r) => {
      const ref = r.ref && r.ref !== r.label ? `  (${r.ref})` : r.ref ? "" : "  (解決できない)";
      return `${mark(r.present)}  ${r.label.padEnd(width)}${ref}`;
    })
    .join("\n");
}

// ---- 以下は gh を呼ぶ部分 ----

export async function ghApi(path) {
  try {
    const { stdout } = await run("gh", ["api", path], { maxBuffer: 64 * 1024 * 1024 });
    return JSON.parse(stdout);
  } catch (e) {
    const err = new Error((e.stderr || e.message || "").trim());
    err.status = /HTTP 404/.test(e.stderr || "") ? 404 : undefined;
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
      out.log(disabled.length ? "\n無効な workflow:" : "\n無効な workflow: なし");
      for (const w of disabled) out.log(`  ${w.state}  ${w.path}  (${w.name})`);
    }
  }
  return 0;
}
