#!/bin/bash
# This script automates the NC classification and environment group setup for the VRO plugin provisioning workflow
# Run this as root on your master
# This script assumes it is being run on a freshly installed PE Master

# User configuration
echo Puppet Master Setup Script
echo --------------------------
echo This script expects to be run from puppet-vro-starter_content directory. If run from a different directory, the script will fail.
echo This script also assumes it is being run on a freshly installed master that is not using code manager.
echo --------------------------

CONTROL_REPO='https://github.com/puppetlabs/puppet-vro-starter_content.git'
ALTERNATE_ENVIRONMENT='dev'
AUTOSIGN_EXAMPLE_CLASS='autosign_example'
VRO_USER_CLASS='vro_plugin_user'
VRO_SSHD_CLASS='vro_plugin_sshd'
MASTER_HOSTNAME=$(puppet config print certname)
NOOP='true'

# Check to see that you are running as root
if [[ $EUID -ne 0 ]]; then
   >&2 echo 'ERROR: This script must be run as root!'
   exit 1
fi

# Check to see if script is being run on a puppet master
if [ ! -f /opt/puppetlabs/server/bin/puppetserver ]; then
  >&2 echo 'ERROR: puppetserver binary not found.'
  exit 1
fi

# Install modules to configure via Puppet code
DEPLOY_MODULEPATH='/opt/puppetlabs/puppet/modules'
puppet module install WhatsARanjit-node_manager --modulepath $DEPLOY_MODULEPATH
puppet module install pltraining-rbac --modulepath $DEPLOY_MODULEPATH

# Configure control repo and run Puppet
echo 'Configuring Code Manager and deploying code...'
puppet apply << MANIFEST
node_group { 'PE Master':
  ensure  => present,
  noop    => $NOOP,
  classes => {
    'pe::repo'                                         => {},
    'pe_repo::platform::el_7_x86_64'                   => {},
    'pe_repo::platform::windows_x86_64'                => {},
    'puppet_enterprise::profile::master::mcollective'  => {},
    'puppet_enterprise::profile::mcollective::peadmin' => {},
    'puppet_enterprise::profile::master'               => {
      'code_manager_auto_configure' => true,
      'r10k_remote'                 => '$CONTROL_REPO',
    },
  },
}
rbac_user { 'codedeployer':
  ensure       => present,
  noop         => $NOOP,
  name         => 'codedeployer',
  email        => 'codedeployer@example.com',
  display_name => 'Code Manager Service Account',
  password     => 'puppetlabs',
  roles        => [ 'Code Deployers' ],
}
MANIFEST
puppet agent -t

# Generate token and run Code Manager
echo 'puppetlabs' | /opt/puppetlabs/bin/puppet-access login codedeployer -l 0
/opt/puppetlabs/bin/puppet-code deploy --all -w

# Create an 'Autosign and vRO Plugin User' classification group to set up autosign example and vro-plugin-user
echo 'Creating the Autosign and vRO Plugin User and sshd config group'
puppet apply << MANIFEST
node_group { 'Autosign and vRO Plugin User':
  ensure  => present,
  noop    => $NOOP,
  rule    => [ 'and', [ '=', [ 'trusted', 'certname' ], '$MASTER_HOSTNAME' ] ],
  classes => {
    '$AUTOSIGN_EXAMPLE_CLASS' => {},
    '$VRO_USER_CLASS'         => {},
    '$VRO_SSHD_CLASS'         => {},
  },
}
node_group { 'Roles':
  ensure => present,
}
MANIFEST

# Make a role group for each role
for file in /etc/puppetlabs/code/environments/$ALTERNATE_ENVIRONMENT/site/role/manifests/*; do
  BASEFILENAME=$(basename "$file")
  ROLE_CLASS="role::${BASEFILENAME%.*}"
  echo "Creating the '$ROLE_CLASS' classification group"
  new_group=$(cat <<MANIFEST
  node_group { '$ROLE_CLASS':
    ensure  => present,
    noop    => $NOOP,
    parent  => 'Roles',
    rule    => [ 'and', [ '=', [ 'trusted', 'pp_role' ], '$ROLE_CLASS' ] ],
    classes => {
      '$ROLE_CLASS' => {},
    },
  }
MANIFEST
  )
  PP="${PP} ${new_group}"
done
puppet apply -e "$PP"

# Create alternate_environment environment group
# Update the 'Agent-specified environment' group so that pp_environment=agent-specified works as expected
echo "Creating the '$ALTERNATE_ENVIRONMENT' environment group"
puppet apply << MANIFEST
node_group { '$ALTERNATE_ENVIRONMENT environment':
  ensure               => present,
  noop                 => $NOOP,
  parent               => 'Production environment',
  rule                 => [ 'and', [ '=', [ 'trusted', 'extensions', 'pp_environment' ], '$ALTERNATE_ENVIRONMENT' ] ],
  override_environment => true,
  environment          => $ALTERNATE_ENVIRONMENT,
  classes              => {},
}
node_group { 'Agent-specified environment':
  ensure               => present,
  noop                 => $NOOP,
  parent               => 'Production environment',
  rule                 => [ 'and', [ '=', [ 'trusted', 'extensions', 'pp_environment' ], 'agent-specified' ] ],
  override_environment => true,
  environment          => $ALTERNATE_ENVIRONMENT,
  classes              => {},
}
MANIFEST

# Ensure that the puppet-strings gem is installed for role class summaries in Puppet component of vRA
/opt/puppetlabs/bin/puppet resource package puppet-strings provider=puppet_gem ensure=installed
