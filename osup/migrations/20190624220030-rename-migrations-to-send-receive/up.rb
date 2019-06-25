require_relative 'common'

m = RenameMigration.new
m.rename_pool_config('migration', 'send-receive')
m.rename_ct_configs('migration_log', 'send_log')
