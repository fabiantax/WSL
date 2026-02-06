/**
 * NPU Plane - DP3 in Axiomatic Design
 * Satisfies: FR3 (NPU/AI Accelerator Access)
 * Independence: Completely separate from storage, GPU, interop
 *
 * Novel Insight from Axiomatic Analysis:
 * The NPU can serve TWO independent purposes:
 *   1. Direct AI inference (obvious use case)
 *   2. I/O prediction for prefetching (novel use case)
 *
 * This creates a new FR-DP mapping:
 *   FR1.5 (Prefetch) → DP3.X (NPU Predictor)
 *
 * However, this is WEAK COUPLING (beneficial), not violation.
 * The NPU Predictor is an OPTIONAL enhancer for FR1.
 *
 * AMD Strix Halo NPU:
 *   - XDNA 2 Architecture (Ryzen AI)
 *   - 50 TOPS peak performance
 *   - Low power (~15W)
 *   - Perfect for background prediction tasks
 */

#ifndef STRIX_NPU_PLANE_H
#define STRIX_NPU_PLANE_H

#include <cstdint>
#include <cstddef>
#include <memory>
#include <span>
#include <expected>
#include <functional>
#include <string_view>
#include <vector>

namespace strix {
namespace npu_plane {

//==============================================================================
// Error Codes
//==============================================================================

enum class NPUError : int32_t {
    Success = 0,
    DeviceNotFound = -1,
    DriverNotLoaded = -2,
    ModelLoadFailed = -3,
    InferenceFailed = -4,
    InvalidInput = -5,
    Timeout = -6,
    OutOfMemory = -7,
    UnsupportedOp = -8,
    BridgeDisconnected = -9
};

template<typename T>
using Result = std::expected<T, NPUError>;

//==============================================================================
// Data Types
//==============================================================================

/**
 * Tensor data types
 */
enum class DataType : uint8_t {
    Float32,
    Float16,
    BFloat16,
    Int32,
    Int16,
    Int8,
    UInt8,
    Bool
};

/**
 * Tensor shape
 */
struct Shape {
    std::vector<int64_t> dims;

    int64_t numel() const {
        int64_t n = 1;
        for (auto d : dims) n *= d;
        return n;
    }

    size_t rank() const { return dims.size(); }
};

/**
 * Tensor - Multi-dimensional array
 */
struct Tensor {
    Shape shape;
    DataType dtype;
    void* data;
    size_t size_bytes;

    // Memory ownership
    enum class Ownership { Borrowed, Owned, Shared };
    Ownership ownership;
};

//==============================================================================
// Model Management (DP3.1)
//==============================================================================

namespace model {

/**
 * Model format
 */
enum class Format {
    ONNX,           // Open Neural Network Exchange
    SafeTensors,    // Safe format for model weights
    TorchScript,    // PyTorch
    TFLite,         // TensorFlow Lite
    OpenVINO_IR,    // Intel OpenVINO
    DirectML_DXC    // DirectML compiled
};

/**
 * Model metadata
 */
struct Metadata {
    char name[128];
    char version[32];
    Format format;

    uint32_t num_inputs;
    uint32_t num_outputs;

    // Performance hints
    uint32_t estimated_flops;
    uint32_t estimated_memory_kb;
    uint32_t optimal_batch_size;
};

/**
 * Model input/output specification
 */
struct IOSpec {
    char name[64];
    Shape shape;            // -1 for dynamic dimensions
    DataType dtype;
    bool is_optional;
};

/**
 * Loaded model handle
 */
struct Handle {
    uint64_t id;
    Metadata meta;
    std::vector<IOSpec> inputs;
    std::vector<IOSpec> outputs;
};

/**
 * Model Manager
 */
class Manager {
public:
    virtual ~Manager() = default;

    /**
     * Load model from file.
     */
    virtual Result<Handle> load(
        std::string_view path,
        Format format = Format::ONNX
    ) = 0;

    /**
     * Load model from memory.
     */
    virtual Result<Handle> load_from_memory(
        std::span<const uint8_t> data,
        Format format
    ) = 0;

