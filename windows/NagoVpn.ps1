# NAGO VPN - Windows 클라이언트 (IKEv2 + EAP-MSCHAPv2)
# Windows 내장 VPN을 사용하므로 별도 드라이버/엔진이 필요 없습니다.
# ps2exe 로 .exe 로 빌드할 수 있습니다 (build-exe.ps1 참고).

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$VpnName  = 'NAGO VPN'
$Server   = '141.164.54.197'        # 서울 Vultr strongSwan 서버 공인 IP (인증서 ID도 이 IP)
# ps2exe로 만든 exe에서는 $PSScriptRoot가 비어 있을 수 있다 → exe가 있는 폴더
$Here     = if ($PSScriptRoot) { $PSScriptRoot } else { [System.AppDomain]::CurrentDomain.BaseDirectory }
$CaPath   = Join-Path $Here 'ca-cert.pem'

# 서버 루트 CA(공개, server/ca-cert.pem과 같음). exe 옆에 ca-cert.pem이 없어도 설치되게 넣어 둔다
$CaPem = @'
-----BEGIN CERTIFICATE-----
MIIERDCCAqygAwIBAgITc7UO9t6wNAYv9M/pzjOBYC62sDANBgkqhkiG9w0BAQsF
ADAqMRkwFwYDVQQDDBBOQUdPIFZQTiBSb290IENBMQ0wCwYDVQQKDAROQUdPMB4X
DTI2MTEyMjE0MzYzMVoXDTM2MTExOTE0MzYzMVowKjEZMBcGA1UEAwwQTkFHTyBW
UE4gUm9vdCBDQTENMAsGA1UECgwETkFHTzCCAaIwDQYJKoZIhvcNAQEBBQADggGP
ADCCAYoCggGBAMEOixE2QnYPNuDgmj7j64aNNvn7uA0jCNOSf7zP5Iaua/7Y1cmQ
d4B3HhZ6zONaWMgH03EWSZK3W5ZHUQsV8tsGtz6VLXAxkWxUWK/kMvfvRyAN5g4M
7lfw5fNXlplfIUf8MkxWqT2hDm1nd28aeKlu+IHue7BYYu4KK6l+CUtoVdIP4wV2
I5x/s6vA0yD1AlPP5RWSQDbKBHwKsh+i7oHxSVkmZlHECaUGs4tz5apt3GH0EJjG
vHys6c+prRcILIumeD/3TcE6nNOwP9SVH5r63aJSrjDKrOraJ/eZlqHRjL53+hyS
zP4oveEmU6fnVV6XNArNpp0HcWboOk0+y78r191rLa3afpX+T9wmLdfc58EEAoOG
4bHkLg1alWw9rnMTyQFRimaoWprLH0k/S0K+WVBGk3wL5t4fcZucTGs5xeI4qyVV
00BLLH2DGPhlHUnBWIjw3hsWeb9/vkOsILjrYYmIHfksw5MV+bthA6GVp4ddmWEV
7dy9zjp8G3zcBQIDAQABo2MwYTAfBgNVHSMEGDAWgBRX42xWhJ0XY9lsf9+D6lBI
DSw2RDAPBgNVHRMBAf8EBTADAQH/MA4GA1UdDwEB/wQEAwIBBjAdBgNVHQ4EFgQU
V+NsVoSdF2PZbH/fg+pQSA0sNkQwDQYJKoZIhvcNAQELBQADggGBAD/jRpS/UF1n
E9yi1bNZx/r4WVn7d1mxe5kLGjCTRS8ezXv+8qDZ09QxNNmT92OrXawmRE6X3hzw
9Q9rdVfitWVobVi9YSzchYuQN8NNc/1kdmOFyGFaQmyTR/bNVhCzOHbWevXXhNGZ
eVHM2ZmpLars9i0xnvoZCgHgVwgua8MXl9NBWlaoL5S3e14lq1MK9NQzJe2CVtsC
lyE4Qvgg3VpX034qy1uOCqUGnDRyQeR3d8aEvnAGuXtoXyWAZO4+x5c3pO/bW2os
4frxJDM5Tk6XoTdNLmvB833j6HHgDp37+xor8Gg27z0/o+aR4u/7zFoU8G6znROe
cPG4rEPnkAGHZK0vq7AOgny0Z+bGwyKUPnTWVw+5VJtDA9VOe2FRrobNccgS/UPM
p6LuYck9lba8ti0f2Oak9+7XjaYzVOc53U1lwV1DMpk1NJTGGyTmpGT0h7kcAoY8
T2FF0UkK71ux14HRM1A2vLkbyVu6NWJd//p9xfTeG3VNHdZUm/N2Mg==
-----END CERTIFICATE-----
'@

function Ensure-CaTrusted {
    # 자체 서명 CA를 '신뢰할 수 있는 루트 인증 기관'에 설치(관리자 권한 필요, 최초 1회)
    if (Test-Path $CaPath) {
        $cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 $CaPath
    } else {
        $b64 = ($CaPem -split "`n" | Where-Object { $_ -and $_ -notmatch '-----' }) -join ''
        $cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 (, [Convert]::FromBase64String($b64.Trim()))
    }
    $store = New-Object System.Security.Cryptography.X509Certificates.X509Store('Root','LocalMachine')
    $store.Open('ReadWrite')
    if (-not ($store.Certificates | Where-Object { $_.Thumbprint -eq $cert.Thumbprint })) {
        $store.Add($cert)
    }
    $store.Close()
}

