/* Our title-only build does not load a JVM or execute code from discs. */
#include <stdlib.h>
#include "libbluray/bdj/bdj.h"
BDJAVA *bdj_open(const char *path, struct bluray *bd, const char *id, BDJ_CONFIG *storage) { return NULL; }
void bdj_close(BDJAVA *bd) {}
int bdj_process_event(BDJAVA *bd, unsigned event, unsigned param) { return -1; }
int bdj_jvm_available(BDJ_CONFIG *storage) { return BDJ_CHECK_NO_JVM; }
void bdj_config_cleanup(BDJ_CONFIG *s) {
    free(s->persistent_root); free(s->cache_root); free(s->java_home);
    free(s->classpath[0]); free(s->classpath[1]);
    s->persistent_root = s->cache_root = s->java_home = NULL;
    s->classpath[0] = s->classpath[1] = NULL;
}
