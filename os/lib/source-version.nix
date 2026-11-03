# Source identity is bound to the OS provider, which can differ from the tested
# repository. Never use a caller's revision to label a pinned provider input.
{
  source,
  sourceInfo ?
    let
      json = builtins.getEnv "TEST_RUNNER_SOURCE_INFO";
    in
    if json == "" then null else builtins.fromJSON json,
}:
{ lib, ... }:
let
  captured = sourceInfo;
  matching = captured != null && captured.sourcePath == toString source.outPath;
  dirty = if matching then captured.dirty else !(source ? rev) && source ? dirtyRev;
  revision =
    if matching then
      captured.revision
    else if source ? rev then
      source.rev
    else if source ? dirtyRev then
      lib.removeSuffix "-dirty" source.dirtyRev
    else
      null;
  shortRev =
    if matching then
      captured.shortRev
    else
      source.shortRev or (
        if source ? dirtyShortRev then
          source.dirtyShortRev
        else if revision == null then
          null
        else
          builtins.substring 0 7 revision
      );
in
{
  system.vpsadminos = lib.optionalAttrs (revision != null) (
    {
      revision = lib.mkDefault revision;
      revisionDirty = lib.mkDefault dirty;
    }
    // lib.optionalAttrs (shortRev != null) {
      versionSuffix = lib.mkDefault ".git.${shortRev}";
    }
  );
}
