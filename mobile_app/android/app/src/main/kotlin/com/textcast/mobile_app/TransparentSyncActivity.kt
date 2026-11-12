package com.textcast.mobile_app

import android.app.Activity
import android.content.ClipboardManager
import android.content.Context
import android.os.Bundle
import android.util.Log
import android.widget.Toast
import org.json.JSONObject
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.InetAddress
import kotlin.concurrent.thread

class TransparentSyncActivity : Activity() {

    private val tag = "TransparentSync"

    override fun onCreate(savedInstanceState: Bundle?) {
        overridePendingTransition(0, 0)
        super.onCreate(savedInstanceState)

        try {
            val cm = getSystemService(Context.CLIPBOARD_SERVICE) as? ClipboardManager
            val clip = cm?.primaryClip
            if (clip != null && clip.itemCount > 0) {
                val text = clip.getItemAt(0)?.text?.toString()?.trim() ?: ""
                if (text.isNotEmpty()) {
                    sendTextToPc(text)
                }
            }
        } catch (e: Exception) {
            Log.e(tag, "Error reading clip in transparent activity: ${e.message}")
        } finally {
            finish()
            overridePendingTransition(0, 0)
        }
    }

    private fun sendTextToPc(text: String) {
        val prefs = getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
        val pcIp = prefs.getString("flutter.pc_server_ip", null)?.trim() ?: return

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
            } catch (e: Exception) {
                Log.e(tag, "UDP send error: ${e.message}")
            }
        }

        val preview = if (text.length > 30) text.substring(0, 27) + "..." else text
        Toast.makeText(applicationContext, "Synced to PC: \"$preview\"", Toast.LENGTH_SHORT).show()
    }
}

