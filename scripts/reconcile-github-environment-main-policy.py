#!/usr/bin/env python3
"""Audit or reconcile exact-main GitHub environment deployment policies."""

from __future__ import annotations

import argparse
import json
import subprocess
from typing import Any
from urllib.parse import quote


REPOSITORY = "Makepad-fr/postgres"
REQUIRED_ENVIRONMENTS = (
    "canary",
    "production",
    "staging-brio-identity-db",
    "release-brio-identity-db",
    "keycloak-cohort-restore",
    "postgres-ci-attestation",
)
MAX_POLICY_PAGES = 1000
REVIEWER_LOGIN = "idilsaglam"
REVIEWER_ID = 39597780
REVIEWER_TYPE = "User"
HUMAN_REVIEW_ENVIRONMENTS = frozenset(REQUIRED_ENVIRONMENTS) - {"postgres-ci-attestation"}
WAIT_TIMERS = {environment: 0 for environment in REQUIRED_ENVIRONMENTS}
ATTESTATION_EXCEPTION = (
    "postgres-ci-attestation is an exact-main machine attestor whose signed "
    "repository_dispatch result must not wait for a human deployment approval"
)


class PolicyError(RuntimeError):
    """Raised when provider state cannot be proven safe and complete."""


def _environment_path(environment: str) -> str:
    if environment not in REQUIRED_ENVIRONMENTS:
        raise PolicyError(f"Unsupported environment: {environment}")
    return f"repos/{REPOSITORY}/environments/{quote(environment, safe='')}"


class GitHubClient:
    """Minimal gh-backed client; authentication remains in gh's credential store."""

    def request(self, method: str, path: str, payload: dict[str, Any] | None = None) -> Any:
        command = [
            "gh",
            "api",
            "--method",
            method,
            "-H",
            "Accept: application/vnd.github+json",
            "-H",
            "X-GitHub-Api-Version: 2022-11-28",
            path,
        ]
        if payload is not None:
            command.extend(("--input", "-"))
        try:
            result = subprocess.run(
                command,
                input=None if payload is None else json.dumps(payload, separators=(",", ":")),
                check=True,
                text=True,
                stdout=subprocess.PIPE,
            )
        except (OSError, subprocess.CalledProcessError) as error:
            raise PolicyError(f"GitHub API {method} failed for {path}") from error
        try:
            return json.loads(result.stdout) if result.stdout.strip() else None
        except json.JSONDecodeError as error:
            raise PolicyError(f"GitHub API returned invalid JSON for {path}") from error

    def get_environment(self, environment: str) -> dict[str, Any]:
        response = self.request("GET", _environment_path(environment))
        if not isinstance(response, dict):
            raise PolicyError(f"Invalid environment response for {environment}")
        return response

    def get_reviewer(self) -> dict[str, Any]:
        response = self.request("GET", f"users/{quote(REVIEWER_LOGIN, safe='')}")
        if not isinstance(response, dict):
            raise PolicyError("Invalid reviewer identity response")
        return response

    def put_environment(self, environment: str, payload: dict[str, Any]) -> None:
        self.request("PUT", _environment_path(environment), payload)

    def list_policies(self, environment: str) -> list[dict[str, Any]]:
        path = f"{_environment_path(environment)}/deployment-branch-policies"
        policies: list[dict[str, Any]] = []
        seen_ids: set[int] = set()
        expected_total: int | None = None
        for page in range(1, MAX_POLICY_PAGES + 1):
            response = self.request("GET", f"{path}?per_page=100&page={page}")
            if not isinstance(response, dict):
                raise PolicyError(f"Invalid branch-policy listing for {environment}")
            total = response.get("total_count")
            page_policies = response.get("branch_policies")
            if not isinstance(total, int) or total < 0 or not isinstance(page_policies, list):
                raise PolicyError(f"Incomplete branch-policy listing for {environment}")
            if expected_total is None:
                expected_total = total
            elif total != expected_total:
                raise PolicyError(f"Branch-policy listing changed during pagination for {environment}")
            for policy in page_policies:
                if not isinstance(policy, dict) or not isinstance(policy.get("id"), int):
                    raise PolicyError(f"Invalid branch policy for {environment}")
                policy_id = policy["id"]
                if policy_id in seen_ids:
                    raise PolicyError(f"Duplicate branch policy returned for {environment}")
                seen_ids.add(policy_id)
                policies.append(policy)
            if len(policies) == expected_total:
                return policies
            if len(policies) > expected_total or not page_policies:
                raise PolicyError(f"Truncated branch-policy listing for {environment}")
        raise PolicyError(f"Branch-policy pagination exceeded its bound for {environment}")

    def create_main_policy(self, environment: str) -> None:
        self.request(
            "POST",
            f"{_environment_path(environment)}/deployment-branch-policies",
            {"name": "main", "type": "branch"},
        )

    def delete_policy(self, environment: str, policy_id: int) -> None:
        if not isinstance(policy_id, int) or policy_id <= 0:
            raise PolicyError(f"Invalid branch-policy ID for {environment}")
        self.request(
            "DELETE",
            f"{_environment_path(environment)}/deployment-branch-policies/{policy_id}",
        )


