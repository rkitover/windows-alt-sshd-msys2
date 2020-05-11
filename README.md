## Concurrent MSYS2 SSHD for Windows

This is a script for installing MSYS2 sshd on port 2222 to run concurrently with
the native OpenSSH sshd for Windows.

It is a fork of this popular gist for installing MSYS2 sshd:

https://gist.github.com/samhocevar/00eec26d9e9988d080ac

This allows full terminal capability in MSYS2, which is currently not possible
with the native OpenSSH sshd or terminal.

### Installation

Download the script and read it:

```powershell
curl -LO 'https://raw.githubusercontent.com/rkitover/windows-alt-sshd-msys2/master/msys2-alt-sshd-setup.sh'
less msys2-alt-sshd-setup.sh
```

Press Win + X and run the Administrator PowerShell or cmd prompt.

Start a privileged bash shell:

```powershell
/msys64/usr/bin/bash -l
```

Go to the directory where you downloaded the script and run it:

```bash
bash msys2-alt-sshd-setup.sh
```

The firewall rule is created automatically.

### OpenSSH Setup

You can configure OpenSSH to create aliases for MSYS2 sessions.

On Windows or Linux.

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

If you are doing this on a remote host, replace localhost with your Windows
host.

Then to connect to the MSYS2 sshd you would simply run:

```powershell
ssh msys2
```

or

```powershell
ssh mingw64
```

etc..

### Microsoft Windows Terminal Preview Setup

This requires OpenSSH set up as described in [OpenSSH Setup](#openssh-setup).

To create MSYS2 entries in the terminal session drop-down, add the following to
your settings.json in the profiles section:

```json
{
    "name": "MSYS2 - MSYS",
    //"backgroundImage": "file://C:/Users/rkitover/Pictures/wallpapers/wallhaven-208786.jpg",
    "backgroundImageOpacity": 0.32,
    "backgroundImageStretchMode": "uniformToFill",
    "fontFace": "Hack",
    "fontSize": 10,
    "colorScheme": "Tango Dark",
    "cursorShape": "filledBox",
    "icon": "file://C:/msys64/msys2.ico",
    "commandline": "ssh msys2"
},
{
    "name": "MSYS2 - MINGW64",
    //"backgroundImage": "file://C:/Users/rkitover/Pictures/wallpapers/wallhaven-208786.jpg",
    "backgroundImageOpacity": 0.32,
    "backgroundImageStretchMode": "uniformToFill",
    "fontFace": "Hack",
    "fontSize": 10,
    "colorScheme": "Tango Dark",
    "cursorShape": "filledBox",
    "icon": "file://C:/msys64/msys2.ico",
    "commandline": "ssh mingw64"
},
{
    "name": "MSYS2 - MINGW32",
    //"backgroundImage": "file://C:/Users/rkitover/Pictures/wallpapers/wallhaven-208786.jpg",
    "backgroundImageOpacity": 0.32,
    "backgroundImageStretchMode": "uniformToFill",
    "fontFace": "Hack",
    "fontSize": 10,
    "colorScheme": "Tango Dark",
    "cursorShape": "filledBox",
    "icon": "file://C:/msys64/msys2.ico",
    "commandline": "ssh mingw32"
},
```

To get the Hack font install "hackfont" from chocolatey.

### Limitations

It is not possible to run GUI apps from these ssh sessions directly, the reason
for this is described here:

https://stackoverflow.com/questions/267838/how-can-a-windows-service-execute-a-gui-application

However, there is a working workaround.

Just start a tmux session in mintty, detach from it, then attach to it in the
ssh session, and you will be able to launch GUI apps.
