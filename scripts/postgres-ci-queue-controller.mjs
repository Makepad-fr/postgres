#!/usr/bin/env node
import crypto, { createSign } from "node:crypto";
import { spawn } from "node:child_process";
import { lstat, mkdir, readFile, realpath, rename, writeFile } from "node:fs/promises";
import path from "node:path";
import { pathToFileURL } from "node:url";

const REPOSITORY = "Makepad-fr/postgres";
const WORKFLOW_PATH = ".github/workflows/ci.yml";
const LABELS = ["self-hosted", "linux", "x64", "makepad-postgres-pr-ephemeral"];

const required = (name, env = process.env) => {
  const value = env[name]?.trim();
  if (!value) throw new Error(`${name} is required`);
  return value;
};

const github = async ({ token, method = "GET", endpoint, body, fetchImpl = fetch }) => {
  const response = await fetchImpl(`https://api.github.com${endpoint}`, {
    method,
    headers: {Accept: "application/vnd.github+json", Authorization: `Bearer ${token}`, "Content-Type": "application/json", "User-Agent": "makepad-postgres-ci-controller", "X-GitHub-Api-Version": "2022-11-28"},
    body: body === undefined ? undefined : JSON.stringify(body),
    redirect: "error",
    signal: AbortSignal.timeout(30_000),
  });
  const text = await response.text();
  let payload = {};
  if (text) payload = JSON.parse(text);
  if (!response.ok) throw new Error(`GitHub ${method} ${endpoint} failed with ${response.status}`);
  return payload;
};

const appJWT = ({appID, key, now = Date.now()}) => {
  if (!/^[1-9]\d*$/.test(appID)) throw new Error("Launcher App ID must be numeric");
  const issued = Math.floor(now / 1000) - 60;
  const encode = (value) => Buffer.from(JSON.stringify(value)).toString("base64url");
  const unsigned = `${encode({alg: "RS256", typ: "JWT"})}.${encode({iat: issued, exp: issued + 540, iss: appID})}`;
  const signer = createSign("RSA-SHA256");
  signer.update(unsigned);
  signer.end();
  return `${unsigned}.${signer.sign(key, "base64url")}`;
};

export const selectAuthorizedJobs = ({ runs, jobsByRun, pullRequests, repositoryID }) => {
  if (!Array.isArray(runs.workflow_runs) || runs.total_count !== runs.workflow_runs.length) throw new Error("workflow-run response is truncated");
  const selected = [];
  for (const run of runs.workflow_runs) {
    if (!Number.isSafeInteger(run.id) || run.id <= 0 || !Number.isSafeInteger(run.run_attempt) || run.run_attempt <= 0) continue;
    const associations = Array.isArray(run.pull_requests) ? run.pull_requests : [];
    if (run.name !== "CI" || run.path !== WORKFLOW_PATH || run.status !== "queued" || run.repository?.id !== repositoryID || !/^[a-f0-9]{40}$/.test(run.head_sha || "")) continue;
    let sourceSHA;
    let pullRequestNumber = null;
    if (run.event === "pull_request_target") {
      if (associations.length !== 1 || !Number.isSafeInteger(associations[0]?.number)) continue;
      const association = associations[0];
      const pull = pullRequests.get(association.number);
      if (association.head?.repo?.id !== repositoryID || association.base?.repo?.id !== repositoryID || association.base?.ref !== "main" || association.base?.sha !== run.head_sha || !/^[a-f0-9]{40}$/.test(association.head?.sha || "") || pull?.number !== association.number || pull?.head?.sha !== association.head?.sha || pull?.head?.repo?.id !== repositoryID || pull?.base?.repo?.id !== repositoryID || pull?.base?.ref !== "main" || pull?.base?.sha !== run.head_sha) continue;
      sourceSHA = association.head.sha;
      pullRequestNumber = association.number;
    } else if (run.event === "push") {
      if (run.head_branch !== "main") continue;
      sourceSHA = run.head_sha;
    } else {
      continue;
    }
    const response = jobsByRun.get(`${run.id}:${run.run_attempt}`);
    if (!response || !Array.isArray(response.jobs) || response.total_count !== response.jobs.length) throw new Error("workflow-job response is missing or truncated");
    for (const job of response.jobs) {
      const labels = Array.isArray(job.labels) ? job.labels.map((value) => String(value).toLowerCase()).sort() : [];
      if (Number.isSafeInteger(job.id) && job.id > 0 && job.name === "policy-and-integration" && job.status === "queued" && job.run_id === run.id && job.head_sha === run.head_sha && job.workflow_name === "CI" && labels.length === LABELS.length && labels.every((value, index) => value === [...LABELS].sort()[index])) {
        selected.push({runID: run.id, attempt: run.run_attempt, jobID: job.id, event: run.event, sourceSHA, workflowSHA: run.head_sha, pullRequestNumber});
      }
    }
  }
  return selected.sort((left, right) => left.jobID - right.jobID);
};

