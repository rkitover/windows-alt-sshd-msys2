#!/bin/sh
(set -o igncr) 2>/dev/null && set -o igncr; # this comment is required
#
#  msys2-alt-sshd-setup.sh — configure sshd on MSYS2 on port 2222 or 2223 on
#  Cygwin and run it as a Windows service
#
#  This script is a fork of this gist:
#
#  https://gist.github.com/samhocevar/00eec26d9e9988d080ac
#
#  Gotchas:
#    — the log file will be /var/log/msys2_sshd.log
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
RUNTIME_VAR=MSYS

if [ $(uname -o) = Cygwin ]; then
    SERVICE=cygwin_sshd
    SERVICE_DESC="Cygwin sshd"
    PORT=2223
    ETC=/etc
    PRIV_USER=sshd_server_cygwin
    EDITRIGHTS=editrights # Comes with cygwin base.
    SSHD=/usr/sbin/sshd.exe
    RUNTIME_VAR=CYGWIN
fi

pwsh=/c/'Program Files'/powershell/7/pwsh.exe

if ! [ -f "$pwsh" ]; then
    pwsh=powershell
fi

pwsh_args="-executionpolicy remotesigned -noprofile"

pacman="pacman --noconfirm"

main() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --port|-p)
                shift
                PORT=$1
                shift
                ;;
            --uninstall|-u)
                shift
                uninstall 0
                ;;
            *)
                echo >&2 "Usage: $0 [--port <PORT-NUM>]"
                exit
                ;;
        esac
    done

    install
}

# This is needed because msys2 rewrites everything that looks like a path.
# So on msys2 we prepend an extra forward slash to windows options.
winopt() {
    _opt=$1
    [ $(uname -o) != Cygwin ] && _opt="/$_opt"
    printf "$_opt"
}

get_apt_cyg() {
    # This is my fork of apt-cyg that supports using curl instead of wget.
    # Windows comes with curl now.
    mkdir -p /tmp/apt-cyg
    curl -L https://raw.githubusercontent.com/rkitover/apt-cyg/master/apt-cyg -o "$(cygpath -w /tmp/apt-cyg/apt-cyg)"

    # apt-cyg expects to be able to run itself via PATH.
    chmod +x /tmp/apt-cyg/apt-cyg
    export PATH=/tmp/apt-cyg:$PATH
    apt_cyg="bash /tmp/apt-cyg/apt-cyg"
}

remove_apt_cyg() {
    rm -rf /tmp/apt-cyg
}

pacman_disable_gpg() {
    sed '/\[options\]/a \
SigLevel = Never TrustAll
/SigLevel/d' /etc/pacman.conf > /tmp/pacman.conf
    pacman="$pacman --config /tmp/pacman.conf"
}

pacman_cleanup() {
    rm -f /tmp/pacman.conf
}

