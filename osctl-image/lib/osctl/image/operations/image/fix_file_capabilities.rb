require 'libosctl'
require 'osctl/image/operations/base'

module OsCtl::Image
  # Fix file capabilities in a built image
  #
  # Since the image is built in a user namespace, its file capabilities include
  # user id (it's a v3 file capability in kernel's terms). This makes the capabilities
  # to work only in the same or compatible user namespace, which is almost never
  # the case in practice. By resetting the capabilities from the host, the kernel
  # will store them without user id (v2 in kernel's terms) and that will make them
  # work in all user namespaces.
  class Operations::Image::FixFileCapabilities < Operations::Base
    include OsCtl::Lib::Utils::Log

    FileCapability = Struct.new(:file, :caps, :flags) do
      def setcap
        "#{caps.join(',')}=#{flags}"
      end

      def to_s
        "#{file} #{setcap}"
      end
    end

    def initialize(image, install_dir)
      @image = image
      @install_dir = install_dir
    end

    def execute
      fix_capabilities(read_capabilities)
    end

    def log_type
      "filecaps #{@image.name}"
    end

    protected

    def read_capabilities
      file_caps = []

      IO.popen("getcap -r #{@install_dir}", 'r') do |io|
        io.each_line do |line|
          # Example lines:
          # /file cap_setuid,cap_net_raw=ep
          # /file with spaces cap_setuid=ep
          # /allcaps =ep
          parts = line.strip.split

          # We explicitly do not handle files with spaces in their name, as those
          # will almost never be found in a base image and it is harder to parse.
          if parts.length != 2
            log(:warn, "Unhandled file capability #{line.inspect}")
            next
          end

          file, caps_str = parts
          caps = []
          cap_flags = nil

          caps_str.split(',').each do |v|
            if v.index('=')
              cap, flags = v.split('=')
            else
              cap = v
              flags = nil
            end

            if flags && cap_flags.nil?
              cap_flags = flags
            elsif flags && cap_flags && flags != cap_flags
              raise OperationError,
                    "unexpected capability #{cap}=#{flags} on #{file.inspect}, expected flags #{cap_flags}"
            end

            caps << cap
          end

          file_cap = FileCapability.new(file, caps, cap_flags)
          log(:info, "Found file capability #{file_cap}")
          file_caps << file_cap
        end
      end

      if $?.exitstatus != 0
        raise OperationError, "getcap failed with exit status #{$?.exitstatus}"
      end

      file_caps
    end

    def fix_capabilities(file_caps)
      file_caps.each do |file_cap|
        unless Kernel.system('setcap', file_cap.setcap, file_cap.file)
          raise OperationError, "failed to set file capability #{file_cap}"
        end
      end
    end
  end
end
