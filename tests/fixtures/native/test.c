/* Checks lib_classify(5) only: the mutants on the `> 100` branch survive,
 * and the `> 0` comparison is killed. */
int lib_classify(int x);
int main(void) { return lib_classify(5) == 1 ? 0 : 1; }
