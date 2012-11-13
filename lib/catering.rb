require 'catering/host'
require 'catering/bootstrap'
require 'catering/hypervisor'

Dir[File.join(File.dirname(__FILE__), "catering/hypervisors/*")].each do |f|
    require "catering/hypervisors/#{File.split(f)[-1].split('.')[0]}"
end
