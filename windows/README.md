# NAGO VPN (Windows)

iOS 앱과 **같은 AWS strongSwan 서버**(IKEv2 + EAP-MSCHAPv2)에 붙는 Windows 클라이언트입니다.
Windows 내장 VPN을 쓰므로 별도 드라이버/엔진 설치가 필요 없고, PowerShell GUI를 `.exe`로 빌드합니다.

## 포함 파일

| 파일 | 설명 |
|---|---|
| `NagoVpn.ps1` | VPN 프로파일 생성 + 연결/끊기 GUI 앱 |
| `build-exe.ps1` | 위 스크립트를 `NagoVpn.exe`로 빌드 |
| `ca-cert.pem` | 서버 루트 CA(공개). 최초 1회 신뢰 설치에 사용 |

## exe 만들기

```powershell
cd windows
powershell -ExecutionPolicy Bypass -File build-exe.ps1
```

`ps2exe` 모듈을 자동 설치하고 `NagoVpn.exe`를 만듭니다. (관리자 권한으로 실행되도록 빌드됨 — CA를 시스템 루트 저장소에 넣기 위함)

## 사용

1. `NagoVpn.exe` 실행(UAC 허용) → 서버 주소/사용자 이름/비밀번호 입력
2. **연결** 클릭
   - 최초 1회 자체 서명 CA를 신뢰 루트에 설치하고
   - `NAGO VPN` 프로파일을 만든 뒤 `rasdial`로 접속합니다
3. 끊을 때는 **연결 끊기**

> 비밀번호는 저장소에 없습니다(채팅으로 별도 전달). 서버 구축/재현은 [`../server/README.md`](../server/README.md) 참고.

## 빌드 없이 바로 쓰기

exe 없이도 PowerShell에서 바로 실행할 수 있습니다:

```powershell
powershell -ExecutionPolicy Bypass -File NagoVpn.ps1
```
(단, CA 설치 단계는 관리자 권한 PowerShell에서 실행해야 합니다.)
