# frozen_string_literal: true

require 'rubygems'
require 'geminabox'

def env_bool(name, default)
  value = ENV.fetch(name, default)

  !%w[0 false no off].include?(value.downcase)
end

def normalized_url(value)
  value.end_with?('/') ? value : "#{value}/"
end

Geminabox.data = ENV.fetch(
  'VPSADMINOS_LOCAL_GEMINABOX_DATA',
  File.expand_path('../.gems/geminabox-data', __dir__)
)
Geminabox.rubygems_proxy = env_bool('VPSADMINOS_LOCAL_GEMINABOX_PROXY', '1')
Geminabox.allow_remote_failure = env_bool('VPSADMINOS_LOCAL_GEMINABOX_ALLOW_REMOTE_FAILURE', '1')
Geminabox.allow_replace = env_bool('VPSADMINOS_LOCAL_GEMINABOX_ALLOW_REPLACE', '1')
Geminabox.allow_upload = true

upstream = normalized_url(
  ENV.fetch('VPSADMINOS_LOCAL_GEMINABOX_UPSTREAM', 'https://rubygems.vpsfree.cz')
)
Geminabox.ruby_gems_url = upstream
Geminabox.bundler_ruby_gems_url = upstream

run Geminabox::Server
