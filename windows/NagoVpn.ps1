# NAGO VPN - Windows 클라이언트 (IKEv2 + EAP-MSCHAPv2)
# Windows 내장 VPN을 사용하므로 별도 드라이버/엔진이 필요 없습니다.
# ps2exe 로 .exe 로 빌드할 수 있습니다 (build-exe.ps1 참고).

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$VpnName  = 'NAGO VPN'
$Server   = '3.38.243.135'          # AWS strongSwan 서버 공인 IP
$CaPath   = Join-Path $PSScriptRoot 'ca-cert.pem'

function Ensure-CaTrusted {
    # 자체 서명 CA를 '신뢰할 수 있는 루트 인증 기관'에 설치(관리자 권한 필요, 최초 1회)
    if (-not (Test-Path $CaPath)) { return }
    $cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 $CaPath
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
