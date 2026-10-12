// idevice_ffi.h — C header for the jkcoxson/idevice Rust FFI
// (pairable-host subset needed by WorkSlop's iOS 27 on-device pairing).
//
// Build the static library with:
//   cargo build --target aarch64-apple-ios --no-default-features \
//     --features remote_pairing,rustcrypto --lib --release
// The output is libidevice_ffi.a.

#ifndef IDEVICE_FFI_H
#define IDEVICE_FFI_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// Opaque error type. NULL = success. Read code/message via struct fields.
typedef struct IdeviceFfiError {
    int32_t code;
    int32_t sub_code;
    const char *message;
} IdeviceFfiError;

// Opaque pairable-host handle.
typedef struct PairableHostHandle PairableHostHandle;

// Opaque pairing-file handle.
typedef struct RpPairingFileHandle RpPairingFileHandle;

// Opaque peer-device info.
typedef struct RpPairingPeerDeviceC RpPairingPeerDeviceC;

// Called when the device issues a setup PIN. May be NULL.
// pin: null-terminated 6-digit string. context: caller-provided pointer.
typedef void (*PairableHostPinCb)(const char *pin, void *context);

// Generates a fresh host identity. Returns NULL on success, error otherwise.
// - name: human-readable name shown on the device (e.g. "WorkSlop").
// - model: hardware model, or NULL for default.
// - allows_pinless_pairing: false for the PIN flow.
// - out_handle: receives handle (free with pairable_host_free).
// - out_service_id: receives Bonjour service name (free with idevice_string_free).
// - out_txt_data/out_txt_len: receives XML plist TXT records (free with idevice_data_free).
// - out_host_alt_irk: optional 16-byte buffer receiving altIRK (persist with pairing file).
struct IdeviceFfiError *pairable_host_prepare(
    const char *name,
    const char *model,
    bool allows_pinless_pairing,
    struct PairableHostHandle **out_handle,
    char **out_service_id,
    uint8_t **out_txt_data,
    size_t *out_txt_len,
    uint8_t *out_host_alt_irk
);

// Runs pair-setup on a connected TCP socket. BLOCKS until done.
// - handle: from pairable_host_prepare.
// - fd: connected TCP socket (duplicated internally; caller keeps ownership).
// - pin_cb/context: PIN callback, must stay valid until return.
// - out_peer_device: optional, may be NULL.
// - out_pairing_file: receives pairing file handle (free with rp_pairing_file_free).
struct IdeviceFfiError *pairable_host_accept_fd(
    struct PairableHostHandle *handle,
    int fd,
    PairableHostPinCb pin_cb,
    void *context,
    struct RpPairingPeerDeviceC **out_peer_device,
    struct RpPairingFileHandle **out_pairing_file
);

// Frees a pairable-host handle.
void pairable_host_free(struct PairableHostHandle *handle);

// Serializes pairing file to XML plist bytes.
// Free with idevice_data_free(data, len).
struct IdeviceFfiError *rp_pairing_file_to_bytes(
    struct RpPairingFileHandle *handle,
    uint8_t **out_data,
    size_t *out_len
);

// Frees a pairing-file handle.
void rp_pairing_file_free(struct RpPairingFileHandle *handle);

// Frees a string from idevice.
void idevice_string_free(char *s);

// Frees data from idevice.
void idevice_data_free(uint8_t *data, size_t len);

// Frees an error (frees message + struct).
void idevice_error_free(struct IdeviceFfiError *err);

#ifdef __cplusplus
}
#endif

#endif // IDEVICE_FFI_H
