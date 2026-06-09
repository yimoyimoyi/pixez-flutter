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
 * Pixiv SNI 嗅探 VPN + 完整 TCP 转发
 *
 * 拦截所有 TCP 流量 → 提取 SNI → 根据 SNI 路由到不同上游：
 *   *.pixiv.net → 127.0.0.1:8443 (LoginProxy HTTPS)
 *   其他        → 原始目标 IP:端口 (直通网络)
 * 非 TCP 流量直通忽略。
 */
class PixivVpnService : VpnService() {

    companion object {
        const val ACTION_STOP = "com.perol.pixez.STOP_VPN"
        val TAG = "PixivVPN"
        const val CHANNEL_ID = "pixiv_vpn_channel"
        const val NOTIFICATION_ID = 1001
        const val VPN_IP = "10.0.0.2"
        const val PROXY_IP = "127.0.0.1"
        const val PROXY_PORT = 8443
    }

    private data class TcpSession(
        val srcIp: Int, val srcPort: Int,
        val dstIp: Int, val dstPort: Int,
        var clientSeq: Long = 0, var clientAck: Long = 0,
        var serverSeq: Long = (Math.random() * 0x3FFFFFFF).toLong(),
        var serverAck: Long = 0,
        val buf: ByteArrayOutputStream = ByteArrayOutputStream(),
        var upstreamSock: Socket? = null,
        var upstreamOut: OutputStream? = null,
        var upstreamIn: InputStream? = null,
        var sni: String? = null,
        var resolved: Boolean = false,
        var lastActivity: Long = System.currentTimeMillis()
    )

    private var tunIn: FileInputStream? = null
    private var tunOut: FileOutputStream? = null
    private var tunFd: ParcelFileDescriptor? = null
    private var isRunning = false
    private val scope = CoroutineScope(Dispatchers.IO + SupervisorJob())
    private val sessions = ConcurrentHashMap<String, TcpSession>()
    private var pktId = 0L

    private fun key(ip: Int, port: Int) = "${ip.toIPv4()}:$port"

