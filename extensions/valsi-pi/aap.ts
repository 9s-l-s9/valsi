// SPDX-License-Identifier: GPL-3.0-or-later

import { existsSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";
import { AAPClient, aapConnection } from "./aap-client.mjs";
import { aapEnvironment, queryArtifact, SYMBOL_MAX_NODES } from "./artifact-tool.mjs";

const extensionDirectory = dirname(fileURLToPath(import.meta.url));
const installedLispDirectory = resolve(extensionDirectory, "..");
const sourceLispDirectory = resolve(extensionDirectory, "..", "..", "lisp");
const environment = aapEnvironment();
const lispDirectory =
	environment.lispDirectory ??
	(existsSync(resolve(installedLispDirectory, "valsi-server.el"))
		? installedLispDirectory
		: sourceLispDirectory);

/** Register the deliberately small read-only Pi→AAP artifact seam. */
export function registerAAPTools(pi: ExtensionAPI) {
	// Reuse the process, but release each document after its query.
	const connection = aapConnection(
		() =>
			new AAPClient(environment.emacs, [
				"-Q",
				"--batch",
				"-L",
				lispDirectory,
				"-l",
				"valsi-server",
				"-f",
				"valsi-server-stdio",
			]),
	);

	pi.on("session_shutdown", async () => {
		connection.close();
	});

	pi.registerTool({
		name: "valsi_artifact",
		label: "Valsi Artifact",
		description:
			"Read capabilities, bounded symbols, or task context from a project markdown artifact. Use maxDepth or nodeTypes to narrow symbols.",
		promptSnippet:
			"Inspect plan/instruction artifacts through Valsi's semantic grammar.",
		parameters: Type.Object({
			action: Type.Union([
				Type.Literal("capabilities"),
				Type.Literal("symbols"),
				Type.Literal("plan_context"),
			]),
			path: Type.String({
				description: "Artifact path relative to the project; must stay inside it, including symlinks",
			}),
			taskId: Type.Optional(
				Type.String({ description: "Task id required for plan_context" }),
			),
			maxDepth: Type.Optional(Type.Integer({
				minimum: 0, maximum: 64,
				description: "Symbols: maximum tree depth (root is 0)",
			})),
			nodeTypes: Type.Optional(Type.Array(Type.String({ minLength: 1 }), {
				description: "Symbols: include only these node types (for example task)",
			})),
			maxNodes: Type.Optional(Type.Integer({
				minimum: 1, maximum: SYMBOL_MAX_NODES,
				description: "Symbols: maximum nodes (default 200), also capped at 32 KiB",
			})),
		}),
		executionMode: "parallel",
		async execute(_id, params, signal, _onUpdate, ctx) {
			return queryArtifact(connection, ctx.cwd, params, signal);
		},
	});
}
