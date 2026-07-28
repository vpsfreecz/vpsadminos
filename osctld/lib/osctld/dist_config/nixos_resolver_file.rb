require 'libosctl'
require 'securerandom'

module OsCtld
  class DistConfig::NixOSResolverFile
    DIRECTORY_MODE = 0o755
    FILE_MODE = 0o644
    MANAGED_DIRECTORY = 'vpsadminos'.freeze
    TARGET_FILE = 'resolv.conf'.freeze

    def initialize(
      run_dir: '/run',
      random_hex: -> { SecureRandom.hex(12) },
      sys: OsCtl::Lib::Sys.new
    )
      @run_dir = run_dir
      @random_hex = random_hex
      @sys = sys
    end

    def write(payload)
      flags = File::RDONLY | File::NOFOLLOW | OsCtl::Lib::Sys::O_DIRECTORY
      File.open(run_dir, flags) do |run_directory|
        raise Errno::ENOTDIR, run_dir unless run_directory.stat.directory?

        managed_directory = open_managed_directory(run_directory)
        begin
          validate_target(managed_directory)

          token = random_hex.call
          unless token.match?(/\A[0-9a-f]+\z/)
            raise ArgumentError, 'invalid temporary-file token'
          end

          temporary = ".resolv.conf.#{token}"
          created = false
          temporary_file = nil

          begin
            open_flags = File::WRONLY | File::CREAT | File::EXCL | File::NOFOLLOW
            temporary_file = sys.openat_io(
              managed_directory,
              temporary,
              flags: open_flags,
              mode: FILE_MODE
            )
            created = true
            temporary_identity = file_identity(temporary_file)
            temporary_file.write(payload)
            temporary_file.flush
            temporary_file.fsync
            sys.fchmod(temporary_file, FILE_MODE)

            verify_directory_entry(run_directory, managed_directory)
            verify_entry_identity(
              managed_directory,
              temporary,
              temporary_identity
            )
            sys.renameat(
              managed_directory,
              temporary,
              managed_directory,
              TARGET_FILE
            )
            created = false

            verify_entry_identity(
              managed_directory,
              TARGET_FILE,
              temporary_identity
            )
            verify_directory_entry(run_directory, managed_directory)
            managed_directory.fsync
          ensure
            temporary_file&.close
            if created
              unlink_created_temporary(
                managed_directory,
                temporary,
                temporary_identity
              )
            end
          end
        ensure
          managed_directory.close
        end
      end

      true
    end

    protected

    attr_reader :run_dir, :random_hex, :sys

    def managed_dir
      File.join(run_dir, MANAGED_DIRECTORY)
    end

    def target_path
      File.join(managed_dir, TARGET_FILE)
    end

    def open_managed_directory(run_directory)
      begin
        sys.mkdirat(run_directory, MANAGED_DIRECTORY, DIRECTORY_MODE)
      rescue Errno::EEXIST
        # Validate the existing object below.
      end

      flags = File::RDONLY | File::NOFOLLOW | OsCtl::Lib::Sys::O_DIRECTORY
      directory = sys.openat_io(
        run_directory,
        MANAGED_DIRECTORY,
        flags:
      )
      stat = directory.stat
      raise Errno::ENOTDIR, managed_dir unless stat.directory?
      unless stat.uid == Process.euid && stat.gid == Process.egid
        raise Errno::EPERM, managed_dir
      end

      sys.fchmod(directory, DIRECTORY_MODE)
      directory
    rescue StandardError
      directory&.close
      raise
    end

    def validate_target(directory)
      target = open_path_handle(directory, TARGET_FILE)
      stat = target.stat
      raise Errno::EINVAL, target_path unless stat.file?
      unless stat.uid == Process.euid && stat.gid == Process.egid
        raise Errno::EPERM, target_path
      end
    rescue Errno::ENOENT
      nil
    ensure
      target&.close
    end

    def verify_directory_entry(run_directory, directory)
      live_directory = sys.openat_io(
        run_directory,
        MANAGED_DIRECTORY,
        flags: File::RDONLY | File::NOFOLLOW | OsCtl::Lib::Sys::O_DIRECTORY
      )
      return if file_identity(live_directory) == file_identity(directory)

      raise Errno::ESTALE, managed_dir
    ensure
      live_directory&.close
    end

    def verify_entry_identity(directory, name, expected_identity)
      entry = open_path_handle(directory, name)
      return if file_identity(entry) == expected_identity

      raise Errno::ESTALE, File.join(managed_dir, name)
    ensure
      entry&.close
    end

    def unlink_created_temporary(directory, name, expected_identity)
      verify_entry_identity(directory, name, expected_identity)
      sys.unlinkat(directory, name)
    rescue Errno::ENOENT, Errno::ESTALE
      nil
    end

    def open_path_handle(directory, name)
      sys.openat_io(
        directory,
        name,
        flags: OsCtl::Lib::Sys::O_PATH | File::NOFOLLOW
      )
    end

    def file_identity(io)
      stat = io.stat
      [stat.dev, stat.ino]
    end
  end
end
