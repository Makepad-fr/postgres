import assert from "node:assert/strict";
import {readFile} from "node:fs/promises";
import path from "node:path";
import test from "node:test";
import {fileURLToPath, pathToFileURL} from "node:url";

const candidateRoot = path.resolve(process.env.POSTGRES_CANDIDATE_ROOT || fileURLToPath(new URL("..", import.meta.url)));
const controllerURL = pathToFileURL(path.join(candidateRoot, "scripts/postgres-ci-queue-controller.mjs"));
const {reconcileIncompleteJobs, selectAuthorizedJobs} = await import(controllerURL.href);
const launcherURL = pathToFileURL(path.join(candidateRoot, "scripts/run-postgres-ci-jit-vm.sh"));

const repositoryID = 77;
const prBase = () => {
  const association = {number: 9, head: {sha: "a".repeat(40), repo: {id: repositoryID}}, base: {ref: "main", sha: "b".repeat(40), repo: {id: repositoryID}}};
  const run = {id: 101, run_attempt: 2, name: "CI", path: ".github/workflows/ci.yml", event: "pull_request_target", status: "queued", head_sha: "b".repeat(40), repository: {id: repositoryID}, pull_requests: [association]};
  const job = {id: 202, run_id: 101, head_sha: "b".repeat(40), workflow_name: "CI", name: "policy-and-integration", status: "queued", labels: ["self-hosted", "linux", "x64", "makepad-postgres-pr-ephemeral"]};
  return {
    runs: {total_count: 1, workflow_runs: [run]},
    jobsByRun: new Map([["101:2", {total_count: 1, jobs: [job]}]]),
    pullRequests: new Map([[9, {number: 9, head: {sha: "a".repeat(40), repo: {id: repositoryID}}, base: {ref: "main", sha: "b".repeat(40), repo: {id: repositoryID}}}]]),
  };
};

test("selects the exact queued protected-base same-repository PR job without relying on a nonexistent job attempt field", () => {
  assert.deepEqual(selectAuthorizedJobs({...prBase(), repositoryID}), [{runID: 101, attempt: 2, jobID: 202, event: "pull_request_target", sourceSHA: "a".repeat(40), workflowSHA: "b".repeat(40), pullRequestNumber: 9}]);
});

test("selects an exact protected-main push job so release CI cannot remain queued", () => {
  const value = prBase();
  const run = value.runs.workflow_runs[0];
  run.event = "push";
  run.head_branch = "main";
  run.pull_requests = [];
  value.pullRequests.clear();
  assert.deepEqual(selectAuthorizedJobs({...value, repositoryID}), [{runID: 101, attempt: 2, jobID: 202, event: "push", sourceSHA: "b".repeat(40), workflowSHA: "b".repeat(40), pullRequestNumber: null}]);
});

test("rejects fork, wrong workflow, extra-label, moved-head, and non-queued jobs", () => {
  for (const mutate of [
    (value) => { value.runs.workflow_runs[0].pull_requests[0].head.repo.id = 999; },
    (value) => { value.runs.workflow_runs[0].path = ".github/workflows/evil.yml"; },
    (value) => { value.jobsByRun.get("101:2").jobs[0].labels.push("persistent"); },
    (value) => { value.pullRequests.get(9).head.sha = "b".repeat(40); },
    (value) => { value.runs.workflow_runs[0].pull_requests[0].base.sha = "d".repeat(40); },
    (value) => { value.jobsByRun.get("101:2").jobs[0].status = "in_progress"; },
  ]) {
    const value = prBase();
    mutate(value);
    assert.deepEqual(selectAuthorizedJobs({...value, repositoryID}), []);
  }
});

test("rejects a non-main push, mismatched job head, and wrong job workflow", () => {
  for (const mutate of [
    (value) => { value.runs.workflow_runs[0].head_branch = "feature"; },
    (value) => { value.jobsByRun.get("101:2").jobs[0].head_sha = "c".repeat(40); },
    (value) => { value.jobsByRun.get("101:2").jobs[0].workflow_name = "Other"; },
  ]) {
    const value = prBase();
    value.runs.workflow_runs[0].event = "push";
    value.runs.workflow_runs[0].head_branch = "main";
    value.runs.workflow_runs[0].pull_requests = [];
    mutate(value);
    assert.deepEqual(selectAuthorizedJobs({...value, repositoryID}), []);
  }
});

