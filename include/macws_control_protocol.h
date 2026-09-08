#ifndef MACWS_CONTROL_PROTOCOL_H
#define MACWS_CONTROL_PROTOCOL_H

#define MACWS_CONTROL_SERVICE "com.macwsguide.host.control"
// Version 10 adds the document-open transaction used after Ventura
// LaunchServices has resolved a document's application but iPadOS
// RunningBoard cannot launch that foreign macOS executable.  hostd validates
// both the bundle and document paths, starts/reuses the target process, then
// hands the standard open-documents lifecycle to that process's AppKit bridge.
#define MACWS_CONTROL_VERSION 10u

#define MACWS_CONTROL_KEY_OP "op"
#define MACWS_CONTROL_KEY_APP_ID "app_id"
#define MACWS_CONTROL_KEY_APP_PATH "app_path"
#define MACWS_CONTROL_KEY_EXPERIMENTAL "experimental"
#define MACWS_CONTROL_KEY_DNS_NODE "dns_node"
#define MACWS_CONTROL_KEY_DNS_SERVICE "dns_service"
#define MACWS_CONTROL_KEY_DNS_FLAGS "dns_flags"
#define MACWS_CONTROL_KEY_DNS_FAMILY "dns_family"
#define MACWS_CONTROL_KEY_DNS_SOCKTYPE "dns_socktype"
#define MACWS_CONTROL_KEY_DNS_PROTOCOL "dns_protocol"
#define MACWS_CONTROL_KEY_TARGET_PID "target_pid"
#define MACWS_CONTROL_KEY_SYSTEM_INPUT_PID "system_input_pid"
#define MACWS_CONTROL_KEY_SYSTEM_INPUT_READY "system_input_ready"
#define MACWS_CONTROL_KEY_METAL_LIBRARY "metal_library"
#define MACWS_CONTROL_KEY_SOURCE_LENGTH "source_length"
#define MACWS_CONTROL_KEY_SOURCE_HASH "source_hash"
#define MACWS_CONTROL_KEY_REPLACEMENT_LENGTH "replacement_length"
#define MACWS_CONTROL_KEY_REPLACEMENT_HASH "replacement_hash"
#define MACWS_CONTROL_KEY_DOCUMENT_PATHS "document_paths"
#define MACWS_CONTROL_KEY_DOCUMENT_OPEN_PENDING "document_open_pending"

#define MACWS_CONTROL_OP_STATUS "status"
#define MACWS_CONTROL_OP_START "start"
#define MACWS_CONTROL_OP_STOP "stop"
#define MACWS_CONTROL_OP_REPAIR "repair"
#define MACWS_CONTROL_OP_REPAIR_DESKTOP "repair-desktop"
#define MACWS_CONTROL_OP_RECOVER "recover"
#define MACWS_CONTROL_OP_LAUNCH_APP "launch-app"
#define MACWS_CONTROL_OP_LAUNCH_PATH "launch-path"
#define MACWS_CONTROL_OP_CAPTURE "capture"
#define MACWS_CONTROL_OP_LOGS "logs"
#define MACWS_CONTROL_OP_RESOLVE_HOST "resolve-host"
#define MACWS_CONTROL_OP_REFRESH_DOCK "refresh-dock"
#define MACWS_CONTROL_OP_RETARGET_METAL_LIBRARY "retarget-metal-library"
#define MACWS_CONTROL_OP_OPEN_DOCUMENTS "open-documents"

#endif
