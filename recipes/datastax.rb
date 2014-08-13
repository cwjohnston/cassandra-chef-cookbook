#
# Cookbook Name:: cassandra
# Recipe:: datastax
#
# Copyright 2011-2012, Michael S Klishin & Travis CI Development Team
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

# This recipe relies on a PPA package and is Ubuntu/Debian specific. Please
# keep this in mind.

include_recipe "cassandra::_datastax_repo"
include_recipe "java"

user node.cassandra.user do
  comment "Cassandra Server user"
  home    node.cassandra.installation_dir
  shell   "/bin/bash"
  action  :create
end

group node.cassandra.user do
  (m = []) << node.cassandra.user
  members m
  action :create
end

[node.cassandra.conf_dir, node.cassandra.data_root_dir, node.cassandra.log_dir, node.cassandra.commitlog_dir].each do |dir|
  directory dir do
    owner     node.cassandra.user
    group     node.cassandra.user
    recursive true
    action    :create
  end
end

case node.platform_family
when "debian"
  # DataStax Server Community Edition package will not install w/o this
  # one installed. MK.
  package "python-cql" do
    action :install
    only_if { node[:cassandra][:datastax_repo_uri] =~ /\/community/ }
  end

  # This is necessary because apt gets very confused by the fact that the
  # latest package available for cassandra is 2.x while you're trying to
  # install dsc12 which requests 1.2.x.
  if node.platform_family == "debian" then
    package node.cassandra.package_name do
      action :install
      version "#{node.cassandra.version}-#{node.cassandra.release}"
    end
  end
when "rhel"
  yum_package node.cassandra.package_name do
    version "#{node.cassandra.version}-#{node.cassandra.release}"
    allow_downgrade
  end
end

link '/etc/init.d/cassandra' do
  to '/etc/init.d/dse'
  only_if { ::File.exists?('/etc/init.d/dse') && !::File.exists?('/etc/init.d/cassandra') }
end

first_run_complete = ::File.join(node.cassandra.conf_dir, "first_run_complete.json")
seeds_set = { :seeds => { :are_set => false } }

if ::File.exists?(first_run_complete)
  require 'json'
  seeds_set = JSON.parse(::File.read(first_run_complete))
end

template ::File.join(node.cassandra.conf_dir, "cassandra.yaml") do
  cookbook node.cassandra.templates_cookbook
  source "cassandra.yaml.erb"
  owner node.cassandra.user
  group node.cassandra.user
  mode  0644
  if ::File.exists?(first_run_complete) && seeds_set["seeds"]["are_set"]
    notifies :nothing, "service[cassandra]", :delayed
  elsif ::File.exists?(first_run_complete) && !seeds_set["seeds"]["are_set"]
    notifies :restart, "service[cassandra]", :delayed
  else
    Chef::Log.warn "No action taken on conf file configuration"
  end
end

template ::File.join(node.cassandra.conf_dir, "cassandra-env.sh") do
  cookbook node.cassandra.templates_cookbook
  source "cassandra-env.sh.erb"
  owner node.cassandra.user
  group node.cassandra.user
  mode  0644
  if ::File.exists?(first_run_complete)
    notifies :restart, "service[cassandra]", :delayed
  end
end

template '/etc/dse/dse.yaml' do
  cookbook node.cassandra.templates_cookbook
  source 'dse.yaml.erb'
  only_if { node[:cassandra][:datastax_repo_uri] =~ /\/enterprise/ }
  if ::File.exists?(first_run_complete)
    notifies :restart, "service[cassandra]", :delayed
  end
end

service "cassandra" do
  supports :restart => true, :status => true
  service_name node.cassandra.service_name
  action [:enable, :start]
  only_if { ::File.exists?(first_run_complete) }
end

cassandra_running = execute "Is Cassandra running" do
  command "service cassandra status"
end

file "#{first_run_complete}" do
  if !cassandra_running
    content '{ "seeds": { "are_set": false } }'
  else
    content '{ "seeds": { "are_set": true } }'
  end
end
