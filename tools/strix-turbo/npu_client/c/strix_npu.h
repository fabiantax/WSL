/*
 * Strix-Turbo NPU Client - C Library
 *
 * C library for communicating with the Windows NPU bridge from WSL2.
 * Provides access to AMD XDNA NPU for inference and file prefetching.
 *
 * Example:
 *     strix_npu_client_t* client = strix_npu_create("localhost", 9999);
 *     if (strix_npu_connect(client) == 0) {
 *         strix_npu_infer_t infer = {
 *             .model_name = "model",
 *             .input_name = "input",
 *             .input_data = data,
 *             .input_size = sizeof(data)
 *         };
 *         strix_npu_infer(client, &infer);
 *         // Use infer.output_data
 *         strix_npu_free_output(&infer);
 *     }
 *     strix_npu_destroy(client);
 */

#ifndef STRIX_NPU_H
#define STRIX_NPU_H

#include <stddef.h>
#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Error codes */
typedef enum {
    STRIX_NPU_OK = 0,
    STRIX_NPU_ERROR_CONNECT = -1,
    STRIX_NPU_ERROR_SEND = -2,
    STRIX_NPU_ERROR_RECV = -3,
    STRIX_NPU_ERROR_PARSE = -4,
    STRIX_NPU_ERROR_INFERENCE = -5,
    STRIX_NPU_ERROR_NOT_CONNECTED = -6,
    STRIX_NPU_ERROR_TIMEOUT = -7,
    STRIX_NPU_ERROR_MEMORY = -8,
    STRIX_NPU_ERROR_INVALID_ARG = -9
} strix_npu_error_t;

/* Forward declarations */
typedef struct strix_npu_client strix_npu_client_t;

/* ============================================================================
 * Client Configuration
 * ============================================================================ */

typedef struct strix_npu_config {
    const char* host;           /* Bridge host (default: "localhost") */
    int port;                   /* Bridge port (default: 9999) */
    int timeout_ms;             /* Timeout in milliseconds (default: 30000) */
    int retry_count;            /* Number of connection retries (default: 3) */
    size_t buffer_size;         /* Receive buffer size (default: 65536) */
} strix_npu_config_t;

/* Initialize config with defaults */
void strix_npu_config_init(strix_npu_config_t* config);

/* ============================================================================
 * Client Lifecycle
 * ============================================================================ */

/* Create client with default configuration */
strix_npu_client_t* strix_npu_create(const char* host, int port);

/* Create client with custom configuration */
strix_npu_client_t* strix_npu_create_with_config(const strix_npu_config_t* config);

/* Destroy client and free resources */
void strix_npu_destroy(strix_npu_client_t* client);

/* Connect to NPU bridge */
int strix_npu_connect(strix_npu_client_t* client);

/* Disconnect from NPU bridge */
void strix_npu_disconnect(strix_npu_client_t* client);

/* Check if connected */
bool strix_npu_is_connected(strix_npu_client_t* client);

/* ============================================================================
 * Status and Info
 * ============================================================================ */

typedef struct strix_npu_status {
    char provider[64];          /* Execution provider name */
    char** models;              /* Array of loaded model names */
    size_t model_count;         /* Number of loaded models */
    size_t history_size;        /* Prefetcher history size */
} strix_npu_status_t;

/* Get bridge status */
int strix_npu_status(strix_npu_client_t* client, strix_npu_status_t* status);

/* Free status structure */
void strix_npu_free_status(strix_npu_status_t* status);

/* Ping bridge (returns 0 on success) */
int strix_npu_ping(strix_npu_client_t* client);

/* ============================================================================
 * Model Management
 * ============================================================================ */

/* Load an ONNX model */
int strix_npu_load_model(strix_npu_client_t* client,
                         const char* name,
                         const char* path);

typedef struct strix_npu_tensor_info {
    char name[64];              /* Tensor name */
    int64_t shape[8];           /* Shape dimensions */
    size_t ndim;                /* Number of dimensions */
    char dtype[16];             /* Data type (e.g., "float32") */
} strix_npu_tensor_info_t;

typedef struct strix_npu_model_info {
    strix_npu_tensor_info_t* inputs;
    size_t input_count;
    strix_npu_tensor_info_t* outputs;
    size_t output_count;
} strix_npu_model_info_t;

/* Get model info */
int strix_npu_model_info(strix_npu_client_t* client,
                         const char* name,
                         strix_npu_model_info_t* info);

/* Free model info */
void strix_npu_free_model_info(strix_npu_model_info_t* info);

/* ============================================================================
 * Inference
 * ============================================================================ */

typedef struct strix_npu_infer {
    /* Input */
    const char* model_name;     /* Model to use */
    const char* input_name;     /* Input tensor name */
    const float* input_data;    /* Input data (float array) */
    size_t input_size;          /* Number of floats */

    /* Output (filled by strix_npu_infer) */
    float* output_data;         /* Output data (allocated by library) */
    size_t output_size;         /* Number of output floats */
    int error;                  /* Error code (0 = success) */
} strix_npu_infer_t;

/* Run inference */
int strix_npu_infer(strix_npu_client_t* client, strix_npu_infer_t* infer);

/* Free inference output */
void strix_npu_free_output(strix_npu_infer_t* infer);

/* ============================================================================
 * Multi-tensor Inference (advanced)
 * ============================================================================ */

typedef struct strix_npu_tensor {
    const char* name;           /* Tensor name */
    const float* data;          /* Data pointer */
    size_t size;                /* Number of elements */
} strix_npu_tensor_t;

typedef struct strix_npu_multi_infer {
    const char* model_name;
    const strix_npu_tensor_t* inputs;
    size_t input_count;

    /* Output (filled by library) */
    strix_npu_tensor_t* outputs;
    size_t output_count;
    int error;
} strix_npu_multi_infer_t;

/* Run multi-tensor inference */
int strix_npu_multi_infer(strix_npu_client_t* client,
                          strix_npu_multi_infer_t* infer);

/* Free multi-tensor output */
void strix_npu_free_multi_output(strix_npu_multi_infer_t* infer);

/* ============================================================================
 * File Prefetching
 * ============================================================================ */

/* Record a file access (for pattern learning) */
int strix_npu_record_access(strix_npu_client_t* client, const char* path);

/* Record access by hash (faster if you pre-compute hashes) */
int strix_npu_record_access_hash(strix_npu_client_t* client, uint32_t path_hash);

/* Compute path hash (same algorithm as Python client) */
uint32_t strix_npu_path_hash(const char* path);

typedef struct strix_npu_predictions {
    uint32_t* hashes;           /* Array of predicted path hashes */
    size_t count;               /* Number of predictions */
} strix_npu_predictions_t;

/* Predict next file accesses */
int strix_npu_predict_next(strix_npu_client_t* client,
                           size_t count,
                           strix_npu_predictions_t* predictions);

/* Free predictions */
void strix_npu_free_predictions(strix_npu_predictions_t* predictions);

/* ============================================================================
 * Error Handling
 * ============================================================================ */

/* Get error message for error code */
const char* strix_npu_strerror(int error);

/* Get last error from client */
int strix_npu_last_error(strix_npu_client_t* client);

/* Get last error message from client */
const char* strix_npu_last_error_msg(strix_npu_client_t* client);

#ifdef __cplusplus
}
#endif

#endif /* STRIX_NPU_H */
