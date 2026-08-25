#!/var/jb/usr/bin/python3
import os
import socket
import subprocess
import threading

SOCKET = "/var/jb/var/run/macws-onboarding.sock"
STATUS = "/var/jb/var/run/macws-onboarding.status"
LOG = "/var/jb/var/log/macws-onboarding.log"
SETUP = "/var/jb/usr/macOS/bin/macws-firstboot.sh"
LAUNCH = "/var/jb/usr/macOS/bin/macws-launch.sh"
STOP = "/var/jb/usr/macOS/bin/macws-stop.sh"

os.makedirs(os.path.dirname(SOCKET), exist_ok=True)
os.makedirs(os.path.dirname(LOG), exist_ok=True)
try:
    os.unlink(SOCKET)
except FileNotFoundError:
    pass

status_lock = threading.Lock()
active_lock = threading.Lock()
active = False


def write_status(state, message):
    tmp = STATUS + ".tmp"
    with status_lock:
        with open(tmp, "w", encoding="utf-8") as f:
            f.write("STATE=%s\n" % state)
            f.write("MESSAGE=%s\n" % message.replace("\n", " ")[:1000])
        os.replace(tmp, STATUS)

write_status("IDLE", "Служба настройки запущена")


def run_script(path, success_message):
    global active
    write_status("RUNNING", "Выполняется: " + success_message)
    try:
        with open(LOG, "ab", buffering=0) as log:
            proc = subprocess.Popen(
                ["/var/jb/usr/bin/bash", path],
                stdout=log,
                stderr=subprocess.STDOUT,
                stdin=subprocess.DEVNULL,
            )
            rc = proc.wait()
        if rc == 0:
            write_status("DONE", success_message)
        else:
            write_status("ERROR", "Ошибка %d. Подробности: %s" % (rc, LOG))
    except Exception as exc:
        write_status("ERROR", str(exc))
    finally:
        with active_lock:
            active = False


def start_async(path, message):
    global active
    with active_lock:
        if active:
            return "Уже выполняется. Следите за полем статуса."
        active = True
    threading.Thread(target=run_script, args=(path, message), daemon=True).start()
    return "Запущено: " + message


def handle_command(command):
    command = command.strip()
    if command == "status":
        try:
            with open(STATUS, "r", encoding="utf-8") as f:
                return f.read()
        except OSError:
            return "STATE=UNKNOWN\nMESSAGE=Нет файла состояния"
    if command == "setup":
        return start_async(SETUP, "полная автоматическая установка")
    if command == "launch":
        return start_async(LAUNCH, "запуск macOS")
    if command == "stop":
        return start_async(STOP, "остановка macOS")
    return "Неизвестная команда"


server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
server.bind(SOCKET)
os.chmod(SOCKET, 0o666)
server.listen(8)

while True:
    conn, _ = server.accept()
    with conn:
        try:
            data = conn.recv(4096)
            command = data.decode("utf-8", "replace")
            response = handle_command(command)
            conn.sendall(response.encode("utf-8", "replace"))
        except Exception as exc:
            try:
                conn.sendall(("Ошибка IPC: %s" % exc).encode("utf-8"))
            except Exception:
                pass
