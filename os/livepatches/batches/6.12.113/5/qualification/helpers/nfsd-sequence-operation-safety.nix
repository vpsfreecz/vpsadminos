args:
import ../../../2/qualification/helpers/nfsd-openowner-operation-safety.nix (
  args
  // {
    oracleId = "nfsd-sequence-operation-safety";
    sequenceEvidence = true;
  }
)
