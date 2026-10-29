import { test } from "node:test";
import assert from "node:assert/strict";
import {
  parseArgs,
  parseStages,
  pickLatestTag,
  isContained,
  tideForCommit,
  tideForPath,
  renderTable,
  encodePath,
  describeSubject,
} from "../lib/tide.mjs";

test("parseArgs: サブコマンドと引数とフラグを分ける", () => {
  assert.deepEqual(parseArgs(["pr", "12", "-R", "o/r", "--json"]), {
    command: "pr",
    target: "12",
    repo: "o/r",
    stages: null,
    json: true,
    workflows: false,
  });
  assert.equal(parseArgs(["path", "a/b", "--stages", "dev,main"]).stages, "dev,main");
  assert.equal(parseArgs(["commit", "abc", "--workflows"]).workflows, true);
});

test("parseArgs: サブコマンドが無ければ help", () => {
  assert.equal(parseArgs([]).command, "help");
  assert.equal(parseArgs(["-h"]).command, "help");
});

test("parseStages: カンマ区切りを種類つきの段に分ける", () => {
  assert.deepEqual(parseStages("develop, staging,tag:^prod-,release"), [
    { kind: "branch", name: "develop" },
    { kind: "branch", name: "staging" },
    { kind: "tag", pattern: "^prod-" },
    { kind: "release" },
  ]);
});

test("pickLatestTag: パターンに合うタグのうち名前が最大のもの", () => {
  const tags = ["v1", "prod-20261007-201054", "stg-20261014", "prod-20261021-200232"];
  assert.equal(pickLatestTag(tags, "^prod-"), "prod-20261021-200232");
  assert.equal(pickLatestTag(tags, "^nothing"), null);
});

test("isContained: compare の status で含まれるかを決める", () => {
  assert.equal(isContained("identical"), true);
  assert.equal(isContained("behind"), true);
  assert.equal(isContained("ahead"), false);
  assert.equal(isContained("diverged"), false);
});

test("tideForCommit: 各段について compare を呼び、含まれるかを返す", async () => {
  const calls = [];
  const api = async (path) => {
    calls.push(path);
    if (path.includes("compare/develop...")) return { status: "behind" };
    if (path.includes("compare/staging...")) return { status: "diverged" };
    throw new Error("unexpected " + path);
  };
  const rows = await tideForCommit(api, "o/r", "abc123", [
    { label: "develop", ref: "develop" },
    { label: "staging", ref: "staging" },
  ]);
  assert.deepEqual(rows, [
    { label: "develop", ref: "develop", present: true },
    { label: "staging", ref: "staging", present: false },
  ]);
  assert.equal(calls[0], "repos/o/r/compare/develop...abc123");
});

test("tideForCommit: 段の ref が解決できなければ present は null", async () => {
  const rows = await tideForCommit(async () => ({ status: "behind" }), "o/r", "abc", [
    { label: "tag:^prod-", ref: null },
  ]);
  assert.equal(rows[0].present, null);
});

test("tideForPath: contents が 404 なら無い", async () => {
  const api = async (path) => {
    if (path.endsWith("ref=main")) return { type: "file" };
    if (path.startsWith("repos/o/r/commits/")) return { sha: "x" };
    const e = new Error("HTTP 404");
    e.status = 404;
    throw e;
  };
  const rows = await tideForPath(api, "o/r", "src/a.js", [
    { label: "dev", ref: "dev" },
    { label: "main", ref: "main" },
  ]);
  assert.deepEqual(
    rows.map((r) => r.present),
    [false, true],
  );
});

test("renderTable: 段ごとに ✓ ✗ ? を並べる", () => {
  const out = renderTable([
    { label: "develop", ref: "develop", present: true },
    { label: "tag:^prod-", ref: "prod-1", present: false },
    { label: "release", ref: null, present: null },
  ]);
  assert.match(out, /✓\s+develop/);
  assert.match(out, /✗\s+tag:\^prod-\s+\(prod-1\)/);
  assert.match(out, /\?\s+release/);
});

test("parseArgs: 値が要るフラグに値が無ければエラー", () => {
  assert.throws(() => parseArgs(["pr", "1", "-R"]));
  assert.throws(() => parseArgs(["pr", "1", "--stages", "--json"]));
});

test("encodePath: ? や # も含めて各要素をエンコードし、先頭の / を落とす", () => {
  assert.equal(encodePath("/a b/c?d#e.js"), "a%20b/c%3Fd%23e.js");
});

test("tideForCommit: 段の ref が無い（compare が 404）なら present は null で、他の段は続ける", async () => {
  const api = async (path) => {
    if (path.includes("compare/nope...")) {
      const e = new Error("HTTP 404");
      e.status = 404;
      throw e;
    }
    return { status: "identical" };
  };
  const rows = await tideForCommit(api, "o/r", "abc", [
    { label: "nope", ref: "nope" },
    { label: "main", ref: "main" },
  ]);
  assert.deepEqual(
    rows.map((r) => r.present),
    [null, true],
  );
});

test("tideForPath: path is missing (404) but the stage itself does not exist either → present is null", async () => {
  const api = async (path) => {
    const e = new Error("HTTP 404");
    e.status = 404;
    if (path.startsWith("repos/o/r/commits/main")) return { sha: "x" };
    throw e;
  };
  const rows = await tideForPath(api, "o/r", "a.js", [
    { label: "nope", ref: "nope" },
    { label: "main", ref: "main" },
  ]);
  assert.deepEqual(
    rows.map((r) => r.present),
    [null, false],
  );
});

test("describeSubject: says whether the merge commit or the head commit is checked", () => {
  assert.equal(
    describeSubject({ number: 7, title: "T", state: "open", merged_at: null, merge_commit_sha: "m", head: { sha: "abcdef1234" } }).note,
    "PR #7 open: T\nchecking head commit abcdef1 (not merged yet)",
  );
  const merged = describeSubject({ number: 8, title: "U", state: "closed", merged_at: "2026-10-29", merge_commit_sha: "1234567890", head: { sha: "h" } });
  assert.equal(merged.sha, "1234567890");
  assert.equal(merged.note, "PR #8 merged: U\nchecking merge commit 1234567");
});
