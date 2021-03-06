require 'chef'
require 'chef/knife'
require 'chef/knife/bootstrap'
require 'chef/knife/core/bootstrap_context'

require 'net/ssh'
require 'celluloid'

# The contents are based on 'https://gist.github.com/2903891'

module Catering

    class CatererBootstrapper
        class BootstrapError < StandardError
        end

        # Using knife's facilities to generate the ssh command to bootstrap our
        # machines. We don't use knife directly because it doesn't report bad
        # exit code from the remote ssh commands.
        #
        # params:
        # * name    - The name to register in chef as
        # * options - A Hash of options. Accepts the following options:
        #           - :run_list       => The run list.
        #           - :env            => Chef environment to use.
        #           - :template_file  => Knife bootstrap template file to use.
        def initialize(fqdn, user, options)
            Chef::Config[:environment] = options[:env]
            bootstrap_config = {
                :bootstrap_version => options[:bootstrap_version],
                :chef_node_name => fqdn
            }

            template = IO.read(options[:template_file]).chomp
            context = Chef::Knife::Core::BootstrapContext.new(bootstrap_config, options[:run_list], Chef::Config)

            @command = Erubis::Eruby.new(template).evaluate(context)
            @command = "sudo #{@command}" if options[:use_sudo]

            @host = options.has_key?(:address) ? options[:address] : fqdn
            @user = user
            @identity_file = options[:identity_file]
            @simulate = options[:simulate]
        end

        # A utility method that helps getting output code from ssh remote
        # command. Idea taken from stackoverflow.com.
        #
        # params:
        # * ssh     - Net::SSH object to use (see example below)
        #
        # You can optionally add a block that accepts data. The data is both stderr
        # and stdout, so you can add a block with 'print data' to see on the console
        # both stdout and error.
        #
        # The stdout and stderr are combined because some commands output
        # to stderror (like wget).
        #
        # Returns: data(stdout and err combined), exit_code, exit_signal(what is this?)
        #
        # Sample usage:
        #
        #     Net::SSH.start(server, Etc.getlogin) do |ssh|
        #       puts ssh_exec!(ssh, "true").inspect
        #       # => ["", "", 0, nil]
        #       puts ssh_exec!(ssh, "false").inspect  
        #       # => ["", "", 1, nil]
        #     end
        def ssh_exec!(ssh)
            output_data = ''
            exit_code = nil
            exit_signal = nil

            ssh.open_channel do |channel|
                channel.exec(@command) do |ch, success|
                    abort "FAILED: couldn't execute command (ssh.channel.exec)" unless success

                    channel.on_data do |_, data|
                        output_data += data
                        yield data if block_given?
                    end

                    channel.on_extended_data do |_, type, data|
                        output_data += data
                        yield data if block_given?
                    end

                    channel.on_request('exit-status') { |_, data| exit_code = data.read_long }

                    channel.on_request('exit-signal') { |_, data| exit_signal = data.read_long }
                end
            end

            ssh.loop
            [output_data, exit_code, exit_signal]
        end

        def run(&block)
            # use a future for this long IO operation so as not to block the
            # host from processing messages and status queries/updates
            future = Celluloid::Future.new do
                Net::SSH.start(@host, @user, :keys => [ @identity_file ], :user_known_hosts_file => [ '/dev/null' ], :paranoid => false) do |ssh|
                    output, exit_code =  ssh_exec!(ssh) { |data| yield data }

                    raise BootstrapError, "#{output}\nexit code: #{exit_code}" if exit_code != 0
                end if not @simulate
            end

            future.value
        end
    end
end
