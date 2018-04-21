module OsCtld
  class Container::Hooks::PostStop < Container::Hooks::Base
    hook :post_stop
    blocking false
  end
end
