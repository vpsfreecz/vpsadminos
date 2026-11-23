# Promoted-clone send cycle

Run `./test-runner.sh test zfs/rsend-promoted-cycle-6.18.49` from the repository
root. The test runs only `rsend_008_pos`, with a five-minute limit on the test
body. The paired OpenZFS fork must refuse the cycle and report `cyclic parent
and clone origin dependencies`. A hang, unexpected success, unrelated failure,
or skip does not pass this test.

The stable OpenZFS pin does not implement this check. Retire this test with its
kernel and OpenZFS pair rather than moving its assumptions to the stable suite.
