#!/bin/bash
# Startup script to ensure user 'user' exists, has .bashrc and ~/Workspace on /home/user

userid=1000
if ! id -u user >/dev/null 2>&1; then
    if id -u $userid >/dev/null 2>&1; then
        userdel $(id -nu $userid) 2>/dev/null || :
    fi
    groups=docker,sudo,users,kvm,cvdnetwork,render
    useradd -m user -u $userid -G $groups --shell /bin/bash >/dev/null 2>&1 || :
    passwd -d user >/dev/null 2>&1 || :
    echo "%sudo ALL=NOPASSWD: ALL" >> /etc/sudoers
fi

chmod 755 /home 2>/dev/null || :
mkdir -p /home/user /home/user/Workspace 2>/dev/null || :

# Copy skel templates if missing
if [ ! -f /home/user/.bashrc ] && [ -f /etc/skel/.bashrc ]; then
    cp /etc/skel/.bashrc /home/user/.bashrc 2>/dev/null || :
fi
if [ ! -f /home/user/.profile ] && [ -f /etc/skel/.profile ]; then
    cp /etc/skel/.profile /home/user/.profile 2>/dev/null || :
fi
if [ ! -f /home/user/.bash_logout ] && [ -f /etc/skel/.bash_logout ]; then
    cp /etc/skel/.bash_logout /home/user/.bash_logout 2>/dev/null || :
fi

chmod 755 /home/user /home/user/Workspace 2>/dev/null || :
chown -R user:user /home/user 2>/dev/null || :
