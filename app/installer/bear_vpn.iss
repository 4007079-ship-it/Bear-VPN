; Установщик Bear VPN для Windows (Inno Setup 6).
; Собирается в CI: iscc /DAppVersion=0.1.0 /DSourceDir=<папка Release> bear_vpn.iss

#ifndef AppVersion
  #define AppVersion "0.0.0"
#endif
#ifndef SourceDir
  #define SourceDir "..\build\windows\x64\runner\Release"
#endif

[Setup]
AppId={{7C1F3B52-9E4A-4C6B-B1D7-BEA2F0E5A001}
AppName=Bear VPN
AppVersion={#AppVersion}
AppVerName=Bear VPN {#AppVersion}
AppPublisher=SMV
AppPublisherURL=https://github.com/4007079-ship-it/Bear-VPN
DefaultDirName={autopf}\Bear VPN
DefaultGroupName=Bear VPN
DisableProgramGroupPage=yes
OutputDir=..\build\installer
OutputBaseFilename=Bear-VPN-{#AppVersion}-windows-setup
SetupIconFile=..\branding\windows\app_icon.ico
UninstallDisplayIcon={app}\BearVPN.exe
UninstallDisplayName=Bear VPN
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
; Закрыть работающий Bear VPN перед обновлением/удалением — он сам вернёт
; настройки прокси Windows при закрытии.
CloseApplications=yes
RestartApplications=no
PrivilegesRequired=admin

[Languages]
Name: "ru"; MessagesFile: "compiler:Languages\Russian.isl"
Name: "en"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\Bear VPN"; Filename: "{app}\BearVPN.exe"
Name: "{group}\{cm:UninstallProgram,Bear VPN}"; Filename: "{uninstallexe}"
Name: "{autodesktop}\Bear VPN"; Filename: "{app}\BearVPN.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\BearVPN.exe"; Description: "{cm:LaunchProgram,Bear VPN}"; Flags: nowait postinstall skipifsilent

[UninstallRun]
; Если ядро осталось после аварийного завершения — остановить его.
Filename: "{sys}\taskkill.exe"; Parameters: "/F /IM xray.exe /T"; Flags: runhidden; RunOnceId: "KillXray"
Filename: "{sys}\taskkill.exe"; Parameters: "/F /IM tun2socks.exe /T"; Flags: runhidden; RunOnceId: "KillTun2socks"

[UninstallDelete]
Type: filesandordirs; Name: "{app}\xray"