    override fun onCreate() { super.onCreate(); createNotifyChannel() }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) { stop(); return START_NOT_STICKY }
        startForeground(NOTIFICATION_ID, buildNotify())
        startVpn(); return START_STICKY
    }

    override fun onRevoke() { stop(); super.onRevoke() }
    override fun onDestroy() { stop(); super.onDestroy() }

    private fun startVpn() {
        if (isRunning) return
        Log.d(TAG, "startVpn...")
        val b = Builder().setSession("PixEz VPN")
            .addAddress(VPN_IP, 32).addRoute("0.0.0.0", 0)
            .addDnsServer("1.1.1.1").setMtu(1500).setBlocking(true)
        tunFd = b.establish()
        if (tunFd == null) { Log.e(TAG, "establish null"); stopSelf(); return }
        tunIn = FileInputStream(tunFd!!.fileDescriptor)
        tunOut = FileOutputStream(tunFd!!.fileDescriptor)
        isRunning = true
        scope.launch { processLoop() }
        scope.launch { cleanupLoop() }
    }

    private fun stop() {
        isRunning = false; scope.cancel()
        sessions.values.forEach { close(it) }; sessions.clear()
        try { tunIn?.close() } catch (_: Exception) {}
        try { tunOut?.close() } catch (_: Exception) {}
        try { tunFd?.close() } catch (_: Exception) {}
        stopForeground(STOP_FOREGROUND_REMOVE); stopSelf()
    }

    // ============ 主循环 ============

    private fun processLoop() {
        val buf = ByteArray(65535)
        Log.d(TAG, "loop start")
        try {
            while (isRunning) {
                val n = tunIn?.read(buf) ?: -1
                if (n <= 0) continue
                pktId++
                if ((buf[0].toInt() shr 4) != 4) continue
                val ih = (buf[0].toInt() and 0x0F) * 4
                if (ih < 20 || n < ih) continue
                val p = buf[9].toInt() and 0xFF
                if (p == 6) handleTcp(buf, n, ih)
            }
        } catch (e: Exception) { Log.e(TAG, "loop err: ${e.message}") }
        Log.d(TAG, "loop end, pkts=$pktId")
    }

    // ============ TCP 处理 ============

    private fun handleTcp(pkt: ByteArray, len: Int, ih: Int) {
        val fl = pkt[ih + 13].toInt() and 0xFF
        val sp = pkt.getUShortAt(ih); val dp = pkt.getUShortAt(ih + 2)
        val seq = pkt.getUIntAt(ih + 4)
        val thl = ((pkt[ih + 12].toInt() shr 4) and 0x0F) * 4
        val pl = len - ih - thl
        val k = key(pkt.getIntAt(12), sp)
        val s = sessions[k]

        if (fl and 0x02 != 0 && s == null) {
            // SYN
            val cliIp = pkt.getIntAt(12); val srvIp = pkt.getIntAt(16)
            val ss = TcpSession(cliIp, sp, srvIp, dp,
                clientSeq = seq + 1, clientAck = seq + 1)
            sessions[k] = ss
            sendTcp(srvIp, cliIp, dp, sp, ss.serverSeq, ss.clientSeq, 0x12, null)
            ss.serverSeq++
            if (pktId <= 10) Log.d(TAG, "SYN ${cliIp.toIPv4()}:$sp → ${srvIp.toIPv4()}:$dp")
            return
        }
        if (s == null) return
        s.lastActivity = System.currentTimeMillis()

        if (fl and 0x10 != 0) {
            // DATA / ACK
            if (pl > 0) s.buf.write(pkt, ih + thl, pl)
            s.clientSeq = seq + pl; s.clientAck = pkt.getUIntAt(ih + 8)
            sendTcp(s.dstIp, s.srcIp, s.dstPort, s.srcPort, s.serverSeq, s.clientSeq, 0x10, null)
            s.serverAck = s.clientSeq

            if (!s.resolved) tryResolve(s)
            if (s.resolved && s.upstreamOut != null && pl > 0) {
                try { s.upstreamOut!!.write(pkt, ih + thl, pl); s.upstreamOut!!.flush() }
                catch (_: Exception) { close(s) }
            }
            return
        }
        if (fl and 0x01 != 0 || fl and 0x04 != 0) {
            sendTcp(s.dstIp, s.srcIp, s.dstPort, s.srcPort, s.serverSeq, s.clientSeq, 0x11, null)
            close(s)
        }
    }

    // ============ SNI 嗅探 + 连接建立 ============

    private fun tryResolve(s: TcpSession) {
        val data = s.buf.toByteArray()
        if (data.size < 5) return
        if (data[0].toInt() != 0x16) return // 非 TLS 握手，直通
        val tlsLen = ((data[3].toInt() and 0xFF) shl 8) or (data[4].toInt() and 0xFF)
        if (data.size < 5 + tlsLen) return

        // 解析 TLS ClientHello 提取 SNI
        var pos = 38; if (pos + 1 > data.size) return
        pos += 1 + (data[pos].toInt() and 0xFF) // skip sessionID
        if (pos + 2 > data.size) return
        pos += 2 + ((data[pos].toInt() and 0xFF) shl 8 or (data[pos + 1].toInt() and 0xFF)) // cipher suites
        if (pos + 1 > data.size) return
        pos += 1 + (data[pos].toInt() and 0xFF) // compression
        if (pos + 2 > data.size) return
        val extLen = ((data[pos].toInt() and 0xFF) shl 8) or (data[pos + 1].toInt() and 0xFF)
        pos += 2
        val extEnd = pos + extLen

        while (pos + 4 <= extEnd && pos + 4 <= data.size) {
            val et = ((data[pos].toInt() and 0xFF) shl 8) or (data[pos + 1].toInt() and 0xFF)
            val dl = ((data[pos + 2].toInt() and 0xFF) shl 8) or (data[pos + 3].toInt() and 0xFF)
            pos += 4
            if (et == 0x0000) { // SNI
                val nl = ((data[pos + 3].toInt() and 0xFF) shl 8) or (data[pos + 4].toInt() and 0xFF)
                s.sni = String(data, pos + 5, nl)
                Log.d(TAG, "SNI: ${s.sni}")
                connectUpstream(s)
                return
            }
            pos += dl
        }
        // 未能提取 SNI，按非 Pixiv 处理直通
        s.sni = "*"
        connectUpstream(s)
    }

    private fun connectUpstream(s: TcpSession) {
        s.resolved = true
        val isPixiv = s.sni?.endsWith(".pixiv.net") == true || s.sni == "pixiv.net"
        val host = if (isPixiv) PROXY_IP else s.dstIp.toIPv4()
        val port = if (isPixiv) PROXY_PORT else s.dstPort
        Log.d(TAG, "${if (isPixiv) "Pixiv" else "Direct"}: ${s.sni} → $host:$port")

        try {
            val sock = Socket()
            sock.connect(InetSocketAddress(host, port), 5000)
            if (!isPixiv) {
                try { protectSocket(sock) } catch (_: Exception) {}
            }
            s.upstreamSock = sock
            s.upstreamOut = sock.getOutputStream()
            s.upstreamIn = sock.getInputStream()
            scope.launch { upstreamToClient(s) }
            val buf = s.buf.toByteArray()
            if (buf.isNotEmpty()) {
                s.upstreamOut!!.write(buf); s.upstreamOut!!.flush()
            }
        } catch (e: Exception) {
            Log.e(TAG, "connect failed: ${e.message}")
            close(s)
        }
    }

    // 通过 VpnService.protect(fd) 保护 socket 不被路由回 TUN
    private fun protectSocket(socket: Socket) {
        try {
            val fdField = socket.javaClass.getDeclaredField("fd")
            fdField.isAccessible = true
            val fdObj = fdField.get(socket) as? Any?
            if (fdObj != null) {
                val fdIntField = fdObj.javaClass.getDeclaredField("descriptor")
                fdIntField.isAccessible = true
                val fdInt = fdIntField.getInt(fdObj)
                protect(fdInt)
            }
        } catch (_: Exception) {}
    }

    private suspend fun upstreamToClient(s: TcpSession) {
        val buf = ByteArray(16384)
        try {
            while (isRunning) {
                val n = s.upstreamIn?.read(buf) ?: -1
                if (n <= 0) break
                sendTcp(s.dstIp, s.srcIp, s.dstPort, s.srcPort,
                    s.serverSeq, s.clientSeq, 0x18, buf.copyOf(n))
                s.serverSeq += n
            }
        } catch (_: Exception) {}
        close(s)
    }

    // ============ TCP 包构造 ============

    private var nextId = 0L

    private fun sendTcp(sip: Int, dip: Int, sp: Int, dpp: Int,
                        seq: Long, ack: Long, fl: Int, data: ByteArray?) {
        val payload = data ?: ByteArray(0)
        val total = 40 + payload.size; val pkt = ByteArray(total)
        pkt[0] = 0x45; pkt.setUShortAt(2, total); pkt.setUShortAt(4, (nextId++ % 65535).toInt())
        pkt[6] = 0x40; pkt[8] = 64; pkt[9] = 6
        pkt.setIntAt(12, sip); pkt.setIntAt(16, dip)
        var ipc = 0L; var j = 0; while (j < 20) { if (j != 10) ipc += pkt.getUShortAt(j).toLong(); j += 2 }
        ipc = (ipc shr 16) + (ipc and 0xFFFF); ipc += (ipc shr 16)
        pkt.setUShortAt(10, (ipc.toInt() and 0xFFFF).inv() and 0xFFFF)

        val to = 20; pkt.setUShortAt(to, sp); pkt.setUShortAt(to + 2, dpp)
        pkt.setUIntAt(to + 4, seq); pkt.setUIntAt(to + 8, ack)
        pkt[to + 12] = 0x50; pkt[to + 13] = fl.toByte()
        pkt.setUShortAt(to + 14, 65535)
        if (payload.isNotEmpty()) System.arraycopy(payload, 0, pkt, to + 20, payload.size)

        val tcpLen = 20 + payload.size
        val cb = ByteBuffer.allocate(12 + (if (tcpLen % 2 != 0) tcpLen + 1 else tcpLen)).order(ByteOrder.BIG_ENDIAN)
        cb.putInt(sip); cb.putInt(dip); cb.put(0); cb.put(6); cb.putShort(tcpLen.toShort())
        cb.put(pkt, to, tcpLen); if (tcpLen % 2 != 0) cb.put(0)
        cb.flip()
        var sum = 0L; while (cb.remaining() > 1) sum += (cb.getShort().toInt() and 0xFFFF).toLong()
        if (cb.remaining() == 1) sum += (cb.get().toInt() and 0xFF) shl 8
        sum = (sum shr 16) + (sum and 0xFFFF); sum += (sum shr 16)
        pkt.setUShortAt(to + 16, (sum.toInt() and 0xFFFF).inv() and 0xFFFF)

        try { tunOut?.write(pkt) } catch (_: Exception) {}
    }

    // ============ 会话管理 ============

    private fun close(s: TcpSession) {
        try { s.upstreamSock?.close() } catch (_: Exception) {}
        sessions.remove(key(s.srcIp, s.srcPort))
    }

    private suspend fun cleanupLoop() {
        while (isRunning) { delay(30000); val now = System.currentTimeMillis()
            sessions.entries.removeAll { (_, s) ->
                if (now - s.lastActivity > 60000) { try { s.upstreamSock?.close() } catch (_: Exception) {}; true }
                else false }
        }
    }

    // ============ 通知 ============

    private fun createNotifyChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            getSystemService(NotificationManager::class.java).createNotificationChannel(
                NotificationChannel(CHANNEL_ID, "PixEz VPN", NotificationManager.IMPORTANCE_LOW))
        }
    }
    private fun buildNotify(): Notification {
        val pi = PendingIntent.getActivity(this, 0, Intent(this, MainActivity::class.java),
            if (Build.VERSION.SDK_INT >= 23) PendingIntent.FLAG_IMMUTABLE else 0)
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("PixEz VPN").setContentText("代理运行中")
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
