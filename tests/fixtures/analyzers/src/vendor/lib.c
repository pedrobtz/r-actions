#include <stdlib.h>
/* The same double free in "vendored" code that `skip` lists. */
void lib_twice(void) { char *p = malloc(4); free(p); free(p); }
