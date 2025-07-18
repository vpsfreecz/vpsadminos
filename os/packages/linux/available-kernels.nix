{
  stableKernelVersion = "6.12.38";
  unstableKernelVersion = "6.12.38";

  kernels = {
    "6.12.38" = {
      rev = "ab57920c34f302e27b85a235952da648659d37fa";
      sha256 = "sha256-Iv03BW5vO5IMZeCwxrlzwqsKSRc/My46bJZWxZPf3pM=";
      zfs = {
        rev = "a479075b2473c1f5679e129f168c09e45df057c8";
        sha256 = "sha256-21QbJtoYGOt9/s1fwxlQlvIkBPxOue2C0YVZSsZXDVA=";
      };
    };
    "6.12.37" = {
      rev = "0930121814a3f94dd58b411a92a19d916457eff8";
      sha256 = "sha256-GW2FXINJ6TziEL3AOtbTMD7b7fGOkwd8z+hxyGV0ZFA=";
      zfs = {
        rev = "b65aa7544705fafb946ec01b65fad32cee3284c2";
        sha256 = "sha256-uxSMi2jbYzNLEw2ee5loRQh3zRZ7zQiacYPs/WWHHiI=";
      };
    };
    "6.12.34" = {
      rev = "ac64d280f3e416449a318a811987ae531c8f7e97";
      sha256 = "sha256-fBwFGKuhxKnXf04Ck98cwoJ6HwC4LpDLGXcwd1JmYIY=";
      zfs = {
        rev = "00d8dc06bad765d7a1357c4f418fc5bb8a5feca8";
        sha256 = "sha256-AOgJm8fPDa0kDhyL4PFBuz+uz1Rz7zsH9C9AXn5GnMA=";
      };
    };
    "6.12.33" = {
      rev = "0655f700a3545ee3a865824694b77c0d2928f17d";
      sha256 = "sha256-2D8OZsXEW3BJODxDTutV8kjCNRnJG+KKk7t8YtJoLdE=";
      zfs = {
        rev = "6546b7270e6c44e7e90fd5fa4dcb2eaba04b0de2";
        sha256 = "sha256-EFSCMEAN8XYVb+k1khXMJki4HsWkWbaH9VtXlwJINjU=";
      };
    };
    "6.6.21" = {
      rev = "86e0c00fd80469aea354b9fc4ca5913d33ea0d92";
      sha256 = "sha256-zJHOmvyBr0aR97boNZHtfBJviqpmv69RNKqR6eBkJ9A=";
      zfs = {
        rev = "5ee3b2fc6eba2df3b2a4501ccf6c469ebd7889ed";
        sha256 = "sha256-jebuLXVqFPoASF4OptpcCHPSvynGIHiIZgw+nDHtGeU=";
      };
    };
  };
}
