{ lib }:
value:
let
  delimiter = "VPSADMINOS_LIVEPATCH_JSON_END";
  json = builtins.toJSON value;
in
assert !lib.hasInfix "\n${delimiter}\n" "\n${json}\n";
''
  JSON.parse(<<~'${delimiter}')
    ${json}
  ${delimiter}
''
