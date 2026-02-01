/*
 * Strix-Turbo NPU Client - C Library Implementation
 */

#define _GNU_SOURCE
#include "strix_npu.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <netdb.h>
#include <poll.h>

/* Simple JSON handling (we avoid external dependencies) */

/* ============================================================================
 * Internal Structures
 * ============================================================================ */

struct strix_npu_client {
    int socket;
    bool connected;
    strix_npu_config_t config;

    /* Buffer for receiving data */
    char* recv_buffer;
    size_t recv_buffer_size;

    /* Error state */
    int last_error;
    char last_error_msg[256];
};

/* ============================================================================
 * Helper Functions
 * ============================================================================ */

static void set_error(strix_npu_client_t* client, int error, const char* msg) {
    client->last_error = error;
    if (msg) {
        strncpy(client->last_error_msg, msg, sizeof(client->last_error_msg) - 1);
        client->last_error_msg[sizeof(client->last_error_msg) - 1] = '\0';
    } else {
        client->last_error_msg[0] = '\0';
    }
}

/* Simple MD5 for path hashing (first 4 bytes only) */
/* This is a simplified implementation for hash consistency with Python */
static uint32_t simple_hash(const char* str) {
    uint32_t hash = 5381;
    int c;
    while ((c = *str++)) {
        hash = ((hash << 5) + hash) + c;
    }
    return hash;
}

/* Find a string in JSON (very simple parser) */
static const char* json_find_string(const char* json, const char* key, char* out, size_t out_size) {
    char pattern[128];
    snprintf(pattern, sizeof(pattern), "\"%s\":", key);

    const char* pos = strstr(json, pattern);
    if (!pos) return NULL;

    pos += strlen(pattern);
    while (*pos == ' ' || *pos == '\t') pos++;

    if (*pos != '"') return NULL;
    pos++;

    size_t i = 0;
    while (*pos && *pos != '"' && i < out_size - 1) {
        out[i++] = *pos++;
    }
    out[i] = '\0';

    return out;
}

/* Find a number in JSON */
static int json_find_int(const char* json, const char* key, int* out) {
    char pattern[128];
    snprintf(pattern, sizeof(pattern), "\"%s\":", key);

    const char* pos = strstr(json, pattern);
    if (!pos) return -1;

    pos += strlen(pattern);
    while (*pos == ' ' || *pos == '\t') pos++;

    char* end;
    long val = strtol(pos, &end, 10);
    if (end == pos) return -1;

    *out = (int)val;
    return 0;
}

/* Check if JSON has "status": "ok" */
static bool json_status_ok(const char* json) {
    char status[32];
    if (json_find_string(json, "status", status, sizeof(status))) {
        return strcmp(status, "ok") == 0;
    }
    return false;
}

/* Build JSON request */
static int build_request(char* buf, size_t size, const char* fmt, ...) {
    va_list args;
    va_start(args, fmt);
    int len = vsnprintf(buf, size, fmt, args);
    va_end(args);

    if (len > 0 && (size_t)len < size - 1) {
        buf[len++] = '\n';
        buf[len] = '\0';
    }

    return len;
}

/* ============================================================================
 * Configuration
 * ============================================================================ */

void strix_npu_config_init(strix_npu_config_t* config) {
    if (!config) return;

    config->host = "localhost";
    config->port = 9999;
    config->timeout_ms = 30000;
    config->retry_count = 3;
    config->buffer_size = 65536;
}

/* ============================================================================
 * Client Lifecycle
 * ============================================================================ */

strix_npu_client_t* strix_npu_create(const char* host, int port) {
    strix_npu_config_t config;
    strix_npu_config_init(&config);
    config.host = host ? host : "localhost";
    config.port = port > 0 ? port : 9999;
    return strix_npu_create_with_config(&config);
}

strix_npu_client_t* strix_npu_create_with_config(const strix_npu_config_t* config) {
    if (!config) return NULL;

    strix_npu_client_t* client = calloc(1, sizeof(strix_npu_client_t));
    if (!client) return NULL;

    client->socket = -1;
    client->connected = false;
    memcpy(&client->config, config, sizeof(strix_npu_config_t));

    /* Allocate receive buffer */
    client->recv_buffer_size = config->buffer_size;
    client->recv_buffer = malloc(client->recv_buffer_size);
    if (!client->recv_buffer) {
        free(client);
        return NULL;
    }

    return client;
}