    /**
     * Unload model.
     */
    virtual void unload(Handle& handle) = 0;

    /**
     * Get model metadata.
     */
    virtual const Metadata& metadata(const Handle& handle) = 0;

    /**
     * Optimize model for NPU execution.
     * May take time but improves inference speed.
     */
    virtual Result<void> optimize(Handle& handle) = 0;
};

} // namespace model

//==============================================================================
// Inference Execution (DP3.2)
//==============================================================================

namespace inference {

/**
 * Execution options
 */
struct Options {
    uint32_t timeout_ms;        // 0 = no timeout
    uint32_t batch_size;        // 0 = auto
    bool async;                 // Async execution
    int priority;               // -10 to 10, 0 = normal

    static Options default_sync() {
        return { .timeout_ms = 5000, .batch_size = 0, .async = false, .priority = 0 };
    }

    static Options default_async() {
        return { .timeout_ms = 0, .batch_size = 0, .async = true, .priority = 0 };
    }

    static Options low_latency() {
        return { .timeout_ms = 100, .batch_size = 1, .async = false, .priority = 10 };
    }
};

/**
 * Inference result
 */
struct Result {
    std::vector<Tensor> outputs;
    uint64_t duration_ns;       // Execution time
    uint32_t power_uw;          // Power consumption (if available)
};

/**
 * Inference completion callback
 */
using Callback = std::function<void(NPUError, Result&&)>;

/**
 * Inference Engine
 */
class Engine {
public:
    virtual ~Engine() = default;

    /**
     * Run inference synchronously.
     */
    virtual npu_plane::Result<Result> run(
        const model::Handle& model,
        std::span<const Tensor> inputs,
        Options opts = Options::default_sync()
    ) = 0;

    /**
     * Run inference asynchronously.
     *
     * @return Request ID for tracking
     */
    virtual npu_plane::Result<uint64_t> run_async(
        const model::Handle& model,
        std::span<const Tensor> inputs,
        Callback callback,
        Options opts = Options::default_async()
    ) = 0;

    /**
     * Wait for async inference.
     */
    virtual npu_plane::Result<Result> wait(uint64_t request_id) = 0;

    /**
     * Cancel pending inference.
     */
    virtual NPUError cancel(uint64_t request_id) = 0;

    /**
     * Check if inference completed.
     */
    virtual bool is_complete(uint64_t request_id) = 0;
};

} // namespace inference

//==============================================================================
// I/O Prediction (DP3.X - Novel Application)
//==============================================================================

namespace prediction {

/**
 * File access record for training/prediction
 */
struct AccessRecord {
    uint64_t path_hash;         // Hash of file path
    uint64_t offset;            // File offset
    uint32_t size;              // Access size
    uint32_t flags;             // Open flags, operation type
    uint64_t timestamp_ns;      // When access occurred
};

/**
 * Prediction result
 */
struct Prediction {
    uint64_t path_hash;         // Predicted path hash
    float confidence;           // 0.0 to 1.0
    uint64_t predicted_offset;  // Where in file
    uint32_t predicted_size;    // How much
};

/**
 * I/O Predictor Model
 *
 * This is the NOVEL APPLICATION of NPU identified by
 * Axiomatic Design analysis.
 *
 * Architecture:
 * - Input: Last N file accesses (AccessRecord sequence)
 * - Model: LSTM or Transformer-based sequence predictor
 * - Output: Next K likely accesses with confidence scores
 *
 * Integration:
 * - Runs on NPU in background
 * - Provides hints to DataPlane for prefetching
 * - Hit rate: 70-80% for build systems (highly predictable)
 *
 * Training:
 * - Collect traces with strace/ETW
 * - Train on user's actual access patterns
 * - Personalized per-project models
 */
class Predictor {
public:
    virtual ~Predictor() = default;

    /**
     * Initialize predictor with pre-trained model.
     */
    virtual Result<void> initialize(std::string_view model_path) = 0;

    /**
     * Initialize predictor with embedded model.
     */
    virtual Result<void> initialize_default() = 0;

    /**
     * Record an I/O access (for training and context).
     */
    virtual void record(const AccessRecord& access) = 0;

