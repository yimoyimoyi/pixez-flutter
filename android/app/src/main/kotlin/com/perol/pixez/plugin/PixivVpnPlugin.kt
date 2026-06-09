package com.perol.pixez.plugin

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.net.VpnService
import android.os.Build
import android.util.Log
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Pixiv VPN MethodChannel 插件
 *
 * Channel: com.perol.dev/pixiv_vpn
 */
class PixivVpnPlugin(private val context: Context) {

    companion object {
        private const val TAG = "PixivVPN"
        const val CHANNEL = "com.perol.dev/pixiv_vpn"
        const val VPN_REQUEST_CODE = 0x1F3E

        private var pendingResult: MethodChannel.Result? = null
        private var _context: Context? = null

        fun bindChannel(context: Context, flutterEngine: FlutterEngine) {
            _context = context.applicationContext
            val plugin = PixivVpnPlugin(context)
            MethodChannel(
                flutterEngine.dartExecutor.binaryMessenger,
                CHANNEL
            ).setMethodCallHandler { call, result ->
                when (call.method) {
                    "start" -> {
                        Log.d(TAG, "start called")
                        val intent = VpnService.prepare(context)
                        if (intent != null) {
                            Log.d(TAG, "VPN permission required, launching activity")
                            val activity = context as? FlutterActivity
                            if (activity != null) {
                                pendingResult = result
                                activity.startActivityForResult(intent, VPN_REQUEST_CODE)
                            } else {
                                Log.e(TAG, "Context is not FlutterActivity")
                                result.error("NO_ACTIVITY", "需要 Activity 上下文来请求 VPN 权限", null)
                            }
                        } else {
                            Log.d(TAG, "VPN permission granted, starting service")
                            startVpnService(context)
                            result.success(true)
                        }
                    }

                    "stop" -> {
                        Log.d(TAG, "stop called")
                        try {
                            _context?.startService(
                                Intent(_context, PixivVpnService::class.java)
                                    .setAction(PixivVpnService.ACTION_STOP)
                            )
                        } catch (_: Exception) {}
                        result.success(true)
                    }

                    "prepare" -> {
                        val intent = VpnService.prepare(context)
                        Log.d(TAG, "prepare: needsPermission=${intent != null}")
                        result.success(intent != null)
                    }

                    else -> result.notImplemented()
                }
            }
        }

        private fun startVpnService(ctx: Context) {
            Log.d(TAG, "Starting PixivVpnService")
            val intent = Intent(ctx, PixivVpnService::class.java)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                ctx.startForegroundService(intent)
            } else {
                ctx.startService(intent)
            }
        }

        /** 在 Activity.onActivityResult 中调用 */
        fun handleActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
            if (requestCode != VPN_REQUEST_CODE) return false
            Log.d(TAG, "onActivityResult: resultCode=$resultCode")
            val result = pendingResult
            pendingResult = null
            val ctx = _context
            if (resultCode == Activity.RESULT_OK && ctx != null) {
                Log.d(TAG, "VPN permission granted, starting service")
                startVpnService(ctx)
                result?.success(true)
            } else {
                Log.d(TAG, "VPN permission denied or no context")
                result?.success("permission_denied")
            }
            return true
        }
    }
}