function Set-VpnProfile {
    if (Get-VpnConnection -Name $VpnName -ErrorAction SilentlyContinue) {
        Remove-VpnConnection -Name $VpnName -Force -ErrorAction SilentlyContinue
    }
    Add-VpnConnection -Name $VpnName -ServerAddress $Server `
        -TunnelType Ikev2 -AuthenticationMethod Eap `
        -EncryptionLevel Required -RememberCredential -Force
    # EAP-MSCHAPv2(사용자 이름/비밀번호) 설정
    Set-VpnConnection -Name $VpnName -EapConfigXml (Get-EapMschapv2Xml) -ErrorAction SilentlyContinue
    # 윈도우 기본 IKEv2 제안(DH 그룹 2·SHA1)은 서버(strongSwan: aes256-sha256-modp2048, ESP aes256gcm16)와
    # 안 맞아서 "정책 일치 오류"가 난다 → 서버가 받는 조합으로 고정
    Set-VpnConnectionIPsecConfiguration -ConnectionName $VpnName `
        -EncryptionMethod AES256 -IntegrityCheckMethod SHA256 -DHGroup Group14 `
        -CipherTransformConstants GCMAES256 -AuthenticationTransformConstants GCMAES256 -PfsGroup None -Force
}

function Get-EapMschapv2Xml {
@'
<EapHostConfig xmlns="http://www.microsoft.com/provisioning/EapHostConfig"><EapMethod><Type xmlns="http://www.microsoft.com/provisioning/EapCommon">26</Type><VendorId xmlns="http://www.microsoft.com/provisioning/EapCommon">0</VendorId><VendorType xmlns="http://www.microsoft.com/provisioning/EapCommon">0</VendorType><AuthorId xmlns="http://www.microsoft.com/provisioning/EapCommon">0</AuthorId></EapMethod><Config xmlns="http://www.microsoft.com/provisioning/EapHostConfig"><Eap xmlns="http://www.microsoft.com/provisioning/BaseEapConnectionPropertiesV1"><Type>26</Type><EapType xmlns="http://www.microsoft.com/provisioning/MsChapV2ConnectionPropertiesV1"><UseWinLogonCredentials>false</UseWinLogonCredentials></EapType></Eap></Config></EapHostConfig>
'@
}

function Connect-Vpn($user, $pass) {
    # rasdial 로 사용자 이름/비밀번호를 넘겨 연결
    $out = & rasdial $VpnName $user $pass 2>&1
    return ($LASTEXITCODE -eq 0), ($out -join "`n")
}

function Disconnect-Vpn { & rasdial $VpnName /disconnect 2>&1 | Out-Null }

# ---------------- GUI ----------------
$form = New-Object Windows.Forms.Form
$form.Text = 'NAGO VPN'
$form.Size = New-Object Drawing.Size(360, 300)
$form.StartPosition = 'CenterScreen'
$form.FormBorderStyle = 'FixedDialog'
$form.MaximizeBox = $false

function Add-Label($text,$y) {
    $l = New-Object Windows.Forms.Label
    $l.Text = $text; $l.Location = New-Object Drawing.Point(20,$y)
    $l.AutoSize = $true; $form.Controls.Add($l)
}
function Add-Box($y,$pw=$false) {
    $t = New-Object Windows.Forms.TextBox
    $t.Location = New-Object Drawing.Point(20,$y)
    $t.Size = New-Object Drawing.Size(300,24)
    if ($pw) { $t.UseSystemPasswordChar = $true }
    $form.Controls.Add($t); return $t
}

Add-Label '서버 주소' 15
$srvBox = Add-Box 35; $srvBox.Text = $Server
Add-Label '사용자 이름' 70
$userBox = Add-Box 90; $userBox.Text = 'wifiscan'
Add-Label '비밀번호' 125
$passBox = Add-Box 145 $true

$status = New-Object Windows.Forms.Label
$status.Location = New-Object Drawing.Point(20,180)
$status.AutoSize = $true; $status.Text = '대기 중'
$form.Controls.Add($status)

$connectBtn = New-Object Windows.Forms.Button
$connectBtn.Text = '연결'
$connectBtn.Location = New-Object Drawing.Point(20,210)
$connectBtn.Size = New-Object Drawing.Size(140,34)
$form.Controls.Add($connectBtn)

$disconnectBtn = New-Object Windows.Forms.Button
$disconnectBtn.Text = '연결 끊기'
$disconnectBtn.Location = New-Object Drawing.Point(180,210)
$disconnectBtn.Size = New-Object Drawing.Size(140,34)
$form.Controls.Add($disconnectBtn)

$connectBtn.Add_Click({
    $status.Text = '설정 중…'; $form.Refresh()
    try {
        Ensure-CaTrusted
        $script:Server = $srvBox.Text.Trim()
        Set-VpnProfile
        $ok, $msg = Connect-Vpn $userBox.Text.Trim() $passBox.Text
        $status.Text = if ($ok) { '연결됨' } else { "실패: $msg" }
    } catch {
        $status.Text = "오류: $($_.Exception.Message)"
    }
})

$disconnectBtn.Add_Click({
    Disconnect-Vpn
    $status.Text = '연결 끊김'
})

[void]$form.ShowDialog()
