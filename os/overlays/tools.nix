self: super:
{
  svctl = super.callPackage ../packages/svctl {};
  test-runner = super.callPackage ../packages/test-runner {};
}
