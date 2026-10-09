package com.nago.vpn

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.net.VpnManager
import kotlinx.coroutines.flow.MutableStateFlow

/** 시스템 VPN이 보내는 실패/해제 이벤트를 화면에 보여 줄 한 줄로 바꿔 둔다. */
object VpnEvents {
    val lastEvent = MutableStateFlow<String?>(null)
}

class VpnEventReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != VpnManager.ACTION_VPN_MANAGER_EVENT) return
        val cats = intent.categories ?: emptySet()
        val code = intent.getIntExtra(VpnManager.EXTRA_ERROR_CODE, -1)
        val event = when {
            VpnManager.CATEGORY_EVENT_IKE_ERROR in cats -> "ike error $code"
            VpnManager.CATEGORY_EVENT_NETWORK_ERROR in cats -> when (code) {
                VpnManager.ERROR_CODE_NETWORK_PROTOCOL_TIMEOUT -> "network: timeout"
                VpnManager.ERROR_CODE_NETWORK_LOST -> "network: lost"
                VpnManager.ERROR_CODE_NETWORK_UNKNOWN_HOST -> "network: unknown host"
                else -> "network error $code"
            }
            VpnManager.CATEGORY_EVENT_DEACTIVATED_BY_USER in cats -> "stopped"
            VpnManager.CATEGORY_EVENT_ALWAYS_ON_STATE_CHANGED in cats -> null
            else -> null
        }
        VpnEvents.lastEvent.value = event
        if (event != null) {
            NagoLog.init(context)
            NagoLog.add("ikev2: $event")
        }
    }
}
