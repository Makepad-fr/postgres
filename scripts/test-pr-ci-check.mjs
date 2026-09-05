import assert from "node:assert/strict";
import { generateKeyPairSync, sign } from "node:crypto";
import path from "node:path";
import test from "node:test";
import {fileURLToPath, pathToFileURL} from "node:url";

const candidateRoot = path.resolve(process.env.POSTGRES_CANDIDATE_ROOT || fileURLToPath(new URL("..", import.meta.url)));
const {
  assertNoAttestationReplay,
  canonicalJSON,
  validateAuthoritativeEvidence,
  verifySignedAttestation,
} = await import(pathToFileURL(path.join(candidateRoot, "scripts/publish-pr-ci-check.mjs")).href);

const now = new Date("2026-09-05T10:00:00Z");
const digest = "a".repeat(64);
const {privateKey, publicKey} = generateKeyPairSync("ed25519");

const baseAttestation = () => ({
  base_image_sha256: digest,
  issued_at: now.toISOString().replace(".000Z", "Z"),
  nonce: "A".repeat(43),
  ref: "refs/heads/main",
  registration_absent: true,
  repository: "Makepad-fr/postgres",
  run: {attempt: 2, conclusion: "success", event: "pull_request_target", head_sha: "b".repeat(40), workflow_sha: "c".repeat(40), id: 1234, job_id: 5678, job_name: "policy-and-integration"},
  runner: {group_id: 12, group_name: "Postgres PR Ephemeral", id: 44, labels: ["self-hosted", "linux", "x64", "makepad-postgres-pr-ephemeral"], name: "postgres-ci-jit-20260905100000-deadbeef"},
  schema: "makepad.postgres.ci-attestation.v1",
  teardown: {disk: true, firewall: true, network: true, vm: true},
  workflow: {name: "CI", path: ".github/workflows/ci.yml"},
});

const signedEvent = (attestation = baseAttestation(), senderID = 9001) => ({
  action: "postgres-pr-ci-attestation",
  repository: {full_name: "Makepad-fr/postgres"},
  sender: {id: senderID, type: "Bot"},
  client_payload: {
    attestation,
    signature: sign(null, Buffer.from(canonicalJSON(attestation)), privateKey).toString("base64url"),
  },
});

const verify = (event, overrides = {}) => verifySignedAttestation({event, publicKey, approvedDigest: digest, launcherSenderID: "9001", now, ...overrides});

const authoritative = (attestation = baseAttestation()) => {
  const job = {
    id: 5678,
    run_id: 1234,
    head_sha: "c".repeat(40),
    workflow_name: "CI",
    name: "policy-and-integration",
    status: "completed",
    conclusion: attestation.run.conclusion,
    runner_id: 44,
    runner_name: "postgres-ci-jit-20260905100000-deadbeef",
    runner_group_id: 12,
    runner_group_name: "Postgres PR Ephemeral",
    labels: ["self-hosted", "linux", "x64", "makepad-postgres-pr-ephemeral"],
  };
  const association = {number: 7, head: {sha: "b".repeat(40), repo: {id: 88}}, base: {ref: "main", sha: "c".repeat(40), repo: {id: 88}}};
  return {
    attestation,
    run: {id: 1234, run_attempt: 2, event: attestation.run.event, head_sha: attestation.run.workflow_sha, head_branch: "main", path: ".github/workflows/ci.yml", name: "CI", status: "completed", conclusion: attestation.run.conclusion, repository: {id: 88, full_name: "Makepad-fr/postgres"}, pull_requests: [association], html_url: "https://github.example/run/1234"},
    jobs: {total_count: 1, jobs: [job]},
    job,
    pullRequest: {number: 7, head: {sha: "b".repeat(40), repo: {full_name: "Makepad-fr/postgres"}}, base: {ref: "main", sha: "c".repeat(40), repo: {full_name: "Makepad-fr/postgres"}}},
    runnerLookupStatus: 404,
  };
};

test("accepts fresh hypervisor-signed teardown evidence from immutable Launcher App sender", () => {
  assert.equal(verify(signedEvent()).run.job_id, 5678);
});

test("rejects forged evidence", () => {
  const event = signedEvent();
  event.client_payload.attestation.run.head_sha = "c".repeat(40);
  assert.throws(() => verify(event), /signature verification failed/);
});

test("rejects stale evidence", () => {
  const attestation = baseAttestation();
  attestation.issued_at = "2026-09-05T09:40:00Z";
  assert.throws(() => verify(signedEvent(attestation)), /stale or from the future/);
});

test("rejects an unapproved base image digest", () => {
  assert.throws(() => verify(signedEvent(), {approvedDigest: "c".repeat(64)}), /not approved/);
});

test("rejects incomplete hypervisor teardown", () => {
  const attestation = baseAttestation();
  attestation.teardown.network = false;
  assert.throws(() => verify(signedEvent(attestation)), /teardown is incomplete/);
});

test("rejects mutable sender-name forgery with the wrong numeric App sender ID", () => {
  assert.throws(() => verify(signedEvent(baseAttestation(), 9002)), /dedicated Launcher App/);
});

test("rejects authoritative runner mismatch and a still-registered runner", () => {
  const mismatch = authoritative();
  mismatch.job.runner_id = 45;
  assert.throws(() => validateAuthoritativeEvidence(mismatch), /runner identity differs/);
  const registered = authoritative();
  registered.runnerLookupStatus = 200;
  assert.throws(() => validateAuthoritativeEvidence(registered), /still registered/);
  const noListAuthority = authoritative();
  noListAuthority.runnerListStatus = 403;
  assert.throws(() => validateAuthoritativeEvidence(noListAuthority), /absence is uncertain/);
});

test("accepts a failing test result only as a failing check after verified teardown", () => {
  const attestation = baseAttestation();
  attestation.run.conclusion = "failure";
  const verified = validateAuthoritativeEvidence(authoritative(attestation));
  assert.equal(verified.conclusion, "failure");
});

test("accepts protected-main push evidence only when source and workflow SHAs match", () => {
  const attestation = baseAttestation();
  attestation.run.event = "push";
  attestation.run.head_sha = attestation.run.workflow_sha;
  const evidence = authoritative(attestation);
  evidence.run.pull_requests = [];
  evidence.pullRequest = null;
  const verified = validateAuthoritativeEvidence(evidence);
  assert.equal(verified.event, "push");
  const mismatch = baseAttestation();
  mismatch.run.event = "push";
  assert.throws(() => verify(signedEvent(mismatch)), /identity or conclusion is invalid/);
});

test("rejects an authoritative workflow execution SHA mismatch", () => {
  const evidence = authoritative();
  evidence.job.head_sha = "d".repeat(40);
  assert.throws(() => validateAuthoritativeEvidence(evidence), /runner identity differs/);
});

test("rejects a pull association whose exact base SHA differs from the workflow SHA", () => {
  const evidence = authoritative();
  evidence.run.pull_requests[0].base.sha = "d".repeat(40);
  assert.throws(() => validateAuthoritativeEvidence(evidence), /head and base identities/);
});

test("rejects replay for the same run attempt and Checks App", () => {
  assert.throws(() => assertNoAttestationReplay({
    appID: "500",
    prefix: "postgres-ci:pull_request_target:1234:2:",
    existing: {total_count: 1, check_runs: [{app: {id: 500}, external_id: `postgres-ci:pull_request_target:1234:2:${"A".repeat(43)}`}]},
  }), /replay detected/);
});
