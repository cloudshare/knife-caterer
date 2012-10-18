#!/usr/bin/env ruby

require 'rubygems'
require 'optparse'
require 'net/ping/tcp'
require 'resolv'
require 'thread'

version = ">= 0"
gem 'chef', version

require 'Chef'
require 'chef/rest'
require 'chef/knife'
require 'chef/knife/core/text_formatter'
require 'chef/knife/core/ui'

class UnsupportedAOMode < Exception
end

module ActiveObject

    def init_ao()

        if @mode != :fork and @mode != :thread and @mode != :direct
            raise UnsupportedAOMode.new()
        end

        @state = :init
        @rc = nil
        @input = nil
        @output = nil
        @thread = nil
        @subproc = nil
    end

    def delegate(options, &block)
        wait = options.has_key?(:wait) and options[:wait]
        if @mode == :fork
            async_fork(wait) { yield }
        elsif @mode == :thread
            async_thread(wait) { yield }
        elsif @mode == :direct
            yield
        else
            raise UnsupportedAOMode.new()
        end

        {:rc => @rc,
         :output => @output,
         :state => @state}
    end

    def set_rc(code)
        @rc = code
    end

    def send_message(msg)
        @input.write(msg) if @input != nil
    end

    private

    def async_fork(wait, &block)

        if @state == :init

            @state = :running
            @output, @input = IO.pipe

            pid = fork
            if pid
                @input.close
                th = Process.detach(pid)
                @thread = th
            else
                @output.close
                STDOUT.reopen(@input)
                STDERR.reopen(@input)
                yield
            end
        end

        if @state == :running
            if @thread and (wait ? @thread.join() : @thread.join(0))

                @rc = @thread.value.to_i if @thread.value.respond_to?(:to_i) and @rc == nil
                @thread = nil
                @state = :finished
            end
        end
    end

    def async_thread(wait, &block)

        if @state == :init

            @state = :running
            @output, @input = IO.pipe
            @thread = Thread.new { yield }
        end

        if @state == :running
            if @thread and (wait ? @thread.join() : @thread.join(0))

                @rc = @thread.value if @rc == nil
                @thread = nil
                @state = :finished
            end
        end
    end
end

class Task

    include ActiveObject

    def initialize(mode, options=nil, &block)
        @mode, @task = mode, block

        @options ||= Hash.new { |hash, key| hash[key] = nil }
        @options.merge!(options) if options

        self.init_ao()
    end

    def run(options={})
        if @options[:init] and !@options[:init_called]
            @options[:init].call(@options[:kwargs])
            @options[:init_called] = true
        end

        self.delegate(options) { @task.call(self, @options[:kwargs]) }
    end

    def reset()
        self.init_ao()
        @options[:init_called] = false
    end
end

class BaseVIMObject

    def initialize()

        @@cache = { :vm_list => Hash.new { |hash, key| hash[key] = {} } }
    end

    def get_base_command()
        bc = Chef::Knife::BaseVsphereCommand.new
        bc.get_vim_connection

        bc
    end

    def get_network_list()

        if !@@cache.has_key?(:network_list)
            bc = get_base_command()
            dc = bc.get_config(:vsphere_dc)

            @@cache[:network_list] = bc.config[:vim].serviceInstance.find_datacenter(dc).network
        end

        @@cache[:network_list]
    end

    def get_vm_list(folder)

        folder_sym = folder.length == 0 ? :root : folder.to_sym

        if !@@cache.has_key?(:vm_list) or !@@cache[:vm_list].has_key?(folder_sym)

            bc = get_base_command()
            vc_folder = bc.find_folder(folder)

            @@cache[:vm_list][folder_sym] = bc.find_all_in_folder(vc_folder, RbVmomi::VIM::VirtualMachine)
        end

        @@cache[:vm_list][folder_sym]
    end
end

class Network < BaseVIMObject

    attr_accessor :name
    attr_accessor :dns
    attr_accessor :subnet
    attr_accessor :gateway
    attr_accessor :domain

    def initialize(name, dns, subnet, gateway, domain)
        super()
        @name, @dns, @subnet, @gateway, @domain = name, dns, subnet, gateway, domain

        @exists = nil
    end

    def exists?()

        if @exists == nil
            # search for the VM in the VC
            @exists = get_network_list().find do |vlan|
                vlan.name == @name
            end

            if !@exists
                puts "network #{@name} not found in VC"
            end
        end

        @exists
    rescue Exception => e
        puts e.to_s
        puts e.backtrace
        false
    end
