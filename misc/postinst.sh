cd $(realpath $HOME/../..)/usr/macOS

add_trustcache() {
    local path="$1"
    local cdhash
    cdhash=$(ldid -arch arm64 -h "$path" 2>/dev/null | grep CDHash= | cut -c8-)
    if [ -n "$cdhash" ]; then
        echo "Adding $path cdhash: $cdhash"
        jbctl trustcache add "$cdhash"
    fi
}

add_arm64e_trustcache() {
    local path="$1"
    local cdhash
    cdhash=$(ldid -arch arm64e -h "$path" 2>/dev/null | grep CDHash= | cut -c8-)
    if [ -n "$cdhash" ]; then
        echo "Adding $path cdhash: $cdhash"
        jbctl trustcache add "$cdhash"
    fi
}

add_x86_64_trustcache() {
    local path="$1"
    local cdhash
    cdhash=$(ldid -arch x86_64 -h "$path" 2>/dev/null | grep CDHash= | cut -c8-)
    if [ -n "$cdhash" ]; then
        echo "Adding $path cdhash: $cdhash"
        jbctl trustcache add "$cdhash"
    fi
}

add_all_trustcache() {
    local path="$1"
    add_trustcache $1
    add_arm64e_trustcache $1
    add_x86_64_trustcache $1
}

add_trustcache "/var/jb/usr/macOS/bin/login"
add_trustcache "/var/jb/usr/macOS/bin/TestMetalIOSurface"
add_all_trustcache "/var/jb/usr/macOS/lib/libmachook.dylib"
add_all_trustcache "/var/jb/usr/macOS/bin/launchdchrootexec"
add_all_trustcache "/var/jb/usr/macOS/bin/launchdchrootexec_debug"
add_all_trustcache "/var/jb/usr/macOS/Frameworks/MetalSerializer.framework/MetalSerializer"
add_all_trustcache "/var/jb/usr/macOS/Frameworks/MTLSimDriver.framework/MTLSimDriver"
add_all_trustcache "/var/jb/usr/macOS/Frameworks/MTLSimImplementation.framework/MTLSimImplementation"
add_all_trustcache "/var/jb/usr/macOS/Frameworks/MTLSimDriver.framework/XPCServices/MTLSimDriverHost.xpc/MTLSimDriverHost"
# codesign -vvv -d dyld_shared_cache_arm64e 2>&1 | grep CDHash=
jbctl trustcache add b5da39409492ac85e5a8e8ab618fe77e2d7a2980
# codesign -vvv -d dyld_shared_cache_arm64e.01 2>&1 | grep CDHash=
jbctl trustcache add bbb765988e2677b98d47a549d612fa0d4af25f69
add_all_trustcache "/var/mnt/rootfs/bin/bash"
add_all_trustcache "/var/mnt/rootfs/System/Library/CoreServices/launchservicesd"
if [ ! -e "/var/mnt/rootfs/System/Library/CoreServices/launchservicesd.dylib" ]; then
	cp -vf /var/jb/usr/macOS/Frameworks/launchservicesd.dylib "/var/mnt/rootfs/System/Library/CoreServices/launchservicesd.dylib"
