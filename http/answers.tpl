KEYMAPOPTS="us us"
HOSTNAMEOPTS="-n blue-router"
DEVDOPTS=mdev

INTERFACESOPTS="auto lo
iface lo inet loopback

auto eth0
iface eth0 inet dhcp
    hostname blue-router

auto eth1
iface eth1 inet manual

auto eth2
iface eth2 inet manual

auto eth3
iface eth3 inet manual
"

DNSOPTS="1.1.1.1"
TIMEZONEOPTS="-z UTC"
PROXYOPTS=none
APKREPOSOPTS="-1 -c"
SSHDOPTS=openssh
USEROPTS="-a -u blue"

ROOTSSHKEY="${pub_key}"
# private key: 
# -----BEGIN OPENSSH PRIVATE KEY-----
# b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtZW
# QyNTUxOQAAACCAuSVPZ3hc67FmSjLRCdZU3Fi74byqkFHfNPzZWu6KkwAAAJAWKGFNFihh
# TQAAAAtzc2gtZWQyNTUxOQAAACCAuSVPZ3hc67FmSjLRCdZU3Fi74byqkFHfNPzZWu6Kkw
# AAAEDhdY7qNIEhh5s8rTotYQeFLaS2N/TLZpoFifWxUezYxIC5JU9neFzrsWZKMtEJ1lTc
# WLvhvKqQUd80/Nla7oqTAAAAC2JsdWUtcm91dGVyAQI=
# -----END OPENSSH PRIVATE KEY-----
DISKOPTS="-m sys /dev/sda"
NTPOPTS=none
LBUOPTS=none
APKCACHEOPTS=none
