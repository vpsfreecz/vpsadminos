{ lib }:
with lib.kernel;
{
  stableKernelVersion = "6.18";
  unstableKernelVersion = "6.18";

  kernels = {
    "6.18" = {
      rev = "f86d9da6fdba0c6cf1a7378d90bc80faa4d09a5c";
      sha256 = "sha256-U4qKPcZGKBeOH9pTtz7Rb7r0Bty7Z4+vv4JWY9C6Kj8=";
      structuredExtraConfig = {
        DAMON = yes;
        DAMON_VADDR = yes;
        DAMON_PADDR = yes;
        DAMON_SYSFS = yes;
        DAMON_RECLAIM = yes;
        TRACING_NS = yes;
        SECURITY_SELINUX = lib.mkForce yes;
        SECURITY_APPARMOR = lib.mkForce yes;
        SECURITY_VPSADMIN_STACK_SELINUX_APPARMOR = yes;
        SECURITY_LSM_NAMESPACE = yes;
      };
      zfs = {
        rev = "847cec703b4bc64d2fa75e5bcbc95663cd97d2f8";
        sha256 = "sha256-p65ca7b3zjUvcR3NWDR7f10EeFNTeenH8lZ8zKJ/bF0=";
      };
    };
    "6.12.81" = {
      rev = "5995eccc096f8057fbdf8b53814793201d1526bc";
      sha256 = "sha256-6N6tB2tQUmCjrnBWSdxeZ88godNc67svj0UhtZ0uKiw=";
      structuredExtraConfig = {
        DAMON = yes;
        DAMON_VADDR = yes;
        DAMON_PADDR = yes;
        DAMON_SYSFS = yes;
        DAMON_RECLAIM = yes;
      };
      zfs = {
        rev = "d4d28949b5a5d774d8677528659e3e84497cc18b";
        sha256 = "sha256-6EtwS4ONz49Z2oAx31bKHf9c7NiVsoXnIB4ngCqFyd4=";
      };
    };
    "6.12.79" = {
      rev = "ba2e5771d4cf731b6cc5a6de78e39ecb377a7d34";
      sha256 = "sha256-mw1npph/YnU1cOVYKHCgzh5LRo3n63JTPj1TrrS516U=";
      structuredExtraConfig = {
        DAMON = yes;
        DAMON_VADDR = yes;
        DAMON_PADDR = yes;
        DAMON_SYSFS = yes;
        DAMON_RECLAIM = yes;
      };
      zfs = {
        rev = "d4d28949b5a5d774d8677528659e3e84497cc18b";
        sha256 = "sha256-6EtwS4ONz49Z2oAx31bKHf9c7NiVsoXnIB4ngCqFyd4=";
      };
    };
    "6.12.70" = {
      rev = "bd0ac1922db0adb7153672bbca8bd1270a367613";
      sha256 = "sha256-Ti+xZg+9DSqAURo6XTAfnVWVAkf5N3k3V2LP1PpqVT8=";
      zfs = {
        rev = "72745ce6bd8a0793c7df45cdc6a3c54f4aeec5dc";
        sha256 = "sha256-Czj4bcTJztcX24mKxLzmcdNeIlfiJh95FbDHJT+fjfk=";
      };
    };
    "6.12.59" = {
      rev = "51ef910ea3116f8c41a5643d4d5c83eb18b03f32";
      sha256 = "sha256-YFodbgNJlkZhm35kQMuNcgkeX765dbvs9OxClSiZ6KA=";
      zfs = {
        rev = "82692f213319780c6546ee4f835afb849b932391";
        sha256 = "sha256-4AyHAyTryhAKs4JRn/Yebn83P1oM1e7Ts69gwjlNWa0=";
      };
    };
    "6.12.58" = {
      rev = "ca71e50004db2e50e769faeded42be79070f1fb1";
      sha256 = "sha256-/7uiLy9WJgWyg1DhyDm1a6ul/oP7/GkiPAxbPe6k5VA=";
      zfs = {
        rev = "82692f213319780c6546ee4f835afb849b932391";
        sha256 = "sha256-4AyHAyTryhAKs4JRn/Yebn83P1oM1e7Ts69gwjlNWa0=";
      };
    };
    "6.12.48" = {
      rev = "5bbd15d9e42bca0ca4a8d102f5ea95cc71803e44";
      sha256 = "sha256-sJThPPzpW2gZinao9dLBpFokxwpsm3U4QxHvNk0S+GA=";
      zfs = {
        rev = "e0156ef58e8a113524efa45553e0321bf8c0f124";
        sha256 = "sha256-4Y73rsSguirDTHZHZATcMGeN3vWwlqEEWZOnBXJDNu8=";
      };
    };
  };
}
