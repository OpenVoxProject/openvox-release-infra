#!/bin/bash

echo "Removing identifier: org.voxpupuli.openbolt..."
if /usr/sbin/pkgutil --files org.voxpupuli.openbolt >/dev/null 2>&1 ; then
  /usr/sbin/pkgutil --forget org.voxpupuli.openbolt
fi
echo "OK"

echo "Removing Files"
/bin/rm -Rf /opt/puppetlabs/bolt /opt/puppetlabs/bolt/bin /opt/puppetlabs/bolt/lib /opt/puppetlabs/bolt/include /opt/puppetlabs/bolt/share /opt/puppetlabs/bolt/share/man /opt/puppetlabs/bolt/lib/ruby /opt/puppetlabs/bolt/lib/ruby/3.2.0 /opt/puppetlabs/bolt/lib/ruby/3.2.0/rubygems /opt/puppetlabs/bolt/lib/ruby/3.2.0/rubygems/ssl_certs /opt/puppetlabs/bin
echo "OK"