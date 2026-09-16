# September 2026 database separation

These are the host-specific tools used for the approved migration from app-server-1 to db-server-1. They are not automatic deployment hooks. The shared PostgreSQL deployment is unchanged. App repositories own their client topology.

Sentry uses a dedicated, exact-version standalone Compose project on db-server-1. Its PostgreSQL 14, custom ClickHouse 25.3, Valkey, Kafka, SeaweedFS, taskbroker, PgBouncer and Memcached remain separate from shared instances. Generated Compose files contain secrets and are retained only in root-owned /var/lib/makepad/db-migration-20260916 on the hosts.

Preparation captures effective source configuration and refuses to overwrite rollback state. Snapshotting requires stopped source containers, preserves ownership, and records SHA256 checksums. Restore checks those checksums and refuses existing destination volumes. Preserve exact source image IDs separately and load them on the destination; this is not a version upgrade. Scripts are specific to the captured September 16 layout and must not be rerun against the already migrated app manifest.

Destination service ports bind only to WireGuard 10.80.0.2. The Sentry subnet is 172.19.0.0/16; firewall forwarding permits the app host and same-network traffic. nftables must flush only its owned table, never the whole ruleset, because Docker owns additional tables. Existing database-host applications remain running.

Live verification: all configured storage health checks passed; PostgreSQL organizations/projects/users counts were preserved; ClickHouse retained 74,568 rows; a new Sentry event was accepted and retrieved by event ID. Cold snapshots were included in a successful encrypted off-server Restic backup. This confirms cutover backup coverage, not a recurring backup schedule for every newly moved store. Attachment round-trip acceptance remains outstanding.

Rollback: stop app writers, capture current destination stores consistently, verify a reverse transfer, then restore source configuration. The retained source volumes are pre-cutover recovery copies and are stale after destination writes. Never restart both sets of stores as active writers. No source production volumes were deleted. RAID repair and reboot were excluded.
