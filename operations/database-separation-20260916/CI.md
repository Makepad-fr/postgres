# Brio CI database routing

Installed on September 16: ci-docker-router.py is /usr/local/bin/docker on app-server-1; other Docker commands execute /usr/bin/docker unchanged. Only the existing brio-browser-postgres-N-N and brio-postgres-integration-N-N test invocations are intercepted. Their local containers are loopback TCP proxies, while PostgreSQL runs on db-server-1. This is scoped harness routing, not a policy that blocks every possible local database invocation.

ci-postgres-remote.py is the root-owned forced SSH command /usr/local/libexec/makepad/ci-postgres-remote.py on db-server-1. The dedicated key uses restrict, from=10.80.0.1 and the forced command. The app key and pinned known_hosts are under /etc/makepad-ci-databases; private material must never be committed. Allowlisted names and labels isolate removal/exec from production databases. SQL runs inside disposable limited containers; it is not restricted SQL access. The helper permits psql and pg_isready only.

The destination network makepad-ci-databases is 172.30.62.0/24. Test ports bind only 10.80.0.2; forwarding allows app-server-1 and same-network traffic. Containers use a pinned PostgreSQL 16 image, 1 GiB memory, 2 CPUs, 256 PIDs and 512 MiB tmpfs. Builds and browsers stay on the app server. Teardown removes both remote database and local proxy.

Verified live: create/readiness/SQL/cleanup, rejection of a production container name, full PostgreSQL integration suite, and all 45 browser smoke tests (Chromium, Firefox, WebKit, mobile and no-JavaScript). Subsequent real CI jobs were observed using the same remote path. Two abandoned old local test databases had no harness process or active client; dumps were retained before stopping them.

To revert routing, wait for running test jobs to finish, then remove the wrapper from PATH and the dedicated authorized-key entry. This would restore local test databases and therefore violate the requested placement; use only as an explicitly approved rollback. Production stores are outside this helper's scope.
