module OsCtl::Repo::Cli
 class Command < OsCtl::Lib::Cli::Command
    def self.run(klass, method)
      Proc.new do |global_opts, opts, args|
        cmd = klass.new(global_opts, opts, args)

        begin
          cmd.method(method).call

        rescue OsCtl::Repo::ImageNotFound => e
          raise GLI::CustomExit.new(
            "Image not found: #{e.message}",
            OsCtl::Repo::EXIT_IMAGE_NOT_FOUND
          )

        rescue OsCtl::Repo::FormatNotFound => e
          raise GLI::CustomExit.new(
            "Format not found: #{e.message}",
            OsCtl::Repo::EXIT_FORMAT_NOT_FOUND
          )

        rescue OsCtl::Repo::BadHttpResponse => e
          raise GLI::CustomExit.new(
            "Unexpected HTTP error: #{e.message}",
            OsCtl::Repo::EXIT_HTTP_ERROR
          )

        rescue OsCtl::Repo::NetworkError => e
          raise GLI::CustomExit.new(
            "Unexpected network error: #{e.message}",
            OsCtl::Repo::EXIT_NETWORK_ERROR
          )
        end
      end
    end
  end
end