test("the durable controller records deterministic resources before launch and never selects recorded IDs again", async () => {
  const source = await readFile(controllerURL, "utf8");
  assert.match(source, /state\.jobs\[String\(job\.jobID\)\] = \{\.\.\.job, nonce, launchID, status: "launching"/);
  assert.match(source, /filter\(\(job\) => !state\.jobs\[String\(job\.jobID\)\]\)/);
  assert.match(source, /await runLauncher/);
  assert.match(source, /issues/);
  const launcherFailure = source.indexOf("// Any nonzero launcher exit is cleanup-uncertain.");
  const failed = source.indexOf('status = "recovery-required"', launcherFailure);
  const persisted = source.indexOf("await atomicState(stateFile, state);", failed);
  const issue = source.indexOf("/issues", failed);
  const rethrow = source.indexOf("throw error;", failed);
  assert.ok(launcherFailure > 0 && launcherFailure < failed && failed < persisted && persisted < issue && issue < rethrow);
  assert.match(source, /systemd OnFailure webhook remains independent of GitHub/);
  assert.match(source, /pull_requests: "read"/);
  assert.match(source, /await reconcileIncompleteJobs/);
  assert.doesNotMatch(source, /status = "failed"/);
});

test("startup reconciliation marks every incomplete launch failed-recovered and persists each transition", async () => {
  const state = {version: 2, jobs: {
    "202": {status: "launching", launchID: "j202-1111111111111111"},
    "203": {status: "recovery-required", launchID: "j203-2222222222222222"},
    "204": {status: "completed", launchID: "j204-3333333333333333"},
  }};
  const reconciled = [];
  let persisted = 0;
  await reconcileIncompleteJobs({state, persist: async () => { persisted += 1; }, reconcile: async (record) => { reconciled.push(record.launchID); }});
  assert.deepEqual(reconciled, ["j202-1111111111111111", "j203-2222222222222222"]);
  assert.equal(persisted, 2);
  assert.equal(state.jobs["202"].status, "failed-recovered");
  assert.equal(state.jobs["203"].status, "failed-recovered");
});

test("failed startup reconciliation stays recovery-required and blocks polling", async () => {
  const state = {version: 2, jobs: {"202": {status: "launching", launchID: "j202-1111111111111111"}}};
  await assert.rejects(reconcileIncompleteJobs({state, persist: async () => {}, reconcile: async () => { throw new Error("still present"); }}), /still present/);
  assert.equal(state.jobs["202"].status, "recovery-required");
});

test("the hypervisor signs only after every disposable resource and registration is proven absent", async () => {
  const source = await readFile(launcherURL, "utf8");
  const vmRemoval = source.indexOf('virsh undefine "${vm_name}"');
  const firewallRemoval = source.indexOf('nft delete table inet "${nft_table}"');
  const networkRemoval = source.indexOf('virsh net-undefine "${network_name}"');
  const registrationRemoval = source.indexOf('actions/runners/${runner_id}');
  const absenceCheck = source.indexOf('remaining_runner_ids=');
  const teardownGate = source.indexOf('"${attestation_eligible}" == true && "${cleanup_failed}" == false');
  const signingDispatch = source.indexOf('node "${script_directory}/dispatch-ci-attestation.mjs"', teardownGate);
  assert.ok(vmRemoval > 0 && firewallRemoval > vmRemoval && networkRemoval > firewallRemoval);
  assert.ok(registrationRemoval > 0 && absenceCheck > registrationRemoval);
  assert.ok(teardownGate > absenceCheck && signingDispatch > teardownGate);
  assert.equal((source.match(/generate-jitconfig/g) || []).length, 2); // API endpoint and explanatory comment.
  assert.match(source, /run\.sh --jitconfig/);
  assert.match(source, /resources\.json/);
  assert.match(source, /--reconcile/);
  assert.match(source, /POSTGRES_CI_RESULT_POLL_ATTEMPTS/);
  assert.match(source, /repository\.get\("private"\) is not False/);
  assert.match(source, /group\.get\("allows_public_repositories"\) is not True/);
});
