"""
Asynchronous NPU Client for WSL2

Provides async/await interface for non-blocking communication with NPU bridge.
"""

import asyncio
import json
import hashlib
import logging
from typing import Dict, List, Any, Optional
from dataclasses import dataclass

logger = logging.getLogger(__name__)


@dataclass
class AsyncNPUClientConfig:
    """Configuration for async NPU client."""
    host: str = "localhost"
    port: int = 9999
    timeout: float = 30.0
    retry_count: int = 3
    retry_delay: float = 1.0
    buffer_size: int = 65536


class AsyncNPUClientError(Exception):
    """Base exception for async NPU client errors."""
    pass


class AsyncConnectionError(AsyncNPUClientError):
    """Failed to connect to NPU bridge."""
    pass


class AsyncInferenceError(AsyncNPUClientError):
    """Inference failed."""
    pass


class AsyncNPUClient:
    """
    Asynchronous NPU client for WSL2.

    Uses asyncio for non-blocking communication with the NPU bridge.

    Example:
        async with AsyncNPUClient() as client:
            result = await client.infer("model", {"input": [1, 2, 3]})
            print(result)
    """

    def __init__(self, config: Optional[AsyncNPUClientConfig] = None):
        """
        Initialize async NPU client.

        Args:
            config: Client configuration. Uses defaults if not provided.
        """
        self.config = config or AsyncNPUClientConfig()
        self._reader: Optional[asyncio.StreamReader] = None
        self._writer: Optional[asyncio.StreamWriter] = None
        self._connected = False
        self._lock = asyncio.Lock()

    async def __aenter__(self):
        """Async context manager entry."""
        await self.connect()
        return self

    async def __aexit__(self, exc_type, exc_val, exc_tb):
        """Async context manager exit."""
        await self.close()
        return False

    @property
    def is_connected(self) -> bool:
        """Check if client is connected."""
        return self._connected and self._writer is not None

    async def connect(self) -> Dict[str, Any]:
        """
        Connect to the NPU bridge asynchronously.

        Returns:
            Status response from the bridge.

        Raises:
            AsyncConnectionError: If connection fails.
        """
        if self.is_connected:
            return await self.ping()

        for attempt in range(self.config.retry_count):
            try:
                self._reader, self._writer = await asyncio.wait_for(
                    asyncio.open_connection(self.config.host, self.config.port),
                    timeout=self.config.timeout
                )
                self._connected = True

                # Verify connection with ping
                response = await self.ping()
                logger.info(f"Connected to NPU bridge: {response}")
                return response

            except (asyncio.TimeoutError, OSError) as e:
                logger.warning(f"Connection attempt {attempt + 1} failed: {e}")
                await self._cleanup()

                if attempt < self.config.retry_count - 1:
                    await asyncio.sleep(self.config.retry_delay)

        raise AsyncConnectionError(
            f"Failed to connect to NPU bridge at {self.config.host}:{self.config.port}"
        )

    async def _cleanup(self):
        """Clean up connection resources."""
        if self._writer:
            try:
                self._writer.close()
                await self._writer.wait_closed()
            except Exception:
                pass
        self._reader = None
        self._writer = None
        self._connected = False

    async def close(self):
        """Close the connection."""
        await self._cleanup()

    async def _send_request(self, request: Dict[str, Any]) -> Dict[str, Any]:
        """
        Send a request to the bridge and get response.

        Args:
            request: Request dictionary.

        Returns:
            Response dictionary.

        Raises:
            AsyncConnectionError: If not connected.
            AsyncNPUClientError: If request fails.
        """
        if not self.is_connected:
            raise AsyncConnectionError("Not connected to NPU bridge")

        async with self._lock:
            try:
                # Send request
                data = json.dumps(request).encode('utf-8') + b'\n'
                self._writer.write(data)
                await self._writer.drain()

                # Receive response
                response_data = await asyncio.wait_for(
                    self._reader.readline(),
                    timeout=self.config.timeout
                )

                if not response_data:
                    raise AsyncConnectionError("Connection closed by server")

                response = json.loads(response_data.decode('utf-8').strip())

                if response.get('status') == 'error':
                    raise AsyncNPUClientError(response.get('message', 'Unknown error'))

                return response

            except asyncio.TimeoutError:
                raise AsyncNPUClientError("Request timed out")
            except json.JSONDecodeError as e:
                raise AsyncNPUClientError(f"Invalid response: {e}")
            except OSError as e:
                self._connected = False
                raise AsyncConnectionError(f"Socket error: {e}")

    async def ping(self) -> Dict[str, Any]:
        """
        Ping the bridge to check connection.

        Returns:
            Status response with provider info.
        """
        return await self._send_request({"cmd": "ping"})

    async def status(self) -> Dict[str, Any]:
        """
        Get bridge status.

        Returns:
            Status dictionary with provider, models, and history size.
        """
        return await self._send_request({"cmd": "status"})

    async def load_model(self, name: str, path: str) -> bool:
        """
        Load an ONNX model on the NPU.

        Args:
            name: Model name for later reference.
            path: Path to ONNX model file (on Windows).

        Returns:
            True if loaded successfully.
        """
        response = await self._send_request({
            "cmd": "load_model",
            "name": name,
            "path": path
        })
        return response.get('status') == 'ok'

    async def model_info(self, name: str) -> Optional[Dict[str, Any]]:
        """
        Get model input/output info.

        Args:
            name: Model name.

        Returns:
            Dictionary with 'inputs' and 'outputs' lists, or None.
        """
        response = await self._send_request({
            "cmd": "model_info",
            "name": name
        })
        return response.get('info')

    async def infer(
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
            AsyncInferenceError: If inference fails.
        """
        # Temporarily adjust timeout if provided
        original_timeout = self.config.timeout
        if timeout:
            self.config.timeout = timeout

        try:
            response = await self._send_request({
                "cmd": "infer",
                "name": name,
                "inputs": inputs
            })

            if response.get('status') != 'ok':
                raise AsyncInferenceError(response.get('message', 'Inference failed'))

            return response.get('outputs', {})

        finally:
            self.config.timeout = original_timeout

    async def record_access(self, path: str) -> bool:
        """
        Record a file access for pattern learning.

        Args:
            path: File path that was accessed.

        Returns:
            True if recorded successfully.
        """
        path_hash = int(hashlib.md5(path.encode()).hexdigest()[:8], 16)

        response = await self._send_request({
            "cmd": "record_access",
            "path_hash": path_hash
        })
        return response.get('status') == 'ok'

    async def predict_next(self, count: int = 10) -> List[int]:
        """
        Predict the next likely file accesses.

        Args:
            count: Number of predictions to return.

        Returns:
            List of file path hashes.
        """
        response = await self._send_request({
            "cmd": "predict_next",
            "count": count
        })
        return response.get('predictions', [])

    async def batch_record(self, paths: List[str]) -> int:
        """
        Record multiple file accesses in one call.

        Args:
            paths: List of file paths.

        Returns:
            Number of paths recorded.
        """
        count = 0
        for path in paths:
            if await self.record_access(path):
                count += 1
        return count


class NPUClientPool:
    """
    Pool of async NPU clients for concurrent requests.

    Useful when you need to make many concurrent inference requests.
    """

    def __init__(
        self,
        size: int = 4,
        config: Optional[AsyncNPUClientConfig] = None
    ):
        """
        Initialize client pool.

        Args:
            size: Number of clients in the pool.
            config: Client configuration.
        """
        self.size = size
        self.config = config or AsyncNPUClientConfig()
        self._clients: List[AsyncNPUClient] = []
        self._semaphore: Optional[asyncio.Semaphore] = None
        self._index = 0
        self._lock = asyncio.Lock()

    async def __aenter__(self):
        """Async context manager entry."""
        await self.start()
        return self

    async def __aexit__(self, exc_type, exc_val, exc_tb):
        """Async context manager exit."""
        await self.stop()
        return False

    async def start(self):
        """Start all clients in the pool."""
        self._semaphore = asyncio.Semaphore(self.size)
        self._clients = []

        for _ in range(self.size):
            client = AsyncNPUClient(self.config)
            await client.connect()
            self._clients.append(client)

        logger.info(f"Started NPU client pool with {self.size} clients")

    async def stop(self):
        """Stop all clients in the pool."""
        for client in self._clients:
            await client.close()
        self._clients = []

    async def _get_client(self) -> AsyncNPUClient:
        """Get next client from pool (round-robin)."""
        async with self._lock:
            client = self._clients[self._index]
            self._index = (self._index + 1) % len(self._clients)
            return client

    async def infer(
        self,
        name: str,
        inputs: Dict[str, List],
        timeout: Optional[float] = None
    ) -> Dict[str, List]:
        """
        Run inference using a pooled client.

        Args:
            name: Model name.
            inputs: Input dictionary.
            timeout: Optional timeout.

        Returns:
            Inference results.
        """
        async with self._semaphore:
            client = await self._get_client()
            return await client.infer(name, inputs, timeout)

    async def batch_infer(
        self,
        name: str,
        batch_inputs: List[Dict[str, List]],
        timeout: Optional[float] = None
    ) -> List[Dict[str, List]]:
        """
        Run multiple inferences concurrently.

        Args:
            name: Model name.
            batch_inputs: List of input dictionaries.
            timeout: Optional timeout per inference.

        Returns:
            List of inference results.
        """
        tasks = [
            self.infer(name, inputs, timeout)
            for inputs in batch_inputs
        ]
        return await asyncio.gather(*tasks)
