require 'osctl/template/operations/base'

module OsCtl::Template
  class Operations::Builder::WaitForNetwork < Operations::Base
    # @return [Builder]
    attr_reader :builder

    # @param builder [Builder]
    def initialize(builder)
      @builder = builder
    end

    def execute
      tmp = Tempfile.new('/tmp/osctl-template.wait-for-network')
      File.chmod(0755, tmp.path)
      tmp.write(<<EOF
#!/bin/sh

test_network() {
  curl https://templates.vpsadminos.org > /dev/null 2>&1
  return $?
}

test_network
if [ $? != 0 ] ; then
  echo -n "Waiting for network..."
  for i in {1..60} ; do
    test_network && exit 0
    echo -n "."
    sleep 1
  done
  exit 1
else
  echo "Network online"
fi
EOF
)
      tmp.close

      begin
        rc = OsCtldClient.new.runscript(builder.ctid, tmp.path)
        fail "network setup failed with exit status #{rc}" if rc != 0
      ensure
        tmp.unlink
      end
    end
  end
end
