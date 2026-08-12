#!/bin/bash
# Sets defaults for ASfP
# 1. Sets RAM allocation to 70% of available ram up to 64gb
# 2. Sets intellisense.filesize to 10000

echo "Setting Android Studio for Platform Options"

function getSeventyPercentOfMemory() {
  local memory=$(free -m 2>&1 | sed -nr 's/.*Mem:\s*([0-9]+).*/\1/p')
  local seventy_percent=$(($memory * 70 / 100 / 100 * 100))
  echo "$seventy_percent"
}

vm_memory=$(getSeventyPercentOfMemory)
if [[ $vm_memory -lt 64000 ]]; then
  sed -i "s/-Xmx20000m/-Xmx${vm_memory}m/" /opt/android-studio-for-platform-canary/bin/studio64.vmoptions 2>/dev/null || :
else
  sed -i "s/-Xmx20000m/-Xmx64000m/" /opt/android-studio-for-platform-canary/bin/studio64.vmoptions 2>/dev/null || :
fi

sed -i 's/-Didea.max.intellisense.filesize=999999/-Didea.max.intellisense.filesize=10000/' /opt/android-studio-for-platform-canary/bin/studio64.vmoptions 2>/dev/null || :
