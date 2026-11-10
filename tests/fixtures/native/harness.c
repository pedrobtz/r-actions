#include <stddef.h>
#include <stdint.h>
int lib_classify(int x);
int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
    if (size) (void)lib_classify(data[0] % 50);   /* never above 100 */
    return 0;
}