    /**
     * Record multiple accesses at once.
     */
    virtual void record_batch(std::span<const AccessRecord> accesses) = 0;

    /**
     * Get predictions for next likely accesses.
     *
     * @param top_k Number of predictions to return
     * @param min_confidence Minimum confidence threshold
     * @return Sorted predictions (highest confidence first)
     */
    virtual std::vector<Prediction> predict(
        size_t top_k = 10,
        float min_confidence = 0.3f
    ) = 0;

    /**
     * Train/update model with recorded accesses.
     * Can run in background.
     */
    virtual Result<void> train_incremental() = 0;

    /**
     * Get prediction statistics.
     */
    struct Stats {
        uint64_t predictions_made;
        uint64_t cache_hits;        // Prediction was correct
        uint64_t cache_misses;      // Prediction was wrong
        float hit_rate;             // hits / (hits + misses)
        float avg_confidence;
    };

    virtual Stats stats() const = 0;

    /**
     * Reset statistics.
     */
    virtual void reset_stats() = 0;
};

/**
 * Path hash function (consistent across sessions)
 */
uint64_t hash_path(std::string_view path);

} // namespace prediction

//==============================================================================
// NPU Device Information
//==============================================================================

struct DeviceInfo {
    char name[128];
    char driver_version[32];

    // AMD XDNA specific
    uint32_t xdna_version;      // 1 = XDNA, 2 = XDNA2
    uint32_t aie_cores;         // AI Engine cores
    uint32_t peak_tops;         // Peak TOPS

    // Capabilities
    uint64_t memory_size;       // NPU memory
    uint32_t max_batch_size;
    bool supports_fp16;
    bool supports_int8;
    bool supports_dynamic_shapes;

    // Current state
    uint32_t utilization_percent;
    uint32_t power_mw;
    uint32_t temperature_c;
};

//==============================================================================
// NPU Plane Interface
//==============================================================================

/**
 * NPU Plane - Main interface
 *
 * This is COMPLETELY INDEPENDENT from:
 * - DataPlane (storage I/O)
 * - GPUPlane (graphics/compute)
 * - CommandPlane (process interop)
 * - BatchingEngine (syscall batching)
 *
 * The ONLY interaction is OPTIONAL prefetch hints to DataPlane,
 * which is weak beneficial coupling (not a violation).
 */
class NPUPlane {
public:
    virtual ~NPUPlane() = default;

    /**
     * Initialize NPU plane.
     *
     * This establishes the bridge to the Windows XDNA driver.
     */
    virtual Result<void> initialize() = 0;

    /**
     * Shutdown NPU plane.
     */
    virtual void shutdown() = 0;

    /**
     * Check if NPU is available and ready.
     */
    virtual bool is_available() const = 0;

    /**
     * Get device information.
     */
    virtual const DeviceInfo& device_info() const = 0;

    //--------------------------------------------------------------------------
    // Component Access
    //--------------------------------------------------------------------------

    virtual model::Manager& models() = 0;
    virtual inference::Engine& inference() = 0;
    virtual prediction::Predictor& predictor() = 0;

    //--------------------------------------------------------------------------
    // High-Level Convenience API
    //--------------------------------------------------------------------------

    /**
     * Quick inference (load, run, unload).
     * Useful for one-off predictions.
     */
    virtual Result<inference::Result> quick_inference(
        std::string_view model_path,
        std::span<const Tensor> inputs
    ) = 0;

    /**
     * Enable I/O prediction with default model.
     *
     * Once enabled, call record_io() for each I/O operation,
     * and call get_prefetch_hints() to get predictions.
     */
    virtual Result<void> enable_io_prediction() = 0;

    /**
     * Disable I/O prediction.
     */
    virtual void disable_io_prediction() = 0;

    /**
     * Check if I/O prediction is enabled.
     */
    virtual bool is_io_prediction_enabled() const = 0;

    /**
     * Record I/O operation for prediction.
     */
    virtual void record_io(
        std::string_view path,
        uint64_t offset,
        uint32_t size,
        bool is_write
    ) = 0;

