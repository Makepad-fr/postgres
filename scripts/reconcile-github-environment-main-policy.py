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
)
MAX_POLICY_PAGES = 1000


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


def build_preserving_update(environment: dict[str, Any]) -> dict[str, Any]:
    rules = environment.get("protection_rules")
    if not isinstance(rules, list):
        raise PolicyError("Environment protection rules are missing")

    wait_timer = 0
    reviewer_entries: list[dict[str, Any]] = []
    prevent_self_review = False
    seen_rule_types: set[str] = set()
    for rule in rules:
        if not isinstance(rule, dict) or not isinstance(rule.get("type"), str):
            raise PolicyError("Environment contains an invalid protection rule")
        rule_type = rule["type"]
        if rule_type in seen_rule_types:
            raise PolicyError(f"Environment contains duplicate {rule_type} protection rules")
        seen_rule_types.add(rule_type)
        if rule_type == "branch_policy":
            continue
        if rule_type == "wait_timer":
            candidate = rule.get("wait_timer")
            if not isinstance(candidate, int) or not 0 <= candidate <= 43_200:
                raise PolicyError("Environment wait timer is invalid")
            wait_timer = candidate
            continue
        if rule_type != "required_reviewers":
            raise PolicyError(f"Refusing to overwrite unsupported protection rule: {rule_type}")

        candidate_prevent = rule.get("prevent_self_review", False)
        if not isinstance(candidate_prevent, bool):
            raise PolicyError("Environment self-review setting is invalid")
        prevent_self_review = candidate_prevent
        reviewers = rule.get("reviewers")
        if not isinstance(reviewers, list) or not 1 <= len(reviewers) <= 6:
            raise PolicyError("Environment required reviewers are invalid")
        for entry in reviewers:
            reviewer = entry.get("reviewer") if isinstance(entry, dict) else None
            reviewer_type = entry.get("type") if isinstance(entry, dict) else None
            reviewer_id = reviewer.get("id") if isinstance(reviewer, dict) else None
            if reviewer_type not in {"User", "Team"} or not isinstance(reviewer_id, int) or reviewer_id <= 0:
                raise PolicyError("Environment required reviewer is invalid")
            reviewer_entries.append({"type": reviewer_type, "id": reviewer_id})

    return {
        "wait_timer": wait_timer,
        "prevent_self_review": prevent_self_review,
        "reviewers": reviewer_entries,
        "deployment_branch_policy": {
            "protected_branches": False,
            "custom_branch_policies": True,
        },
    }


def audit_environment(client: GitHubClient, environment: str) -> None:
    current = client.get_environment(environment)
    if not has_custom_policy_mode(current):
        raise PolicyError(f"{environment} does not use custom deployment branch policies")
    policies = client.list_policies(environment)
    if not is_exact_main_policy(policies):
        raise PolicyError(f"{environment} is not restricted to the exact branch main")


def reconcile_environment(client: GitHubClient, environment: str) -> None:
    current = client.get_environment(environment)
    if not has_custom_policy_mode(current):
        client.put_environment(environment, build_preserving_update(current))

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
    audit_environment(client, environment)


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
        expected_confirmation = f"{REPOSITORY}:{environments[0]}:exact-main"
        if args.confirm != expected_confirmation:
            parser.error(f"apply requires --confirm {expected_confirmation}")

    client = GitHubClient()
    try:
        for environment in environments:
            if args.mode == "apply":
                reconcile_environment(client, environment)
            else:
                audit_environment(client, environment)
            print(f"{environment}: exact custom branch policy main")
    except PolicyError as error:
        print(f"Environment policy verification failed: {error}", file=__import__("sys").stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
