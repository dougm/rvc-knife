#
# Author:: Doug MacEachern <dougm@vmware.com>
# RVC Module Name:: knife
#
# Copyright (c) 2011 VMware, Inc.  All Rights Reserved.
# 
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
# 
# The above copyright notice and this permission notice shall be included in
# all copies or substantial portions of the Software.
# 
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
# THE SOFTWARE.

require 'chef/knife'
require 'chef/node'
require 'chef/search/query'

def chef_query query
  list = []

  Chef::Search::Query.new.search(:node, query) do |node|
    item = {}
    [:hostname, :fqdn, :ipaddress].each do |key|
      item[key] = node[key]
    end
    if node[:dmi] and node[:dmi][:system]
      item[:uuid] = node[:dmi][:system][:uuid]
    end
    list << item
  end

  list
end

def find_vm vmFolder, node
  if node[:uuid]
    vm = vmFolder.findByUuid(node[:uuid].downcase)
    return vm if vm
  end

  [:fqdn, :hostname].each do |name|
    vm = vmFolder.findByDnsName(node[name])
    return vm if vm
  end

  return vmFolder.findByIp(node[:ipaddress])
end

def find_node_name vm, uuid
  name = vm.summary.guest.hostName

  q = Chef::Search::Query.new
  queries = ["dmi_system_uuid:#{uuid}", "hostname:#{name}", "fqdn:#{name}", "hostname:#{name.upcase}"]
  queries.each do |query|
    q.search(:node, query) do |node|
      return node.name
    end
  end

  nil
end

def get_node_name vm
  uuid = vm.config.uuid.upcase

  @node_name_cache[uuid] ||= find_node_name vm, uuid
end

def knife_init
  unless @configured_chef
    Chef::Knife.new.configure_chef
    @node_name_cache = {}
    @configured_chef = true
  end
end

opts :mark do
  summary "Mark VMs using Chef search"
  arg :query, "Search node query", :type => :string
  opt :name, "mark name (defaults to query)", :short => 'n', :type => :string, :default => nil
end

def mark query, opts
  knife_init

  connections = $shell.session.get_mark('@') || $shell.connections.map { |c| c[1] }

  objs = []

  chef_query(query).each do |node|
    connections.each do |conn|
      dc = conn.serviceInstance.find_datacenter
      vmFolder = dc.vmFolder
      vm = find_vm(vmFolder, node)
      if vm
        #link this VirtualMachine object into the RVC virtual filesystem
        dc.rvc_link conn, dc.name
        vmFolder.rvc_link dc, vmFolder.name
        vm.rvc_link vmFolder, vm.name

        objs << vm
        break
      end
    end
  end

  name = opts[:name] || query.gsub(/[^\w]/, "_")

  CMD.mark.mark name, objs
  puts "created mark '#{name}' with #{objs.length} VMs"
end

opts :show do
  summary "knife node show for given VM"
  arg :vm, nil, :lookup => VIM::VirtualMachine
  opt :attribute, "Show only one attribute", :short => 'a', :type => :string, :default => nil, :multi => true
  opt :runlist, "Show only the run list", :short => 'r', :type => :boolean, :default => false
  opt :environment, "Show only the Chef environment", :short => 'E', :type => :boolean, :default => false
end

def show vm, opts
  knife_init
  node_name = get_node_name(vm)
  if node_name
    args = ["node", "show", node_name]
    if opts[:attribute]
      opts[:attribute].each do |val|
        args << "-a"
        args << val
      end
    end
    if opts[:runlist]
      args << "-r"
    end
    if opts[:environment]
      args << "-E"
    end
    Chef::Knife.run(args)
  else
    err "unable to find chef node for VM #{vm.name}"
  end
end
