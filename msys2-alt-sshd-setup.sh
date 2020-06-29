#!/bin/sh
(set -o igncr) 2>/dev/null && set -o igncr; # this comment is required
#
#  msys2-alt-sshd-setup.sh — configure sshd on MSYS2 on port 2222 and run it as a Windows service
#
#  This script is a fork of this gist:
#
#  https://gist.github.com/samhocevar/00eec26d9e9988d080ac
#
#  Gotchas:
#    — the log file will be /var/log/msys2_sshd.log
#    — if you get error “sshd: fatal: seteuid XXX : No such device or address”
#      in the logs, try “passwd -R” (with admin privileges)
#

set -e

#
# Configuration
#

PRIV_NAME="Privileged user for sshd"
UNPRIV_USER=sshd # DO NOT CHANGE; this username is hardcoded in the openssh code
UNPRIV_NAME="Privilege separation user for sshd"

SERVICE=msys2_sshd
SERVICE_DESC="MSYS2 sshd"
PORT=2222
ETC=/etc/ssh
PRIV_USER=sshd_server_msys2
EDITRIGHTS=/mingw64/bin/editrights
SSHD=/usr/bin/sshd.exe

if [ $(uname -o) = Cygwin ]; then
    SERVICE=cygwin_sshd
    SERVICE_DESC="Cygwin sshd"
    PORT=2223
    ETC=/etc
    PRIV_USER=sshd_server_cygwin
    EDITRIGHTS=editrights # Comes with cygwin base.
    SSHD=/usr/sbin/sshd.exe
fi

# This is needed because msys2 rewrites everything that looks like a path.
# So on msys2 we prepend an extra forward slash to windows options.
winopt() {
    _opt=$1
    [ $(uname -o) != Cygwin ] && _opt="/${_opt}"
    printf "$_opt"
}

while [ $# -gt 0 ]; do
    case "$1" in
        --port|-p)
            shift
            PORT=$1
            shift
            ;;
        *)
            printf "Usage: $0 [--port <PORT-NUM>]\n"
            exit
            ;;
    esac
done

EMPTY_DIR=/var/empty

mkdir -p "$EMPTY_DIR"
mkdir -p /var/log
touch /var/log/lastlog

#
# Make sure needed packages are installed.
#

if [ $(uname -o) != Cygwin ]; then
    pacman --noconfirm -Sy
    pacman --noconfirm -S --needed openssh cygrunsrv mingw-w64-x86_64-editrights

# Check that we have deps, or install them for Cygwin.
elif ! [ -x /usr/sbin/sshd ] || ! command -v cygrunsrv >/dev/null; then
    # This is my fork of apt-cyg that supports using curl instead of wget.
    # Windows comes with curl now.
    curl -LO https://raw.githubusercontent.com/rkitover/apt-cyg/master/apt-cyg

    # apt-cyg expects to be able to run itself via PATH.
    chmod +x ./apt-cyg
    export PATH=$PWD:$PATH

    bash ./apt-cyg update
    bash ./apt-cyg install openssh cygrunsrv
fi

SFTP_SERVER=/usr/sbin/sftp-server
[ -x /usr/lib/ssh/sftp-server ] && SFTP_SERVER=/usr/lib/ssh/sftp-server

#
# Check that stock sshd_config is installed, or write one.
#
if ! [ -f "$ETC/sshd_config" ]; then
    mkdir -p "$ETC"

    if [ -f /etc/defaults/etc/sshd_config ]; then
        cp /etc/defaults/etc/sshd_config "$ETC"
    else
        cat > "$ETC/sshd_config" <<EOF
Port $PORT
AuthorizedKeysFile      .ssh/authorized_keys
Subsystem       sftp    $SFTP_SERVER
EOF
    fi
fi

#
# Generate ssh host keys.
#

if [ ! -f "$ETC/ssh_host_rsa_key.pub" ]; then
    ssh-keygen -A
fi

#
# The privileged cyg_server user
#

