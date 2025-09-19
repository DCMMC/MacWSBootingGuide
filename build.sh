set -e

DEVICE_IP="192.168.5.7"

gmake FINALPACKAGE=1 STRIP=0 THEOS_PACKAGE_SCHEME=rootless package install THEOS_DEVICE_IP=$DEVICE_IP THEOS_DEVICE_PORT=2222 GO_EASY_ON_ME=1

cp .theos/obj/libmachook.dylib .
vtool -set-build-version 1 13.0 13.0 -replace -output libmachook.dylib libmachook.dylib
ldid -S libmachook.dylib
codesign -f -s - libmachook.dylib 
scp -P 2222 libmachook.dylib root@$DEVICE_IP:/var/jb/usr/macOS/lib/libmachook.dylib
scp -P 2222 ./misc/postinst.sh root@$DEVICE_IP:/var/jb/usr/macOS/bin
scp -P 2222 ./misc/run_bash.sh root@$DEVICE_IP:/var/jb/usr/macOS/bin