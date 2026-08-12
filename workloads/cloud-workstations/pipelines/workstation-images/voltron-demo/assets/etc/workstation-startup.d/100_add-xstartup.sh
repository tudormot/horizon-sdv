#!/bin/bash
USER_HOME="/home/user"
VNC_DIR="$USER_HOME/.vnc"
AUTOSTART_DIR="$USER_HOME/.config/autostart"

# 1. Unconditionally fix user home permissions for fresh/empty disks
chown -R user:user "$USER_HOME" 2>/dev/null || :

# 2. Unconditionally remove SystemdService from D-Bus service definitions
sed -i '/SystemdService=/d' /usr/share/dbus-1/services/org.gnome.Terminal.service 2>/dev/null || :
sed -i '/SystemdService=/d' /usr/local/share/dbus-1/services/org.gnome.Terminal.service 2>/dev/null || :

mkdir -p "$VNC_DIR" "$AUTOSTART_DIR"
rm -f "$AUTOSTART_DIR/gnome-terminal.desktop" 2>/dev/null || :

# 3. Write global autostart terminal helper (with single-instance check)
cat << 'EOF' > /usr/local/bin/autostart-terminal.sh
#!/bin/bash
export DISPLAY=:1
export XDG_CURRENT_DESKTOP=ubuntu:GNOME
export DESKTOP_SESSION=ubuntu

# Strip SystemdService from D-Bus definitions
sed -i '/SystemdService=/d' /usr/share/dbus-1/services/org.gnome.Terminal.service 2>/dev/null || :
sed -i '/SystemdService=/d' /usr/local/share/dbus-1/services/org.gnome.Terminal.service 2>/dev/null || :

# Remove redundant autostart desktop entry
rm -f /home/user/.config/autostart/gnome-terminal.desktop 2>/dev/null || :

# Wait for GNOME Shell session D-Bus bus address
for i in $(seq 1 30); do
    DBUS_PID=$(pgrep -u user gnome-shell | head -n1)
    if [ -n "$DBUS_PID" ] && [ -r "/proc/$DBUS_PID/environ" ]; then
        DBUS_ADDR=$(tr "\0" "\n" < "/proc/$DBUS_PID/environ" | grep "^DBUS_SESSION_BUS_ADDRESS=" | cut -d= -f2-)
        if [ -n "$DBUS_ADDR" ]; then
            export DBUS_SESSION_BUS_ADDRESS="$DBUS_ADDR"
            gsettings set org.gnome.desktop.lockdown disable-lock-screen true 2>/dev/null || :
            gsettings set org.gnome.desktop.screensaver lock-enabled false 2>/dev/null || :
            gsettings set org.gnome.desktop.session idle-delay 0 2>/dev/null || :
            sleep 0.5
            if ! pgrep -u user -f gnome-terminal-server >/dev/null 2>&1; then
                /usr/bin/gnome-terminal --window &
            fi
            exit 0
        fi
    fi
    sleep 0.5
done
EOF
chmod 755 /usr/local/bin/autostart-terminal.sh

# 4. Overwrite xstartup on the persistent home disk
cat << 'XEOF' > "$VNC_DIR/xstartup"
#!/bin/bash
export DISPLAY=:1
export XDG_CURRENT_DESKTOP=ubuntu:GNOME
export DESKTOP_SESSION=ubuntu
export GNOME_SHELL_SESSION_MODE=ubuntu
export XDG_SESSION_TYPE=x11
export GDK_BACKEND=x11

/usr/local/bin/autostart-terminal.sh &

exec dbus-launch --exit-with-session /usr/bin/gnome-session --session=ubuntu
XEOF
chmod 755 "$VNC_DIR/xstartup"

# 5. User D-Bus service override
mkdir -p "$USER_HOME/.local/share/dbus-1/services"
cat << 'XEOF' > "$USER_HOME/.local/share/dbus-1/services/org.gnome.Terminal.service"
[D-BUS Service]
Name=org.gnome.Terminal
Exec=/usr/libexec/gnome-terminal-server
XEOF

chown -R user:user "$USER_HOME"
