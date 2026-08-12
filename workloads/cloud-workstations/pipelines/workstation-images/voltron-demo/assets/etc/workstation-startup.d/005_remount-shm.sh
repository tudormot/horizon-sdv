#!/bin/bash
mount -o remount,size=2G /dev/shm 2>/dev/null || :
chmod 755 /home 2>/dev/null || :
