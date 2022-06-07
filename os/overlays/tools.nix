self: super:
{
  scrubctl = super.callPackage ../packages/scrubctl {};
  svctl = super.callPackage ../packages/svctl {};
  test-runner = super.callPackage ../packages/test-runner {};
}
