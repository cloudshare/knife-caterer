require 'rubygems'
require 'bundler/setup'
require 'celluloid'
require 'net/ping/tcp'
require 'timeout'
require 'ostruct'


class AsyncArray < Array
    include Celluloid
end


class Chef::Knife::Caterer::VirtualMachine

    attr_accessor :name

    def initialize(name, vm)
        @name = name
        @vm = vm
    end

    def powered_on?
        @vm.runtime.powerState
    end

    def ip
        @vm.guest.ipAddress if @vm.guest.ipAddress and @vm.guest.ipAddress.length > 0
    end
end


class Chef::Knife::Caterer::Network

    attr_accessor :name
    attr_accessor :dns
    attr_accessor :subnet
    attr_accessor :gateway
    attr_accessor :domain

    def initialize(name, hypervisor, dns, subnet, gateway, domain)
        @name, @hypervisor, @dns, @subnet, @gateway, @domain =
            name, hypervisor, dns, subnet, gateway, domain
    end

    def exists?
        # search for the VM in the hypervisor
        @hypervisor.network_exists?(@name)
    rescue Exception => e
        puts e.to_s
        puts e.backtrace
    end
end


class Chef::Knife::Caterer::Template

    attr_accessor :hypervisor
    attr_accessor :name
    attr_accessor :user
    attr_accessor :key
    attr_accessor :os

    def initialize(name, hypervisor, user, key, os)
        @name, @hypervisor, @user, @key, @os = name, hypervisor, user, key, os
    end

    def exists?
        # search for the VM in the hypervisor
        @hypervisor.template_exists?(@name)
    rescue Exception => e
        puts e.to_s
        puts e.backtrace
    end
end


class Chef::Knife::Caterer::Hypervisor

    attr_accessor :name
    attr_accessor :vm_folder
    attr_accessor :template_folder
    attr_accessor :datastore
    attr_accessor :resource_pool

    def initialize(name, host, type, options = {})
        @name = name
        @host = host
        @type = type

        case type
        when 'vsphere'
            @connection = Chef::Knife::BaseVsphereCommand.new
            @connection.get_vim_connection

            @vm_folder = options[:vm_folder]
            @template_folder = options[:template_folder]
            @datastore = options[:datastore]
            @resource_pool = options[:resource_pool]
        else
            abort "Unsupported hypervisor type #{type}"
        end
    end

    def vm_exists?(vm_name)
        f = @connection.find_folder(@vm_folder)
        @connection.find_in_folder(f, RbVmomi::VIM::VirtualMachine, vm_name) != nil
    end

    def find_vm(vm_name)
        f = @connection.find_folder(@vm_folder)

        vm = @connection.find_in_folder(f, RbVmomi::VIM::VirtualMachine, vm_name)
        if vm
           Chef::Knife::Caterer::VirtualMachine.new(vm_name, vm)
        end
    end

    def template_exists?(vm_name)
        f = @connection.find_folder(@template_folder)
        @connection.find_in_folder(f, RbVmomi::VIM::VirtualMachine, vm_name) != nil
    end

    def network_exists?(network)
        dc = @connection.get_config(:vsphere_dc)

        nil != @connection.config[:vim].serviceInstance.find_datacenter(dc).network.find do |vlan|
            vlan.name == network
        end
    end
end


