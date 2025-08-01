import ../make-test.nix (
  { pkgs }:
  {
    name = "secrets";

    description = ''
      Test secrets passed through `system.secretsDir`
    '';

    tags = [ "ci" ];

    machine = import ../machines/with-empty.nix {
      inherit pkgs;
      config =
        { config, ... }:
        {
          system.secretsDir = toString (
            pkgs.runCommand "secrets-dir" { } ''
              mkdir $out
              echo secret hello > $out/secret-hello.txt

              mkdir $out/subdir
              echo another secret > $out/subdir/another.txt
            ''
          );
        };
    };

    testScript = ''
      before(:suite) do
        machine.start
        machine.wait_for_boot
      end

      describe '/var/secrets' do
        it 'exists' do
          machine.succeeds('stat /var/secrets')
        end

        it 'has 0500 permissions' do
          expect(machine.succeeds('stat -c %a /var/secrets')[1].strip).to eq('500')
        end

        it 'belongs to root:root' do
          expect(machine.succeeds('stat -c %u:%g /var/secrets')[1].strip).to eq('0:0')
        end

        it 'contains secret-hello.txt' do
          expect(machine.succeeds('cat /var/secrets/secret-hello.txt')[1].strip).to eq('secret hello')
        end

        it 'contains subdir/another.txt' do
          expect(machine.succeeds('cat /var/secrets/subdir/another.txt')[1].strip).to eq('another secret')
        end

        it "doesn't contain other files" do
          content = ([""] + %w[secret-hello.txt subdir subdir/another.txt]).map do |v|
            File.join('/var/secrets', v)
          end

          expect(machine.succeeds("find /var/secrets/ | sort")[1].strip.split("\n")).to eq(content)
        end

        it 'is not in /nix/store' do
          expect(machine.succeeds("find /nix/store -name secret-hello.txt")[1].strip).to be_empty
        end
      end
    '';
  }
)
