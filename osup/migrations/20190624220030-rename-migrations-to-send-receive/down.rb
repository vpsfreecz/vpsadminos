require_relative 'common'

m = RenameMigration.new
m.rename_pool_config('send-receive', 'migration')
m.rename_ct_configs('send_log', 'migration_log')
