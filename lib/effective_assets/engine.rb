module EffectiveAssets
  class Engine < ::Rails::Engine
    engine_name 'effective_assets'

    config.autoload_paths += Dir["#{config.root}/lib/validators/", "#{config.root}/lib/inputs/"]

    config.eager_load_paths += Dir["#{config.root}/lib/validators/", "#{config.root}/lib/inputs/"]

    # Include acts_as_addressable concern and allow any ActiveRecord object to call it
    initializer 'effective_assets.active_record' do |app|
      app.config.to_prepare do
        ActiveSupport.on_load :active_record do
          ActiveRecord::Base.extend(ActsAsAssetBox::ActiveRecord)
        end
      end
    end

    initializer 'effective_assets.action_view' do |app|
      app.config.to_prepare do
        ActiveSupport.on_load :action_view do
          ActionView::Helpers::FormBuilder.send(:include, AssetBoxFormInput)
        end
      end
    end

    # Set up our default configuration options.
    initializer "effective_assets.defaults", :before => :load_config_initializers do |app|
      eval File.read("#{config.root}/config/effective_assets.rb")
    end

    initializer "effective_assets.append_precompiled_assets" do |app|
      Rails.application.config.assets.precompile += [
        'effective_assets_manifest.js', 'effective_assets.js', 'effective_assets_iframe.js', 'effective_assets_iframe.css',
        'effective_assets/*', 'mime-types/*'
      ]
    end

    # ActiveAdmin (optional)
    # This prepends the load path so someone can override the assets.rb if they want.
    initializer 'effective_assets.active_admin' do
      if defined?(ActiveAdmin) && EffectiveAssets.use_active_admin == true
        ActiveAdmin.application.load_paths.unshift *Dir["#{config.root}/active_admin"]
      end
    end

    # Rails 7.2 compatibility: Patch serialize method to handle old API
    initializer 'effective_assets.rails72_serialize_compat' do |app|
      app.config.to_prepare do
        # Monkey patch to fix serialize method for Rails 7.2 compatibility
        # In Rails 7.2, serialize changed from serialize(attr, coder) to serialize(attr, coder: coder)
        # This patch allows the old API to work by converting it to the new API
        module SerializeRails72Compat
          def serialize(attr_name, *args, **options)
            # If a second positional argument is provided (old API), convert it to keyword argument
            options[:coder] = args.first if args.length > 0 && !options.key?(:coder) && args.first

            # Rails 7.2 signature: serialize(attr_name, coder: nil, type: Object, comparable: false, yaml: {}, **options)
            # We must explicitly call the parent method with ONLY attr_name as positional and everything else as keywords
            # Using method() to get the original method and call it directly to avoid super forwarding issues
            original_method = method(:serialize).super_method
            if options.any?
              original_method.call(attr_name, **options)
            else
              original_method.call(attr_name)
            end
          end
        end

        # Patch build_column_serializer to handle coder initialization errors
        module BuildColumnSerializerPatch
          def build_column_serializer(name, coder, type, yaml)
            # Rails 7.2 may try to instantiate coders with 2 arguments, but some only accept 0-1
            # Wrap the call to handle ArgumentError gracefully

            super
          rescue ArgumentError => e
            raise unless e.message.include?('wrong number of arguments') && coder.is_a?(Class)

            # If it's a class coder and initialization fails, try creating an instance first
            coder_instance = begin
              # Try with no arguments
              coder.new
            rescue ArgumentError
              begin
                # Try with one argument
                coder.new(name)
              rescue ArgumentError
                # If both fail, use the class itself (Rails should handle this)
                coder
              end
            end
            # Retry with the instance instead of the class
            super(name, coder_instance, type, yaml)
          end
        end

        # Prepend both modules
        ActiveRecord::AttributeMethods::Serialization::ClassMethods.prepend(SerializeRails72Compat)
        ActiveRecord::AttributeMethods::Serialization::ClassMethods.prepend(BuildColumnSerializerPatch)
      end
    end

  end
end
