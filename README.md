# TextCast - Bidirectional Wi-Fi Clipboard Sync

An end-to-end local Wi-Fi clipboard synchronization system connecting Windows PC to Android devices with **zero-configuration automatic Wi-Fi discovery**, **system tray background execution**, and **system-wide automatic copy from all apps**.

---

## Highlights & Features

- **Automatic Background Copy from ANY App:**
  - **No manual button clicking required:** When enabled, whenever you copy text in **Chrome, WhatsApp, Telegram, Notes, Instagram, etc.**, it is automatically detected and beamed straight to your PC clipboard in the background!
  - **Accessibility Service:** Android 10+ restricts background apps from reading clipboard data silently. TextCast includes a dedicated, lightweight `TextCastAccessibilityService` that catches copy events across all apps and pushes them directly to the PC.
  - **Context Menu "Copy to PC":** Whenever you select/highlight text in any app, a **"Copy to PC"** action appears directly in the system text context menu (alongside Cut/Copy/Paste).
- **Instant Connect & Auto-Sync on App Open:**
  - Upon opening TextCast, the app connects automatically and instantly syncs whatever is already on your phone's clipboard to your PC without you needing to press any button.
- **PC ➔ Phone Sync:**
  - Press `Ctrl+C` on your PC $\rightarrow$ text is immediately pushed via WebSocket to your phone and copied to the Android clipboard.
- **Automatic Wi-Fi Discovery:**
  - Scans local Wi-Fi via UDP beacons/probes (port `8766`). Discovered PCs appear automatically with a 1-tap **Connect** button.
- **System Tray Background Execution (`.exe`):**
  - Standalone compiled executable runs silently in the Windows taskbar notification area (System Tray) with zero command-prompt windows flashing.
- **Launch at Windows Startup:**
  - Toggle in the dashboard UI and tray menu registers TextCast in the Windows Registry (`HKCU\Software\Microsoft\Windows\CurrentVersion\Run`).

---

## How to Enable System-Wide Auto-Copy on Android

Because Android 10+ blocks background apps from reading your clipboard for privacy reasons, follow this **one-time 5-second setup**:

1. Open **TextCast** on your phone.
2. In the connected PC card, look for the card: **"Auto-Copy from Any App"** $\rightarrow$ tap **Enable**.
3. Android's **Accessibility** settings will open:
   - Find and tap **TextCast** (under Installed Services / Apps).
   - Turn the switch **ON** and tap **Allow**.
4. That's it! Now whenever you copy any text anywhere on your phone (in a browser, chat app, document, etc.), it will **instantly sync to your PC clipboard** automatically. Just press `Ctrl+V` on your PC to paste!

---

## Project Structure

```text
D:\Safayet\Personal\flutter\textcast\
├── pc_server/
│   ├── clipboard_server.py      # Bidirectional server + UDP Discovery + UDP Auto-Copy listener
│   ├── clipboard_server.spec    # PyInstaller windowed spec with custom icon
│   ├── icon.ico / icon.png      # Application & tray icons
│   └── dist/
│       └── clipboard_server.exe # Standalone Windows executable with UI & Tray
├── mobile_app/
│   ├── lib/
│   │   └── main.dart            # Flutter client with auto-sync & accessibility integration
│   └── android/app/src/main/
│       ├── kotlin/.../
│       │   ├── MainActivity.kt                  # MethodChannel for Accessibility check/open
│       │   ├── TextCastAccessibilityService.kt  # System-wide copy interceptor & UDP sender
│       │   └── ProcessTextActivity.kt           # Context menu "Copy to PC" action
│       └── AndroidManifest.xml                  # Service & process-text declarations
├── run_pc_server.bat            # 1-Click launcher for PC server
└── TextCast.apk                 # Ready-to-install Android release APK
```
