#ifndef MACWS_CONTROL_PROTOCOL_H
#define MACWS_CONTROL_PROTOCOL_H

#define MACWS_CONTROL_SERVICE "com.macwsguide.host.control"
// Version 9 publishes the live desktop system-input owner independently from
// retained display-layer metadata.  A final-composite layer is allowed to stay
// visually static across a Dock restart; it is therefore not an input-liveness
// authority.
#define MACWS_CONTROL_VERSION 9u

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

#endif
