/* A fixture for the fuzz-reach and mutation self-tests: one function the
 * harness and the test both reach, with a condition taken one way only, and
 * one function nothing calls. */
int lib_classify(int x) {
    if (x > 100)
        return 2;
    if (x > 0)
        return 1;
    return 0;
}

int lib_unused(int x) {
    return x * 3;
}
