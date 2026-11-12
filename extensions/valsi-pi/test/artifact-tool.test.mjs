// SPDX-License-Identifier: GPL-3.0-or-later

import assert from "node:assert/strict";
import { mkdtemp, mkdir, writeFile, symlink, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { aapEnvironment, artifactPath, queryArtifact, symbolResult, SYMBOL_MAX_BYTES } from "../artifact-tool.mjs";

test("artifact paths stay in the canonical project, including symlink targets", async () => {
	const tmp = await mkdtemp(join(tmpdir(), "valsi-path-"));
	try {
		const root = join(tmp, "project");
		await mkdir(root);
		await writeFile(join(root, "PLAN.md"), "# Plan\n");
		await writeFile(join(tmp, "private.md"), "outside");
		await symlink(root, join(tmp, "alias"));
		await symlink("PLAN.md", join(root, "inside.md"));
		await symlink("../private.md", join(root, "outside.md"));
		assert.equal(await artifactPath(root, "inside.md"), join(root, "PLAN.md"));
		assert.equal(await artifactPath(join(tmp, "alias"), "PLAN.md"), join(root, "PLAN.md"));
		for (const path of ["../private.md", "../project-other/file.md", "outside.md", join(root, "PLAN.md"), ""]) {
			await assert.rejects(artifactPath(root, path), /relative|leaves the project/);
		}
	} finally { await rm(tmp, { recursive: true, force: true }); }
});

test("invalid query arguments fail before file access or connection creation", async () => {
	const connect = () => { assert.fail("connection must not be opened"); };
	for (const taskId of [undefined, "", "   "]) {
		await assert.rejects(queryArtifact(connect, "/missing", {
			action: "plan_context", path: "missing.md", taskId,
		}), /taskId is required/);
	}
	for (const limits of [{ maxDepth: -1 }, { maxDepth: 0.5 }, { maxDepth: 65 },
		{ maxNodes: 0 }, { maxNodes: 501 }]) {
		await assert.rejects(queryArtifact(connect, "/missing", {
			action: "symbols", path: "missing.md", ...limits,
		}), /must be an integer/);
	}
});

test("symbols are compact, bounded in UTF-8, and report truncation", () => {
	const tree = { type: "document", props: {}, children: Array.from({ length: 10_000 },
		(_, id) => ({ type: "task", beg: id, end: id + 1,
			props: { id: `T${id}`, title: "🐈".repeat(70) }, children: [] })) };
	const result = symbolResult(tree, { maxNodes: 500 });
	assert.ok(result.nodes.length > 1 && result.nodes.length < 500);
	assert.equal(result.truncated, true);
	assert.match(result.notice, /truncated; narrow/);
	assert.ok(Buffer.byteLength(JSON.stringify(result), "utf8") <= SYMBOL_MAX_BYTES);
	assert.ok(result.nodes.every(node => !Object.hasOwn(node, "children")));
	assert.deepEqual(symbolResult(null), { nodes: [], truncated: false });
	assert.equal(symbolResult({ type: "document", props: { huge: "x".repeat(50_000) } }).truncated, true);
});

test("depth/type filters preserve document order and explicit node limits", () => {
	const tree = { type: "document", children: [
		{ type: "section", children: [{ type: "task", props: { id: "T1" }, children: [] }] },
		{ type: "task", props: { id: "T2" }, children: [] },
	] };
	assert.deepEqual(symbolResult(tree, { maxDepth: 0 }).nodes.map(n => n.type), ["document"]);
	const tasks = symbolResult(tree, { nodeTypes: ["task"] });
	assert.deepEqual(tasks.nodes.map(n => [n.props.id, n.depth]), [["T1", 2], ["T2", 1]]);
	assert.equal(tasks.truncated, false);
	assert.deepEqual(symbolResult(tree, { maxDepth: 1, nodeTypes: ["task"] }).nodes.map(n => n.props.id), ["T2"]);
	assert.equal(symbolResult(tree, { nodeTypes: ["task"], maxNodes: 1 }).truncated, true);
});

test("uppercase AAP configuration wins and legacy spellings remain supported", () => {
	assert.deepEqual(aapEnvironment({}), { emacs: "emacs", lispDirectory: undefined });
	assert.deepEqual(aapEnvironment({ Valsi_AAP_EMACS: "old", Valsi_AAP_LISP_DIRECTORY: "/old" }),
		{ emacs: "old", lispDirectory: "/old" });
	assert.deepEqual(aapEnvironment({ VALSI_AAP_EMACS: "new", VALSI_AAP_LISP_DIRECTORY: "/new",
		Valsi_AAP_EMACS: "old", Valsi_AAP_LISP_DIRECTORY: "/old" }),
		{ emacs: "new", lispDirectory: "/new" });
});
