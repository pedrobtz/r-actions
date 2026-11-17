/* Two independent bugs, so that a run which stops at the first finding
 * reports one and keep-going reports both: input starting "OV" overflows a
 * heap buffer, input starting "SH" shifts by more than the type's width. */
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
  if (size >= 3 && data[0] == 'O' && data[1] == 'V') {
    char *buf = malloc(4);
    memcpy(buf, data, size); /* writes past 4 bytes when size > 4 */
    /* Read it back: a buffer written and freed unread is optimised away at
     * -O1, overflow and all, as the README's fuzz.yml section warns. */
    volatile char sink = buf[size - 1];
    (void)sink;
    free(buf);
  }
  if (size >= 3 && data[0] == 'S' && data[1] == 'H') {
    volatile int shift = data[2];
    /* Unsigned, so that shift 31 is defined: with a signed 1 it is a second,
     * differently worded UBSan report ("left shift of 1 by 31 places"),
     * which the check would rightly count as a third finding. */
    volatile unsigned value = 1u << shift; /* UB when shift >= 32 */
    (void)value;
  }
  return 0;
}
