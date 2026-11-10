/* Checks lib_classify() at 5 and at 0, never above 100: both mutants of the
 * `> 0` comparison are killed, and `> 100` -> `>= 100` survives. */
int lib_classify(int x);
int main(void) { return lib_classify(5) == 1 && lib_classify(0) == 0 ? 0 : 1; }
