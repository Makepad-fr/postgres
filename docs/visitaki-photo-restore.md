# Visitaki photo-memory restore evidence

Run only as the authorized database-host operator on `db-server-1`, after the
reviewed helper is installed through the normal server maintenance procedure.
This does not activate photos or alter the production database. Do not grant
the application workflow general database-root access.

1. Run the existing encrypted backup helper's `backup` operation and retain its
   sanitized snapshot receipt. It reads only `visitaki` and `keycloak_visitaki`.
2. Run its `restore` operation using that exact snapshot and the checksum of
   migration 026 from the deployed Visitaki release:

   ```sh
   sudo /usr/bin/python3 /srv/makepad/visitaki-backups/visitaki-encrypted-backup.py restore --snapshot VERIFIED_SNAPSHOT_ID --photo-migration-sha256 VERIFIED_MIGRATION_SHA256
   ```

   Current migration 026 source checksum (reverify against the deployed release):
   `dc2c4e2c9f5ea9efeaed570415bd93da10c9eca1f4c5a60b3f97ca41b37868fc`.

The photo-specific mode requires a backup under 24 hours old, exact dump hashes,
the exact restored migration checksum, photo size/JPEG encoding bounds,
completion ownership, operation revision integrity and the enabled account
erasure trigger. Only a boolean leaves the restored database. It starts no app
services, exposes no ports and uses a network-disabled disposable PostgreSQL.
Success is emitted only after container and temporary plaintext cleanup.

Provide the sanitized JSON receipt, not dumps, photographs, identifiers or
credentials. An old receipt must not be reused after a failed attempt. The
consumer must check its timestamp, expected snapshot and migration checksum.

Separately report actual Restic access restrictions, retention policy and
deletion expiry, backup schedule health and database storage headroom. Successful
restore alone does not establish these policies or application/proxy logging.
Do not run Restic forget/prune or change retention as part of this verification.

## Visitaki-specific expiry

Install `visitaki-backup-retention.py` alongside the backup helper and install
`visitaki-postgres-retention.service` / `.timer`. The daily 04:30 UTC operation
expires only exact Visitaki-tagged snapshots on db-server-1 with the expected
single backup path. A backup under 24 hours old is required before expiry.
The recovery window is 90 elapsed days, with expiry at the next daily run
(up to 24 hours plus the timer's 10 minute jitter). Failed runs delay expiry;
inspect service status and the timestamped retention receipt before claiming it.

The shared encrypted repository's prune removes only unreferenced data, with
zero unused tolerance; it cannot delete data referenced by retained snapshots
of any product. Repository locks remain enforced. Never use forced unlock.
After a failed run, inspect repository locks and prove the owning process is
absent before normal stale-lock cleanup. No unrelated snapshot forget occurs.
Deleted/replaced images may remain in backups until their last snapshot expires.
The cadence and 90-day window are operational policy, not immediate erasure.

Validation: five fail-closed selection tests and an actual disposable Restic
repository exercise expired Visitaki deletion, retained fresh/foreign snapshots,
restoration, and a complete read-data integrity check. CI runs selection tests.
