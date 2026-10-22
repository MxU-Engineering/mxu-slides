#ifndef CAUDIOATOMICS_H
#define CAUDIOATOMICS_H

#include <stdatomic.h>
#include <stdint.h>

typedef struct { _Atomic(int64_t) value; } mxu_atomic_i64;
typedef struct { _Atomic(void *) value; } mxu_atomic_ptr;

static inline int64_t mxu_load_i64(mxu_atomic_i64 *a) { return atomic_load_explicit(&a->value, memory_order_acquire); }
static inline void mxu_store_i64(mxu_atomic_i64 *a, int64_t v) { atomic_store_explicit(&a->value, v, memory_order_release); }
static inline int64_t mxu_exchange_i64(mxu_atomic_i64 *a, int64_t v) { return atomic_exchange_explicit(&a->value, v, memory_order_acq_rel); }
static inline void *mxu_load_ptr(mxu_atomic_ptr *a) { return atomic_load_explicit(&a->value, memory_order_acquire); }
static inline void mxu_store_ptr(mxu_atomic_ptr *a, void *v) { atomic_store_explicit(&a->value, v, memory_order_release); }

#include <fcntl.h>
#include <sys/mman.h>
static inline int mxu_shm_open(const char *name, int oflag, mode_t mode) { return shm_open(name, oflag, mode); }

#endif
