#define _POSIX_C_SOURCE 200809L
#include <inttypes.h>
#include <stdio.h>
#include <time.h>

static int64_t nanoseconds(struct timespec value) {
  return (int64_t)value.tv_sec * INT64_C(1000000000) + value.tv_nsec;
}

int main(void) {
  struct timespec before, mono, after;
  if (clock_gettime(CLOCK_BOOTTIME, &before) != 0 ||
      clock_gettime(CLOCK_MONOTONIC, &mono) != 0 ||
      clock_gettime(CLOCK_BOOTTIME, &after) != 0) {
    perror("clock_gettime");
    return 1;
  }
  printf("{\"bootBeforeNs\":%" PRId64 ",\"monotonicNs\":%" PRId64
         ",\"bootAfterNs\":%" PRId64 "}\n",
         nanoseconds(before), nanoseconds(mono), nanoseconds(after));
  return 0;
}
