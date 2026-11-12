// ExecAndLogOutput disables the native HWND without changing VCL Enabled.
// Setting WizardForm.Enabled := True alone is therefore a no-op.
function EnableDependencyWindow(Wnd: HWND; Enabled: BOOL): BOOL;
  external 'EnableWindow@user32.dll stdcall';

// Streaming worker protocol. Counters describe the current phase, not the entire installation.
function ProgressToken(var Value: String): String;
var
  P: Integer;
begin
  P := Pos('|', Value);
  if P = 0 then begin Result := Value; Value := ''; end
  else begin Result := Copy(Value, 1, P - 1); Delete(Value, 1, P); end;
end;

function ProgressCaption(Phase: String): String;
begin
  Result := '';
  if Phase = 'metadata-pulsar' then Result := 'Получение сведений о Pulsar'
  else if Phase = 'download-pulsar' then Result := 'Загрузка Pulsar'
  else if Phase = 'verify-pulsar' then Result := 'Проверка архива Pulsar'
  else if Phase = 'extract-pulsar' then Result := 'Распаковка Pulsar'
  else if Phase = 'copy-pulsar' then Result := 'Установка файлов Pulsar'
  else if Phase = 'detect-dotnet' then Result := 'Проверка .NET 10 Desktop Runtime'
  else if Phase = 'metadata-dotnet' then Result := 'Получение сведений о .NET 10'
  else if Phase = 'download-runtime' then Result := 'Загрузка .NET 10 Runtime'
  else if Phase = 'download-windowsdesktop' then Result := 'Загрузка .NET 10 Desktop Runtime'
  else if (Phase = 'verify-runtime') or (Phase = 'verify-windowsdesktop') then Result := 'Проверка файлов .NET 10'
  else if (Phase = 'extract-runtime') or (Phase = 'extract-windowsdesktop') then Result := 'Распаковка .NET 10'
  else if Phase = 'done' then Result := 'Компонент готов';
end;

function RenderDependencyProgress(Line: String): Boolean;
var
  Data, Phase, Caption, Detail: String;
  Current, Total: Int64;
  Position, Percent: Integer;
begin
  Result := False;
  if Copy(Line, 1, 13) <> 'SCO_PROGRESS|' then Exit;
  Data := Copy(Line, 14, Length(Line));
  Phase := ProgressToken(Data);
  Current := StrToInt64Def(ProgressToken(Data), -1);
  Total := StrToInt64Def(ProgressToken(Data), -1);
  Caption := ProgressCaption(Phase);
  if (Data <> '') or (Caption = '') or (Current < 0) or (Total < 0) then Exit;
  if (Total > 0) and (Current > Total) then Exit;
  Result := True;
  if not DependencyPageVisible then Exit;

  // Exec disables windows while waiting. This page has psNoButtons, so enabling
  // only the wizard safely permits repaint/move/minimize, not reentrant setup actions.
  EnableDependencyWindow(WizardForm.Handle, True);
  Detail := '';
  if (Total > 0) and (Pos('metadata-', Phase) <> 1) then begin
    // Force floating-point arithmetic: Int64 / Int64 truncates in Pascal Script.
    Position := Round((Current * 1000.0) / Total);
    Percent := Round((Current * 100.0) / Total);
    if Pos('download-', Phase) = 1 then
      Detail := Format('%.1f / %.1f МБ (%d%%)', [Current / 1048576.0, Total / 1048576.0, Percent])
    else if Phase <> 'done' then
      Detail := Format('Файлы: %s / %s (%d%%)', [IntToStr(Current), IntToStr(Total), Percent]);
    DependencyPage.SetText(Caption, Detail);
    DependencyPage.SetProgress(Position, 1000);
  end else begin
    if Pos('download-', Phase) = 1 then Detail := Format('Скачано %.1f МБ', [Current / 1048576.0]);
    DependencyPage.SetText(Caption, Detail);
    DependencyPage.SetProgress(0, 1000);
    DependencyPage.ProgressBar.Style := npbstMarquee;
  end;
end;

procedure DependencyOutput(const S: String; const Error, FirstLine: Boolean);
begin
  Log(S);
  if Error then DependencyOutputError := True;
  if not RenderDependencyProgress(S) then begin
    if Length(DependencyMessages) < 32768 then
      DependencyMessages := DependencyMessages + S + #13#10;
  end;
end;