const atomicState = async (file, state) => {
  const incoming = `${file}.incoming-${process.pid}-${crypto.randomBytes(8).toString("hex")}`;
  await writeFile(incoming, `${JSON.stringify(state, null, 2)}\n`, {mode: 0o600, flag: "wx"});
  await rename(incoming, file);
};

const runLauncher = ({launcher, token, metadata, environment, arguments: launcherArguments = []}) => new Promise((resolve, reject) => {
  const child = spawn(launcher, launcherArguments, {
    env: {...environment, POSTGRES_CI_RUN_ID: String(metadata.runID || ""), POSTGRES_CI_RUN_ATTEMPT: String(metadata.attempt || ""), POSTGRES_CI_JOB_ID: String(metadata.jobID || ""), POSTGRES_CI_RUN_EVENT: metadata.event || "", POSTGRES_CI_HEAD_SHA: metadata.sourceSHA || "", POSTGRES_CI_WORKFLOW_SHA: metadata.workflowSHA || "", POSTGRES_CI_ATTESTATION_NONCE: metadata.nonce || "", POSTGRES_CI_LAUNCH_ID: metadata.launchID || ""},
    stdio: ["pipe", "inherit", "inherit"],
  });
  child.stdin.end(`${token}\n`);
  child.once("error", reject);
  child.once("exit", (code, signal) => code === 0 && signal === null ? resolve() : reject(new Error(`launcher exited ${code ?? signal}`)));
});

export const reconcileIncompleteJobs = async ({state, persist, reconcile}) => {
  for (const [jobID, record] of Object.entries(state.jobs).sort(([left], [right]) => Number(left) - Number(right))) {
    if (!record || !["launching", "recovery-required"].includes(record.status)) continue;
    if (!/^j[1-9][0-9]{0,15}-[a-f0-9]{16}$/.test(record.launchID || "")) {
      throw new Error(`incomplete job ${jobID} has no safe deterministic resource manifest`);
    }
    try {
      await reconcile(record);
      record.status = "failed-recovered";
      record.failure = "controller restart reconciled an incomplete disposable launch";
      record.finishedAt = new Date().toISOString();
      await persist();
    } catch (error) {
      record.status = "recovery-required";
      record.failure = error instanceof Error ? error.message.slice(0, 200) : "unknown reconciliation failure";
      await persist();
      throw error;
    }
  }
};

