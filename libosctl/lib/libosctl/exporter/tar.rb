require 'libosctl/exporter/base'

module OsCtl::Lib
  # Handles dumping containers into tar archives
  #
  # The container's rootfs is stored as a compressed tar archive.
  class Exporter::Tar < Exporter::Base
    include Utils::Log
    include Utils::System

    def pack_rootfs
      tar.mkdir('rootfs', DIR_MODE)
      tar.add_file('rootfs/base.tar.gz', FILE_MODE) do |tf|
        IO.popen("exec tar --xattrs-include=security.capability --xattrs -cz -C #{ct.rootfs} .") do |io|
          tf.write(io.read(BLOCK_SIZE)) until io.eof?
        end

        fail "tar failed with exit status #{$?.exitstatus}" if $?.exitstatus != 0
      end
    end

    def format
      :tar
    end
  end
end
