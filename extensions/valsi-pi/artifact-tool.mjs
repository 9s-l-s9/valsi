// SPDX-License-Identifier: GPL-3.0-or-later

import { readFile, realpath } from "node:fs/promises";
import { isAbsolute, relative, resolve, sep } from "node:path";

export const SYMBOL_MAX_BYTES = 32_768;
export const SYMBOL_MAX_NODES = 500;

function outside(root, path) {
	const rel = relative(root, path);
	return rel === ".." || rel.startsWith(`..${sep}`) || isAbsolute(rel);
}

/** Resolve a project-relative artifact, rejecting lexical and symlink escapes. */
export async function artifactPath(cwd, path) {
	if (typeof path !== "string" || !path || isAbsolute(path)) {
		throw new Error("path must be relative to the project");
	}
	const root = resolve(cwd);
	const target = resolve(root, path);
	if (outside(root, target)) throw new Error("path leaves the project");
	const [realRoot, realTarget] = await Promise.all([realpath(root), realpath(target)]);
	if (outside(realRoot, realTarget)) throw new Error("path symlink leaves the project");
	return realTarget;
}

/** Standard uppercase environment names take precedence over legacy names. */
export function aapEnvironment(env = process.env) {
	return {
		emacs: env.VALSI_AAP_EMACS ?? env.Valsi_AAP_EMACS ?? "emacs",
		lispDirectory: env.VALSI_AAP_LISP_DIRECTORY ?? env.Valsi_AAP_LISP_DIRECTORY,
	};
}

/** Flatten symbols in document order while bounding the entire tool result. */
export function symbolResult(tree, { maxDepth, nodeTypes, maxNodes = 200 } = {}) {
	const types = nodeTypes?.length ? new Set(nodeTypes) : undefined;
	const nodes = [];
	const stack = tree ? [{ node: tree, depth: 0 }] : [];
	// Reserve room for the envelope and truncation notice, including UTF-8.
	let bytes = 256;
	let truncated = false;
	while (stack.length) {
		const { node, depth } = stack.pop();
		if (!types || types.has(node.type)) {
			const { children, ...fields } = node;
			const entry = { ...fields, depth };
			const size = Buffer.byteLength(JSON.stringify(entry), "utf8") + 1;
			if (nodes.length >= maxNodes || bytes + size > SYMBOL_MAX_BYTES) {
				truncated = true;
				break;
			}
			nodes.push(entry);
			bytes += size;
		}
		if (maxDepth === undefined || depth < maxDepth) {
			for (let i = (node.children?.length ?? 0) - 1; i >= 0; i--) {
				stack.push({ node: node.children[i], depth: depth + 1 });
			}
		}
	}
	return {
		nodes,
		truncated,
		...(truncated ? { notice: "Symbols truncated; narrow the query with maxDepth or nodeTypes." } : {}),
	};
}

/** Validate before reading, then query and release the server's document. */
export async function queryArtifact(connection, cwd, params, signal) {
	if (!["capabilities", "symbols", "plan_context"].includes(params.action)) {
		throw new Error("Unknown artifact action");
	}
	if (params.action === "plan_context" && !params.taskId?.trim()) {
		throw new Error("taskId is required for plan_context");
	}
	if (params.maxDepth !== undefined &&
		(!Number.isInteger(params.maxDepth) || params.maxDepth < 0 || params.maxDepth > 64)) {
		throw new Error("maxDepth must be an integer from 0 to 64");
	}
	if (params.maxNodes !== undefined &&
		(!Number.isInteger(params.maxNodes) || params.maxNodes < 1 || params.maxNodes > SYMBOL_MAX_NODES)) {
		throw new Error(`maxNodes must be an integer from 1 to ${SYMBOL_MAX_NODES}`);
	}
	signal?.throwIfAborted();
	const path = await artifactPath(cwd, params.path);
	const text = await readFile(path, { encoding: "utf8", signal });
	const aap = connection();
	const method = {
		capabilities: "artifact/capabilities", symbols: "artifact/symbols",
		plan_context: "artifact/planContext",
	}[params.action];
	const value = await aap.withDocument(path, text,
		(client) => client.request(method, {
			uri: path, ...(params.taskId ? { taskId: params.taskId } : {}),
		}, signal), signal);
	const details = params.action === "symbols" ? symbolResult(value, params) : value;
	return { content: [{ type: "text", text: JSON.stringify(details) }], details };
}
