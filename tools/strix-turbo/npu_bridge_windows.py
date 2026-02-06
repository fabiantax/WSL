"""
Windows NPU Bridge for WSL2

Since AMD XDNA NPU has no WSL2 drivers, we run inference on Windows
and communicate with WSL2 via shared memory.

Architecture:
    ┌─────────────────────────────────────────────────────────────┐
    │                      WINDOWS                                 │
    │  ┌─────────────────────────────────────────────────────┐   │
    │  │           NPU Bridge Service (This Script)           │   │
    │  │  - Loads ONNX model on AMD XDNA NPU                 │   │
    │  │  - Listens on named pipe / shared memory            │   │
    │  │  - Runs inference on request                         │   │
    │  └─────────────────────────────────────────────────────┘   │
    │                           ▲                                 │
    │                           │ Named Pipe / TCP                │
    │                           │                                 │
    └───────────────────────────┼─────────────────────────────────┘
                                │
    ┌───────────────────────────┼─────────────────────────────────┐
    │                      WSL2 │                                 │
    │  ┌─────────────────────────────────────────────────────┐   │
    │  │              NPU Client (Python/C++)                 │   │
    │  │  - Sends inference requests to Windows              │   │
    │  │  - Receives predictions                              │   │
    │  │  - Uses predictions for I/O prefetching             │   │
    │  └─────────────────────────────────────────────────────┘   │
    └─────────────────────────────────────────────────────────────┘

Requirements:
    - Windows 11 with AMD XDNA driver
    - Python 3.10+ with onnxruntime-directml
    - AMD Ryzen AI SDK (optional, for full NPU access)

Install:
    pip install onnxruntime-directml numpy

Usage:
    # Start the bridge on Windows
    python npu_bridge_windows.py --model prefetcher.onnx --port 9999

    # From WSL2, connect via TCP
    nc localhost 9999

Author: Strix-Turbo Project
"""

import argparse
import json
import logging
import socket
import struct
import threading
import time
from pathlib import Path
from typing import Optional, Dict, Any, List
import numpy as np

# Try to import ONNX Runtime with DirectML (for NPU/GPU)
try:
    import onnxruntime as ort
    ONNX_AVAILABLE = True
except ImportError:
    ONNX_AVAILABLE = False
    print("WARNING: onnxruntime not installed. Install with: pip install onnxruntime-directml")


# =============================================================================
# Configuration
# =============================================================================

DEFAULT_PORT = 9999
DEFAULT_HOST = "127.0.0.1"
BUFFER_SIZE = 65536

logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s [%(levelname)s] %(message)s'
)
logger = logging.getLogger(__name__)


# =============================================================================
# NPU Session Manager
# =============================================================================

class NPUSessionManager:
    """Manages ONNX Runtime sessions on NPU/GPU via DirectML."""

    def __init__(self):
        self.sessions: Dict[str, ort.InferenceSession] = {}
        self.execution_provider = self._detect_best_provider()
        logger.info(f"Using execution provider: {self.execution_provider}")

    def _detect_best_provider(self) -> str:
        """Detect the best available execution provider."""
        available = ort.get_available_providers()
        logger.info(f"Available providers: {available}")

        # Priority: NPU (via DirectML) > GPU (DirectML) > CPU
        if 'DmlExecutionProvider' in available:
            # DirectML supports both NPU and GPU
            # On AMD Ryzen AI, it will use the NPU if available
            return 'DmlExecutionProvider'
        elif 'CUDAExecutionProvider' in available:
            return 'CUDAExecutionProvider'
        elif 'ROCMExecutionProvider' in available:
            return 'ROCMExecutionProvider'
        else:
            return 'CPUExecutionProvider'

    def load_model(self, name: str, model_path: str) -> bool:
        """Load an ONNX model."""
        try:
            # Session options for NPU optimization
            sess_options = ort.SessionOptions()
            sess_options.graph_optimization_level = ort.GraphOptimizationLevel.ORT_ENABLE_ALL
            sess_options.enable_mem_pattern = True

            # Create session with DirectML provider
            providers = [self.execution_provider, 'CPUExecutionProvider']
            session = ort.InferenceSession(
                model_path,
                sess_options,
                providers=providers
            )

            self.sessions[name] = session
            logger.info(f"Loaded model '{name}' from {model_path}")
            return True

        except Exception as e:
            logger.error(f"Failed to load model '{name}': {e}")
            return False

    def run_inference(self, name: str, inputs: Dict[str, np.ndarray]) -> Optional[Dict[str, np.ndarray]]:
        """Run inference on a loaded model."""
        if name not in self.sessions:
            logger.error(f"Model '{name}' not loaded")
            return None

        try:
            session = self.sessions[name]
            outputs = session.run(None, inputs)

            # Convert to dict with output names
            output_names = [o.name for o in session.get_outputs()]
            return dict(zip(output_names, outputs))

        except Exception as e:
            logger.error(f"Inference failed for '{name}': {e}")
            return None

    def get_model_info(self, name: str) -> Optional[Dict[str, Any]]:
        """Get input/output info for a model."""
        if name not in self.sessions:
            return None

        session = self.sessions[name]
        return {
            'inputs': [
                {'name': i.name, 'shape': i.shape, 'type': i.type}
                for i in session.get_inputs()
            ],
            'outputs': [
                {'name': o.name, 'shape': o.shape, 'type': o.type}
                for o in session.get_outputs()
            ]
        }