install() {
    trap 'uninstall 1' ERR

    EMPTY_DIR=/var/empty

    mkdir -p "$EMPTY_DIR"
    mkdir -p /var/log
    touch /var/log/lastlog

    #
    # Make sure needed packages are installed.
    #
    if [ $(uname -o) != Cygwin ]; then
        pacman_disable_gpg
        $pacman -Sy
        $pacman -S --needed openssh cygrunsrv mingw-w64-x86_64-editrights
        pacman_cleanup

    # Check that we have deps, or install them for Cygwin.
    elif ! [ -x /usr/sbin/sshd ] || ! command -v cygrunsrv >/dev/null; then
        get_apt_cyg
        $apt_cyg update
        $apt_cyg remove openssh cygrunsrv
        $apt_cyg install openssh cygrunsrv
        remove_apt_cyg
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

    # Delete users from previous versions of this script.
    delete_users

    # Create user
    add="$(if ! net user "{PRIV_USER" >/dev/null 2>&1; then echo "$(winopt /add)"; fi)"
    if ! net user "$PRIV_USER" "$tmp_pass" $add $(winopt /fullname):"$PRIV_NAME" \
            $(winopt /homedir):"$(cygpath -w $EMPTY_DIR)" $(winopt /yes); then
        echo >&2 "ERROR: Unable to create Windows user $PRIV_USER"
        uninstall 1
    fi

    # Add user to the Administrators group if necessary
    admingroup=$(mkgroup -l | awk -F: '{if ($2 == "S-1-5-32-544") print $1;}')
    if ! (net localgroup "$admingroup" 2>/dev/null | grep -q '^'"$PRIV_USER"'\>'); then
        if ! net localgroup "$admingroup" "$PRIV_USER" $(winopt /add) 2>/dev/null; then
            echo >&2 "ERROR: Unable to add user $PRIV_USER to group $admingroup"
            uninstall 1
        fi
    fi

    # Infinite passwd expiry
    "$pwsh" $pwsh_args -c '$u = [adsi]"WinNT://./'"$PRIV_USER"'"; $u.userflags[0] = $u.userflags[0] -bor 0x10000; $u.setinfo()'

    # set required privileges
    for flag in SeAssignPrimaryTokenPrivilege SeCreateTokenPrivilege \
      SeTcbPrivilege SeDenyRemoteInteractiveLogonRight SeServiceLogonRight; do
        if ! $EDITRIGHTS -a "$flag" -u "$PRIV_USER"; then
            echo >&2 "ERROR: Unable to give $flag rights to user $PRIV_USER"
            uninstall 1
        fi
    done


    #
    # The unprivileged sshd user (for privilege separation)
    #

    add=$(if ! net user "$UNPRIV_USER" >/dev/null 2>&1; then echo "$(winopt /add)"; fi)
    if ! net user "$UNPRIV_USER" $add $(winopt /fullname):"$UNPRIV_NAME" \
            $(winopt /homedir):"$(cygpath -w $EMPTY_DIR)" $(winopt /active):no; then
        echo >&2 "ERROR: Unable to create Windows user $UNPRIV_USER"
        uninstall 1
    fi


    #
    # Add or update /etc/passwd service entries
    #

    touch /etc/passwd
    for u in "$PRIV_USER" "$UNPRIV_USER"; do
        sed -i -e '/^'"$u"':/d' /etc/passwd
        SED='/^'"$u"':/s?^\(\([^:]*:\)\{5\}\).*?\1'"$EMPTY_DIR"':/bin/false?p'
        mkpasswd -l -u "$u" | sed -e 's/^[^:]*+//' | sed -ne "$SED" \
                 >> /etc/passwd
    done
    mkgroup.exe -l > /etc/group

    #
    # Add or update current user and groups in /etc/passwd and /etc/group
    #

    u=$(whoami)
    sed -i -e '/^'"$u"':/d' /etc/passwd
    mkpasswd    -c >> /etc/passwd
    mkgroup.exe -c >> /etc/group

    # Remove duplicates from /etc/group
    mv /etc/group /etc/group.work
    awk '!a[$0]++' /etc/group.work > /etc/group
    rm -f /etc/group.work

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
    delete_firewall_rule

    if ! netsh advfirewall firewall add rule name=$SERVICE dir=in action=allow protocol=TCP localport=$PORT; then
        echo >&2 "WARNING: unable to add firewall rule to open port $PORT"
    fi

    #
    # Make sure key and authorized_keys exists.
    #
    mkdir -p "$USERPROFILE/.ssh"
    chmod 700 "$USERPROFILE/.ssh"
    mkdir -p ~/.ssh
    chmod 700 ~/.ssh

    # Create key if it does not exist.
    # From: https://unix.stackexchange.com/a/135090/340856
    key="$USERPROFILE/.ssh/id_rsa"
    (yes "" | ssh-keygen -t rsa -b 4096 -N "" -f "$key" >/dev/null 2>&1) || :
    chmod 600 "$key"

    # Make sure existing public keys (or new one) are in authorized_keys.
    touch ~/.ssh/authorized_keys
    chmod 600 ~/.ssh/authorized_keys

    for pubkey in "$USERPROFILE"/.ssh/id_*.pub; do
        if ! grep -q "$(cat "$pubkey")" ~/.ssh/authorized_keys; then
            cat "$pubkey" >> ~/.ssh/authorized_keys
        fi
    done

    # Make sure permissions are good on the environment home directory, this is
    # especially important if using the Windows profile directory as the home
    # directory. This only has an effect on Cygwin.
    #
    # From: https://echoicdev.home.blog/2019/03/11/fix-cygwin-ssh-error-ignored-authorized-keys-bad-ownership-or-modes-for-directory/
    chown "$USER":None "$HOME"
    chmod 700 "$HOME"

    # Add aliases to ssh config.
    ssh_config=$USERPROFILE/.ssh/config
    touch "$ssh_config"
    chmod 600 "$ssh_config"

    posix_username=$(whoami)

    if [ $(uname -o) != Cygwin ]; then
        for sys in MSYS MINGW64 MINGW32; do
            if ! grep -q "MSYSTEM=$sys" "$ssh_config"; then
                # For host alias, lowercase and rename 'msys' -> 'msys2'.
                host=$(echo "$sys" | tr 'A-Z' 'a-z')
                [ "$host" = msys ] && host=msys2

                cat >>"$ssh_config" <<EOF

Host $host
  User $posix_username
  HostName localhost
  Port $PORT
  RequestTTY yes
  RemoteCommand MSYSTEM=$sys MSYS2_PATH_TYPE=inherit exec bash -l
EOF
            fi
        done
    else
        if ! grep -q cygwin "$ssh_config"; then
            cat >>"$ssh_config" <<EOF

Host cygwin
  User $posix_username
  HostName localhost
  Port $PORT
EOF
        fi
    fi

    # Change ssh config to UNIX line endings. Sometimes it has DOS
    # line endings if it's in the user's profile dir, and this
    # script corrupts the file by writing text with UNIX line
    # endings.
    tr -d '\r' < "$ssh_config" > "${ssh_config}.new"
    mv -f "${ssh_config}.new" "$ssh_config"

    # Make sure all ssh files in the profile dir have correct
    # Windows permissions.
    fix_permissions

    # Make sure .bash_logout returns 0 or the terminal tab will not close immediately.
    case "$(grep -Ev '^[[:space:]]*$' ~/.bash_logout 2>/dev/null | tail -n 1)" in
        *"exit 0")
            ;;
        *)
            echo 'exit 0' >> ~/.bash_logout
            ;;
    esac

    # Check for dev mode and enable real symlinks if enabled.
    dev_mode=$("$(cygpath 'c:\Windows\System32\reg.exe')" query 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock' $(winopt /v) AllowDevelopmentWithoutDevLicense 2>/dev/null | grep REG_DWORD | awk '{ print $3 }' | sed 's/^0x//')

    symlinks=
    if [ "$dev_mode" = 1 ]; then
        echo "Developer mode is ENABLED, enabling real symlink support."
        symlinks='winsymlinks:nativestrict'
    fi

    #
    # Finally, register service with cygrunsrv and start it
    #

    remove_service

    cygrunsrv -I $SERVICE -d "$SERVICE_DESC" -p \
              "$SSHD" -a "-D -e" -y tcpip -u "$PRIV_USER" -w "$tmp_pass" \
              --env "$RUNTIME_VAR=ntsec export wincmdln $symlinks"

    # The SSH service should start automatically when Windows is rebooted.
    if ! net start $SERVICE; then
        echo >&2 "ERROR: Unable to start $SERVICE service"
        uninstall 1
    fi

    if [ "$("$(cygpath 'c:\windows\system32\whoami.exe')" | cut -f1 -d'\' | tr 'A-Z' 'a-z')" != "$(echo "$COMPUTERNAME" | tr 'A-Z' 'a-z')" ]; then # user is domain user
        printf "Please enter your Windows domain user password, this is needed for passwordless logon with a key.\n\n"
        passwd -R
    fi
}