def has_custom_policy_mode(environment: dict[str, Any]) -> bool:
    policy = environment.get("deployment_branch_policy")
    return (
        isinstance(policy, dict)
        and policy.get("protected_branches") is False
        and policy.get("custom_branch_policies") is True
    )


def is_exact_main_policy(policies: list[dict[str, Any]]) -> bool:
    return len(policies) == 1 and policies[0].get("name") == "main" and policies[0].get("type") == "branch"


def reviewer_snapshot(client: GitHubClient, environment: str) -> dict[str, Any] | None:
    if environment not in HUMAN_REVIEW_ENVIRONMENTS:
        return None
    reviewer = client.get_reviewer()
    snapshot = {
        "type": reviewer.get("type"),
        "id": reviewer.get("id"),
        "login": reviewer.get("login"),
    }
    expected = {"type": REVIEWER_TYPE, "id": REVIEWER_ID, "login": REVIEWER_LOGIN}
    if snapshot != expected:
        raise PolicyError("Required reviewer identity does not match the pinned GitHub snapshot")
    return snapshot


def expected_protection(environment: str, reviewer: dict[str, Any] | None) -> dict[str, Any]:
    if environment not in REQUIRED_ENVIRONMENTS:
        raise PolicyError(f"Unsupported environment: {environment}")
    requires_review = environment in HUMAN_REVIEW_ENVIRONMENTS
    if requires_review != (reviewer is not None):
        raise PolicyError(f"Reviewer snapshot presence is invalid for {environment}")
    return {
        "wait_timer": WAIT_TIMERS[environment],
        "prevent_self_review": requires_review,
        "reviewers": [] if reviewer is None else [reviewer],
    }


def protection_snapshot(environment: str, payload: dict[str, Any]) -> dict[str, Any]:
    if payload.get("name") != environment:
        raise PolicyError(f"Environment identity differs from requested environment {environment}")
    rules = payload.get("protection_rules")
    if not isinstance(rules, list):
        raise PolicyError(f"Protection rules are missing for {environment}")

    wait_timer = 0
    prevent_self_review = False
    reviewers: list[dict[str, Any]] = []
    seen_rule_types: set[str] = set()
    for rule in rules:
        if not isinstance(rule, dict) or not isinstance(rule.get("type"), str):
            raise PolicyError(f"Protection rule is invalid for {environment}")
        rule_type = rule["type"]
        if rule_type in seen_rule_types:
            raise PolicyError(f"Duplicate {rule_type} protection rule for {environment}")
        seen_rule_types.add(rule_type)
        if rule_type == "branch_policy":
            continue
        if rule_type == "wait_timer":
            candidate = rule.get("wait_timer")
            if not isinstance(candidate, int) or not 1 <= candidate <= 43_200:
                raise PolicyError(f"Wait timer is invalid for {environment}")
            wait_timer = candidate
            continue
        if rule_type != "required_reviewers":
            raise PolicyError(f"Unsupported protection rule {rule_type} for {environment}")

        candidate_prevent = rule.get("prevent_self_review")
        candidates = rule.get("reviewers")
        if not isinstance(candidate_prevent, bool) or not isinstance(candidates, list) or not 1 <= len(candidates) <= 6:
            raise PolicyError(f"Required-reviewer rule is invalid for {environment}")
        prevent_self_review = candidate_prevent
        for entry in candidates:
            nested = entry.get("reviewer") if isinstance(entry, dict) else None
            if not isinstance(nested, dict):
                raise PolicyError(f"Required reviewer is invalid for {environment}")
            snapshot = {
                "type": entry.get("type"),
                "id": nested.get("id"),
                "login": nested.get("login"),
            }
            if nested.get("type") != snapshot["type"]:
                raise PolicyError(f"Nested reviewer identity is inconsistent for {environment}")
            if (
                snapshot["type"] not in {"User", "Team"}
                or not isinstance(snapshot["id"], int)
                or snapshot["id"] <= 0
                or not isinstance(snapshot["login"], str)
                or not snapshot["login"]
            ):
                raise PolicyError(f"Required reviewer identity is invalid for {environment}")
            reviewers.append(snapshot)

    if "branch_policy" not in seen_rule_types:
        raise PolicyError(f"Branch-policy protection rule is missing for {environment}")
    return {
        "wait_timer": wait_timer,
        "prevent_self_review": prevent_self_review,
        "reviewers": reviewers,
    }


