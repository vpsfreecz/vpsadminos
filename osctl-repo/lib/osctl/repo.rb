require 'libosctl'

module OsCtl
  module Repo
    module Base ; end

    # Classes for manipulation of the repository on the server-side
    module Local ; end

    # Classes for working with a remote repository over HTTP
    module Remote ; end

    module Downloader ; end
  end
end

require_relative 'repo/version'
require_relative 'repo/constants'
require_relative 'repo/exceptions'
require_relative 'repo/base/template'
require_relative 'repo/local/index'
require_relative 'repo/local/repository'
require_relative 'repo/remote/template'
require_relative 'repo/remote/index'
require_relative 'repo/remote/repository'
require_relative 'repo/downloader/direct'
require_relative 'repo/downloader/cached'
