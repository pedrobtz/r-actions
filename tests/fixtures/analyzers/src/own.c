#include <stdlib.h>
/* A double free the analyzer reports: this file is analysed. */
void own_twice(void) { char *p = malloc(4); free(p); free(p); }
