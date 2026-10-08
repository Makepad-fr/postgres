import importlib.util
from pathlib import Path
import socket
import struct
import threading
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('router', Path(__file__).with_name('ci-docker-router.py'))
router = importlib.util.module_from_spec(spec)
spec.loader.exec_module(router)

class ReadinessTests(unittest.TestCase):
    def probe(self, response):
        listener = socket.socket()
        listener.bind(('127.0.0.1', 0))
        listener.listen()
        observed = []
        def serve():
            with listener:
                connection, _ = listener.accept()
                with connection:
                    observed.append(connection.recv(8))
                    if response:
                        connection.sendall(response)
        thread = threading.Thread(target=serve)
        thread.start()
        ready = router.postgres_route_ready(listener.getsockname()[1])
        thread.join(timeout=2)
        self.assertFalse(thread.is_alive())
        self.assertEqual(observed, [struct.pack('!II', 8, 80877103)])
        return ready

    def test_proxy_accepting_then_closing_is_not_ready(self):
        self.assertFalse(self.probe(b''))

    def test_unrelated_protocol_is_not_ready(self):
        self.assertFalse(self.probe(b'H'))

    def test_postgres_with_or_without_tls_is_ready(self):
        for response in (b'N', b'S'):
            with self.subTest(response=response):
                self.assertTrue(self.probe(response))

    def test_refused_connection_is_not_ready(self):
        with patch.object(router.socket, 'create_connection', side_effect=ConnectionRefusedError):
            self.assertFalse(router.postgres_route_ready(12345))

    def test_remote_readiness_must_also_pass_local_route(self):
        with patch.object(router, 'original', ['exec', 'brio-postgres-integration-1-2', 'pg_isready']), \
             patch.object(router, 'managed', return_value=True), \
             patch.object(router, 'rpc', return_value={'code': 0, 'stdout': '', 'stderr': ''}), \
             patch.object(router.subprocess, 'check_output', return_value='127.0.0.1:12345\n'), \
             patch.object(router, 'postgres_route_ready', return_value=False) as probe:
            self.assertEqual(router.main(), 1)
            probe.assert_called_once_with(12345)

if __name__ == '__main__':
    unittest.main()
