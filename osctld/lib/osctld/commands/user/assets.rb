module OsCtld
  class Commands::User::Assets < Commands::Assets
    handle :user_assets

    def execute
      u = DB::Users.find(opts[:name], opts[:pool])
      return error('user not found') unless u

      # Datasets
      add(:dataset, u.dataset, "User's home dataset")

      # Directories and files
      add(:directory, u.homedir, "Home directory")
      add(:file, u.config_path, "osctld's user config")

      add(:entry, '/etc/passwd', "System user") do |path|
        /^#{Regexp.escape(u.sysusername)}:/ =~ File.read(path) ? true : false
      end

      add(:entry, '/etc/group', "System group") do |path|
        /^#{Regexp.escape(u.sysgroupname)}:/ =~ File.read(path) ? true : false
      end

      ok(assets)
    end
  end
end
