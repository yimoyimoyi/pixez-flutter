package com.perol.pixez.plugin

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Intent
import android.net.VpnService
import android.os.Build
import android.os.ParcelFileDescriptor
import androidx.core.app.NotificationCompat
import com.perol.pixez.MainActivity
import kotlinx.coroutines.*
import android.util.Log
import java.io.FileInputStream
import java.io.FileOutputStream
import java.io.InputStream
import java.io.OutputStream
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.Socket
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.ConcurrentHashMap

/**
 * Pixiv 登录专用 VPN 服务
 *
 * DNS 劫持: *.pixiv.net → 10.0.0.1
 * TCP 代理: 10.0.0.1:443 → 127.0.0.1:8443 (LoginProxy HTTPS)
 * 其他流量: 直通（通过 TUN 返回）
 */
class PixivVpnService : VpnService() {

    companion object {
        const val ACTION_STOP = "com.perol.pixez.STOP_VPN"
        const val CHANNEL_ID = "pixiv_vpn_channel"
        const val NOTIFICATION_ID = 1001
        const val VPN_ADDRESS = "10.0.0.2"
        const val VIRTUAL_IP = "10.0.0.1"
        const val PROXY_PORT = 8443
        const val DNS_PORT = 53
        const val TCP_PROTOCOL = 6
        const val UDP_PROTOCOL = 17
        const val IP_HEADER_LEN = 20
    }

    // ============ 数据类 ============

    /** TCP 连接会话 */
    data class TcpSession(
        val clientIp: Int,       // 客户端 IP（网络字节序）
        val clientPort: Int,     // 客户端端口
        var clientSeq: Long,     // 客户端下一个 SEQ
        var clientAck: Long,     // 期望从客户端收到的 ACK
        var proxySeq: Long,      // 代理侧下一个 SEQ（初始为随机 ISN）
        var proxyAck: Long,      // 期望从代理侧收到的 ACK
        val socket: Socket,
        val output: OutputStream,
        var connected: Boolean,
        var lastActivity: Long
    )

    // ============ 状态 ============

    private var tunInput: FileInputStream? = null
    private var tunOutput: FileOutputStream? = null
    private var tunFd: ParcelFileDescriptor? = null
    private var isRunning = false
    private val scope = CoroutineScope(Dispatchers.IO + SupervisorJob())
    private val sessions = ConcurrentHashMap<String, TcpSession>()
    private var sessionIdCounter = 0L

    // 客户端 IP 标识 (srcIp:srcPort -> sessionKey)
    private fun sessionKey(ip: Int, port: Int) = "${ip}:${port}"

