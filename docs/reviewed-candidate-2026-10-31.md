# PostgreSQL restore fixture readiness

The image initialization server accepts Unix-socket connections before initialization finishes, then shuts down. Restore fixtures wait for final TCP readiness instead.

A disposable regression holds the initialization phase open: the old socket probe succeeds, while the new wait stays blocked until the final TCP server starts. The five-database ownership/ACL restore test then passes. No production major-version migration is included or authorized; environment-specific image pins remain authoritative.
