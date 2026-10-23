package com.nago.vpn

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

    @Synchronized
    fun clear() {
        lines.value = emptyList()
        prefs?.edit()?.remove(KEY)?.apply()
    }
}
