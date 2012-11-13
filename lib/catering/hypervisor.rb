module Catering

    class Hypervisor

        def initialize(options)
            @options = options

            case @options[:type]
            when 'vsphere'
                # requires the following keys in options:
                # :vsphere_host
                # :vsphere_user
                # :vsphere_pass
                # :vsphere_dc
                # :vm_folder
                # :datastore
                # :resource_pool
                #
                # optional settings are:
                # :insecure
                # :port
                # :use_ssl
                @options[:vsphere_path] ||= "/sdk"
                @options[:port] ||= 443
                @options[:use_ssl] ||= true

                self.extend Catering::Hypervisors::Vsphere
            else
                abort "Unsupported hypervisor type #{type}"
            end
        end

        def type
            @options[:type]
        end

        alias_method :inspect, :to_s
    end
end
