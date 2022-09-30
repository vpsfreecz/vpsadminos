require 'osctl/exporter/collectors/base'
require 'libosctl'

module OsCtl::Exporter
  class Collectors::KernelKeyring < Collectors::Base
    def setup
      add_metric(
        :users_usage,
        :gauge,
        :kernel_keyring_users_usage,
        docstring: 'Kernel-internal usage count',
        labels: %i(uid),
      )
      add_metric(
        :users_nkeys,
        :gauge,
        :kernel_keyring_users_nkeys,
        docstring: 'The total number of keys owned by the user',
        labels: %i(uid),
      )
      add_metric(
        :users_nikeys,
        :gauge,
        :kernel_keyring_users_nikeys,
        docstring: 'The number of nkeys that have been instantiated',
        labels: %i(uid),
      )
      add_metric(
        :users_qnkeys,
        :gauge,
        :kernel_keyring_users_qnkeys,
        docstring: 'The number of keys owned by the user',
        labels: %i(uid),
      )
      add_metric(
        :users_maxkeys,
        :gauge,
        :kernel_keyring_users_maxkeys,
        docstring: 'The maximum number of keys that the user may own',
        labels: %i(uid),
      )
      add_metric(
        :users_qnbytes,
        :gauge,
        :kernel_keyring_users_qnbytes,
        docstring: 'The number of bytes consumed in payloads of the keys owned by this user',
        labels: %i(uid),
      )
      add_metric(
        :users_maxbytes,
        :gauge,
        :kernel_keyring_users_maxbytes,
        docstring: 'The upper limit on the number of bytes in key payloads for the user',
        labels: %i(uid),
      )
    end

    def collect(client)
      OsCtl::Lib::KernelKeyring.new.each do |ku|
        @users_usage.set(ku.usage, labels: {uid: ku.uid})
        @users_nkeys.set(ku.nkeys, labels: {uid: ku.uid})
        @users_nikeys.set(ku.nikeys, labels: {uid: ku.uid})
        @users_qnkeys.set(ku.qnkeys, labels: {uid: ku.uid})
        @users_maxkeys.set(ku.maxkeys, labels: {uid: ku.uid})
        @users_qnbytes.set(ku.qnbytes, labels: {uid: ku.uid})
        @users_maxbytes.set(ku.maxbytes, labels: {uid: ku.uid})
      end
    end
  end
end
