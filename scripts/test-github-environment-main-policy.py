#!/usr/bin/env python3
"""Behavioral tests for the exact PostgreSQL environment-protection matrix."""

from __future__ import annotations

import copy
import runpy
from pathlib import Path


module = runpy.run_path(
    str(Path(__file__).with_name("reconcile-github-environment-main-policy.py")),
    run_name="postgres_environment_policy",
)
ATTESTATION_EXCEPTION = module["ATTESTATION_EXCEPTION"]
HUMAN_REVIEW_ENVIRONMENTS = module["HUMAN_REVIEW_ENVIRONMENTS"]
PolicyError = module["PolicyError"]
REQUIRED_ENVIRONMENTS = module["REQUIRED_ENVIRONMENTS"]
REVIEWER_ID = module["REVIEWER_ID"]
REVIEWER_LOGIN = module["REVIEWER_LOGIN"]
WAIT_TIMERS = module["WAIT_TIMERS"]
audit_environment = module["audit_environment"]
build_expected_update = module["build_expected_update"]
reconcile_environment = module["reconcile_environment"]


def pinned_reviewer(*, reviewer_id=REVIEWER_ID, login=REVIEWER_LOGIN, kind="User"):
    return {"type": kind, "id": reviewer_id, "login": login}


def environment_payload(
    environment,
    *,
    reviewer=True,
    reviewer_id=REVIEWER_ID,
    reviewer_login=REVIEWER_LOGIN,
    reviewer_kind="User",
    prevent_self_review=True,
    wait_timer=0,
    custom=True,
    extra_rule=None,
):
    rules = []
    if wait_timer:
        rules.append({"type": "wait_timer", "wait_timer": wait_timer})
    if reviewer:
        rules.append(
            {
                "type": "required_reviewers",
                "prevent_self_review": prevent_self_review,
                "reviewers": [
                    {
                        "type": reviewer_kind,
                        "reviewer": {
                            "type": reviewer_kind,
                            "id": reviewer_id,
                            "login": reviewer_login,
                        },
                    }
                ],
            }
        )
    if extra_rule is not None:
        rules.append(copy.deepcopy(extra_rule))
    rules.append({"type": "branch_policy"})
    return {
        "name": environment,
        "deployment_branch_policy": {
            "protected_branches": not custom,
            "custom_branch_policies": custom,
        },
        "protection_rules": rules,
    }


class FakeClient:
    def __init__(self, environment, policies, *, reviewers=None, discard_put=False):
        self.environment = copy.deepcopy(environment)
        self.policies = copy.deepcopy(policies)
        self.reviewers = copy.deepcopy(reviewers or [pinned_reviewer()])
        self.discard_put = discard_put
        self.calls = []
        self.next_id = 100

    def get_reviewer(self):
        self.calls.append(("get-reviewer", REVIEWER_LOGIN))
        if len(self.reviewers) > 1:
            return copy.deepcopy(self.reviewers.pop(0))
        return copy.deepcopy(self.reviewers[0])

    def get_environment(self, environment):
        self.calls.append(("get", environment))
        return copy.deepcopy(self.environment)

    def put_environment(self, environment, payload):
        self.calls.append(("put", environment, copy.deepcopy(payload)))
        if self.discard_put:
            return
        reviewers = payload["reviewers"]
        self.environment = environment_payload(
            environment,
            reviewer=bool(reviewers),
            reviewer_id=reviewers[0]["id"] if reviewers else REVIEWER_ID,
            reviewer_login=REVIEWER_LOGIN,
            reviewer_kind=reviewers[0]["type"] if reviewers else "User",
            prevent_self_review=payload["prevent_self_review"],
            wait_timer=payload["wait_timer"],
            custom=True,
        )

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


def expect_policy_error(function, message):
    try:
        function()
    except PolicyError:
        return
    raise AssertionError(message)


assert "production" in REQUIRED_ENVIRONMENTS
assert HUMAN_REVIEW_ENVIRONMENTS == set(REQUIRED_ENVIRONMENTS) - {"postgres-ci-attestation"}
assert WAIT_TIMERS == {environment: 0 for environment in REQUIRED_ENVIRONMENTS}
assert "must not wait for a human" in ATTESTATION_EXCEPTION