    // ============ 生命周期 ============

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) { stopVpn(); return START_NOT_STICKY }
        startForeground(NOTIFICATION_ID, buildNotification())
        startVpn()
        return START_STICKY
    }

    override fun onRevoke() { stopVpn(); super.onRevoke() }
    override fun onDestroy() { stopVpn(); super.onDestroy() }

    private fun startVpn() {
        if (isRunning) return
        Log.d("PixivVPN", "startVpn: building TUN interface...")
        val builder = Builder()
            .setSession("PixEz VPN")
            .addAddress(VPN_ADDRESS, 32)
            .addRoute("0.0.0.0", 0)
            .addDnsServer("8.8.8.8")
            .setMtu(1500)
            .setBlocking(true)
        tunFd = builder.establish()
        if (tunFd == null) {
            Log.e("PixivVPN", "startVpn: establish() returned null!")
            stopSelf(); return
        }
        Log.d("PixivVPN", "startVpn: TUN established, fd=${tunFd!!.fd}")
        tunInput = FileInputStream(tunFd!!.fileDescriptor)
        tunOutput = FileOutputStream(tunFd!!.fileDescriptor)
        isRunning = true
        Log.d("PixivVPN", "startVpn: starting packet processing loop")
        scope.launch { processPackets() }
        scope.launch { cleanupSessions() }
    }

    private fun stopVpn() {
        isRunning = false
        scope.cancel()
        sessions.values.forEach { try { it.socket.close() } catch (_: Exception) {} }
        sessions.clear()
        try { dnsForwardSocket?.close() } catch (_: Exception) {}
        dnsForwardSocket = null
        try { tunInput?.close() } catch (_: Exception) {}
        try { tunOutput?.close() } catch (_: Exception) {}
        try { tunFd?.close() } catch (_: Exception) {}
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    // ============ 主处理循环 ============

    private var packetCount = 0L

    private fun processPackets() {
        val buf = ByteArray(32767)
        Log.d("PixivVPN", "processPackets: loop started")
        try {
            while (isRunning) {
                val len = tunInput?.read(buf) ?: -1
                if (len <= 0) {
                    if (len < 0) Log.d("PixivVPN", "processPackets: read returned $len, breaking")
                    if (len == 0) continue
                    break
                }
                packetCount++
                if (packetCount <= 5 || packetCount % 100 == 0L) {
                    val ipVer = (buf[0].toInt() shr 4) and 0x0F
                    val proto = buf[9].toInt() and 0xFF
                    val srcI = buf.getIntAt(12)
                    val dstI = buf.getIntAt(16)
                    Log.d("PixivVPN", "pkt #$packetCount: IPv$ipVer proto=$proto src=${srcI.toIPv4()} dst=${dstI.toIPv4()} len=$len")
                }

                val ipHdrLen = (buf[0].toInt() and 0x0F) * 4
                if (ipHdrLen < 20 || len < ipHdrLen) continue

                val protocol = buf[9].toInt() and 0xFF
                val srcIp = buf.getIntAt(12)
                val dstIp = buf.getIntAt(16)

                when (protocol) {
                    TCP_PROTOCOL -> handleTcp(buf, len, ipHdrLen, srcIp, dstIp)
                    UDP_PROTOCOL -> handleUdp(buf, len, ipHdrLen, srcIp, dstIp)
                }
            }
        } catch (e: Exception) {
            Log.e("PixivVPN", "processPackets error: ${e.message}", e)
        }
        Log.d("PixivVPN", "processPackets: loop ended, packets=$packetCount")
    }

    // ============ UDP / DNS 劫持 ============

    private var dnsForwardSocket: DatagramSocket? = null

    private fun handleUdp(pkt: ByteArray, len: Int, ipHdr: Int, srcIp: Int, dstIp: Int) {
        val udpHdr = ipHdr + 8
        if (udpHdr > len) return
        val dstPort = pkt.getUShortAt(ipHdr + 2)
        if (dstPort != DNS_PORT) return

        val dnsStart = ipHdr + 8
        val dnsData = pkt.copyOfRange(dnsStart, len)
        val qname = parseDnsName(dnsData, 12)

        if (qname != null && qname.endsWith(".pixiv.net")) {
            // 劫持: *.pixiv.net → 10.0.0.1
            val resp = buildDnsResponse(pkt, len, ipHdr, srcIp, dstIp, dnsData, qname)
            try { tunOutput?.write(resp) } catch (_: Exception) {}
        } else {
            // 转发其他 DNS 查询到 8.8.8.8
            forwardDns(pkt, dnsData, len, ipHdr, srcIp, dstIp)
        }
    }

    private fun forwardDns(pkt: ByteArray, dnsData: ByteArray, len: Int, ipHdr: Int, srcIp: Int, dstIp: Int) {
        try {
            if (dnsForwardSocket == null || dnsForwardSocket!!.isClosed) {
                dnsForwardSocket = DatagramSocket()
                dnsForwardSocket!!.soTimeout = 5000
            }
            val query = DatagramPacket(dnsData, dnsData.size, InetAddress.getByName("8.8.8.8"), 53)
            dnsForwardSocket!!.send(query)
            val resp = ByteArray(1024)
            val respPacket = DatagramPacket(resp, resp.size)
            dnsForwardSocket!!.receive(respPacket)
            // 将真实 DNS 响应封装回 IP/UDP 并写入 TUN
            val dnsResp = resp.copyOf(respPacket.length)
            val udpLen = 8 + dnsResp.size
            val total = IP_HEADER_LEN + udpLen
            val out = ByteArray(total)
            out[0] = 0x45.toByte()
            out.setUShortAt(2, total)
            out.setUShortAt(4, pkt.getUShortAt(4))
            out[6] = 0x40.toByte(); out[8] = 64; out[9] = 17
            out.setIntAt(12, dstIp); out.setIntAt(16, srcIp)
            out.setUShortAt(10, ipChecksum(out, 0, IP_HEADER_LEN))
            // UDP
            out.setUShortAt(IP_HEADER_LEN, pkt.getUShortAt(ipHdr + 2)) // src = orig dst port
            out.setUShortAt(IP_HEADER_LEN + 2, pkt.getUShortAt(ipHdr)) // dst = orig src port
            out.setUShortAt(IP_HEADER_LEN + 4, udpLen)
            System.arraycopy(dnsResp, 0, out, IP_HEADER_LEN + 8, dnsResp.size)
            try { tunOutput?.write(out) } catch (_: Exception) {}
        } catch (_: Exception) {}
    }

    // ============ TCP 代理 ============

    private fun handleTcp(pkt: ByteArray, len: Int, ipHdr: Int, srcIp: Int, dstIp: Int) {
        val tcpHdr = ipHdr
        val dstPort = pkt.getUShortAt(tcpHdr + 2)
        val srcPort = pkt.getUShortAt(tcpHdr)
        val flags = pkt[tcpHdr + 13].toInt() and 0xFF

        // 拦截 DNS-over-TLS (TCP:853) → 发送 RST，强制回退到 UDP:53 传统 DNS
        if (dstPort == 853) {
            if (flags and 0x02 != 0) { // SYN
                Log.d("PixivVPN", "Blocking DoT to ${dstIp.toIPv4()}:853")
                sendTcpPacket(
                    srcIp = dstIp, dstIp = srcIp,
                    srcPort = dstPort, dstPort = srcPort,
                    seq = 0, ack = pkt.getUIntAt(tcpHdr + 4) + 1,
                    flags = 0x14, data = null  // RST+ACK
                )
            }
            return
        }

        // 仅处理去往虚拟 IP:443 的流量
        if (dstIp.toIPv4() != VIRTUAL_IP || dstPort != 443) return

        val key = sessionKey(srcIp, srcPort)
        val existing = sessions[key]

        when {
            // === SYN: 新连接 ===
            flags and 0x02 != 0 && existing == null -> {
                val clientSeq = pkt.getUIntAt(tcpHdr + 4)
                Log.d("PixivVPN", "TCP SYN from ${srcIp.toIPv4()}:$srcPort to ${dstIp.toIPv4()}:$dstPort")
                try {
                    val sock = Socket()
                    sock.connect(InetSocketAddress("127.0.0.1", PROXY_PORT), 5000)
                    Log.d("PixivVPN", "Connected to proxy 127.0.0.1:$PROXY_PORT")
                    val session = TcpSession(
                        clientIp = srcIp,
                        clientPort = srcPort,
                        clientSeq = clientSeq + 1,
                        clientAck = clientSeq + 1,
                        proxySeq = (Math.random() * 0xFFFFFFFF).toLong() and 0xFFFFFFFFL,
                        proxyAck = 0,
                        socket = sock,
                        output = sock.getOutputStream(),
                        connected = true,
                        lastActivity = System.currentTimeMillis()
                    )
                    sessions[key] = session
                    Log.d("PixivVPN", "Sending SYN-ACK, our seq=${session.proxySeq}, ack=${session.clientSeq}")

                    sendTcpPacket(
                        srcIp = dstIp, dstIp = srcIp,
                        srcPort = dstPort, dstPort = srcPort,
                        seq = session.proxySeq,
                        ack = session.clientSeq,
                        flags = 0x12,  // SYN+ACK
                        data = null
                    )
                    session.proxySeq++

                    scope.launch { relayFromProxy(key) }
                } catch (e: Exception) {
                    Log.e("PixivVPN", "SYN failed: ${e.message}")
                    sendTcpPacket(
                        srcIp = dstIp, dstIp = srcIp,
                        srcPort = dstPort, dstPort = srcPort,
                        seq = clientSeq, ack = 0,
                        flags = 0x14, data = null  // RST+ACK
                    )
                }
            }

            // === ACK: 握手完成或数据 ===
            flags and 0x10 != 0 && existing != null -> {
                val clientSeq = pkt.getUIntAt(tcpHdr + 4)
                val clientAck = pkt.getUIntAt(tcpHdr + 8)
                val payloadLen = len - tcpHdr - ((pkt[tcpHdr + 12].toInt() shr 4) and 0x0F) * 4

                existing.clientSeq = clientSeq + payloadLen
                existing.proxyAck = clientAck
                existing.lastActivity = System.currentTimeMillis()

                // 如果有数据负载，转发到代理
                if (payloadLen > 0) {
                    val dataOff = tcpHdr + ((pkt[tcpHdr + 12].toInt() shr 4) and 0x0F) * 4
                    try {
                        existing.output.write(pkt, dataOff, payloadLen)
                        existing.output.flush()
                    } catch (_: Exception) {
                        closeSession(key)
                    }
                }
            }

            // === FIN / RST: 关闭连接 ===
            flags and 0x01 != 0 || flags and 0x04 != 0 -> {
                existing?.let {
                    sendFinAck(it)
                    closeSession(key)
                }
            }
        }
    }

    /** 从代理读取数据并转发到客户端 */
    private suspend fun relayFromProxy(key: String) {
        val session = sessions[key] ?: return
        val buf = ByteArray(16384)
        try {
            val input: InputStream = session.socket.getInputStream()
            while (isRunning && sessions.containsKey(key)) {
                val n = input.read(buf)
                if (n < 0) break
                sendTcpPacket(
                    srcIp = VIRTUAL_IP.toIPInt(), dstIp = session.clientIp,
                    srcPort = 443, dstPort = session.clientPort,
                    seq = session.proxySeq,
                    ack = session.clientSeq,
                    flags = 0x18,  // PSH+ACK
                    data = buf.copyOf(n)
                )
                session.proxySeq += n
                session.lastActivity = System.currentTimeMillis()
            }
        } catch (_: Exception) {}
        closeSession(key)
    }

    // ============ TCP 包构造 ============

    private fun sendTcpPacket(
        srcIp: Int, dstIp: Int, srcPort: Int, dstPort: Int,
        seq: Long, ack: Long, flags: Int, data: ByteArray?
    ) {
        val payloadLen = data?.size ?: 0
        val totalLen = IP_HEADER_LEN + 20 + payloadLen
        val pkt = ByteArray(totalLen)

        // IP 头
        pkt[0] = 0x45.toByte() // IPv4, 5 words
        pkt.setUShortAt(2, totalLen)
        pkt.setUShortAt(4, (sessionIdCounter++ % 65535).toInt())
        pkt[6] = 0x40.toByte() // Flags: Don't Fragment
        pkt[8] = 64 // TTL
        pkt[9] = TCP_PROTOCOL.toByte()
        pkt.setIntAt(12, srcIp)
        pkt.setIntAt(16, dstIp)
        // IP checksum
        val ipCsum = ipChecksum(pkt, 0, IP_HEADER_LEN)
        pkt.setUShortAt(10, ipCsum)

        // TCP 头
        val tcpOff = IP_HEADER_LEN
        pkt.setUShortAt(tcpOff, srcPort)
        pkt.setUShortAt(tcpOff + 2, dstPort)
        pkt.setUIntAt(tcpOff + 4, seq)
        pkt.setUIntAt(tcpOff + 8, ack)
        pkt[tcpOff + 12] = 0x50.toByte()  // data offset = 5 words (20 bytes)
        pkt[tcpOff + 13] = flags.toByte()
        pkt.setUShortAt(tcpOff + 14, 65535)  // window size

        // 数据
        if (data != null) {
            System.arraycopy(data, 0, pkt, tcpOff + 20, data.size)
        }

        // TCP 校验和
        val tcpCsum = tcpChecksum(pkt, IP_HEADER_LEN, 20 + payloadLen, srcIp, dstIp)
        pkt.setUShortAt(tcpOff + 16, tcpCsum)

        try {
            tunOutput?.write(pkt)
        } catch (e: Exception) {
            Log.e("PixivVPN", "write failed: ${e.message}")
        }
    }

    // ============ IP 校验和 ============

    private fun ipChecksum(pkt: ByteArray, offset: Int, len: Int): Int {
        var sum = 0L
        var i = offset
        while (i < offset + len) {
            if (i == offset + 10) { i += 2; continue } // skip checksum field
            sum += pkt.getUShortAt(i).toLong()
            i += 2
        }
        sum = (sum shr 16) + (sum and 0xFFFF)
        sum += (sum shr 16)
        return (sum.toInt() and 0xFFFF).inv() and 0xFFFF
    }

    // ============ 会话管理 ============

    private fun sendFinAck(s: TcpSession) {
        sendTcpPacket(
            srcIp = VIRTUAL_IP.toIPInt(), dstIp = s.clientIp,
            srcPort = 443, dstPort = s.clientPort,
            seq = s.proxySeq, ack = s.clientSeq,
            flags = 0x11, data = null  // FIN+ACK
        )
    }

    private fun closeSession(key: String) {
        sessions.remove(key)?.let {
            try { it.socket.close() } catch (_: Exception) {}
        }
    }

    private suspend fun cleanupSessions() {
        while (isRunning) {
            delay(30000)
            val now = System.currentTimeMillis()
            sessions.entries.removeAll { (_, s) ->
                if (now - s.lastActivity > 60000) {
                    try { s.socket.close() } catch (_: Exception) {}
                    true
                } else false
            }
        }
    }

    // ============ DNS 响应构造 ============

    private fun parseDnsName(data: ByteArray, offset: Int): String? {
        val sb = StringBuilder()
        var pos = offset
        try {
            while (pos < data.size) {
                val len = data[pos].toInt() and 0xFF
                if (len == 0) break
                if (len and 0xC0 == 0xC0) break
                if (sb.isNotEmpty()) sb.append('.')
                for (i in 1..len) sb.append((data[pos + i].toInt() and 0xFF).toChar())
                pos += len + 1
            }
        } catch (_: Exception) { return null }
        return sb.toString().lowercase()
    }

    /** 计算 DNS 查询中 QNAME 的 wire format 长度（从 offset 到 0x00） */
    private fun dnsNameWireLen(data: ByteArray, offset: Int): Int {
        var pos = offset
        while (pos < data.size) {
            val len = data[pos].toInt() and 0xFF
            if (len == 0) return pos - offset + 1 // +1 for null terminator
            if (len and 0xC0 == 0xC0) return pos - offset + 2 // compressed pointer
            pos += len + 1
        }
        return pos - offset
    }

    private fun buildDnsResponse(
        pkt: ByteArray, len: Int, ipHdr: Int,
        srcIp: Int, dstIp: Int,
        dnsData: ByteArray, qname: String
    ): ByteArray {
        // 计算 wire format question 长度
        val nameLen = dnsNameWireLen(dnsData, 12)
        val qTotalLen = 12 + nameLen + 4 // header(12) + qname(wire) + qtype(2) + qclass(2)
        val ansLen = 16
        val respDnsLen = qTotalLen + ansLen
        val udpLen = 8 + respDnsLen
        val total = IP_HEADER_LEN + udpLen
        val resp = ByteArray(total)

        // IP 头: 交换 src/dst
        resp[0] = 0x45.toByte()
        resp.setUShortAt(2, total)
        resp.setUShortAt(4, pkt.getUShortAt(4)) // 复用 ID
        resp[8] = 64
        resp[9] = UDP_PROTOCOL.toByte()
        resp.setIntAt(12, dstIp)
        resp.setIntAt(16, srcIp)
        val ipCsum = ipChecksum(resp, 0, IP_HEADER_LEN)
        resp.setUShortAt(10, ipCsum)

        // UDP 头
        val udpOff = IP_HEADER_LEN
        resp.setUShortAt(udpOff, pkt.getUShortAt(ipHdr + 2)) // src = orig dst port
        resp.setUShortAt(udpOff + 2, pkt.getUShortAt(ipHdr)) // dst = orig src port
        resp.setUShortAt(udpOff + 4, udpLen)

        // DNS 响应
        val dnsOff = udpOff + 8
        System.arraycopy(dnsData, 0, resp, dnsOff, 2)       // TXID
        resp[dnsOff + 2] = 0x81.toByte(); resp[dnsOff + 3] = 0x80.toByte() // flags: response
        System.arraycopy(dnsData, 4, resp, dnsOff + 4, 6)    // QDCOUNT + ANCOUNT(=QDCOUNT) + NSCOUNT(0) + ARCOUNT(0)
        // 复制完整 question section（包括 qname wire format + qtype + qclass）
        System.arraycopy(dnsData, 12, resp, dnsOff + 12, qTotalLen - 12)

        // 答案: A 记录 10.0.0.1
        val ansOff = dnsOff + qTotalLen
        resp[ansOff] = 0xC0.toByte(); resp[ansOff + 1] = 0x0C.toByte() // 域名指针 → offset 12
        resp.setUShortAt(ansOff + 2, 1)   // Type A
        resp.setUShortAt(ansOff + 4, 1)   // Class IN
        resp.setUIntAt(ansOff + 6, 60)    // TTL 60s
        resp.setUShortAt(ansOff + 10, 4)  // Data length = 4
        resp[ansOff + 12] = 10; resp[ansOff + 13] = 0
        resp[ansOff + 14] = 0; resp[ansOff + 15] = 1 // 10.0.0.1

        return resp
    }

    // ============ TCP 校验和 ============

    private fun tcpChecksum(pkt: ByteArray, ipHdr: Int, tcpLen: Int, srcIp: Int, dstIp: Int): Int {
        val buf = ByteBuffer.allocate(12 + tcpLen).order(ByteOrder.BIG_ENDIAN)
        buf.putInt(srcIp); buf.putInt(dstIp)
        buf.put(0); buf.put(TCP_PROTOCOL.toByte())
        buf.putShort(tcpLen.toShort())
        buf.put(pkt, ipHdr, tcpLen)
        buf.flip()
        var sum = 0L
        while (buf.hasRemaining()) {
            if (buf.remaining() == 1) {
                sum += (buf.get().toInt() and 0xFF) shl 8
            } else {
                sum += buf.getShort().toInt() and 0xFFFF
            }
        }
        sum = (sum shr 16) + (sum and 0xFFFF)
        sum += (sum shr 16)
        return (sum.toInt() and 0xFFFF).inv() and 0xFFFF
    }

    // ============ 通知 ============

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            getSystemService(NotificationManager::class.java).createNotificationChannel(
                NotificationChannel(CHANNEL_ID, "PixEz 登录 VPN", NotificationManager.IMPORTANCE_LOW)
                    .apply { description = "PixEz 登录代理运行中" })
        }
    }

    private fun buildNotification(): Notification {
        val pi = PendingIntent.getActivity(this, 0, Intent(this, MainActivity::class.java),
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) PendingIntent.FLAG_IMMUTABLE else 0)
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("PixEz 登录 VPN")
            .setContentText("代理运行中")
            .setSmallIcon(android.R.drawable.ic_menu_share)
            .setContentIntent(pi).setOngoing(true).build()
    }
}

