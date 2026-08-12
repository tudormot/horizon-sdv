#!/bin/bash
mkdir -p /run/sshd /var/run/sshd
ssh-keygen -A
/usr/sbin/sshd 2>/dev/null || service ssh restart 2>/dev/null || :
