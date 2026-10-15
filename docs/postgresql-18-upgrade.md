# PostgreSQL 18 major-version upgrade

The repository is pinned to PostgreSQL 18. `scripts/preflight-postgres-major.sh`
refuses to start that image against a data directory initialized by an older
major version. A normal deploy is not an upgrade mechanism.

## Required gate

Schedule a maintenance window and assign an operator plus reviewer. Before
stopping writers, require all of the following:

- a fresh certificate-verified logical backup of every database, including
  `amiary`, `amiary_canary`, and `keycloak_amiary`;
- verified checksums and `pg_restore --list` for every custom-format archive;
- a successful isolated restore drill using the PostgreSQL 18 client/server;
- a separately protected globals export and an inventory of extensions;
- measured rollback time within the four-hour RTO; and
- a filesystem-level snapshot of the PostgreSQL 16 data directory retained
  unchanged until the PostgreSQL 18 validation window closes.

## Cutover outline

1. Disable application writes and stop all database clients and backup jobs.
2. Take and verify a final logical backup and globals export over
   certificate-verified TLS. Treat globals and dumps as secrets.
3. Move the PostgreSQL 16 data directory to a narrow, timestamped rollback
   path. Never overwrite or delete it during the cutover.
4. Create a new empty directory at the configured data path with the existing
   PostgreSQL uid/gid and mode, then run the major-version preflight.
5. Start the pinned PostgreSQL 18 image, restore reviewed globals and all
   database archives, and re-run every idempotent application bootstrap.
6. Run ownership, grants, RLS isolation, migration checksum, TLS/HBA, backup,
   application smoke, and latency checks before enabling writers.
7. Re-enable clients gradually. Roll back to the untouched PostgreSQL 16
   directory if any acceptance gate fails.

Record image digests, backup identifiers, checksums, commands, timings,
reviewer approval, and restore evidence. Do not delete the PostgreSQL 16
rollback snapshot until the retention decision is explicitly reviewed.
