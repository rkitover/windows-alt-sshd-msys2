## Concurrent MSYS2/Cygwin SSHD for Windows

This is a script for installing MSYS2 sshd on port 2222 to run concurrently with
the native OpenSSH sshd for Windows.

It also works for Cygwin, in which case the Cygwin ssh can also run
concurrently with the MSYS2 sshd on the default port of 2223.

It is a fork of this popular gist for installing MSYS2 sshd:

https://gist.github.com/samhocevar/00eec26d9e9988d080ac

This allows full terminal capability in MSYS2, which is currently not possible
with the native OpenSSH sshd or terminal.

### Options

The port can be specified with the `--port` or `-p` option, you can also edit
`sshd_config` after installation and restart the service
(`/etc/ssh/sshd_config` on MSYS2 and `/etc/sshd_config` on Cygwin.)

The service name is `msys2_sshd` for MSYS2 and `cygwin_sshd` for Cygwin.

To uninstall the service, use `--uninstall` or `-u`.

### Home Directory Location

If you want to use your Windows profile directory as your MSYS2 or Cygwin home
directory, put the following in `/etc/nsswitch.conf`:

```
db_home: windows
```

If you choose to do this, I recommend adding the following to your `~/.bashrc`:

```bash
alias ls="ls -h --color=auto --hide='ntuser.*' --hide='NTUSER.*'"
```

### Installation

Download the script and read it:

**(powershell)**

```powershell
iwr https://raw.githubusercontent.com/rkitover/windows-alt-sshd-msys2/master/msys2-alt-sshd-setup.sh -outfile msys2-alt-sshd-setup.sh
more msys2-alt-sshd-setup.sh
```

**(bash or cmd.exe)**

```bash
curl -LO "https://raw.githubusercontent.com/rkitover/windows-alt-sshd-msys2/master/msys2-alt-sshd-setup.sh"
more msys2-alt-sshd-setup.sh
```

Press Win + X and run the Administrator PowerShell or cmd prompt.

Start a privileged bash shell on MSYS2:

```powershell
/msys64/usr/bin/bash -l
```

if you installed MSYS2 with Chocolatey, it would instead be:

```powershell
/tools/msys64/usr/bin/bash -l
```
.

And on Cygwin:

```powershell
/cygwin64/bin/bash -l
```

or if you installed MSYS2 with Chocolatey, it would instead be:

```powershell
/tools/cygwin/bin/bash -l
```
.

Go to the directory where you downloaded the script and run it:

```bash
bash msys2-alt-sshd-setup.sh
```

The firewall rule is created automatically.

### OpenSSH Setup

The script configures OpenSSH automatically to create aliases for your MSYS2 or
Cygwin sessions.

You must install OpenSSH for Windows to use this, it can be installed via the
`openssh` chocolatey package.

If you want to do this yourself here are the details:

Edit `~/.ssh/config` and add the following:

```
Host msys2
  HostName localhost
  Port 2222
  RequestTTY yes
  RemoteCommand MSYSTEM=MSYS exec bash -l

Host mingw64
  HostName localhost
  Port 2222
  RequestTTY yes
  RemoteCommand MSYSTEM=MINGW64 bash -l

Host mingw32
  HostName localhost
  Port 2222
  RequestTTY yes
  RemoteCommand MSYSTEM=MINGW32 bash -l
```

For Cygwin it would be:

```
Host cygwin
  HostName localhost
  Port 2223
```

If you are doing this on a remote host, replace localhost with your Windows
host.

This can be done on Windows or Linux etc..

Then to connect to the MSYS2 sshd you would simply run:

```powershell
ssh msys2
```

or

```powershell
ssh mingw64
```

or to connect to Cygwin:

```powershell
ssh cygwin
```

etc..

### Passwordless SSH

To not require a password to connect to your MSYS2/Cygwin sshd, the script
automatically sets up an `authorized_keys` file for you with a key if you do
not have one.

To do this yourself:

First, if you do not already have an ssh key, generate one:

```powershell
ssh-keygen -t rsa -b 4096
ssh-add ~/.ssh/id_rsa
```

You can leave the passphrase empty, if you do set it, the `ssh-agent` service
will store it for you so you are not asked for it constantly.

Then add your public key to `authorized_keys` to allow key authentication
instead of using a password. **NOTE:** this is the `authorized_keys` in your
MSYS2 or Cygwin home directory, assuming you're not using your Windows home
directory.

So from an MSYS2 or Cygwin shell you would do:

```bash
mkdir -p ~/.ssh
chmod 700 ~/.ssh
cat "${USERPROFILE}/.ssh/id_rsa.pub" >> ~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys
```

Note that the Windows sshd does not by default use this location for the
authorized_keys file for users in the Administrators group. In this case, this
does not matter because the MSYS2/Cygwin sshd does, but if you set your
MSYS2/Cygwin home directory to your profile directory, and you are in the
Administrators group, and you want to use the same authorized_keys file for
both, then edit `C:\ProgramData\ssh\sshd_config` and comment out these lines by
putting a `#` in front of each one:

```sshconfig
Match Group administrators
       AuthorizedKeysFile __PROGRAMDATA__/ssh/administrators_authorized_keys
```
.

This can be done with this command:

```powershell
sed -i 's/.*administrators.*/#&/g' /programdata/ssh/sshd_config
```
.

Make sure to fix the permissions on the `~/.ssh` files in your profile directory
by running the following from PowerShell:

```powershell
&(resolve-path /prog*s/openssh*/fixuserfilepermissions.ps1)
import-module -force $(resolve-path /prog*s/openssh*/opensshutils.psd1)
repair-authorizedkeypermission -file ~/.ssh/authorized_keys
```
, the script does this as well.

### Microsoft Windows Terminal Setup

This requires OpenSSH set up as described in [OpenSSH Setup](#openssh-setup)
and [Passwordless SSH](#passwordless-ssh). The script does both of these steps
automatically.

To create MSYS2 entries in the terminal session drop-down, add the following to
your settings.json in the profiles section:

```json
{
    "name": "MSYS2 - MSYS",
    "icon": "file://C:/msys64/msys2.ico",
    "commandline": "ssh msys2"
},
{
    "name": "MSYS2 - MINGW64",
    "icon": "file://C:/msys64/msys2.ico",
    "commandline": "ssh mingw64"
},
{
    "name": "MSYS2 - MINGW32",
    "icon": "file://C:/msys64/msys2.ico",
    "commandline": "ssh mingw32"
},
```

A Cygwin entry might look like this:

```json
{
    "name": "Cygwin",
    "icon": "file://C:/cygwin64/Cygwin-Terminal.ico",
    "commandline": "ssh cygwin"
},
```

### Limitations

It is not possible to run GUI apps from these ssh sessions directly, the reason
for this is described here:

https://stackoverflow.com/questions/267838/how-can-a-windows-service-execute-a-gui-application

However, there is a workaround.

Just start a tmux session in mintty, detach from it, then attach to it in the
ssh session, and you will be able to launch GUI apps.
