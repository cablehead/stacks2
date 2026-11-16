// xs, built into Stacks2: the C interface of xs-ffi/src/lib.rs.
// Every char * returned is freed with xs_free_string, bytes with xs_free_bytes.
#include <stddef.h>
#include <stdint.h>

// NULL once open, or an error message.
char *xs_open(const char *path);
// The appended frame as JSON, or {"error": ...}. query: "ttl=last:1" or "".
char *xs_append(const char *topic, const char *query, const char *meta_json,
                const uint8_t *body, size_t len);
// Frames as a JSON array, or {"error": ...}. query: as the HTTP read, or "".
char *xs_read(const char *query);
// CAS bytes, or NULL with *err set.
uint8_t *xs_cas(const char *hash, size_t *len, char **err);

// Each frame as a JSON line, then NULL once when the follow ends.
typedef void (*xs_line)(void *ctx, const char *json);
uint64_t xs_follow(const char *query, xs_line line, void *ctx);
void xs_follow_stop(uint64_t id);

void xs_close(void);
void xs_free_string(char *s);
void xs_free_bytes(uint8_t *ptr, size_t len);
