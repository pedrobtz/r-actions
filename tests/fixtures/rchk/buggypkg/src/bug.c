#include <R.h>
#include <Rinternals.h>
#include <R_ext/Rdynload.h>
SEXP make_pair(void) {
  SEXP a = Rf_allocVector(INTSXP, 1);   /* not protected */
  SEXP b = Rf_allocVector(INTSXP, 1);   /* may collect a */
  INTEGER(a)[0] = 1; INTEGER(b)[0] = 2;
  SEXP out = PROTECT(Rf_allocVector(VECSXP, 2));
  SET_VECTOR_ELT(out, 0, a); SET_VECTOR_ELT(out, 1, b);
  UNPROTECT(1);
  return out;
}
static const R_CallMethodDef calls[] = {{"make_pair", (DL_FUNC) &make_pair, 0}, {NULL, NULL, 0}};
void R_init_buggypkg(DllInfo *dll) { R_registerRoutines(dll, NULL, calls, NULL, NULL); R_useDynamicSymbols(dll, FALSE); }
