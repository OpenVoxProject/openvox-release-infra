#!/bin/bash

echo "Unloading service org.voxpupuli.puppet..."
/bin/launchctl unload /Library/LaunchDaemons/org.voxpupuli.puppet.plist
echo "OK"
echo "Removing service file /Library/LaunchDaemons/org.voxpupuli.puppet.plist..."
/bin/rm /Library/LaunchDaemons/org.voxpupuli.puppet.plist
echo "OK"

echo "Removing identifier: org.voxpupuli.openvox-agent..."
if /usr/sbin/pkgutil --files org.voxpupuli.openvox-agent >/dev/null 2>&1 ; then
  /usr/sbin/pkgutil --forget org.voxpupuli.openvox-agent
fi
echo "OK"

echo "Removing Files"
/bin/rm -Rf /opt/puppetlabs /opt/puppetlabs/puppet /private/etc/puppetlabs /opt/puppetlabs/bin /var/log/puppetlabs /var/run/puppetlabs /opt/puppetlabs/puppet/bin /opt/puppetlabs/puppet/cache /opt/puppetlabs/puppet/public /private/etc/puppetlabs/puppet /opt/puppetlabs/puppet/share/locale /private/etc/puppetlabs/code /private/etc/puppetlabs/code/modules /opt/puppetlabs/puppet/modules /private/etc/puppetlabs/code/environments /private/etc/puppetlabs/code/environments/production /private/etc/puppetlabs/code/environments/production/manifests /private/etc/puppetlabs/code/environments/production/modules /private/etc/puppetlabs/code/environments/production/data /var/log/puppetlabs/puppet /opt/puppetlabs/facter/facts.d /opt/puppetlabs/puppet/vendor_modules
echo "OK"