# Some random password; this is only needed internally by cygrunsrv and
# is limited to 14 characters by Windows (lol)
# Use some chars from different classes to satisfy domain password requirements.
tmp_pass=$(
  set -- '[:lower:]' 2 '[:digit:]' 4 '~!@#$%&*()_+=' 5 '[:upper:]' 3
  while [ $# -gt 0 ]; do
    class=$1 count=$2
    shift; shift
    tr -dc "$class" < /dev/urandom | dd count="$count" bs=1 2>/dev/null
  done
)

# Delete user from previous versions of this script.
if net user sshd_server >/dev/null 2>&1; then
    net user sshd_server $(winopt /delete)
fi

# Create user
add="$(if ! net user "${PRIV_USER}" >/dev/null; then echo "$(winopt /add)"; fi)"
if ! net user "${PRIV_USER}" "${tmp_pass}" ${add} $(winopt /fullname):"${PRIV_NAME}" \
        $(winopt /homedir):"$(cygpath -w ${EMPTY_DIR})" $(winopt /yes); then
    echo "ERROR: Unable to create Windows user ${PRIV_USER}"
    exit 1
fi

# Add user to the Administrators group if necessary
admingroup=$(mkgroup -l | awk -F: '{if ($2 == "S-1-5-32-544") print $1;}')
if ! (net localgroup "${admingroup}" | grep -q '^'"${PRIV_USER}"'\>'); then
    if ! net localgroup "${admingroup}" "${PRIV_USER}" $(winopt /add); then
        echo "ERROR: Unable to add user ${PRIV_USER} to group ${admingroup}"
        exit 1
    fi
fi

# Infinite passwd expiry
wmic useraccount where name="'${PRIV_USER}'" set passwordexpires=false

# set required privileges
for flag in SeAssignPrimaryTokenPrivilege SeCreateTokenPrivilege \
  SeTcbPrivilege SeDenyRemoteInteractiveLogonRight SeServiceLogonRight; do
    if ! $EDITRIGHTS -a "${flag}" -u "${PRIV_USER}"; then
        echo "ERROR: Unable to give ${flag} rights to user ${PRIV_USER}"
        exit 1
    fi
done


#
# The unprivileged sshd user (for privilege separation)
#

add=$(if ! net user "${UNPRIV_USER}" >/dev/null; then echo "$(winopt /add)"; fi)
if ! net user "${UNPRIV_USER}" ${add} $(winopt /fullname):"${UNPRIV_NAME}" \
        $(winopt /homedir):"$(cygpath -w ${EMPTY_DIR})" $(winopt /active):no; then
    echo "ERROR: Unable to create Windows user ${PRIV_USER}"
    exit 1
fi


#
# Add or update /etc/passwd entries
#

touch /etc/passwd
for u in "${PRIV_USER}" "${UNPRIV_USER}"; do
    sed -i -e '/^'"${u}"':/d' /etc/passwd
    SED='/^'"${u}"':/s?^\(\([^:]*:\)\{5\}\).*?\1'"${EMPTY_DIR}"':/bin/false?p'
    mkpasswd -l -u "${u}" | sed -e 's/^[^:]*+//' | sed -ne "${SED}" \
             >> /etc/passwd
done
mkgroup.exe -l > /etc/group

#
# Set port to configured $PORT (2222 in msys2 and 2223 in cygwin by default) in
# sshd config.
#

if grep -qEi '^ *#? *Port( |$)' "$ETC/sshd_config"; then
    sed -i -E 's/^ *#? *Port( |$).*/Port '$PORT'/' "$ETC/sshd_config"
else
    printf '# Added by msys2-alt-sshd-setup.sh:\nPort '$PORT'\n' >> "$ETC/sshd_config"
fi

#
# Add firewall rule.
#
netsh advfirewall firewall delete rule name=$SERVICE 2>/dev/null || :

if ! netsh advfirewall firewall add rule name=$SERVICE dir=in action=allow protocol=TCP localport=$PORT; then
    echo "WARNING: unable to add firewall rule to open port $PORT"
fi

#
# Make sure key and authorized_keys exists.
#
mkdir -p "${USERPROFILE}/.ssh"
chmod 700 "${USERPROFILE}/.ssh"
mkdir -p ~/.ssh
chmod 700 ~/.ssh

# Create key if it does not exist.
# From: https://unix.stackexchange.com/a/135090/340856
key="${USERPROFILE}/.ssh/id_rsa"
(yes "" | ssh-keygen -t rsa -b 4096 -N "" -f "$key" >/dev/null 2>&1) || :
chmod 600 "$key"
# Make sure key windows permissions are correct.
# From: https://superuser.com/a/1329702/226829
key=$(cygpath -w "$key")
icacls "$key" $(winopt /c) $(winopt /t) $(winopt /Inheritance):d
icacls "$key" $(winopt /c) $(winopt /t) $(winopt /Grant) "$USERNAME":F
icacls "$key" $(winopt /c) $(winopt /t) $(winopt /Remove) Administrator "Authenticated Users" 'BUILTIN\Administrators' BUILTIN Everyone System Users

# Make sure existing public keys (or new one) are in authorized_keys.
touch ~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys

for pubkey in "${USERPROFILE}"/.ssh/id_*.pub; do
    if ! grep -q "$(cat "$pubkey")" ~/.ssh/authorized_keys; then
        cat "$pubkey" >> ~/.ssh/authorized_keys
    fi
done

# Add aliases to ssh config.
ssh_config=${USERPROFILE}/.ssh/config
touch "$ssh_config"
chmod 600 "$ssh_config"

if [ $(uname -o) != Cygwin ]; then
    for sys in MSYS MINGW64 MINGW32; do
        if ! grep -q "MSYSTEM=$sys" "$ssh_config"; then
            # For host alias, lowercase and rename 'msys' -> 'msys2'.
            host=$(echo "$sys" | tr 'A-Z' 'a-z')
            [ "$host" = msys ] && host=msys2

            cat >>"$ssh_config" <<EOF

Host $host
  HostName localhost
  Port $PORT
  RequestTTY yes
  RemoteCommand MSYSTEM=$sys exec bash -l
EOF
        fi
    done
else
    if ! grep -q cygwin "$ssh_config"; then
        cat >>"$ssh_config" <<EOF

Host cygwin
  HostName localhost
  Port $PORT
EOF
    fi
fi

# Make sure .bash_logout returns 0 or the terminal tab will not close immediately.
echo 'exit 0' >> ~/.bash_logout

#
# Finally, register service with cygrunsrv and start it
#

cygrunsrv -R $SERVICE 2>/dev/null || :
cygrunsrv -I $SERVICE -d "$SERVICE_DESC" -p \
          "$SSHD" -a "-D -e" -y tcpip -u "${PRIV_USER}" -w "${tmp_pass}"

# The SSH service should start automatically when Windows is rebooted.
if ! net start $SERVICE; then
    echo "ERROR: Unable to start $SERVICE service"
    exit 1
fi
