{
  stableKernelVersion = "6.1.141";
  unstableKernelVersion = "6.1.141";

  kernels = {
    "6.1.141" = {
      rev = "55400cc00efd138b3264b6660a9e91cae36efd40";
      sha256 = "sha256-dcidyBE/cm034gUqalfrDWBQpzdNsr5TMwrQJ0DoC/w=";
      zfs = {
        rev = "059684462a7e7b81c7c4e0a7e5f0c3a734b64860";
        sha256 = "sha256-kQbeKxiZtm2tpMxdf6bMyhPd1W6KQ3qNmZsyR/aeXyM=";
      };
    };
    "6.12.34-2" = {
      rev = "a5364787e87a870fba4b6513cc918de56e7d7e61";
      sha256 = "sha256-XCMr3/1q2HRKK5O+IyUbqlt/BmmNqH0VYFhcjJCONzg=";
      zfs = {
        rev = "e24cd603b883ad89c11172784485b290f742ef2d";
        sha256 = "sha256-ehV/dsXjTD4b9h16yxtQddnkmA/35ayr+4K7xNlW/Kg=";
      };
    };
    "6.12.34" = {
      rev = "ec6a50f7e824695651f5cf148b70e7776e8d42c4";
      sha256 = "sha256-7uAtgQEQZkF4gCfVLTAOdttxWqxSdh3ZAmVcnrgZuwM=";
      zfs = {
        rev = "e24cd603b883ad89c11172784485b290f742ef2d";
        sha256 = "sha256-ehV/dsXjTD4b9h16yxtQddnkmA/35ayr+4K7xNlW/Kg=";
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
