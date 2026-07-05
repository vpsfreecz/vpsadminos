{ lib }:
with lib.kernel;
{
  stableKernelVersion = "6.12.95";
  unstableKernelVersion = "6.12.95";

  kernels = {
    "6.12.95" = {
      rev = "a2384967b90f24d2470c9eb15f0e66d938df7e08";
      sha256 = "sha256-QlwV4uFeX7ZbWHMuU14rFXswmpqpb1hdVmYUAGOWRh8=";
      zfs = {
        rev = "6f5f54c3bfd68c1e52b0b6f454ee9679aaa9e83d";
        sha256 = "sha256-4WQWL4wd3TYaTfqEqQ6ZDYLXmqnHW7XQz2DP0FpwsRQ=";
      };
    };
    "6.12.93" = {
      rev = "09a984467872f2ef8022c4e8cabbd260e6f7edcf";
      sha256 = "sha256-UFg1ZnE6BpuCFRrOvS3so0e4isYq3ZAnJrxqI4HVscw=";
      zfs = {
        rev = "6f5f54c3bfd68c1e52b0b6f454ee9679aaa9e83d";
        sha256 = "sha256-4WQWL4wd3TYaTfqEqQ6ZDYLXmqnHW7XQz2DP0FpwsRQ=";
      };
    };
    "6.12.91" = {
      rev = "af3725cb1aaf04ffd59960d110002021e1d90948";
      sha256 = "sha256-1uameJ6OIag2l4FV65qCOSWzEDgeysQ39z4bvvojDyw=";
      zfs = {
        rev = "d4d28949b5a5d774d8677528659e3e84497cc18b";
        sha256 = "sha256-6EtwS4ONz49Z2oAx31bKHf9c7NiVsoXnIB4ngCqFyd4=";
      };
    };
    "6.12.89" = {
      rev = "a42c7bacf76cd80077fc5118e40d6954c37ffccb";
      sha256 = "sha256-zzvj+N4G/tb2H8or6fLQ9Huti7+FMST8bOryjld3cLM=";
      zfs = {
        rev = "d4d28949b5a5d774d8677528659e3e84497cc18b";
        sha256 = "sha256-6EtwS4ONz49Z2oAx31bKHf9c7NiVsoXnIB4ngCqFyd4=";
      };
    };
    "6.12.87" = {
      rev = "d98fa49ce694ee46c7699b69acc3051dce30a7b5";
      sha256 = "sha256-3xmngal5rCzo520Xp7Naw9BiB/g3bgUTxOKdriS6wqU=";
      zfs = {
        rev = "d4d28949b5a5d774d8677528659e3e84497cc18b";
        sha256 = "sha256-6EtwS4ONz49Z2oAx31bKHf9c7NiVsoXnIB4ngCqFyd4=";
      };
    };
    "6.12.81" = {
      rev = "5995eccc096f8057fbdf8b53814793201d1526bc";
      sha256 = "sha256-6N6tB2tQUmCjrnBWSdxeZ88godNc67svj0UhtZ0uKiw=";
      zfs = {
        rev = "d4d28949b5a5d774d8677528659e3e84497cc18b";
        sha256 = "sha256-6EtwS4ONz49Z2oAx31bKHf9c7NiVsoXnIB4ngCqFyd4=";
      };
    };
    "6.12.79" = {
      rev = "ba2e5771d4cf731b6cc5a6de78e39ecb377a7d34";
      sha256 = "sha256-mw1npph/YnU1cOVYKHCgzh5LRo3n63JTPj1TrrS516U=";
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
