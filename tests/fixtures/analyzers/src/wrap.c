/* A wrapper that #includes the vendored file, as zumir's do: the
   diagnostic names vendor/lib.c, so only `skip` on wrap.c silences it. */
#define lib_twice wrap_twice
#include "vendor/lib.c"