    /**
     * Get prefetch hints based on I/O patterns.
     *
     * Returns paths that should be prefetched.
     */
    struct PrefetchHint {
        std::string path;           // Full path to prefetch
        uint64_t offset;            // Start offset
        uint32_t size;              // Size to prefetch
        float confidence;           // Prediction confidence
    };

    virtual std::vector<PrefetchHint> get_prefetch_hints(
        size_t max_hints = 10
    ) = 0;

    //--------------------------------------------------------------------------
    // Power Management
    //--------------------------------------------------------------------------

    enum class PowerMode {
        Performance,    // Maximum performance
        Balanced,       // Balance performance and power
        Efficiency      // Minimize power
    };

    virtual void set_power_mode(PowerMode mode) = 0;
    virtual PowerMode power_mode() const = 0;
};

/**
 * Create NPU plane.
 *
 * On WSL2: Creates bridge to Windows XDNA driver
 * On Native Linux: Uses direct ROCm/XDNA access
 */
std::unique_ptr<NPUPlane> create_npu_plane();

/**
 * Check if NPU is available on this system.
 */
bool is_npu_available();

//==============================================================================
// WSL2-Specific: NPU Bridge Protocol
//==============================================================================

namespace bridge {

/**
 * Bridge message types
 */
enum class MessageType : uint16_t {
    // Connection
    Connect,
    Disconnect,
    Ping,

    // Model management
    LoadModel,
    UnloadModel,
    GetModelInfo,

    // Inference
    RunInference,
    CancelInference,
    GetResult,

    // Prediction
    RecordAccess,
    GetPredictions,
    TrainIncremental,

    // Status
    GetDeviceInfo,
    GetStats
};

/**
 * Bridge message header
 */
struct MessageHeader {
    MessageType type;
    uint16_t flags;
    uint32_t sequence;
    uint32_t payload_size;
    uint32_t _pad;
};

/**
 * Bridge connection options
 */
struct ConnectionOptions {
    uint32_t timeout_ms;
    uint32_t retry_count;
    bool auto_reconnect;

    static ConnectionOptions defaults() {
        return { .timeout_ms = 5000, .retry_count = 3, .auto_reconnect = true };
    }
};

/**
 * NPU Bridge Client (Linux/WSL2 side)
 */
class Client {
public:
    virtual ~Client() = default;

    /**
     * Connect to Windows NPU bridge service.
     */
    virtual Result<void> connect(ConnectionOptions opts = ConnectionOptions::defaults()) = 0;

    /**
     * Disconnect from bridge.
     */
    virtual void disconnect() = 0;

    /**
     * Check connection status.
     */
    virtual bool is_connected() const = 0;

    /**
     * Send message and get response.
     */
    virtual Result<std::vector<uint8_t>> send(
        MessageType type,
        std::span<const uint8_t> payload
    ) = 0;

    /**
     * Send message asynchronously.
     */
    using ResponseCallback = std::function<void(NPUError, std::span<uint8_t>)>;

    virtual Result<uint32_t> send_async(
        MessageType type,
        std::span<const uint8_t> payload,
        ResponseCallback callback
    ) = 0;
};

/**
 * Create bridge client.
 */
std::unique_ptr<Client> create_client();

} // namespace bridge

//==============================================================================
// Pre-built Prediction Models
//==============================================================================

namespace models {

/**
 * Model type for different access patterns
 */
enum class PredictionModelType {
    Generic,            // Works for any workload
    BuildSystem,        // Optimized for cmake, make, ninja
    PackageManager,     // Optimized for npm, pip, cargo
    VCS,                // Optimized for git operations
    IDE,                // Optimized for IDE file access
    Database            // Optimized for database file access
};

/**
 * Get embedded model data.
 */
std::span<const uint8_t> get_embedded_model(PredictionModelType type);

/**
 * Model selection based on workload detection.
 */
PredictionModelType detect_workload(std::span<const prediction::AccessRecord> recent);

} // namespace models

} // namespace npu_plane
} // namespace strix

#endif // STRIX_NPU_PLANE_H