# =============================================================================
# I/O Prefetcher Model
# =============================================================================

class IOPrefetcherModel:
    """
    Lightweight model for predicting next file accesses.

    For the Strix-Turbo use case, we use a simple embedding + attention
    model that can run efficiently on the NPU.
    """

    def __init__(self, npu_manager: NPUSessionManager):
        self.npu = npu_manager
        self.model_loaded = False
        self.history: List[int] = []  # Recent file path hashes
        self.max_history = 64

    def load_or_create_model(self, model_path: Optional[str] = None) -> bool:
        """Load existing model or create a simple one."""
        if model_path and Path(model_path).exists():
            return self.npu.load_model('prefetcher', model_path)

        # Create a simple model for demonstration
        # In production, you'd train this on actual access patterns
        logger.info("No model provided, using hash-based prediction")
        self.model_loaded = False
        return True

    def record_access(self, path_hash: int):
        """Record a file access for pattern learning."""
        self.history.append(path_hash)
        if len(self.history) > self.max_history:
            self.history.pop(0)

    def predict_next(self, count: int = 10) -> List[int]:
        """Predict the next likely file accesses."""
        if not self.history:
            return []

        if self.model_loaded and 'prefetcher' in self.npu.sessions:
            # Use NPU model
            input_array = np.array(self.history[-self.max_history:], dtype=np.int64)
            input_array = np.pad(input_array, (self.max_history - len(input_array), 0))
            input_array = input_array.reshape(1, -1)

            result = self.npu.run_inference('prefetcher', {'input': input_array})
            if result:
                predictions = result['output'][0]
                top_k = np.argsort(predictions)[-count:][::-1]
                return top_k.tolist()

        # Fallback: simple frequency-based prediction
        from collections import Counter
        freq = Counter(self.history)
        return [h for h, _ in freq.most_common(count)]


# =============================================================================
# Bridge Server
# =============================================================================

