require 'chef'
require 'chef/knife'
require 'chef/knife/bootstrap'
require 'chef/knife/core/bootstrap_context'

require 'net/ssh'

# The contents are based on 'https://gist.github.com/2903891'

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
        kb = Chef::Knife::Bootstrap.new
        Chef::Config[:environment]    = options[:env]
        kb.config[:run_list]          = options[:run_list]
        kb.config[:use_sudo]          = options[:use_sudo]
        kb.config[:bootstrap_version] = options[:bootstrap_version]
        kb.config[:template_file]     = options[:template_file]
        kb.config[:chef_node_name]    = fqdn
        @command = kb.ssh_command

        @host = options.has_key?(:address) ? options[:address] : fqdn
        @user = user
        @identity_file = options[:identity_file]
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
        output_data = ""
        exit_code = nil
        exit_signal = nil

        ssh.open_channel do |channel|
            channel.exec(@command) do |ch, success|
                unless success
                    abort "FAILED: couldn't execute command (ssh.channel.exec)"
                end

                channel.on_data do |ch, data|
                    output_data += data
                    if block_given?
                        yield data
                    end
                end

                channel.on_extended_data do |ch, type, data|
                    output_data += data
                    if block_given?
                        yield data
                    end
                end

                channel.on_request("exit-status") do |ch, data|
                    exit_code = data.read_long
                end

                channel.on_request("exit-signal") do |ch, data|
                    exit_signal = data.read_long
                end
            end
        end

        ssh.loop
        [output_data, exit_code, exit_signal]
    end

    def run(&block)
        Net::SSH.start(@host, @user, :keys => [@identity_file]) do |ssh|
            output, exit_code, signal =  ssh_exec!(ssh) do |data|
                yield data
            end

            if exit_code != 0
                raise BootstrapError, "#{output}\nexit code: #{exit_code}"
            end
        end
    end
end