void strix_npu_destroy(strix_npu_client_t* client) {
    if (!client) return;

    strix_npu_disconnect(client);
    free(client->recv_buffer);
    free(client);
}

int strix_npu_connect(strix_npu_client_t* client) {
    if (!client) return STRIX_NPU_ERROR_INVALID_ARG;
    if (client->connected) return STRIX_NPU_OK;

    struct hostent* he = gethostbyname(client->config.host);
    if (!he) {
        set_error(client, STRIX_NPU_ERROR_CONNECT, "Failed to resolve host");
        return STRIX_NPU_ERROR_CONNECT;
    }

    for (int attempt = 0; attempt < client->config.retry_count; attempt++) {
        client->socket = socket(AF_INET, SOCK_STREAM, 0);
        if (client->socket < 0) {
            continue;
        }

        /* Set timeout */
        struct timeval tv;
        tv.tv_sec = client->config.timeout_ms / 1000;
        tv.tv_usec = (client->config.timeout_ms % 1000) * 1000;
        setsockopt(client->socket, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
        setsockopt(client->socket, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));

        struct sockaddr_in addr;
        memset(&addr, 0, sizeof(addr));
        addr.sin_family = AF_INET;
        addr.sin_port = htons(client->config.port);
        memcpy(&addr.sin_addr, he->h_addr, he->h_length);

        if (connect(client->socket, (struct sockaddr*)&addr, sizeof(addr)) == 0) {
            client->connected = true;

            /* Verify with ping */
            if (strix_npu_ping(client) == STRIX_NPU_OK) {
                return STRIX_NPU_OK;
            }

            /* Ping failed, disconnect and retry */
            strix_npu_disconnect(client);
        }

        close(client->socket);
        client->socket = -1;

        if (attempt < client->config.retry_count - 1) {
            usleep(1000000);  /* 1 second delay */
        }
    }

    set_error(client, STRIX_NPU_ERROR_CONNECT, "Failed to connect after retries");
    return STRIX_NPU_ERROR_CONNECT;
}

void strix_npu_disconnect(strix_npu_client_t* client) {
    if (!client) return;

    if (client->socket >= 0) {
        close(client->socket);
        client->socket = -1;
    }
    client->connected = false;
}

bool strix_npu_is_connected(strix_npu_client_t* client) {
    return client && client->connected;
}

/* ============================================================================
 * Communication
 * ============================================================================ */

static int send_request(strix_npu_client_t* client, const char* request) {
    if (!client || !client->connected) {
        return STRIX_NPU_ERROR_NOT_CONNECTED;
    }

    size_t len = strlen(request);
    ssize_t sent = send(client->socket, request, len, 0);

    if (sent < 0) {
        set_error(client, STRIX_NPU_ERROR_SEND, strerror(errno));
        return STRIX_NPU_ERROR_SEND;
    }

    if ((size_t)sent != len) {
        set_error(client, STRIX_NPU_ERROR_SEND, "Partial send");
        return STRIX_NPU_ERROR_SEND;
    }

    return STRIX_NPU_OK;
}

static int recv_response(strix_npu_client_t* client) {
    if (!client || !client->connected) {
        return STRIX_NPU_ERROR_NOT_CONNECTED;
    }

    size_t total = 0;
    while (total < client->recv_buffer_size - 1) {
        ssize_t n = recv(client->socket, client->recv_buffer + total,
                        client->recv_buffer_size - 1 - total, 0);

        if (n < 0) {
            if (errno == EAGAIN || errno == EWOULDBLOCK) {
                set_error(client, STRIX_NPU_ERROR_TIMEOUT, "Receive timeout");
                return STRIX_NPU_ERROR_TIMEOUT;
            }
            set_error(client, STRIX_NPU_ERROR_RECV, strerror(errno));
            return STRIX_NPU_ERROR_RECV;
        }

        if (n == 0) {
            set_error(client, STRIX_NPU_ERROR_RECV, "Connection closed");
            client->connected = false;
            return STRIX_NPU_ERROR_RECV;
        }

        total += n;
        client->recv_buffer[total] = '\0';

        /* Check for newline (end of response) */
        if (strchr(client->recv_buffer, '\n')) {
            break;
        }
    }

    return STRIX_NPU_OK;
}

