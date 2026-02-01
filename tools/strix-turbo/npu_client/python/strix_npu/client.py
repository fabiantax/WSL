"""
Synchronous NPU Client for WSL2

Communicates with the Windows NPU bridge to run inference on the AMD XDNA NPU.
"""

import json
import socket
import hashlib
import time
import logging
from typing import Dict, List, Any, Optional, Union
from dataclasses import dataclass
from contextlib import contextmanager

logger = logging.getLogger(__name__)


@dataclass
class NPUClientConfig:
    """Configuration for NPU client."""
    host: str = "localhost"
    port: int = 9999
    timeout: float = 30.0
    retry_count: int = 3
    retry_delay: float = 1.0
    buffer_size: int = 65536


class NPUClientError(Exception):
    """Base exception for NPU client errors."""
    pass


class ConnectionError(NPUClientError):
    """Failed to connect to NPU bridge."""
    pass


class InferenceError(NPUClientError):
    """Inference failed."""
    pass


class NPUClient:
    """
    Synchronous NPU client for WSL2.

    Connects to the Windows NPU bridge service and provides methods for:
    - Running ONNX model inference on the NPU
    - Recording file access patterns for prefetching
    - Predicting next file accesses

    Example:
        client = NPUClient()
        client.connect()

        # Check status
        print(client.status())

        # Run inference
        result = client.infer("model", {"input": [[1.0, 2.0, 3.0]]})

        client.close()
    """

    def __init__(self, config: Optional[NPUClientConfig] = None):
        """
        Initialize NPU client.

        Args:
            config: Client configuration. Uses defaults if not provided.
        """
        self.config = config or NPUClientConfig()
        self._socket: Optional[socket.socket] = None
        self._connected = False

    def __enter__(self):
        """Context manager entry."""
        self.connect()
        return self

    def __exit__(self, exc_type, exc_val, exc_tb):
        """Context manager exit."""
        self.close()
        return False

    @property
    def is_connected(self) -> bool:
        """Check if client is connected."""
        return self._connected and self._socket is not None

    def connect(self) -> Dict[str, Any]:
        """
        Connect to the NPU bridge.

        Returns:
            Status response from the bridge.

        Raises:
            ConnectionError: If connection fails.
        """
        if self.is_connected:
            return self.ping()

        for attempt in range(self.config.retry_count):
            try:
                self._socket = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
                self._socket.settimeout(self.config.timeout)
                self._socket.connect((self.config.host, self.config.port))
                self._connected = True

                # Verify connection with ping
                response = self.ping()
                logger.info(f"Connected to NPU bridge: {response}")
                return response

            except socket.error as e:
                logger.warning(f"Connection attempt {attempt + 1} failed: {e}")
                if self._socket:
                    self._socket.close()
                    self._socket = None

                if attempt < self.config.retry_count - 1:
                    time.sleep(self.config.retry_delay)

        raise ConnectionError(
            f"Failed to connect to NPU bridge at {self.config.host}:{self.config.port}"
        )

    def close(self):
        """Close the connection."""
        if self._socket:
            try:
                self._socket.close()
            except socket.error:
                pass
            finally:
                self._socket = None
                self._connected = False

    def _send_request(self, request: Dict[str, Any]) -> Dict[str, Any]:
        """
        Send a request to the bridge and get response.

        Args:
            request: Request dictionary.

        Returns:
            Response dictionary.

        Raises:
            ConnectionError: If not connected.
            NPUClientError: If request fails.
        """
        if not self.is_connected:
            raise ConnectionError("Not connected to NPU bridge")

        try:
            # Send request
            data = json.dumps(request).encode('utf-8') + b'\n'
            self._socket.sendall(data)

            # Receive response
            response_data = b''
            while True:
                chunk = self._socket.recv(self.config.buffer_size)
                if not chunk:
                    break
                response_data += chunk
                if b'\n' in chunk:
                    break

            response = json.loads(response_data.decode('utf-8').strip())

            if response.get('status') == 'error':
                raise NPUClientError(response.get('message', 'Unknown error'))

            return response

        except socket.timeout:
            raise NPUClientError("Request timed out")
        except json.JSONDecodeError as e:
            raise NPUClientError(f"Invalid response: {e}")
        except socket.error as e:
            self._connected = False
            raise ConnectionError(f"Socket error: {e}")

    def ping(self) -> Dict[str, Any]:
        """
        Ping the bridge to check connection.

        Returns:
            Status response with provider info.
        """
        return self._send_request({"cmd": "ping"})

    def status(self) -> Dict[str, Any]:
        """
        Get bridge status.

        Returns:
            Status dictionary with provider, models, and history size.
        """
        return self._send_request({"cmd": "status"})

    def load_model(self, name: str, path: str) -> bool:
        """
        Load an ONNX model on the NPU.

        Args:
            name: Model name for later reference.
            path: Path to ONNX model file (on Windows).

        Returns:
            True if loaded successfully.
        """
        response = self._send_request({
            "cmd": "load_model",
            "name": name,
            "path": path
        })
        return response.get('status') == 'ok'

    def model_info(self, name: str) -> Optional[Dict[str, Any]]:
        """
        Get model input/output info.

        Args:
            name: Model name.

        Returns:
            Dictionary with 'inputs' and 'outputs' lists, or None.
        """
        response = self._send_request({
            "cmd": "model_info",
            "name": name
        })
        return response.get('info')

    def infer(
        self,
        name: str,
        inputs: Dict[str, List],
        timeout: Optional[float] = None
    ) -> Dict[str, List]:
        """
        Run inference on a loaded model.

        Args:
            name: Model name.
            inputs: Dictionary mapping input names to lists/arrays.
            timeout: Optional timeout override.

        Returns:
            Dictionary mapping output names to result lists.

        Raises:
            InferenceError: If inference fails.
        """
        # Store original timeout
        original_timeout = self._socket.gettimeout() if self._socket else None

        try:
            if timeout and self._socket:
                self._socket.settimeout(timeout)

            response = self._send_request({
                "cmd": "infer",
                "name": name,
                "inputs": inputs
            })

            if response.get('status') != 'ok':
                raise InferenceError(response.get('message', 'Inference failed'))

            return response.get('outputs', {})

        finally:
            if original_timeout and self._socket:
                self._socket.settimeout(original_timeout)

    def record_access(self, path: str) -> bool:
        """
        Record a file access for pattern learning.

        The bridge builds a model of file access patterns to predict
        which files should be prefetched.

        Args:
            path: File path that was accessed.

        Returns:
            True if recorded successfully.
        """
        # Hash the path to a numeric value
        path_hash = int(hashlib.md5(path.encode()).hexdigest()[:8], 16)

        response = self._send_request({
            "cmd": "record_access",
            "path_hash": path_hash
        })
        return response.get('status') == 'ok'

    def predict_next(self, count: int = 10) -> List[int]:
        """
        Predict the next likely file accesses.

        Returns hashed file identifiers for the predicted next files.
        Use this to prefetch files before they're needed.

        Args:
            count: Number of predictions to return.

        Returns:
            List of file path hashes.
        """
        response = self._send_request({
            "cmd": "predict_next",
            "count": count
        })
        return response.get('predictions', [])


@contextmanager
def npu_client(
    host: str = "localhost",
    port: int = 9999,
    timeout: float = 30.0
) -> NPUClient:
    """
    Context manager for NPU client.

    Example:
        with npu_client() as client:
            result = client.infer("model", {"input": [1, 2, 3]})
    """
    config = NPUClientConfig(host=host, port=port, timeout=timeout)
    client = NPUClient(config)
    try:
        client.connect()
        yield client
    finally:
        client.close()
