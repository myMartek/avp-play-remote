// The signer's C interface (signer/src/lib.rs). Each function returns 0 on success and writes a short text into
// `message`: who signed, or what went wrong.
#include <stddef.h>
#include <stdint.h>

/// Writes a new RSA key (PEM, readable by the owner only) and the certificate request for it (PEM).
int32_t probe_sign_new_key(const char *key_out, const char *request_out, char *message, size_t message_size);

/// Signs the app bundle at `app` in place. `certificate` is DER or PEM; `entitlements` is an XML file, or NULL.
int32_t probe_sign_app(const char *app, const char *key, const char *certificate, const char *entitlements,
                       char *message, size_t message_size);