class Chef::Knife::Caterer::Host
    include Celluloid

    class Machine
        include Celluloid::FSM

        default_state :waiting

        state :verify, :to => [:verified, :locate_vm] do
            # run acceptance tests to verify the host
            if actor.is_ready?
                actor.messages << "acceptance test passed"
                transition :verified

            else
                actor.messages << "no acceptance test provided, or test failed"
                transition :locate_vm
            end
        end

        state :locate_vm, :to => [:runtime_state, :provision] do
            # try to find the VM in the hypervisor
            if actor.vm_exists?
                actor.messages << "VM found"
                transition :runtime_state
            else
                actor.messages << "VM not found"
                transition :provision
            end
        end

        state :runtime_state, :to => [:powered_off, :networking_down, :check_connectivity] do
            # check the VM's runtime state (power and IP)
            if not actor.powered_on?
                actor.messages << "VM is powered off"
                transition :powered_off

            elsif not actor.ip
                actor.messages << "VM has no IP address"
                transition :networking_down

            else
                transition :check_connectivity
            end
        end

        state :check_connectivity, :to => [:running, :unreachable] do
            # check networking connectivity to the VM
            if actor.answers_ping?
                actor.messages << "VM responds to network ping"
                transition :running
            else
                actor.messages << "VM does not respond to network ping"
                transition :disconnected
            end
        end

        state :provision, :to => [:customizing, :prerequisites, :provisioning_failure] do
            # verify the prerequisites are met, and provision a new VM
            missing_networks = actor.networks.reject { |net| net.exists? }
            if not actor.template.exists? or missing_networks.size > 0
                actor.messages << "missing required template or network"
                transition :prerequisites

            elsif not actor.simulate and not actor.remove_client
                actor.messages << "failed to remove client from Chef server"
                transition :prerequisites

            elsif actor.simulate == :calc
                actor.messages << "needs to be provisioned"

            elsif not actor.provision
                actor.messages << "VM provisioning failed"
                transition :provisioning_failure

            else
                transition :customizing
            end
        end

        state :customizing, :to => [:verify_connectivity, :customization_timeout] do
            # wait for the customization to complete (power on & IP)
            actor.messages << "waiting for VM customization to complete"
            
            status = Timeout::timeout(5 * 60) do
                sleep 10 until actor.simulate or (actor.powered_on? and actor.ip)
                true
            end

            if status
                actor.messages << "VM customization complete"
                transition :verify_connectivity

            else
                actor.messages << "VM customization failed"
                transition :customization_timeout
            end
        end

        state :verify_connectivity, :to => [:bootstrap, :customization_failure] do
            # check networking connectivity to the VM
            if actor.simulate or actor.answers_ping?
                actor.messages << "VM responds to network ping"
                transition :bootstrap

            else
                actor.messages << "VM does not respond to network ping"
                transition :customization_failure
            end
        end

        state :bootstrap, :to => [:test, :bootstrapping_failure] do
            # Bootstrap the VM with chef-client
            if actor.simulate == :calc
                actor.messages << "requires bootstrapping"

            elsif not actor.bootstrap
                actor.messages << "bootstrapping failed"
                transition :bootstrapping_failure

            else
                actor.messages << "updating node run list"
                actor.update_node
                transition :test
            end
        end

        state :test, :to => [:verified, :acceptance_failed] do
            # run acceptance tests to verify the host
            begin
                status = Timeout::timeout(5 * 60) do
                    sleep 30 until [nil, true].include? actor.is_ready?
                    true
                end

            rescue Timeout::Error
                status = nil
            end

            if status
                actor.messages << "acceptance test passed"
                transition :verified

            else
                # verification failed
                actor.messages << "acceptance test failed"
                transition :acceptance_failed
            end
        end

        attr_accessor :success

        handle_failure = Proc.new do
            @success = false
        end

        handle_success = Proc.new do
            @success = true
        end

        # failure end states
        state :prerequisites, &handle_failure
        state :provisioning_failure, &handle_failure
        state :customization_timeout, &handle_failure
        state :customization_failure, &handle_failure
        state :bootstrapping_failure, &handle_failure
        state :powered_off, &handle_failure
        state :networking_down, &handle_failure
        state :disconnected, &handle_failure
        state :unreachable, &handle_failure
        state :acceptance_failed, &handle_failure

        # success end states
        state :running, &handle_success
        state :verified, &handle_success
    end


    attr_accessor :fqdn
    attr_accessor :networks
    attr_accessor :template
    attr_accessor :messages
    attr_accessor :simulate


    def initialize(actor, instance, env, domain, roles, networks, template,
                   cpu_count, memoryGB, address, accept_test, hypervisor, simulate)

        @env, @networks, @template, @cpu_count, @memoryGB, @address,
            @accept_test, @hypervisor, @simulate =
            env, networks, template, cpu_count, memoryGB, address,
            accept_test, hypervisor, simulate

        @machine = Machine.new

        @vm_name = "#{actor}#{instance}"
        @fqdn = "#{@vm_name}.#{domain}"

        @messages = AsyncArray.new

        @rest_client ||= Chef::REST.new(Chef::Config['chef_server_url'])

        @node = Chef::Node.new
        @node.name = @fqdn
        @node.chef_environment = @env

        run_list = []
        roles.each do |role|

            @node.run_list << Chef::RunList::RunListItem.new(role)
            run_list << role
        end
        @roles = "'#{run_list * ','}'"

        @@cloning_mutex ||= Mutex.new

    rescue Exception => e
        puts e.to_s
        puts e.backtrace
    end


    def state(&block)
        if block_given?
            yield @machine.state
        else
            @machine.state
        end
    end


    def success
        @machine.success
    end


    def vm_exists?
        @hypervisor.vm_exists?(@fqdn)

    rescue Exception => e
        puts e.to_s
        puts e.backtrace
    end


    def powered_on?
        vm = @hypervisor.find_vm(@fqdn)
        vm and vm.powered_on?

    rescue Exception => e
        puts e.to_s
        puts e.backtrace
    end


    def ip
        vm = @hypervisor.find_vm(@fqdn)
        vm.ip

    rescue Exception => e
        puts e.to_s
        puts e.backtrace
    end


    def answers_ping?
        service = @template.os != "windows" ? 22 : 3389

        if Chef::Config[:verbosity]
            @messages << "pinging #{ip}:#{service}"
        end

        pingable = Net::Ping::TCP.new(ip, service).ping?

        if !pingable
            @messages << "host is not responding to ping"
        end

        pingable

    rescue Exception => e
        puts e.to_s
        puts e.backtrace
    end


    def remove_client
        if not @simulate
            clients = @rest_client.get_rest('/clients')
            if clients.has_key?(@fqdn)
                @rest_client.delete_rest(clients[@fqdn])
            end

            !@rest_client.get_rest('/clients').has_key?(@fqdn)
        else
            true
        end
    end


    def update_node
        if not @simulate
            nodes = @rest_client.get_rest('/nodes')
            if nodes.has_key?(@fqdn)
                @messages << "updating run list: #{@node.run_list}"
                node = @rest_client.get_rest("/nodes/#{@fqdn}")
                node.run_list = @node.run_list
                @rest_client.put_rest("/nodes/#{@fqdn}", node)
            end
        end

    rescue Net::HTTPFatalError => hfe
        @messages << hfe.to_s
    end


    def provision
        cmd = [
            '/Users/leeor/.rvm/gems/ruby-1.9.3-p286/bin/knife',
            'vsphere',
            'vm',
            'clone',
            "#{@fqdn}",
            "--vsinsecure", "true",
            "--template", "#{@template.name}",
            "--ccpu", "#{@cpu_count}",
            "--cram", "#{@memoryGB}",
            "--cvlan", "#{@networks[0].name}",
            "--chostname", "#{@vm_name}",
            "--datastore", "#{@hypervisor.datastore}",
            "--dest-folder", "#{@hypervisor.vm_folder}",
            "--folder", "#{@hypervisor.template_folder}",
            "--resource-pool", "#{@hypervisor.resource_pool}",
            "--start", "true",
            "-VV"
        ]

        if @address != nil
            cmd += [
                "--cgw", "#{@networks[0].gateway}",
                "--cdomain", "#{@networks[0].domain}",
                "--cdnsips", "#{@networks[0].dns}",
                "--cips", "#{@address}/#{@networks[0].subnet.split('/')[1]}",
            ]
        end

        if Chef::Config.configuration.has_key? :config
            cmd += ["-c", "#{Chef::Config[:config]}"]
        end

        @messages << "running external command: #{cmd * ' '}\n"

        rd, wr = IO.pipe
        if @simulate
            provision_proc = Process.spawn '/bin/echo "Sleeping..." && /bin/sleep 10', :out => wr
        else
            provision_proc = Process.spawn(*cmd, :out => wr)
        end
        wr.close

        begin
            loop do
                @messages << rd.read_nonblock(1024)
            end

        rescue Errno::EAGAIN
            sleep 1
            retry

        rescue EOFError => e
            # the process completed
            Process.wait(provision_proc)
            $?.exitstatus == 0

        rescue Exception => e
            @messages << e.to_s
            @messages << e.backtrace
            false
        end

    rescue Exception => e
        puts e.to_s
        puts e.backtrace
    end


    def bootstrap(&block)
        template_dir = File.dirname(__FILE__)
        bootstrap_options = {
            :env => @env,
            :run_list => "#{@roles}",
            :use_sudo => @template.os == 'ubuntu',
            :bootstrap_version => "10.12.0",
            :template_file => "#{template_dir}/caterer_bootstrap.erb",
            :identity_file => "#{Chef::Config[:ssh_certificate_path]}/#{@template.key}"
        }

        if @address
            bootstrap_options[:address] = @address
        end

        bootstrapper = CatererBootstrapper.new(@fqdn, @template.user, bootstrap_options)
        bootstrapper.run do |output|
            @messages << output
        end

        true

    rescue Exception => e
        puts e.to_s
        puts e.backtrace
    end


    def prepare_test_args(context, args)
        if args.is_a? Hash
            # Hash
            args.each_pair do |key, value|
                args[key] = prepare_test_args(context, value)
            end
        elsif args.is_a? Array
            # Array
            args.collect do |arg|
                prepare_test_args(context, arg)
            end
        elsif args.is_a? String
            # String
            Erubis::Eruby.new(args).evaluate(context)
        else
            args
        end
    end


    def is_ready?

        if @accept_test and @accept_test.has_key?("tester")
            begin
                require "#{Chef::Config[:tests_path]}/#{@accept_test['tester']}.rb"

                if @accept_test.has_key?("args")
                    context = OpenStruct.new()

                    begin
                        # try to add the node (if it exists) to the arguments'
                        # context
                        context.node = @rest_client.get_rest("/nodes/#{@fqdn}")
                    rescue
                    end

                    tester_args = prepare_test_args(context, @accept_test['args'])
                    @messages << "running acceptance test, arguments: #{tester_args.inspect}"

                    send("test_#{@accept_test['tester']}", *tester_args, @simulate == :dryrun) and true
                else
                    send("test_#{@accept_test['tester']}", @simulate == :dryrun) and true
                end
            rescue Exception => e
                @messages << e.to_s
                @messages << e.backtrace
                false
            end
        else
            nil
        end

    rescue Exception => e
        puts e.to_s
        puts e.backtrace
        false
    end


    def runner
        @machine.transition :verify
    end


    def to_s
        "#{@fqdn}(@state=#{@machine.state})"
    end

    alias_method :inspect, :to_s
end
