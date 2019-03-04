module Bosh::Director
  module DeploymentPlan
    class InstanceSpec
      def self.create_empty
        EmptyInstanceSpec.new
      end

      def self.create_from_database(spec, instance, variables_interpolator)
        new(spec, instance, variables_interpolator)
      end

      def self.create_from_instance_plan(instance_plan)
        instance = instance_plan.instance
        deployment_name = instance.deployment_model.name
        instance_group = instance_plan.desired_instance.instance_group
        powerdns_manager = PowerDnsManagerProvider.create

        spec = {
          'deployment' => deployment_name,
          'job' => instance_group.spec,
          'index' => instance.index,
          'bootstrap' => instance.bootstrap?,
          'lifecycle' => instance_group.lifecycle,
          'name' => instance.instance_group_name,
          'id' => instance.uuid,
          'az' => instance.availability_zone_name,
          'networks' => instance_plan.network_settings_hash,
          'vm_type' => instance_group.vm_type&.spec,
          'vm_resources' => instance_group.vm_resources&.spec,
          'stemcell' => instance_group.stemcell.spec,
          'env' => instance_group.env.spec,
          'packages' => instance_group.package_spec,
          'properties' => instance_group.properties,
          'properties_need_filtering' => true,
          'dns_domain_name' => powerdns_manager.root_domain,
          'address' => instance_plan.network_address,
          'update' => instance_group.update_spec
        }


        disk_spec = instance_group.persistent_disk_collection.generate_spec

        spec.merge!(disk_spec)

        new(spec, instance, instance_plan.variables_interpolator)
      end

      def initialize(full_spec, instance, variables_interpolator)
        @full_spec = full_spec
        @instance = instance
        @variables_interpolator = variables_interpolator
      end

      def as_template_spec(use_last_successful = false)
        TemplateSpec.new(full_spec, @variables_interpolator, @instance.desired_variable_set, @instance).spec(use_last_successful)
      end

      def as_apply_spec
        ApplySpec.new(full_spec).spec
      end

      def as_jobless_apply_spec
        spec = full_spec
        spec['job'] = {}

        ApplySpec.new(spec).spec
      end

      def full_spec
        # re-generate spec with rendered templates info
        # since job renderer sets it directly on instance
        spec = @full_spec

        if @instance.template_hashes
          spec['template_hashes'] = @instance.template_hashes
        end

        if @instance.rendered_templates_archive
          spec['rendered_templates_archive'] = @instance.rendered_templates_archive.spec
        end

        if @instance.configuration_hash
          spec['configuration_hash'] = @instance.configuration_hash
        end

        spec
      end
    end

    private

    class EmptyInstanceSpec < InstanceSpec
      def initialize
      end

      def full_spec
        {}
      end
    end

    class TemplateSpec
      def initialize(full_spec, variables_interpolator, variable_set, instance)
        @full_spec = full_spec
        @variables_interpolator = variables_interpolator
        @variable_set = variable_set
        @instance = instance
        links_serial_id = instance.deployment_model.links_serial_id
        @links_manager = Bosh::Director::Links::LinksManager.new(links_serial_id)
        @logger = Bosh::Director::Config.logger
      end

      def spec(use_last_successful = false)
        keys = [
          'deployment',
          'job',
          'index',
          'bootstrap',
          'name',
          'id',
          'az',
          'networks',
          'properties_need_filtering',
          'dns_domain_name',
          'persistent_disk',
          'address',
          'ip'
        ]

        whitelisted_link_spec_keys = [
          'address',
          'default_network',
          'deployment_name',
          'domain',
          'group_name',
          'instance_group',
          'instances',
          'properties',
          'use_link_dns_names',
          'use_short_dns_addresses',
        ]

        template_hash = @full_spec.select {|k,v| keys.include?(k) }

        instance_properties = @full_spec['properties']

        if @variables_interpolator.is_deploy_action
          template_hash['properties'] =  @variables_interpolator.interpolate_template_spec_properties(instance_properties, @full_spec['deployment'], @variable_set)
        else
          unless use_last_successful
            @logger.debug("===== re-rendering template with properties from instance model #{@instance.index} (#{@instance.instance_group_name}/#{@instance.model[:uuid]})")

            # Pull properties from intended source
            # TODO: why is this bad when we are doing the dynamic network re-render?
            # TODO: should we use @instance.model.spec instead of [:spec_json]?
            spec = @instance.model.spec
            instance_properties = spec['properties'] unless spec.nil?
            @logger.debug("===== properties used are: #{instance_properties.inspect}")

            template_hash['properties'] =  @variables_interpolator.interpolate_template_spec_properties(instance_properties, @full_spec['deployment'], @variable_set)
          else
            @logger.debug("===== re-rendering template with properties from last successful variable set  #{@instance.index} (#{@instance.instance_group_name}/#{@instance.model[:uuid]})")
            @logger.debug("===== properties (successful: #{JSON.parse(@instance.model[:spec_json])['properties']}) used are: #{instance_properties.inspect}")

            # On retry render as last successful node
            last_successful_variable_set = @instance.model.deployment.last_successful_variable_set
            template_hash['properties'] =  @variables_interpolator.interpolate_template_spec_properties(instance_properties, @full_spec['deployment'], last_successful_variable_set)
          end
        end

        template_hash['links'] = {}

        links_hash = @links_manager.get_links_for_instance(@instance)
        links_hash.each do |job_name, links|
          template_hash['links'][job_name] ||= {}
          # TODO: should we retry with the last_successful_varaible set here too?
          interpolated_links_spec = @variables_interpolator.interpolate_link_spec_properties(links, @variable_set)

          interpolated_links_spec.each do |link_name, link_spec|
            template_hash['links'][job_name][link_name] = link_spec.select {|k,v| whitelisted_link_spec_keys.include?(k) }
          end
        end

        networks_hash = template_hash['networks']

        ip = nil
        modified_networks_hash = networks_hash.each_pair do |network_name, network_settings|
          if @full_spec['job'] != nil
            settings_with_dns = network_settings.merge({'dns_record_name' => DnsNameGenerator.dns_record_name(@full_spec['index'], @full_spec['job']['name'], network_name, @full_spec['deployment'], @full_spec['dns_domain_name'])})
            networks_hash[network_name] = settings_with_dns
          end

          defaults = network_settings['default'] || []

          if defaults.include?('addressable') || (!ip && defaults.include?('gateway'))
            ip = network_settings['ip']
          end

          if network_settings['type'] == 'dynamic'
            # Templates may get rendered before we know dynamic IPs from the Agent.
            # Use valid IPs so that templates don't have to write conditionals around nil values.
            networks_hash[network_name]['ip'] ||= '127.0.0.1'
            networks_hash[network_name]['netmask'] ||= '127.0.0.1'
            networks_hash[network_name]['gateway'] ||= '127.0.0.1'
          end
        end

        template_hash.merge!({'resource_pool' => @full_spec['vm_type']['name']}) unless @full_spec['vm_type'].nil?
        template_hash.merge({
          'ip' => ip,
          'networks' => modified_networks_hash
        })
      end
    end

    class ApplySpec
      def initialize(full_spec)
        @full_spec = full_spec
      end

      def spec
        keys = [
          'deployment',
          'job',
          'index',
          'name',
          'id',
          'az',
          'networks',
          'packages',
          'dns_domain_name',
          'configuration_hash',
          'persistent_disk',
          'template_hashes',
          'rendered_templates_archive',
        ]
        @full_spec.select {|k,_| keys.include?(k) }
      end
    end
  end
end
