#define AppVersion "0.5.8"
#ifndef PayloadRoot
  #define PayloadRoot "payload"
#endif
#ifndef InstallerOutput
  #define InstallerOutput "out"
#endif

[Setup]
AppId={{8E1C8179-C475-4BC7-A797-5E769E477C0C}
AppName=映屿
AppVersion={#AppVersion}
AppVerName=映屿 测试版 {#AppVersion}
AppPublisher=映屿
DefaultDirName=C:\Yingyu
DefaultGroupName=映屿
UsePreviousAppDir=yes
UsePreviousGroup=yes
UsePreviousTasks=yes
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
OutputDir={#InstallerOutput}
OutputBaseFilename=Yingyu-Setup-x64-{#AppVersion}
SetupIconFile={#PayloadRoot}\Assets\YingyuAppIcon.ico
UninstallDisplayIcon={app}\Yingyu.exe
UninstallDisplayName=映屿 测试版 {#AppVersion}
VersionInfoVersion=0.5.8.0
VersionInfoProductVersion={#AppVersion}
VersionInfoDescription=映屿 测试版 {#AppVersion} 安装程序
Compression=lzma2/normal
SolidCompression=yes
WizardStyle=modern
CloseApplications=yes
CloseApplicationsFilter=Yingyu.exe,Yingyu.dll,Yingyu.Core.dll,Yingyu.Update.dll,Yingyu.LogCenter.exe
RestartApplications=no
SetupLogging=yes

[Languages]
Name: "chinesesimplified"; MessagesFile: "compiler:Languages\ChineseSimplified.isl"

[Files]
Source: "{#PayloadRoot}\*"; DestDir: "{app}"; Excludes: "Cache\*"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\映屿"; Filename: "{app}\Yingyu.exe"; WorkingDir: "{app}"
Name: "{userdesktop}\映屿"; Filename: "{app}\Yingyu.exe"; WorkingDir: "{app}"; Check: DesktopShortcutMissing

[InstallDelete]
Type: files; Name: "{app}\Components\NativeDolby\Yingyu.NativeDolby.dll"
Type: files; Name: "{group}\映屿日志中心.lnk"

[Run]
Filename: "{app}\Yingyu.exe"; Description: "启动映屿"; Flags: nowait postinstall skipifsilent unchecked

[Code]
const
  CacheOwner = 'Yingyu:8E1C8179-C475-4BC7-A797-5E769E477C0C';
  CacheMarker = '.yingyu-cache-owner-v1';
  ReparsePoint = $400;
var
  KeepPersonalInformation: Boolean;

function DesktopShortcutMissing: Boolean;
begin
  Result := not FileExists(ExpandConstant('{userdesktop}\映屿.lnk')) and
    not FileExists(ExpandConstant('{commondesktop}\映屿.lnk'));
end;

function GetFileAttributesW(lpFileName: String): LongWord;
  external 'GetFileAttributesW@kernel32.dll stdcall';

function Canonical(Path: String): String;
begin
  Result := RemoveBackslashUnlessRoot(ExpandFileName(Path));
end;

function NoLinks(Path: String): Boolean;
var
  Current, Parent: String;
  Attributes: LongWord;
begin
  Result := False;
  Current := Canonical(Path);
  repeat
    Attributes := GetFileAttributesW(Current);
    if (Attributes <> $FFFFFFFF) and ((Attributes and ReparsePoint) <> 0) then exit;
    Parent := ExtractFileDir(Current);
    if CompareText(Parent, Current) = 0 then break;
    Current := Parent;
  until Current = '';
  Result := True;
end;

function StrictChild(Parent, Target: String): Boolean;
begin
  Parent := AddBackslash(Canonical(Parent));
  Target := Canonical(Target);
  Result := (Length(Target) > Length(Parent)) and
    (CompareText(Copy(Target, 1, Length(Parent)), Parent) = 0);
end;

function TreeSafe(Root, Current: String): Boolean;
var
  Find: TFindRec;
  Target: String;
begin
  Result := False;
  if not ((CompareText(Canonical(Root), Canonical(Current)) = 0) or StrictChild(Root, Current)) then exit;
  if not NoLinks(Current) then exit;
  if FindFirst(AddBackslash(Current) + '*', Find) then
  begin
    try
      repeat
        if (Find.Name <> '.') and (Find.Name <> '..') then
        begin
          Target := AddBackslash(Current) + Find.Name;
          if (Find.Attributes and ReparsePoint) <> 0 then exit;
          if ((Find.Attributes and FILE_ATTRIBUTE_DIRECTORY) <> 0) and not TreeSafe(Root, Target) then exit;
        end;
      until not FindNext(Find);
    finally
      FindClose(Find);
    end;
  end;
  Result := True;
end;

function PrepareToInstall(var NeedsRestart: Boolean): String;
var
  AppRoot: String;
begin
  Result := '';
  AppRoot := Canonical(ExpandConstant('{app}'));
  if (Length(AppRoot) <= 3) or (Copy(AppRoot, 2, 2) <> ':\') then
    Result := '请选择本机磁盘上的映屿专用安装文件夹。'
  else if not NoLinks(AppRoot) or not NoLinks(AddBackslash(AppRoot) + 'Cache') then
    Result := '安装路径包含目录链接，请选择普通文件夹。';
end;

procedure CurStepChanged(CurStep: TSetupStep);
var
  Root, Marker: String;
  Existing: AnsiString;
begin
  if CurStep <> ssPostInstall then exit;
  Root := ExpandConstant('{app}\Cache');
  if not NoLinks(Root) then RaiseException('缓存路径包含链接，未写入。');
  if not ForceDirectories(Root) then RaiseException('无法创建安装目录下的 Cache，没有改用其他磁盘。');
  Marker := AddBackslash(Root) + CacheMarker;
  if FileExists(Marker) then
  begin
    if not LoadStringFromFile(Marker, Existing) or (Existing <> CacheOwner) then
      RaiseException('缓存目录的应用身份不匹配，原文件已保留。');
  end
  else if not SaveStringToFile(Marker, CacheOwner, False) then
    RaiseException('缓存归属记录写入失败，没有改用其他磁盘。');
end;

function InitializeUninstall: Boolean;
var
  Form: TSetupForm;
  Keep: TNewCheckBox;
  Explanation: TNewStaticText;
  ConfirmButton, CancelButton: TNewButton;
begin
  KeepPersonalInformation := True;
  Result := True;
  if UninstallSilent then exit;
  Form := CreateCustomForm(ScaleX(440), ScaleY(185), False, False);
  try
    Form.Caption := '卸载映屿';
    Explanation := TNewStaticText.Create(Form);
    Explanation.Parent := Form;
    Explanation.SetBounds(ScaleX(20), ScaleY(18), ScaleX(400), ScaleY(65));
    Explanation.WordWrap := True;
    Explanation.Caption := '卸载软件后，可保留账号、设置、观看进度及当前缓存。取消勾选将清除这些资料，下载的影片和旧缓存迁移源仍保留。';
    Keep := TNewCheckBox.Create(Form);
    Keep.Parent := Form;
    Keep.SetBounds(ScaleX(20), ScaleY(91), ScaleX(400), ScaleY(24));
    Keep.Caption := '保留个人信息（账号、设置、观看进度和缓存）';
    Keep.Checked := True;
    ConfirmButton := TNewButton.Create(Form);
    ConfirmButton.Parent := Form;
    ConfirmButton.SetBounds(ScaleX(232), ScaleY(140), ScaleX(90), ScaleY(28));
    ConfirmButton.Caption := '卸载'; ConfirmButton.ModalResult := mrOk; ConfirmButton.Default := True;
    CancelButton := TNewButton.Create(Form);
    CancelButton.Parent := Form;
    CancelButton.SetBounds(ScaleX(330), ScaleY(140), ScaleX(90), ScaleY(28));
    CancelButton.Caption := '取消'; CancelButton.ModalResult := mrCancel; CancelButton.Cancel := True;
    Result := Form.ShowModal = mrOk;
    if Result then KeepPersonalInformation := Keep.Checked;
  finally
    Form.Free;
  end;
end;

procedure DeleteExactTree(Parent, Name: String);
var
  Target: String;
begin
  Target := AddBackslash(Canonical(Parent)) + Name;
  if not DirExists(Target) then exit;
  if not StrictChild(Parent, Target) or not TreeSafe(Target, Target) then
    RaiseException('个人资料目录包含链接或越界路径，已保留，请手动处理。');
  if not DelTree(Target, True, True, True) then
    RaiseException('个人资料清理未完成，请关闭占用该目录的程序后重试。');
end;

procedure DeletePersonalFile(Root, Name: String);
var
  Target: String;
begin
  Target := AddBackslash(Canonical(Root)) + Name;
  if not FileExists(Target) then exit;
  if not StrictChild(Root, Target) or not NoLinks(Target) then
    RaiseException('个人资料路径不安全，未删除。');
  if not DeleteFile(Target) then RaiseException('个人资料文件清理未完成。');
end;

function IsGuidStagingName(Name, BaseName: String): Boolean;
var
  Index, PrefixLength: Integer;
  Token: String;
begin
  Result := False;
  PrefixLength := Length(BaseName) + 1;
  if Length(Name) <> PrefixLength + 32 + 4 then exit;
  if CompareText(Copy(Name, 1, PrefixLength), BaseName + '.') <> 0 then exit;
  if CompareText(Copy(Name, PrefixLength + 33, 4), '.tmp') <> 0 then exit;
  Token := Copy(Name, PrefixLength + 1, 32);
  for Index := 1 to 32 do
    if Pos(Token[Index], '0123456789abcdefABCDEF') = 0 then exit;
  Result := True;
end;

procedure DeleteGuidPersonalStaging(Root, BaseName: String);
var
  Find: TFindRec;
begin
  { Enumerate one known store basename; deletion still requires the exact GUID shape. }
  if FindFirst(AddBackslash(Canonical(Root)) + BaseName + '.*.tmp', Find) then
  begin
    try
      repeat
        if ((Find.Attributes and FILE_ATTRIBUTE_DIRECTORY) = 0) and
          IsGuidStagingName(Find.Name, BaseName) then
          DeletePersonalFile(Root, Find.Name);
      until not FindNext(Find);
    finally
      FindClose(Find);
    end;
  end;
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
var
  AppRoot, CacheRoot, DataRoot: String;
  Owner: AnsiString;
begin
  if (CurUninstallStep <> usUninstall) or KeepPersonalInformation then exit;
  AppRoot := Canonical(ExpandConstant('{app}'));
  CacheRoot := AddBackslash(AppRoot) + 'Cache';
  DataRoot := Canonical(ExpandConstant('{localappdata}\映屿'));
  if (Length(AppRoot) <= 3) or not NoLinks(AppRoot) or not NoLinks(DataRoot) then
    RaiseException('当前安装或个人资料路径不安全，资料已保留。');
  if DirExists(CacheRoot) then
  begin
    if not LoadStringFromFile(AddBackslash(CacheRoot) + CacheMarker, Owner) or (Owner <> CacheOwner) then
      RaiseException('无法确认当前 Cache 归属，已保留。');
    DeleteExactTree(AppRoot, 'Cache');
  end;
  { Exact personal-data names only. Never delete Downloads or the whole app/data root. }
  DeletePersonalFile(DataRoot, 'server-profiles.json');
  DeletePersonalFile(DataRoot, 'server-profiles.backup.json');
  DeletePersonalFile(DataRoot, 'session.json');
  DeletePersonalFile(DataRoot, 'session.backup.json');
  DeletePersonalFile(DataRoot, 'desktop-library.json');
  DeletePersonalFile(DataRoot, 'preferences.json');
  DeletePersonalFile(DataRoot, 'window.json');
  DeletePersonalFile(DataRoot, 'device.id');
  DeletePersonalFile(DataRoot, 'video-cache-settings-v1.json');
  DeletePersonalFile(DataRoot, 'image-policy.json');
  DeletePersonalFile(DataRoot, 'browse-refresh.txt');
  DeletePersonalFile(DataRoot, 'desktop-theme.json');
  DeletePersonalFile(DataRoot, 'actor-cache-settings.json');
  { Interrupted writes from the actual stores; no arbitrary *.tmp cleanup. }
  DeletePersonalFile(DataRoot, 'server-profiles.json.tmp');
  DeletePersonalFile(DataRoot, 'server-profiles.backup.json.tmp');
  DeletePersonalFile(DataRoot, 'session.json.tmp');
  DeletePersonalFile(DataRoot, 'preferences.json.tmp');
  DeletePersonalFile(DataRoot, 'window.json.tmp');
  DeletePersonalFile(DataRoot, 'image-policy.json.tmp');
  DeletePersonalFile(DataRoot, 'browse-refresh.txt.tmp');
  DeleteGuidPersonalStaging(DataRoot, 'desktop-library.json');
  DeleteGuidPersonalStaging(DataRoot, 'video-cache-settings-v1.json');
  DeleteGuidPersonalStaging(DataRoot, 'desktop-theme.json');
  DeleteGuidPersonalStaging(DataRoot, 'actor-cache-settings.json');
  DeleteExactTree(DataRoot, '日志');
  { PlaybackSync is personal progress despite its historical Cache parent. }
  DeleteExactTree(DataRoot, 'Cache\PlaybackSync');
end;
