package com.zarz.mornye

import android.app.ActivityManager
import android.app.Application
import android.content.Context
import android.content.pm.ApplicationInfo
import android.os.Bundle
import android.os.Process
import androidx.test.platform.app.InstrumentationRegistry

/** Test-only run binding. No argument means no side effect or metadata emission. */
internal object TestOwnCrashCorrelation {
    fun summary(nonce: String?): ByteArray? {
        if (nonce == null) return null
        check(nonce.matches(Regex("[a-f0-9]{32}")))
        return ("MUSA_TEST_TRACE:" + nonce).toByteArray(Charsets.US_ASCII)
    }
    fun bindIfRequested(context: Context) {
        val value = summary(InstrumentationRegistry.getArguments().getString("diagNonce")) ?: return
        check(context.packageName == "org.musa.music.catalogintegration")
        check(context.applicationContext.javaClass == Application::class.java)
        check(Application.getProcessName() == context.packageName)
        check(context.applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE != 0)
        check(Process.myUid() == context.applicationInfo.uid)
        val began = System.currentTimeMillis()
        context.getSystemService(ActivityManager::class.java).setProcessStateSummary(value)
        // Nonce is never emitted. Supervisor consumes these numeric own-run fields
        // privately in memory; they are excluded from persistent/public output.
        InstrumentationRegistry.getInstrumentation().sendStatus(2, Bundle().apply {
            putInt("musa_diag_uid", Process.myUid())
            putInt("musa_diag_pid", Process.myPid())
            putLong("musa_diag_start_ms", began)
        })
    }
}
