#!/usr/bin/env python3
"""Exercise the restore predicate against disposable PostgreSQL, without host ports."""
import importlib.util
from pathlib import Path
import subprocess
import time
import unittest
import uuid

spec = importlib.util.spec_from_file_location('backup', Path(__file__).with_name('visitaki-encrypted-backup.py'))
backup = importlib.util.module_from_spec(spec)
spec.loader.exec_module(backup)
IMAGE = 'postgres:16-alpine@sha256:57c72fd2a128e416c7fcc499958864df5301e940bca0a56f58fddf30ffc07777'
CHECKSUM = 'a' * 64


class PhotoRestorePostgresTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.container = 'visitaki-photo-restore-test-' + uuid.uuid4().hex[:12]
        cls.addClassCleanup(subprocess.run, ['docker', 'rm', '-fv', cls.container],
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=True)
        subprocess.run(['docker', 'run', '-d', '--name', cls.container, '--network', 'none',
                        '--cpus', '1', '--memory', '256m',
                        '--tmpfs', '/var/lib/postgresql/data:rw',
                        '-e', 'POSTGRES_HOST_AUTH_METHOD=trust', IMAGE],
                       check=True, stdout=subprocess.DEVNULL)
        for _ in range(60):
            ready = subprocess.run(['docker', 'exec', cls.container, 'pg_isready',
                                    '-h', '127.0.0.1', '-U', 'postgres'], capture_output=True)
            if ready.returncode == 0:
                return
            time.sleep(1)
        raise RuntimeError('Disposable PostgreSQL did not become ready')

    def sql(self, query):
        result = subprocess.run(['docker', 'exec', '-i', self.container, 'psql', '-XAt',
                                 '-v', 'ON_ERROR_STOP=1', '-U', 'postgres'],
                                input=query, text=True, capture_output=True, check=True)
        return result.stdout.strip()

    def setUp(self):
        # Deliberately omit data constraints: a restore audit must reject corrupt
        # historical rows independently of constraints in the current schema.
        self.sql("""
            DROP SCHEMA public CASCADE; CREATE SCHEMA public;
            CREATE TABLE schema_migrations(version text, content_sha256 text);
            CREATE TABLE accounts(id text, disabled boolean);
            CREATE TABLE community_completions(account_id text, quest_id text);
            CREATE TABLE quest_photo_memories(account_id text, quest_id text, revision bigint, image bytea);
            CREATE TABLE quest_photo_memory_operations(account_id text, quest_id text, revision bigint);
            CREATE FUNCTION erase_disabled_account_memories() RETURNS trigger LANGUAGE plpgsql AS
              $$ BEGIN RETURN NEW; END $$;
            CREATE TRIGGER erase_disabled_account_memories AFTER UPDATE ON accounts
              FOR EACH ROW EXECUTE FUNCTION erase_disabled_account_memories();
            INSERT INTO schema_migrations VALUES('026_quest_photo_memories.sql', '%s');
            INSERT INTO community_completions VALUES('owner', 'quest');
            INSERT INTO quest_photo_memories VALUES('owner', 'quest', 1, decode('ffd8ff01', 'hex'));
            INSERT INTO quest_photo_memory_operations VALUES('owner', 'quest', 1);
        """ % CHECKSUM)

    def valid(self):
        return self.sql(backup.photo_integrity_query(CHECKSUM)) == 't'

    def test_valid_origin_and_always_trigger(self):
        self.assertTrue(self.valid())
        self.sql('ALTER TABLE accounts ENABLE ALWAYS TRIGGER erase_disabled_account_memories')
        self.assertTrue(self.valid())

    def test_disabled_and_replica_only_trigger(self):
        for mode in ['DISABLE', 'ENABLE REPLICA']:
            with self.subTest(mode=mode):
                self.sql('ALTER TABLE accounts ' + mode + ' TRIGGER erase_disabled_account_memories')
                self.assertFalse(self.valid())

    def test_same_named_trigger_on_another_table(self):
        self.sql('''DROP TRIGGER erase_disabled_account_memories ON accounts;
                    CREATE TABLE unrelated(id text);
                    CREATE TRIGGER erase_disabled_account_memories AFTER UPDATE ON unrelated
                    FOR EACH ROW EXECUTE FUNCTION erase_disabled_account_memories();''')
        self.assertFalse(self.valid())

    def test_wrong_trigger_function(self):
        self.sql('''CREATE FUNCTION unrelated_handler() RETURNS trigger LANGUAGE plpgsql AS
                    $$ BEGIN RETURN NEW; END $$;
                    DROP TRIGGER erase_disabled_account_memories ON accounts;
                    CREATE TRIGGER erase_disabled_account_memories AFTER UPDATE ON accounts
                    FOR EACH ROW EXECUTE FUNCTION unrelated_handler();''')
        self.assertFalse(self.valid())

    def test_trigger_must_run_on_updates_without_a_filter(self):
        for event in ['INSERT', 'UPDATE']:
            with self.subTest(event=event):
                self.sql('DROP TRIGGER erase_disabled_account_memories ON accounts')
                condition = ' WHEN (false)' if event == 'UPDATE' else ''
                self.sql('CREATE TRIGGER erase_disabled_account_memories AFTER ' + event +
                         ' ON accounts FOR EACH ROW' + condition +
                         ' EXECUTE FUNCTION erase_disabled_account_memories()')
                self.assertFalse(self.valid())

    def test_corrupt_rows_and_migration_are_rejected(self):
        for statement in [
            "DELETE FROM schema_migrations",
            "UPDATE schema_migrations SET content_sha256='wrong'",
            "DELETE FROM community_completions",
            "UPDATE quest_photo_memories SET image=decode('010203', 'hex')",
            "UPDATE quest_photo_memories SET revision=0",
            "UPDATE quest_photo_memory_operations SET revision=2",
            "UPDATE quest_photo_memory_operations SET account_id='other'",
        ]:
            with self.subTest(statement=statement):
                self.setUp()
                self.sql(statement)
                self.assertFalse(self.valid())


if __name__ == '__main__':
    unittest.main()
