require 'fileutils'
require 'net/http'
require 'time'
require 'osctl/repo/downloader/base'

module OsCtl::Repo
  # Download template in a specified format and cache it locally
  class Downloader::Cached < Downloader::Base
    # @return [Array<Remote::Template>]
    def list
      connect do |http|
        index = nil

        repo.lock_index do
          update_index(http)
          index = Remote::Index.from_file(repo, repo.index_path)
        end

        index.templates
      end
    end

    # param opts [Hash]
    # @option opts [Boolean] :force_check
    # @yieldparam [String] downloaded data
    # @return [String] path to image
    def get(vendor, variant, arch, dist, vtag, format, opts = {}, &block)
      if opts.has_key?(:force_check)
        force_check = opts[:force_check]
      else
        force_check = false
      end

      begin
        image_path, fh = download(
          vendor,
          variant,
          arch,
          dist,
          vtag,
          format,
          block ? true : false,
        )
      rescue SystemCallError,
             OpenSSL::SSL::SSLError,
             BadHttpResponse => dl_e
        if force_check
          raise
        elsif block
          begin
            fh = read_from_cache(vendor, variant, arch, dist, vtag, format)
          rescue CacheMiss => cache_e
            fail "Unable to reach remote repository: #{dl_e.message}; "+
                 "not found in cache: #{cache_e.message}"
          end
        end
      end

      if block
        block.call(fh.read(16*1024)) until fh.eof?
        fh.close
      end

      File.absolute_path(image_path)
    end

    protected
    attr_reader :repo

    # @return [Array(String, [IO, nil])] `[image_path, io|nil]`
    def download(vendor, variant, arch, dist, vtag, format, open)
      path = fh = nil

      connect do |http|
        index = nil

        repo.lock_index do
          update_index(http)
          index = Remote::Index.from_file(repo, repo.index_path)
        end

        t = index.lookup(vendor, variant, arch, dist, vtag)

        raise TemplateNotFound, t unless t
        raise FormatNotFound.new(t, format) unless t.has_image?(format)

        FileUtils.mkdir_p(t.abs_dir_path)

        t.lock(format) do
          path = fetch_template(http, t, format)
          fh = File.open(path, 'r') if open
        end
      end

      [path, fh]
    end

    def read_from_cache(vendor, variant, arch, dist, vtag, format)
      fh = nil
      index = nil

      repo.lock_index do
        begin
          index = Remote::Index.from_file(repo, repo.index_path)
        rescue Errno::ENOENT
          raise CacheMiss, 'Repository index not found in cache'
        end
      end

      t = index.lookup(vendor, variant, arch, dist, vtag)

      raise TemplateNotFound, t unless t
      raise FormatNotFound.new(t, format) unless t.has_image?(format)

      t.lock(format) do
        unless t.cached?(format)
          raise CacheMiss, "Template #{t} not found in cache"
        end

        fh = File.open(t.abs_cache_path(format), 'r')
      end

      fh
    end

    def update_index(http)
      uri = index_uri

      if repo.has_index?
        headers = {'If-Modified-Since' => File.stat(repo.index_path).mtime.httpdate}

        http.request_get(uri.path, headers) do |res|
          case res.code
          when '200'
            File.open(repo.index_path, 'w') do |f|
              res.read_body { |fragment| f.write(fragment) }
            end

            if res['last-modified']
              # Save the modtime for later requests
              FileUtils.touch(
                repo.index_path,
                mtime: Time.httpdate(res['last-modified'])
              )
            end

          when '304'
            # index unchanged

          else
            raise BadHttpResponse, res.code
          end
        end

      else
        http.request_get(uri.path) do |res|
          raise BadHttpResponse, res.code if res.code != '200'

          File.open(repo.index_path, 'w') do |f|
            res.read_body do |fragment|
              f.write(fragment)
            end
          end

          if res['last-modified']
            # Save the modtime for later requests
            FileUtils.touch(
              repo.index_path,
              mtime: Time.httpdate(res['last-modified'])
            )
          end
        end
      end
    end

    def fetch_template(http, t, format)
      uri = URI(t.abs_image_url(format))
      t_path = t.abs_cache_path(format)
      t_tmp_path = "#{t_path}.new"

      if t.cached?(format)
        headers = {'If-Modified-Since' => File.stat(t_path).mtime.httpdate}

        http.request_get(uri.path, headers) do |res|
          case res.code
          when '200'
            File.open(t_tmp_path, 'w') do |f|
              res.read_body do |fragment|
                f.write(fragment)
              end
            end

            if res['last-modified']
              # Save the modtime for later requests
              FileUtils.touch(t_tmp_path, mtime: Time.httpdate(res['last-modified']))
            end

            File.rename(t_tmp_path, t_path)
            return t_path

          when '304'
            # template unchanged

          else
            raise BadHttpResponse, res.code
          end
        end

      else # download it
        http.request_get(uri.path) do |res|
          File.open(t_tmp_path, 'w') do |f|
            raise BadHttpResponse, res.code if res.code != '200'

            res.read_body do |fragment|
              f.write(fragment)
            end
          end

          if res['last-modified']
            # Save the modtime for later requests
            FileUtils.touch(t_tmp_path, mtime: Time.httpdate(res['last-modified']))
          end

          File.rename(t_tmp_path, t_path)
        end
      end

      t_path
    end
  end
end
