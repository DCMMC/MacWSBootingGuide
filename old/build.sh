set -e

DEVICE_IP="iphone-cua-duy.local"

gmake FINALPACKAGE=1 STRIP=0 THEOS_PACKAGE_SCHEME=rootless package install THEOS_DEVICE_IP=$DEVICE_IP THEOS_DEVICE_PORT=2222 GO_EASY_ON_ME=1

cp .theos/obj/libmachook.dylib .
#vtool -set-build-version 1 11.0 11.0 -replace -output libmachook.dylib .theos/obj/libmachook.dylib
#ldid -S libmachook.dylib

vtool -arch arm64 -set-build-version 1 13.0 13.0 -replace -output .theos/obj/launchservicesd .theos/obj/launchservicesd
ldid -S -M .theos/obj/launchservicesd

libmachook_path="/var/jb/usr/macOS/lib/libmachook.dylib"
driverhost_path="/var/jb/usr/macOS/Frameworks/MTLSimDriver.framework/XPCServices/MTLSimDriverHost.xpc/MTLSimDriverHost"
launchdchrootexec_path="/var/jb/usr/macOS/LaunchDaemons/launchdchrootexec"
driverhost_hash=$(ldid -h .theos/obj/MTLSimDriverHost | grep CDHash= | cut -c8-)
libmachook_hash=$(ldid -h libmachook.dylib | grep CDHash= | cut -c8-)
exec_hash=$(ldid -h .theos/obj/exec | grep CDHash= | cut -c8-)
launchdchrootexec_hash=$(ldid -h .theos/obj/launchdchrootexec | grep CDHash= | cut -c8-)

ssh root@$DEVICE_IP -p 2222 "jbctl trustcache add $driverhost_hash; jbctl trustcache add $libmachook_hash; jbctl trustcache add $exec_hash; jbctl trustcache add $launchdchrootexec_hash"
