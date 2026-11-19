package com.zarz.mornye

import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import android.os.StatFs
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.io.File

/** Facts about the installed package that the update flow needs. */
internal fun MainActivity.registerAppUpdateChannel(messenger: BinaryMessenger) {
    MethodChannel(messenger, "musa/app_update").setMethodCallHandler { call, result ->
        try {
            when (call.method) {
                "installedBuild" -> {
                    val info = @Suppress("DEPRECATION")
                    packageManager.getPackageInfo(packageName, 0)
                    result.success(
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                            info.longVersionCode
                        } else {
                            @Suppress("DEPRECATION")
                            info.versionCode.toLong()
                        },
                    )
                }
                "canInstallPackages" -> result.success(
                    Build.VERSION.SDK_INT < Build.VERSION_CODES.O ||
                        packageManager.canRequestPackageInstalls(),
                )
                "openInstallPermissionSettings" -> {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                        startActivity(
                            Intent(
                                Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                                Uri.parse("package:$packageName"),
                            ),
                        )
                    }
                    result.success(null)
                }
                "freeBytes" -> {
                    val path = call.argument<String>("path")
                        ?: throw IllegalArgumentException("Missing path")
                    var target: File? = File(path)
                    while (target != null && !target.exists()) target = target.parentFile
                    result.success(
                        if (target == null) -1L else StatFs(target.path).availableBytes,
                    )
                }
                else -> result.notImplemented()
            }
        } catch (error: Exception) {
            result.error("app_update", error.message, null)
        }
    }
}
