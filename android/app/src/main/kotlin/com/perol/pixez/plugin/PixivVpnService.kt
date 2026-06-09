package com.perol.pixez.plugin

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Intent
import android.net.VpnService
import android.os.Build
import android.os.ParcelFileDescriptor
import android.util.Log
import androidx.core.app.NotificationCompat
import com.perol.pixez.MainActivity
import kotlinx.coroutines.*
import java.io.*
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.Socket
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.ConcurrentHashMap

/**
 * Pixiv SNI 嗅探 VPN 服务
 *
 * 不劫持 DNS，直接读取 TLS ClientHello 的 SNI 字段。
 * 命中 *.pixiv.net → 转发到 LoginProxy HTTPS
 * 其他 → 直通系统网络
 */
class PixivVpnService : VpnService() {

    companion object {
        const val ACTION_STOP = "com.perol.pixez.STOP_VPN"
        const val CHANNEL_ID = "pixiv_vpn_channel"
        const val NOTIFICATION_ID = 1001
        const val VPN_ADDRESS = "10.0.0.2"
        const val LOCAL_PROXY = "127.0.0.1"
        const val PROXY_PORT = 8443
    }

    private data class TcpSession(
        val srcIp: Int,
        val srcPort: Int,
        val dstIp: Int,
        val dstPort: Int,
        var state: Int = SYN_SENT,
        var clientSeq: Long = 0,
        var clientAck: Long = 0,
        var serverSeq: Long = 0,
        var serverAck: Long = 0,
        val buf: ByteArrayOutputStream = ByteArrayOutputStream(), // 缓存 ClientHello
        var upstreamSocket: Socket? = null,
        var upstreamOut: OutputStream? = null,
        var upstreamIn: InputStream? = null,
        var sni: String? = null,           // 解析到的 SNI
        var resolved: Boolean = false,     // 是否已确定转发目标
        var lastActivity: Long = System.currentTimeMillis()
    ) {
        companion object {
            const val SYN_SENT = 0
            const val SYN_ACKED = 1
            const val ESTABLISHED = 2
            const val CLOSING = 3
        }
    }

    private var tunInput: FileInputStream? = null
    private var tunOutput: FileOutputStream? = null
    private var tunFd: ParcelFileDescriptor? = null
    private var isRunning = false
    private val scope = CoroutineScope(Dispatchers.IO + SupervisorJob())
    private val sessions = ConcurrentHashMap<String, TcpSession>()
    private var packetId = 0L

    private fun sessionKey(srcIp: Int, srcPort: Int) = "${srcIp.toIPv4()}:$srcPort"

    // ============ 生命周期 ============