fix_permissions() {
    mkdir -p /tmp/powershell-permissions-repair-scripts
    old_pwd=$PWD
    cd /tmp/powershell-permissions-repair-scripts

    curl -sLO https://raw.githubusercontent.com/PowerShell/openssh-portable/latestw_all/contrib/win32/openssh/FixUserFilePermissions.ps1
    curl -sLO https://raw.githubusercontent.com/PowerShell/openssh-portable/latestw_all/contrib/win32/openssh/OpenSSHUtils.psd1
    curl -sLO https://raw.githubusercontent.com/PowerShell/openssh-portable/latestw_all/contrib/win32/openssh/OpenSSHUtils.psm1

    "$pwsh" $pwsh_args -file ./FixUserFilePermissions.ps1

    if [ -f "${USERPROFILE}/.ssh/authorized_keys" ]; then
        "$pwsh" $pwsh_args -c 'import-module -force ./OpenSSHUtils.psd1; repair-authorizedkeypermission -file ~/.ssh/authorized_keys'
    fi

    cd $old_pwd
    rm -rf /tmp/powershell-permissions-repair-scripts
}

delete_users() {
    for u in "$PRIV_USER" "$UNPRIV_USER"; do
        if net user "$u" >/dev/null 2>&1; then
            net user "$u" $(winopt /delete)
        fi
    done
}

delete_firewall_rule() {
    netsh advfirewall firewall delete rule name=$SERVICE 2>/dev/null || :
}

remove_service() {
    cygrunsrv -R $SERVICE 2>/dev/null || :
}

uninstall() {
    net stop $SERVICE || :
    remove_service
    delete_firewall_rule
    delete_users
    echo "Service uninstalled."
    exit $1
}

main "$@"

# vim:sw=4 et:
