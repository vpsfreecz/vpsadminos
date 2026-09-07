import ../make-test.nix (
  { pkgs }:
  {
    name = "defaults";

    description = ''
      Test expected default vpsAdminOS configuration
    '';

    tags = [ "ci" ];

    machine = import ../machines/vpsadminos/with-tank.nix {
      inherit pkgs;
      config = {
        services.rsyslogd.extraConfig = ''
          template(name="replaceRegression" type="string"
            string="%$!overlap%|%$!repeated%|%$!trailing%|%$!empty%\n")
          if ($programname == "rsyslog-replace-regression") then {
            set $!overlap = replace("aab", "ab", "0123456789");
            set $!repeated = replace("aaaaab", "aaab", "Q");
            set $!trailing = replace("ababa", "aba", "X");
            set $!empty = replace("abc", "", "Q");
            action(type="omfile" file="/var/log/rsyslog-replace-regression"
              template="replaceRegression")
          }
        '';
      };
    };

    testScript = ''
      machine.start
      machine.fails('cat /sys/module/apparmor/parameters/enabled')

      machine.wait_for_service('pool-tank')

      st, output = machine.succeeds('zfs get -H -o value xattr tank')
      fail "xattr = '#{output}', expected 'on' or 'sa'" unless %w[on sa].include?(output.strip)

      machine.wait_for_service('rsyslog')
      machine.succeeds('/run/current-system/sw/bin/logger -t rsyslog-replace-regression ready')
      machine.wait_until_succeeds('test -s /var/log/rsyslog-replace-regression')
      _, output = machine.succeeds('cat /var/log/rsyslog-replace-regression')
      expected = 'a0123456789|aaQ|Xba|Q'
      fail "rsyslog replace returned #{output.inspect}, expected #{expected.inspect}" unless output.strip == expected
    '';
  }
)