    override fun onCreate() { super.onCreate(); createNotificationChannel() }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) { stopVpn(); return START_NOT_STICKY }
        startForeground(NOTIFICATION_ID, buildNotification())
        startVpn(); return START_STICKY
    }

    override fun onRevoke() { stopVpn(); super.onRevoke() }
    override fun onDestroy() { stopVpn(); super.onDestroy() }

    private fun startVpn() {
        if (isRunning) return
        Log.d("PixivVPN", "startVpn...")
        val builder = Builder().setSession("PixEz VPN")
            .addAddress(VPN_ADDRESS, 32).addRoute("0.0.0.0", 0)
            .addDnsServer("1.1.1.1").setMtu(1500).setBlocking(true)
        tunFd = builder.establish()
        if (tunFd == null) { Log.e("PixivVPN", "establish returned null"); stopSelf(); return }
        tunInput = FileInputStream(tunFd!!.fileDescriptor)
        tunOutput = FileOutputStream(tunFd!!.fileDescriptor)
        isRunning = true
        Log.d("PixivVPN", "TUN OK, starting loop")
        scope.launch { processPackets() }
        scope.launch { cleanupSessions() }
    }

    private fun stopVpn() {
        isRunning = false; scope.cancel()
        sessions.values.forEach { closeSession(it) }; sessions.clear()
        try { tunInput?.close() } catch (_: Exception) {}
        try { tunOutput?.close() } catch (_: Exception) {}
        try { tunFd?.close() } catch (_: Exception) {}
        stopForeground(STOP_FOREGROUND_REMOVE); stopSelf()
    }

    // ============ 主循环 ============

    private fun processPackets() {
        val buf = ByteArray(32767)
        Log.d("PixivVPN", "loop started")
        try {
            while (isRunning) {
                val n = try { tunInput?.read(buf) ?: -1 } catch (_: Exception) { -1 }
                if (n <= 0) continue
                packetId++
                if ((buf[0].toInt() shr 4) != 4) continue // IPv4 only

                val ipHdr = (buf[0].toInt() and 0x0F) * 4
                if (ipHdr < 20 || n < ipHdr) continue
                val proto = buf[9].toInt() and 0xFF
                val srcIp = buf.getIntAt(12)
                val dstIp = buf.getIntAt(16)

                if (proto == 6) handleTcpPacket(buf, n, ipHdr, srcIp, dstIp)
                // UDP packets: let them pass through (no interception)
            }
        } catch (e: Exception) { Log.e("PixivVPN", "loop error: ${e.message}") }
        Log.d("PixivVPN", "loop ended, packets=$packetId")
    }

    // ============ TCP 处理 ============

    private fun handleTcpPacket(pkt: ByteArray, len: Int, ipHdr: Int, srcIp: Int, dstIp: Int) {
        val flags = pkt[ipHdr + 13].toInt() and 0xFF
        val srcPort = pkt.getUShortAt(ipHdr)
        val dstPort = pkt.getUShortAt(ipHdr + 2)
        val seq = pkt.getUIntAt(ipHdr + 4)
        val ack = pkt.getUIntAt(ipHdr + 8)
        val tcpHdrLen = ((pkt[ipHdr + 12].toInt() shr 4) and 0x0F) * 4
        val payloadLen = len - ipHdr - tcpHdrLen
        val key = sessionKey(srcIp, srcPort)
        val existing = sessions[key]

        // 只关心 TCP:443（HTTPS），非 443 直通
        if (dstPort != 443 && dstPort != 8443) return

        if (flags and 0x02 != 0 && existing == null) {
            // SYN → 创建会话
            val s = TcpSession(srcIp, srcPort, dstIp, dstPort,
                clientSeq = seq + 1, clientAck = seq + 1,
                serverSeq = (Math.random() * 0x3FFFFFFF).toLong())
            sessions[key] = s
            // SYN-ACK
            sendTcpPkt(dstIp, srcIp, dstPort, srcPort, s.serverSeq, s.clientSeq, 0x12, null)
            s.serverSeq++
            Log.d("PixivVPN", "SYN ${srcIp.toIPv4()}:$srcPort → ${dstIp.toIPv4()}:$dstPort")
            return
        }

        if (existing == null) return
        existing.lastActivity = System.currentTimeMillis()

        if (flags and 0x10 != 0 && payloadLen > 0) {
            // PSH|ACK → 数据
            val dataOff = ipHdr + tcpHdrLen
            existing.buf.write(pkt, dataOff, payloadLen)
            existing.clientSeq = seq + payloadLen
            existing.clientAck = ack
            sendTcpPkt(dstIp, srcIp, dstPort, srcPort, existing.serverSeq, existing.clientSeq, 0x10, null)
            existing.serverAck = existing.clientSeq

            // 未解析 SNI 时尝试解析
            if (!existing.resolved) {
                tryParseSni(existing)
            }

            // 已解析的，转发数据到上游
            if (existing.resolved && existing.upstreamOut != null) {
                try {
                    existing.upstreamOut!!.write(pkt, dataOff, payloadLen)
                    existing.upstreamOut!!.flush()
                } catch (_: Exception) { closeSession(existing) }
            }
            return
        }

        if (flags and 0x01 != 0 || flags and 0x04 != 0) {
            // FIN/RST → 关闭
            sendTcpPkt(dstIp, srcIp, dstPort, srcPort, existing.serverSeq, existing.clientSeq, 0x11, null)
            closeSession(existing)
        }
    }

    // ============ SNI 嗅探 ============

    private fun tryParseSni(session: TcpSession) {
        val data = session.buf.toByteArray()
        if (data.size < 5) return
        // TLS record: type(1) + version(2) + length(2)
        if (data[0].toInt() != 0x16) return // not Handshake
        val tlsLen = ((data[3].toInt() and 0xFF) shl 8) or (data[4].toInt() and 0xFF)
        if (data.size < 5 + tlsLen || tlsLen < 4) return

        // ClientHello: type(1) + length(3) + version(2) + random(32) + sessionID(1)
        var pos = 5 + 1 + 3 + 2 + 32 // skip to sessionID length
        if (pos + 1 > data.size) return
        val sidLen = data[pos].toInt() and 0xFF; pos += 1 + sidLen // skip sessionID
        if (pos + 2 > data.size) return
        val cipherLen = ((data[pos].toInt() and 0xFF) shl 8) or (data[pos + 1].toInt() and 0xFF)
        pos += 2 + cipherLen // skip cipher suites
        if (pos + 1 > data.size) return
        val compLen = data[pos].toInt() and 0xFF; pos += 1 + compLen // skip compression
        if (pos + 2 > data.size) return
        val extLen = ((data[pos].toInt() and 0xFF) shl 8) or (data[pos + 1].toInt() and 0xFF)
        pos += 2; val extEnd = pos + extLen

        while (pos + 4 <= extEnd && pos + 4 <= data.size) {
            val extType = ((data[pos].toInt() and 0xFF) shl 8) or (data[pos + 1].toInt() and 0xFF)
            val extDataLen = ((data[pos + 2].toInt() and 0xFF) shl 8) or (data[pos + 3].toInt() and 0xFF)
            pos += 4

            if (extType == 0x0000) { // SNI extension
                if (pos + 3 > extEnd || pos + 3 > data.size) break
                // sni list length(2) + entry type(1) + name length(2)
                val sniNameLen = ((data[pos + 3].toInt() and 0xFF) shl 8) or (data[pos + 4].toInt() and 0xFF)
                pos += 5
                if (pos + sniNameLen <= extEnd && pos + sniNameLen <= data.size) {
                    session.sni = String(data, pos, sniNameLen)
                    Log.d("PixivVPN", "SNI: ${session.sni}")
                    resolveSession(session)
                    return
                }
            }
            pos += extDataLen
        }
        // Couldn't find SNI, mark as resolved but non-pixiv
        if (!session.resolved) {
            session.resolved = true
            session.sni = "*"
            // Forward to real destination
            resolveSession(session)
        }
    }

    private fun resolveSession(session: TcpSession) {
        val sni = session.sni ?: ""
        session.resolved = true

        if (sni.endsWith(".pixiv.net") || sni == "pixiv.net") {
            // Pixiv → 本地代理
            Log.d("PixivVPN", "Pixiv: $sni → 127.0.0.1:$PROXY_PORT")
            try {
                val sock = Socket()
                sock.connect(InetSocketAddress(LOCAL_PROXY, PROXY_PORT), 3000)
                session.upstreamSocket = sock
                session.upstreamOut = sock.getOutputStream()
                session.upstreamIn = sock.getInputStream()
                // 启动上游读取协程
                scope.launch { relayFromUpstream(session) }
                // 发送缓存的 ClientHello
                val buf = session.buf.toByteArray()
                if (buf.isNotEmpty()) {
                    session.upstreamOut!!.write(buf)
                    session.upstreamOut!!.flush()
                    Log.d("PixivVPN", "Forwarded ${buf.size} bytes for $sni")
                }
            } catch (e: Exception) {
                Log.e("PixivVPN", "Connect proxy failed: ${e.message}")
                closeSession(session)
            }
        } else {
            // 非 Pixiv → 直通真实网络（TODO）
            // 简化：关闭连接，让其走系统栈
            Log.d("PixivVPN", "Non-pixiv: $sni, closing")
            closeSession(session)
        }
    }

    private suspend fun relayFromUpstream(session: TcpSession) {
        val buf = ByteArray(16384)
        try {
            while (isRunning && sessions.containsValue(session)) {
                val n = session.upstreamIn?.read(buf) ?: -1
                if (n <= 0) break
                sendTcpPkt(session.dstIp, session.srcIp, session.dstPort, session.srcPort,
                    session.serverSeq, session.clientSeq, 0x18, buf.copyOf(n))
                session.serverSeq += n
            }
        } catch (_: Exception) {}
        closeSession(session)
    }

    // ============ TCP 包构造 ============

    private var idCounter = 0L

    private fun sendTcpPkt(srcIp: Int, dstIp: Int, srcPort: Int, dstPort: Int,
                           seq: Long, ack: Long, flags: Int, data: ByteArray?) {
        val payload = data ?: ByteArray(0)
        val total = 40 + payload.size
        val pkt = ByteArray(total)
        pkt[0] = 0x45.toByte()
        pkt.setUShortAt(2, total)
        pkt.setUShortAt(4, (idCounter++ % 65535).toInt())
        pkt[6] = 0x40.toByte(); pkt[8] = 64.toByte(); pkt[9] = 6.toByte()
        pkt.setIntAt(12, srcIp); pkt.setIntAt(16, dstIp)
        // IP checksum
        var ipSum = 0L
        for (i in 0 until 20 step 2) { if (i != 10) ipSum += pkt.getUShortAt(i).toLong() }
        ipSum = (ipSum shr 16) + (ipSum and 0xFFFF)
        ipSum += (ipSum shr 16)
        pkt.setUShortAt(10, (ipSum.toInt() and 0xFFFF).inv() and 0xFFFF)

        val tcpOff = 20
        pkt.setUShortAt(tcpOff, srcPort); pkt.setUShortAt(tcpOff + 2, dstPort)
        pkt.setUIntAt(tcpOff + 4, seq); pkt.setUIntAt(tcpOff + 8, ack)
        pkt[tcpOff + 12] = 0x50.toByte(); pkt[tcpOff + 13] = flags.toByte()
        pkt.setUShortAt(tcpOff + 14, 65535)
        if (payload.isNotEmpty()) System.arraycopy(payload, 0, pkt, tcpOff + 20, payload.size)

        // TCP checksum
        val tcpLen = 20 + payload.size
        val ckBuf = ByteBuffer.allocate(12 + (if (tcpLen % 2 != 0) tcpLen + 1 else tcpLen)).order(ByteOrder.BIG_ENDIAN)
        ckBuf.putInt(srcIp); ckBuf.putInt(dstIp)
        ckBuf.put(0); ckBuf.put(6.toByte()); ckBuf.putShort(tcpLen.toShort())
        ckBuf.put(pkt, tcpOff, tcpLen)
        if (tcpLen % 2 != 0) ckBuf.put(0)
        ckBuf.flip()
        var sum = 0L
        while (ckBuf.remaining() > 1) sum += (ckBuf.getShort().toInt() and 0xFFFF).toLong()
        if (ckBuf.remaining() == 1) sum += (ckBuf.get().toInt() and 0xFF) shl 8
        sum = (sum shr 16) + (sum and 0xFFFF); sum += (sum shr 16)
        pkt.setUShortAt(tcpOff + 16, (sum.toInt() and 0xFFFF).inv() and 0xFFFF)

        try { tunOutput?.write(pkt) } catch (_: Exception) {}
    }

    // ============ 会话管理 ============

    private fun closeSession(s: TcpSession) {
        try { s.upstreamSocket?.close() } catch (_: Exception) {}
        sessions.remove(sessionKey(s.srcIp, s.srcPort))
    }

    private suspend fun cleanupSessions() {
        while (isRunning) {
            delay(30000)
            val now = System.currentTimeMillis()
            sessions.entries.removeAll { (_, s) ->
                if (now - s.lastActivity > 60000) { try { s.upstreamSocket?.close() } catch (_: Exception) {}; true }
                else false
            }
        }
    }

    // ============ 通知 ============

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            getSystemService(NotificationManager::class.java).createNotificationChannel(
                NotificationChannel(CHANNEL_ID, "PixEz VPN", NotificationManager.IMPORTANCE_LOW))
        }
    }

    private fun buildNotification(): Notification {
        val pi = PendingIntent.getActivity(this, 0, Intent(this, MainActivity::class.java),
            if (Build.VERSION.SDK_INT >= 23) PendingIntent.FLAG_IMMUTABLE else 0)
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("PixEz VPN").setContentText("SNI 嗅探运行中")
            .setSmallIcon(android.R.drawable.ic_menu_share).setContentIntent(pi).setOngoing(true).build()
    }
}

