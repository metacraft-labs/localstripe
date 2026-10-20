"""Transfer-reversal recovery contract over real HTTP; no mocks.

Metadata and scoped, paginated reads let an interrupted caller find a reversal
without moving money twice. The subprocess is this checkout's actual server.
"""
import base64
import json
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import time
import unittest
import urllib.error
import urllib.parse
import urllib.request


class TransferReversalTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.work = tempfile.TemporaryDirectory(prefix='localstripe-reversals-')
        cls.log = open(Path(cls.work.name) / 'server.log', 'w+')
        with socket.socket() as listener:
            listener.bind(('127.0.0.1', 0))
            port = listener.getsockname()[1]
        cls.url = 'http://127.0.0.1:' + str(port)
        cls.server = subprocess.Popen(
            [sys.executable, '-m', 'localstripe.server', '--from-scratch',
             '--port', str(port)], cwd=Path(__file__).resolve().parent,
            stdout=cls.log, stderr=subprocess.STDOUT)
        deadline = time.monotonic() + 30
        while time.monotonic() < deadline:
            try:
                if cls.call('GET', '/v1/customers')[0] == 200:
                    return
            except OSError:
                pass
            if cls.server.poll() is not None:
                break
            time.sleep(0.05)
        cls.log.seek(0)
        raise RuntimeError('localstripe failed to start: ' + cls.log.read())

    @classmethod
    def tearDownClass(cls):
        cls.server.terminate()
        cls.server.wait()
        cls.log.close()
        cls.work.cleanup()

    @classmethod
    def call(cls, method, path, form=None):
        data = None if form is None else urllib.parse.urlencode(form).encode()
        request = urllib.request.Request(cls.url + path, data=data,
                                         method=method)
        request.add_header('Authorization', 'Basic ' + base64.b64encode(
            b'sk_test_reversals:').decode())
        try:
            with urllib.request.urlopen(request, timeout=10) as response:
                return response.status, json.load(response)
        except urllib.error.HTTPError as error:
            return error.code, json.load(error)

    def test_metadata_scoped_reads_and_pagination_preserve_one_effect(self):
        status, account = self.call('POST', '/v1/accounts', {
            'type': 'express', 'email': 'reversals@test.example'})
        self.assertEqual(status, 200, account)
        transfers = []
        for _ in range(2):
            status, transfer = self.call('POST', '/v1/transfers', {
                'amount': 1000, 'currency': 'usd',
                'destination': account['id']})
            self.assertEqual(status, 200, transfer)
            transfers.append(transfer['id'])
        path = '/v1/transfers/' + transfers[0] + '/reversals'
        created = []
        for index in range(3):
            status, reversal = self.call('POST', path, {
                'amount': 100, 'description': 'partial reversal',
                'metadata[billing_intent_id]': 'intent-' + str(index)})
            self.assertEqual(status, 200, reversal)
            self.assertEqual(reversal['object'], 'transfer_reversal')
            self.assertEqual(reversal['metadata'], {
                'billing_intent_id': 'intent-' + str(index)})
            self.assertEqual(reversal['transfer'], transfers[0])
            created.append(reversal)
        status, page = self.call('GET', path + '?limit=2')
        self.assertEqual(status, 200, page)
        self.assertTrue(page['has_more'])
        self.assertEqual(page['data'], list(reversed(created[1:])))
        status, last = self.call(
            'GET', path + '?limit=2&starting_after=' + page['data'][-1]['id'])
        self.assertEqual(status, 200, last)
        self.assertFalse(last['has_more'])
        self.assertEqual(last['data'], [created[0]])
        status, previous = self.call(
            'GET', path + '?limit=1&ending_before=' + created[0]['id'])
        self.assertEqual(status, 200, previous)
        self.assertEqual(previous['data'], [created[1]])
        self.assertTrue(previous['has_more'])
        status, read = self.call('GET', path + '/' + created[0]['id'])
        self.assertEqual(status, 200, read)
        self.assertEqual(read, created[0])
        other = '/v1/transfers/' + transfers[1] + '/reversals'
        self.assertEqual(self.call('GET', other)[1]['data'], [])
        status, _ = self.call(
            'GET', other + '?starting_after=' + created[0]['id'])
        self.assertEqual(status, 400)
        self.assertEqual(self.call('GET', other + '/' + created[0]['id'])[0],
                         404)
        self.assertEqual(self.call('GET',
                         '/v1/transfers/tr_missing/reversals')[0], 404)
        self.assertEqual(self.call('POST', path, {'amount': 701})[0], 400)
        self.assertEqual(self.call('POST', path, {
            'amount': 100, 'metadata': 'invalid'})[0], 400)
        self.assertEqual(self.call('GET', path + '?limit=101')[0], 400)
        status, transfer = self.call('GET', '/v1/transfers/' + transfers[0])
        self.assertEqual(status, 200, transfer)
        self.assertEqual(transfer['amount_reversed'], 300)
        self.assertEqual(transfer['reversals']['data'],
                         list(reversed(created)))
        self.assertFalse(transfer['reversed'])
        # Omitted amount reverses the remaining balance, exactly once.
        status, final = self.call('POST', path, {})
        self.assertEqual(status, 200, final)
        self.assertEqual(final['amount'], 700)
        self.assertEqual(self.call('POST', path, {})[0], 400)
        transfer = self.call('GET', '/v1/transfers/' + transfers[0])[1]
        self.assertEqual(transfer['amount_reversed'], 1000)
        self.assertTrue(transfer['reversed'])


if __name__ == '__main__':
    unittest.main()
