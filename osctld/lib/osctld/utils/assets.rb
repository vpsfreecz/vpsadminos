module OsCtld
  module Utils::Assets
    # @param entity [#assets]
    def list_and_validate_assets(entity)
      validator = Assets::Validator.new(entity.assets)
      validator.validate.map do |asset|
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
