#ifndef MACWS_CONTROL_PROTOCOL_H
#define MACWS_CONTROL_PROTOCOL_H

#define MACWS_CONTROL_SERVICE "com.macwsguide.host.control"
#define MACWS_CONTROL_VERSION 6u

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

#define MACWS_CONTROL_OP_STATUS "status"
#define MACWS_CONTROL_OP_START "start"
#define MACWS_CONTROL_OP_STOP "stop"
#define MACWS_CONTROL_OP_REPAIR "repair"
#define MACWS_CONTROL_OP_RECOVER "recover"
#define MACWS_CONTROL_OP_LAUNCH_APP "launch-app"
#define MACWS_CONTROL_OP_LAUNCH_PATH "launch-path"
#define MACWS_CONTROL_OP_CAPTURE "capture"
#define MACWS_CONTROL_OP_LOGS "logs"
#define MACWS_CONTROL_OP_RESOLVE_HOST "resolve-host"
#define MACWS_CONTROL_OP_REFRESH_DOCK "refresh-dock"

#endif
