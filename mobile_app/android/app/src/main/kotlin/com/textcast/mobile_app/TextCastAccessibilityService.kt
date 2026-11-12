package com.textcast.mobile_app

import android.accessibilityservice.AccessibilityService
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.graphics.PixelFormat
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.view.Gravity
import android.view.View
import android.view.WindowManager
import android.view.accessibility.AccessibilityEvent
import android.widget.Toast
import org.json.JSONObject
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.InetAddress
import kotlin.concurrent.thread

class TextCastAccessibilityService : AccessibilityService(), ClipboardManager.OnPrimaryClipChangedListener {

    private val tag = "TextCastService"
    private var clipboardManager: ClipboardManager? = null
    private var lastSyncedText: String = ""
    private val mainHandler = Handler(Looper.getMainLooper())

    override fun onServiceConnected() {
        super.onServiceConnected()
        clipboardManager = getSystemService(Context.CLIPBOARD_SERVICE) as? ClipboardManager
        clipboardManager?.addPrimaryClipChangedListener(this)
        Log.i(tag, "TextCast Accessibility Service connected and listening for clipboard changes")
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        if (event == null) return

        // Intercept when user clicks copy or changes focus
        if (event.eventType == AccessibilityEvent.TYPE_VIEW_CLICKED ||
            event.eventType == AccessibilityEvent.TYPE_VIEW_TEXT_SELECTION_CHANGED ||
            event.eventType == AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED) {
            checkAndSyncClipboard()
        }
    }

    override fun onInterrupt() {
        Log.w(tag, "TextCast Accessibility Service interrupted")
    }

    override fun onPrimaryClipChanged() {
        checkAndSyncClipboard()
    }

    private fun checkAndSyncClipboard() {
        mainHandler.post {
            var text = tryReadDirectClipboard()

            // If null/empty due to Android 10+ background focus restriction, try overlay focus
            if (text.isEmpty()) {
                text = tryReadWithOverlay()
            }

            // If still empty, trigger transparent activity to gain instantaneous window focus
            if (text.isEmpty()) {
                try {
                    val intent = Intent(this, TransparentSyncActivity::class.java).apply {
                        addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        addFlags(Intent.FLAG_ACTIVITY_NO_ANIMATION)
                    }
                    startActivity(intent)
                } catch (e: Exception) {
                    Log.e(tag, "Failed to start TransparentSyncActivity: ${e.message}")
                }
                return@post
            }

            if (text.isNotEmpty() && text != lastSyncedText) {
                lastSyncedText = text
                sendTextToPc(text)
            }
        }
    }

    private fun tryReadDirectClipboard(): String {
        return try {
            val clip = clipboardManager?.primaryClip
            if (clip != null && clip.itemCount > 0) {
                clip.getItemAt(0)?.text?.toString()?.trim() ?: ""
            } else ""
        } catch (_: Exception) {
            ""
        }
    }

    private fun tryReadWithOverlay(): String {
        val wm = getSystemService(Context.WINDOW_SERVICE) as? WindowManager ?: return ""
        val view = View(this)
        val params = WindowManager.LayoutParams(
            0, 0,
            WindowManager.LayoutParams.TYPE_ACCESSIBILITY_OVERLAY,
            WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL,
            PixelFormat.TRANSLUCENT
        ).apply {
            gravity = Gravity.TOP or Gravity.START
        }

        var result = ""
        try {
            wm.addView(view, params)
            view.isFocusable = true
            view.isFocusableInTouchMode = true
            view.requestFocus()

            val clip = clipboardManager?.primaryClip
            if (clip != null && clip.itemCount > 0) {
                result = clip.getItemAt(0)?.text?.toString()?.trim() ?: ""
            }
        } catch (e: Exception) {
            Log.e(tag, "Overlay focus read failed: ${e.message}")
        } finally {
            try {
                wm.removeView(view)
            } catch (_: Exception) {}
        }
        return result
    }

    private fun sendTextToPc(text: String) {
        val prefs = getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
        val pcIp = prefs.getString("flutter.pc_server_ip", null)?.trim()

        if (pcIp.isNullOrEmpty()) {
            Log.w(tag, "PC IP address not found in preferences")
            return
        }

        thread {
            try {
                val payload = JSONObject().apply {
                    put("cmd", "CLIPBOARD")
                    put("text", text)
                }.toString()

                val bytes = payload.toByteArray(Charsets.UTF_8)
                val address = InetAddress.getByName(pcIp)
                val socket = DatagramSocket()
                val packet = DatagramPacket(bytes, bytes.size, address, 8766)
                socket.send(packet)
                socket.close()

                mainHandler.post {
                    val preview = if (text.length > 30) text.substring(0, 27) + "..." else text
                    Toast.makeText(applicationContext, "Synced to PC: \"$preview\"", Toast.LENGTH_SHORT).show()
                }
                Log.i(tag, "Successfully sent clipboard to PC ($pcIp:8766): $text")
            } catch (e: Exception) {
                Log.e(tag, "Error sending UDP packet to PC: ${e.message}")
            }
        }
    }

    override fun onDestroy() {
        clipboardManager?.removePrimaryClipChangedListener(this)
        super.onDestroy()
    }
}
