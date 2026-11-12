import asyncio
import json
import os
import socket
import sys
import threading
import time
import winreg
import pyperclip
import websockets
from datetime import datetime
from PIL import Image, ImageDraw
import pystray
import tkinter as tk
from tkinter import ttk, messagebox

import traceback

# Crash logging helper
def log_exception(exc_type, exc_value, exc_tb):
    try:
        log_dir = os.path.dirname(os.path.abspath(sys.argv[0])) if getattr(sys, "frozen", False) else os.path.dirname(os.path.abspath(__file__))
        with open(os.path.join(log_dir, "textcast_debug.log"), "a", encoding="utf-8") as f:
            f.write(f"\n--- Exception at {datetime.now()} ---\n")
            traceback.print_exception(exc_type, exc_value, exc_tb, file=f)
    except Exception:
        pass

sys.excepthook = log_exception

# Redirect stdout/stderr when built with PyInstaller --noconsole
if sys.stdout is None:
    sys.stdout = open(os.devnull, "w")
if sys.stderr is None:
    sys.stderr = open(os.devnull, "w")

WS_PORT = 8765
DISCOVERY_PORT = 8766
REG_RUN_KEY = r"Software\Microsoft\Windows\CurrentVersion\Run"
APP_REG_NAME = "TextCast"


def get_local_ip() -> str:
    """Detect the active local IPv4 address using UDP socket routing check."""
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.connect(("8.8.8.8", 80))
        ip = s.getsockname()[0]
    except Exception:
        try:
            ip = socket.gethostbyname(socket.gethostname())
        except Exception:
            ip = "127.0.0.1"
    finally:
        s.close()
    return ip


def get_executable_command() -> str:
    """Get command to launch this app, whether packaged as exe or run from python."""
    if getattr(sys, "frozen", False):
        return f'"{sys.executable}"'
    else:
        script_path = os.path.abspath(__file__)
        return f'"{sys.executable}" "{script_path}"'


def is_autostart_enabled() -> bool:
    """Check if TextCast is registered in Windows Startup registry."""
    try:
        with winreg.OpenKey(winreg.HKEY_CURRENT_USER, REG_RUN_KEY, 0, winreg.KEY_READ) as key:
            val, _ = winreg.QueryValueEx(key, APP_REG_NAME)
            return bool(val)
    except FileNotFoundError:
        return False
    except Exception:
        return False


def set_autostart(enable: bool) -> bool:
    """Enable or disable TextCast running on Windows startup."""
    try:
        with winreg.OpenKey(winreg.HKEY_CURRENT_USER, REG_RUN_KEY, 0, winreg.KEY_ALL_ACCESS) as key:
            if enable:
                cmd = get_executable_command()
                winreg.SetValueEx(key, APP_REG_NAME, 0, winreg.REG_SZ, cmd)
            else:
                try:
                    winreg.DeleteValue(key, APP_REG_NAME)
                except FileNotFoundError:
                    pass
        return True
    except Exception as e:
        print(f"Error updating startup registry: {e}")
        return False


def create_tray_image():
    """Create a crisp system tray icon in memory using PIL."""
    size = 64
    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)

    # Teal rounded background
    d.rounded_rectangle([2, 2, 61, 61], radius=14, fill=(0, 173, 181, 255))
    # Clipboard paper
    d.rounded_rectangle([18, 18, 46, 52], radius=4, fill=(255, 255, 255, 255))
    # Clip on top
    d.rounded_rectangle([24, 12, 40, 20], radius=3, fill=(34, 35, 54, 255))
    # Inner lines
    d.rectangle([23, 27, 41, 30], fill=(0, 173, 181, 255))
    d.rectangle([23, 34, 41, 37], fill=(0, 173, 181, 255))
    d.rectangle([23, 41, 35, 44], fill=(0, 173, 181, 255))
    return img