/* ============================================================================
 * Status and Info
 * ============================================================================ */

int strix_npu_ping(strix_npu_client_t* client) {
    char request[128];
    build_request(request, sizeof(request), "{\"cmd\":\"ping\"}");

    int ret = send_request(client, request);
    if (ret != STRIX_NPU_OK) return ret;

    ret = recv_response(client);
    if (ret != STRIX_NPU_OK) return ret;

    if (!json_status_ok(client->recv_buffer)) {
        set_error(client, STRIX_NPU_ERROR_PARSE, "Ping failed");
        return STRIX_NPU_ERROR_PARSE;
    }

    return STRIX_NPU_OK;
}

int strix_npu_status(strix_npu_client_t* client, strix_npu_status_t* status) {
    if (!status) return STRIX_NPU_ERROR_INVALID_ARG;

    memset(status, 0, sizeof(*status));

    char request[128];
    build_request(request, sizeof(request), "{\"cmd\":\"status\"}");

    int ret = send_request(client, request);
    if (ret != STRIX_NPU_OK) return ret;

    ret = recv_response(client);
    if (ret != STRIX_NPU_OK) return ret;

    if (!json_status_ok(client->recv_buffer)) {
        set_error(client, STRIX_NPU_ERROR_PARSE, "Status failed");
        return STRIX_NPU_ERROR_PARSE;
    }

    json_find_string(client->recv_buffer, "provider", status->provider, sizeof(status->provider));

    int hist_size = 0;
    if (json_find_int(client->recv_buffer, "history_size", &hist_size) == 0) {
        status->history_size = (size_t)hist_size;
    }

    return STRIX_NPU_OK;
}

void strix_npu_free_status(strix_npu_status_t* status) {
    if (!status) return;

    if (status->models) {
        for (size_t i = 0; i < status->model_count; i++) {
            free(status->models[i]);
        }
        free(status->models);
    }
    memset(status, 0, sizeof(*status));
}

/* ============================================================================
 * Model Management
 * ============================================================================ */

int strix_npu_load_model(strix_npu_client_t* client, const char* name, const char* path) {
    if (!name || !path) return STRIX_NPU_ERROR_INVALID_ARG;

    char request[1024];
    build_request(request, sizeof(request),
                  "{\"cmd\":\"load_model\",\"name\":\"%s\",\"path\":\"%s\"}",
                  name, path);

    int ret = send_request(client, request);
    if (ret != STRIX_NPU_OK) return ret;

    ret = recv_response(client);
    if (ret != STRIX_NPU_OK) return ret;

    if (!json_status_ok(client->recv_buffer)) {
        set_error(client, STRIX_NPU_ERROR_INFERENCE, "Load model failed");
        return STRIX_NPU_ERROR_INFERENCE;
    }

    return STRIX_NPU_OK;
}

int strix_npu_model_info(strix_npu_client_t* client, const char* name,
                         strix_npu_model_info_t* info) {
    if (!name || !info) return STRIX_NPU_ERROR_INVALID_ARG;

    memset(info, 0, sizeof(*info));

    char request[256];
    build_request(request, sizeof(request),
                  "{\"cmd\":\"model_info\",\"name\":\"%s\"}", name);

    int ret = send_request(client, request);
    if (ret != STRIX_NPU_OK) return ret;

    ret = recv_response(client);
    if (ret != STRIX_NPU_OK) return ret;

    if (!json_status_ok(client->recv_buffer)) {
        set_error(client, STRIX_NPU_ERROR_PARSE, "Model info failed");
        return STRIX_NPU_ERROR_PARSE;
    }

    /* Simplified parsing - in production, use a proper JSON library */
    /* For now, just indicate success */
    return STRIX_NPU_OK;
}

void strix_npu_free_model_info(strix_npu_model_info_t* info) {
    if (!info) return;
    free(info->inputs);
    free(info->outputs);
    memset(info, 0, sizeof(*info));
}

