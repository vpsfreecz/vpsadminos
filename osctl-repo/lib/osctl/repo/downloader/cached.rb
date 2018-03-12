require 'fileutils'
require 'net/http'
require 'time'

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

    # yieldparam [String] downloaded data
    def download(vendor, variant, arch, dist, vtag, format, &block)
      connect do |http|
        index = nil

        repo.lock_index do
          update_index(http)
          index = Remote::Index.from_file(repo, repo.index_path)
        end

        t = index.lookup(vendor, variant, arch, dist, vtag)

        raise TemplateNotFound, t unless t
        raise FormatNotFound.new(t, format) unless t.has_rootfs?(format)

        FileUtils.mkdir_p(t.abs_dir_path)

        t.lock(format) do
          get_template(http, t, format, &block)
        end
      end
    end

    protected
    attr_reader :repo

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

    def get_template(http, t, format)
      uri = URI(t.abs_rootfs_url(format))
      t_path = t.abs_rootfs_path(format)

      if t.cached?(format)
        headers = {'If-Modified-Since' => File.stat(t_path).mtime.httpdate}

        http.request_get(uri.path, headers) do |res|
          case res.code
          when '200'
            File.open(t_path, 'w') do |f|
              res.read_body do |fragment|
                f.write(fragment)
                yield(fragment) if block_given?
              end
            end

            if res['last-modified']
              # Save the modtime for later requests
              FileUtils.touch(t_path, mtime: Time.httpdate(res['last-modified']))
            end

            return

          when '304'
            # template unchanged
            if block_given?
              File.open(t_path, 'r') do |f|
                yield(f.read(16*1024)) until f.eof?
              end
            end

          else
            raise BadHttpResponse, res.code
          end
        end

      else # download it
        http.request_get(uri.path) do |res|
          File.open(t_path, 'w') do |f|
            raise BadHttpResponse, res.code if res.code != '200'

            res.read_body do |fragment|
              f.write(fragment)
              yield(fragment) if block_given?
            end
          end

          if res['last-modified']
            # Save the modtime for later requests
            FileUtils.touch(t_path, mtime: Time.httpdate(res['last-modified']))
          end
        end
      end
    end
  end
end
