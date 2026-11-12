; Build through tools/release.ps1. No administrator rights or game files are required.
#ifndef AppVersion
  #define AppVersion "0.0.0"
#endif
#ifndef PayloadDir
  #error PayloadDir must point to the staged release
#endif
#ifndef OutputPath
  #define OutputPath "..\dist"
#endif

[Setup]
AppId={{58234B10-6052-47CC-A295-6B04B8389684}
AppName=SentisClientOptimisation
AppVersion={#AppVersion}
AppPublisher=Sentis Project
DefaultDirName={localappdata}\Programs\SentisClientOptimisation
DisableDirPage=yes
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
MinVersion=10.0
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
WizardStyle=modern
SetupIconFile=..\package\SentisClientOptimisation.ico
UninstallDisplayIcon={app}\SentisClientOptimisation.ico
OutputDir={#OutputPath}
OutputBaseFilename=SentisClientOptimisation-{#AppVersion}-Setup
Compression=lzma2
SolidCompression=yes
CloseApplications=no
RestartApplications=no
SetupLogging=yes
VersionInfoVersion={#AppVersion}.0

[Languages]
Name: "russian"; MessagesFile: "compiler:Languages\Russian.isl"
Name: "english"; MessagesFile: "compiler:Default.isl"

[Files]
Source: "{#PayloadDir}\SentisClientOptimisation.dll"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#PayloadDir}\SentisClientOptimisation.ico"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#PayloadDir}\install.ps1"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#PayloadDir}\uninstall.ps1"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#PayloadDir}\install-pulsar.ps1"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#PayloadDir}\install-dotnet.ps1"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#PayloadDir}\install-transaction.ps1"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#PayloadDir}\README.txt"; DestDir: "{app}"; Flags: ignoreversion

[UninstallDelete]
Type: files; Name: "{app}\runtime.txt"

[Code]
var
  RuntimePage: TInputOptionWizardPage;
  TransactionStarted, Completed, CleanPrevious: Boolean;
  SavedRuntime: String;
  TransactionAction: String;

function SelectedRuntime(): String;
begin
  Result := ExpandConstant('{param:RUNTIME|}');
  if Result = '' then Result := SavedRuntime;
  if Result = '' then begin
    if RuntimePage.SelectedValueIndex = 1 then Result := 'Interim'
    else Result := 'Legacy';
  end;
end;

function RuntimeLabel(Name: String): String;
begin
  if FileExists(GetEnv('APPDATA') + '\Pulsar\' + Name + '.exe') then
    Result := Name + ' (установлен)'
  else Result := Name + ' (нужно скачать)';
end;

function InitializeSetup(): Boolean;
var
  Value: String;
begin
  Value := ExpandConstant('{param:RUNTIME|}');
  Result := (Value = '') or (Value = 'Legacy') or (Value = 'Interim');
  if not Result then SuppressibleMsgBox('RUNTIME: Legacy или Interim.', mbError, MB_OK, IDOK);
end;

procedure InitializeWizard;
begin
  RuntimePage := CreateInputOptionPage(wpWelcome, 'Запуск Space Engineers 1',
    'Выберите вариант Pulsar',
    'Legacy — .NET Framework 4.8. Interim — .NET 10 через слой совместимости.' + #13#10 +
    'Для Interim при необходимости будет загружен .NET 10 Desktop Runtime с сайта Microsoft.' + #13#10 +
    'Modern предназначен для Space Engineers 2 и здесь не используется.', True, False);
  RuntimePage.Add(RuntimeLabel('Legacy'));
  RuntimePage.Add(RuntimeLabel('Interim'));
  RuntimePage.SelectedValueIndex := 0;
  if FileExists(GetEnv('APPDATA') + '\Pulsar\Interim.exe') and
    not FileExists(GetEnv('APPDATA') + '\Pulsar\Legacy.exe') then RuntimePage.SelectedValueIndex := 1;
end;

function EnsureProfile(var Failure: String): Boolean;
var
  Data, ProfilePath: String;
begin
  Data := GetEnv('APPDATA') + '\Pulsar\' + SelectedRuntime();
  if (SelectedRuntime() = 'Interim') and not DirExists(Data) then
    Data := GetEnv('APPDATA') + '\Pulsar\Legacy';
  ProfilePath := Data + '\Profiles\Current.xml';
  Result := True;
  if not FileExists(ProfilePath) then begin
    Result := ForceDirectories(Data + '\Profiles') and SaveStringToFile(ProfilePath,
      '<?xml version="1.0" encoding="utf-8"?><Profile><Name>Current</Name>' +
      '<GitHub/><DevFolder/><Local/><Mods/></Profile>', False);
    if not Result then Failure := 'Не удалось создать профиль Pulsar: ' + ProfilePath;
  end;
end;

function PSQuote(Value: String): String;
begin
  StringChangeEx(Value, '''', '''''', True);
  Result := '''' + Value + '''';
end;

function DesktopPath(): String;
begin
  // Explicit override is useful for isolated lifecycle tests (also pass it to unins000.exe).
  Result := ExpandConstant('{param:DESKTOP|{userdesktop}}');
end;

function RunScript(Path: String; ValidateOnly: Boolean; var Failure: String): Boolean;
var
  Params, Command: String;
  Code, I: Integer;
  Output: TExecOutput;
begin
  Failure := '';
  Command := '[Console]::OutputEncoding = [System.Text.Encoding]::UTF8; & ' + PSQuote(Path);
  if (ExtractFileName(Path) = 'install.ps1') or (ExtractFileName(Path) = 'uninstall.ps1') then
    Command := Command + ' -NonInteractive -Desktop ' + PSQuote(DesktopPath());
  if (ExtractFileName(Path) = 'install.ps1') or (ExtractFileName(Path) = 'install-pulsar.ps1') or
    (ExtractFileName(Path) = 'uninstall.ps1') then
    Command := Command + ' -Runtime ' + PSQuote(SelectedRuntime());
  if ExtractFileName(Path) = 'install-transaction.ps1' then
    Command := Command + ' -Action ' + TransactionAction + ' -StatePath ' +
      PSQuote(ExpandConstant('{tmp}\sco-transaction')) + ' -Desktop ' + PSQuote(DesktopPath());
  if ValidateOnly then Command := Command + ' -ValidateOnly';
  Command := Command + '; exit $LASTEXITCODE';
  Params := '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command "' + Command + '"';
  try
    Result := ExecAndCaptureOutput(ExpandConstant('{sys}\WindowsPowerShell\v1.0\powershell.exe'),
      Params, ExtractFileDir(Path), SW_HIDE, ewWaitUntilTerminated, Code, Output);
    if not Result then begin
      Failure := SysErrorMessage(Code);
      Exit;
    end;
    for I := 0 to GetArrayLength(Output.StdOut) - 1 do begin
      Log(Output.StdOut[I]);
      Failure := Failure + Output.StdOut[I] + #13#10;
    end;
    for I := 0 to GetArrayLength(Output.StdErr) - 1 do begin
      Log(Output.StdErr[I]);
      Failure := Failure + Output.StdErr[I] + #13#10;
    end;
    Result := (Code = 0) and not Output.Error;
    if Result then Failure := ''
    else if Failure = '' then Failure := 'PowerShell exit code: ' + IntToStr(Code);
  except
    Result := False;
    Failure := GetExceptionMessage;
  end;
end;

function RunTransaction(Action: String; var Failure: String): Boolean;
begin
  TransactionAction := Action;
  Result := RunScript(ExpandConstant('{tmp}\install-transaction.ps1'), False, Failure);
end;

procedure DeinitializeSetup;
var
  Failure: String;
begin
  if TransactionStarted and not Completed then begin
    if not RunTransaction('Rollback', Failure) then Log('Rollback failed: ' + Failure);
  end;
end;

function PrepareToInstall(var NeedsRestart: Boolean): String;
var
  Failure: String;
  Consent: Boolean;
begin
  Result := '';
  ExtractTemporaryFile('install.ps1');
  ExtractTemporaryFile('uninstall.ps1');
  ExtractTemporaryFile('install-pulsar.ps1');
  ExtractTemporaryFile('install-dotnet.ps1');
  ExtractTemporaryFile('install-transaction.ps1');
  ExtractTemporaryFile('SentisClientOptimisation.dll');
  ExtractTemporaryFile('SentisClientOptimisation.ico');
  if not FileExists(GetEnv('APPDATA') + '\Pulsar\' + SelectedRuntime() + '.exe') then begin
    Consent := False;
    if WizardSilent then
      Consent := ExpandConstant('{param:INSTALLPULSAR|0}') = '1'
    else
      Consent := MsgBox('Pulsar ' + SelectedRuntime() + ' не найден.' + #13#10 +
        'Скачать и установить Pulsar с официального GitHub?' + #13#10 +
        'Для загрузки требуется подключение к интернету.', mbConfirmation, MB_YESNO or MB_DEFBUTTON2) = IDYES;
    if not Consent then begin
      Result := 'Для работы плагина требуется Pulsar. Установка отменена: Pulsar не установлен.';
      Exit;
    end;
    WizardForm.StatusLabel.Caption := 'Загрузка и установка Pulsar...';
    WizardForm.Refresh;
    if not RunScript(ExpandConstant('{tmp}\install-pulsar.ps1'), False, Failure) then begin
      Result := 'Не удалось установить Pulsar:' + #13#10 + Failure;
      Exit;
    end;
  end;
  if SelectedRuntime() = 'Interim' then begin
    WizardForm.StatusLabel.Caption := 'Проверка и установка .NET 10 Desktop Runtime...';
    WizardForm.Refresh;
    if not RunScript(ExpandConstant('{tmp}\install-dotnet.ps1'), False, Failure) then begin
      Result := 'Не удалось подготовить .NET 10:' + #13#10 + Failure;
      Exit;
    end;
  end;
  if TransactionStarted then begin
    if not RunTransaction('Rollback', Failure) then begin Result := Failure; Exit; end;
    TransactionStarted := False;
  end;
  if not RunTransaction('Begin', Failure) then begin Result := Failure; Exit; end;
  TransactionStarted := True;
  if not EnsureProfile(Failure) then begin
    Result := Failure;
    Exit;
  end;
  if not RunScript(ExpandConstant('{tmp}\install.ps1'), True, Failure) then begin
    Result := Failure;
    Exit;
  end;
  CleanPrevious := FileExists(GetEnv('APPDATA') + '\Pulsar\Legacy\Local\SentisClientOptimisation.dll') or
    FileExists(GetEnv('APPDATA') + '\Pulsar\Interim\Local\SentisClientOptimisation.dll') or
    FileExists(GetEnv('APPDATA') + '\Pulsar\Legacy.exe.config.bak-before-gc') or
    FileExists(GetEnv('APPDATA') + '\Pulsar\Interim.runtimeconfig.json.bak-before-gc');
  if CleanPrevious and not RunScript(ExpandConstant('{tmp}\uninstall.ps1'), True, Failure) then Result := Failure;
end;

procedure CurStepChanged(CurStep: TSetupStep);
var
  Failure: String;
begin
  if CurStep = ssPostInstall then begin
    if not SaveStringToFile(ExpandConstant('{app}\runtime.txt'), SelectedRuntime(), False) then
      RaiseException('Не удалось сохранить выбранный runtime.');
  end;
  if CurStep = ssDone then begin
    Completed := True;
    if TransactionStarted and not RunTransaction('Commit', Failure) then Log(Failure);
    TransactionStarted := False;
  end;
  if CurStep = ssInstall then begin
    if CleanPrevious and not RunScript(ExpandConstant('{tmp}\uninstall.ps1'), False, Failure) then begin
      SuppressibleMsgBox(Failure, mbError, MB_OK, IDOK);
      Abort;
    end;
    if not RunScript(ExpandConstant('{tmp}\install.ps1'), False, Failure) then begin
      SuppressibleMsgBox(Failure, mbError, MB_OK, IDOK);
      Abort;
    end;
  end;
end;

function InitializeUninstall(): Boolean;
var
  Failure: String;
  Value: AnsiString;
begin
  SavedRuntime := 'Legacy';
  if LoadStringFromFile(ExpandConstant('{app}\runtime.txt'), Value) then begin
    if Value = 'Interim' then SavedRuntime := 'Interim';
  end;
  Result := RunScript(ExpandConstant('{app}\uninstall.ps1'), True, Failure);
  if not Result then SuppressibleMsgBox(Failure, mbError, MB_OK, IDOK);
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
var
  Failure: String;
begin
  if CurUninstallStep = usUninstall then begin
    if not RunScript(ExpandConstant('{app}\uninstall.ps1'), False, Failure) then begin
      SuppressibleMsgBox(Failure, mbError, MB_OK, IDOK);
      Abort;
    end;
  end;
end;
