#!/bin/sh

apk_name="luci-app-ipinfo"
version="2.4.1"
releases="20251023"

echo "Updating packages"
if ! opkg update; then
    echo "Failed to update OPKG"
    exit 1
fi

echo "Downloading $apk_name"
if ! curl -LO "https://github.com/alrescha79-cmd/luci-app-ipinfo-mod/releases/download/$version/${apk_name}_${version}-${releases}_all.ipk"; then
    echo "Failed to download $apk_name"
    exit 1
fi

echo "Installing $apk_name"
if ! opkg install "${apk_name}_${version}-${releases}_all.ipk"; then
    echo "Failed to install $apk_name"
    exit 1
fi

echo "Process completed. $apk_name has been installed."
