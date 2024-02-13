require 'libosctl'
require 'require_all'

module OsCtl
  module Repo
    module Base; end

    # Classes for manipulation of the repository on the server-side
    module Local; end

    # Classes for working with a remote repository over HTTP
    module Remote; end

    module Downloader; end
  end
end

require_rel 'repo/*.rb'
require_rel 'repo/base'
require_rel 'repo/local'
require_rel 'repo/remote'
require_rel 'repo/downloader'