/* ============================================================================
 * Inference
 * ============================================================================ */

int strix_npu_infer(strix_npu_client_t* client, strix_npu_infer_t* infer) {
    if (!infer || !infer->model_name || !infer->input_name ||
        !infer->input_data || infer->input_size == 0) {
        return STRIX_NPU_ERROR_INVALID_ARG;
    }

    infer->output_data = NULL;
    infer->output_size = 0;
    infer->error = 0;

    /* Build request with input data as JSON array */
    size_t data_str_size = infer->input_size * 20 + 256;
    char* request = malloc(data_str_size);
    if (!request) {
        infer->error = STRIX_NPU_ERROR_MEMORY;
        return STRIX_NPU_ERROR_MEMORY;
    }

    char* p = request;
    p += sprintf(p, "{\"cmd\":\"infer\",\"name\":\"%s\",\"inputs\":{\"%s\":[",
                 infer->model_name, infer->input_name);

    for (size_t i = 0; i < infer->input_size; i++) {
        if (i > 0) *p++ = ',';
        p += sprintf(p, "%g", infer->input_data[i]);
    }

    p += sprintf(p, "]}}\n");

    int ret = send_request(client, request);
    free(request);

    if (ret != STRIX_NPU_OK) {
        infer->error = ret;
        return ret;
    }

    ret = recv_response(client);
    if (ret != STRIX_NPU_OK) {
        infer->error = ret;
        return ret;
    }

    if (!json_status_ok(client->recv_buffer)) {
        set_error(client, STRIX_NPU_ERROR_INFERENCE, "Inference failed");
        infer->error = STRIX_NPU_ERROR_INFERENCE;
        return STRIX_NPU_ERROR_INFERENCE;
    }

    /* Parse output array - simplified */
    /* Find "outputs" and extract numbers */
    const char* outputs = strstr(client->recv_buffer, "\"outputs\"");
    if (!outputs) {
        infer->error = STRIX_NPU_ERROR_PARSE;
        return STRIX_NPU_ERROR_PARSE;
    }

    /* Count numbers in output */
    const char* bracket = strchr(outputs, '[');
    if (!bracket) {
        infer->error = STRIX_NPU_ERROR_PARSE;
        return STRIX_NPU_ERROR_PARSE;
    }

    /* Count elements (rough estimate) */
    size_t count = 0;
    const char* scan = bracket;
    while (*scan && *scan != ']') {
        if (*scan == ',' || *scan == '[') count++;
        scan++;
    }

    if (count == 0) count = 1;

    infer->output_data = malloc(count * sizeof(float));
    if (!infer->output_data) {
        infer->error = STRIX_NPU_ERROR_MEMORY;
        return STRIX_NPU_ERROR_MEMORY;
    }

    /* Parse numbers */
    scan = bracket + 1;
    size_t idx = 0;
    while (*scan && idx < count) {
        while (*scan && (*scan == ' ' || *scan == ',' || *scan == '[')) scan++;
        if (*scan == ']') break;

        char* end;
        double val = strtod(scan, &end);
        if (end > scan) {
            infer->output_data[idx++] = (float)val;
            scan = end;
        } else {
            scan++;
        }
    }

    infer->output_size = idx;
    return STRIX_NPU_OK;
}

void strix_npu_free_output(strix_npu_infer_t* infer) {
    if (!infer) return;
    free(infer->output_data);
    infer->output_data = NULL;
    infer->output_size = 0;
}

/* Multi-tensor inference - simplified */
int strix_npu_multi_infer(strix_npu_client_t* client,
                          strix_npu_multi_infer_t* infer) {
    (void)client;
    (void)infer;
    /* TODO: Implement multi-tensor inference */
    return STRIX_NPU_ERROR_INVALID_ARG;
}

void strix_npu_free_multi_output(strix_npu_multi_infer_t* infer) {
    if (!infer || !infer->outputs) return;

    for (size_t i = 0; i < infer->output_count; i++) {
        free((void*)infer->outputs[i].data);
    }
    free(infer->outputs);
    infer->outputs = NULL;
    infer->output_count = 0;
}

