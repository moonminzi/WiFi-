package com.nago.vpn

import android.content.Context
import android.net.Ikev2VpnProfile
import android.net.eap.EapSessionConfig
import android.net.ipsec.ike.ChildSaProposal
import android.net.ipsec.ike.IkeFqdnIdentification
import android.net.ipsec.ike.IkeIdentification
import android.net.ipsec.ike.IkeIpv4AddrIdentification
import android.net.ipsec.ike.IkeSaProposal
import android.net.ipsec.ike.IkeSessionParams
import android.net.ipsec.ike.IkeTunnelConnectionParams
import android.net.ipsec.ike.SaProposal
import android.net.ipsec.ike.TunnelModeChildSessionParams
import android.system.OsConstants
import java.net.Inet4Address
import java.net.InetAddress
import java.security.cert.CertificateFactory
import java.security.cert.X509Certificate

/**
 * 안드로이드 내장 IKEv2(VpnManager)용 프로필을 만든다.
 *
 * 간단한 Ikev2VpnProfile.Builder(서버, ID)는 서버 주소를 그대로 원격 ID로 쓰는데, 해외 서버는 켤 때마다
 * IP가 바뀌어서 인증서 ID를 FQDN(jp.nago.vpn)으로 두었다. 그래서 IkeSessionParams를 직접 만들어
 * "접속은 IP로, 인증서 확인은 FQDN으로" 한다(Android 13+).
 */
object NagoVpn {
    /** 서버 인증서를 서명한 CA. 앱에 들어 있어서 기기에 CA를 설치할 필요가 없다. */
    fun caCert(context: Context): X509Certificate =
        context.resources.openRawResource(R.raw.nago_ca).use {
            CertificateFactory.getInstance("X.509").generateCertificate(it) as X509Certificate
        }

    private fun identification(id: String): IkeIdentification {
        val isIpv4 = id.split('.').let { parts -> parts.size == 4 && parts.all { p -> p.toIntOrNull() in 0..255 } }
        return if (isIpv4) IkeIpv4AddrIdentification(InetAddress.getByName(id) as Inet4Address)
        else IkeFqdnIdentification(id)
    }

    fun profile(context: Context, target: Target, user: String, password: String): Ikev2VpnProfile {
        // IKE(제어용): 서버 제안 aes256-sha256-modp2048과 맞춘다(안드로이드 IKE는 ECP 그룹이 없음).
        val ikeSa = IkeSaProposal.Builder()
            .addEncryptionAlgorithm(SaProposal.ENCRYPTION_ALGORITHM_AES_CBC, SaProposal.KEY_LEN_AES_256)
            .addIntegrityAlgorithm(SaProposal.INTEGRITY_ALGORITHM_HMAC_SHA2_256_128)
            .addPseudorandomFunction(SaProposal.PSEUDORANDOM_FUNCTION_SHA2_256)
            .addDhGroup(SaProposal.DH_GROUP_2048_BIT_MODP)
            .build()

        val eap = EapSessionConfig.Builder()
            .setEapIdentity(user.toByteArray())
            .setEapMsChapV2Config(user, password)
            .build()

        val ike = IkeSessionParams.Builder()
            .setServerHostname(target.address)
            .setRemoteIdentification(identification(target.identifier))
            .setLocalIdentification(IkeFqdnIdentification(user))
            .setAuthEap(caCert(context), eap)
            .addIkeSaProposal(ikeSa)
            .build()

        // 데이터(ESP): AES-256-GCM(하드웨어 AES)을 먼저, 재키 때 서버가 GCM+PFS만 받는 경우를 위해 CBC도 같이 낸다.
        val gcm = ChildSaProposal.Builder()
            .addEncryptionAlgorithm(SaProposal.ENCRYPTION_ALGORITHM_AES_GCM_16, SaProposal.KEY_LEN_AES_256)
            .build()
        val cbc = ChildSaProposal.Builder()
            .addEncryptionAlgorithm(SaProposal.ENCRYPTION_ALGORITHM_AES_CBC, SaProposal.KEY_LEN_AES_256)
            .addIntegrityAlgorithm(SaProposal.INTEGRITY_ALGORITHM_HMAC_SHA2_256_128)
            .build()
        val child = TunnelModeChildSessionParams.Builder()
            .addChildSaProposal(gcm)
            .addChildSaProposal(cbc)
            .addInternalAddressRequest(OsConstants.AF_INET)
            .addInternalDnsServerRequest(OsConstants.AF_INET)
            .build()

        return Ikev2VpnProfile.Builder(IkeTunnelConnectionParams(ike, child))
            .setMaxMtu(1400)
            .setBypassable(false)
            .build()
    }
}
