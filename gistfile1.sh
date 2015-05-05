#!/bin/sh

set -e

#
# Configuration
#

PRIV_USER=cyg_server
PRIV_NAME="Privileged server"
UNPRIV_USER=sshd
UNPRIV_NAME="User for sshd privsep"

EMPTY_DIR=/var/empty


#
# Check installation sanity
#

if ! /mingw64/bin/editrights -h >/dev/null; then
    echo "Missing 'editrights'. Try: pacman -S mingw-w64-x86_64-editrights."
    exit 1
fi

if ! cygrunsrv -v >/dev/null; then
    echo "Missing 'cygrunsrv'. Try: pacman -S cygrunsrv."
    exit 1
fi

if ! ssh-keygen -A; then
    echo "Missing 'ssh-keygen'. Try: pacman -S openssh."
    exit 1
fi


#
# The privileged cyg_server user
#

# Some random password; this is only needed internally by cygrunsrv and
# is limited to 14 characters by Windows (lol)
tmp_pass="$(tr -dc 'a-zA-Z0-9' < /dev/urandom | dd count=14 bs=1 2>/dev/null)"

# Create user
add="$(if ! net user "${PRIV_USER}" >/dev/null; then echo "//add"; fi)"
net user "${PRIV_USER}" "${tmp_pass}" ${add} //fullname:"${PRIV_NAME}" \
         //homedir:"$(cygpath -w ${EMPTY_DIR})" //yes

# Add user to the Administrators group if necessary
admingroup="$(mkgroup -l | awk -F: '{if ($2 == "S-1-5-32-544") print $1;}')"
if ! (net localgroup "${admingroup}" | grep -q '^'"${PRIV_USER}"'$'); then
    net localgroup "${admingroup}" "${PRIV_USER}" //add
fi

# Infinite passwd expiry
passwd -e "${PRIV_USER}"

# set required privileges
/mingw64/bin/editrights -a SeAssignPrimaryTokenPrivilege -u "${PRIV_USER}"
/mingw64/bin/editrights -a SeCreateTokenPrivilege -u "${PRIV_USER}"
/mingw64/bin/editrights -a SeTcbPrivilege -u "${PRIV_USER}"
/mingw64/bin/editrights -a SeDenyRemoteInteractiveLogonRight -u "${PRIV_USER}"
/mingw64/bin/editrights -a SeServiceLogonRight -u "${PRIV_USER}"


#
# The unprivileged sshd user (for privilege separation)
#

add="$(if ! net user "${UNPRIV_USER}" >/dev/null; then echo "//add"; fi)"
net user "${UNPRIV_USER}" ${add} //fullname:"${UNPRIV_NAME}" \
         //homedir:"$(cygpath -w ${EMPTY_DIR})" //active:no


#
# Add or update /etc/passwd entries
#

for u in "${PRIV_USER}" "${UNPRIV_USER}"; do
    sed -i -e '/^'"${u}"':/d' /etc/passwd
    SED='/^'"${u}"':/s?^\(\([^:]*:\)\{5\}\).*?\1'"${EMPTY_DIR}"':/bin/false?p'
    mkpasswd -l -u "${u}" | sed -e 's/^[^:]*+//' | sed -ne "${SED}" \
             >> /etc/passwd
done


#
# Finally, register service with cygrunsrv and start it
#

cygrunsrv -R sshd || true
cygrunsrv -I sshd -d "MSYS2 sshd" -p \
          /usr/bin/sshd -a -D -y tcpip -u "${PRIV_USER}" -w "${tmp_pass}"

# The SSH service should start automatically when Windows is rebooted. You can
# manually restart the service by running `net stop sshd` + `net start sshd`
net start sshd