expected_human_update = {
    "wait_timer": 0,
    "prevent_self_review": True,
    "reviewers": [{"type": "User", "id": REVIEWER_ID}],
    "deployment_branch_policy": {"protected_branches": False, "custom_branch_policies": True},
}
for environment in HUMAN_REVIEW_ENVIRONMENTS:
    assert build_expected_update(environment, pinned_reviewer()) == expected_human_update
    client = FakeClient(
        environment_payload(environment),
        [{"id": 9, "name": "main", "type": "branch"}],
    )
    audit_environment(client, environment)

attestation = "postgres-ci-attestation"
expected_attestation_update = {
    "wait_timer": 0,
    "prevent_self_review": False,
    "reviewers": [],
    "deployment_branch_policy": {"protected_branches": False, "custom_branch_policies": True},
}
assert build_expected_update(attestation, None) == expected_attestation_update
client = FakeClient(
    environment_payload(attestation, reviewer=False, prevent_self_review=False),
    [{"id": 9, "name": "main", "type": "branch"}],
)
audit_environment(client, attestation)
assert not any(call[0] == "get-reviewer" for call in client.calls)

# Every human gate rejects missing, substituted, self-approvable, or delayed policy.
for candidate, label in (
    (environment_payload("production", reviewer=False), "missing reviewer"),
    (environment_payload("production", reviewer_id=77), "substituted reviewer ID"),
    (environment_payload("production", reviewer_login="renamed"), "substituted reviewer login"),
    (environment_payload("production", prevent_self_review=False), "enabled self review"),
    (environment_payload("production", wait_timer=15), "unexpected wait timer"),
    (
        environment_payload("production", extra_rule={"type": "custom_protection_rule"}),
        "unsupported protection rule",
    ),
):
    client = FakeClient(candidate, [{"id": 9, "name": "main", "type": "branch"}])
    expect_policy_error(lambda client=client: audit_environment(client, "production"), f"accepted {label}")

client = FakeClient(
    environment_payload(attestation),
    [{"id": 9, "name": "main", "type": "branch"}],
)
expect_policy_error(lambda: audit_environment(client, attestation), "attestation accepted a human review rule")

mismatched_name = environment_payload("production")
mismatched_name["name"] = "canary"
client = FakeClient(mismatched_name, [{"id": 9, "name": "main", "type": "branch"}])
expect_policy_error(lambda: audit_environment(client, "production"), "accepted mismatched environment identity")

# A pinned identity mismatch fails before any provider mutation.
client = FakeClient(
    environment_payload("production", reviewer=False),
    [{"id": 7, "name": "release/*", "type": "branch"}],
    reviewers=[pinned_reviewer(reviewer_id=77)],
)
expect_policy_error(lambda: reconcile_environment(client, "production"), "accepted a stale reviewer snapshot")
assert not any(call[0] in {"put", "create", "delete"} for call in client.calls)

# Reconciliation installs the exact matrix, creates main before deleting broad rules,
# and verifies the provider's post-write state.
client = FakeClient(
    environment_payload("production", reviewer=False, custom=False),
    [{"id": 7, "name": "release/*", "type": "branch"}],
)
reconcile_environment(client, "production")
audit_environment(client, "production")
assert client.policies == [{"id": 100, "name": "main", "type": "branch"}]
assert next(index for index, call in enumerate(client.calls) if call[0] == "create") < next(
    index for index, call in enumerate(client.calls) if call[0] == "delete"
)
put_call = next(call for call in client.calls if call[0] == "put")
assert put_call[2] == expected_human_update

# The attestation exception is actively reconciled to no reviewers and no timer.
client = FakeClient(
    environment_payload(attestation, wait_timer=15),
    [{"id": 9, "name": "main", "type": "branch"}],
)
reconcile_environment(client, attestation)
assert next(call for call in client.calls if call[0] == "put")[2] == expected_attestation_update
assert not any(call[0] == "get-reviewer" for call in client.calls)

# A provider that accepts PUT but does not expose the exact state fails closed.
client = FakeClient(
    environment_payload("production", reviewer=False),
    [{"id": 9, "name": "main", "type": "branch"}],
    discard_put=True,
)
expect_policy_error(lambda: reconcile_environment(client, "production"), "accepted a failed policy read-back")

print("GitHub environment protection-matrix tests passed.")