class TextCastServer:
    def __init__(self, ui_callbacks):
        self.ui_callbacks = ui_callbacks
        self.hostname = socket.gethostname()
        self.local_ip = get_local_ip()
        self.connected_clients = set()
        self.connected_ips = []
        self.stop_event = threading.Event()
        self.loop = None
        self.last_text = ""  # Shared between clipboard monitor and incoming socket for echo suppression

    def get_discovery_payload(self) -> bytes:
        payload = {
            "service": "textcast",
            "name": self.hostname,
            "ip": self.local_ip,
            "port": WS_PORT,
            "version": "1.0",
        }
        return json.dumps(payload).encode("utf-8")

    def run_udp_discovery(self):
        """UDP server listening on 8766 for probes and sending periodic beacons."""
        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
        if hasattr(socket, "SIO_UDP_CONNRESET"):
            try:
                sock.ioctl(socket.SIO_UDP_CONNRESET, False)
            except Exception:
                pass

        try:
            sock.bind(("", DISCOVERY_PORT))
        except Exception as e:
            self.ui_callbacks["log"](f"UDP Discovery bind error on {DISCOVERY_PORT}: {e}")
            return

        sock.settimeout(1.0)
        last_beacon = 0

        while not self.stop_event.is_set():
            now = time.time()
            # Send periodic beacon every 2.5 seconds
            if now - last_beacon >= 2.5:
                last_beacon = now
                try:
                    payload = self.get_discovery_payload()
                    sock.sendto(payload, ("255.255.255.255", DISCOVERY_PORT))
                except Exception:
                    pass

            try:
                data, addr = sock.recvfrom(65535)
                if data:
                    # Check if it is an automated background clipboard sync packet from Android
                    try:
                        packet_str = data.decode("utf-8", errors="ignore").trim() if hasattr(str, "trim") else data.decode("utf-8", errors="ignore").strip()
                        if packet_str.startswith("{") and '"CLIPBOARD"' in packet_str:
                            msg = json.loads(packet_str)
                            if msg.get("cmd") == "CLIPBOARD":
                                text = msg.get("text", "")
                                if text and text != self.last_text:
                                    self.last_text = text
                                    try:
                                        pyperclip.copy(text)
                                    except Exception as e:
                                        self.ui_callbacks["log"](f"Clipboard write error: {e}")
                                        continue

                                    preview = text.replace("\r\n", " ").replace("\n", " ").strip()
                                    if len(preview) > 50:
                                        preview = preview[:47] + "..."
                                    self.ui_callbacks["log"](f"[<< AUTO-COPY FROM PHONE] ({len(text)} chars) -> Copied to PC: {preview}")
                                continue
                    except Exception:
                        pass

                    payload = self.get_discovery_payload()
                    sock.sendto(payload, addr)
            except socket.timeout:
                continue
            except Exception:
                pass

        sock.close()

    async def register_client(self, websocket):
        client_ip = websocket.remote_address[0]
        self.connected_clients.add(websocket)
        self.connected_ips.append(client_ip)
        self.ui_callbacks["update_clients"](list(self.connected_ips))
        self.ui_callbacks["log"](f"[+] Android device connected: {client_ip} (Total: {len(self.connected_clients)})")

        try:
            # Listen continuously for incoming messages from Android phone
            async for raw_message in websocket:
                await self.handle_incoming_from_phone(websocket, raw_message)
        except Exception:
            pass
        finally:
            self.connected_clients.discard(websocket)
            if client_ip in self.connected_ips:
                self.connected_ips.remove(client_ip)
            self.ui_callbacks["update_clients"](list(self.connected_ips))
            self.ui_callbacks["log"](f"[-] Android device disconnected: {client_ip} (Total: {len(self.connected_clients)})")

    async def handle_incoming_from_phone(self, sender_ws, raw_message):
        """Process incoming text copied on Android phone and update PC clipboard."""
        try:
            text = ""
            if isinstance(raw_message, str):
                if raw_message.startswith("{") and '"text"' in raw_message:
                    try:
                        data = json.loads(raw_message)
                        text = data.get("text", "")
                    except Exception:
                        text = raw_message
                else:
                    text = raw_message

            if text and text != self.last_text:
                # Update echo suppression state so clipboard_monitor does not re-broadcast
                self.last_text = text
                try:
                    pyperclip.copy(text)
                except Exception as e:
                    self.ui_callbacks["log"](f"Clipboard write error: {e}")
                    return

                preview = text.replace("\r\n", " ").replace("\n", " ").strip()
                if len(preview) > 50:
                    preview = preview[:47] + "..."
                self.ui_callbacks["log"](f"[<< FROM PHONE] ({len(text)} chars) -> Copied to PC: {preview}")

                # Forward to any other connected Android devices (excluding the sender)
                if len(self.connected_clients) > 1:
                    for ws in list(self.connected_clients):
                        if ws != sender_ws:
                            try:
                                await ws.send(text)
                            except Exception:
                                pass
        except Exception as e:
            self.ui_callbacks["log"](f"Error handling message from phone: {e}")

    async def broadcast_text(self, text: str):
        if not self.connected_clients:
            return
        disconnected = set()
        for ws in list(self.connected_clients):
            try:
                await ws.send(text)
            except Exception:
                disconnected.add(ws)
        for ws in disconnected:
            self.connected_clients.discard(ws)

    async def clipboard_monitor(self):
        """Poll clipboard every 300ms and broadcast on change (PC -> Phone)."""
        try:
            self.last_text = pyperclip.paste() or ""
        except Exception:
            self.last_text = ""

        while not self.stop_event.is_set():
            try:
                current_text = pyperclip.paste()
                if current_text and current_text != self.last_text:
                    self.last_text = current_text
                    preview = current_text.replace("\r\n", " ").replace("\n", " ").strip()
                    if len(preview) > 50:
                        preview = preview[:47] + "..."
                    self.ui_callbacks["log"](f"[>> TO PHONE] ({len(current_text)} chars): {preview}")
                    await self.broadcast_text(current_text)
            except Exception:
                pass
            await asyncio.sleep(0.3)

    async def _async_main(self):
        async with websockets.serve(self.register_client, "0.0.0.0", WS_PORT):
            self.ui_callbacks["log"](f"[*] WebSocket server listening on ws://{self.local_ip}:{WS_PORT}")
            self.ui_callbacks["log"](f"[*] UDP Wi-Fi discovery active on port {DISCOVERY_PORT}")
            self.ui_callbacks["log"]("[*] Bidirectional sync active (PC <-> Phone)")
            await self.clipboard_monitor()

    def run_async_server(self):
        self.loop = asyncio.new_event_loop()
        asyncio.set_event_loop(self.loop)
        try:
            self.loop.run_until_complete(self._async_main())
        except Exception as e:
            self.ui_callbacks["log"](f"Server loop error: {e}")
        finally:
            try:
                self.loop.close()
            except Exception:
                pass

    def start(self):
        # 1. Start UDP Discovery thread
        self.discovery_thread = threading.Thread(target=self.run_udp_discovery, daemon=True)
        self.discovery_thread.start()

        # 2. Start WebSocket + Clipboard async loop thread
        self.server_thread = threading.Thread(target=self.run_async_server, daemon=True)
        self.server_thread.start()

    def stop(self):
        self.stop_event.set()
        if self.loop and self.loop.is_running():
            self.loop.call_soon_threadsafe(self.loop.stop)


