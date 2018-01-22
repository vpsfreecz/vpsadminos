module OsCtl::Cli::Top
  class Tui < View
    class Screen
      def open
        raise NotImplementedError
      end
    end
  end
end
