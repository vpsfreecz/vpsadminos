require 'libosctl'

module OsCtld
  class Assets::Validator
    Run = Struct.new(:dataset_tree)

    # @return [Array<Asset::Base>]
    attr_reader :assets

    # @param assets [Array<Asset::Base>]
    def initialize(assets = [])
      @assets = assets.clone
    end

    # @param asset [Asset::Base]
    def add_asset(asset)
      assets << asset
    end

    # @param new_assets [Array<Asset::Base>]
    def add_assets(new_assets)
      assets.concat(new_assets)
    end

    # Validate and return assets
    # @return [Array<Asset::Base>]
    def validate
      dataset_hash = {}
      property_hash = {}

      assets.each do |asset|
        datasets, properties = asset.prefetch_zfs

        datasets.each do |ds|
          dataset_hash[ds] = true
        end

        properties.each do |p|
          property_hash[p] = true
        end
      end

      propreader = OsCtl::Lib::Zfs::PropertyReader.new
      tree = propreader.read(
        dataset_hash.keys,
        property_hash.keys,
        recursive: false,
        ignore_error: true,
      )

      run = Run.new(tree)

      assets.each do |asset|
        asset.send(:run_validation, run)
      end

      assets
    end
  end
end
