require 'osctl/image/operations/base'

module OsCtl::Image
  class Operations::Builder::WaitForNetwork < Operations::Base
    # @return [Builder]
    attr_reader :builder

    # @param builder [Builder]
    def initialize(builder)
      super()
      @builder = builder
    end

    def execute
      script = <<~EOF
        #!/bin/sh

        test_network() {
          curl --head https://images.vpsadminos.org > /dev/null 2>&1
          [ $? = 0 ] && return 0

          wget -q -O - https://images.vpsadminos.org > /dev/null 2>&1
          [ $? = 0 ] && return 0

          ping -c 1 images.vpsadminos.org > /dev/null 2>&1
          [ $? = 0 ] && return 0

          return 1
        }

        test_network
        if [ $? != 0 ] ; then
          echo -n "Waiting for network..."
          for i in $(seq 1 60); do
            test_network && exit 0
            echo -n "."
            sleep 1
          done
          exit 1
        else
          echo "Network online"
        fi
      EOF

      rc = Operations::Builder::ControlledRunscript.run(
        builder,
        script:,
        name: 'osctl-image.wait-for-network'
      )

      return unless rc != 0

      raise OperationError, "network setup failed with exit status #{rc}"
    end
  end
end
