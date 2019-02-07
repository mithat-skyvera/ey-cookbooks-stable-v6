lock_db_version = node.engineyard.environment.components.find_all {|e| e['key'] == 'lock_db_version'}.first['value'] if node.engineyard.environment.lock_db_version?

lock_version_file = '/db/.lock_db_version'
db_running = %x{mysql -N -e "select 1;" 2> /dev/null}.strip == '1'

known_versions = {
  '5.7.24' => 'https://www.percona.com/downloads/Percona-Server-5.7/Percona-Server-5.7.24-27/binary/debian/bionic/x86_64/Percona-Server-5.7.24-27-rbd42700-bionic-x86_64-bundle.tar',
  '5.7.23' => 'https://www.percona.com/downloads/Percona-Server-5.7/Percona-Server-5.7.23-25/binary/debian/bionic/x86_64/Percona-Server-5.7.23-25-r7e2732e-bionic-x86_64-bundle.tar',
  '5.7.22' => 'https://www.percona.com/downloads/Percona-Server-5.7/Percona-Server-5.7.22-22/binary/debian/bionic/x86_64/Percona-Server-5.7.22-22-rf62d93c-bionic-x86_64-bundle.tar',
  '5.7.21' => 'https://www.percona.com/downloads/Percona-Server-5.7/Percona-Server-5.7.21-21/binary/debian/bionic/x86_64/Percona-Server-5.7.21-21-r2a37e4e-bionic-x86_64-bundle.tar'
}

# create or delete /db/.lock_db_version
if node.dna['instance_role'][/^(db|solo)/]
  execute "dropping lock version file" do
    command "echo $(mysql --version | grep -E -o 'Distrib [0-9]+\.[0-9]+\.[0-9]+' | awk '{print $NF}') > #{lock_version_file}"
    action :run
    only_if { lock_db_version and not File.exists?(lock_version_file) and db_running }
  end

  execute "remove lock version file" do
    command "rm #{lock_version_file}"
    only_if { not lock_db_version and File.exists?(lock_version_file) }
  end
end

# check if the version is valid
if File.exists?(lock_version_file)
  install_version  = %x{cat #{lock_version_file}}.strip
else
  install_version = node['mysql']['latest_version']
end
package_url = known_versions[install_version]

if package_url.nil?
  Chef::Log.info "Chef does not know about MySQL version #{install_version}"
  exit(1)
else
  Chef::Log.info "lock_db_version: #{lock_db_version}, Installing: #{install_version}"
end

# download the tar file from Percona
remote_file "/tmp/src/Percona-Server-#{install_version}.tar" do
  source package_url
end

directory "delete Percona src directory" do
  path "/tmp/src/Percona-Server-#{install_version}"
  action :delete
  recursive true
end

directory "create Percona src directory" do
  path "/tmp/src/Percona-Server-#{install_version}"
  action :create
end

execute "extract Percona" do
  command "tar xvf /tmp/src/Percona-Server-#{install_version}.tar -C /tmp/src/Percona-Server-#{install_version}"
end

# install the dependencies of the Percona packages
%w[debsums libaio1 libmecab2].each do |package|
  package package
end

package "libmysqlclient-dev"

if node['dna']['instance_role'][/db|solo/]
  directory "/etc/systemd/system/mysql.service.d" do
    owner "root"
    group "root"
    mode 0755
    recursive true
  end

  cookbook_file "/etc/systemd/system/mysql.service.d/override.conf" do
    source "mysql_override.conf"
    owner "root"
    group "root"
    mode 0644
    notifies :run, "execute[reload-systemd]", :immediately
  end

  packages = %w[percona-server-common percona-server-client percona-server-server]
else
  packages = %w[percona-server-common percona-server-client]
end

packages.each do |package|
  execute "install #{package}" do
    command %Q{
      installed=$(apt-cache policy #{package}-#{node['mysql']['short_version']} | grep "Installed: #{install_version}-")
      if [ -z $installed ]
      then
        echo 'Installing #{package}-#{node['mysql']['short_version']}'
        dpkg -i /tmp/src/Percona-Server-#{install_version}/#{package}*.deb
      else
        echo '#{package}-#{node['mysql']['short_version']} is already installed'
      fi
    }
    environment({"DEBIAN_FRONTEND" => "noninteractive"})
  end
end
