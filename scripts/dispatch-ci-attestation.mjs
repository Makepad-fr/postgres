#!/usr/bin/env node
import { sign } from "node:crypto";
import { readFile } from "node:fs/promises";
import process from "node:process";
import { canonicalJSON } from "./publish-pr-ci-check.mjs";

const evidencePath = process.env.POSTGRES_CI_ATTESTATION_JSON_FILE;
const privateKeyPath = process.env.POSTGRES_CI_ATTESTATION_PRIVATE_KEY_FILE;
if (!evidencePath?.startsWith("/") || !privateKeyPath?.startsWith("/")) throw new Error("absolute attestation and private-key paths are required");
const [source, privateKey] = await Promise.all([readFile(evidencePath, "utf8"), readFile(privateKeyPath, "utf8")]);
const attestation = JSON.parse(source);
const canonical = canonicalJSON(attestation);
if (`${canonical}\n` !== source && canonical !== source) throw new Error("attestation file is not canonical JSON");

let token = "";
for await (const chunk of process.stdin) token += chunk;
token = token.trim();
if (!/^ghs_[A-Za-z0-9_]{20,}$/.test(token)) throw new Error("a dedicated Launcher App installation token is required on stdin");
const signature = sign(null, Buffer.from(canonical), privateKey).toString("base64url");
const response = await fetch("https://api.github.com/repos/Makepad-fr/postgres/dispatches", {
  method: "POST",
  headers: {
    Accept: "application/vnd.github+json",
    Authorization: `Bearer ${token}`,
    "Content-Type": "application/json",
    "User-Agent": "makepad-postgres-ci-launcher",
    "X-GitHub-Api-Version": "2022-11-28",
  },
  body: JSON.stringify({event_type: "postgres-pr-ci-attestation", client_payload: {attestation, signature}}),
  redirect: "error",
  signal: AbortSignal.timeout(30_000),
});
token = "";
if (response.status !== 204) throw new Error(`Launcher App attestation dispatch failed with ${response.status}`);
process.stdout.write(`Dispatched signed teardown attestation for run ${attestation.run.id}, attempt ${attestation.run.attempt}.\n`);
