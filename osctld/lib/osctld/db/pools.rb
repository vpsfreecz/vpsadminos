require 'osctld/db/list'

module OsCtld
  class DB::Pools < DB::List
    class << self
      %i(get_or_default).each do |v|
        define_method(v) do |*args, &block|
          instance.send(v, *args, &block)
        end
      end
    end

    def get_or_default(name)
      sync do
        if name
          find(name)

        else
          objects.first
        end
      end
    end
  end
end