class NPUBridgeServer:
    """TCP server that bridges WSL2 requests to Windows NPU."""

    def __init__(self, host: str, port: int, npu_manager: NPUSessionManager):
        self.host = host
        self.port = port
        self.npu = npu_manager
        self.prefetcher = IOPrefetcherModel(npu_manager)
        self.running = False
        self.socket = None

    def start(self):
        """Start the bridge server."""
        self.socket = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self.socket.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.socket.bind((self.host, self.port))
        self.socket.listen(5)
        self.running = True

        logger.info(f"NPU Bridge listening on {self.host}:{self.port}")
        logger.info(f"From WSL2, connect with: nc localhost {self.port}")

        while self.running:
            try:
                client, addr = self.socket.accept()
                logger.info(f"Connection from {addr}")
                thread = threading.Thread(target=self._handle_client, args=(client,))
                thread.daemon = True
                thread.start()
            except Exception as e:
                if self.running:
                    logger.error(f"Accept error: {e}")

    def stop(self):
        """Stop the server."""
        self.running = False
        if self.socket:
            self.socket.close()

    def _handle_client(self, client: socket.socket):
        """Handle a client connection."""
        try:
            while self.running:
                data = client.recv(BUFFER_SIZE)
                if not data:
                    break

                try:
                    request = json.loads(data.decode('utf-8'))
                    response = self._process_request(request)
                    client.send(json.dumps(response).encode('utf-8') + b'\n')
                except json.JSONDecodeError:
                    client.send(b'{"error": "Invalid JSON"}\n')
                except Exception as e:
                    client.send(json.dumps({'error': str(e)}).encode('utf-8') + b'\n')

        except Exception as e:
            logger.error(f"Client handler error: {e}")
        finally:
            client.close()

    def _process_request(self, request: Dict[str, Any]) -> Dict[str, Any]:
        """Process a request from WSL2."""
        cmd = request.get('cmd', '')

        if cmd == 'ping':
            return {'status': 'ok', 'provider': self.npu.execution_provider}

        elif cmd == 'load_model':
            name = request.get('name', 'default')
            path = request.get('path', '')
            success = self.npu.load_model(name, path)
            return {'status': 'ok' if success else 'error'}

        elif cmd == 'model_info':
            name = request.get('name', 'default')
            info = self.npu.get_model_info(name)
            return {'status': 'ok', 'info': info} if info else {'status': 'error'}

        elif cmd == 'infer':
            name = request.get('name', 'default')
            inputs = request.get('inputs', {})
            # Convert lists to numpy arrays
            np_inputs = {k: np.array(v) for k, v in inputs.items()}
            result = self.npu.run_inference(name, np_inputs)
            if result:
                # Convert numpy arrays to lists for JSON
                return {'status': 'ok', 'outputs': {k: v.tolist() for k, v in result.items()}}
            return {'status': 'error'}

        elif cmd == 'record_access':
            path_hash = request.get('path_hash', 0)
            self.prefetcher.record_access(path_hash)
            return {'status': 'ok'}

        elif cmd == 'predict_next':
            count = request.get('count', 10)
            predictions = self.prefetcher.predict_next(count)
            return {'status': 'ok', 'predictions': predictions}

        elif cmd == 'status':
            return {
                'status': 'ok',
                'provider': self.npu.execution_provider,
                'models': list(self.npu.sessions.keys()),
                'history_size': len(self.prefetcher.history)
            }

        else:
            return {'status': 'error', 'message': f'Unknown command: {cmd}'}


# =============================================================================
# WSL2 Client (for reference)
# =============================================================================

WSL2_CLIENT_CODE = '''
#!/usr/bin/env python3
"""
NPU Bridge Client for WSL2

Usage:
    from npu_client import NPUClient

    client = NPUClient()
    client.connect()

    # Record file access
    client.record_access("/path/to/file")

    # Get predictions
    next_files = client.predict_next(10)
    print(f"Prefetch these: {next_files}")
"""

import json
import socket
import hashlib


class NPUClient:
    def __init__(self, host="localhost", port=9999):
        self.host = host
        self.port = port
        self.socket = None

    def connect(self):
        self.socket = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self.socket.connect((self.host, self.port))
        return self._send({"cmd": "ping"})

    def _send(self, request):
        self.socket.send(json.dumps(request).encode() + b"\\n")
        response = self.socket.recv(65536)
        return json.loads(response.decode())

    def record_access(self, path: str):
        path_hash = int(hashlib.md5(path.encode()).hexdigest()[:8], 16)
        return self._send({"cmd": "record_access", "path_hash": path_hash})

    def predict_next(self, count: int = 10):
        return self._send({"cmd": "predict_next", "count": count})

    def status(self):
        return self._send({"cmd": "status"})

    def close(self):
        if self.socket:
            self.socket.close()


if __name__ == "__main__":
    client = NPUClient()
    print(client.connect())
    print(client.status())
'''


# =============================================================================
# Main
# =============================================================================

def main():
    parser = argparse.ArgumentParser(
        description='NPU Bridge: Run NPU inference on Windows for WSL2'
    )
    parser.add_argument('--host', default=DEFAULT_HOST, help='Listen host')
    parser.add_argument('--port', type=int, default=DEFAULT_PORT, help='Listen port')
    parser.add_argument('--model', help='Path to ONNX model file')
    parser.add_argument('--generate-client', action='store_true',
                       help='Generate WSL2 client script')
    args = parser.parse_args()

    if args.generate_client:
        print(WSL2_CLIENT_CODE)
        return

    if not ONNX_AVAILABLE:
        print("ERROR: onnxruntime not installed")
        print("Install with: pip install onnxruntime-directml")
        return

    # Initialize NPU manager
    npu = NPUSessionManager()

    # Load model if provided
    if args.model:
        npu.load_model('prefetcher', args.model)

    # Start server
    server = NPUBridgeServer(args.host, args.port, npu)
    try:
        server.start()
    except KeyboardInterrupt:
        logger.info("Shutting down...")
        server.stop()


if __name__ == '__main__':
    main()
