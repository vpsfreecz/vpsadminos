# frozen_string_literal: true

module StructHelpers
  DatasetInfo = Struct.new(:name, :relative_name, keyword_init: true)
  ProcessInfo = Struct.new(:ct_id, :state, keyword_init: true)
  RawValue = Struct.new(:raw, keyword_init: true)
  LoadAvgInfo = Struct.new(:avg, keyword_init: true)
  ObjsetInfo = Struct.new(
    :write_bytes,
    :read_bytes,
    :write_ios,
    :read_ios,
    keyword_init: true
  )
  KeyringUsageInfo = Struct.new(:qnkeys, :qnbytes, keyword_init: true)
  KeyringUserInfo = Struct.new(
    :uid,
    :usage,
    :nkeys,
    :nikeys,
    :qnkeys,
    :maxkeys,
    :qnbytes,
    :maxbytes,
    keyword_init: true
  )
  ZpoolVdevInfo = Struct.new(
    :name,
    :role,
    :type,
    :state,
    :read,
    :write,
    :checksum,
    :virtual_devices,
    keyword_init: true
  )
  ZpoolPoolInfo = Struct.new(
    :name,
    :state,
    :scan,
    :scan_percent,
    :virtual_devices,
    keyword_init: true
  )
  ZpoolStatusInfo = Struct.new(:pools, keyword_init: true)
  class TreeDatasetInfo
    attr_reader :properties

    def initialize(properties:, dataset:)
      @properties = properties
      @dataset = dataset
    end

    def as_dataset(base:)
      @dataset
    end
  end
  TreeRootInfo = Struct.new(:tree_datasets, keyword_init: true) do
    def each_tree_dataset(&block)
      tree_datasets.each(&block)
    end
  end
  TxgInfo = Struct.new(
    :txg,
    :ndirty,
    :nread,
    :nwritten,
    :reads,
    :writes,
    :otime_ns,
    :qtime_ns,
    :wtime_ns,
    :stime_ns,
    keyword_init: true
  )

  def dataset_info(**)
    DatasetInfo.new(**)
  end

  def process_info(**)
    ProcessInfo.new(**)
  end

  def raw_value(raw)
    RawValue.new(raw:)
  end

  def load_avg_info(avg)
    LoadAvgInfo.new(avg:)
  end

  def objset_info(**)
    ObjsetInfo.new(**)
  end

  def keyring_usage_info(**)
    KeyringUsageInfo.new(**)
  end

  def keyring_user_info(**)
    KeyringUserInfo.new(**)
  end

  def zpool_vdev_info(**)
    ZpoolVdevInfo.new(**)
  end

  def zpool_pool_info(**)
    ZpoolPoolInfo.new(**)
  end

  def zpool_status_info(pools)
    ZpoolStatusInfo.new(pools:)
  end

  def tree_dataset_info(**)
    TreeDatasetInfo.new(**)
  end

  def tree_root_info(tree_datasets)
    TreeRootInfo.new(tree_datasets:)
  end

  def txg_info(**)
    TxgInfo.new(**)
  end
end

RSpec.configure do |config|
  config.include StructHelpers
end
