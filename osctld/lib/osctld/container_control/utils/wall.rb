module OsCtld
  module ContainerControl::Utils::Wall
    module Frontend
      # @param message [String]
      # @param banner [Boolean]
      # @return [String]
      def make_message(message, banner: true)
        ret =
          if banner
            "Message from host machine #{Socket.gethostname} (#{Time.now}):\n\n#{message}"
          else
            message
          end

        "\n\n#{ret}\n\n"
      end
    end

    module Runner
      # @param message [String]
      # @return [Process::Status]
      def ct_wall(message)
        pid = lxc_ct.attach do
          UtmpReader.read_utmp_fhs(max_entries: 32) do |entry|
            next if entry.record_type != :user_process

            begin
              write_to_tty(File.join('/dev', entry.ut_line), message)
            rescue SystemCallError
              next
            end
          end
        end

        begin
          Process.wait(pid)
          $?
        rescue Errno::ECHILD
          1
        end
      end

      # @param path [String] pty device
      # @param message [String]
      def write_to_tty(path, message)
        File.write(path, message)
      end
    end
  end
end
