
#define MyAppName "BMM Auto Motors"
#define MyAppVersion "0.1.0"
#define MyAppExeName "bmm_auto_motors.exe"

[Setup]
AppId={{6D7A92C1-5F31-4B86-9E21-8C6F4A72D103}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher=BMM Auto Motors
DefaultDirName={localappdata}\Programs\BMM Auto Motors
DefaultGroupName=BMM Auto Motors
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
OutputDir=installer-output
OutputBaseFilename=BMM-Auto-Motors-Setup
UninstallDisplayIcon={app}\{#MyAppExeName}
WizardStyle=modern
Compression=lzma2
SolidCompression=yes

[Tasks]
Name: "desktopicon"; Description: "Create a desktop shortcut"; GroupDescription: "Additional shortcuts:"; Flags: unchecked

[Files]
Source: "build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\BMM Auto Motors"; Filename: "{app}\{#MyAppExeName}"
Name: "{autodesktop}\BMM Auto Motors"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "Launch BMM Auto Motors"; Flags: postinstall nowait skipifsilent
