/* SPDX-License-Identifier: GPL-2.0 */
#ifndef LIVEPATCH_TEST_PROBE_H
#define LIVEPATCH_TEST_PROBE_H

#include <linux/compiler_types.h>

void livepatch_test_hold_trampoline(void);
void notrace livepatch_test_wait_for_release(void);

#endif