def build_expected_update(environment: str, reviewer: dict[str, Any] | None) -> dict[str, Any]:
    expected = expected_protection(environment, reviewer)
    return {
        "wait_timer": expected["wait_timer"],
        "prevent_self_review": expected["prevent_self_review"],
        "reviewers": [
            {"type": candidate["type"], "id": candidate["id"]}
            for candidate in expected["reviewers"]
        ],
        "deployment_branch_policy": {
            "protected_branches": False,
            "custom_branch_policies": True,
        },
    }


def audit_protection(
    environment: str,
    current: dict[str, Any],
    reviewer: dict[str, Any] | None,
) -> None:
    if not has_custom_policy_mode(current):
        raise PolicyError(f"{environment} does not use custom deployment branch policies")
    actual = protection_snapshot(environment, current)
    expected = expected_protection(environment, reviewer)
    if actual != expected:
        raise PolicyError(f"{environment} protection does not match the pinned reviewer matrix")


def audit_environment(
    client: GitHubClient,
    environment: str,
    expected_reviewer: dict[str, Any] | None = None,
) -> None:
    reviewer = reviewer_snapshot(client, environment) if expected_reviewer is None else expected_reviewer
    current = client.get_environment(environment)
    audit_protection(environment, current, reviewer)
    policies = client.list_policies(environment)
    if not is_exact_main_policy(policies):
        raise PolicyError(f"{environment} is not restricted to the exact branch main")


def reconcile_environment(client: GitHubClient, environment: str) -> None:
    initial_reviewer = reviewer_snapshot(client, environment)
    current = client.get_environment(environment)
    # Parse before writing so unknown or malformed rules are never silently removed.
    current_snapshot = protection_snapshot(environment, current)
    expected = expected_protection(environment, initial_reviewer)
    if not has_custom_policy_mode(current) or current_snapshot != expected:
        client.put_environment(environment, build_expected_update(environment, initial_reviewer))
        audit_protection(environment, client.get_environment(environment), initial_reviewer)

    policies = client.list_policies(environment)
    exact_main = [policy for policy in policies if policy.get("name") == "main" and policy.get("type") == "branch"]
    if not exact_main:
        client.create_main_policy(environment)
        policies = client.list_policies(environment)
        exact_main = [policy for policy in policies if policy.get("name") == "main" and policy.get("type") == "branch"]
    if not exact_main:
        raise PolicyError(f"Unable to create exact main policy for {environment}")

    keep_id = exact_main[0]["id"]
    for policy in policies:
        if policy["id"] != keep_id:
            client.delete_policy(environment, policy["id"])

    final_reviewer = reviewer_snapshot(client, environment)
    if final_reviewer != initial_reviewer:
        raise PolicyError("Required reviewer identity changed during reconciliation")
    audit_environment(client, environment, initial_reviewer)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=("audit", "apply"))
    parser.add_argument("--environment", choices=REQUIRED_ENVIRONMENTS, action="append")
    parser.add_argument("--confirm", default="")
    args = parser.parse_args()

    environments = tuple(args.environment or REQUIRED_ENVIRONMENTS)
    if args.mode == "apply":
        if len(environments) != 1:
            parser.error("apply requires exactly one --environment")
        expected_confirmation = f"{REPOSITORY}:{environments[0]}:protected-policy-v1"
        if args.confirm != expected_confirmation:
            parser.error(f"apply requires --confirm {expected_confirmation}")

    client = GitHubClient()
    try:
        for environment in environments:
            if args.mode == "apply":
                reconcile_environment(client, environment)
            else:
                audit_environment(client, environment)
            if environment == "postgres-ci-attestation":
                print(f"{environment}: exact main, no timer, automated-attestor exception")
            else:
                print(f"{environment}: exact main, pinned reviewer, self-review denied, no timer")
    except PolicyError as error:
        print(f"Environment policy verification failed: {error}", file=__import__("sys").stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
