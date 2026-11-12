package com.textcast.mobile_app

import android.app.Activity
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.os.Bundle
import android.widget.Toast
import org.json.JSONObject
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.InetAddress
import kotlin.concurrent.thread

class ProcessTextActivity : Activity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        val selectedText = intent.getCharSequenceExtra(Intent.EXTRA_PROCESS_TEXT)?.toString()?.trim()

        if (!selectedText.isNullOrEmpty()) {
            // 1. Copy to phone clipboard
            try {
                val clipboard = getSystemService(Context.CLIPBOARD_SERVICE) as? ClipboardManager
                clipboard?.setPrimaryClip(ClipData.newPlainText("TextCast", selectedText))
            } catch (_: Exception) {}

            // 2. Send to PC over UDP
            val prefs = getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
            val pcIp = prefs.getString("flutter.pc_server_ip", null)?.trim()

            if (!pcIp.isNullOrEmpty()) {
                thread {
                    try {
                        val payload = JSONObject().apply {
                            put("cmd", "CLIPBOARD")
                            put("text", selectedText)
                        }.toString()

                        val bytes = payload.toByteArray(Charsets.UTF_8)
                        val address = InetAddress.getByName(pcIp)
                        val socket = DatagramSocket()
                        val packet = DatagramPacket(bytes, bytes.size, address, 8766)
                        socket.send(packet)
                        socket.close()
                    } catch (_: Exception) {}
                }

                val preview = if (selectedText.length > 30) selectedText.substring(0, 27) + "..." else selectedText
                Toast.makeText(this, "Copied to PC: \"$preview\"", Toast.LENGTH_SHORT).show()
            } else {
                Toast.makeText(this, "Connect TextCast to PC first", Toast.LENGTH_SHORT).show()
            }
        }

        finish()
    }
}

