module OsCtl::Lib
  module Utils::Log
    module PrivateMethods
      LEVELS = %i[debug info warn error fatal unknown].freeze

      def self.log(level, type, msg)
        Logger.log(
          LEVELS.include?(level) ? level : :unknown,
          "[#{type}] #{msg}"
        )
      end

      def self.resolve_type(type)
        return 'general' unless type

        if type.respond_to?(:log_type)
          type.log_type

        else
          type.to_s
        end
      end
    end

    module CommonMethods
      # Arguments are one of:
      #  - `level`, `type`, `msg`
      #  - `level`, `msg` (`type` is taken as `self`)
      #  - `msg`
      #
      # `level` defaults to `info`, `type` to `general`.
      #
      # If `type` responds to `log_type`, it is called to return the log type.
      #
      # Log levels: {PrivateMethods::LEVELS}
      # Types: init, general, regular, special types and any other
      def log(*args)
        if args.count == 3
          level, type, msg = args

          PrivateMethods.log(level, PrivateMethods.resolve_type(type), msg)

        elsif args.count == 2
          level, msg = args

          PrivateMethods.log(level, PrivateMethods.resolve_type(self), msg)

        elsif args.count == 1
          PrivateMethods.log(:info, :general, args.first)

        else
          raise 'Provide either one or three arguments'
        end
      end
    end

    def self.included(klass)
      klass.send(:include, CommonMethods)
      klass.send(:extend, CommonMethods)
    end
  end
end
