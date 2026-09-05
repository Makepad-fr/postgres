#!/usr/bin/env python3
"""Bind a disposed JIT runner to its exact authoritative GitHub result."""

from __future__ import annotations

import argparse
import json
import re
from pathlib import Path


EXPECTED_REPOSITORY = "Makepad-fr/postgres"
EXPECTED_LABELS = {"self-hosted", "linux", "x64", "makepad-postgres-pr-ephemeral"}


def positive(value: object, label: str) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or value <= 0:
        raise ValueError(f"{label} must be a positive integer")
    return value


def load_object(path: Path, label: str) -> dict[str, object]:
    if path.is_symlink() or not path.is_file() or path.stat().st_size > 2 * 1024 * 1024:
        raise ValueError(f"{label} must be a small regular file")
    value = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(value, dict):
        raise ValueError(f"{label} must be a JSON object")
    return value


def validate(
    run: dict[str, object],
    response: dict[str, object],
    *,
    run_id: int,
    attempt: int,
    job_id: int,
    event: str,
    source_sha: str,
    workflow_sha: str,
    runner_id: int,
    runner_name: str,
    runner_group_id: int,
) -> str:
    for value, label in (
        (run_id, "run ID"),
        (attempt, "run attempt"),
        (job_id, "job ID"),
        (runner_id, "runner ID"),
        (runner_group_id, "runner group ID"),
    ):
        positive(value, label)
    if event not in {"pull_request_target", "push"}:
        raise ValueError("unsupported workflow event")
    if not re.fullmatch(r"[a-f0-9]{40}", source_sha) or not re.fullmatch(r"[a-f0-9]{40}", workflow_sha):
        raise ValueError("source and workflow SHAs must be lowercase commit IDs")
    if not re.fullmatch(r"postgres-ci-jit-j[1-9][0-9]{0,15}-[a-f0-9]{16}", runner_name):
        raise ValueError("runner name is outside the deterministic JIT namespace")

    jobs = response.get("jobs")
    total = response.get("total_count")
    if not isinstance(jobs, list) or isinstance(total, bool) or total != len(jobs):
        raise ValueError("authoritative attempt-job response is truncated")
    matches = [value for value in jobs if isinstance(value, dict) and value.get("id") == job_id]
    if len(matches) != 1:
        raise ValueError("exact job is not unique in the authoritative run attempt")
    job = matches[0]
    raw_labels = job.get("labels")
    if not isinstance(raw_labels, list) or not all(isinstance(value, str) for value in raw_labels):
        raise ValueError("authoritative job labels are invalid")
    actual_labels = [value.lower() for value in raw_labels]
    if len(actual_labels) != len(EXPECTED_LABELS) or set(actual_labels) != EXPECTED_LABELS:
        raise ValueError("authoritative job identity does not match this hypervisor execution")

    repository = run.get("repository")
    if not isinstance(repository, dict):
        raise ValueError("authoritative repository identity is missing")
    repository_id = positive(repository.get("id"), "repository ID")
    if (
        run.get("id") != run_id
        or run.get("run_attempt") != attempt
        or run.get("event") != event
        or run.get("head_sha") != workflow_sha
        or run.get("head_branch") != "main"
        or run.get("name") != "CI"
        or run.get("path") != ".github/workflows/ci.yml"
        or run.get("status") != "completed"
        or repository.get("full_name") != EXPECTED_REPOSITORY
        or job.get("run_id") != run_id
        or job.get("id") != job_id
        or job.get("head_sha") != workflow_sha
        or job.get("workflow_name") != "CI"
        or job.get("runner_id") != runner_id
        or job.get("runner_name") != runner_name
        or job.get("runner_group_id") != runner_group_id
        or job.get("runner_group_name") != "Postgres PR Ephemeral"
        or job.get("name") != "policy-and-integration"
        or job.get("status") != "completed"
    ):
        raise ValueError("authoritative job identity does not match this hypervisor execution")

    if event == "pull_request_target":
        associations = run.get("pull_requests")
        if not isinstance(associations, list) or len(associations) != 1 or not isinstance(associations[0], dict):
            raise ValueError("authoritative pull request association differs from the requested source")
        association = associations[0]
        head = association.get("head")
        base = association.get("base")
        if not isinstance(head, dict) or not isinstance(base, dict):
            raise ValueError("authoritative pull request association differs from the requested source")
        head_repository = head.get("repo")
        base_repository = base.get("repo")
        if (
            not isinstance(head_repository, dict)
            or not isinstance(base_repository, dict)
            or head.get("sha") != source_sha
            or head_repository.get("id") != repository_id
            or base_repository.get("id") != repository_id
            or base.get("ref") != "main"
            or base.get("sha") != workflow_sha
        ):
            raise ValueError("authoritative pull request association differs from the requested source")
    elif source_sha != workflow_sha:
        raise ValueError("protected-main push source differs from its workflow SHA")

    run_conclusion = run.get("conclusion")
    job_conclusion = job.get("conclusion")
    if run_conclusion != job_conclusion or run_conclusion not in {"success", "failure"}:
        raise ValueError("authoritative run and job conclusions are not an exact supported result")
    return run_conclusion


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("run_file", type=Path)
    parser.add_argument("jobs_file", type=Path)
    parser.add_argument("run_id", type=int)
    parser.add_argument("attempt", type=int)
    parser.add_argument("job_id", type=int)
    parser.add_argument("event")
    parser.add_argument("source_sha")
    parser.add_argument("workflow_sha")
    parser.add_argument("runner_id", type=int)
    parser.add_argument("runner_name")
    parser.add_argument("runner_group_id", type=int)
    arguments = parser.parse_args()
    print(
        validate(
            load_object(arguments.run_file, "run response"),
            load_object(arguments.jobs_file, "jobs response"),
            run_id=arguments.run_id,
            attempt=arguments.attempt,
            job_id=arguments.job_id,
            event=arguments.event,
            source_sha=arguments.source_sha,
            workflow_sha=arguments.workflow_sha,
            runner_id=arguments.runner_id,
            runner_name=arguments.runner_name,
            runner_group_id=arguments.runner_group_id,
        )
    )


if __name__ == "__main__":
    main()
