#ifndef MACWS_CONTROL_PROTOCOL_H
#define MACWS_CONTROL_PROTOCOL_H

#define MACWS_CONTROL_SERVICE "com.macwsguide.host.control"
#define MACWS_CONTROL_VERSION 5u

#define MACWS_CONTROL_KEY_OP "op"
#define MACWS_CONTROL_KEY_APP_ID "app_id"
#define MACWS_CONTROL_KEY_APP_PATH "app_path"
#define MACWS_CONTROL_KEY_EXPERIMENTAL "experimental"
#define MACWS_CONTROL_KEY_DEBUG "debug"

// Status reply keys beyond those decoded by the app.
#define MACWS_CONTROL_KEY_DEBUG_MODE "debug_mode"
#define MACWS_CONTROL_KEY_LAST_ERROR_DETAIL "last_error_detail"

#define MACWS_CONTROL_OP_STATUS "status"
#define MACWS_CONTROL_OP_START "start"
#define MACWS_CONTROL_OP_STOP "stop"
#define MACWS_CONTROL_OP_REPAIR "repair"
#define MACWS_CONTROL_OP_RECOVER "recover"
#define MACWS_CONTROL_OP_LAUNCH_APP "launch-app"
#define MACWS_CONTROL_OP_LAUNCH_PATH "launch-path"
#define MACWS_CONTROL_OP_CAPTURE "capture"
#define MACWS_CONTROL_OP_LOGS "logs"

#endif
