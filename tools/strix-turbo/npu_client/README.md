# Strix-Turbo NPU Client

WSL2 client libraries for accessing the AMD XDNA NPU through the Windows bridge.

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                      WINDOWS                                 │
│  ┌─────────────────────────────────────────────────────┐   │
│  │           NPU Bridge (npu_bridge_windows.py)        │   │
│  │  - ONNX Runtime + DirectML                          │   │
│  │  - TCP server on port 9999                          │   │
│  └─────────────────────────────────────────────────────┘   │
│                           ▲                                 │
│                           │ TCP/JSON                        │
└───────────────────────────┼─────────────────────────────────┘
                            │
┌───────────────────────────┼─────────────────────────────────┐
│                      WSL2 │                                 │
│  ┌─────────────────────────────────────────────────────┐   │
│  │              NPU Client (this library)              │   │
│  │  - Python: strix_npu package                        │   │
│  │  - C: libstrix_npu.so                               │   │
│  └─────────────────────────────────────────────────────┘   │
│                                                              │
│  Applications:                                               │
│  ┌────────────┐  ┌────────────┐  ┌────────────┐            │
│  │   Python   │  │  C/C++     │  │   Rust     │            │
│  │   Apps     │  │  Apps      │  │   (via C)  │            │
│  └────────────┘  └────────────┘  └────────────┘            │
└──────────────────────────────────────────────────────────────┘
```

## Python Client

### Installation

```bash
cd python
pip install .
```

### Usage

```python
from strix_npu import NPUClient

# Connect to bridge
with NPUClient() as client:
    # Check status
    print(client.status())

    # Run inference
    result = client.infer("model", {"input": [[1.0, 2.0, 3.0]]})
    print(result)

    # File prefetching
    client.record_access("/path/to/file")
    predictions = client.predict_next(10)
```

### Async Usage

```python
import asyncio
from strix_npu import AsyncNPUClient

async def main():
    async with AsyncNPUClient() as client:
        # Multiple concurrent inferences
        results = await asyncio.gather(
            client.infer("model", {"input": [1, 2, 3]}),
            client.infer("model", {"input": [4, 5, 6]}),
            client.infer("model", {"input": [7, 8, 9]})
        )
        print(results)

asyncio.run(main())
```

## C Library

### Building

```bash
cd c
make
```

### Usage

```c
#include <strix_npu.h>

int main() {
    // Create and connect
    strix_npu_client_t* client = strix_npu_create("localhost", 9999);
    if (strix_npu_connect(client) != STRIX_NPU_OK) {
        printf("Failed: %s\n", strix_npu_last_error_msg(client));
        return 1;
    }

    // Run inference
    float input[] = {1.0f, 2.0f, 3.0f};
    strix_npu_infer_t infer = {
        .model_name = "model",
        .input_name = "input",
        .input_data = input,
        .input_size = 3
    };

    if (strix_npu_infer(client, &infer) == STRIX_NPU_OK) {
        printf("Output: ");
        for (size_t i = 0; i < infer.output_size; i++) {
            printf("%f ", infer.output_data[i]);
        }
        printf("\n");
        strix_npu_free_output(&infer);
    }

    // File prefetching
    strix_npu_record_access(client, "/path/to/file");

    strix_npu_predictions_t predictions;
    strix_npu_predict_next(client, 10, &predictions);
    printf("Predictions: %zu\n", predictions.count);
    strix_npu_free_predictions(&predictions);

    strix_npu_destroy(client);
    return 0;
}
```

### Linking

```bash
gcc -o myapp myapp.c -lstrix_npu
```

## API Reference

### Commands

| Command | Description | Request | Response |
|---------|-------------|---------|----------|
| `ping` | Check connection | `{"cmd":"ping"}` | `{"status":"ok","provider":"..."}` |
| `status` | Get bridge status | `{"cmd":"status"}` | `{"status":"ok","models":[...],"history_size":N}` |
| `load_model` | Load ONNX model | `{"cmd":"load_model","name":"...","path":"..."}` | `{"status":"ok"}` |
| `model_info` | Get model info | `{"cmd":"model_info","name":"..."}` | `{"status":"ok","info":{...}}` |
| `infer` | Run inference | `{"cmd":"infer","name":"...","inputs":{...}}` | `{"status":"ok","outputs":{...}}` |
| `record_access` | Record file access | `{"cmd":"record_access","path_hash":N}` | `{"status":"ok"}` |
| `predict_next` | Predict next files | `{"cmd":"predict_next","count":N}` | `{"status":"ok","predictions":[...]}` |

## Testing

### Python

```bash
cd python
pip install -e ".[dev]"
pytest tests/
```

### C

```bash
cd c
make test
```

**Note:** Integration tests require the NPU bridge running on Windows:

```powershell
# On Windows
python npu_bridge_windows.py --port 9999
```

## Use Cases

### 1. NPU-Accelerated ML Inference

Access XDNA NPU from WSL2 for ML workloads:

```python
from strix_npu import NPUClient

client = NPUClient()
client.connect()
client.load_model("classifier", "C:\\Models\\classifier.onnx")

# Run inference
result = client.infer("classifier", {"input": preprocessed_image})
```

### 2. Intelligent File Prefetching

Use NPU to predict file accesses and prefetch:

```python
from strix_npu import NPUClient
import os

client = NPUClient()
client.connect()

# Record access patterns
for file in accessed_files:
    client.record_access(file)

# Get predictions
predictions = client.predict_next(20)

# Prefetch predicted files
for path_hash in predictions:
    # Trigger prefetch via Strix-Turbo cache
    pass
```

### 3. Build System Optimization

Predict which source files will be compiled next:

```python
# In build system wrapper
client.record_access(current_file)
next_files = client.predict_next(10)
# Prefetch next_files in background
```

## License

MIT License - Strix-Turbo Project 2026