end

class Template < BaseVIMObject

    attr_accessor :vc
    attr_accessor :name
    attr_accessor :user
    attr_accessor :key
    attr_accessor :os

    def initialize(name, vc, user, key, os, folder)
        super()
        @name, @vc, @user, @key, @os, @folder = name, vc, user, key, os, folder

        @exists = nil
    end

    def exists?()
        if @exists == nil
            # search for the VM in the VC
            @exists = get_vm_list(@folder).find do |vm|
                vm.name == @name
            end

            if !@exists
                puts "template #{@name} not found in VC"
            end
        end

        @exists != nil
    rescue Exception => e
        puts e.to_s
        puts e.backtrace
        false
    end
end

class Host < BaseVIMObject

    attr_accessor :fqdn
    attr_accessor :actor

    def initialize(actor, instance, env, domain, roles, networks, template, cpu_count, memoryGB, address, folder, resource_pool)
        super()
        @actor, @instance, @env, @domain, @networks, @template, @cpu_count, @memoryGB, @address, @folder, @resource_pool =
            actor, instance, env, domain, networks, template, cpu_count, memoryGB, address, folder, resource_pool

        @name = @actor + @instance.to_s
        @vm_name = "#{@name}-#{@env}"
        @fqdn = "#{@vm_name}.#{@domain}"
        @vm_exists = nil
        @node_exists = nil
        @ip = nil
        @pingable = nil

        @node = Chef::Node.new
        @node.name = @fqdn
        @node.chef_environment = @env

        role_list = []
        roles.each do |role|

            @node.run_list << Chef::RunList::RunListItem.new("role[#{role}]")
            role_list << "role[#{role}]"
        end
        @roles = "'#{role_list * ','}'"

        @@cloning_mutex ||= Mutex.new()
    end

    def vm_exists?(&block)
        if @vm_exists == nil
            # search for the VM in the VC
            @vm_exists = get_vm_list(@folder).find do |vm|
                vm.name == @vm_name
            end

            if !@vm_exists
                yield :msg => "VM #{@vm_name} not found in VC"
            end
        end

        @vm_exists != nil
    rescue Exception => e
        puts e.to_s
        puts e.backtrace
        false
    end

    def node_exists?(&block)
        if @node_exists == nil
            # search for the node in the chef server
            nodes = $rest_client.get_rest('/nodes')
            if nodes.has_key?(@fqdn)
                @node_exists = true
            else
                yield :msg => "Node #{@fqdn} not found in Chef server"
            end
        end

        @node_exists != nil
    rescue Exception => e
        puts e.to_s
        puts e.backtrace
        false
    end

    def node_resolvable?(&block)
        # Resolve the FQDN
        if @ip == nil
            begin
                # try to get the machine's IP address
                node = $rest_client.get_rest("/nodes/#{fqdn}")
                interfaces = node.automatic_attrs['network']['interfaces']
                default_if = interfaces[node.automatic_attrs['network']['default_interface']]
                addresses = default_if['addresses'].keys
                @ip = addresses.find do |address|
                    default_if['addresses'][address]['family'] == 'inet'
                end

            rescue
                yield :msg => "Failed to resolve node #{@fqdn}"
                false
            end
        end

        @ip != nil
    end

    def answers_ping?(&block)
        # Ping will do a TCP based echo to port 7. The machine doesn't have to
        # actually listen on that port, as actively rejecting the connection
        # attempt is good enough to mean that the host is up.
        if !@pingable
            service = @template.os != "windows" ? 22 : 3389

            if $options[:verbose]
                yield :msg => "#{@fqdn}: pinging #{@address}:#{service}"
            end

            @pingable = Net::Ping::TCP.new(@address, service).ping?

            if !@pingable
                yield :msg => "#{@fqdn}: host is not responding to ping"
            end
        end

        @pingable != nil and @pingable != false
    rescue
        puts e.to_s
    end

    def wait_for_ping(&block)
        if $options[:dryrun]
            count = 5
            while count > 0
                count -= 1
                sleep 5
            end
        else
            while not answers_ping?(&block)
                sleep 10
            end
        end

        true
    end

    def dns_resolvable?(&block)
        # Resolve the FQDN
        if @ip == nil
            begin
                @ip = Resolv.getaddress(@fqdn)
            rescue Resolv::ResolvError => re
                yield :msg => "Failed to resolve host name #{@fqdn}"
                false
            end
        end

        @ip != nil
    end

    def remove_client(&block)
        if $options[:dryrun] != true
            clients = $rest_client.get_rest('/clients')
            if clients.has_key?(@fqdn)
                $rest_client.delete_rest(clients[@fqdn])
            end

            !$rest_client.get_rest('/clients').has_key?(@fqdn)
        else
            true
        end
    end

    def update_node(&block)
        if $options[:dryrun] != true
            nodes = $rest_client.get_rest('/nodes')
            if !nodes.has_key?(@fqdn)
                yield :msg => "creating node #{@fqdn}: #{@node.inspect}"
                $rest_client.post_rest('/nodes', @node)
            else
                yield :msg => "updating node #{@fqdn} run list: #{@node.run_list}"
                node = $rest_client.get_rest("/nodes/#{@fqdn}")
                node.run_list= @node.run_list
                $rest_client.put_rest("/nodes/#{@fqdn}", node)
            end

            $rest_client.get_rest('/nodes').has_key?(@fqdn)
        else
            true
        end
    rescue Net::HTTPFatalError => hfe
        yield :msg => hfe.to_s
        false
    end

    def provision(&block)

        cmd = [
            '/usr/bin/knife',
            'vsphere',
            'vm',
            'clone',
            "#{@vm_name}",
            "-c", "#{$options[:config_file]}",
            "--vsinsecure", "true",
            "--template", "#{@template.name}",
            "--ccpu", "#{@cpu_count}",
            "--cram", "#{@memoryGB}",
            "--cvlan", "#{@networks[0].name}",
            "--cgw", "#{@networks[0].gateway}",
            "--cdomain", "#{@networks[0].domain}",
            "--cdnsips", "#{@networks[0].dns}",
            "--cips", "#{@address}/#{@networks[0].subnet.split('/')[1]}",
            "--chostname", "#{@vm_name}",
            "--dest-folder", "#{@folder}",
            "--resource-pool", "#{@resource_pool}",
            "--start", "true",
            "-VV"
        ]

        @provisioning_ao = Task.new(:fork, options={:kwargs => {:cmd => cmd}}) do |task, kwargs|

            if $options[:dryrun] != true
                Process.exec(*kwargs[:cmd])
            else
                Process.exec('./test.sh', '10')
            end
        end

        provisioning_status = {}
        @@cloning_mutex.synchronize do
            yield :msg => "running external command: #{cmd * ' '}\n"

            while !provisioning_status.has_key?(:state) or provisioning_status[:state] != :finished
                provisioning_status = @provisioning_ao.run()

                begin
                    yield :msg => provisioning_status[:output].read_nonblock(1024)
                rescue IOError => e
                rescue EOFError => e
                rescue Errno::EAGAIN => e
                end

                sleep 1
            end
        end

        provisioning_status[:rc] == 0
    rescue Exception => e
        puts e.to_s
        puts e.backtrace
        false
    end

    def bootstrap(&block)

        cmd = [
            '/usr/bin/knife',
            'bootstrap',
            "#{@address}",
            "-c", "#{$options[:config_file]}",
            "--bootstrap-version", "10.12.0",
            "-x", "#{@template.user}",
            "-i", "#{@template.key}",
            "--environment", "#{@env}",
            "--run-list", "#{@roles}",
            "-VV"
        ]

        if @template.os == 'ubuntu'
            cmd << "--sudo"
        end

        # TODO read the key itself from the template, not a file name

        yield :msg => "running external command: #{cmd * ' '}\n"

        if $options[:dryrun] != true
            Process.exec(*cmd)
        else
            Process.exec('./test.sh', '10')
        end
    rescue Exception => e
        puts e.to_s
        puts e.backtrace
        false
    end

    def run

        @states ||= {
            :start => {
                :task => Task.new(:thread) do |task, kwargs|
                    self.node_exists? do |dict|
                        task.set_rc(dict[:rc]) if dict[:rc] != nil
                        task.send_message(dict[:msg]) if dict[:msg] != nil
                    end
                end,
                :next => {
                    true => {:state => :resolve_node, :msg => "Node found" },
                    false => {:state => :verify_template, :msg => "Node not found" }
                }
            },
            :resolve_node => {
                :task => Task.new(:thread) do |task, kwargs|
                    self.node_resolvable? do |dict|
                        task.set_rc(dict[:rc]) if dict[:rc] != nil
                        task.send_message(dict[:msg]) if dict[:msg] != nil
                    end
                end,
                :next => {
                    true => {:state => :ping, :msg => "IP address resolved" },
                    false => {:state => :verify_template, :msg => "IP address not resolved" }
                }
            },
            :ping => {
                :task => Task.new(:thread) do |task, kwargs|
                    self.answers_ping? do |dict|
                        task.set_rc(dict[:rc]) if dict[:rc] != nil
                        task.send_message(dict[:msg]) if dict[:msg] != nil
                    end
                end,
                :next => {
                    true => {:state => :update_node, :msg => "Host is up & running" },
                    false => {:state => :vm_exists, :msg => "VM exists but is not responding" }
                }
            },
            :vm_exists => {
                :task => Task.new(:thread) do |task, kwargs|
                    self.vm_exists? do |dict|
                        task.set_rc(dict[:rc]) if dict[:rc] != nil
                        task.send_message(dict[:msg]) if dict[:msg] != nil
                    end
                end,
                :next => {
                    true => {:state => :delete, :msg => "Host exists, but is not respondind" },
                    false => {:state => :verify_template, :msg => "VM does not exist" }
                }
            },
            :verify_template => {
                :task => Task.new(:thread) do |task, kwargs|
                    @template.exists? do |dict|
                        task.set_rc(dict[:rc]) if dict[:rc] != nil
                        task.send_message(dict[:msg]) if dict[:msg] != nil
                    end
                end,
                :next => {
                    true => {:state => :verify_networks, :msg => "template exists" },
                    false => {:state => :error, :msg => "required template does not exist" }
                }
            },
            :verify_networks => {
                :task => Task.new(:thread) do |task, kwargs|
                    @networks.reject do |net|
                        net.exists? do |dict|
                            task.set_rc(dict[:rc]) if dict[:rc] != nil
                            task.send_message(dict[:msg]) if dict[:msg] != nil
                        end
                    end.length == 0
                end,
                :next => {
                    true => {:state => :remove_chef_client, :msg => "networks exist" },
                    false => {:state => :error, :msg => "required network does not exist" }
                }
            },
            :remove_chef_client => {
                :task => Task.new(:thread) do |task, kwargs|
                    self.remove_client do |dict|
                        task.set_rc(dict[:rc]) if dict[:rc] != nil
                        task.send_message(dict[:msg]) if dict[:msg] != nil
                    end
                end,
                :next => {
                    true => {:state => :provision, :msg => "" },
                    false => {:state => :error, :msg => "" }
                }
            },
            :provision => {
                :task => Task.new(:thread) do |task, kwargs|
                    self.provision do |dict|
                        task.set_rc(dict[:rc]) if dict[:rc] != nil
                        task.send_message(dict[:msg]) if dict[:msg] != nil
                    end
                end,
                :next => {
                    true => {:state => :ready_for_bootstrap, :msg => "VM provisioned" },
                    false => {:state => :error, :msg => "Provisioning failed" }
                }
            },
            :ready_for_bootstrap => {
                :task => Task.new(:thread) do |task, kwargs|
                    self.wait_for_ping do |dict|
                        task.set_rc(dict[:rc]) if dict[:rc] != nil
                        task.send_message(dict[:msg]) if dict[:msg] != nil
                    end
                end,
                :next => {
                    true => {:state => :bootstrap, :msg => "Host is up & running" },
                    false => {:state => :ready_for_bootstrap, :msg => "VM does not respond to network ping" }
                }
            },
            :bootstrap => {
                :task => Task.new(:fork) do |task, kwargs|
                    self.bootstrap do |dict|
                        task.set_rc(dict[:rc]) if dict[:rc] != nil
                        task.send_message(dict[:msg]) if dict[:msg] != nil
                    end
                end,
                :next => {
                    0 => {:state => :update_node, :msg => "VM bootstrapped" },
                    1 => {:state => :error, :msg => "Bootstrapping failed" }
                }
            },
            :update_node => {
                :task => Task.new(:thread) do |task, kwargs|
                    self.update_node do |dict|
                        task.set_rc(dict[:rc]) if dict[:rc] != nil
                        task.send_message(dict[:msg]) if dict[:msg] != nil
                    end
                end,
                :next => {
                    true => {:state => :done, :msg => "VM provisioning complete" },
                    false => {:state => :error, :msg => "Node update failed" }
                }
            }
        }

        @state ||= :start
        @status ||= ""
        progressed = false

        while @states.has_key?(@state)
            status = @states[@state][:task].run()

            begin
                output = status[:output].read_nonblock(1024)
                if $options[:verbose]
                    puts output
                end

            rescue IOError => e
            rescue EOFError => e
            rescue Errno::EAGAIN => e
            end

            if status[:rc] != nil
                if $options[:verbose]
                    puts "#{@fqdn}: state #{@state} finished with code #{status[:rc]}"
                end

                @states[@state][:task].reset()

                if @states[@state][:next].has_key?(status[:rc])
                    @status = @states[@state][:next][status[:rc]][:msg]
                    @state = @states[@state][:next][status[:rc]][:state]
                else
                    @status = "Error!"
                    @state = :error
                end

                progressed = true
            else
                # still being processed
                break
            end
        end

        [@states.has_key?(@state), progressed, @status]
    end

    def to_s()
        "#{@vm_name}(@state=#{@state})"#, @status=\"#{@status}\')"
    end
