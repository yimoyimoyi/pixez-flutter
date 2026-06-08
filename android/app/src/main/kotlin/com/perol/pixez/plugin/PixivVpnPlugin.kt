package com.perol.pixez.plugin

import android.content.Context
import android.content.Intent
import android.net.VpnService
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Pixiv VPN MethodChannel 插件
 *
 * Channel: com.perol.dev/pixiv_vpn
 */
class PixivVpnPlugin(private val context: Context) {

    companion object {
        const val CHANNEL = "com.perol.dev/pixiv_vpn"

        fun bindChannel(context: Context, flutterEngine: FlutterEngine) {
            val plugin = PixivVpnPlugin(context)
            MethodChannel(
                flutterEngine.dartExecutor.binaryMessenger,
                CHANNEL
            ).setMethodCallHandler { call, result ->
                when (call.method) {
                    "start" -> {
                        val intent = VpnService.prepare(context)
                        if (intent != null) {
                            // 需要用户授权 VPN 权限
                            result.success("need_permission")
                        } else {
                            context.startService(
                                Intent(context, PixivVpnService::class.java)
                            )
                            result.success(true)
                        }
                    }

                    "stop" -> {
                        context.startService(
                            Intent(context, PixivVpnService::class.java)
                                .setAction(PixivVpnService.ACTION_STOP)
                        )
                        result.success(true)
                    }

                    "prepare" -> {
                        val intent = VpnService.prepare(context)
                        result.success(intent != null)
                    }

                    else -> result.notImplemented()
                }
            }
        }
    }
}