/* ============================================================================
 * File Prefetching
 * ============================================================================ */

uint32_t strix_npu_path_hash(const char* path) {
    if (!path) return 0;
    return simple_hash(path);
}

int strix_npu_record_access(strix_npu_client_t* client, const char* path) {
    if (!path) return STRIX_NPU_ERROR_INVALID_ARG;
    return strix_npu_record_access_hash(client, strix_npu_path_hash(path));
}

int strix_npu_record_access_hash(strix_npu_client_t* client, uint32_t path_hash) {
    char request[256];
    build_request(request, sizeof(request),
                  "{\"cmd\":\"record_access\",\"path_hash\":%u}", path_hash);

    int ret = send_request(client, request);
    if (ret != STRIX_NPU_OK) return ret;

    ret = recv_response(client);
    if (ret != STRIX_NPU_OK) return ret;

    if (!json_status_ok(client->recv_buffer)) {
        return STRIX_NPU_ERROR_PARSE;
    }

    return STRIX_NPU_OK;
}

int strix_npu_predict_next(strix_npu_client_t* client, size_t count,
                           strix_npu_predictions_t* predictions) {
    if (!predictions) return STRIX_NPU_ERROR_INVALID_ARG;

    predictions->hashes = NULL;
    predictions->count = 0;

    char request[256];
    build_request(request, sizeof(request),
                  "{\"cmd\":\"predict_next\",\"count\":%zu}", count);

    int ret = send_request(client, request);
    if (ret != STRIX_NPU_OK) return ret;

    ret = recv_response(client);
    if (ret != STRIX_NPU_OK) return ret;

    if (!json_status_ok(client->recv_buffer)) {
        return STRIX_NPU_ERROR_PARSE;
    }

    /* Parse predictions array */
    const char* preds = strstr(client->recv_buffer, "\"predictions\"");
    if (!preds) return STRIX_NPU_OK;

    const char* bracket = strchr(preds, '[');
    if (!bracket) return STRIX_NPU_OK;

    /* Allocate array */
    predictions->hashes = malloc(count * sizeof(uint32_t));
    if (!predictions->hashes) return STRIX_NPU_ERROR_MEMORY;

    /* Parse numbers */
    const char* scan = bracket + 1;
    size_t idx = 0;
    while (*scan && idx < count) {
        while (*scan && (*scan == ' ' || *scan == ',')) scan++;
        if (*scan == ']') break;

        char* end;
        unsigned long val = strtoul(scan, &end, 10);
        if (end > scan) {
            predictions->hashes[idx++] = (uint32_t)val;
            scan = end;
        } else {
            scan++;
        }
    }

    predictions->count = idx;
    return STRIX_NPU_OK;
}

void strix_npu_free_predictions(strix_npu_predictions_t* predictions) {
    if (!predictions) return;
    free(predictions->hashes);
    predictions->hashes = NULL;
    predictions->count = 0;
}

/* ============================================================================
 * Error Handling
 * ============================================================================ */

const char* strix_npu_strerror(int error) {
    switch (error) {
        case STRIX_NPU_OK: return "Success";
        case STRIX_NPU_ERROR_CONNECT: return "Connection failed";
        case STRIX_NPU_ERROR_SEND: return "Send failed";
        case STRIX_NPU_ERROR_RECV: return "Receive failed";
        case STRIX_NPU_ERROR_PARSE: return "Parse error";
        case STRIX_NPU_ERROR_INFERENCE: return "Inference failed";
        case STRIX_NPU_ERROR_NOT_CONNECTED: return "Not connected";
        case STRIX_NPU_ERROR_TIMEOUT: return "Timeout";
        case STRIX_NPU_ERROR_MEMORY: return "Memory allocation failed";
        case STRIX_NPU_ERROR_INVALID_ARG: return "Invalid argument";
        default: return "Unknown error";
    }
}

int strix_npu_last_error(strix_npu_client_t* client) {
    return client ? client->last_error : STRIX_NPU_ERROR_INVALID_ARG;
}

const char* strix_npu_last_error_msg(strix_npu_client_t* client) {
    return client ? client->last_error_msg : "";
}
