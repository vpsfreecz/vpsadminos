module OsCtld
  module Utils::Assets
    def list_and_validate_assets(entity)
      entity.assets.map do |asset|
        {
          type: asset.type,
          path: asset.path,
          opts: asset.opts,
          state: asset.state,
          errors: asset.errors,
        }
      end
    end
  end
end
