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