end

class Caterer

    def initialize()

        @actors = Hash.new { |hash, key| hash[key] = [] }
        @tasks = Hash.new { |hash, key| hash[key] = [] }
        @templates = {}
        @networks = {}

        @ui = Chef::Knife::UI.new($stdout, $stderr, $stdin, Chef::Config)

        db = Chef::DataBag.load("#{$options[:environment]}/#{$options[:composition]}")

        @vc = db["vc"]

        db["networks"].each_pair do |network, props|

            @networks[network.to_sym] = Network.new(props['vlan'],
                                                    props['dns'],
                                                    props['subnet'],
                                                    props['gateway'],
                                                    props['domain'])
        end

        db["templates"].each_pair do |template, props|

            @templates[template.to_sym] = Template.new(props['name'],
                                                       props['vc'],
                                                       props['user'],
                                                       props['key'],
                                                       props['os'],
                                                       @vc[props['vc']]['template-folder'])
        end

        db["actors"].each_pair do |actor, props|

            if props['instances'] == props['addresses'].size

                props["instances"].times do |instance|

                    host = Host.new(actor,
                                    instance + 1, 
                                    $options[:environment],
                                    @networks[props["networks"][0].to_sym].domain,
                                    props["roles"],
                                    props["networks"].collect {|net| @networks[net.to_sym]},
                                    @templates[props["template"].to_sym],
                                    props["cpus"],
                                    props["memoryGB"],
                                    props["addresses"][instance],
                                    @vc[@templates[props["template"].to_sym].vc]['vm-folder'],
                                    @vc[@templates[props["template"].to_sym].vc]['resource-pool'])

                    @actors[actor] << host
                end
            else
                puts "Actor #{actor} instances number differs from the number of provided addresses"
            end
        end
    end

    def run()
        repeat = true

        while repeat
            repeat = false
            progress_made = false

            @actors.each_pair do |name, hosts|

                hosts.each do |host|

                    host_in_progress, host_made_progress, status = host.run()

                    repeat ||= host_in_progress
                    progress_made ||= host_made_progress
                end
            end

            if repeat
                if !progress_made
                    sleep(1)
                else
                    puts Chef::Knife::Core::TextFormatter.new(@actors, @ui).formatted_data #if $options[:verbose]
                end
            end
        end

        puts Chef::Knife::Core::TextFormatter.new(@actors, @ui).formatted_data
    end
end

$options = {}

begin
    parser = OptionParser.new do |opts|
        opts.banner = 'Usage: caterer.rb [options]'

        opts.on('-c', '--config [FILE]', 'Configuration file') do |c|
            $options[:config_file] = c
        end

        opts.on('-e', '--environment [ENVIRONMENT]', 'Environment name') do |e|
            $options[:environment] = e
        end

        opts.on('-d', '--description [DESCRIPTION]', 'Environment composition') do |d|
            $options[:composition] = d
        end

        opts.on('-n', '--dry-run', 'Calculate and report only, take no action') do |d|
            $options[:dryrun] = d
        end

        opts.on('-v', '--verbose', 'Be verbose') do |v|
            $options[:verbose] = v
        end
    end.parse!(ARGV)
rescue OptionParser::InvalidOption => e
    puts e.to_s
end

Chef::Config.from_file($options[:config_file])

# load all knife sub-commands
Chef::Knife.load_commands()

exit 1 unless $rest_client = Chef::REST.new(Chef::Config['chef_server_url'])

Caterer.new().run()
