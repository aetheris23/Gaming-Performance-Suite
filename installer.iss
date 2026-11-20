; Inno Setup script for Gaming Performance Suite
; Build with: iscc installer.iss (requires Inno Setup 6)

#define MyAppName "Gaming Performance Suite"
#define MyAppVersion "3.2"
#define MyAppPublisher "Gaming Performance Suite"
#define MyAppURL "https://github.com/"
#define MyAppExeName "Start-GamingSuite.bat"

[Setup]
AppId={{B7F3E8A2-9C42-4D1B-8E56-7A2F9D3C8041}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
AppPublisherURL={#MyAppURL}
AppSupportURL={#MyAppURL}
AppUpdatesURL={#MyAppURL}
DefaultDirName={autopf}\{#MyAppName}
DefaultGroupName={#MyAppName}
AllowNoIcons=yes
OutputDir=.
OutputBaseFilename=GamingPerformanceSuite-Setup-{#MyAppVersion}
Compression=lzma2
SolidCompression=yes
UninstallDisplayIcon={app}\Start-GamingSuite.bat
PrivilegesRequired=admin

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked
Name: "startup"; Description: "Start watcher at user sign-in"; GroupDescription: "{cm:AdditionalIcons}"; Flags: checkedonce

[Files]
Source: "GamingPerformanceSuite.zip"; DestDir: "{tmp}"; Flags: deleteafterinstall
Source: "Start-GamingSuite.bat"; DestDir: "{app}"; Flags: ignoreversion
Source: "Start-Watcher-Hidden.bat"; DestDir: "{app}"; Flags: ignoreversion
Source: "Stop-GamingSuite.bat"; DestDir: "{app}"; Flags: ignoreversion
Source: "README.md"; DestDir: "{app}"; Flags: ignoreversion
Source: ".gitignore"; DestDir: "{app}"; Flags: ignoreversion
Source: "src\*"; DestDir: "{app}\src"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\{#MyAppName}"; Filename: "{app}\Start-GamingSuite.bat"
Name: "{group}\Stop Gaming Performance Suite"; Filename: "{app}\Stop-GamingSuite.bat"
Name: "{commondesktop}\{#MyAppName}"; Filename: "{app}\Start-GamingSuite.bat"; Tasks: desktopicon

[Run]
Filename: "{app}\Start-Watcher-Hidden.bat"; Description: "{cm:LaunchProgram,{#StringChange(MyAppName, '&', '&&')}}"; Flags: nowait postinstall skipifsilent

[UninstallRun]
Filename: "{cmd}"; Parameters: "/c """"{app}\Stop-GamingSuite.bat"""" & timeout /t 2 >nul"; Flags: runhidden

[Registry]
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; ValueType: string; ValueName: "GamingPerformanceSuiteAutoStart"; ValueData: "powershell.exe -WindowStyle Hidden -ExecutionPolicy Bypass -File ""{app}\src\Main.ps1"" -AutoStart"; Flags: uninsdeletevalue; Tasks: startup

[Code]
function InitializeSetup(): Boolean;
begin
  Result := True;
end;
