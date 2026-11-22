package com.nago.vpn

import android.app.ActivityManager
import android.app.ApplicationExitInfo
import android.content.Context
import android.content.SharedPreferences
import kotlinx.coroutines.flow.MutableStateFlow
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/** 연결 로그(settings → logs). 최근 300줄을 앱 저장소에 둔다. */
object NagoLog {
    private const val KEY = "log"
    private const val LIMIT = 300

    val lines = MutableStateFlow<List<String>>(emptyList())
    private var prefs: SharedPreferences? = null
    private val stamp = SimpleDateFormat("MM-dd HH:mm:ss", Locale.US)

    @Synchronized
    fun init(context: Context) {
        if (prefs != null) return
        val p = context.applicationContext.getSharedPreferences("nago", Context.MODE_PRIVATE)
        prefs = p
        lines.value = (p.getString(KEY, "") ?: "").split('\n').filter { it.isNotEmpty() }
    }

    @Synchronized
    fun add(text: String) {
        val next = (lines.value + "${stamp.format(Date())} $text").takeLast(LIMIT)
        lines.value = next
        prefs?.edit()?.putString(KEY, next.joinToString("\n"))?.apply()
    }

    /**
     * 앱이 예외로 죽기 직전 그 이유를 로그에 남긴다(바로 디스크에 써서 다음에 열면 settings → logs에 보임).
     * 앱 화면과 VPN 서비스가 같은 프로세스라 어디서 부르든 한 번만 건다.
     */
    @Synchronized
    fun catchCrashes(context: Context) {
        init(context)
        val previous = Thread.getDefaultUncaughtExceptionHandler()
        if (previous is CrashLogger) return
        Thread.setDefaultUncaughtExceptionHandler(CrashLogger(previous))
    }

    private class CrashLogger(private val next: Thread.UncaughtExceptionHandler?) : Thread.UncaughtExceptionHandler {
        override fun uncaughtException(thread: Thread, e: Throwable) {
            runCatching {
                val where = e.stackTrace.take(4).joinToString(" ← ") { "${it.className.substringAfterLast('.')}.${it.methodName}:${it.lineNumber}" }
                synchronized(NagoLog) {
                    val next = (lines.value + "${stamp.format(Date())} ✗ crash [${thread.name}] ${e.javaClass.simpleName}: ${e.message} @ $where")
                        .takeLast(LIMIT)
                    lines.value = next
                    prefs?.edit()?.putString(KEY, next.joinToString("\n"))?.commit()
                }
            }
            next?.uncaughtException(thread, e)
        }
    }

    /** 지난번에 앱이 네이티브 크래시(엔진)·응답 없음으로 끝났으면 한 줄 남긴다(자바 예외는 [catchCrashes]가 남김). */
    fun reportLastExit(context: Context) {
        val p = prefs ?: return
        val exit = runCatching {
            context.getSystemService(ActivityManager::class.java)
                .getHistoricalProcessExitReasons(context.packageName, 0, 1).firstOrNull()
        }.getOrNull() ?: return
        if (exit.timestamp <= p.getLong("lastExitSeen", 0L)) return
        p.edit().putLong("lastExitSeen", exit.timestamp).apply()
        val kind = when (exit.reason) {
            ApplicationExitInfo.REASON_CRASH_NATIVE -> "native crash"
            ApplicationExitInfo.REASON_ANR -> "not responding (anr)"
            else -> return
        }
        add("✗ last run ended: $kind${exit.description?.let { " · $it" } ?: ""}")
    }

    @Synchronized
    fun clear() {
        lines.value = emptyList()
        prefs?.edit()?.remove(KEY)?.apply()
    }
}
