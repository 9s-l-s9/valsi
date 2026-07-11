// SPDX-License-Identifier: GPL-3.0-or-later

import { existsSync } from "node:fs";
import { readFile } from "node:fs/promises";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";
import { AAPClient } from "./aap-client.mjs";

const extensionDirectory = dirname(fileURLToPath(import.meta.url));
const installedLispDirectory = resolve(extensionDirectory, "..");
const sourceLispDirectory = resolve(extensionDirectory, "..", "..", "lisp");
const lispDirectory =
	process.env.Valsi_AAP_LISP_DIRECTORY ??
	(existsSync(resolve(installedLispDirectory, "valsi-server.el"))
		? installedLispDirectory
		: sourceLispDirectory);

function result(value: unknown) {
	return {
		content: [{ type: "text" as const, text: JSON.stringify(value, null, 2) }],
		details: value,
	};
}

/** Register the deliberately small read-only Pi→AAP artifact seam. */
export function registerAAPTools(pi: ExtensionAPI) {
	let client: AAPClient | undefined;
	const connection = () => {
		client ??= new AAPClient(process.env.Valsi_AAP_EMACS ?? "emacs", [
			"-Q",
			"--batch",
			"-L",
			lispDirectory,
			"-l",
			"valsi-server",
			"-f",
			"valsi-server-stdio",
		]);
		return client;
	};

	pi.on("session_shutdown", async () => {
		client?.close();
		client = undefined;
	});

	pi.registerTool({
		name: "valsi_artifact",
		label: "Valsi Artifact",
		description:
			"Read grammar-aware capabilities, symbols, or task context from a markdown artifact.",
		promptSnippet:
			"Inspect plan/instruction artifacts through Valsi's semantic grammar.",
		parameters: Type.Object({
			action: Type.Union([
				Type.Literal("capabilities"),
				Type.Literal("symbols"),
				Type.Literal("plan_context"),
			]),
			path: Type.String({ description: "Artifact path relative to the project" }),
			taskId: Type.Optional(
				Type.String({ description: "Task id required for plan_context" }),
			),
		}),
		executionMode: "parallel",
		async execute(_id, params, signal, _onUpdate, ctx) {
			const path = resolve(ctx.cwd, params.path);
			const text = await readFile(path, "utf8");
			const aap = connection();
			await aap.request("artifact/didOpen", { uri: path, text }, signal);
			const method =
				params.action === "capabilities"
					? "artifact/capabilities"
					: params.action === "symbols"
						? "artifact/symbols"
						: "artifact/planContext";
			if (params.action === "plan_context" && !params.taskId) {
				throw new Error("taskId is required for plan_context");
			}
			return result(
				await aap.request(
					method,
					{ uri: path, ...(params.taskId ? { taskId: params.taskId } : {}) },
					signal,
				),
			);
		},
	});
}