fi
add_all_trustcache "/var/mnt/rootfs/System/Library/CoreServices/launchservicesd.dylib"
add_all_trustcache "/var/mnt/rootfs/System/Library/PrivateFrameworks/SkyLight.framework/Resources/WindowServer"
add_all_trustcache /var/jb/usr/macOS/bin/HostInjectBootstrap
add_all_trustcache /var/mnt/rootfs/System/Library/Frameworks/Metal.framework/XPCServices/MTLCompilerService.xpc/Contents/MacOS/MTLCompilerService
add_all_trustcache /System/Library/Frameworks/Metal.framework/XPCServices/MTLCompilerService.xpc/MTLCompilerService
cp -vf /var/jb/usr/macOS/lib/libmachook.dylib /var/mnt/rootfs/usr/local/lib/libmachook.dylib
add_all_trustcache /var/mnt/rootfs/usr/local/lib/libmachook.dylib
add_all_trustcache '/var/mnt/rootfs/System/Applications/Utilities/Activity Monitor.app/Contents/MacOS/Activity Monitor'
add_all_trustcache /var/mnt/rootfs/usr/lib/libobjc-trampolines.dylib
add_all_trustcache /var/mnt/rootfs/usr/lib/dyld
add_all_trustcache /var/mnt/rootfs/bin/ps
add_all_trustcache /var/mnt/rootfs/bin/mv
add_all_trustcache /var/mnt/rootfs/bin/cp
add_all_trustcache /var/mnt/rootfs/usr/bin/log
add_all_trustcache /var/mnt/rootfs/bin/launchctl
add_all_trustcache /var/mnt/rootfs/usr/bin/open
add_all_trustcache /var/jb/usr/macOS/bin/PingMTLCompilerService
add_all_trustcache /var/jb/usr/macOS/bin/launchdchrootexec
add_all_trustcache /var/jb/Library/Frameworks/CydiaSubstrate.framework/CydiaSubstrate
add_all_trustcache /var/mnt/rootfs/System/Library/Frameworks/CydiaSubstrate.framework/CydiaSubstrate
add_all_trustcache /var/mnt/rootfs/System/Tweaks/TweakLoader.dylib
# add_all_trustcache /var/mnt/rootfs/System/Library/HIDPlugins/ServicePlugins/IOHIDEventServicePlugin.plugin/Contents/MacOS/IOHIDEventServicePlugin
add_all_trustcache "/var/mnt/rootfs/System/Library/CoreServices/Installer Progress.app/Contents/MacOS/Installer Progress"
add_all_trustcache /var/mnt/rootfs/usr/lib/systemhook.dylib
add_all_trustcache /var/jb/usr/lib/libroot.dylib
add_all_trustcache /var/mnt/rootfs/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/Resources/CursorAsset
add_all_trustcache /var/mnt/rootfs/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/Resources/CursorAsset_base
# add_all_trustcache /var/mnt/rootfs/System/Library/HIDPlugins/AppleSPUHIDStatistics.plugin/Contents/MacOS/AppleSPUHIDStatistics
# add_all_trustcache /var/mnt/rootfs/System/Library/HIDPlugins/IOHIDEventSystemStatistics.plugin/Contents/MacOS/IOHIDEventSystemStatistics
# add_all_trustcache /var/mnt/rootfs/System/Library/HIDPlugins/IOHIDNXEventTranslatorSessionFilter.plugin/Contents/MacOS/IOHIDNXEventTranslatorSessionFilter
# add_all_trustcache /var/mnt/rootfs/System/Library/HIDPlugins/IOHIDDFREventFilter.plugin/Contents/MacOS/IOHIDDFREventFilter
# add_all_trustcache /var/mnt/rootfs/System/Library/HIDPlugins/SessionFilters/IOHIDRemoteSensorSessionFilter.plugin/Contents/MacOS/IOHIDRemoteSensorSessionFilter
# add_all_trustcache /var/mnt/rootfs/System/Library/HIDPlugins/SessionFilters/IOAnalytics.plugin/Contents/MacOS/IOAnalytics
# add_all_trustcache /var/mnt/rootfs/System/Library/CoreServices/TouchBarEvent.bundle
add_all_trustcache /var/mnt/rootfs/System/Library/PrivateFrameworks/GPUCompiler.framework/Versions/31001/Libraries/libGPUCompiler.dylib
add_all_trustcache /var/mnt/rootfs/usr/local/Frameworks/MetalSerializer.framework/MetalSerializer
add_all_trustcache /var/mnt/rootfs/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal
add_all_trustcache /var/mnt/rootfs/usr/local/lib/.jbroot/usr/lib/libroot.dylib
# vnc server
add_all_trustcache /var/mnt/rootfs/System/Library/CoreServices/RemoteManagement/ARDAgent.app/Contents/Resources/kickstart
add_all_trustcache /var/mnt/rootfs/System/Library/CoreServices/RemoteManagement/ARDAgent.app/Contents/MacOS/ARDAgent
add_all_trustcache /var/mnt/rootfs/bin/launchctl
add_all_trustcache /var/mnt/rootfs/bin/rm
add_all_trustcache /var/mnt/rootfs/bin/ls
add_all_trustcache /var/mnt/rootfs/bin/kill
add_all_trustcache /var/mnt/rootfs/bin/pwd
add_all_trustcache /var/mnt/rootfs/usr/bin/python3
add_all_trustcache /var/mnt/rootfs/usr/bin/defaults
add_all_trustcache /var/mnt/rootfs/usr/bin/perl
add_all_trustcache /var/mnt/rootfs/usr/bin/perl5.30
add_all_trustcache /var/mnt/rootfs/usr/bin/which
add_all_trustcache /var/mnt/rootfs/usr/bin/env
add_all_trustcache /var/mnt/rootfs/usr/bin/grep
add_all_trustcache /var/mnt/rootfs/usr/bin/vim
add_all_trustcache /var/mnt/rootfs/System/Library/CoreServices/RemoteManagement/ARDAgent.app/Contents/Support/ardpackage
add_all_trustcache /var/mnt/rootfs/System/Library/CoreServices/RemoteManagement/ARDAgent.app/Contents/Support/build_hd_index
add_all_trustcache /var/mnt/rootfs/System/Library/CoreServices/RemoteManagement/ARDAgent.app/Contents/Support/distnotifyutil
add_all_trustcache /var/mnt/rootfs/System/Library/CoreServices/RemoteManagement/ARDAgent.app/Contents/Support/sysinfocachegen
add_all_trustcache /var/mnt/rootfs/System/Library/CoreServices/RemoteManagement/ARDAgent.app/Contents/Support/tccstate
add_all_trustcache /var/mnt/rootfs/System/Library/CoreServices/RemoteManagement/ARDAgent.app/Contents/Support/Remote\ Desktop\ Message.app/Contents/MacOS/Remote\ Desktop\ Message
add_all_trustcache /var/mnt/rootfs/System/Library/CoreServices/RemoteManagement/ARDAgent.app/Contents/Support/Remote\ Desktop\ Message.app/Contents/MacOS/Remote\ Desktop\ Message
add_all_trustcache /var/mnt/rootfs/System/Library/CoreServices/RemoteManagement/ARDAgent.app/Contents/Support/Shared\ Screen\ Viewer.app/Contents/MacOS/Shared\ Screen\ Viewer
add_all_trustcache /var/mnt/rootfs/System/Library/CoreServices/SystemUIServer.app/Contents/MacOS/SystemUIServer
add_all_trustcache /var/mnt/rootfs/usr/local/bin/OSXvnc-server
if [ -d /var/mnt/rootfs/var/jb ] && [ ! "$(ls -A /var/mnt/rootfs/var/jb)" ]; then
	/var/jb/usr/local/bin/mount_bindfs /var/jb /var/mnt/rootfs/var/jb
fi