// ============ ByteArray 扩展: 网络字节序读写 ============

private fun ByteArray.getUShortAt(i: Int): Int =
    ((this[i].toInt() and 0xFF) shl 8) or (this[i + 1].toInt() and 0xFF)

private fun ByteArray.setUShortAt(i: Int, v: Int) {
    this[i] = ((v shr 8) and 0xFF).toByte()
    this[i + 1] = (v and 0xFF).toByte()
}

private fun ByteArray.getUIntAt(i: Int): Long =
    ((this[i].toLong() and 0xFF) shl 24) or
    ((this[i + 1].toLong() and 0xFF) shl 16) or
    ((this[i + 2].toLong() and 0xFF) shl 8) or
    (this[i + 3].toLong() and 0xFF)

private fun ByteArray.setUIntAt(i: Int, v: Long) {
    this[i] = ((v shr 24) and 0xFF).toByte()
    this[i + 1] = ((v shr 16) and 0xFF).toByte()
    this[i + 2] = ((v shr 8) and 0xFF).toByte()
    this[i + 3] = (v and 0xFF).toByte()
}

private fun ByteArray.getIntAt(i: Int): Int =
    ((this[i].toInt() and 0xFF) shl 24) or
    ((this[i + 1].toInt() and 0xFF) shl 16) or
    ((this[i + 2].toInt() and 0xFF) shl 8) or
    (this[i + 3].toInt() and 0xFF)

private fun ByteArray.setIntAt(i: Int, v: Int) {
    this[i] = ((v shr 24) and 0xFF).toByte()
    this[i + 1] = ((v shr 16) and 0xFF).toByte()
    this[i + 2] = ((v shr 8) and 0xFF).toByte()
    this[i + 3] = (v and 0xFF).toByte()
}

private fun Int.toIPv4() =
    "${(this shr 24) and 0xFF}.${(this shr 16) and 0xFF}.${(this shr 8) and 0xFF}.${this and 0xFF}"

private fun String.toIPInt(): Int {
    val p = split(".")
    return (p[0].toInt() shl 24) or (p[1].toInt() shl 16) or (p[2].toInt() shl 8) or p[3].toInt()
}
