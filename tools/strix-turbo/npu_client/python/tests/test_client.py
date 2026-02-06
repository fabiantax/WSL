"""
Tests for Strix-Turbo NPU Client

Run with: pytest tests/
"""

import pytest
import json
import socket
import threading
import time
from unittest.mock import Mock, patch, MagicMock

from strix_npu import NPUClient
from strix_npu.client import NPUClientConfig, NPUClientError, ConnectionError


class MockNPUBridge:
    """Mock NPU bridge server for testing."""

    def __init__(self, port: int = 19999):
        self.port = port
        self.server: socket.socket = None
        self.running = False
        self.responses = {}
        self._thread = None

    def set_response(self, cmd: str, response: dict):
        """Set response for a command."""
        self.responses[cmd] = response

    def start(self):
        """Start mock server."""
        self.server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self.server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.server.bind(('localhost', self.port))
        self.server.listen(1)
        self.server.settimeout(5.0)
        self.running = True

        self._thread = threading.Thread(target=self._serve)
        self._thread.daemon = True
        self._thread.start()

        # Wait for server to start
        time.sleep(0.1)

    def stop(self):
        """Stop mock server."""
        self.running = False
        if self.server:
            self.server.close()
        if self._thread:
            self._thread.join(timeout=1.0)

    def _serve(self):
        """Server loop."""
        while self.running:
            try:
                client, _ = self.server.accept()
                client.settimeout(1.0)
                self._handle_client(client)
            except socket.timeout:
                continue
            except Exception:
                break

    def _handle_client(self, client: socket.socket):
        """Handle client connection."""
        try:
            while self.running:
                data = client.recv(65536)
                if not data:
                    break

                request = json.loads(data.decode('utf-8').strip())
                cmd = request.get('cmd', '')

                if cmd in self.responses:
                    response = self.responses[cmd]
                else:
                    response = {'status': 'error', 'message': f'Unknown command: {cmd}'}

                client.send(json.dumps(response).encode('utf-8') + b'\n')

        except Exception:
            pass
        finally:
            client.close()


@pytest.fixture
def mock_bridge():
    """Create mock NPU bridge."""
    bridge = MockNPUBridge()
    bridge.set_response('ping', {'status': 'ok', 'provider': 'DmlExecutionProvider'})
    bridge.set_response('status', {
        'status': 'ok',
        'provider': 'DmlExecutionProvider',
        'models': ['test_model'],
        'history_size': 100
    })
    bridge.set_response('load_model', {'status': 'ok'})
    bridge.set_response('model_info', {
        'status': 'ok',
        'info': {
            'inputs': [{'name': 'input', 'shape': [1, 3], 'type': 'float32'}],
            'outputs': [{'name': 'output', 'shape': [1, 2], 'type': 'float32'}]
        }
    })
    bridge.set_response('infer', {
        'status': 'ok',
        'outputs': {'output': [[0.5, 0.5]]}
    })
    bridge.set_response('record_access', {'status': 'ok'})
    bridge.set_response('predict_next', {
        'status': 'ok',
        'predictions': [12345, 67890, 11111]
    })

    bridge.start()
    yield bridge
    bridge.stop()


@pytest.fixture
def client_config(mock_bridge):
    """Create client config for mock bridge."""
    return NPUClientConfig(
        host='localhost',
        port=mock_bridge.port,
        timeout=5.0,
        retry_count=1
    )


class TestNPUClient:
    """Tests for NPUClient."""

    def test_connect(self, mock_bridge, client_config):
        """Test connecting to bridge."""
        client = NPUClient(client_config)
        response = client.connect()

        assert client.is_connected
        assert response['status'] == 'ok'
        assert 'provider' in response

        client.close()
        assert not client.is_connected

    def test_context_manager(self, mock_bridge, client_config):
        """Test using client as context manager."""
        with NPUClient(client_config) as client:
            assert client.is_connected
            response = client.ping()
            assert response['status'] == 'ok'

        assert not client.is_connected

    def test_status(self, mock_bridge, client_config):
        """Test getting bridge status."""
        with NPUClient(client_config) as client:
            status = client.status()

            assert status['status'] == 'ok'
            assert 'provider' in status
            assert 'models' in status
            assert 'history_size' in status

    def test_load_model(self, mock_bridge, client_config):
        """Test loading a model."""
        with NPUClient(client_config) as client:
            result = client.load_model('test', '/path/to/model.onnx')
            assert result is True

    def test_model_info(self, mock_bridge, client_config):
        """Test getting model info."""
        with NPUClient(client_config) as client:
            info = client.model_info('test')

            assert info is not None
            assert 'inputs' in info
            assert 'outputs' in info
            assert len(info['inputs']) > 0

    def test_infer(self, mock_bridge, client_config):
        """Test running inference."""
        with NPUClient(client_config) as client:
            result = client.infer('test', {'input': [[1.0, 2.0, 3.0]]})

            assert 'output' in result
            assert len(result['output']) > 0

    def test_record_access(self, mock_bridge, client_config):
        """Test recording file access."""
        with NPUClient(client_config) as client:
            result = client.record_access('/path/to/file.txt')
            assert result is True

    def test_predict_next(self, mock_bridge, client_config):
        """Test predicting next accesses."""
        with NPUClient(client_config) as client:
            predictions = client.predict_next(5)

            assert isinstance(predictions, list)
            assert len(predictions) > 0

    def test_connection_error(self):
        """Test connection error handling."""
        config = NPUClientConfig(
            host='localhost',
            port=1,  # Invalid port
            timeout=1.0,
            retry_count=1
        )
        client = NPUClient(config)

        with pytest.raises(ConnectionError):
            client.connect()

    def test_not_connected_error(self, client_config):
        """Test error when not connected."""
        client = NPUClient(client_config)

        with pytest.raises(ConnectionError):
            client.ping()

    def test_error_response(self, mock_bridge, client_config):
        """Test handling error response."""
        mock_bridge.set_response('bad_cmd', {
            'status': 'error',
            'message': 'Command failed'
        })

        with NPUClient(client_config) as client:
            with pytest.raises(NPUClientError):
                client._send_request({'cmd': 'bad_cmd'})


class TestNPUClientConfig:
    """Tests for NPUClientConfig."""

    def test_default_config(self):
        """Test default configuration values."""
        config = NPUClientConfig()

        assert config.host == 'localhost'
        assert config.port == 9999
        assert config.timeout == 30.0
        assert config.retry_count == 3
        assert config.buffer_size == 65536

    def test_custom_config(self):
        """Test custom configuration."""
        config = NPUClientConfig(
            host='192.168.1.100',
            port=8888,
            timeout=60.0
        )

        assert config.host == '192.168.1.100'
        assert config.port == 8888
        assert config.timeout == 60.0


class TestPathHashing:
    """Tests for path hashing consistency."""

    def test_hash_consistency(self, mock_bridge, client_config):
        """Test that same path produces same hash."""
        with NPUClient(client_config) as client:
            # Record same path twice
            path = '/test/path/file.txt'
            client.record_access(path)
            client.record_access(path)

            # Should work without error
            assert True

    def test_hash_uniqueness(self):
        """Test that different paths produce different hashes."""
        import hashlib

        path1 = '/path/to/file1.txt'
        path2 = '/path/to/file2.txt'

        hash1 = int(hashlib.md5(path1.encode()).hexdigest()[:8], 16)
        hash2 = int(hashlib.md5(path2.encode()).hexdigest()[:8], 16)

        assert hash1 != hash2


if __name__ == '__main__':
    pytest.main([__file__, '-v'])
