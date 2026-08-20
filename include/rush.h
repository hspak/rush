/**
 * @file rush.h
 *
 * librush — embeddable Rush shell.
 *
 * Evaluates the shell language and builtins in-process. External commands
 * return 127. Pipes, subshells, and job control fail with status 2 and
 * write `rush: shell error` to stderr.
 *
 * Native builds install the static and platform shared libraries under
 * `${prefix}/lib` and this header under `${prefix}/include`. Wasm builds
 * install `rush.wasm` instead.
 */

#ifndef RUSH_H
#define RUSH_H

#include <stddef.h>
#include <stdint.h>

/* Symbol visibility for shared-library consumers. Define RUSH_STATIC before
 * including this header when linking the static library. */
#ifndef RUSH_API
#if defined(RUSH_STATIC)
#define RUSH_API
#elif defined(_WIN32) || defined(_WIN64)
#ifdef RUSH_BUILD_SHARED
#define RUSH_API __declspec(dllexport)
#else
#define RUSH_API __declspec(dllimport)
#endif
#elif defined(__GNUC__) && __GNUC__ >= 4
#define RUSH_API __attribute__((visibility("default")))
#else
#define RUSH_API
#endif
#endif

#ifdef __cplusplus
extern "C" {
#endif

typedef struct Rush Rush;

/* Except where documented otherwise, pointer arguments must not be NULL.
 * A Rush instance must not be accessed concurrently. */

/** UTF-8 version string. Valid for the life of the process. */
RUSH_API const char *rush_version(void);

/** New persistent shell, or NULL on allocation failure. */
RUSH_API Rush *rush_create(void);

/**
 * Run EXIT traps if they have not already run, then free the instance.
 * Destroy-time EXIT output is discarded. Eval `exit` first to read it. A NULL
 * instance is safely ignored.
 */
RUSH_API void rush_destroy(Rush *instance);

/**
 * Evaluate one REPL command. `ptr`/`len` are UTF-8 bytes that must stay
 * valid for the call. After `exit` or a fatal flow, later evals return the
 * finished status and do not run more script.
 */
RUSH_API uint8_t rush_eval(Rush *instance, const uint8_t *ptr, size_t len);

/**
 * Captured stdout/stderr from the last eval. Pointers are invalidated by
 * the next eval or by destroy.
 */
RUSH_API const uint8_t *rush_stdout_ptr(const Rush *instance);
RUSH_API size_t rush_stdout_len(const Rush *instance);
RUSH_API const uint8_t *rush_stderr_ptr(const Rush *instance);
RUSH_API size_t rush_stderr_len(const Rush *instance);

/**
 * Heap helpers for embedders that cannot allocate wasm/host memory. A
 * zero-length allocation returns NULL. Free requires the original length;
 * a NULL pointer is safely ignored.
 */
RUSH_API uint8_t *rush_wasm_alloc_u8_array(size_t len);
RUSH_API void rush_wasm_free_u8_array(uint8_t *ptr, size_t len);

#ifdef __cplusplus
}
#endif

#endif