// ============ ByteArray 扩展 ============

private fun ByteArray.getUShortAt(i: Int) = ((this[i].toInt() and 0xFF) shl 8) or (this[i + 1].toInt() and 0xFF)
private fun ByteArray.setUShortAt(i: Int, v: Int) { this[i] = ((v shr 8) and 0xFF).toByte(); this[i + 1] = (v and 0xFF).toByte() }
private fun ByteArray.getUIntAt(i: Int): Long = ((this[i].toLong() and 0xFF) shl 24) or ((this[i + 1].toLong() and 0xFF) shl 16) or ((this[i + 2].toLong() and 0xFF) shl 8) or (this[i + 3].toLong() and 0xFF)
private fun ByteArray.setUIntAt(i: Int, v: Long) { this[i] = ((v shr 24) and 0xFF).toByte(); this[i + 1] = ((v shr 16) and 0xFF).toByte(); this[i + 2] = ((v shr 8) and 0xFF).toByte(); this[i + 3] = (v and 0xFF).toByte() }
private fun ByteArray.getIntAt(i: Int) = ((this[i].toInt() and 0xFF) shl 24) or ((this[i + 1].toInt() and 0xFF) shl 16) or ((this[i + 2].toInt() and 0xFF) shl 8) or (this[i + 3].toInt() and 0xFF)
private fun ByteArray.setIntAt(i: Int, v: Int) { this[i] = ((v shr 24) and 0xFF).toByte(); this[i + 1] = ((v shr 16) and 0xFF).toByte(); this[i + 2] = ((v shr 8) and 0xFF).toByte(); this[i + 3] = (v and 0xFF).toByte() }
private fun Int.toIPv4() = "${(this shr 24) and 0xFF}.${(this shr 16) and 0xFF}.${(this shr 8) and 0xFF}.${this and 0xFF}"
