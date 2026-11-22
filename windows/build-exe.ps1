# NagoVpn.ps1 -> NagoVpn.exe 빌드 스크립트
# PowerShell(관리자 아님 OK)에서 이 파일이 있는 폴더로 이동 후 실행하세요.
#   powershell -ExecutionPolicy Bypass -File build-exe.ps1

if (-not (Get-Module -ListAvailable -Name ps2exe)) {
    Install-Module ps2exe -Scope CurrentUser -Force
}

Import-Module ps2exe

$src = Join-Path $PSScriptRoot 'NagoVpn.ps1'
$out = Join-Path $PSScriptRoot 'NagoVpn.exe'

# -requireAdmin: CA 인증서를 시스템 루트 저장소에 설치하려면 관리자 권한이 필요
# -noConsole: 콘솔 창 없이 GUI만 표시
$before = if (Test-Path $out) { (Get-Item $out).LastWriteTime } else { $null }
Invoke-ps2exe -InputFile $src -OutputFile $out -noConsole -requireAdmin `
    -title 'NAGO VPN' -product 'NAGO VPN' -version '1.1.1.0'

if ((Test-Path $out) -and (Get-Item $out).LastWriteTime -ne $before) {
    Write-Host "빌드 완료: $out"
} else {
    Write-Host "빌드 실패: $out 을(를) 쓰지 못함 (실행 중인 NagoVpn.exe를 닫고 다시)" -ForegroundColor Red
    exit 1
}