class TextCastAppUI:
    def __init__(self, root: tk.Tk):
        self.root = root
        self.root.title("TextCast Server - Bidirectional Clipboard Sync")
        self.root.geometry("560x650")
        self.root.minsize(500, 560)
        self.root.configure(bg="#161722")

        # Color palette
        self.bg_color = "#161722"
        self.card_bg = "#212338"
        self.card_border = "#2F324E"
        self.accent_color = "#00ADB5"
        self.text_primary = "#F1F2F6"
        self.text_secondary = "#9AA0B8"
        self.green_color = "#00E676"

        self.server = TextCastServer({
            "log": self.log_from_thread,
            "update_clients": self.update_clients_from_thread,
        })

        self.autostart_var = tk.BooleanVar(value=is_autostart_enabled())
        self.client_count_var = tk.StringVar(value="0 devices connected")
        self.clients_list_var = tk.StringVar(value="Waiting for Android devices to connect...")

        self.build_ui()
        self.setup_tray()

        # Intercept window close button ('X') -> minimize to notification area
        self.root.protocol("WM_DELETE_WINDOW", self.hide_to_tray)

        # Start server background threads
        self.server.start()
        self.log(f"TextCast started on {self.server.hostname} ({self.server.local_ip})")

    def build_ui(self):
        # Header banner
        header = tk.Frame(self.root, bg="#1B1D2E", height=70, padx=20, pady=12)
        header.pack(fill="x", side="top")

        title_frame = tk.Frame(header, bg="#1B1D2E")
        title_frame.pack(side="left")

        title_lbl = tk.Label(
            title_frame,
            text="TextCast Server",
            font=("Segoe UI", 16, "bold"),
            fg=self.text_primary,
            bg="#1B1D2E",
        )
        title_lbl.pack(anchor="w")

        sub_lbl = tk.Label(
            title_frame,
            text="2-Way Clipboard Sync: PC <-> Android Phone",
            font=("Segoe UI", 9),
            fg=self.text_secondary,
            bg="#1B1D2E",
        )
        sub_lbl.pack(anchor="w")

        status_badge = tk.Frame(header, bg="#15362E", padx=10, pady=4)
        status_badge.pack(side="right")
        tk.Label(
            status_badge,
            text="● 2-Way Sync Active",
            font=("Segoe UI", 10, "bold"),
            fg=self.green_color,
            bg="#15362E",
        ).pack()

        # Container frame
        container = tk.Frame(self.root, bg=self.bg_color, padx=18, pady=12)
        container.pack(fill="both", expand=True)

        # Card 1: Network & Connection Info
        card1 = self.create_card(container)
        card1.pack(fill="x", pady=(0, 10))

        tk.Label(
            card1,
            text="NETWORK & DISCOVERY",
            font=("Segoe UI", 8, "bold"),
            fg=self.accent_color,
            bg=self.card_bg,
        ).pack(anchor="w")

        ip_row = tk.Frame(card1, bg=self.card_bg, pady=4)
        ip_row.pack(fill="x")

        tk.Label(
            ip_row,
            text="PC IPv4 Address:",
            font=("Segoe UI", 10),
            fg=self.text_secondary,
            bg=self.card_bg,
        ).pack(side="left")

        ip_val = tk.Label(
            ip_row,
            text=self.server.local_ip,
            font=("Consolas", 13, "bold"),
            fg="#FFFFFF",
            bg=self.card_bg,
            padx=8,
        )
        ip_val.pack(side="left")

        copy_btn = tk.Button(
            ip_row,
            text="Copy IP",
            font=("Segoe UI", 8),
            bg="#2E3352",
            fg="#FFFFFF",
            activebackground=self.accent_color,
            activeforeground="#FFFFFF",
            relief="flat",
            padx=8,
            pady=2,
            cursor="hand2",
            command=self.copy_ip_to_clipboard,
        )
        copy_btn.pack(side="right")

        details_row = tk.Frame(card1, bg=self.card_bg, pady=2)
        details_row.pack(fill="x")
        tk.Label(
            details_row,
            text=f"PC Name: {self.server.hostname}  •  WebSocket Port: {WS_PORT}  •  Auto-Discovery: Active",
            font=("Segoe UI", 9),
            fg=self.text_secondary,
            bg=self.card_bg,
        ).pack(anchor="w")

        # Card 2: Connected Devices
        card2 = self.create_card(container)
        card2.pack(fill="x", pady=(0, 10))

        tk.Label(
            card2,
            text="CONNECTED ANDROID DEVICES",
            font=("Segoe UI", 8, "bold"),
            fg=self.accent_color,
            bg=self.card_bg,
        ).pack(anchor="w")

        tk.Label(
            card2,
            textvariable=self.client_count_var,
            font=("Segoe UI", 11, "bold"),
            fg=self.text_primary,
            bg=self.card_bg,
            pady=2,
        ).pack(anchor="w")

        tk.Label(
            card2,
            textvariable=self.clients_list_var,
            font=("Consolas", 9),
            fg=self.text_secondary,
            bg=self.card_bg,
        ).pack(anchor="w")

        # Card 3: Launch at Startup Toggle
        card3 = self.create_card(container)
        card3.pack(fill="x", pady=(0, 10))

        tk.Label(
            card3,
            text="STARTUP PREFERENCE",
            font=("Segoe UI", 8, "bold"),
            fg=self.accent_color,
            bg=self.card_bg,
        ).pack(anchor="w")

        startup_check = tk.Checkbutton(
            card3,
            text="Launch TextCast automatically on Windows startup",
            variable=self.autostart_var,
            font=("Segoe UI", 10),
            fg=self.text_primary,
            bg=self.card_bg,
            selectcolor="#1B1D2E",
            activebackground=self.card_bg,
            activeforeground=self.text_primary,
            command=self.on_toggle_startup,
            cursor="hand2",
        )
        startup_check.pack(anchor="w", pady=(4, 2))

        tk.Label(
            card3,
            text="When enabled, TextCast runs in notification area when Windows boots.",
            font=("Segoe UI", 8),
            fg=self.text_secondary,
            bg=self.card_bg,
        ).pack(anchor="w")

        # Card 4: Activity Log
        card4 = self.create_card(container)
        card4.pack(fill="both", expand=True, pady=(0, 10))

        log_hdr = tk.Frame(card4, bg=self.card_bg)
        log_hdr.pack(fill="x", pady=(0, 4))
        tk.Label(
            log_hdr,
            text="LIVE 2-WAY SYNC ACTIVITY LOG",
            font=("Segoe UI", 8, "bold"),
            fg=self.accent_color,
            bg=self.card_bg,
        ).pack(side="left")

        clear_log_btn = tk.Button(
            log_hdr,
            text="Clear",
            font=("Segoe UI", 8),
            bg="#2E3352",
            fg=self.text_secondary,
            relief="flat",
            padx=6,
            pady=1,
            cursor="hand2",
            command=self.clear_log,
        )
        clear_log_btn.pack(side="right")

        self.log_text = tk.Text(
            card4,
            bg="#161722",
            fg="#AAB0CC",
            font=("Consolas", 9),
            relief="flat",
            wrap="word",
            height=8,
            padx=8,
            pady=8,
        )
        self.log_text.pack(fill="both", expand=True)

        # Bottom Action Bar
        bottom_bar = tk.Frame(self.root, bg="#1B1D2E", padx=20, pady=10)
        bottom_bar.pack(fill="x", side="bottom")

        hide_btn = tk.Button(
            bottom_bar,
            text="Hide to Notification Area",
            font=("Segoe UI", 9, "bold"),
            bg="#00ADB5",
            fg="#FFFFFF",
            activebackground="#008B91",
            activeforeground="#FFFFFF",
            relief="flat",
            padx=14,
            pady=6,
            cursor="hand2",
            command=self.hide_to_tray,
        )
        hide_btn.pack(side="left")

        quit_btn = tk.Button(
            bottom_bar,
            text="Exit Server",
            font=("Segoe UI", 9),
            bg="#3F252E",
            fg="#FF7A8A",
            activebackground="#4E2E38",
            activeforeground="#FF9AA6",
            relief="flat",
            padx=14,
            pady=6,
            cursor="hand2",
            command=self.quit_app,
        )
        quit_btn.pack(side="right")

    def create_card(self, parent):
        return tk.Frame(
            parent,
            bg=self.card_bg,
            highlightbackground=self.card_border,
            highlightthickness=1,
            padx=14,
            pady=10,
        )

    def copy_ip_to_clipboard(self):
        pyperclip.copy(self.server.local_ip)
        self.log(f"Copied PC IP address ({self.server.local_ip}) to clipboard.")

    def on_toggle_startup(self):
        enabled = self.autostart_var.get()
        success = set_autostart(enabled)
        if success:
            state_str = "enabled" if enabled else "disabled"
            self.log(f"Windows startup launch {state_str}.")
        else:
            self.log("Failed to update Windows startup registry.")

    def log_from_thread(self, message: str):
        try:
            self.root.after(0, lambda: self.log(message))
        except Exception:
            pass

    def log(self, message: str):
        try:
            now = datetime.now().strftime("%H:%M:%S")
            line = f"[{now}] {message}\n"
            self.log_text.insert("end", line)
            self.log_text.see("end")
        except Exception:
            pass

    def clear_log(self):
        self.log_text.delete("1.0", "end")

    def update_clients_from_thread(self, client_ips: list):
        try:
            self.root.after(0, lambda: self.update_clients(client_ips))
        except Exception:
            pass

    def update_clients(self, client_ips: list):
        count = len(client_ips)
        if count == 0:
            self.client_count_var.set("0 devices connected")
            self.clients_list_var.set("Waiting for Android devices to connect...")
        else:
            self.client_count_var.set(f"{count} device{'s' if count > 1 else ''} connected")
            self.clients_list_var.set("Active: " + ", ".join(client_ips))

    def hide_to_tray(self):
        self.root.withdraw()

    def show_window(self, icon=None, item=None):
        self.root.after(0, self._restore_window)

    def _restore_window(self):
        self.root.deiconify()
        self.root.lift()
        self.root.focus_force()

    def setup_tray(self):
        tray_image = create_tray_image()
        menu = pystray.Menu(
            pystray.MenuItem("Open TextCast", self.show_window, default=True),
            pystray.MenuItem(
                "Launch at Startup",
                self.tray_toggle_startup,
                checked=lambda item: is_autostart_enabled(),
            ),
            pystray.Menu.SEPARATOR,
            pystray.MenuItem("Exit TextCast", self.tray_quit),
        )
        self.tray_icon = pystray.Icon(
            "TextCast",
            tray_image,
            f"TextCast Server ({self.server.local_ip}:{WS_PORT})",
            menu=menu,
        )
        self.tray_icon.run_detached()

    def tray_toggle_startup(self, icon, item):
        new_val = not is_autostart_enabled()
        set_autostart(new_val)
        self.root.after(0, lambda: self.autostart_var.set(new_val))
        self.log(f"Windows startup launch {'enabled' if new_val else 'disabled'}.")

    def tray_quit(self, icon=None, item=None):
        self.root.after(0, self.quit_app)

    def quit_app(self):
        try:
            self.server.stop()
        except Exception:
            pass
        try:
            if hasattr(self, "tray_icon"):
                self.tray_icon.stop()
        except Exception:
            pass
        self.root.destroy()
        sys.exit(0)


def main():
    root = tk.Tk()
    app = TextCastAppUI(root)

    # By default, as requested by user:
    # "when i run the exe it will go to notification are of taskbar and run in background"
    # Hide window immediately unless --show / --gui is passed.
    if "--show" not in sys.argv and "--gui" not in sys.argv:
        root.withdraw()
    else:
        root.deiconify()

    root.mainloop()


if __name__ == "__main__":
    try:
        main()
    except Exception as e:
        log_exception(*sys.exc_info())
        try:
            messagebox.showerror("TextCast Error", f"Fatal error starting TextCast:\n{e}")
        except Exception:
            pass
