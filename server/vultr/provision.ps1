<#
NAGO VPN - Vultr에 서버 4대(kr/jp/us/uk)와 방화벽 그룹을 만든다. 이미 있으면(같은 라벨) 건너뛴다.
윈도우 PowerShell 5.1에서 그대로 돈다.

  $env:VULTR_API_KEY = '<Vultr API 키>'     # Vultr 계정 → Account → API (내 IP를 Access Control에 추가)
  .\provision.ps1 -SshPublicKey "$HOME\.ssh\id_ed25519.pub"
  .\provision.ps1 -WhatIf                    # 만들지 않고 무엇을 할지만 보기

만드는 것
  - 방화벽 그룹 nago-vpn: udp 500/4500(IKEv2), udp 51820/443(WireGuard), tcp 22(SSH), tcp 80/443(서울 API·인증서), icmp
  - 서버: Ubuntu 22.04, 라벨 nago-<code>, IPv6 끔. 플랜/지역은 아래 $Nodes에서 바꾼다
끝나면 control.json의 nodes에 넣을 값(addr, vultr_id)을 출력한다.
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$SshPublicKey,
    [string]$OsName = 'Ubuntu 22.04 LTS x64'
)
$ErrorActionPreference = 'Stop'

# code, Vultr 지역, 플랜. 요금은 Vultr 가격표 기준으로 control.json에 따로 적는다.
$Nodes = @(
    @{ code = 'kr'; region = 'icn'; plan = 'vc2-2c-4gb' },
    @{ code = 'jp'; region = 'nrt'; plan = 'vc2-1c-2gb' },
    @{ code = 'us'; region = 'sea'; plan = 'vc2-1c-2gb' },
    @{ code = 'uk'; region = 'lhr'; plan = 'vc2-1c-2gb' }
)

if (-not $env:VULTR_API_KEY) { throw 'VULTR_API_KEY 환경 변수를 먼저 설정하세요.' }
$Api = 'https://api.vultr.com/v2'
$Headers = @{ Authorization = "Bearer $($env:VULTR_API_KEY)" }
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

function Invoke-Vultr([string]$Method, [string]$Path, $Body) {
    $params = @{ Method = $Method; Uri = "$Api$Path"; Headers = $Headers }
    if ($null -ne $Body) {
        $params.Body = [Text.Encoding]::UTF8.GetBytes(($Body | ConvertTo-Json -Depth 5 -Compress))
        $params.ContentType = 'application/json'
    }
    Invoke-RestMethod @params
}

# --- OS
$os = (Invoke-Vultr GET '/os?per_page=500' $null).os | Where-Object { $_.name -eq $OsName } | Select-Object -First 1
if (-not $os) { throw "OS '$OsName'를 찾지 못했습니다." }
Write-Host "OS: $($os.name) (id $($os.id))"

# --- SSH 키 (선택)
$sshKeyIds = @()
if ($SshPublicKey) {
    $pub = (Get-Content -Raw $SshPublicKey).Trim()
    $existing = (Invoke-Vultr GET '/ssh-keys?per_page=500' $null).ssh_keys | Where-Object { $_.ssh_key.Trim() -eq $pub }
    if ($existing) {
        $sshKeyIds = @($existing[0].id)
        Write-Host "SSH 키: 이미 등록됨 ($($existing[0].name))"
    } elseif ($PSCmdlet.ShouldProcess('ssh key nago-admin', 'create')) {
        $sshKeyIds = @((Invoke-Vultr POST '/ssh-keys' @{ name = 'nago-admin'; ssh_key = $pub }).ssh_key.id)
        Write-Host 'SSH 키: nago-admin 등록'
    }
}

# --- 방화벽 그룹
$fw = (Invoke-Vultr GET '/firewalls?per_page=500' $null).firewall_groups | Where-Object { $_.description -eq 'nago-vpn' } | Select-Object -First 1
if (-not $fw -and $PSCmdlet.ShouldProcess('firewall group nago-vpn', 'create')) {
    $fw = (Invoke-Vultr POST '/firewalls' @{ description = 'nago-vpn' }).firewall_group
    $rules = @(
        @{ protocol = 'udp'; port = '500';   notes = 'IKE' },
        @{ protocol = 'udp'; port = '4500';  notes = 'IKE NAT-T' },
        @{ protocol = 'udp'; port = '51820'; notes = 'WireGuard' },
        @{ protocol = 'udp'; port = '443';   notes = 'WireGuard (443->51820)' },
        @{ protocol = 'tcp'; port = '22';    notes = 'SSH' },
        @{ protocol = 'tcp'; port = '80';    notes = 'ACME http-01 (kr)' },
        @{ protocol = 'tcp'; port = '443';   notes = 'control API (kr)' },
        @{ protocol = 'icmp'; port = '';     notes = 'ping / PMTU' }
    )
    foreach ($r in $rules) {
        $body = @{ ip_type = 'v4'; protocol = $r.protocol; subnet = '0.0.0.0'; subnet_size = 0; notes = $r.notes }
        if ($r.port) { $body.port = $r.port }
        Invoke-Vultr POST "/firewalls/$($fw.id)/rules" $body | Out-Null
    }
    Write-Host "방화벽 그룹 nago-vpn 만듦 ($($fw.id))"
} elseif ($fw) {
    Write-Host "방화벽 그룹 nago-vpn: 이미 있음 ($($fw.id))"
}

# --- 서버
$all = (Invoke-Vultr GET '/instances?per_page=500' $null).instances
foreach ($n in $Nodes) {
    $label = "nago-$($n.code)"
    if ($all | Where-Object { $_.label -eq $label }) { Write-Host "$label : 이미 있음"; continue }
    if (-not $PSCmdlet.ShouldProcess("$label ($($n.region), $($n.plan))", 'create instance')) { continue }
    $body = @{
        region = $n.region; plan = $n.plan; os_id = $os.id; label = $label; hostname = $label
        enable_ipv6 = $false; backups = 'disabled'
    }
    if ($fw) { $body.firewall_group_id = $fw.id }
    if ($sshKeyIds.Count) { $body.sshkey_id = $sshKeyIds }
    $inst = (Invoke-Vultr POST '/instances' $body).instance
    Write-Host "$label : 만드는 중 ($($inst.id))"
    if ($inst.default_password) { Write-Host "  root 비밀번호는 Vultr 콘솔에서 확인하세요." }
}

if ($WhatIfPreference) { return }

# --- IP가 붙을 때까지 기다렸다가 control.json용 값 출력
Write-Host "`nIP 기다리는 중..."
$deadline = (Get-Date).AddMinutes(5)
do {
    Start-Sleep -Seconds 5
    $mine = (Invoke-Vultr GET '/instances?per_page=500' $null).instances | Where-Object { $_.label -like 'nago-*' }
    $pending = $mine | Where-Object { $_.main_ip -eq '0.0.0.0' -or -not $_.main_ip }
} while ($pending -and (Get-Date) -lt $deadline)

$mine | Sort-Object label | Format-Table label, region, plan, main_ip, status, power_status, id -AutoSize
Write-Host 'control.json nodes에 넣을 값:'
foreach ($i in ($mine | Sort-Object label)) {
    Write-Host ('  {0}: "addr": "{1}", "vultr_id": "{2}"' -f $i.label.Substring(5), $i.main_ip, $i.id)
}
