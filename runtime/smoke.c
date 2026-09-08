#ifdef NDEBUG
#error "Runtime smoke tests require assertions; compile with -UNDEBUG"
#endif

#include <assert.h>
#include <errno.h>
#include <math.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static _Thread_local int tls_value = 7;
static void *worker(void *unused) {
    (void)unused;
    assert(tls_value == 7);
    tls_value = 19;
    errno = ERANGE;
    return NULL;
}

int main(int argc, char **argv) {
    assert(argc > 0 && argv[0]);
    char *memory = malloc(256);
    assert(memory);
    strcpy(memory, "runtime");
    assert(strlen(memory) == 7);
    memory = realloc(memory, 512);
    assert(memory && strcmp(memory, "runtime") == 0);
    free(memory);
    volatile double input = 9.0;
    assert(fabs(sqrt(input) - 3.0) < 0.0001);
    pthread_t thread;
    assert(pthread_create(&thread, NULL, worker, NULL) == 0);
    assert(pthread_join(thread, NULL) == 0);
    assert(tls_value == 7);
    FILE *stream = tmpfile();
    assert(stream);
    assert(fputs("verified runtime", stream) >= 0);
    rewind(stream);
    char buffer[32];
    assert(fgets(buffer, sizeof buffer, stream));
    assert(strcmp(buffer, "verified runtime") == 0);
    assert(fclose(stream) == 0);
    puts("runtime smoke passed");
    return 0;
}