export const controller = async ({environment = process.env, fetchImpl = fetch, once = false} = {}) => {
  if (process.getuid?.() !== 0) throw new Error("queue controller must run as root on the dedicated hypervisor");
  const repositoryID = Number(required("POSTGRES_CI_REPOSITORY_ID", environment));
  const appID = required("POSTGRES_CI_LAUNCHER_APP_ID", environment);
  const installationID = required("POSTGRES_CI_LAUNCHER_APP_INSTALLATION_ID", environment);
  const privateKeyFile = required("POSTGRES_CI_LAUNCHER_APP_PRIVATE_KEY_FILE", environment);
  const stateDirectory = required("POSTGRES_CI_CONTROLLER_STATE_DIRECTORY", environment);
  const launcher = required("POSTGRES_CI_LAUNCHER", environment);
  if (!Number.isSafeInteger(repositoryID) || repositoryID <= 0 || !/^[1-9]\d*$/.test(installationID)) throw new Error("repository and installation IDs must be positive integers");
  if (!/^\/var\/lib\/makepad\/postgres-ci\/[A-Za-z0-9._/-]+$/.test(stateDirectory) || stateDirectory.includes("..") || path.normalize(stateDirectory) !== stateDirectory) throw new Error("controller state directory is outside the root-owned Postgres PR Ephemeral tree");
  for (const [file, expectedMode] of [[privateKeyFile, 0o400], [launcher, 0o755]]) {
    if (!path.isAbsolute(file)) throw new Error(`controller file is not absolute: ${file}`);
    const value = await lstat(file);
    if (!value.isFile() || value.isSymbolicLink() || value.uid !== 0 || (value.mode & 0o777) !== expectedMode || await realpath(file) !== file) throw new Error(`insecure controller file: ${file}`);
  }
  const key = await readFile(privateKeyFile, "utf8");
  await mkdir(stateDirectory, {recursive: true, mode: 0o700});
  const directory = await lstat(stateDirectory);
  if (!directory.isDirectory() || directory.isSymbolicLink() || directory.uid !== 0 || (directory.mode & 0o777) !== 0o700 || await realpath(stateDirectory) !== stateDirectory) throw new Error("controller state directory must be a root-only real path");
  const stateFile = path.join(stateDirectory, "jobs.json");
  let state = {version: 2, jobs: {}};
  try { state = JSON.parse(await readFile(stateFile, "utf8")); } catch (error) { if (error.code !== "ENOENT") throw error; }
  if (state.version === 1 && state.jobs && typeof state.jobs === "object") {
    if (Object.values(state.jobs).some((record) => record?.status === "launching")) throw new Error("legacy controller state contains an unreconciled launch; operator recovery is required");
    state = {version: 2, jobs: state.jobs};
    await atomicState(stateFile, state);
  }
  if (state.version !== 2 || !state.jobs || typeof state.jobs !== "object" || Array.isArray(state.jobs)) throw new Error("controller state is invalid");

  do {
    const jwt = appJWT({appID, key});
    const installation = await github({token: jwt, method: "POST", endpoint: `/app/installations/${installationID}/access_tokens`, body: {repositories: ["postgres"], permissions: {actions: "read", contents: "write", issues: "write", organization_self_hosted_runners: "write", pull_requests: "read"}}, fetchImpl});
    const token = installation.token;
    if (typeof token !== "string" || !token.startsWith("ghs_")) throw new Error("Launcher App did not issue an installation token");
    await reconcileIncompleteJobs({
      state,
      persist: () => atomicState(stateFile, state),
      reconcile: (record) => runLauncher({launcher, token, metadata: record, environment, arguments: ["--reconcile", record.launchID]}),
    });
    const runs = await github({token, endpoint: `/repos/${REPOSITORY}/actions/workflows/ci.yml/runs?status=queued&per_page=100`, fetchImpl});
    const jobsByRun = new Map();
    const pullRequests = new Map();
    for (const run of runs.workflow_runs || []) {
      jobsByRun.set(`${run.id}:${run.run_attempt}`, await github({token, endpoint: `/repos/${REPOSITORY}/actions/runs/${run.id}/attempts/${run.run_attempt}/jobs?per_page=100`, fetchImpl}));
      const number = run.pull_requests?.[0]?.number;
      if (Number.isSafeInteger(number) && !pullRequests.has(number)) pullRequests.set(number, await github({token, endpoint: `/repos/${REPOSITORY}/pulls/${number}`, fetchImpl}));
    }
    const pending = selectAuthorizedJobs({runs, jobsByRun, pullRequests, repositoryID}).filter((job) => !state.jobs[String(job.jobID)]);
    for (const job of pending) {
      const nonce = crypto.randomBytes(32).toString("base64url");
      const launchID = `j${job.jobID}-${crypto.randomBytes(8).toString("hex")}`;
      state.jobs[String(job.jobID)] = {...job, nonce, launchID, status: "launching", createdAt: new Date().toISOString()};
      await atomicState(stateFile, state);
      try {
        await runLauncher({launcher, token, metadata: {...job, nonce, launchID}, environment});
        state.jobs[String(job.jobID)].status = "completed";
      } catch (error) {
        // Any nonzero launcher exit is cleanup-uncertain. Keep the deterministic
        // launch identity eligible for mandatory startup reconciliation; the
        // controller must never convert an uncertain launch into terminal state.
        state.jobs[String(job.jobID)].status = "recovery-required";
        state.jobs[String(job.jobID)].failure = error instanceof Error ? error.message.slice(0, 200) : "unknown launcher failure";
        state.jobs[String(job.jobID)].recoveryRequiredAt = new Date().toISOString();
        // Persist the no-retry decision before any network alert. Exiting
        // nonzero then activates the independent host OnFailure channel; the
        // GitHub issue below is useful secondary evidence, not the sole alert.
        await atomicState(stateFile, state);
        const title = `Postgres JIT launcher failed for job ${job.jobID}`;
        try {
          await github({token, method: "POST", endpoint: `/repos/${REPOSITORY}/issues`, body: {title, body: `The supervised hypervisor controller could not complete run ${job.runID}, attempt ${job.attempt}, job ${job.jobID}. No success attestation was issued. Inspect the root-only hypervisor journal.`}, fetchImpl});
        } catch {
          // The systemd OnFailure webhook remains independent of GitHub.
        }
        throw error;
      }
      state.jobs[String(job.jobID)].finishedAt = new Date().toISOString();
      await atomicState(stateFile, state);
    }
    if (once) break;
    const pollSeconds = Math.min(120, Math.max(15, Number(environment.POSTGRES_CI_POLL_SECONDS || 30)));
    await new Promise((resolve) => setTimeout(resolve, pollSeconds * 1000));
  } while (true);
};

const invokedAsCLI = process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href;
if (invokedAsCLI) controller({once: process.argv.includes("--once")}).catch((error) => {
  process.stderr.write(`${error instanceof Error ? error.message : String(error)}\n`);
  process.exitCode = 1;
});
