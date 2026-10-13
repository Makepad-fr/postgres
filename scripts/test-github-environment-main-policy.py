#!/usr/bin/env python3
"""Behavioral tests for exact-main GitHub environment reconciliation."""

from __future__ import annotations

import copy
import runpy
from pathlib import Path


module = runpy.run_path(
    str(Path(__file__).with_name("reconcile-github-environment-main-policy.py")),
    run_name="postgres_environment_policy",
)
PolicyError = module["PolicyError"]
REQUIRED_ENVIRONMENTS = module["REQUIRED_ENVIRONMENTS"]
audit_environment = module["audit_environment"]
build_preserving_update = module["build_preserving_update"]
reconcile_environment = module["reconcile_environment"]


class FakeClient:
    def __init__(self, environment, policies):
        self.environment = copy.deepcopy(environment)
        self.policies = copy.deepcopy(policies)
        self.calls = []
        self.next_id = 100

    def get_environment(self, environment):
        self.calls.append(("get", environment))
        return copy.deepcopy(self.environment)

    def put_environment(self, environment, payload):
        self.calls.append(("put", environment, copy.deepcopy(payload)))
        self.environment["deployment_branch_policy"] = copy.deepcopy(payload["deployment_branch_policy"])

    def list_policies(self, environment):
        self.calls.append(("list", environment))
        return copy.deepcopy(self.policies)

    def create_main_policy(self, environment):
        self.calls.append(("create", environment, "main", "branch"))
        self.policies.append({"id": self.next_id, "name": "main", "type": "branch"})
        self.next_id += 1

    def delete_policy(self, environment, policy_id):
        self.calls.append(("delete", environment, policy_id))
        self.policies = [policy for policy in self.policies if policy["id"] != policy_id]


protected_environment = {
    "deployment_branch_policy": {"protected_branches": True, "custom_branch_policies": False},
    "protection_rules": [
        {"type": "branch_policy"},
        {"type": "wait_timer", "wait_timer": 15},
        {
            "type": "required_reviewers",
            "prevent_self_review": True,
            "reviewers": [{"type": "Team", "reviewer": {"id": 42}}],
        },
    ],
}

assert "production" in REQUIRED_ENVIRONMENTS
preserved = build_preserving_update(protected_environment)
assert preserved == {
    "wait_timer": 15,
    "prevent_self_review": True,
    "reviewers": [{"type": "Team", "id": 42}],
    "deployment_branch_policy": {"protected_branches": False, "custom_branch_policies": True},
}

client = FakeClient(protected_environment, [{"id": 7, "name": "release/*", "type": "branch"}])
try:
    audit_environment(client, "production")
except PolicyError:
    pass
else:
    raise AssertionError("generic protected-branch policy was accepted")

client.calls.clear()
reconcile_environment(client, "production")
audit_environment(client, "production")
assert client.policies == [{"id": 100, "name": "main", "type": "branch"}]
assert next(index for index, call in enumerate(client.calls) if call[0] == "create") < next(
    index for index, call in enumerate(client.calls) if call[0] == "delete"
)
put_call = next(call for call in client.calls if call[0] == "put")
assert put_call[2]["reviewers"] == [{"type": "Team", "id": 42}]
assert put_call[2]["wait_timer"] == 15

client = FakeClient(
    {
        "deployment_branch_policy": {"protected_branches": False, "custom_branch_policies": True},
        "protection_rules": [{"type": "branch_policy"}],
    },
    [
        {"id": 9, "name": "main", "type": "branch"},
        {"id": 10, "name": "main", "type": "tag"},
    ],
)
try:
    audit_environment(client, "production")
except PolicyError:
    pass
else:
    raise AssertionError("additional tag policy was accepted")

print("GitHub environment exact-main policy tests passed.")
