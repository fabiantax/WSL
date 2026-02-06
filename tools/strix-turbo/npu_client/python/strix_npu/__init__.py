"""
Strix-Turbo NPU Client for WSL2

Provides access to the AMD XDNA NPU from within WSL2 by communicating
with a Windows-side bridge service.

Example:
    from strix_npu import NPUClient

    # Connect to bridge
    client = NPUClient()
    client.connect()

    # Run inference
    result = client.infer("model_name", {"input": [1.0, 2.0, 3.0]})
    print(result)

    # File access prediction
    client.record_access("/path/to/file")
    predictions = client.predict_next(10)
"""

from .client import NPUClient
from .async_client import AsyncNPUClient

__version__ = "0.1.0"
__author__ = "Strix-Turbo Project"

__all__ = ["NPUClient", "AsyncNPUClient"]
