self: super:
{
  osctl = super.callPackage ../packages/osctl {};
  osctld = super.callPackage ../packages/osctld {};
}
